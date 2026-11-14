-- TASK-029…033 · REQ-018…022, REQ-024, REQ-031
-- Job cards: intake, checklist, estimate lines, approvals, extra work, stages,
-- mechanic assignment, quality check and parts with stock movements.
--
-- Line status:  estimate      — in the estimate, before customer approval
--               approved      — approved work (estimate approved, or extra approved)
--               extra_pending — added after approval; needs customer re-approval (REQ-022)
--               rejected      — customer said no; never invoiced
--               removed       — taken off before invoicing
-- Stock follows part lines: once the job is approved, an approved or extra_pending
-- part line takes stock; rejecting or removing it gives stock back (REQ-031).

alter table public.stations add column inspection_fee_paisa bigint not null default 0 check (inspection_fee_paisa >= 0);

create type public.job_stage as enum
  ('intake', 'awaiting_approval', 'approved', 'in_progress', 'quality_check', 'ready', 'delivered', 'cancelled');
create type public.fuel_level as enum ('E', 'Q1', 'H', 'Q3', 'F');
create type public.job_kind as enum ('normal', 'rework', 'warranty');
create type public.line_kind as enum ('part', 'labour', 'fee', 'customer_part');
create type public.line_status as enum ('estimate', 'approved', 'extra_pending', 'rejected', 'removed');
create type public.check_status as enum ('not_checked', 'ok', 'attention');
create type public.approval_via as enum ('app', 'phone', 'in_person');

-- Station checklist template (REQ-019) ---------------------------------------
create table public.checklist_templates (
  id         uuid primary key default gen_random_uuid(),
  station_id uuid not null references public.stations(id) on delete cascade,
  name       text not null check (length(trim(name)) between 2 and 80),
  sort_order integer not null default 0,
  active     boolean not null default true,
  unique (station_id, name)
);

-- Sequential job numbers per station, never reused.
create table public.job_counters (
  station_id uuid primary key references public.stations(id) on delete cascade,
  last_no    integer not null default 1000
);

create table public.job_cards (
  id                 uuid primary key default gen_random_uuid(),
  station_id         uuid not null references public.stations(id) on delete cascade,
  job_no             integer not null,
  kind               public.job_kind not null default 'normal',
  parent_job_id      uuid references public.job_cards(id),
  customer_id        uuid not null references public.customers(id),
  vehicle_id         uuid not null references public.vehicles(id),
  booking_id         uuid,
  odometer_km        integer not null check (odometer_km >= 0),
  fuel_level         public.fuel_level not null,
  complaints         text,
  expected_delivery  timestamptz,
  stage              public.job_stage not null default 'intake',
  parts_free         boolean not null default false,   -- rework/warranty: parts charged 0
  approved_via       public.approval_via,
  approved_by_name   text,
  approved_at        timestamptz,
  qc_note            text,
  cancel_reason      text,
  started_at         timestamptz,
  delivered_at       timestamptz,
  created_by         uuid default auth.uid(),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (station_id, job_no)
);
create index job_cards_stage_idx on public.job_cards(station_id, stage, created_at desc);
create index job_cards_vehicle_idx on public.job_cards(vehicle_id, created_at desc);

create table public.job_assignments (
  station_id  uuid not null references public.stations(id) on delete cascade,
  job_id      uuid not null references public.job_cards(id) on delete cascade,
  user_id     uuid not null references public.profiles(id),
  assigned_at timestamptz not null default now(),
  primary key (job_id, user_id)
);
create index job_assignments_user_idx on public.job_assignments(user_id);

create table public.job_checklist_items (
  id          uuid primary key default gen_random_uuid(),
  station_id  uuid not null references public.stations(id) on delete cascade,
  job_id      uuid not null references public.job_cards(id) on delete cascade,
  name        text not null,
  sort_order  integer not null default 0,
  status      public.check_status not null default 'not_checked',
  note        text,
  changed_at  timestamptz not null default now(),   -- client time of the last change (conflict rule)
  updated_by  uuid
);
create index job_checklist_job_idx on public.job_checklist_items(job_id);

create table public.job_lines (
  id                uuid primary key default gen_random_uuid(),  -- clients may supply it (offline adds)
  station_id        uuid not null references public.stations(id) on delete cascade,
  job_id            uuid not null references public.job_cards(id) on delete cascade,
  kind              public.line_kind not null,
  item_id           uuid references public.items(id),
  description       text not null,
  qty               numeric(12,3) not null check (qty > 0),
  unit_price_paisa  bigint not null default 0 check (unit_price_paisa >= 0),
  status            public.line_status not null,
  warranty_days     integer not null default 0,
  checklist_item_id uuid references public.job_checklist_items(id),
  warranty_of_line  uuid references public.job_lines(id),
  stock_applied     numeric(12,3) not null default 0,     -- qty already taken from stock
  added_by          uuid default auth.uid(),
  created_at        timestamptz not null default now(),
  check ((kind = 'part') = (item_id is not null) or kind = 'customer_part')
);
create index job_lines_job_idx on public.job_lines(job_id);

-- Every stage and field change, with the client time for offline changes (REQ-021, REQ-023).
create table public.job_history (
  id          bigint generated always as identity primary key,
  station_id  uuid not null references public.stations(id) on delete cascade,
  job_id      uuid not null references public.job_cards(id) on delete cascade,
  field       text not null,          -- 'stage', 'checklist:<id>', 'line:<id>', 'approval', 'qc', ...
  old_value   text,
  new_value   text,
  note        text,
  conflict    boolean not null default false,   -- this value lost to a later change
  client_time timestamptz,
  source      text not null default 'online',   -- online | sync
  actor_id    uuid default auth.uid(),
  created_at  timestamptz not null default now()
);
create index job_history_job_idx on public.job_history(job_id, created_at);
create trigger job_history_append_only before update or delete on public.job_history
  for each row execute function private.append_only();

-- Minimal in-app notifications (push delivery arrives with Phase 7, REQ-056).
create table public.notifications (
  id          bigint generated always as identity primary key,
  station_id  uuid not null references public.stations(id) on delete cascade,
  user_id     uuid references public.profiles(id),          -- null = all owners/managers
  kind        text not null,                                -- conflict | qc_fail | assigned | negative_stock
  title       text not null,
  body        text,
  ref_id      uuid,
  created_at  timestamptz not null default now(),
  read_at     timestamptz
);
create index notifications_user_idx on public.notifications(station_id, created_at desc);

-- RLS -----------------------------------------------------------------------------
alter table public.checklist_templates enable row level security;
alter table public.job_counters        enable row level security;
alter table public.job_cards           enable row level security;
alter table public.job_assignments     enable row level security;
alter table public.job_checklist_items enable row level security;
alter table public.job_lines           enable row level security;
alter table public.job_history         enable row level security;
alter table public.notifications       enable row level security;

create or replace function private.is_assigned(p_job uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$ select exists (select 1 from public.job_assignments a where a.job_id = p_job and a.user_id = auth.uid()); $$;

-- Staff (OW, MG, CA) see all jobs; mechanics only jobs assigned to them.
create or replace function private.can_see_job(p_station uuid, p_job uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select private.has_role(p_station, array['owner','manager','cashier']::public.member_role[])
      or (private.has_role(p_station, array['mechanic']::public.member_role[]) and private.is_assigned(p_job))
      or private.has_support_grant(p_station);
$$;
grant execute on all functions in schema private to authenticated, service_role;

create policy checklist_templates_read on public.checklist_templates for select to authenticated
  using (private.can_read_station(station_id));
create policy job_cards_read on public.job_cards for select to authenticated
  using (private.can_see_job(station_id, id));
create policy job_assignments_read on public.job_assignments for select to authenticated
  using (private.can_see_job(station_id, job_id));
create policy job_checklist_read on public.job_checklist_items for select to authenticated
  using (private.can_see_job(station_id, job_id));
-- Prices: never to mechanics (REQ-002). Mechanics get lines through sync_pull without prices.
create policy job_lines_read on public.job_lines for select to authenticated
  using (private.has_role(station_id, array['owner','manager','cashier']::public.member_role[])
         or private.has_support_grant(station_id));
create policy job_history_read on public.job_history for select to authenticated
  using (private.can_see_job(station_id, job_id));
create policy notifications_read on public.notifications for select to authenticated
  using (user_id = auth.uid()
         or (user_id is null and private.has_role(station_id, array['owner','manager']::public.member_role[])));

revoke insert, update, delete on public.checklist_templates, public.job_counters, public.job_cards,
  public.job_assignments, public.job_checklist_items, public.job_lines, public.job_history, public.notifications
  from anon, authenticated;
-- job_counters is internal only: RLS on, no select policy, so clients see no rows.

create trigger audit_job_cards after insert or update on public.job_cards
  for each row execute function private.audit_row();
create trigger audit_job_lines after insert or update on public.job_lines
  for each row execute function private.audit_row();

-- Internal helpers ---------------------------------------------------------------
create or replace function private.notify(p_station uuid, p_user uuid, p_kind text, p_title text, p_body text, p_ref uuid)
returns void
language sql security definer set search_path = ''
as $$
  insert into public.notifications (station_id, user_id, kind, title, body, ref_id)
  values (p_station, p_user, p_kind, p_title, p_body, p_ref);
$$;

create or replace function private.log_job(
  p_station uuid, p_job uuid, p_field text, p_old text, p_new text,
  p_note text default null, p_client_time timestamptz default null, p_source text default 'online', p_conflict boolean default false)
returns void
language sql security definer set search_path = ''
as $$
  insert into public.job_history (station_id, job_id, field, old_value, new_value, note, client_time, source, conflict)
  values (p_station, p_job, p_field, p_old, p_new, p_note, p_client_time, p_source, p_conflict);
$$;

-- Loads a job and checks the caller may act on it. Mechanics only on assigned jobs.
create or replace function private.job_for(p_job uuid, p_roles public.member_role[])
returns public.job_cards
language plpgsql stable security definer set search_path = ''
as $$
declare j public.job_cards;
begin
  select * into j from public.job_cards where id = p_job;
  if j.id is null
     or not private.has_role(j.station_id, p_roles)
     or (private.has_role(j.station_id, array['mechanic']::public.member_role[])
         and not private.has_role(j.station_id, array['owner','manager','cashier']::public.member_role[])
         and not private.is_assigned(p_job)) then
    perform private.fail('NOT_FOUND', 'Job card not found');
  end if;
  return j;
end;
$$;

-- Brings a line's stock in line with its status (idempotent). Kits move their components.
create or replace function private.sync_line_stock(p_line uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  l public.job_lines;
  j public.job_cards;
  v_unit public.item_unit;
  v_want numeric;
  v_delta numeric;
  c record;
begin
  select * into l from public.job_lines where id = p_line for update;
  if l.kind <> 'part' then return; end if;
  select * into j from public.job_cards where id = l.job_id;
  v_want := case
    when l.status in ('approved', 'extra_pending')
     and j.stage in ('approved', 'in_progress', 'quality_check', 'ready', 'delivered', 'cancelled') then l.qty
    else 0 end;
  v_delta := v_want - l.stock_applied;
  if v_delta = 0 then return; end if;

  select unit into v_unit from public.items where id = l.item_id;
  if v_unit = 'kit' then
    for c in select component_item_id, qty from public.kit_components where kit_item_id = l.item_id loop
      perform private.move_stock(l.station_id, c.component_item_id, -(v_delta * c.qty),
        case when v_delta > 0 then 'job_use'::public.stock_move_kind else 'job_return'::public.stock_move_kind end, l.job_id);
    end loop;
  else
    perform private.move_stock(l.station_id, l.item_id, -v_delta,
      case when v_delta > 0 then 'job_use'::public.stock_move_kind else 'job_return'::public.stock_move_kind end, l.job_id);
    -- REQ-031: negative stock is allowed with a warning to managers.
    if v_delta > 0 and private.on_hand(l.item_id) < 0 then
      perform private.notify(l.station_id, null, 'negative_stock', 'Negative stock',
        (select name from public.items where id = l.item_id) || ' is below zero', l.item_id);
    end if;
  end if;
  update public.job_lines set stock_applied = v_want where id = p_line;
end;
$$;

create or replace function private.sync_job_stock(p_job uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare r record;
begin
  for r in select id from public.job_lines where job_id = p_job and kind = 'part' loop
    perform private.sync_line_stock(r.id);
  end loop;
end;
$$;

-- Stage change with rules per role (REQ-021). Mechanics: approved -> in_progress -> quality_check.
create or replace function private.set_stage(
  p_job uuid, p_stage public.job_stage, p_note text default null,
  p_client_time timestamptz default null, p_source text default 'online')
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  j public.job_cards := private.job_for(p_job, array['owner','manager','cashier','mechanic']::public.member_role[]);
  v_staff boolean := private.has_role(j.station_id, array['owner','manager','cashier']::public.member_role[]);
  v_ok boolean;
begin
  perform private.assert_can_write(j.station_id);
  if j.stage = p_stage then return; end if;

  v_ok := case
    when j.stage = 'approved'      and p_stage = 'in_progress'   then true
    when j.stage = 'quality_check' and p_stage = 'in_progress'   then true   -- reopened by mechanic
    when j.stage = 'in_progress'   and p_stage = 'quality_check' then true
    when j.stage = 'ready'         and p_stage = 'delivered'     then v_staff
    else false end;
  if not v_ok then
    perform private.fail('VALIDATION', format('Cannot move from %s to %s', j.stage, p_stage));
  end if;
  if p_stage = 'quality_check' and exists (select 1 from public.job_checklist_items
      where job_id = p_job and status = 'not_checked') then
    perform private.fail('VALIDATION', 'Finish the checklist before quality check');
  end if;
  if p_stage = 'delivered' and exists (select 1 from public.job_lines where job_id = p_job and status = 'extra_pending') then
    perform private.fail('VALIDATION', 'Extra work is still waiting for customer approval');
  end if;
  -- Delivery payment / credit-release rule (REQ-039) is added with billing in Phase 4.

  update public.job_cards set stage = p_stage, updated_at = now(),
    started_at = case when p_stage = 'in_progress' then coalesce(started_at, now()) else started_at end,
    delivered_at = case when p_stage = 'delivered' then now() else delivered_at end
  where id = p_job;
  perform private.log_job(j.station_id, p_job, 'stage', j.stage::text, p_stage::text, p_note, p_client_time, p_source);
end;
$$;

-- Adds a line. Status depends on the stage: estimate before approval, extra_pending after.
create or replace function private.add_line(
  p_job uuid, p_kind public.line_kind, p_item uuid, p_description text, p_qty numeric,
  p_price bigint, p_line_id uuid default null, p_checklist uuid default null,
  p_client_time timestamptz default null, p_source text default 'online')
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  j public.job_cards := private.job_for(p_job, array['owner','manager','cashier','mechanic']::public.member_role[]);
  v_mechanic boolean := not private.has_role(j.station_id, array['owner','manager','cashier']::public.member_role[]);
  it public.items;
  v_id uuid := coalesce(p_line_id, gen_random_uuid());
  v_status public.line_status;
  v_price bigint := coalesce(p_price, 0);
  v_desc text := nullif(trim(p_description), '');
begin
  perform private.assert_can_write(j.station_id);
  if j.stage in ('delivered', 'cancelled', 'ready') then
    perform private.fail('VALIDATION', 'This job card is closed for changes');
  end if;
  if v_mechanic and (p_kind <> 'part' or j.stage not in ('approved', 'in_progress', 'quality_check')) then
    perform private.fail('FORBIDDEN', 'Mechanics add parts used after approval');
  end if;
  if coalesce(p_qty, 0) <= 0 then perform private.fail('VALIDATION', 'Quantity must be above 0'); end if;

  if p_kind = 'part' then
    select * into it from public.items where id = p_item and station_id = j.station_id;
    if it.id is null then perform private.fail('NOT_FOUND', 'Item not found'); end if;
    if not private.valid_qty(it.unit, p_qty) then
      perform private.fail('VALIDATION', case when it.unit = 'litre' then 'Litres allow at most 2 decimals' else 'Quantity must be a whole number' end);
    end if;
    v_desc := coalesce(v_desc, it.name);
    -- Mechanics never set prices; staff may edit within the discount rule later (Phase 4).
    if v_mechanic or p_price is null then v_price := it.selling_price_paisa; end if;
  elsif p_kind = 'customer_part' then
    v_price := 0;   -- customer-supplied: no price, no stock effect (REQ-031)
  end if;
  if v_desc is null then perform private.fail('VALIDATION', 'Description is required'); end if;
  if j.parts_free and p_kind in ('part', 'labour') then v_price := 0; end if;
  if j.kind <> 'normal' and p_kind = 'labour' then v_price := 0; end if;   -- rework / warranty labour is free

  v_status := case when j.stage in ('intake', 'awaiting_approval') then 'estimate' else 'extra_pending' end;
  if j.stage = 'awaiting_approval' then
    -- Changing a sent estimate takes it back to intake so it can be re-sent.
    update public.job_cards set stage = 'intake', updated_at = now() where id = p_job;
    perform private.log_job(j.station_id, p_job, 'stage', 'awaiting_approval', 'intake', 'Estimate changed');
  end if;

  insert into public.job_lines (id, station_id, job_id, kind, item_id, description, qty, unit_price_paisa, status,
                                warranty_days, checklist_item_id)
  values (v_id, j.station_id, p_job, p_kind, case when p_kind = 'part' then p_item end, v_desc, p_qty, v_price, v_status,
          coalesce(it.warranty_days, 0), p_checklist);
  perform private.sync_line_stock(v_id);
  perform private.log_job(j.station_id, p_job, 'line:' || v_id, null, v_desc || ' × ' || p_qty, null, p_client_time, p_source);
  return v_id;
end;
$$;

create or replace function private.remove_line(p_line uuid, p_client_time timestamptz default null, p_source text default 'online')
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  l public.job_lines;
  j public.job_cards;
  v_mechanic boolean;
begin
  select * into l from public.job_lines where id = p_line;
  if l.id is null then perform private.fail('NOT_FOUND', 'Line not found'); end if;
  j := private.job_for(l.job_id, array['owner','manager','cashier','mechanic']::public.member_role[]);
  v_mechanic := not private.has_role(j.station_id, array['owner','manager','cashier']::public.member_role[]);
  perform private.assert_can_write(j.station_id);
  if l.status in ('removed', 'rejected') then return; end if;
  if j.stage in ('delivered', 'cancelled', 'ready') then
    perform private.fail('VALIDATION', 'This job card is closed for changes');
  end if;
  if v_mechanic and (l.kind <> 'part' or l.added_by is distinct from auth.uid()) then
    perform private.fail('FORBIDDEN', 'Mechanics can remove only parts they added');
  end if;
  update public.job_lines set status = 'removed' where id = p_line;
  perform private.sync_line_stock(p_line);
  perform private.log_job(j.station_id, j.id, 'line:' || p_line, l.description, 'removed', null, p_client_time, p_source);
end;
$$;

-- Checklist update with the last-change-wins rule (REQ-023): an older client change
-- than the stored one loses, is kept in history and managers are told.
create or replace function private.set_check(
  p_check uuid, p_status public.check_status, p_note text,
  p_client_time timestamptz default null, p_source text default 'online')
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  c public.job_checklist_items;
  j public.job_cards;
  v_time timestamptz := coalesce(p_client_time, now());
begin
  select * into c from public.job_checklist_items where id = p_check for update;
  if c.id is null then perform private.fail('NOT_FOUND', 'Checklist item not found'); end if;
  j := private.job_for(c.job_id, array['owner','manager','cashier','mechanic']::public.member_role[]);
  perform private.assert_can_write(j.station_id);
  if j.stage in ('delivered', 'cancelled') then perform private.fail('VALIDATION', 'This job card is closed'); end if;

  if v_time < c.changed_at then
    perform private.log_job(j.station_id, j.id, 'checklist:' || p_check, c.status::text, p_status::text,
      coalesce(p_note, '') || ' (lost to a later change)', p_client_time, p_source, true);
    perform private.notify(j.station_id, null, 'conflict', 'Offline change overwritten',
      format('Job %s: "%s" — a later change was kept', j.job_no, c.name), j.id);
    return 'conflict';
  end if;

  update public.job_checklist_items
     set status = p_status, note = nullif(trim(p_note), ''), changed_at = v_time, updated_by = auth.uid()
   where id = p_check;
  perform private.log_job(j.station_id, j.id, 'checklist:' || p_check, c.status::text, p_status::text, p_note, p_client_time, p_source);
  return 'applied';
end;
$$;

grant execute on all functions in schema private to authenticated, service_role;

-- Public RPCs (web and staff app online) ----------------------------------------
-- REQ-018: create a job card. Odometer lower than the last visit needs p_confirm_odometer.
create or replace function public.station_create_job(
  p_station uuid, p_customer uuid, p_vehicle uuid, p_odometer integer, p_fuel public.fuel_level,
  p_complaints text default null, p_expected timestamptz default null,
  p_confirm_odometer boolean default false, p_booking uuid default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_id uuid;
  v_no integer;
  v_last integer;
begin
  if not private.has_role(p_station, array['owner','manager','cashier']::public.member_role[]) then
    perform private.fail('FORBIDDEN');
  end if;
  perform private.assert_can_write(p_station);
  if not exists (select 1 from public.vehicles where id = p_vehicle and customer_id = p_customer and station_id = p_station) then
    perform private.fail('VALIDATION', 'Choose the customer''s vehicle');
  end if;
  if p_odometer is null or p_odometer < 0 then perform private.fail('VALIDATION', 'Enter the odometer reading'); end if;
  select max(odometer_km) into v_last from public.job_cards where vehicle_id = p_vehicle and stage <> 'cancelled';
  if v_last is not null and p_odometer < v_last and not coalesce(p_confirm_odometer, false) then
    perform private.fail('ODOMETER_LOWER', format('Odometer lower than last visit (%s) — confirm?', to_char(v_last, 'FM999,999,999')));
  end if;

  insert into public.job_counters (station_id) values (p_station) on conflict do nothing;
  update public.job_counters set last_no = last_no + 1 where station_id = p_station returning last_no into v_no;

  insert into public.job_cards (station_id, job_no, customer_id, vehicle_id, booking_id, odometer_km, fuel_level,
                                complaints, expected_delivery)
  values (p_station, v_no, p_customer, p_vehicle, p_booking, p_odometer, p_fuel, nullif(trim(p_complaints), ''), p_expected)
  returning id into v_id;

  insert into public.job_checklist_items (station_id, job_id, name, sort_order)
  select p_station, v_id, t.name, t.sort_order from public.checklist_templates t
  where t.station_id = p_station and t.active order by t.sort_order;

  perform private.log_job(p_station, v_id, 'stage', null, 'intake');
  return v_id;
end;
$$;

-- REQ-019: owner maintains the checklist template.
create or replace function public.station_save_checklist_template(p_station uuid, p_names text[])
returns void
language plpgsql security definer set search_path = ''
as $$
declare i integer;
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then perform private.fail('FORBIDDEN'); end if;
  perform private.assert_station_open(p_station);
  update public.checklist_templates set active = false where station_id = p_station;
  for i in 1 .. coalesce(array_length(p_names, 1), 0) loop
    if length(trim(p_names[i])) >= 2 then
      insert into public.checklist_templates (station_id, name, sort_order, active)
      values (p_station, trim(p_names[i]), i, true)
      on conflict (station_id, name) do update set sort_order = excluded.sort_order, active = true;
    end if;
  end loop;
end;
$$;

create or replace function public.station_set_inspection_fee(p_station uuid, p_fee_paisa bigint)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then perform private.fail('FORBIDDEN'); end if;
  perform private.assert_station_open(p_station);
  if coalesce(p_fee_paisa, -1) < 0 then perform private.fail('VALIDATION', 'Fee cannot be negative'); end if;
  update public.stations set inspection_fee_paisa = p_fee_paisa where id = p_station;
end;
$$;

create or replace function public.job_set_check(p_check uuid, p_status public.check_status, p_note text default null)
returns text
language sql security definer set search_path = ''
as $$ select private.set_check(p_check, p_status, p_note); $$;

-- REQ-019: "Add to estimate" from a checklist item marked Needs attention.
create or replace function public.job_check_to_estimate(p_check uuid, p_item uuid default null, p_description text default null, p_price_paisa bigint default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare c public.job_checklist_items;
begin
  select * into c from public.job_checklist_items where id = p_check;
  if c.id is null then perform private.fail('NOT_FOUND'); end if;
  if c.status <> 'attention' then perform private.fail('VALIDATION', 'Only items marked Needs attention'); end if;
  return private.add_line(c.job_id, case when p_item is null then 'labour'::public.line_kind else 'part'::public.line_kind end,
    p_item, coalesce(p_description, c.name), 1, p_price_paisa, null, p_check);
end;
$$;

create or replace function public.job_add_line(
  p_job uuid, p_kind public.line_kind, p_item uuid, p_description text, p_qty numeric, p_price_paisa bigint default null)
returns uuid
language sql security definer set search_path = ''
as $$ select private.add_line(p_job, p_kind, p_item, p_description, p_qty, p_price_paisa); $$;

create or replace function public.job_remove_line(p_line uuid)
returns void
language sql security definer set search_path = ''
as $$ select private.remove_line(p_line); $$;

-- REQ-020: send the estimate (stage -> awaiting approval). Customer notification: Phase 6/7.
create or replace function public.job_send_estimate(p_job uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare j public.job_cards := private.job_for(p_job, array['owner','manager','cashier']::public.member_role[]);
begin
  perform private.assert_can_write(j.station_id);
  if j.stage <> 'intake' then perform private.fail('VALIDATION', 'The estimate was already sent'); end if;
  if not exists (select 1 from public.job_lines where job_id = p_job and status = 'estimate') then
    perform private.fail('VALIDATION', 'Add at least one line to the estimate');
  end if;
  update public.job_cards set stage = 'awaiting_approval', updated_at = now() where id = p_job;
  perform private.log_job(j.station_id, p_job, 'stage', 'intake', 'awaiting_approval', 'Estimate sent');
end;
$$;

-- REQ-020 / REQ-022: record the customer's decision (phone / in person; app in Phase 6).
-- p_extra = false: the estimate. p_extra = true: the extra-work request.
create or replace function public.job_record_approval(
  p_job uuid, p_approve boolean, p_via public.approval_via, p_by_name text, p_extra boolean default false)
returns void
language plpgsql security definer set search_path = ''
as $$
declare j public.job_cards := private.job_for(p_job, array['owner','manager','cashier']::public.member_role[]);
begin
  perform private.assert_can_write(j.station_id);
  if length(trim(coalesce(p_by_name, ''))) < 2 then perform private.fail('VALIDATION', 'Enter who approved'); end if;

  if not p_extra then
    if j.stage not in ('intake', 'awaiting_approval') then perform private.fail('VALIDATION', 'Estimate already decided'); end if;
    if not exists (select 1 from public.job_lines where job_id = p_job and status = 'estimate') then
      perform private.fail('VALIDATION', 'Add at least one line to the estimate');
    end if;
    if not p_approve then
      perform public.job_cancel(p_job, 'Estimate rejected by ' || trim(p_by_name));
      return;
    end if;
    update public.job_lines set status = 'approved' where job_id = p_job and status = 'estimate';
    update public.job_cards set stage = 'approved', approved_via = p_via, approved_by_name = trim(p_by_name),
      approved_at = now(), updated_at = now() where id = p_job;
    perform private.log_job(j.station_id, p_job, 'stage', j.stage::text, 'approved',
      format('Approved by %s (%s)', trim(p_by_name), replace(p_via::text, '_', ' ')));
    perform private.sync_job_stock(p_job);
  else
    if not exists (select 1 from public.job_lines where job_id = p_job and status = 'extra_pending') then
      perform private.fail('VALIDATION', 'No extra work is waiting');
    end if;
    update public.job_lines set status = case when p_approve then 'approved'::public.line_status else 'rejected'::public.line_status end
    where job_id = p_job and status = 'extra_pending';
    perform private.sync_job_stock(p_job);
    perform private.log_job(j.station_id, p_job, 'approval', null, case when p_approve then 'extra approved' else 'extra rejected' end,
      format('By %s (%s)', trim(p_by_name), replace(p_via::text, '_', ' ')));
  end if;
end;
$$;

-- REQ-021: assign mechanics (one or more).
create or replace function public.job_assign(p_job uuid, p_mechanics uuid[])
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  j public.job_cards := private.job_for(p_job, array['owner','manager','cashier']::public.member_role[]);
  m uuid;
begin
  perform private.assert_can_write(j.station_id);
  if j.stage in ('delivered', 'cancelled') then perform private.fail('VALIDATION', 'This job card is closed'); end if;
  foreach m in array coalesce(p_mechanics, '{}') loop
    if not exists (select 1 from public.station_members where station_id = j.station_id and user_id = m and active and role = 'mechanic') then
      perform private.fail('VALIDATION', 'Only active mechanics can be assigned');
    end if;
  end loop;
  delete from public.job_assignments where job_id = p_job and not (user_id = any(coalesce(p_mechanics, '{}')));
  foreach m in array coalesce(p_mechanics, '{}') loop
    if not exists (select 1 from public.job_assignments where job_id = p_job and user_id = m) then
      insert into public.job_assignments (station_id, job_id, user_id) values (j.station_id, p_job, m);
      perform private.notify(j.station_id, m, 'assigned', 'New job assigned', format('Job %s', j.job_no), p_job);
    end if;
  end loop;
  perform private.log_job(j.station_id, p_job, 'assigned', null,
    (select string_agg(p.full_name, ', ') from public.profiles p where p.id = any(coalesce(p_mechanics, '{}'))));
end;
$$;

create or replace function public.job_set_stage(p_job uuid, p_stage public.job_stage, p_note text default null)
returns void
language sql security definer set search_path = ''
as $$ select private.set_stage(p_job, p_stage, p_note); $$;

-- REQ-024: quality check by MG/OW. Pass -> Ready; Fail -> In progress with a note to mechanics.
create or replace function public.job_quality_check(p_job uuid, p_pass boolean, p_note text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  j public.job_cards := private.job_for(p_job, array['owner','manager']::public.member_role[]);
  a record;
begin
  perform private.assert_can_write(j.station_id);
  if j.stage <> 'quality_check' then perform private.fail('VALIDATION', 'The job is not waiting for quality check'); end if;
  if not p_pass and length(trim(coalesce(p_note, ''))) < 3 then
    perform private.fail('VALIDATION', 'Add a note for the mechanic');
  end if;
  update public.job_cards set stage = case when p_pass then 'ready'::public.job_stage else 'in_progress'::public.job_stage end,
    qc_note = nullif(trim(p_note), ''), updated_at = now() where id = p_job;
  perform private.log_job(j.station_id, p_job, 'qc', 'quality_check', case when p_pass then 'ready' else 'in_progress' end, p_note);
  if not p_pass then
    for a in select user_id from public.job_assignments where job_id = p_job loop
      perform private.notify(j.station_id, a.user_id, 'qc_fail', format('Job %s failed quality check', j.job_no), p_note, p_job);
    end loop;
  end if;
  -- "Vehicle ready" message to the customer arrives with notifications (Phase 7).
end;
$$;

-- REQ-025: cancel (or estimate rejected). Inspection fee line; unused parts back to stock.
-- The invoice for these lines is created by billing (TASK-039, Phase 4).
create or replace function public.job_cancel(p_job uuid, p_reason text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  j public.job_cards := private.job_for(p_job, array['owner','manager','cashier']::public.member_role[]);
  v_fee bigint;
  v_work_started boolean;
begin
  if not private.has_role(j.station_id, array['owner','manager']::public.member_role[])
     and not (j.stage in ('intake', 'awaiting_approval')) then
    perform private.fail('FORBIDDEN', 'Only the owner or manager can cancel a job in progress');
  end if;
  perform private.assert_can_write(j.station_id);
  if j.stage in ('delivered', 'cancelled') then perform private.fail('VALIDATION', 'This job card is closed'); end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then perform private.fail('VALIDATION', 'A reason is required'); end if;

  v_work_started := j.stage in ('in_progress', 'quality_check', 'ready');
  -- Work not started: nothing was used, so every line goes; started: approved lines were used and stay.
  update public.job_lines set status = 'removed'
   where job_id = p_job and status in ('estimate', 'extra_pending')
      or (job_id = p_job and not v_work_started and status = 'approved');
  select inspection_fee_paisa into v_fee from public.stations where id = j.station_id;
  if v_fee > 0 then
    insert into public.job_lines (station_id, job_id, kind, description, qty, unit_price_paisa, status)
    values (j.station_id, p_job, 'fee', 'Inspection fee', 1, v_fee, 'approved');
  end if;
  update public.job_cards set stage = 'cancelled', cancel_reason = trim(p_reason), updated_at = now() where id = p_job;
  perform private.sync_job_stock(p_job);
  perform private.log_job(j.station_id, p_job, 'stage', j.stage::text, 'cancelled', p_reason);
end;
$$;

grant execute on all functions in schema private to authenticated, service_role;

revoke execute on function
  public.station_create_job(uuid, uuid, uuid, integer, public.fuel_level, text, timestamptz, boolean, uuid),
  public.station_save_checklist_template(uuid, text[]),
  public.station_set_inspection_fee(uuid, bigint),
  public.job_set_check(uuid, public.check_status, text),
  public.job_check_to_estimate(uuid, uuid, text, bigint),
  public.job_add_line(uuid, public.line_kind, uuid, text, numeric, bigint),
  public.job_remove_line(uuid),
  public.job_send_estimate(uuid),
  public.job_record_approval(uuid, boolean, public.approval_via, text, boolean),
  public.job_assign(uuid, uuid[]),
  public.job_set_stage(uuid, public.job_stage, text),
  public.job_quality_check(uuid, boolean, text),
  public.job_cancel(uuid, text)
from public, anon;
grant execute on function
  public.station_create_job(uuid, uuid, uuid, integer, public.fuel_level, text, timestamptz, boolean, uuid),
  public.station_save_checklist_template(uuid, text[]),
  public.station_set_inspection_fee(uuid, bigint),
  public.job_set_check(uuid, public.check_status, text),
  public.job_check_to_estimate(uuid, uuid, text, bigint),
  public.job_add_line(uuid, public.line_kind, uuid, text, numeric, bigint),
  public.job_remove_line(uuid),
  public.job_send_estimate(uuid),
  public.job_record_approval(uuid, boolean, public.approval_via, text, boolean),
  public.job_assign(uuid, uuid[]),
  public.job_set_stage(uuid, public.job_stage, text),
  public.job_quality_check(uuid, boolean, text),
  public.job_cancel(uuid, text)
to authenticated;
