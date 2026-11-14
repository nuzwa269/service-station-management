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
