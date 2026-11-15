-- Phase 8 migration (staff records, attendance, advances, payroll with commission, reports,
-- mechanic performance, dashboard totals) for the Supabase dashboard SQL Editor.
-- Run once, AFTER the Phase 1-7 files.

-- ===== supabase/migrations/20261120000021_staff_reports.sql =====
-- TASK-063…067 · REQ-050…054, REQ-059, REQ-060
-- Staff records, daily attendance, salary advances, monthly payroll with commission,
-- mechanic performance, reports (date range) and dashboard totals.
-- Staff, attendance, advances and payroll are Premium ("payroll" feature).

create type public.attendance_status as enum ('present', 'absent', 'half_day', 'leave', 'off');

-- REQ-050: staff records (with or without an app login).
create table public.staff (
  id                 uuid primary key default gen_random_uuid(),
  station_id         uuid not null references public.stations(id) on delete cascade,
  user_id            uuid references public.profiles(id),          -- app login, if any
  name               text not null check (length(trim(name)) between 2 and 120),
  mobile             text check (mobile is null or mobile ~ '^03[0-9]{9}$'),
  role               text not null check (role in ('owner', 'manager', 'cashier', 'mechanic', 'helper', 'other')),
  salary_paisa       bigint not null default 0 check (salary_paisa >= 0),
  commission_pct     numeric(5,2) not null default 0 check (commission_pct between 0 and 100),
  joined_on          date not null default private.today_pk(),
  left_on            date,
  active             boolean not null default true,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (station_id, user_id)
);

-- REQ-051: one row per staff member per day; no row = present (PROPOSED default).
create table public.attendance (
  station_id uuid not null references public.stations(id) on delete cascade,
  staff_id   uuid not null references public.staff(id) on delete cascade,
  day        date not null,
  status     public.attendance_status not null,
  note       text,
  updated_by uuid default auth.uid(),
  updated_at timestamptz not null default now(),
  primary key (staff_id, day)
);
create index attendance_station_day_idx on public.attendance(station_id, day);

-- REQ-052: advances; deducted in the payroll of the month they are given, or split
-- over p_months months starting that month (PROPOSED).
create table public.salary_advances (
  id           uuid primary key default gen_random_uuid(),
  station_id   uuid not null references public.stations(id) on delete cascade,
  staff_id     uuid not null references public.staff(id) on delete cascade,
  given_on     date not null,
  amount_paisa bigint not null check (amount_paisa > 0),
  method       public.pay_method not null default 'cash' check (method <> 'credit'),
  months       integer not null default 1 check (months between 1 and 12),
  note         text,
  created_by   uuid default auth.uid(),
  created_at   timestamptz not null default now()
);
create trigger salary_advances_append_only before update or delete on public.salary_advances
  for each row execute function private.append_only();

-- REQ-053: monthly sheet; finalising locks it.
create table public.payroll_runs (
  id           uuid primary key default gen_random_uuid(),
  station_id   uuid not null references public.stations(id) on delete cascade,
  month        date not null check (extract(day from month) = 1),
  status       text not null default 'draft' check (status in ('draft', 'final')),
  finalized_by uuid,
  finalized_at timestamptz,
  created_at   timestamptz not null default now(),
  unique (station_id, month)
);
create table public.payroll_lines (
  id               uuid primary key default gen_random_uuid(),
  run_id           uuid not null references public.payroll_runs(id) on delete cascade,
  station_id       uuid not null references public.stations(id) on delete cascade,
  staff_id         uuid not null references public.staff(id),
  days_in_month    integer not null,
  paid_days        numeric(5,1) not null,
  monthly_paisa    bigint not null,
  salary_paisa     bigint not null,
  labour_paisa     bigint not null default 0,
  commission_pct   numeric(5,2) not null default 0,
  commission_paisa bigint not null default 0,
  advances_paisa   bigint not null default 0,
  adjustment_paisa bigint not null default 0,
  adjustment_note  text,
  net_paisa        bigint not null,
  unique (run_id, staff_id)
);

alter table public.staff           enable row level security;
alter table public.attendance      enable row level security;
alter table public.salary_advances enable row level security;
alter table public.payroll_runs    enable row level security;
alter table public.payroll_lines   enable row level security;

-- Staff and attendance: owner and manager; salary, advances and payroll: owner only (REQ-050).
create policy staff_read on public.staff for select to authenticated
  using (private.has_role(station_id, array['owner','manager']::public.member_role[]) or private.has_support_grant(station_id));
create policy attendance_read on public.attendance for select to authenticated
  using (private.has_role(station_id, array['owner','manager']::public.member_role[]) or private.has_support_grant(station_id));
create policy salary_advances_read on public.salary_advances for select to authenticated
  using (private.has_role(station_id, array['owner']::public.member_role[]) or private.has_support_grant(station_id));
create policy payroll_runs_read on public.payroll_runs for select to authenticated
  using (private.has_role(station_id, array['owner']::public.member_role[]) or private.has_support_grant(station_id));
create policy payroll_lines_read on public.payroll_lines for select to authenticated
  using (private.has_role(station_id, array['owner']::public.member_role[]) or private.has_support_grant(station_id));
revoke insert, update, delete on public.staff, public.attendance, public.salary_advances, public.payroll_runs, public.payroll_lines
  from anon, authenticated;
-- Managers see staff names and roles but not pay (column privileges on top of RLS).
revoke select on public.staff from authenticated;
grant select (id, station_id, user_id, name, mobile, role, joined_on, left_on, active, created_at, updated_at) on public.staff to authenticated;

create trigger audit_staff after insert or update on public.staff for each row execute function private.audit_row();
create trigger audit_attendance after insert or update on public.attendance for each row execute function private.audit_row();
create trigger audit_salary_advances after insert on public.salary_advances for each row execute function private.audit_row();
create trigger audit_payroll_runs after insert or update on public.payroll_runs for each row execute function private.audit_row();
create trigger audit_payroll_lines after update on public.payroll_lines for each row execute function private.audit_row();

-- Staff functions -------------------------------------------------------------------------
-- REQ-050 (owner). p: {id?, user_id?, name, mobile?, role, salary_paisa, commission_pct, joined_on?, active?}
create or replace function public.station_save_staff(p_station uuid, p jsonb)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_id uuid := nullif(p ->> 'id', '')::uuid;
  v_mobile text := nullif(trim(coalesce(p ->> 'mobile', '')), '');
  v_pct numeric := coalesce((p ->> 'commission_pct')::numeric, 0);
  v_salary bigint := coalesce((p ->> 'salary_paisa')::bigint, 0);
  v_user uuid := nullif(p ->> 'user_id', '')::uuid;
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then perform private.fail('FORBIDDEN'); end if;
  perform private.assert_can_write(p_station, 'payroll');
  if length(trim(coalesce(p ->> 'name', ''))) < 2 then perform private.fail('VALIDATION', 'Name is required'); end if;
  if v_mobile is not null then
    v_mobile := private.normalize_pk_mobile(v_mobile);
    if v_mobile is null then perform private.fail('VALIDATION', 'Mobile must be like 0300-1234567'); end if;
  end if;
  if v_pct < 0 or v_pct > 100 then perform private.fail('VALIDATION', 'Commission must be 0–100%'); end if;
  if v_salary < 0 then perform private.fail('VALIDATION', 'Salary cannot be negative'); end if;
  if v_user is not null and not exists (select 1 from public.station_members where station_id = p_station and user_id = v_user) then
    perform private.fail('VALIDATION', 'That login is not a member of this station');
  end if;
  if v_id is null then
    insert into public.staff (station_id, user_id, name, mobile, role, salary_paisa, commission_pct, joined_on)
    values (p_station, v_user, trim(p ->> 'name'), v_mobile, coalesce(p ->> 'role', 'other'), v_salary, v_pct,
            coalesce((p ->> 'joined_on')::date, private.today_pk()))
    returning id into v_id;
  else
    update public.staff set user_id = v_user, name = trim(p ->> 'name'), mobile = v_mobile, role = coalesce(p ->> 'role', role),
      salary_paisa = v_salary, commission_pct = v_pct, joined_on = coalesce((p ->> 'joined_on')::date, joined_on),
      active = coalesce((p ->> 'active')::boolean, active),
      left_on = case when coalesce((p ->> 'active')::boolean, active) then null else coalesce(left_on, private.today_pk()) end,
      updated_at = now()
    where id = v_id and station_id = p_station;
    if not found then perform private.fail('NOT_FOUND'); end if;
  end if;
  return v_id;
end;
$$;

-- Salary details for the owner (managers can't read the pay columns).
create or replace function public.station_staff_pay(p_station uuid)
returns table (staff_id uuid, salary_paisa bigint, commission_pct numeric)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) and not private.has_support_grant(p_station) then
    perform private.fail('FORBIDDEN');
  end if;
  return query select s.id, s.salary_paisa, s.commission_pct from public.staff s where s.station_id = p_station;
end;
$$;

-- REQ-051: manager edits today only; owner any day (logged by the audit trigger).
create or replace function public.station_set_attendance(p_staff uuid, p_day date, p_status public.attendance_status, p_note text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare s public.staff;
begin
  select * into s from public.staff where id = p_staff;
  if s.id is null or not private.has_role(s.station_id, array['owner','manager']::public.member_role[]) then
    perform private.fail('NOT_FOUND');
  end if;
  perform private.assert_can_write(s.station_id, 'payroll');
  if p_day > private.today_pk() then perform private.fail('VALIDATION', 'Attendance cannot be set for a future day'); end if;
  if p_day <> private.today_pk() and not private.has_role(s.station_id, array['owner']::public.member_role[]) then
    perform private.fail('FORBIDDEN', 'Only the owner can change attendance of another day');
  end if;
  if exists (select 1 from public.payroll_runs where station_id = s.station_id and month = date_trunc('month', p_day)::date and status = 'final') then
    perform private.fail('VALIDATION', 'Payroll for this month is final');
  end if;
  insert into public.attendance (station_id, staff_id, day, status, note)
  values (s.station_id, p_staff, p_day, p_status, nullif(trim(p_note), ''))
  on conflict (staff_id, day) do update set status = excluded.status, note = excluded.note, updated_by = auth.uid(), updated_at = now();
end;
$$;

-- REQ-052 (owner).
create or replace function public.station_add_advance(
  p_staff uuid, p_amount_paisa bigint, p_method public.pay_method default 'cash', p_given_on date default null,
  p_months integer default 1, p_note text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare s public.staff; v_id uuid; v_day date := coalesce(p_given_on, private.today_pk());
begin
  select * into s from public.staff where id = p_staff;
  if s.id is null or not private.has_role(s.station_id, array['owner']::public.member_role[]) then perform private.fail('NOT_FOUND'); end if;
  perform private.assert_can_write(s.station_id, 'payroll');
  if coalesce(p_amount_paisa, 0) <= 0 then perform private.fail('VALIDATION', 'Amount must be more than 0'); end if;
  if p_method = 'credit' then perform private.fail('VALIDATION', 'Pick how the advance was paid'); end if;
  if coalesce(p_months, 1) not between 1 and 12 then perform private.fail('VALIDATION', 'Split over 1 to 12 months'); end if;
  if exists (select 1 from public.payroll_runs where station_id = s.station_id and month = date_trunc('month', v_day)::date and status = 'final') then
    perform private.fail('VALIDATION', 'Payroll for this month is final; date the advance next month');
  end if;
  insert into public.salary_advances (station_id, staff_id, given_on, amount_paisa, method, months, note)
  values (s.station_id, p_staff, v_day, p_amount_paisa, p_method, coalesce(p_months, 1), nullif(trim(p_note), ''))
  returning id into v_id;
  return v_id;
end;
$$;

-- Payroll ------------------------------------------------------------------------------------
-- Labour on invoices fully paid in [from, to], after a share of the invoice discount, split
-- equally between the job's mechanics (REQ-053). Rework labour is 0 so it earns nothing.
create or replace function private.paid_labour_by_user(p_station uuid, p_from date, p_to date)
returns table (user_id uuid, labour_paisa bigint)
language sql stable security definer set search_path = ''
as $$
  with paid as (
    select b.invoice_id, b.job_id
    from public.invoice_balances b
    where b.station_id = p_station and b.status = 'paid'
      and (select max(x.paid_on) from public.payments x
           where x.invoice_id = b.invoice_id or (x.invoice_id is null and x.job_id = b.job_id)) between p_from and p_to
  ), lab as (
    select p.invoice_id, p.job_id,
           (select coalesce(sum(l.total_paisa), 0) from public.invoice_lines l where l.invoice_id = p.invoice_id and l.kind = 'labour') as labour,
           i.parts_paisa + i.labour_paisa as gross,
           case when i.discount_state = 'applied' then i.discount_paisa else 0 end as disc
    from paid p join public.invoices i on i.id = p.invoice_id
  ), net as (
    select job_id, (labour - case when gross > 0 then round(disc::numeric * labour / gross) else 0 end)::bigint as labour
    from lab
  ), mech as (
    select n.job_id, n.labour, a.user_id, count(*) over (partition by n.job_id) as n_mech
    from net n join public.job_assignments a on a.job_id = n.job_id
  )
  select m.user_id, coalesce(round(sum(m.labour::numeric / m.n_mech)), 0)::bigint from mech m group by m.user_id;
$$;

-- REQ-053: (re)builds the month's draft sheet. Adjustments already entered are kept.
create or replace function public.payroll_generate(p_station uuid, p_month date)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_month date := date_trunc('month', p_month)::date;
  v_end date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
  v_days integer := extract(day from (date_trunc('month', p_month) + interval '1 month - 1 day'))::int;
  v_run public.payroll_runs;
  s record;
  v_from date; v_to date; v_paid numeric; v_salary bigint; v_lab bigint; v_comm bigint; v_adv bigint; v_adj bigint; v_note text;
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then perform private.fail('FORBIDDEN'); end if;
  perform private.assert_can_write(p_station, 'payroll');
  if v_month > date_trunc('month', private.today_pk())::date then perform private.fail('VALIDATION', 'This month has not started'); end if;
  select * into v_run from public.payroll_runs where station_id = p_station and month = v_month;
  if v_run.status = 'final' then perform private.fail('VALIDATION', 'This payroll is final'); end if;
  if v_run.id is null then
    insert into public.payroll_runs (station_id, month) values (p_station, v_month) returning * into v_run;
  end if;

  for s in select * from public.staff st where st.station_id = p_station
             and st.joined_on <= v_end and (st.left_on is null or st.left_on >= v_month) loop
    v_from := greatest(v_month, s.joined_on);
    v_to := least(v_end, coalesce(s.left_on, v_end));
    -- Paid days = Present + Leave + Off + ½ Half day; days without a row count as present.
    select (v_to - v_from + 1)
           - coalesce(sum(case a.status when 'absent' then 1 when 'half_day' then 0.5 else 0 end), 0)
      into v_paid
    from public.attendance a where a.staff_id = s.id and a.day between v_from and v_to;
    v_salary := round(s.salary_paisa::numeric * v_paid / v_days);
    v_lab := coalesce((select labour_paisa from private.paid_labour_by_user(p_station, v_month, v_end) where user_id = s.user_id), 0);
    v_comm := round(v_lab * s.commission_pct / 100);
    -- Each advance is deducted in equal parts over its months, starting the month it was given;
    -- the last part takes the remainder.
    select coalesce(sum(case
             when k.n between 0 and k.months - 1 then k.amount_paisa / k.months
                  + case when k.n = k.months - 1 then k.amount_paisa % k.months else 0 end
             else 0 end), 0)::bigint
      into v_adv
    from (select a.amount_paisa, a.months,
                 ((extract(year from v_month) * 12 + extract(month from v_month))
                  - (extract(year from a.given_on) * 12 + extract(month from a.given_on)))::int as n
          from public.salary_advances a where a.staff_id = s.id) k;
    select adjustment_paisa, adjustment_note into v_adj, v_note from public.payroll_lines where run_id = v_run.id and staff_id = s.id;
    v_adj := coalesce(v_adj, 0);
    insert into public.payroll_lines (run_id, station_id, staff_id, days_in_month, paid_days, monthly_paisa, salary_paisa,
                                      labour_paisa, commission_pct, commission_paisa, advances_paisa, adjustment_paisa, adjustment_note, net_paisa)
    values (v_run.id, p_station, s.id, v_days, v_paid, s.salary_paisa, v_salary, v_lab, s.commission_pct, v_comm, v_adv, v_adj, v_note,
            v_salary + v_comm - v_adv + v_adj)
    on conflict (run_id, staff_id) do update set
      days_in_month = excluded.days_in_month, paid_days = excluded.paid_days, monthly_paisa = excluded.monthly_paisa,
      salary_paisa = excluded.salary_paisa, labour_paisa = excluded.labour_paisa, commission_pct = excluded.commission_pct,
      commission_paisa = excluded.commission_paisa, advances_paisa = excluded.advances_paisa, net_paisa = excluded.net_paisa;
  end loop;
  return v_run.id;
end;
$$;

create or replace function public.payroll_set_adjustment(p_line uuid, p_amount_paisa bigint, p_note text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare l public.payroll_lines;
begin
  select * into l from public.payroll_lines where id = p_line;
  if l.id is null or not private.has_role(l.station_id, array['owner']::public.member_role[]) then perform private.fail('NOT_FOUND'); end if;
  perform private.assert_can_write(l.station_id, 'payroll');
  if (select status from public.payroll_runs where id = l.run_id) = 'final' then perform private.fail('VALIDATION', 'This payroll is final'); end if;
  if coalesce(p_amount_paisa, 0) <> 0 and length(trim(coalesce(p_note, ''))) < 3 then
    perform private.fail('VALIDATION', 'Add a note for the adjustment');
  end if;
  update public.payroll_lines set adjustment_paisa = coalesce(p_amount_paisa, 0), adjustment_note = nullif(trim(p_note), ''),
    net_paisa = salary_paisa + commission_paisa - advances_paisa + coalesce(p_amount_paisa, 0)
  where id = p_line;
end;
$$;

create or replace function public.payroll_finalize(p_run uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare r public.payroll_runs;
begin
  select * into r from public.payroll_runs where id = p_run;
  if r.id is null or not private.has_role(r.station_id, array['owner']::public.member_role[]) then perform private.fail('NOT_FOUND'); end if;
  perform private.assert_can_write(r.station_id, 'payroll');
  if r.status = 'final' then perform private.fail('VALIDATION', 'Already final'); end if;
  if r.month = date_trunc('month', private.today_pk())::date then
    perform private.fail('VALIDATION', 'Finalise after the month ends');
  end if;
  update public.payroll_runs set status = 'final', finalized_by = auth.uid(), finalized_at = now() where id = p_run;
end;
$$;

-- A final sheet can't change.
create or replace function private.payroll_lines_locked()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if (select status from public.payroll_runs where id = coalesce(new.run_id, old.run_id)) = 'final' then
    perform private.fail('VALIDATION', 'This payroll is final');
  end if;
  return coalesce(new, old);
end;
$$;
create trigger payroll_lines_lock before insert or update or delete on public.payroll_lines
  for each row execute function private.payroll_lines_locked();

-- Reports (REQ-059) --------------------------------------------------------------------------
create or replace function private.assert_report(p_station uuid, p_roles public.member_role[], p_feature text default null)
returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (private.has_role(p_station, p_roles) or private.has_support_grant(p_station)) then perform private.fail('FORBIDDEN'); end if;
  if p_feature is not null and not private.has_feature(p_station, p_feature) then perform private.fail('FEATURE_LOCKED', p_feature); end if;
end;
$$;

-- Monthly revenue: invoices issued in the range. Net = parts + labour − discounts (before tax).
create or replace function public.report_revenue(p_station uuid, p_from date, p_to date)
returns table (invoices bigint, parts_paisa bigint, labour_paisa bigint, discount_paisa bigint, tax_paisa bigint,
               refunds_paisa bigint, net_paisa bigint, total_paisa bigint)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform private.assert_report(p_station, array['owner','manager']::public.member_role[]);
  return query
  with i as (
    select * from public.invoices x
    where x.station_id = p_station and (x.issued_at at time zone 'Asia/Karachi')::date between p_from and p_to
  )
  select count(*)::bigint,
         coalesce(sum(i.parts_paisa), 0)::bigint,
         coalesce(sum(i.labour_paisa), 0)::bigint,
         coalesce(sum(case when i.discount_state = 'applied' then i.discount_paisa else 0 end), 0)::bigint,
         coalesce(sum(i.tax_parts_paisa + i.tax_services_paisa), 0)::bigint,
         (select coalesce(sum(c.amount_paisa), 0) from public.credit_notes c
          where c.station_id = p_station and (c.created_at at time zone 'Asia/Karachi')::date between p_from and p_to)::bigint,
         (coalesce(sum(i.parts_paisa + i.labour_paisa), 0)
          - coalesce(sum(case when i.discount_state = 'applied' then i.discount_paisa else 0 end), 0))::bigint,
         coalesce(sum(i.total_paisa), 0)::bigint
  from i;
end;
$$;

-- Payments by day and method (cash closing report over a range).
create or replace function public.report_collections(p_station uuid, p_from date, p_to date)
returns table (day date, method public.pay_method, amount_paisa bigint, closed boolean, counted_cash bigint, difference bigint)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform private.assert_report(p_station, array['owner','manager','cashier']::public.member_role[]);
  return query
  select p.paid_on, p.method, sum(p.amount_paisa)::bigint,
         bool_or(d.closed_at is not null and d.reopened_at is null), max(d.counted_cash), max(d.difference)
  from public.payments p
  left join public.day_closings d on d.station_id = p.station_id and d.day = p.paid_on
  where p.station_id = p_station and p.paid_on between p_from and p_to and p.method <> 'credit'
  group by p.paid_on, p.method
  order by p.paid_on, p.method;
end;
$$;

-- Stock on hand and value at average cost (owner only).
create or replace function public.report_stock_value(p_station uuid)
returns table (item_id uuid, code text, name text, unit text, on_hand numeric, avg_cost_paisa bigint, value_paisa bigint)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform private.assert_report(p_station, array['owner']::public.member_role[]);
  return query
  select i.id, i.code, i.name, i.unit::text, s.on_hand, coalesce(c.avg_cost_paisa, 0),
         round(greatest(s.on_hand, 0) * coalesce(c.avg_cost_paisa, 0))::bigint
  from public.items i
  join public.item_stock s on s.item_id = i.id
  left join public.item_costs c on c.item_id = i.id
  where i.station_id = p_station and i.active and i.unit <> 'kit'
  order by i.name;
end;
$$;

-- Profit per job (Premium, owner only): revenue before tax minus parts at cost.
create or replace function public.report_job_profit(p_station uuid, p_from date, p_to date)
returns table (job_id uuid, job_no integer, invoice_no integer, plate text, revenue_paisa bigint, parts_cost_paisa bigint, profit_paisa bigint)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform private.assert_report(p_station, array['owner']::public.member_role[], 'profit_reports');
  return query
  select x.id, x.job_no, x.invoice_no, x.plate, x.revenue, x.cost, x.revenue - x.cost
  from (
    select j.id, j.job_no, i.invoice_no, v.plate,
           (i.parts_paisa + i.labour_paisa - case when i.discount_state = 'applied' then i.discount_paisa else 0 end)::bigint as revenue,
           coalesce((select round(sum(-m.qty * coalesce(m.unit_cost_paisa, c.avg_cost_paisa, 0)))
                     from public.stock_movements m left join public.item_costs c on c.item_id = m.item_id
                     where m.ref_id = j.id and m.kind in ('job_use', 'job_return')), 0)::bigint as cost
    from public.invoices i
    join public.job_cards j on j.id = i.job_id
    join public.vehicles v on v.id = j.vehicle_id
    where i.station_id = p_station and (i.issued_at at time zone 'Asia/Karachi')::date between p_from and p_to
  ) x
  order by x.job_no;
end;
$$;

-- Profit per part (Premium, owner only): sold on invoices in the range vs average cost.
create or replace function public.report_part_profit(p_station uuid, p_from date, p_to date)
returns table (item_id uuid, name text, qty numeric, sales_paisa bigint, cost_paisa bigint, profit_paisa bigint)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform private.assert_report(p_station, array['owner']::public.member_role[], 'profit_reports');
  return query
  select it.id, it.name, sum(l.qty), sum(l.total_paisa)::bigint,
         round(sum(l.qty * coalesce(c.avg_cost_paisa, 0)))::bigint,
         (sum(l.total_paisa) - round(sum(l.qty * coalesce(c.avg_cost_paisa, 0))))::bigint
  from public.invoice_lines l
  join public.invoices i on i.id = l.invoice_id
  join public.items it on it.id = l.item_id
  left join public.item_costs c on c.item_id = l.item_id
  where i.station_id = p_station and l.kind = 'part' and (i.issued_at at time zone 'Asia/Karachi')::date between p_from and p_to
  group by it.id, it.name
  order by 6 desc;
end;
$$;

-- REQ-054: mechanic performance (Premium).
create or replace function public.report_mechanics(p_station uuid, p_from date, p_to date)
returns table (user_id uuid, name text, jobs_completed bigint, labour_paisa bigint, rework_jobs bigint, rework_pct numeric,
               qc_fails bigint, avg_hours numeric)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform private.assert_report(p_station, array['owner','manager']::public.member_role[], 'payroll');
  return query
  with done as (   -- jobs that first reached Ready in the range
    select h.job_id, min(h.created_at) as at from public.job_history h
    join public.job_cards j on j.id = h.job_id
    where j.station_id = p_station and h.new_value = 'ready' and h.field in ('stage', 'qc') and not h.conflict
    group by h.job_id
    having (min(h.created_at) at time zone 'Asia/Karachi')::date between p_from and p_to
  ), per as (      -- one row per mechanic and job, with that mechanic's share of the labour
    select a.user_id, d.job_id, j.kind,
           (select coalesce(sum(round(l.qty * l.unit_price_paisa)), 0) from public.job_lines l
            where l.job_id = d.job_id and l.kind = 'labour' and l.status = 'approved')::numeric
           / (select count(*) from public.job_assignments x where x.job_id = d.job_id) as labour,
           extract(epoch from (
             (select min(h.created_at) from public.job_history h where h.job_id = d.job_id and h.field = 'stage' and h.new_value = 'quality_check')
             - (select min(h.created_at) from public.job_history h where h.job_id = d.job_id and h.field = 'stage' and h.new_value = 'in_progress')
           )) / 3600 as hours
    from done d join public.job_assignments a on a.job_id = d.job_id join public.job_cards j on j.id = d.job_id
  ), agg as (
    select m.user_id, pr.full_name as name,
           count(per.job_id) filter (where per.kind <> 'rework') as jobs,
           coalesce(round(sum(per.labour)), 0)::bigint as labour,
           round(avg(per.hours)::numeric, 1) as hours,
           (select count(*) from public.job_cards r
            where r.station_id = p_station and r.kind = 'rework'
              and (r.created_at at time zone 'Asia/Karachi')::date between p_from and p_to
              and exists (select 1 from public.job_assignments x where x.job_id = r.parent_job_id and x.user_id = m.user_id)) as reworks,
           (select count(*) from public.job_history h join public.job_assignments x on x.job_id = h.job_id
            join public.job_cards jj on jj.id = h.job_id
            where jj.station_id = p_station and x.user_id = m.user_id and h.field = 'qc' and h.new_value = 'in_progress'
              and (h.created_at at time zone 'Asia/Karachi')::date between p_from and p_to) as qc_fails
    from public.station_members m
    join public.profiles pr on pr.id = m.user_id
    left join per on per.user_id = m.user_id
    where m.station_id = p_station and m.role = 'mechanic'
    group by m.user_id, pr.full_name
  )
  select g.user_id, g.name, g.jobs::bigint, g.labour, g.reworks::bigint,
         case when g.jobs > 0 then round(g.reworks * 100.0 / g.jobs, 1) else 0 end,
         g.qc_fails::bigint, g.hours
  from agg g
  order by g.name;
end;
$$;

-- No-shows (Standard+) and message usage.
create or replace function public.report_no_shows(p_station uuid, p_from date, p_to date)
returns table (slot_start timestamptz, customer text, mobile text, plate text, no_shows integer, blocked boolean)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform private.assert_report(p_station, array['owner','manager','cashier']::public.member_role[], 'booking');
  return query
  select b.slot_start, c.name, c.mobile, v.plate, coalesce(n.no_shows, 0), coalesce(n.blocked, false)
  from public.bookings b
  join public.customers c on c.id = b.customer_id
  join public.vehicles v on v.id = b.vehicle_id
  left join public.no_show_counters n on n.customer_id = b.customer_id
  where b.station_id = p_station and b.status = 'no_show'
    and (b.slot_start at time zone 'Asia/Karachi')::date between p_from and p_to
  order by b.slot_start;
end;
$$;

create or replace function public.report_messages(p_station uuid, p_from date, p_to date)
returns table (event text, label text, automatic bigint, sent_by_staff bigint, waiting bigint, skipped bigint, push bigint)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform private.assert_report(p_station, array['owner','manager']::public.member_role[]);
  return query
  select e.code, e.label,
         count(*) filter (where o.channel = 'whatsapp' and o.status = 'sent' and o.handled_by is null),
         count(*) filter (where o.channel = 'whatsapp' and o.status in ('sent', 'opened') and o.handled_by is not null),
         count(*) filter (where o.channel = 'whatsapp' and o.status in ('manual', 'queued', 'sending')),
         count(*) filter (where o.channel = 'whatsapp' and o.status = 'skipped'),
         count(*) filter (where o.channel = 'push' and o.status = 'sent')
  from public.message_events e
  left join public.message_outbox o on o.event = e.code and o.station_id = p_station
    and (o.created_at at time zone 'Asia/Karachi')::date between p_from and p_to
  group by e.code, e.label, e.sort
  order by e.sort;
end;
$$;

-- REQ-060: dashboard totals beyond the job and collection tiles.
create or replace function public.station_dashboard_totals(p_station uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform private.assert_report(p_station, array['owner','manager','cashier']::public.member_role[]);
  return jsonb_build_object(
    'dues_paisa', (select coalesce(sum(dues_paisa), 0) from public.customer_balances where station_id = p_station),
    'low_stock', (select count(*) from public.low_stock_items where station_id = p_station),
    'messages_to_send', (select count(*) from public.message_outbox where station_id = p_station and channel = 'whatsapp' and status in ('manual', 'opened')),
    'pending_approvals', (select count(*) from public.approval_requests where station_id = p_station and status = 'pending'),
    'jobs_by_stage', (select coalesce(jsonb_object_agg(stage, n), '{}') from
                       (select stage::text, count(*) as n from public.job_cards
                        where station_id = p_station and stage not in ('delivered', 'cancelled') group by stage) x)
  );
end;
$$;

revoke execute on function
  public.station_save_staff(uuid, jsonb), public.station_staff_pay(uuid),
  public.station_set_attendance(uuid, date, public.attendance_status, text),
  public.station_add_advance(uuid, bigint, public.pay_method, date, integer, text),
  public.payroll_generate(uuid, date), public.payroll_set_adjustment(uuid, bigint, text), public.payroll_finalize(uuid),
  public.report_revenue(uuid, date, date), public.report_collections(uuid, date, date), public.report_stock_value(uuid),
  public.report_job_profit(uuid, date, date), public.report_part_profit(uuid, date, date), public.report_mechanics(uuid, date, date),
  public.report_no_shows(uuid, date, date), public.report_messages(uuid, date, date), public.station_dashboard_totals(uuid)
from public, anon;
grant execute on function
  public.station_save_staff(uuid, jsonb), public.station_staff_pay(uuid),
  public.station_set_attendance(uuid, date, public.attendance_status, text),
  public.station_add_advance(uuid, bigint, public.pay_method, date, integer, text),
  public.payroll_generate(uuid, date), public.payroll_set_adjustment(uuid, bigint, text), public.payroll_finalize(uuid),
  public.report_revenue(uuid, date, date), public.report_collections(uuid, date, date), public.report_stock_value(uuid),
  public.report_job_profit(uuid, date, date), public.report_part_profit(uuid, date, date), public.report_mechanics(uuid, date, date),
  public.report_no_shows(uuid, date, date), public.report_messages(uuid, date, date), public.station_dashboard_totals(uuid)
to authenticated;
