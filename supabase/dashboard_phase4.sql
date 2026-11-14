-- Phase 4 migrations (billing, payments, day closing) for the Supabase dashboard SQL Editor.
-- Run once, AFTER the Phase 1-3 files. Optional: enable the pg_cron extension first (Database > Extensions) so storage charges run daily.

-- ===== supabase/migrations/20261116000014_billing.sql =====
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

-- ===== supabase/migrations/20261116000015_payments.sql =====
-- TASK-041, TASK-042, TASK-043, TASK-045 · REQ-038…042, REQ-044
-- Payments (split, advance, change), handover rule with credit release, customer dues
-- (oldest first), refunds as numbered credit notes, reversals, daily cash closing.
-- Payments are append-only: a wrong entry is reversed with a reason, never edited.

create type public.pay_method as enum ('cash', 'jazzcash', 'easypaisa', 'bank', 'card', 'credit');
create type public.pay_kind as enum ('payment', 'advance', 'refund', 'reversal', 'credit_use');

create table public.payments (
  id            uuid primary key default gen_random_uuid(),
  station_id    uuid not null references public.stations(id) on delete cascade,
  customer_id   uuid not null references public.customers(id),
  invoice_id    uuid references public.invoices(id),
  job_id        uuid references public.job_cards(id),
  kind          public.pay_kind not null,
  method        public.pay_method not null,
  amount_paisa  bigint not null check (amount_paisa <> 0),   -- money in > 0, money out < 0
  reference     text,
  paid_on       date not null,
  reverses_id   uuid references public.payments(id),
  reason        text,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now()
);
create index payments_invoice_idx on public.payments(invoice_id);
create index payments_job_idx on public.payments(job_id);
create index payments_day_idx on public.payments(station_id, paid_on);
create trigger payments_append_only before update or delete on public.payments
  for each row execute function private.append_only();

create table public.credit_notes (
  id            uuid primary key default gen_random_uuid(),
  station_id    uuid not null references public.stations(id) on delete cascade,
  cn_no         integer not null,
  invoice_id    uuid not null references public.invoices(id),
  customer_id   uuid not null references public.customers(id),
  amount_paisa  bigint not null check (amount_paisa > 0),
  mode          text not null check (mode in ('cash', 'credit')),
  reason        text not null,
  approval_id   uuid references public.approval_requests(id),
  created_at    timestamptz not null default now(),
  unique (station_id, cn_no)
);
create trigger credit_notes_append_only before update or delete on public.credit_notes
  for each row execute function private.append_only();

create table public.day_closings (
  station_id      uuid not null references public.stations(id) on delete cascade,
  day             date not null,
  expected        jsonb not null,           -- {method: paisa}
  counted_cash    bigint not null,
  difference      bigint not null,
  note            text,
  closed_by       uuid,
  closed_at       timestamptz,
  reopened_at     timestamptz,
  reopened_by     uuid,
  reopen_reason   text,
  primary key (station_id, day)
);

alter table public.payments     enable row level security;
alter table public.credit_notes enable row level security;
alter table public.day_closings enable row level security;
create policy payments_read on public.payments for select to authenticated
  using (private.has_role(station_id, array['owner','manager','cashier']::public.member_role[]) or private.has_support_grant(station_id));
create policy credit_notes_read on public.credit_notes for select to authenticated
  using (private.has_role(station_id, array['owner','manager','cashier']::public.member_role[]) or private.has_support_grant(station_id));
create policy day_closings_read on public.day_closings for select to authenticated
  using (private.has_role(station_id, array['owner','manager','cashier']::public.member_role[]) or private.has_support_grant(station_id));
revoke insert, update, delete on public.payments, public.credit_notes, public.day_closings from anon, authenticated;

create trigger audit_payments after insert on public.payments for each row execute function private.audit_row();
create trigger audit_credit_notes after insert on public.credit_notes for each row execute function private.audit_row();
create trigger audit_day_closings after insert or update on public.day_closings for each row execute function private.audit_row();

-- Balances ---------------------------------------------------------------------------
-- paid = net money for the invoice (payments, advances on its job, credit used, minus
-- refunds and reversals). due = total − credit notes − paid, never below zero.
create or replace view public.invoice_balances
with (security_invoker = true)
as
with p as (
  select i.id,
         coalesce((select sum(x.amount_paisa) from public.payments x
                   where x.invoice_id = i.id or (x.invoice_id is null and x.job_id = i.job_id)), 0)::bigint as paid,
         coalesce((select sum(c.amount_paisa) from public.credit_notes c where c.invoice_id = i.id), 0)::bigint as credited
  from public.invoices i
)
select i.id as invoice_id, i.station_id, i.invoice_no, i.job_id, i.customer_id, i.issued_at, i.total_paisa,
       p.paid as paid_paisa, p.credited as credited_paisa,
       greatest(i.total_paisa - p.credited - p.paid, 0)::bigint as due_paisa,
       case
         when i.discount_state = 'pending' then 'discount_pending'
         when i.total_paisa - p.credited - p.paid <= 0 then 'paid'
         when i.on_credit then 'on_credit'
         when p.paid > 0 then 'partly_paid'
         else 'unpaid'
       end as status
from public.invoices i join p on p.id = i.id;

-- REQ-040: dues = unpaid amounts of delivered or credit-released invoices; credit = credit notes kept as credit minus credit used.
create or replace view public.customer_balances
with (security_invoker = true)
as
select c.station_id, c.id as customer_id, c.name, c.mobile,
       coalesce((select sum(b.due_paisa) from public.invoice_balances b join public.job_cards j on j.id = b.job_id
                 where b.customer_id = c.id and (b.status = 'on_credit' or j.stage = 'delivered')), 0)::bigint as dues_paisa,
       (coalesce((select sum(n.amount_paisa) from public.credit_notes n where n.customer_id = c.id and n.mode = 'credit'), 0)
        - coalesce((select sum(x.amount_paisa) from public.payments x where x.customer_id = c.id and x.method = 'credit'), 0))::bigint as credit_paisa
from public.customers c;

grant select on public.invoice_balances, public.customer_balances to authenticated;

-- Helpers ----------------------------------------------------------------------------
create or replace function private.invoice_due(p_invoice uuid)
returns bigint
language sql stable security definer set search_path = ''
as $$
  select greatest(i.total_paisa
    - coalesce((select sum(c.amount_paisa) from public.credit_notes c where c.invoice_id = i.id), 0)
    - coalesce((select sum(x.amount_paisa) from public.payments x where x.invoice_id = i.id or (x.invoice_id is null and x.job_id = i.job_id)), 0), 0)::bigint
  from public.invoices i where i.id = p_invoice;
$$;

create or replace function private.customer_credit(p_customer uuid)
returns bigint
language sql stable security definer set search_path = ''
as $$
  select (coalesce((select sum(n.amount_paisa) from public.credit_notes n where n.customer_id = p_customer and n.mode = 'credit'), 0)
        - coalesce((select sum(x.amount_paisa) from public.payments x where x.customer_id = p_customer and x.method = 'credit'), 0))::bigint;
$$;

create or replace function private.assert_day_open(p_station uuid, p_day date)
returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if p_day > (now() at time zone 'Asia/Karachi')::date then
    perform private.fail('VALIDATION', 'Payments cannot be dated in the future');
  end if;
  if exists (select 1 from public.day_closings where station_id = p_station and day = p_day
             and closed_at is not null and reopened_at is null) then
    perform private.fail('DAY_CLOSED', format('%s is closed — ask the owner to reopen it', to_char(p_day, 'DD-MM-YYYY')));
  end if;
end;
$$;

create or replace function private.today_pk()
returns date
language sql stable
as $$ select (now() at time zone 'Asia/Karachi')::date; $$;

grant execute on all functions in schema private to authenticated, service_role;

-- REQ-038 payments --------------------------------------------------------------------
create or replace function public.invoice_record_payment(
  p_invoice uuid, p_amount_paisa bigint, p_method public.pay_method, p_reference text default null, p_paid_on date default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  inv public.invoices;
  v_day date := coalesce(p_paid_on, private.today_pk());
  v_id uuid;
begin
  select * into inv from public.invoices where id = p_invoice;
  if inv.id is null or not private.has_role(inv.station_id, array['owner','manager','cashier']::public.member_role[]) then
    perform private.fail('NOT_FOUND', 'Invoice not found');
  end if;
  perform private.assert_can_write(inv.station_id);
  if inv.discount_state = 'pending' then perform private.fail('VALIDATION', 'Discount awaiting approval — the invoice cannot be finalised yet'); end if;
  if p_method = 'credit' then perform private.fail('VALIDATION', 'Use customer credit with "Use credit"'); end if;
  if p_method <> 'cash' and length(trim(coalesce(p_reference, ''))) < 2 then
    perform private.fail('VALIDATION', 'Reference number is required for non-cash payments');
  end if;
  if coalesce(p_amount_paisa, 0) <= 0 then perform private.fail('VALIDATION', 'Amount must be above 0'); end if;
  perform private.assert_day_open(inv.station_id, v_day);
  perform private.refresh_invoice(p_invoice);   -- last chance for storage days before locking
  if p_amount_paisa > private.invoice_due(p_invoice) then
    perform private.fail('VALIDATION', format('Amount is more than the due (Rs %s)', to_char(private.invoice_due(p_invoice) / 100, 'FM999,999,999')));
  end if;
  insert into public.payments (station_id, customer_id, invoice_id, job_id, kind, method, amount_paisa, reference, paid_on)
  values (inv.station_id, inv.customer_id, p_invoice, inv.job_id, 'payment', p_method, p_amount_paisa, nullif(trim(p_reference), ''), v_day)
  returning id into v_id;
  update public.invoices set locked = true where id = p_invoice and not locked;
  return v_id;
end;
$$;

-- Advance on a job card before the invoice; it is counted on the invoice later.
create or replace function public.job_record_advance(
  p_job uuid, p_amount_paisa bigint, p_method public.pay_method, p_reference text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  j public.job_cards := private.job_for(p_job, array['owner','manager','cashier']::public.member_role[]);
  v_id uuid;
begin
  perform private.assert_can_write(j.station_id);
  if exists (select 1 from public.invoices where job_id = p_job) then perform private.fail('VALIDATION', 'Invoice exists — record a payment on it'); end if;
  if j.stage in ('delivered', 'cancelled') then perform private.fail('VALIDATION', 'This job card is closed'); end if;
  if p_method = 'credit' or coalesce(p_amount_paisa, 0) <= 0 then perform private.fail('VALIDATION', 'Enter an amount and a payment method'); end if;
  if p_method <> 'cash' and length(trim(coalesce(p_reference, ''))) < 2 then
    perform private.fail('VALIDATION', 'Reference number is required for non-cash payments');
  end if;
  perform private.assert_day_open(j.station_id, private.today_pk());
  insert into public.payments (station_id, customer_id, job_id, kind, method, amount_paisa, reference, paid_on)
  values (j.station_id, j.customer_id, p_job, 'advance', p_method, p_amount_paisa, nullif(trim(p_reference), ''), private.today_pk())
  returning id into v_id;
  return v_id;
end;
$$;

-- Pay from the customer's credit balance (credit notes kept as credit).
create or replace function public.invoice_use_credit(p_invoice uuid, p_amount_paisa bigint)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  inv public.invoices;
  v_id uuid;
begin
  select * into inv from public.invoices where id = p_invoice;
  if inv.id is null or not private.has_role(inv.station_id, array['owner','manager','cashier']::public.member_role[]) then
    perform private.fail('NOT_FOUND', 'Invoice not found');
  end if;
  perform private.assert_can_write(inv.station_id);
  if inv.discount_state = 'pending' then perform private.fail('VALIDATION', 'Discount awaiting approval'); end if;
  if coalesce(p_amount_paisa, 0) <= 0 or p_amount_paisa > private.customer_credit(inv.customer_id)
     or p_amount_paisa > private.invoice_due(p_invoice) then
    perform private.fail('VALIDATION', 'Amount is more than the credit or the due');
  end if;
  insert into public.payments (station_id, customer_id, invoice_id, job_id, kind, method, amount_paisa, paid_on, reason)
  values (inv.station_id, inv.customer_id, p_invoice, inv.job_id, 'credit_use', 'credit', p_amount_paisa, private.today_pk(), 'Customer credit used')
  returning id into v_id;
  update public.invoices set locked = true where id = p_invoice and not locked;
  return v_id;
end;
$$;

-- REQ-042: reverse a payment with a reason (OW/MG). Original stays visible.
create or replace function public.payment_reverse(p_payment uuid, p_reason text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  p public.payments;
  v_day date;
  v_id uuid;
begin
  select * into p from public.payments where id = p_payment;
  if p.id is null or not private.has_role(p.station_id, array['owner','manager']::public.member_role[]) then
    perform private.fail('NOT_FOUND', 'Payment not found');
  end if;
  perform private.assert_can_write(p.station_id);
  if p.kind not in ('payment', 'advance', 'credit_use') then perform private.fail('VALIDATION', 'Only payments can be reversed'); end if;
  if exists (select 1 from public.payments where reverses_id = p_payment) then perform private.fail('VALIDATION', 'Already reversed'); end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then perform private.fail('VALIDATION', 'A reason is required'); end if;
  -- Same day if it is still open, otherwise today.
  v_day := case when exists (select 1 from public.day_closings where station_id = p.station_id and day = p.paid_on
                             and closed_at is not null and reopened_at is null) then private.today_pk() else p.paid_on end;
  perform private.assert_day_open(p.station_id, v_day);
  insert into public.payments (station_id, customer_id, invoice_id, job_id, kind, method, amount_paisa, reference, paid_on, reverses_id, reason)
  values (p.station_id, p.customer_id, p.invoice_id, p.job_id, 'reversal', p.method, -p.amount_paisa, p.reference, v_day, p_payment, trim(p_reason))
  returning id into v_id;
  return v_id;
end;
$$;

-- REQ-039 credit release ---------------------------------------------------------------
create or replace function public.invoice_request_credit(p_invoice uuid, p_reason text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  inv public.invoices;
  v_due bigint;
begin
  select * into inv from public.invoices where id = p_invoice;
  if inv.id is null or not private.has_role(inv.station_id, array['owner','manager','cashier']::public.member_role[]) then
    perform private.fail('NOT_FOUND', 'Invoice not found');
  end if;
  perform private.assert_can_write(inv.station_id);
  if inv.on_credit then return 'approved'; end if;
  v_due := private.invoice_due(p_invoice);
  if v_due = 0 then perform private.fail('VALIDATION', 'Nothing is due'); end if;
  if private.has_role(inv.station_id, array['owner']::public.member_role[]) then
    insert into public.approval_requests (station_id, type, status, record_table, record_id, amount_paisa, reason, decided_by, decided_at, decision_note)
    values (inv.station_id, 'credit_release', 'approved', 'invoices', p_invoice, v_due, coalesce(nullif(trim(p_reason), ''), 'Credit release'),
            auth.uid(), now(), 'Owner decision');
    update public.invoices set on_credit = true where id = p_invoice;
    return 'approved';
  end if;
  if exists (select 1 from public.approval_requests where record_id = p_invoice and type = 'credit_release' and status = 'pending') then
    return 'pending';
  end if;
  perform private.create_approval(inv.station_id, 'credit_release', 'invoices', p_invoice, v_due,
    coalesce(nullif(trim(p_reason), ''), 'Customer cannot pay in full'), jsonb_build_object('invoice_no', inv.invoice_no));
  return 'pending';
end;
$$;

-- REQ-040: collect dues, oldest invoice first.
create or replace function public.customer_collect_dues(
  p_customer uuid, p_amount_paisa bigint, p_method public.pay_method, p_reference text default null)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  c public.customers;
  v_left bigint := p_amount_paisa;
  v_take bigint;
  r record;
  n integer := 0;
begin
  select * into c from public.customers where id = p_customer;
  if c.id is null or not private.has_role(c.station_id, array['owner','manager','cashier']::public.member_role[]) then
    perform private.fail('NOT_FOUND', 'Customer not found');
  end if;
  perform private.assert_can_write(c.station_id);
  if p_method = 'credit' or coalesce(p_amount_paisa, 0) <= 0 then perform private.fail('VALIDATION', 'Enter an amount and a payment method'); end if;
  if p_method <> 'cash' and length(trim(coalesce(p_reference, ''))) < 2 then
    perform private.fail('VALIDATION', 'Reference number is required for non-cash payments');
  end if;
  perform private.assert_day_open(c.station_id, private.today_pk());
  if p_amount_paisa > (select dues_paisa from public.customer_balances where customer_id = p_customer) then
    perform private.fail('VALIDATION', 'Amount is more than the dues');
  end if;
  for r in select b.invoice_id, b.due_paisa, b.job_id from public.invoice_balances b join public.job_cards j on j.id = b.job_id
           where b.customer_id = p_customer and b.due_paisa > 0 and (b.status = 'on_credit' or j.stage = 'delivered')
           order by b.issued_at, b.invoice_no loop
    exit when v_left <= 0;
    v_take := least(v_left, r.due_paisa);
    insert into public.payments (station_id, customer_id, invoice_id, job_id, kind, method, amount_paisa, reference, paid_on, reason)
    values (c.station_id, p_customer, r.invoice_id, r.job_id, 'payment', p_method, v_take, nullif(trim(p_reference), ''), private.today_pk(), 'Dues collection');
    update public.invoices set locked = true where id = r.invoice_id and not locked;
    v_left := v_left - v_take;
    n := n + 1;
  end loop;
  return n;
end;
$$;

-- REQ-041 refunds -----------------------------------------------------------------------
-- p_returns: [{invoice_line_id, qty}] unused new parts coming back to stock.
create or replace function public.invoice_request_refund(
  p_invoice uuid, p_amount_paisa bigint, p_mode text, p_reason text, p_returns jsonb default '[]'::jsonb)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  inv public.invoices;
  v_paid bigint;
  v_credited bigint;
  r public.approval_requests;
begin
  select * into inv from public.invoices where id = p_invoice;
  if inv.id is null or not private.has_role(inv.station_id, array['owner','manager','cashier']::public.member_role[]) then
    perform private.fail('NOT_FOUND', 'Invoice not found');
  end if;
  perform private.assert_can_write(inv.station_id);
  if p_mode not in ('cash', 'credit') then perform private.fail('VALIDATION', 'Refund as cash or as customer credit'); end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then perform private.fail('VALIDATION', 'A reason is required'); end if;
  select coalesce(sum(amount_paisa), 0) into v_paid from public.payments where invoice_id = p_invoice or (invoice_id is null and job_id = inv.job_id);
  select coalesce(sum(amount_paisa), 0) into v_credited from public.credit_notes where invoice_id = p_invoice;
  if v_paid <= 0 then perform private.fail('VALIDATION', 'Refunds are for paid invoices'); end if;
  if coalesce(p_amount_paisa, 0) <= 0 or p_amount_paisa > least(v_paid, inv.total_paisa - v_credited) then
    perform private.fail('VALIDATION', 'Refund is more than what was paid');
  end if;

  if private.has_role(inv.station_id, array['owner']::public.member_role[]) then
    insert into public.approval_requests (station_id, type, status, record_table, record_id, amount_paisa, reason, payload, decided_by, decided_at, decision_note)
    values (inv.station_id, 'refund', 'approved', 'invoices', p_invoice, p_amount_paisa, trim(p_reason),
            jsonb_build_object('mode', p_mode, 'returns', coalesce(p_returns, '[]'::jsonb), 'invoice_no', inv.invoice_no),
            auth.uid(), now(), 'Owner decision')
    returning * into r;
    perform private.apply_approval(r);
    return 'approved';
  end if;
  perform private.create_approval(inv.station_id, 'refund', 'invoices', p_invoice, p_amount_paisa, p_reason,
    jsonb_build_object('mode', p_mode, 'returns', coalesce(p_returns, '[]'::jsonb), 'invoice_no', inv.invoice_no));
  return 'pending';
end;
$$;

-- Approvals: what happens on approve / reject for each type --------------------------------
create or replace function private.apply_approval(r public.approval_requests)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  inv public.invoices;
  rt jsonb;
  il public.invoice_lines;
  v_qty numeric;
begin
  if r.type = 'stock_adjustment' then
    perform private.move_stock(r.station_id, (r.payload ->> 'item_id')::uuid, (r.payload ->> 'qty')::numeric, 'adjustment', r.id, null, r.reason);
  elsif r.type = 'discount' then
    update public.invoices set discount_state = 'applied' where id = r.record_id and discount_state = 'pending';
    perform private.recalc_invoice(r.record_id);
  elsif r.type = 'credit_release' then
    update public.invoices set on_credit = true where id = r.record_id;
  elsif r.type = 'refund' then
    select * into inv from public.invoices where id = r.record_id;
    insert into public.credit_notes (station_id, cn_no, invoice_id, customer_id, amount_paisa, mode, reason, approval_id)
    values (inv.station_id, private.next_no(inv.station_id, 'credit_note'), inv.id, inv.customer_id, r.amount_paisa,
            r.payload ->> 'mode', r.reason, r.id);
    if r.payload ->> 'mode' = 'cash' then
      perform private.assert_day_open(inv.station_id, private.today_pk());
      insert into public.payments (station_id, customer_id, invoice_id, job_id, kind, method, amount_paisa, paid_on, reason)
      values (inv.station_id, inv.customer_id, inv.id, inv.job_id, 'refund', 'cash', -r.amount_paisa, private.today_pk(), r.reason);
    end if;
    for rt in select * from jsonb_array_elements(coalesce(r.payload -> 'returns', '[]'::jsonb)) loop
      select * into il from public.invoice_lines where id = (rt ->> 'invoice_line_id')::uuid and invoice_id = inv.id;
      v_qty := (rt ->> 'qty')::numeric;
      if il.id is null or il.kind <> 'part' or v_qty <= 0 or il.returned_qty + v_qty > il.qty then
        perform private.fail('VALIDATION', 'Returned quantity is not valid');
      end if;
      perform private.move_stock(inv.station_id, il.item_id, v_qty, 'job_return', inv.job_id, null, 'Refund ' || r.reason);
      update public.invoice_lines set returned_qty = returned_qty + v_qty where id = il.id;
    end loop;
  end if;
end;
$$;

create or replace function private.reject_approval(r public.approval_requests)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if r.type = 'discount' then
    update public.invoices set discount_state = 'rejected' where id = r.record_id and discount_state = 'pending';
    perform private.recalc_invoice(r.record_id);
  end if;
end;
$$;
grant execute on all functions in schema private to authenticated, service_role;

create or replace function public.station_decide_approval(p_request uuid, p_approve boolean, p_note text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare r public.approval_requests;
begin
  select * into r from public.approval_requests where id = p_request for update;
  if r.id is null or not private.can_approve(r.station_id) then perform private.fail('NOT_FOUND'); end if;
  perform private.assert_can_write(r.station_id);
  if r.status <> 'pending' then perform private.fail('VALIDATION', 'This request was already decided'); end if;
  if r.requested_by = auth.uid() then perform private.fail('VALIDATION', 'You cannot decide your own request'); end if;
  update public.approval_requests
     set status = case when p_approve then 'approved'::public.approval_status else 'rejected'::public.approval_status end,
         decided_by = auth.uid(), decided_at = now(), decision_note = nullif(trim(p_note), '')
   where id = p_request
  returning * into r;
  if p_approve then perform private.apply_approval(r); else perform private.reject_approval(r); end if;
end;
$$;

-- REQ-039: Delivered only when the invoice is paid or credit is released.
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
  v_inv public.invoices;
  v_due bigint;
begin
  perform private.assert_can_write(j.station_id);
  if j.stage = p_stage then return; end if;
  v_ok := case
    when j.stage = 'approved'      and p_stage = 'in_progress'   then true
    when j.stage = 'quality_check' and p_stage = 'in_progress'   then true
    when j.stage = 'in_progress'   and p_stage = 'quality_check' then true
    when j.stage = 'ready'         and p_stage = 'delivered'     then v_staff
    else false end;
  if not v_ok then perform private.fail('VALIDATION', format('Cannot move from %s to %s', j.stage, p_stage)); end if;
  if p_stage = 'quality_check' and exists (select 1 from public.job_checklist_items where job_id = p_job and status = 'not_checked') then
    perform private.fail('VALIDATION', 'Finish the checklist before quality check');
  end if;
  if p_stage = 'delivered' then
    if exists (select 1 from public.job_lines where job_id = p_job and status = 'extra_pending') then
      perform private.fail('VALIDATION', 'Extra work is still waiting for customer approval');
    end if;
    select * into v_inv from public.invoices where job_id = p_job;
    if v_inv.id is null then perform private.fail('VALIDATION', 'Create the invoice before delivery'); end if;
    perform private.refresh_invoice(v_inv.id);
    v_due := private.invoice_due(v_inv.id);
    if v_due > 0 and not (select on_credit from public.invoices where id = v_inv.id) then
      perform private.fail('PAYMENT_DUE', format('Collect Rs %s or request credit approval', to_char(v_due / 100, 'FM999,999,999')));
    end if;
  end if;
  update public.job_cards set stage = p_stage, updated_at = now(),
    started_at = case when p_stage = 'in_progress' then coalesce(started_at, now()) else started_at end,
    delivered_at = case when p_stage = 'delivered' then now() else delivered_at end
  where id = p_job;
  perform private.log_job(j.station_id, p_job, 'stage', j.stage::text, p_stage::text, p_note, p_client_time, p_source);
end;
$$;
grant execute on all functions in schema private to authenticated, service_role;

-- REQ-044 day closing ---------------------------------------------------------------------
create or replace function public.station_day_summary(p_station uuid, p_day date default null)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_day date := coalesce(p_day, private.today_pk());
  d public.day_closings;
begin
  if not private.has_role(p_station, array['owner','manager','cashier']::public.member_role[]) then perform private.fail('FORBIDDEN'); end if;
  select * into d from public.day_closings where station_id = p_station and day = v_day;
  return jsonb_build_object(
    'day', v_day,
    'expected', coalesce((select jsonb_object_agg(method, total) from (
        select method::text, sum(amount_paisa) as total from public.payments
        where station_id = p_station and paid_on = v_day and method <> 'credit' group by method) t), '{}'::jsonb),
    'count', (select count(*) from public.payments where station_id = p_station and paid_on = v_day and method <> 'credit'),
    'closed', d.closed_at is not null and d.reopened_at is null,
    'closing', case when d.station_id is null then null else to_jsonb(d) end);
end;
$$;

create or replace function public.station_close_day(p_station uuid, p_day date, p_counted_cash_paisa bigint, p_note text default null)
returns bigint
language plpgsql security definer set search_path = ''
as $$
declare
  v_expected jsonb;
  v_cash bigint;
  v_diff bigint;
begin
  if not private.has_role(p_station, array['owner','manager','cashier']::public.member_role[]) then perform private.fail('FORBIDDEN'); end if;
  perform private.assert_can_write(p_station);
  if p_day > private.today_pk() then perform private.fail('VALIDATION', 'A future day cannot be closed'); end if;
  perform private.assert_day_open(p_station, p_day);
  v_expected := public.station_day_summary(p_station, p_day) -> 'expected';
  v_cash := coalesce((v_expected ->> 'cash')::bigint, 0);
  v_diff := coalesce(p_counted_cash_paisa, -1) - v_cash;
  if p_counted_cash_paisa is null or p_counted_cash_paisa < 0 then perform private.fail('VALIDATION', 'Enter the counted cash'); end if;
  if v_diff <> 0 and length(trim(coalesce(p_note, ''))) < 3 then
    perform private.fail('VALIDATION', format('Difference of Rs %s — add a note', to_char(v_diff / 100, 'FMS999,999,999')));
  end if;
  insert into public.day_closings (station_id, day, expected, counted_cash, difference, note, closed_by, closed_at)
  values (p_station, p_day, v_expected, p_counted_cash_paisa, v_diff, nullif(trim(p_note), ''), auth.uid(), now())
  on conflict (station_id, day) do update set expected = excluded.expected, counted_cash = excluded.counted_cash,
    difference = excluded.difference, note = excluded.note, closed_by = excluded.closed_by, closed_at = excluded.closed_at,
    reopened_at = null, reopened_by = null;
  return v_diff;
end;
$$;

create or replace function public.station_reopen_day(p_station uuid, p_day date, p_reason text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then perform private.fail('FORBIDDEN', 'Only the owner can reopen a day'); end if;
  perform private.assert_can_write(p_station);
  if length(trim(coalesce(p_reason, ''))) < 3 then perform private.fail('VALIDATION', 'A reason is required'); end if;
  update public.day_closings set reopened_at = now(), reopened_by = auth.uid(), reopen_reason = trim(p_reason)
  where station_id = p_station and day = p_day and closed_at is not null and reopened_at is null;
  if not found then perform private.fail('VALIDATION', 'That day is not closed'); end if;
end;
$$;

revoke execute on function
  public.invoice_record_payment(uuid, bigint, public.pay_method, text, date),
  public.job_record_advance(uuid, bigint, public.pay_method, text),
  public.invoice_use_credit(uuid, bigint),
  public.payment_reverse(uuid, text),
  public.invoice_request_credit(uuid, text),
  public.customer_collect_dues(uuid, bigint, public.pay_method, text),
  public.invoice_request_refund(uuid, bigint, text, text, jsonb),
  public.station_day_summary(uuid, date),
  public.station_close_day(uuid, date, bigint, text),
  public.station_reopen_day(uuid, date, text)
from public, anon;
grant execute on function
  public.invoice_record_payment(uuid, bigint, public.pay_method, text, date),
  public.job_record_advance(uuid, bigint, public.pay_method, text),
  public.invoice_use_credit(uuid, bigint),
  public.payment_reverse(uuid, text),
  public.invoice_request_credit(uuid, text),
  public.customer_collect_dues(uuid, bigint, public.pay_method, text),
  public.invoice_request_refund(uuid, bigint, text, text, jsonb),
  public.station_day_summary(uuid, date),
  public.station_close_day(uuid, date, bigint, text),
  public.station_reopen_day(uuid, date, text)
to authenticated;
