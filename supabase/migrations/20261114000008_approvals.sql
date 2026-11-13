-- TASK-023, TASK-024 · REQ-057, REQ-032 (and later REQ-037, REQ-039, REQ-041)
-- Approvals engine. Standard+: requests go to the inbox, decided by the owner or a
-- manager with approval rights (on by default). Basic: no inbox, so restricted
-- actions are done only under the owner's login (PRD §3, DEC-027).

alter table public.stations add column manager_can_approve boolean not null default true;

create type public.approval_type as enum ('discount', 'refund', 'stock_adjustment', 'credit_release');
create type public.approval_status as enum ('pending', 'approved', 'rejected');
create type public.adjustment_reason as enum ('count_difference', 'damaged', 'expired', 'other');

create table public.approval_requests (
  id            uuid primary key default gen_random_uuid(),
  station_id    uuid not null references public.stations(id) on delete cascade,
  type          public.approval_type not null,
  status        public.approval_status not null default 'pending',
  requested_by  uuid not null default auth.uid() references public.profiles(id),
  record_table  text,
  record_id     uuid,
  amount_paisa  bigint,
  reason        text not null,
  payload       jsonb not null default '{}'::jsonb,
  decided_by    uuid references public.profiles(id),
  decided_at    timestamptz,
  decision_note text,
  created_at    timestamptz not null default now()
);
create index approval_requests_pending_idx on public.approval_requests(station_id, created_at desc) where status = 'pending';

-- Who may approve: the owner; or a manager when delegated and the plan has the inbox.
create or replace function private.can_approve(p_station uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select private.has_role(p_station, array['owner']::public.member_role[])
      or (private.has_role(p_station, array['manager']::public.member_role[])
          and private.has_feature(p_station, 'approvals_inbox')
          and coalesce((select manager_can_approve from public.stations where id = p_station), false));
$$;
grant execute on all functions in schema private to authenticated, service_role;

alter table public.approval_requests enable row level security;

-- Approvers see the station's requests; everyone sees their own.
create policy approval_requests_read on public.approval_requests for select to authenticated
  using (requested_by = auth.uid() or private.can_approve(station_id) or private.has_support_grant(station_id));
revoke insert, update, delete on public.approval_requests from anon, authenticated;

create trigger audit_approval_requests after insert or update on public.approval_requests
  for each row execute function private.audit_row();

-- Generic request creator used by later phases (discount, refund, credit release).
create or replace function private.create_approval(
  p_station uuid, p_type public.approval_type, p_record_table text, p_record_id uuid,
  p_amount bigint, p_reason text, p_payload jsonb default '{}'::jsonb)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_id uuid;
begin
  if not private.has_feature(p_station, 'approvals_inbox') then
    perform private.fail('OWNER_ONLY', 'On the Basic plan only the owner can do this. Ask the owner to log in.');
  end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then
    perform private.fail('VALIDATION', 'A reason is required');
  end if;
  insert into public.approval_requests (station_id, type, record_table, record_id, amount_paisa, reason, payload)
  values (p_station, p_type, p_record_table, p_record_id, p_amount, trim(p_reason), coalesce(p_payload, '{}'::jsonb))
  returning id into v_id;
  return v_id;
end;
$$;

-- Applies an approved request. Each type adds its effect here as later phases arrive.
create or replace function private.apply_approval(r public.approval_requests)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if r.type = 'stock_adjustment' then
    perform private.move_stock(r.station_id, (r.payload ->> 'item_id')::uuid, (r.payload ->> 'qty')::numeric,
                               'adjustment', r.id, null, r.reason);
  end if;
  -- discount / refund / credit_release: the waiting action checks for an approved request (Phase 4).
end;
$$;
grant execute on all functions in schema private to authenticated, service_role;

-- REQ-032: request a stock adjustment. The owner's own adjustment applies at once
-- (and is logged as an approved request); others wait for approval.
create or replace function public.station_request_stock_adjustment(
  p_station uuid, p_item uuid, p_qty numeric, p_reason public.adjustment_reason, p_note text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_id uuid;
  v_text text;
  v_unit public.item_unit;
  r public.approval_requests;
begin
  if not private.has_role(p_station, array['owner','manager','cashier']::public.member_role[]) then
    perform private.fail('FORBIDDEN');
  end if;
  perform private.assert_can_write(p_station);
  select unit into v_unit from public.items where id = p_item and station_id = p_station;
  if v_unit is null then perform private.fail('NOT_FOUND', 'Item not found'); end if;
  if v_unit = 'kit' then perform private.fail('VALIDATION', 'Adjust the kit''s components instead'); end if;
  if coalesce(p_qty, 0) = 0 or not private.valid_qty(v_unit, p_qty) then
    perform private.fail('VALIDATION', 'Enter a + or − quantity (whole numbers; 2 decimals for litres)');
  end if;
  if p_reason = 'other' and length(trim(coalesce(p_note, ''))) < 3 then
    perform private.fail('VALIDATION', 'Add a note for "other"');
  end if;
  v_text := replace(p_reason::text, '_', ' ') || coalesce(': ' || nullif(trim(p_note), ''), '');

  if private.has_role(p_station, array['owner']::public.member_role[]) then
    insert into public.approval_requests (station_id, type, status, record_table, record_id, reason, payload,
                                          decided_by, decided_at, decision_note)
    values (p_station, 'stock_adjustment', 'approved', 'items', p_item, v_text,
            jsonb_build_object('item_id', p_item, 'qty', p_qty, 'reason', p_reason),
            auth.uid(), now(), 'Owner adjustment')
    returning * into r;
    perform private.apply_approval(r);
    return r.id;
  end if;

  v_id := private.create_approval(p_station, 'stock_adjustment', 'items', p_item, null, v_text,
                                  jsonb_build_object('item_id', p_item, 'qty', p_qty, 'reason', p_reason));
  return v_id;
end;
$$;

-- REQ-057: approve or reject. Final; nobody decides their own request.
create or replace function public.station_decide_approval(p_request uuid, p_approve boolean, p_note text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.approval_requests;
begin
  select * into r from public.approval_requests where id = p_request for update;
  if r.id is null or not private.can_approve(r.station_id) then
    perform private.fail('NOT_FOUND');
  end if;
  perform private.assert_can_write(r.station_id);
  if r.status <> 'pending' then
    perform private.fail('VALIDATION', 'This request was already decided');
  end if;
  if r.requested_by = auth.uid() then
    perform private.fail('VALIDATION', 'You cannot decide your own request');
  end if;

  update public.approval_requests
     set status = case when p_approve then 'approved'::public.approval_status else 'rejected'::public.approval_status end,
         decided_by = auth.uid(), decided_at = now(), decision_note = nullif(trim(p_note), '')
   where id = p_request
  returning * into r;

  if p_approve then
    perform private.apply_approval(r);
  end if;
end;
$$;

create or replace function public.station_set_manager_can_approve(p_station uuid, p_allowed boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then
    perform private.fail('FORBIDDEN');
  end if;
  perform private.assert_station_open(p_station);
  update public.stations set manager_can_approve = coalesce(p_allowed, true) where id = p_station;
end;
$$;

-- Inbox rows with names, for SCR-012 / SCR-034.
create or replace view public.approval_inbox
with (security_invoker = true)
as
select r.*, rq.full_name as requested_by_name, dc.full_name as decided_by_name,
       i.name as item_name, i.unit as item_unit
from public.approval_requests r
left join public.profiles rq on rq.id = r.requested_by
left join public.profiles dc on dc.id = r.decided_by
left join public.items i on i.id = r.record_id and r.record_table = 'items';
grant select on public.approval_inbox to authenticated;

revoke execute on function
  public.station_request_stock_adjustment(uuid, uuid, numeric, public.adjustment_reason, text),
  public.station_decide_approval(uuid, boolean, text),
  public.station_set_manager_can_approve(uuid, boolean)
from public, anon;
grant execute on function
  public.station_request_stock_adjustment(uuid, uuid, numeric, public.adjustment_reason, text),
  public.station_decide_approval(uuid, boolean, text),
  public.station_set_manager_can_approve(uuid, boolean)
to authenticated;
