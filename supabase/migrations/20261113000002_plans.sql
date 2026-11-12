-- TASK-017 · REQ-006, REQ-007, REQ-009
-- Plans, features, subscriptions and the station_entitlements view.

create table public.plans (
  code              text primary key,
  name              text not null,
  monthly_price_pkr integer not null check (monthly_price_pkr >= 0),
  yearly_price_pkr  integer not null check (yearly_price_pkr >= 0),
  sort_order        integer not null
);

create table public.features (
  code        text primary key,
  description text not null
);

create table public.plan_features (
  plan_code    text not null references public.plans(code) on delete cascade,
  feature_code text not null references public.features(code) on delete cascade,
  primary key (plan_code, feature_code)
);

-- Yearly = 10 months' price (DEC-025).
insert into public.plans (code, name, monthly_price_pkr, yearly_price_pkr, sort_order) values
  ('basic',    'Basic',    2500, 25000, 1),
  ('standard', 'Standard', 5000, 50000, 2),
  ('premium',  'Premium',  8000, 80000, 3);

-- PRD section 4 feature matrix.
insert into public.features (code, description) values
  ('core',            'Sign-up, users, job cards, inventory, billing, customer history, monthly revenue report, manual WhatsApp'),
  ('supplier_ledger', 'Supplier ledger and supplier dues'),
  ('booking',         'Booking and customer app'),
  ('whatsapp_auto',   'Automatic WhatsApp from the station''s own account'),
  ('approvals_inbox', 'Approvals inbox'),
  ('audit_log_view',  'Audit log view'),
  ('payroll',         'Staff attendance, advances, payroll, commission, performance'),
  ('profit_reports',  'Profit per part / per job reports');

insert into public.plan_features (plan_code, feature_code)
select p.code, f.code
from public.plans p cross join public.features f
where f.code = 'core'
   or (p.code in ('standard','premium') and f.code in ('supplier_ledger','booking','whatsapp_auto','approvals_inbox','audit_log_view'))
   or (p.code = 'premium' and f.code in ('payroll','profit_reports'));

create type public.subscription_state as enum ('trial', 'active', 'suspended', 'closed');
create type public.billing_cycle as enum ('monthly', 'yearly');

-- One subscription row per station. "grace" and "read_only" are derived from dates.
create table public.subscriptions (
  station_id         uuid primary key references public.stations(id) on delete cascade,
  plan_code          text not null references public.plans(code),
  state              public.subscription_state not null default 'trial',
  billing_cycle      public.billing_cycle not null default 'monthly',
  trial_ends_at      timestamptz,
  current_period_end timestamptz,
  updated_at         timestamptz not null default now()
);

alter table public.plans          enable row level security;
alter table public.features       enable row level security;
alter table public.plan_features  enable row level security;
alter table public.subscriptions  enable row level security;

-- Plan catalogue is public information (pricing page, locked-feature cards).
create policy plans_read         on public.plans         for select to anon, authenticated using (true);
create policy features_read      on public.features      for select to anon, authenticated using (true);
create policy plan_features_read on public.plan_features for select to anon, authenticated using (true);

create policy subscriptions_read on public.subscriptions
  for select to authenticated
  using (private.can_read_station(station_id) or private.is_super_admin());

revoke insert, update, delete on public.plans, public.features, public.plan_features, public.subscriptions
  from anon, authenticated;

-- Grace = 7 days of full use after the renewal / trial end; read-only from day 8.
create or replace function private.effective_status(
  p_state public.subscription_state, p_trial_ends timestamptz, p_period_end timestamptz,
  p_at timestamptz default now())
returns text
language sql immutable
as $$
  select case
    when p_state = 'suspended' then 'suspended'
    when p_state = 'closed'    then 'closed'
    when p_state = 'trial' and p_at <  p_trial_ends                     then 'trial'
    when p_state = 'trial' and p_at <  p_trial_ends + interval '7 days' then 'grace'
    when p_state = 'trial'                                              then 'read_only'
    when p_at <  p_period_end                                           then 'active'
    when p_at <  p_period_end + interval '7 days'                       then 'grace'
    else 'read_only'
  end;
$$;

-- Trial gives all Premium features (REQ-007).
create or replace view public.station_entitlements
with (security_invoker = true)
as
select
  s.station_id,
  s.plan_code,
  case when s.state = 'trial' then 'premium' else s.plan_code end as effective_plan,
  private.effective_status(s.state, s.trial_ends_at, s.current_period_end) as status,
  coalesce(s.trial_ends_at, s.current_period_end) as renews_at,
  array(
    select pf.feature_code from public.plan_features pf
    where pf.plan_code = case when s.state = 'trial' then 'premium' else s.plan_code end
    order by pf.feature_code
  ) as features
from public.subscriptions s;

grant select on public.station_entitlements to authenticated;

create or replace function private.has_feature(p_station uuid, p_feature text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.subscriptions s
    join public.plan_features pf
      on pf.plan_code = case when s.state = 'trial' then 'premium' else s.plan_code end
    where s.station_id = p_station and pf.feature_code = p_feature
  );
$$;

-- Called first by every write function: blocks writes in read-only/suspended/closed
-- states and for features outside the plan.
create or replace function private.assert_can_write(p_station uuid, p_feature text default 'core')
returns void
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_status text;
begin
  select private.effective_status(s.state, s.trial_ends_at, s.current_period_end)
    into v_status
  from public.subscriptions s where s.station_id = p_station;

  if v_status is null then
    perform private.fail('NOT_FOUND');
  elsif v_status in ('read_only', 'suspended', 'closed') then
    perform private.fail('READ_ONLY', 'Subscription expired — read-only. Ask the owner to renew');
  elsif not private.has_feature(p_station, p_feature) then
    perform private.fail('FEATURE_LOCKED', p_feature);
  end if;
end;
$$;

grant execute on all functions in schema private to authenticated, service_role;
