-- TASK-038, TASK-039, TASK-040, TASK-044 · REQ-035, REQ-036, REQ-037, REQ-043
-- Labour/service list, invoices from approved job lines (sequential numbers, tax per
-- category, whole rupees), discount limit with approval, storage charge.
-- An invoice follows its job card until the first payment; after that it is fixed
-- and changes go through credit notes or reversals (REQ-036, REQ-042).

alter table public.stations
  add column storage_free_days integer not null default 3 check (storage_free_days >= 0),
  add column storage_charge_paisa bigint not null default 0 check (storage_charge_paisa >= 0);

-- When the vehicle became Ready (storage days count from here).
alter table public.job_cards add column ready_at timestamptz;
create or replace function private.stamp_ready()
returns trigger
language plpgsql
as $$
begin
  if new.stage = 'ready' and old.stage is distinct from 'ready' then new.ready_at := now(); end if;
  return new;
end;
$$;
create trigger job_cards_stamp_ready before update on public.job_cards
  for each row execute function private.stamp_ready();

-- Generic sequential numbers per station and document type (invoice, credit_note).
create table public.doc_counters (
  station_id uuid not null references public.stations(id) on delete cascade,
  doc        text not null,
  last_no    integer not null default 0,
  primary key (station_id, doc)
);
alter table public.doc_counters enable row level security;   -- no policy: internal only
revoke insert, update, delete on public.doc_counters from anon, authenticated;

create or replace function private.next_no(p_station uuid, p_doc text)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare v integer;
begin
  insert into public.doc_counters (station_id, doc) values (p_station, p_doc) on conflict do nothing;
  update public.doc_counters set last_no = last_no + 1 where station_id = p_station and doc = p_doc returning last_no into v;
  return v;
end;
$$;

-- REQ-035 services -------------------------------------------------------------------
create table public.services (
  id            uuid primary key default gen_random_uuid(),
  station_id    uuid not null references public.stations(id) on delete cascade,
  name          text not null check (length(trim(name)) between 2 and 120),
  rate_paisa    bigint not null default 0 check (rate_paisa >= 0),
  warranty_days integer not null default 0 check (warranty_days >= 0),
  active        boolean not null default true,
  unique (station_id, name)
);
alter table public.services enable row level security;
create policy services_read on public.services for select to authenticated
  using (private.has_role(station_id, array['owner','manager','cashier']::public.member_role[]) or private.has_support_grant(station_id));
revoke insert, update, delete on public.services from anon, authenticated;
create trigger audit_services after insert or update on public.services for each row execute function private.audit_row();

alter table public.job_lines add column service_id uuid references public.services(id);

-- Invoices --------------------------------------------------------------------------
create type public.discount_state as enum ('none', 'applied', 'pending', 'rejected');

create table public.invoices (
  id                  uuid primary key default gen_random_uuid(),
  station_id          uuid not null references public.stations(id) on delete cascade,
  invoice_no          integer not null,
  job_id              uuid not null unique references public.job_cards(id),
  customer_id         uuid not null references public.customers(id),
  vehicle_id          uuid not null references public.vehicles(id),
  issued_at           timestamptz not null default now(),
  parts_paisa         bigint not null default 0,      -- parts subtotal
  labour_paisa        bigint not null default 0,      -- labour + fees + storage
  discount_paisa      bigint not null default 0,      -- requested/applied discount
  discount_state      public.discount_state not null default 'none',
  discount_reason     text,
  tax_parts_paisa     bigint not null default 0,
  tax_services_paisa  bigint not null default 0,
  total_paisa         bigint not null default 0,      -- whole rupees
  locked              boolean not null default false, -- true after the first payment
  on_credit           boolean not null default false, -- credit release approved (REQ-039)
  created_by          uuid default auth.uid(),
  unique (station_id, invoice_no)
);
create index invoices_customer_idx on public.invoices(customer_id, issued_at);

create table public.invoice_lines (
  id               uuid primary key default gen_random_uuid(),
  station_id       uuid not null references public.stations(id) on delete cascade,
  invoice_id       uuid not null references public.invoices(id) on delete cascade,
  job_line_id      uuid references public.job_lines(id),
  kind             public.line_kind not null,
  item_id          uuid references public.items(id),
  description      text not null,
  qty              numeric(12,3) not null,
  unit_price_paisa bigint not null,
  total_paisa      bigint not null,
  warranty_days    integer not null default 0,
  returned_qty     numeric(12,3) not null default 0
);
create index invoice_lines_invoice_idx on public.invoice_lines(invoice_id);

alter table public.invoices      enable row level security;
alter table public.invoice_lines enable row level security;
create policy invoices_read on public.invoices for select to authenticated
  using (private.has_role(station_id, array['owner','manager','cashier']::public.member_role[]) or private.has_support_grant(station_id));
create policy invoice_lines_read on public.invoice_lines for select to authenticated
  using (private.has_role(station_id, array['owner','manager','cashier']::public.member_role[]) or private.has_support_grant(station_id));
revoke insert, update, delete on public.invoices, public.invoice_lines from anon, authenticated;
create trigger audit_invoices after insert or update on public.invoices for each row execute function private.audit_row();

-- Rounds paisa half-up to whole rupees (invoices show whole rupees, DEC-027).
create or replace function private.whole_rupees(p bigint)
returns bigint
language sql immutable
as $$ select (round(p / 100.0) * 100)::bigint; $$;

-- Recomputes totals from lines + discount + tax. Discount is shared across parts and
-- labour in proportion before tax (PROPOSED); tax per category, total in whole rupees.
create or replace function private.recalc_invoice(p_invoice uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  inv public.invoices;
  st public.stations;
  v_parts bigint;
  v_labour bigint;
  v_sub bigint;
  v_disc bigint;
  v_parts_net numeric;
  v_labour_net numeric;
  v_tp bigint := 0;
  v_ts bigint := 0;
begin
  select * into inv from public.invoices where id = p_invoice;
  select * into st from public.stations where id = inv.station_id;
  select coalesce(sum(total_paisa) filter (where kind = 'part'), 0),
         coalesce(sum(total_paisa) filter (where kind in ('labour', 'fee')), 0)
    into v_parts, v_labour
  from public.invoice_lines where invoice_id = p_invoice;
  v_sub := v_parts + v_labour;
  v_disc := case when inv.discount_state = 'applied' then least(inv.discount_paisa, v_sub) else 0 end;
  v_parts_net := case when v_sub = 0 then 0 else v_parts - v_disc * v_parts::numeric / v_sub end;
  v_labour_net := case when v_sub = 0 then 0 else v_labour - v_disc * v_labour::numeric / v_sub end;
  if st.sales_tax_enabled then
    v_tp := round(v_parts_net * st.parts_tax_pct / 100);
    v_ts := round(v_labour_net * st.services_tax_pct / 100);
  end if;
  update public.invoices set
    parts_paisa = v_parts, labour_paisa = v_labour,
    tax_parts_paisa = v_tp, tax_services_paisa = v_ts,
    total_paisa = private.whole_rupees(v_sub - v_disc + v_tp + v_ts)
  where id = p_invoice;
end;
$$;

-- REQ-043: storage line on a Ready job — days beyond the free days × daily charge.
create or replace function private.apply_storage(p_job uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  j public.job_cards;
  st public.stations;
  v_days integer;
  v_line uuid;
begin
  select * into j from public.job_cards where id = p_job;
  select * into st from public.stations where id = j.station_id;
  if st.storage_charge_paisa = 0 or j.stage <> 'ready' or j.ready_at is null then return; end if;
  v_days := ((now() at time zone 'Asia/Karachi')::date - (j.ready_at at time zone 'Asia/Karachi')::date) - st.storage_free_days;
  select id into v_line from public.job_lines where job_id = p_job and kind = 'fee' and description like 'Storage charge%' and status = 'approved';
  if v_days <= 0 then return; end if;
  if v_line is null then
    insert into public.job_lines (station_id, job_id, kind, description, qty, unit_price_paisa, status)
    values (j.station_id, p_job, 'fee', 'Storage charge (per day)', v_days, st.storage_charge_paisa, 'approved');
    perform private.notify(j.station_id, null, 'storage', format('Storage charge started — job %s', j.job_no),
      format('Vehicle ready for %s days beyond the free period', v_days), p_job);
  else
    update public.job_lines set qty = v_days where id = v_line and qty <> v_days;
  end if;
end;
$$;

-- Copies the job's approved lines into the invoice (only while unlocked) and recomputes.
create or replace function private.refresh_invoice(p_invoice uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare inv public.invoices;
begin
  select * into inv from public.invoices where id = p_invoice;
  if inv.locked then return; end if;
  perform private.apply_storage(inv.job_id);
  delete from public.invoice_lines where invoice_id = p_invoice;
  insert into public.invoice_lines (station_id, invoice_id, job_line_id, kind, item_id, description, qty, unit_price_paisa, total_paisa, warranty_days)
  select l.station_id, p_invoice, l.id, l.kind, l.item_id, l.description, l.qty, l.unit_price_paisa,
         round(l.qty * l.unit_price_paisa)::bigint, l.warranty_days
  from public.job_lines l
  where l.job_id = inv.job_id and l.status = 'approved' and l.kind <> 'customer_part'
  order by l.created_at;
  perform private.recalc_invoice(p_invoice);
end;
$$;

-- Daily scheduler (TASK-044): storage charges and "vehicle ready" reminders to staff.
-- Customer messages arrive with WhatsApp in Phase 7. Safe to run twice.
create or replace function private.daily_ready_jobs()
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  r record;
  n integer := 0;
begin
  for r in select j.id, j.station_id, j.job_no, st.storage_free_days, j.ready_at
           from public.job_cards j join public.stations st on st.id = j.station_id
           where j.stage = 'ready' loop
    perform private.apply_storage(r.id);
    perform private.refresh_invoice(i.id) from public.invoices i where i.job_id = r.id;
    if r.ready_at is not null and r.ready_at < now() - make_interval(days => r.storage_free_days)
       and not exists (select 1 from public.notifications where ref_id = r.id and kind = 'uncollected' and created_at > now() - interval '20 hours') then
      perform private.notify(r.station_id, null, 'uncollected', format('Vehicle not collected — job %s', r.job_no),
        'Ready since ' || to_char(r.ready_at at time zone 'Asia/Karachi', 'DD-MM-YYYY'), r.id);
      n := n + 1;
    end if;
  end loop;
  return n;
end;
$$;
grant execute on all functions in schema private to authenticated, service_role;

-- Runs daily at 09:00 PKT (04:00 UTC) when pg_cron is enabled on the project.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('daily-ready-jobs', '0 4 * * *', 'select private.daily_ready_jobs()');
  end if;
end $$;

-- Public RPCs ------------------------------------------------------------------------
create or replace function public.station_save_service(
  p_station uuid, p_id uuid, p_name text, p_rate_paisa bigint, p_warranty_days integer, p_active boolean default true)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_id uuid := p_id;
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then perform private.fail('FORBIDDEN'); end if;
  perform private.assert_can_write(p_station);
  if length(trim(coalesce(p_name, ''))) < 2 then perform private.fail('VALIDATION', 'Service name is required'); end if;
  if coalesce(p_rate_paisa, -1) < 0 or coalesce(p_warranty_days, -1) < 0 then perform private.fail('VALIDATION', 'Rate and warranty cannot be negative'); end if;
  if v_id is null then
    insert into public.services (station_id, name, rate_paisa, warranty_days) values (p_station, trim(p_name), p_rate_paisa, p_warranty_days)
    returning id into v_id;
  else
    update public.services set name = trim(p_name), rate_paisa = p_rate_paisa, warranty_days = p_warranty_days, active = coalesce(p_active, true)
    where id = v_id and station_id = p_station;
    if not found then perform private.fail('NOT_FOUND'); end if;
  end if;
  return v_id;
end;
$$;

-- REQ-035: a labour line from the service list (rate pre-filled, editable; warranty carried).
create or replace function public.job_add_service(p_job uuid, p_service uuid, p_qty numeric default 1, p_price_paisa bigint default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  sv public.services;
  v_line uuid;
begin
  select * into sv from public.services where id = p_service and active;
  if sv.id is null then perform private.fail('NOT_FOUND', 'Service not found'); end if;
  if not exists (select 1 from public.job_cards where id = p_job and station_id = sv.station_id) then perform private.fail('NOT_FOUND'); end if;
  v_line := private.add_line(p_job, 'labour', null, sv.name, p_qty, coalesce(p_price_paisa, sv.rate_paisa));
  update public.job_lines set service_id = sv.id, warranty_days = sv.warranty_days where id = v_line;
  return v_line;
end;
$$;

create or replace function public.station_set_billing_rules(
  p_station uuid, p_discount_limit_pct numeric, p_storage_free_days integer, p_storage_charge_paisa bigint)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then perform private.fail('FORBIDDEN'); end if;
  perform private.assert_station_open(p_station);
  if p_discount_limit_pct not between 0 and 100 or p_storage_free_days < 0 or p_storage_charge_paisa < 0 then
    perform private.fail('VALIDATION', 'Check the discount limit (0–100 %) and storage values');
  end if;
  update public.stations set discount_limit_pct = p_discount_limit_pct, storage_free_days = p_storage_free_days,
    storage_charge_paisa = p_storage_charge_paisa where id = p_station;
end;
$$;

-- REQ-036: create the invoice from approved lines (one per job card).
create or replace function public.station_create_invoice(p_job uuid)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  j public.job_cards := private.job_for(p_job, array['owner','manager','cashier']::public.member_role[]);
  v_id uuid;
begin
  perform private.assert_can_write(j.station_id);
  select id into v_id from public.invoices where job_id = p_job;
  if v_id is not null then
    perform private.refresh_invoice(v_id);
    return v_id;
  end if;
  if j.stage in ('intake', 'awaiting_approval') then
    perform private.fail('VALIDATION', 'The estimate is not approved yet');
  end if;
  if exists (select 1 from public.job_lines where job_id = p_job and status = 'extra_pending') then
    perform private.fail('VALIDATION', 'Extra work is still waiting for customer approval');
  end if;
  if not exists (select 1 from public.job_lines where job_id = p_job and status = 'approved' and kind <> 'customer_part') then
    perform private.fail('VALIDATION', 'There are no approved lines to bill');
  end if;
  insert into public.invoices (station_id, invoice_no, job_id, customer_id, vehicle_id)
  values (j.station_id, private.next_no(j.station_id, 'invoice'), p_job, j.customer_id, j.vehicle_id)
  returning id into v_id;
  perform private.refresh_invoice(v_id);
  return v_id;
end;
$$;

-- REQ-037: discount within the owner's limit applies at once; above it needs approval
-- (Standard+) or the owner's own login (Basic). Payments wait while it is pending.
create or replace function public.invoice_set_discount(p_invoice uuid, p_amount_paisa bigint, p_reason text default null)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  inv public.invoices;
  v_limit numeric;
  v_sub bigint;
begin
  select * into inv from public.invoices where id = p_invoice;
  if inv.id is null or not private.has_role(inv.station_id, array['owner','manager','cashier']::public.member_role[]) then
    perform private.fail('NOT_FOUND', 'Invoice not found');
  end if;
  perform private.assert_can_write(inv.station_id);
  if inv.locked then perform private.fail('VALIDATION', 'Invoice already has payments — use a credit note'); end if;
  if inv.discount_state = 'pending' then perform private.fail('VALIDATION', 'A discount is already waiting for approval'); end if;
  v_sub := inv.parts_paisa + inv.labour_paisa;
  if coalesce(p_amount_paisa, -1) < 0 or p_amount_paisa > v_sub then
    perform private.fail('VALIDATION', 'Discount must be between 0 and the subtotal');
  end if;
  select discount_limit_pct into v_limit from public.stations where id = inv.station_id;

  if p_amount_paisa = 0 then
    update public.invoices set discount_paisa = 0, discount_state = 'none', discount_reason = null where id = p_invoice;
  elsif p_amount_paisa * 100 <= v_limit * v_sub or private.has_role(inv.station_id, array['owner']::public.member_role[]) then
    update public.invoices set discount_paisa = p_amount_paisa, discount_state = 'applied', discount_reason = nullif(trim(p_reason), '')
    where id = p_invoice;
  else
    perform private.create_approval(inv.station_id, 'discount', 'invoices', p_invoice, p_amount_paisa,
      coalesce(nullif(trim(p_reason), ''), 'Discount above limit'),
      jsonb_build_object('invoice_no', inv.invoice_no, 'subtotal', v_sub, 'limit_pct', v_limit));
    update public.invoices set discount_paisa = p_amount_paisa, discount_state = 'pending', discount_reason = nullif(trim(p_reason), '')
    where id = p_invoice;
  end if;
  perform private.recalc_invoice(p_invoice);
  return (select discount_state::text from public.invoices where id = p_invoice);
end;
$$;

create or replace function public.invoice_refresh(p_invoice uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare inv public.invoices;
begin
  select * into inv from public.invoices where id = p_invoice;
  if inv.id is null or not private.has_role(inv.station_id, array['owner','manager','cashier']::public.member_role[]) then
    perform private.fail('NOT_FOUND', 'Invoice not found');
  end if;
  perform private.assert_can_write(inv.station_id);
  perform private.refresh_invoice(p_invoice);
end;
$$;

revoke execute on function
  public.station_save_service(uuid, uuid, text, bigint, integer, boolean),
  public.job_add_service(uuid, uuid, numeric, bigint),
  public.station_set_billing_rules(uuid, numeric, integer, bigint),
  public.station_create_invoice(uuid),
  public.invoice_set_discount(uuid, bigint, text),
  public.invoice_refresh(uuid)
from public, anon;
grant execute on function
  public.station_save_service(uuid, uuid, text, bigint, integer, boolean),
  public.job_add_service(uuid, uuid, numeric, bigint),
  public.station_set_billing_rules(uuid, numeric, integer, bigint),
  public.station_create_invoice(uuid),
  public.invoice_set_discount(uuid, bigint, text),
  public.invoice_refresh(uuid)
to authenticated;
