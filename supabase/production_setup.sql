-- PRODUCTION SETUP: every migration (1-23) in order, for a NEW, EMPTY Supabase project.
-- Supabase dashboard -> SQL Editor -> paste all -> Run once. Do NOT run this on staging
-- (staging already has them; use the dashboard_phase*.sql files there).
-- Generated from supabase/migrations; regenerate after adding a migration.

-- ===== supabase/migrations/20261113000001_core.sql =====
-- TASK-010 · REQ-002, REQ-003
-- Core tenancy: stations, profiles, station members and roles.
-- Rule: every tenant table carries station_id and has RLS. Clients never write
-- tables directly; all writes go through SECURITY DEFINER functions.

create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated, service_role;

create type public.member_role as enum ('owner', 'manager', 'cashier', 'mechanic');

-- Stations (one branch each at launch) -------------------------------------
create table public.stations (
  id                 uuid primary key default gen_random_uuid(),
  name               text not null check (length(trim(name)) between 2 and 120),
  city               text not null check (length(trim(city)) between 2 and 80),
  address            text,
  phone              text,
  logo_path          text,
  ntn                text,
  strn               text,
  sales_tax_enabled  boolean not null default false,
  parts_tax_pct      numeric(5,2) not null default 0 check (parts_tax_pct between 0 and 100),
  services_tax_pct   numeric(5,2) not null default 0 check (services_tax_pct between 0 and 100),
  discount_limit_pct numeric(5,2) not null default 5 check (discount_limit_pct between 0 and 100),
  station_code       text not null unique,
  created_at         timestamptz not null default now(),
  closed_at          timestamptz
);

-- Profiles: one per auth user (station staff and super admins) -------------
create table public.profiles (
  id             uuid primary key references auth.users(id) on delete cascade,
  full_name      text not null check (length(trim(full_name)) between 2 and 120),
  mobile         text unique check (mobile ~ '^03[0-9]{9}$'),
  email          text check (email is null or email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  is_super_admin boolean not null default false,
  created_at     timestamptz not null default now()
);

-- Membership of a user in a station with one role --------------------------
create table public.station_members (
  id             uuid primary key default gen_random_uuid(),
  station_id     uuid not null references public.stations(id) on delete cascade,
  user_id        uuid not null references public.profiles(id) on delete cascade,
  role           public.member_role not null,
  active         boolean not null default true,
  created_at     timestamptz not null default now(),
  deactivated_at timestamptz,
  unique (station_id, user_id)
);
create index station_members_user_idx on public.station_members(user_id) where active;

-- Helpers (SECURITY DEFINER so policies don't recurse through RLS) ----------
create or replace function private.member_station_ids()
returns setof uuid
language sql stable security definer set search_path = ''
as $$
  select m.station_id from public.station_members m
  where m.user_id = auth.uid() and m.active;
$$;

create or replace function private.has_role(p_station uuid, p_roles public.member_role[])
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.station_members m
    where m.station_id = p_station and m.user_id = auth.uid()
      and m.active and m.role = any(p_roles)
  );
$$;

create or replace function private.is_super_admin()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((select p.is_super_admin from public.profiles p where p.id = auth.uid()), false);
$$;

-- Who may READ a station's rows. Replaced in the support-grant migration
-- to also allow a super admin holding an active grant (REQ-005).
create or replace function private.can_read_station(p_station uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select p_station in (select private.member_station_ids());
$$;

-- Raise a coded error the apps map to readable messages (packages/core).
create or replace function private.fail(p_code text, p_message text default null)
returns void
language plpgsql
as $$
begin
  raise exception using errcode = 'P0001', message = p_code, detail = coalesce(p_message, p_code);
end;
$$;

grant execute on all functions in schema private to authenticated, service_role;

-- RLS ------------------------------------------------------------------------
alter table public.stations        enable row level security;
alter table public.profiles        enable row level security;
alter table public.station_members enable row level security;

create policy stations_read on public.stations
  for select to authenticated
  using (private.can_read_station(id));

-- Own profile, or profiles of people in a station I can read.
create policy profiles_read on public.profiles
  for select to authenticated
  using (
    id = auth.uid()
    or exists (
      select 1 from public.station_members m
      where m.user_id = profiles.id and private.can_read_station(m.station_id)
    )
  );

-- Owners and managers see the member list; everyone sees their own membership.
create policy station_members_read on public.station_members
  for select to authenticated
  using (
    user_id = auth.uid()
    or private.has_role(station_id, array['owner','manager']::public.member_role[])
    or (private.can_read_station(station_id) and private.is_super_admin())
  );

-- No direct writes from clients.
revoke insert, update, delete on public.stations, public.profiles, public.station_members
  from anon, authenticated;

-- ===== supabase/migrations/20261113000002_plans.sql =====
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

-- ===== supabase/migrations/20261113000003_audit.sql =====
-- TASK-018 · REQ-058
-- Append-only audit log written by triggers. Nobody can edit or delete entries.

create table public.audit_log (
  id          bigint generated always as identity primary key,
  station_id  uuid references public.stations(id) on delete cascade,
  actor_id    uuid,
  table_name  text not null,
  record_id   text,
  action      text not null,          -- insert | update | delete | event name
  changes     jsonb not null default '{}'::jsonb,  -- {field: {"old": x, "new": y}}
  created_at  timestamptz not null default now()
);
create index audit_log_station_idx on public.audit_log(station_id, created_at desc);

alter table public.audit_log enable row level security;

-- Owner only, Standard+ (REQ-058). Recording happens on all plans.
create policy audit_log_read on public.audit_log
  for select to authenticated
  using (
    private.has_role(station_id, array['owner']::public.member_role[])
    and private.has_feature(station_id, 'audit_log_view')
  );

revoke all on public.audit_log from anon, authenticated;
grant select on public.audit_log to authenticated;

-- Hard block on edits and deletes, for every role including service_role.
-- (Deletion of a whole closed station after 90 days goes through the FK cascade,
--  which runs as a cascade delete and is allowed only via private.purge flag.)
create or replace function private.audit_log_immutable()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' and current_setting('app.purge_station', true) = 'on' then
    return old;
  end if;
  raise exception using errcode = 'P0001', message = 'AUDIT_IMMUTABLE';
end;
$$;

create trigger audit_log_no_update before update on public.audit_log
  for each row execute function private.audit_log_immutable();
create trigger audit_log_no_delete before delete on public.audit_log
  for each row execute function private.audit_log_immutable();

-- Event entries that are not row changes (e.g. support view session).
create or replace function private.write_audit(
  p_station uuid, p_table text, p_record text, p_action text, p_changes jsonb default '{}'::jsonb)
returns void
language sql security definer set search_path = ''
as $$
  insert into public.audit_log (station_id, actor_id, table_name, record_id, action, changes)
  values (p_station, auth.uid(), p_table, p_record, p_action, coalesce(p_changes, '{}'::jsonb));
$$;

-- Generic row trigger: records changed fields old -> new.
create or replace function private.audit_row()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_old jsonb := case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end;
  v_new jsonb := case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end;
  v_row jsonb := coalesce(v_new, v_old);
  v_station uuid;
  v_changes jsonb := '{}'::jsonb;
  k text;
begin
  v_station := coalesce(
    (v_row ->> 'station_id')::uuid,
    case when tg_table_name = 'stations' then (v_row ->> 'id')::uuid end);

  if tg_op = 'UPDATE' then
    for k in select jsonb_object_keys(v_new) loop
      if (v_new -> k) is distinct from (v_old -> k) then
        v_changes := v_changes || jsonb_build_object(k, jsonb_build_object('old', v_old -> k, 'new', v_new -> k));
      end if;
    end loop;
    if v_changes = '{}'::jsonb then
      return new;
    end if;
  elsif tg_op = 'INSERT' then
    v_changes := jsonb_build_object('new', v_new);
  else
    v_changes := jsonb_build_object('old', v_old);
  end if;

  insert into public.audit_log (station_id, actor_id, table_name, record_id, action, changes)
  values (v_station, auth.uid(), tg_table_name,
          coalesce(v_row ->> 'id', v_row ->> 'station_id'), lower(tg_op), v_changes);

  return coalesce(new, old);
end;
$$;

create trigger audit_stations after insert or update on public.stations
  for each row execute function private.audit_row();
create trigger audit_station_members after insert or update or delete on public.station_members
  for each row execute function private.audit_row();
create trigger audit_subscriptions after insert or update on public.subscriptions
  for each row execute function private.audit_row();

grant execute on all functions in schema private to authenticated, service_role;

-- ===== supabase/migrations/20261113000004_support_access.sql =====
-- TASK-019 · REQ-005
-- Owner grants the super admin time-limited, read-only access to station data.

create table public.support_grants (
  id          uuid primary key default gen_random_uuid(),
  station_id  uuid not null references public.stations(id) on delete cascade,
  granted_by  uuid not null references public.profiles(id),
  starts_at   timestamptz not null default now(),
  expires_at  timestamptz not null,
  revoked_at  timestamptz,
  revoked_by  uuid references public.profiles(id),
  check (expires_at > starts_at)
);
create index support_grants_station_idx on public.support_grants(station_id, expires_at desc);

alter table public.support_grants enable row level security;

create policy support_grants_read on public.support_grants
  for select to authenticated
  using (
    private.has_role(station_id, array['owner']::public.member_role[])
    or private.is_super_admin()
  );

revoke insert, update, delete on public.support_grants from anon, authenticated;

create trigger audit_support_grants after insert or update on public.support_grants
  for each row execute function private.audit_row();

create or replace function private.has_support_grant(p_station uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select private.is_super_admin() and exists (
    select 1 from public.support_grants g
    where g.station_id = p_station and g.revoked_at is null
      and now() >= g.starts_at and now() < g.expires_at
  );
$$;

-- Readers = active members, or a super admin with an active grant.
-- Write functions check membership roles, so a super admin can never write.
create or replace function private.can_read_station(p_station uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select p_station in (select private.member_station_ids())
      or private.has_support_grant(p_station);
$$;

grant execute on all functions in schema private to authenticated, service_role;

-- Public RPCs ---------------------------------------------------------------
create or replace function public.station_grant_support(p_station uuid, p_hours integer)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_id uuid;
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then
    perform private.fail('FORBIDDEN');
  end if;
  if p_hours not in (1, 24, 72) then
    perform private.fail('VALIDATION', 'Support access can be 1, 24 or 72 hours');
  end if;

  insert into public.support_grants (station_id, granted_by, expires_at)
  values (p_station, auth.uid(), now() + make_interval(hours => p_hours))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.station_revoke_support(p_grant uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_station uuid;
begin
  select station_id into v_station from public.support_grants where id = p_grant;
  if v_station is null or not private.has_role(v_station, array['owner']::public.member_role[]) then
    perform private.fail('NOT_FOUND');
  end if;
  update public.support_grants
     set revoked_at = now(), revoked_by = auth.uid()
   where id = p_grant and revoked_at is null;
end;
$$;

-- The super admin calls this when opening a support session, so each view is logged.
create or replace function public.admin_open_support_session(p_station uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.has_support_grant(p_station) then
    perform private.fail('NOT_FOUND');
  end if;
  perform private.write_audit(p_station, 'support_grants', null, 'support_view');
end;
$$;

revoke execute on function public.station_grant_support(uuid, integer),
                           public.station_revoke_support(uuid),
                           public.admin_open_support_session(uuid) from public, anon;
grant execute on function public.station_grant_support(uuid, integer),
                          public.station_revoke_support(uuid),
                          public.admin_open_support_session(uuid) to authenticated;

-- ===== supabase/migrations/20261113000005_station_functions.sql =====
-- TASK-014, TASK-015, TASK-016 · REQ-001, REQ-002, REQ-004
-- Station sign-up, member management and station profile.
-- Every function: role check -> state check -> validation -> write (audited by triggers).

-- Settings and users stay editable in read-only mode (REQ-009 blocks operations only),
-- but not when the station is suspended or closed.
create or replace function private.assert_station_open(p_station uuid)
returns void
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_state public.subscription_state;
begin
  select state into v_state from public.subscriptions where station_id = p_station;
  if v_state is null then
    perform private.fail('NOT_FOUND');
  elsif v_state in ('suspended', 'closed') then
    perform private.fail('STATION_SUSPENDED');
  end if;
end;
$$;

-- Normalises a Pakistani mobile to 03XXXXXXXXX. Accepts 03.., 923.., +923.., with dashes/spaces.
create or replace function private.normalize_pk_mobile(p_raw text)
returns text
language plpgsql immutable
as $$
declare
  d text := regexp_replace(coalesce(p_raw, ''), '[^0-9]', '', 'g');
begin
  if d ~ '^923[0-9]{9}$' then d := '0' || substr(d, 3); end if;
  if d ~ '^3[0-9]{9}$'   then d := '0' || d; end if;
  if d ~ '^03[0-9]{9}$'  then return d; end if;
  return null;
end;
$$;

-- Placeholder until job cards exist (TASK-029): open jobs assigned to a user.
create or replace function private.open_job_count(p_station uuid, p_user uuid)
returns integer
language sql stable
as $$ select 0; $$;

-- 6-character code customers type to link a station (REQ-047). No 0/O/1/I to avoid misreading.
create or replace function private.new_station_code()
returns text
language plpgsql volatile set search_path = ''
as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v text;
begin
  loop
    v := '';
    for i in 1..6 loop
      v := v || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.stations where station_code = v);
  end loop;
  return v;
end;
$$;

grant execute on all functions in schema private to authenticated, service_role;

-- REQ-001: called right after the owner's phone is verified by one-time code.
-- Creates the station, the owner membership and a 14-day Premium trial.
create or replace function public.station_signup(
  p_station_name text, p_city text, p_full_name text, p_email text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_phone text;
  v_confirmed timestamptz;
  v_mobile text;
  v_station uuid;
begin
  if v_uid is null then
    perform private.fail('UNAUTHENTICATED');
  end if;

  select u.phone, u.phone_confirmed_at into v_phone, v_confirmed
  from auth.users u where u.id = v_uid;

  if v_confirmed is null then
    perform private.fail('PHONE_NOT_VERIFIED');
  end if;
  v_mobile := private.normalize_pk_mobile(v_phone);
  if v_mobile is null then
    perform private.fail('VALIDATION', 'Mobile must be a Pakistani number 03XX-XXXXXXX');
  end if;
  if length(trim(coalesce(p_station_name, ''))) < 2 or length(trim(coalesce(p_city, ''))) < 2
     or length(trim(coalesce(p_full_name, ''))) < 2 then
    perform private.fail('VALIDATION', 'Name, station name and city are required');
  end if;
  if exists (select 1 from public.station_members where user_id = v_uid) then
    perform private.fail('ALREADY_REGISTERED');
  end if;
  if exists (select 1 from public.profiles where mobile = v_mobile and id <> v_uid) then
    perform private.fail('MOBILE_IN_USE');
  end if;

  insert into public.profiles (id, full_name, mobile, email)
  values (v_uid, trim(p_full_name), v_mobile, nullif(trim(p_email), ''))
  on conflict (id) do update
    set full_name = excluded.full_name, mobile = excluded.mobile, email = excluded.email;

  insert into public.stations (name, city, station_code)
  values (trim(p_station_name), trim(p_city), private.new_station_code())
  returning id into v_station;

  insert into public.station_members (station_id, user_id, role)
  values (v_station, v_uid, 'owner');

  insert into public.subscriptions (station_id, plan_code, state, trial_ends_at)
  values (v_station, 'premium', 'trial', now() + interval '14 days');

  return v_station;
end;
$$;

-- REQ-002: the invite-member Edge Function creates the auth user (it holds the
-- service role) and then calls this with the inviting user's id as p_actor.
create or replace function public.admin_add_member(
  p_actor uuid, p_station uuid, p_user uuid, p_full_name text, p_mobile text, p_role public.member_role)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_mobile text := private.normalize_pk_mobile(p_mobile);
  v_id uuid;
begin
  -- Make auth.uid() = actor so role checks and audit rows name the real person.
  perform set_config('request.jwt.claim.sub', p_actor::text, true);

  if not private.has_role(p_station, array['owner']::public.member_role[]) then
    perform private.fail('FORBIDDEN');
  end if;
  perform private.assert_station_open(p_station);
  if p_role = 'owner' then
    perform private.fail('VALIDATION', 'A station has one owner');
  end if;
  if v_mobile is null then
    perform private.fail('VALIDATION', 'Mobile must be a Pakistani number 03XX-XXXXXXX');
  end if;

  insert into public.profiles (id, full_name, mobile)
  values (p_user, trim(p_full_name), v_mobile)
  on conflict (id) do nothing;

  insert into public.station_members (station_id, user_id, role)
  values (p_station, p_user, p_role)
  on conflict (station_id, user_id) do update set role = excluded.role, active = true, deactivated_at = null
  returning id into v_id;
  return v_id;
end;
$$;

-- Lets the Edge Function confirm the caller may add users before it creates an auth user.
create or replace function public.station_can_manage_users(p_station uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select private.has_role(p_station, array['owner']::public.member_role[]);
$$;

create or replace function public.station_set_member_role(p_member uuid, p_role public.member_role)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  m public.station_members;
begin
  select * into m from public.station_members where id = p_member;
  if m.id is null or not private.has_role(m.station_id, array['owner']::public.member_role[]) then
    perform private.fail('NOT_FOUND');
  end if;
  perform private.assert_station_open(m.station_id);
  if m.role = 'owner' or p_role = 'owner' then
    perform private.fail('VALIDATION', 'The owner role cannot be changed here');
  end if;
  update public.station_members set role = p_role where id = p_member;
end;
$$;

-- REQ-002: a deactivated user cannot log in; their history remains.
create or replace function public.station_set_member_active(p_member uuid, p_active boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  m public.station_members;
begin
  select * into m from public.station_members where id = p_member;
  if m.id is null or not private.has_role(m.station_id, array['owner']::public.member_role[]) then
    perform private.fail('NOT_FOUND');
  end if;
  perform private.assert_station_open(m.station_id);
  if m.role = 'owner' then
    perform private.fail('VALIDATION', 'The owner cannot be deactivated');
  end if;
  if not p_active and private.open_job_count(m.station_id, m.user_id) > 0 then
    perform private.fail('HAS_OPEN_JOBS', 'Reassign this user''s open jobs first');
  end if;
  update public.station_members
     set active = p_active,
         deactivated_at = case when p_active then null else now() end
   where id = p_member;
end;
$$;

-- REQ-004: station profile, branding and tax settings.
create or replace function public.station_update_profile(
  p_station uuid,
  p_name text,
  p_address text,
  p_phone text,
  p_ntn text,
  p_strn text,
  p_sales_tax_enabled boolean,
  p_parts_tax_pct numeric,
  p_services_tax_pct numeric,
  p_logo_path text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then
    perform private.fail('FORBIDDEN');
  end if;
  perform private.assert_station_open(p_station);
  if length(trim(coalesce(p_name, ''))) < 2 then
    perform private.fail('VALIDATION', 'Station name is required');
  end if;
  if p_parts_tax_pct not between 0 and 100 or p_services_tax_pct not between 0 and 100
     or p_parts_tax_pct <> round(p_parts_tax_pct, 2) or p_services_tax_pct <> round(p_services_tax_pct, 2) then
    perform private.fail('VALIDATION', 'Tax % must be 0–100 with at most 2 decimals');
  end if;
  if p_logo_path is not null and split_part(p_logo_path, '/', 1) <> p_station::text then
    perform private.fail('VALIDATION', 'Logo must be uploaded to this station''s folder');
  end if;

  update public.stations set
    name              = trim(p_name),
    address           = nullif(trim(p_address), ''),
    phone             = nullif(trim(p_phone), ''),
    ntn               = nullif(trim(p_ntn), ''),
    strn              = nullif(trim(p_strn), ''),
    sales_tax_enabled = coalesce(p_sales_tax_enabled, false),
    parts_tax_pct     = coalesce(p_parts_tax_pct, 0),
    services_tax_pct  = coalesce(p_services_tax_pct, 0),
    logo_path         = coalesce(p_logo_path, logo_path)
  where id = p_station;
end;
$$;

-- Function grants: nothing for anon; admin_add_member only for the service role.
revoke execute on function
  public.station_signup(text, text, text, text),
  public.admin_add_member(uuid, uuid, uuid, text, text, public.member_role),
  public.station_can_manage_users(uuid),
  public.station_set_member_role(uuid, public.member_role),
  public.station_set_member_active(uuid, boolean),
  public.station_update_profile(uuid, text, text, text, text, text, boolean, numeric, numeric, text)
from public, anon;

grant execute on function
  public.station_signup(text, text, text, text),
  public.station_can_manage_users(uuid),
  public.station_set_member_role(uuid, public.member_role),
  public.station_set_member_active(uuid, boolean),
  public.station_update_profile(uuid, text, text, text, text, text, boolean, numeric, numeric, text)
to authenticated;

grant execute on function
  public.admin_add_member(uuid, uuid, uuid, text, text, public.member_role)
to service_role;
revoke execute on function public.admin_add_member(uuid, uuid, uuid, text, text, public.member_role) from authenticated;

-- ===== supabase/migrations/20261113000006_storage.sql =====
-- TASK-016 · REQ-004
-- Station logos: PNG/JPG, max 2 MB, stored under "<station_id>/...".
-- Public read so logos can appear on shared invoices and customer messages.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('station-logos', 'station-logos', true, 2097152, array['image/png', 'image/jpeg'])
on conflict (id) do nothing;

create policy station_logos_owner_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'station-logos'
    and private.has_role(((storage.foldername(name))[1])::uuid, array['owner']::public.member_role[])
  );

create policy station_logos_owner_update on storage.objects
  for update to authenticated
  using (
    bucket_id = 'station-logos'
    and private.has_role(((storage.foldername(name))[1])::uuid, array['owner']::public.member_role[])
  );

-- ===== supabase/migrations/20261114000007_inventory.sql =====
-- TASK-020, TASK-021, TASK-022, TASK-025 · REQ-028, REQ-029, REQ-030, REQ-031, REQ-033
-- Items, kits, append-only stock movements with weighted average cost, suppliers,
-- purchases and the supplier ledger. Money = integer paisa. Quantities = numeric(12,3).

create type public.item_unit as enum ('piece', 'litre', 'kit');
create type public.stock_move_kind as enum
  ('opening', 'purchase', 'purchase_reversal', 'adjustment', 'job_use', 'job_return', 'supplier_return');

-- Generic guard for append-only tables (money and stock: corrections by reversal, REQ-042).
create or replace function private.append_only()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' and current_setting('app.purge_station', true) = 'on' then
    return old;
  end if;
  raise exception using errcode = 'P0001', message = 'APPEND_ONLY',
    detail = 'Saved entries cannot be changed or deleted. Reverse them with a reason.';
end;
$$;

-- Quantity rule: litres up to 2 decimals; pieces and kits whole numbers.
create or replace function private.valid_qty(p_unit public.item_unit, p_qty numeric)
returns boolean
language sql immutable
as $$
  select p_qty is not null and case
    when p_unit = 'litre' then p_qty = round(p_qty, 2)
    else p_qty = trunc(p_qty)
  end;
$$;

-- Items ----------------------------------------------------------------------
create table public.items (
  id                  uuid primary key default gen_random_uuid(),
  station_id          uuid not null references public.stations(id) on delete cascade,
  code                text not null check (length(trim(code)) between 1 and 40),
  name                text not null check (length(trim(name)) between 2 and 120),
  barcode             text,
  category            text,
  unit                public.item_unit not null default 'piece',
  is_bulk             boolean not null default false,  -- partial drum: decimal use allowed
  selling_price_paisa bigint not null default 0 check (selling_price_paisa >= 0),
  min_stock           numeric(12,3) not null default 0 check (min_stock >= 0),
  warranty_days       integer not null default 0 check (warranty_days >= 0),
  active              boolean not null default true,
  created_at          timestamptz not null default now(),
  unique (station_id, code),
  check (not is_bulk or unit = 'litre')
);
create unique index items_barcode_uq on public.items(station_id, barcode) where barcode is not null;
create index items_name_idx on public.items(station_id, lower(name));

-- Purchase cost is owner-only (REQ-028), so it lives in its own table.
create table public.item_costs (
  item_id             uuid primary key references public.items(id) on delete cascade,
  station_id          uuid not null references public.stations(id) on delete cascade,
  avg_cost_paisa      bigint not null default 0 check (avg_cost_paisa >= 0),
  last_cost_paisa     bigint not null default 0 check (last_cost_paisa >= 0),
  updated_at          timestamptz not null default now()
);

create table public.kit_components (
  station_id        uuid not null references public.stations(id) on delete cascade,
  kit_item_id       uuid not null references public.items(id) on delete cascade,
  component_item_id uuid not null references public.items(id),
  qty               numeric(12,3) not null check (qty > 0),
  primary key (kit_item_id, component_item_id),
  check (kit_item_id <> component_item_id)
);

create table public.stock_movements (
  id              bigint generated always as identity primary key,
  station_id      uuid not null references public.stations(id) on delete cascade,
  item_id         uuid not null references public.items(id),
  qty             numeric(12,3) not null check (qty <> 0),
  kind            public.stock_move_kind not null,
  ref_id          uuid,
  unit_cost_paisa bigint,
  note            text,
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now()
);
create index stock_movements_item_idx on public.stock_movements(item_id);
create trigger stock_movements_append_only before update or delete on public.stock_movements
  for each row execute function private.append_only();

-- Stock on hand = sum of movements (ARCHITECTURE §5).
create or replace view public.item_stock
with (security_invoker = true)
as
select i.station_id, i.id as item_id, coalesce(sum(m.qty), 0)::numeric(12,3) as on_hand
from public.items i
left join public.stock_movements m on m.item_id = i.id
group by i.station_id, i.id;

-- REQ-033: at or below minimum; REQ-031: negative stock is shown too.
create or replace view public.low_stock_items
with (security_invoker = true)
as
select i.station_id, i.id as item_id, i.code, i.name, i.unit, i.min_stock, s.on_hand,
       (s.on_hand < 0) as negative
from public.items i
join public.item_stock s on s.item_id = i.id
where i.active and i.unit <> 'kit' and (s.on_hand < 0 or (i.min_stock > 0 and s.on_hand <= i.min_stock));

-- Suppliers and purchases --------------------------------------------------------
create table public.suppliers (
  id         uuid primary key default gen_random_uuid(),
  station_id uuid not null references public.stations(id) on delete cascade,
  name       text not null check (length(trim(name)) between 2 and 120),
  phone      text,
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  unique (station_id, name)
);

create type public.purchase_status as enum ('posted', 'reversed');

create table public.purchases (
  id               uuid primary key default gen_random_uuid(),
  station_id       uuid not null references public.stations(id) on delete cascade,
  supplier_id      uuid references public.suppliers(id),
  supplier_name    text not null,          -- free text on Basic; copied from supplier on Standard+
  bill_no          text,
  bill_date        date not null default current_date,
  total_paisa      bigint not null check (total_paisa >= 0),
  paid_now_paisa   bigint not null default 0 check (paid_now_paisa >= 0),
  status           public.purchase_status not null default 'posted',
  reversal_reason  text,
  reversed_at      timestamptz,
  reversed_by      uuid,
  created_by       uuid default auth.uid(),
  created_at       timestamptz not null default now()
);
create index purchases_station_idx on public.purchases(station_id, bill_date desc);

create table public.purchase_lines (
  id              uuid primary key default gen_random_uuid(),
  station_id      uuid not null references public.stations(id) on delete cascade,
  purchase_id     uuid not null references public.purchases(id) on delete cascade,
  item_id         uuid not null references public.items(id),
  qty             numeric(12,3) not null check (qty > 0),
  unit_cost_paisa bigint not null check (unit_cost_paisa >= 0)
);
create index purchase_lines_purchase_idx on public.purchase_lines(purchase_id);

create type public.supplier_entry_kind as enum ('purchase', 'payment', 'purchase_reversal', 'payment_reversal', 'return');

-- Positive amount = station owes more; negative = owes less.
create table public.supplier_ledger (
  id           bigint generated always as identity primary key,
  station_id   uuid not null references public.stations(id) on delete cascade,
  supplier_id  uuid not null references public.suppliers(id),
  kind         public.supplier_entry_kind not null,
  amount_paisa bigint not null check (amount_paisa <> 0),
  ref_id       uuid,
  method       text,
  reference    text,
  note         text,
  created_by   uuid default auth.uid(),
  created_at   timestamptz not null default now()
);
create index supplier_ledger_supplier_idx on public.supplier_ledger(supplier_id, created_at);
create trigger supplier_ledger_append_only before update or delete on public.supplier_ledger
  for each row execute function private.append_only();

create or replace view public.supplier_balances
with (security_invoker = true)
as
select s.station_id, s.id as supplier_id, s.name,
       coalesce(sum(l.amount_paisa) filter (where l.kind in ('purchase','purchase_reversal','return')), 0)::bigint as purchases_paisa,
       coalesce(-sum(l.amount_paisa) filter (where l.kind in ('payment','payment_reversal')), 0)::bigint as payments_paisa,
       coalesce(sum(l.amount_paisa), 0)::bigint as due_paisa
from public.suppliers s
left join public.supplier_ledger l on l.supplier_id = s.id
group by s.station_id, s.id, s.name;

-- RLS (PRD §3 matrix) -----------------------------------------------------------
alter table public.items           enable row level security;
alter table public.item_costs      enable row level security;
alter table public.kit_components  enable row level security;
alter table public.stock_movements enable row level security;
alter table public.suppliers       enable row level security;
alter table public.purchases       enable row level security;
alter table public.purchase_lines  enable row level security;
alter table public.supplier_ledger enable row level security;

-- Items and prices: OW, MG, CA (mechanics get name/stock only via sync in Phase 3).
create policy items_read on public.items for select to authenticated
  using (private.has_role(station_id, array['owner','manager','cashier']::public.member_role[])
         or private.has_support_grant(station_id));
create policy kit_components_read on public.kit_components for select to authenticated
  using (private.has_role(station_id, array['owner','manager','cashier']::public.member_role[])
         or private.has_support_grant(station_id));
create policy stock_movements_read on public.stock_movements for select to authenticated
  using (private.has_role(station_id, array['owner','manager','cashier']::public.member_role[])
         or private.has_support_grant(station_id));
-- Purchase cost: owner only.
create policy item_costs_read on public.item_costs for select to authenticated
  using (private.has_role(station_id, array['owner']::public.member_role[]));
-- Purchases and suppliers: OW, MG.
create policy suppliers_read on public.suppliers for select to authenticated
  using (private.has_role(station_id, array['owner','manager']::public.member_role[])
         or private.has_support_grant(station_id));
create policy purchases_read on public.purchases for select to authenticated
  using (private.has_role(station_id, array['owner','manager']::public.member_role[])
         or private.has_support_grant(station_id));
create policy purchase_lines_read on public.purchase_lines for select to authenticated
  using (private.has_role(station_id, array['owner','manager']::public.member_role[])
         or private.has_support_grant(station_id));
create policy supplier_ledger_read on public.supplier_ledger for select to authenticated
  using (private.has_role(station_id, array['owner','manager']::public.member_role[])
         or private.has_support_grant(station_id));

revoke insert, update, delete on public.items, public.item_costs, public.kit_components, public.stock_movements,
  public.suppliers, public.purchases, public.purchase_lines, public.supplier_ledger from anon, authenticated;
grant select on public.item_stock, public.low_stock_items, public.supplier_balances to authenticated;

-- Audit (REQ-058: prices, stock, purchases) ---------------------------------------
create trigger audit_items after insert or update on public.items
  for each row execute function private.audit_row();
create trigger audit_item_costs after update on public.item_costs
  for each row execute function private.audit_row();
create trigger audit_purchases after insert or update on public.purchases
  for each row execute function private.audit_row();
create trigger audit_stock_movements after insert on public.stock_movements
  for each row execute function private.audit_row();
create trigger audit_supplier_ledger after insert on public.supplier_ledger
  for each row execute function private.audit_row();

grant execute on all functions in schema private to authenticated, service_role;

-- Functions --------------------------------------------------------------------
-- Create or update an item (REQ-028). Cost is set only through purchases or by the owner.
create or replace function public.station_save_item(
  p_station uuid,
  p_item jsonb,                 -- {id?, code, name, barcode, category, unit, is_bulk, selling_price_paisa, min_stock, warranty_days, active}
  p_components jsonb default null)  -- for kits: [{item_id, qty}]
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_id   uuid := nullif(p_item ->> 'id', '')::uuid;
  v_unit public.item_unit := coalesce(p_item ->> 'unit', 'piece')::public.item_unit;
  v_bar  text := nullif(trim(p_item ->> 'barcode'), '');
  c      jsonb;
begin
  if not private.has_role(p_station, array['owner','manager']::public.member_role[]) then
    perform private.fail('FORBIDDEN');
  end if;
  perform private.assert_can_write(p_station);

  if length(trim(coalesce(p_item ->> 'name', ''))) < 2 then
    perform private.fail('VALIDATION', 'Name missing');
  end if;
  if length(trim(coalesce(p_item ->> 'code', ''))) < 1 then
    perform private.fail('VALIDATION', 'Code missing');
  end if;
  if coalesce((p_item ->> 'selling_price_paisa')::bigint, 0) < 0 then
    perform private.fail('VALIDATION', 'Selling price cannot be negative');
  end if;
  if coalesce((p_item ->> 'is_bulk')::boolean, false) and v_unit <> 'litre' then
    perform private.fail('VALIDATION', 'Only litre items can be bulk containers');
  end if;
  if not private.valid_qty(v_unit, coalesce((p_item ->> 'min_stock')::numeric, 0)) then
    perform private.fail('VALIDATION', 'Minimum stock must be a whole number (2 decimals for litres)');
  end if;
  if exists (select 1 from public.items where station_id = p_station and code = trim(p_item ->> 'code')
             and id is distinct from v_id) then
    perform private.fail('VALIDATION', 'Another item already uses this code');
  end if;
  if v_bar is not null and exists (select 1 from public.items where station_id = p_station and barcode = v_bar
             and id is distinct from v_id) then
    perform private.fail('VALIDATION', 'Another item already uses this barcode');
  end if;

  if v_id is null then
    insert into public.items (station_id, code, name, barcode, category, unit, is_bulk,
                              selling_price_paisa, min_stock, warranty_days)
    values (p_station, trim(p_item ->> 'code'), trim(p_item ->> 'name'), v_bar,
            nullif(trim(p_item ->> 'category'), ''), v_unit,
            coalesce((p_item ->> 'is_bulk')::boolean, false),
            coalesce((p_item ->> 'selling_price_paisa')::bigint, 0),
            coalesce((p_item ->> 'min_stock')::numeric, 0),
            coalesce((p_item ->> 'warranty_days')::integer, 0))
    returning id into v_id;
    insert into public.item_costs (item_id, station_id) values (v_id, p_station);
  else
    if not exists (select 1 from public.items where id = v_id and station_id = p_station) then
      perform private.fail('NOT_FOUND');
    end if;
    if (select unit from public.items where id = v_id) <> v_unit
       and exists (select 1 from public.stock_movements where item_id = v_id) then
      perform private.fail('VALIDATION', 'Unit cannot change after stock was recorded');
    end if;
    update public.items set
      code = trim(p_item ->> 'code'), name = trim(p_item ->> 'name'), barcode = v_bar,
      category = nullif(trim(p_item ->> 'category'), ''), unit = v_unit,
      is_bulk = coalesce((p_item ->> 'is_bulk')::boolean, false),
      selling_price_paisa = coalesce((p_item ->> 'selling_price_paisa')::bigint, 0),
      min_stock = coalesce((p_item ->> 'min_stock')::numeric, 0),
      warranty_days = coalesce((p_item ->> 'warranty_days')::integer, 0),
      active = coalesce((p_item ->> 'active')::boolean, true)
    where id = v_id;
  end if;

  if v_unit = 'kit' then
    delete from public.kit_components where kit_item_id = v_id;
    for c in select * from jsonb_array_elements(coalesce(p_components, '[]'::jsonb)) loop
      if not exists (select 1 from public.items where id = (c ->> 'item_id')::uuid
                     and station_id = p_station and unit <> 'kit') then
        perform private.fail('VALIDATION', 'Kit components must be non-kit items of this station');
      end if;
      insert into public.kit_components (station_id, kit_item_id, component_item_id, qty)
      values (p_station, v_id, (c ->> 'item_id')::uuid, (c ->> 'qty')::numeric);
    end loop;
    if not exists (select 1 from public.kit_components where kit_item_id = v_id) then
      perform private.fail('VALIDATION', 'A kit needs at least one component');
    end if;
  end if;
  return v_id;
end;
$$;

-- Owner sets/corrects the cost directly (e.g. opening stock value).
create or replace function public.station_set_item_cost(p_item uuid, p_cost_paisa bigint)
returns void
language plpgsql security definer set search_path = ''
as $$
declare v_station uuid;
begin
  select station_id into v_station from public.items where id = p_item;
  if v_station is null or not private.has_role(v_station, array['owner']::public.member_role[]) then
    perform private.fail('NOT_FOUND');
  end if;
  perform private.assert_can_write(v_station);
  if p_cost_paisa < 0 then perform private.fail('VALIDATION', 'Cost cannot be negative'); end if;
  update public.item_costs set avg_cost_paisa = p_cost_paisa, updated_at = now() where item_id = p_item;
end;
$$;

-- Internal: record a stock movement after checks done by the caller.
create or replace function private.move_stock(
  p_station uuid, p_item uuid, p_qty numeric, p_kind public.stock_move_kind,
  p_ref uuid default null, p_cost bigint default null, p_note text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare v_unit public.item_unit;
begin
  select unit into v_unit from public.items where id = p_item and station_id = p_station;
  if v_unit is null then perform private.fail('NOT_FOUND', 'Item not found'); end if;
  if v_unit = 'kit' then perform private.fail('VALIDATION', 'Kits have no own stock; use their components'); end if;
  if not private.valid_qty(v_unit, p_qty) then
    perform private.fail('VALIDATION', case when v_unit = 'litre' then 'Litres allow at most 2 decimals'
                                            else 'Quantity must be a whole number' end);
  end if;
  insert into public.stock_movements (station_id, item_id, qty, kind, ref_id, unit_cost_paisa, note)
  values (p_station, p_item, p_qty, p_kind, p_ref, p_cost, p_note);
end;
$$;

create or replace function private.on_hand(p_item uuid)
returns numeric
language sql stable security definer set search_path = ''
as $$ select coalesce(sum(qty), 0) from public.stock_movements where item_id = p_item; $$;

grant execute on all functions in schema private to authenticated, service_role;

-- REQ-029: post a supplier bill. Stock up, weighted average cost, supplier due (Standard+).
create or replace function public.station_post_purchase(
  p_station uuid,
  p_supplier_id uuid,      -- Standard+ (null on Basic)
  p_supplier_name text,    -- Basic free text
  p_bill_no text,
  p_bill_date date,
  p_lines jsonb,           -- [{item_id, qty, unit_cost_paisa}]
  p_paid_now_paisa bigint default 0)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_id uuid;
  v_total bigint := 0;
  v_name text;
  l jsonb;
  v_item uuid;
  v_qty numeric;
  v_cost bigint;
  v_old_qty numeric;
  v_old_avg bigint;
  v_has_ledger boolean := private.has_feature(p_station, 'supplier_ledger');
begin
  if not private.has_role(p_station, array['owner','manager']::public.member_role[]) then
    perform private.fail('FORBIDDEN');
  end if;
  perform private.assert_can_write(p_station);
  if jsonb_array_length(coalesce(p_lines, '[]'::jsonb)) = 0 then
    perform private.fail('VALIDATION', 'Add at least one line');
  end if;

  if p_supplier_id is not null then
    if not v_has_ledger then perform private.fail('FEATURE_LOCKED', 'supplier_ledger'); end if;
    select name into v_name from public.suppliers where id = p_supplier_id and station_id = p_station;
    if v_name is null then perform private.fail('NOT_FOUND', 'Supplier not found'); end if;
  else
    v_name := nullif(trim(p_supplier_name), '');
    if v_name is null then perform private.fail('VALIDATION', 'Supplier name is required'); end if;
  end if;

  for l in select * from jsonb_array_elements(p_lines) loop
    v_qty := (l ->> 'qty')::numeric;
    v_cost := (l ->> 'unit_cost_paisa')::bigint;
    if v_qty is null or v_qty <= 0 or v_cost is null or v_cost < 0 then
      perform private.fail('VALIDATION', 'Each line needs a quantity above 0 and a price');
    end if;
    v_total := v_total + round(v_qty * v_cost)::bigint;
  end loop;
  if coalesce(p_paid_now_paisa, 0) < 0 or coalesce(p_paid_now_paisa, 0) > v_total then
    perform private.fail('VALIDATION', 'Amount paid must be between 0 and the bill total');
  end if;

  insert into public.purchases (station_id, supplier_id, supplier_name, bill_no, bill_date, total_paisa, paid_now_paisa)
  values (p_station, p_supplier_id, v_name, nullif(trim(p_bill_no), ''), coalesce(p_bill_date, current_date),
          v_total, coalesce(p_paid_now_paisa, 0))
  returning id into v_id;

  for l in select * from jsonb_array_elements(p_lines) loop
    v_item := (l ->> 'item_id')::uuid;
    v_qty := (l ->> 'qty')::numeric;
    v_cost := (l ->> 'unit_cost_paisa')::bigint;

    -- Weighted average: (old qty × old avg + new qty × new cost) / total qty.
    -- When stock is zero or negative the new cost becomes the average.
    v_old_qty := private.on_hand(v_item);
    select avg_cost_paisa into v_old_avg from public.item_costs where item_id = v_item;

    perform private.move_stock(p_station, v_item, v_qty, 'purchase', v_id, v_cost);
    insert into public.purchase_lines (station_id, purchase_id, item_id, qty, unit_cost_paisa)
    values (p_station, v_id, v_item, v_qty, v_cost);

    update public.item_costs set
      avg_cost_paisa = case when v_old_qty <= 0 then v_cost
                            else round((v_old_qty * coalesce(v_old_avg, 0) + v_qty * v_cost) / (v_old_qty + v_qty))::bigint end,
      last_cost_paisa = v_cost,
      updated_at = now()
    where item_id = v_item;
  end loop;

  if p_supplier_id is not null then
    insert into public.supplier_ledger (station_id, supplier_id, kind, amount_paisa, ref_id, note)
    values (p_station, p_supplier_id, 'purchase', v_total, v_id, 'Bill ' || coalesce(p_bill_no, ''));
    if coalesce(p_paid_now_paisa, 0) > 0 then
      insert into public.supplier_ledger (station_id, supplier_id, kind, amount_paisa, ref_id, method, note)
      values (p_station, p_supplier_id, 'payment', -p_paid_now_paisa, v_id, 'cash', 'Paid with bill');
    end if;
  end if;
  return v_id;
end;
$$;

-- REQ-029/REQ-042: reverse a posted purchase with a reason. Average cost is left as is.
create or replace function public.station_reverse_purchase(p_purchase uuid, p_reason text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  p public.purchases;
  l public.purchase_lines;
begin
  select * into p from public.purchases where id = p_purchase;
  if p.id is null or not private.has_role(p.station_id, array['owner','manager']::public.member_role[]) then
    perform private.fail('NOT_FOUND');
  end if;
  perform private.assert_can_write(p.station_id);
  if p.status = 'reversed' then perform private.fail('VALIDATION', 'Already reversed'); end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then
    perform private.fail('VALIDATION', 'A reason is required');
  end if;

  for l in select * from public.purchase_lines where purchase_id = p_purchase loop
    perform private.move_stock(p.station_id, l.item_id, -l.qty, 'purchase_reversal', p_purchase, l.unit_cost_paisa, p_reason);
  end loop;
  if p.supplier_id is not null then
    insert into public.supplier_ledger (station_id, supplier_id, kind, amount_paisa, ref_id, note)
    values (p.station_id, p.supplier_id, 'purchase_reversal', -p.total_paisa, p_purchase, p_reason);
    if p.paid_now_paisa > 0 then
      insert into public.supplier_ledger (station_id, supplier_id, kind, amount_paisa, ref_id, note)
      values (p.station_id, p.supplier_id, 'payment_reversal', p.paid_now_paisa, p_purchase, p_reason);
    end if;
  end if;
  update public.purchases set status = 'reversed', reversal_reason = trim(p_reason),
    reversed_at = now(), reversed_by = auth.uid()
  where id = p_purchase;
end;
$$;

-- REQ-030 (Standard+) -----------------------------------------------------------
create or replace function public.station_save_supplier(p_station uuid, p_id uuid, p_name text, p_phone text, p_active boolean default true)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_id uuid := p_id;
begin
  if not private.has_role(p_station, array['owner','manager']::public.member_role[]) then
    perform private.fail('FORBIDDEN');
  end if;
  perform private.assert_can_write(p_station, 'supplier_ledger');
  if length(trim(coalesce(p_name, ''))) < 2 then perform private.fail('VALIDATION', 'Supplier name is required'); end if;
  if exists (select 1 from public.suppliers where station_id = p_station and lower(name) = lower(trim(p_name))
             and id is distinct from p_id) then
    perform private.fail('VALIDATION', 'A supplier with this name exists');
  end if;
  if v_id is null then
    insert into public.suppliers (station_id, name, phone) values (p_station, trim(p_name), nullif(trim(p_phone), ''))
    returning id into v_id;
  else
    update public.suppliers set name = trim(p_name), phone = nullif(trim(p_phone), ''), active = coalesce(p_active, true)
    where id = v_id and station_id = p_station;
    if not found then perform private.fail('NOT_FOUND'); end if;
  end if;
  return v_id;
end;
$$;

create or replace function public.station_pay_supplier(
  p_supplier uuid, p_amount_paisa bigint, p_method text, p_reference text default null, p_note text default null)
returns bigint
language plpgsql security definer set search_path = ''
as $$
declare
  v_station uuid;
  v_id bigint;
begin
  select station_id into v_station from public.suppliers where id = p_supplier;
  if v_station is null or not private.has_role(v_station, array['owner','manager']::public.member_role[]) then
    perform private.fail('NOT_FOUND');
  end if;
  perform private.assert_can_write(v_station, 'supplier_ledger');
  if coalesce(p_amount_paisa, 0) <= 0 then perform private.fail('VALIDATION', 'Amount must be above 0'); end if;
  if p_method not in ('cash', 'bank', 'jazzcash', 'easypaisa', 'card', 'cheque') then
    perform private.fail('VALIDATION', 'Choose a payment method');
  end if;
  insert into public.supplier_ledger (station_id, supplier_id, kind, amount_paisa, method, reference, note)
  values (v_station, p_supplier, 'payment', -p_amount_paisa, p_method, nullif(trim(p_reference), ''), nullif(trim(p_note), ''))
  returning id into v_id;
  return v_id;
end;
$$;

-- Function grants -------------------------------------------------------------------
revoke execute on function
  public.station_save_item(uuid, jsonb, jsonb),
  public.station_set_item_cost(uuid, bigint),
  public.station_post_purchase(uuid, uuid, text, text, date, jsonb, bigint),
  public.station_reverse_purchase(uuid, text),
  public.station_save_supplier(uuid, uuid, text, text, boolean),
  public.station_pay_supplier(uuid, bigint, text, text, text)
from public, anon;
grant execute on function
  public.station_save_item(uuid, jsonb, jsonb),
  public.station_set_item_cost(uuid, bigint),
  public.station_post_purchase(uuid, uuid, text, text, date, jsonb, bigint),
  public.station_reverse_purchase(uuid, text),
  public.station_save_supplier(uuid, uuid, text, text, boolean),
  public.station_pay_supplier(uuid, bigint, text, text, text)
to authenticated;

-- ===== supabase/migrations/20261114000008_approvals.sql =====
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

-- ===== supabase/migrations/20261114000009_customers.sql =====
-- TASK-026, TASK-028 · REQ-046, REQ-048
-- Customers and vehicles per station; search by phone, plate or name.

create table public.customers (
  id         uuid primary key default gen_random_uuid(),
  station_id uuid not null references public.stations(id) on delete cascade,
  name       text not null check (length(trim(name)) between 2 and 120),
  mobile     text not null check (mobile ~ '^03[0-9]{9}$'),
  email      text check (email is null or email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  address    text,
  created_at timestamptz not null default now(),
  unique (station_id, mobile)
);
create index customers_name_idx on public.customers(station_id, lower(name));

create table public.vehicles (
  id          uuid primary key default gen_random_uuid(),
  station_id  uuid not null references public.stations(id) on delete cascade,
  customer_id uuid not null references public.customers(id),
  plate       text not null check (plate ~ '^[A-Z0-9]+(-[A-Z0-9]+)*$'),
  make        text,
  model       text,
  year        integer check (year is null or year between 1950 and 2100),
  colour      text,
  created_at  timestamptz not null default now(),
  unique (station_id, plate)
);
create index vehicles_customer_idx on public.vehicles(customer_id);

-- Ownership history (REQ-046: a vehicle can move to another customer).
create table public.vehicle_owner_history (
  id               bigint generated always as identity primary key,
  station_id       uuid not null references public.stations(id) on delete cascade,
  vehicle_id       uuid not null references public.vehicles(id) on delete cascade,
  from_customer_id uuid references public.customers(id),
  to_customer_id   uuid not null references public.customers(id),
  changed_by       uuid default auth.uid(),
  changed_at       timestamptz not null default now()
);

alter table public.customers             enable row level security;
alter table public.vehicles              enable row level security;
alter table public.vehicle_owner_history enable row level security;

-- OW, MG, CA. Mechanics see the vehicle on their assigned job (Phase 3, via sync).
create policy customers_read on public.customers for select to authenticated
  using (private.has_role(station_id, array['owner','manager','cashier']::public.member_role[])
         or private.has_support_grant(station_id));
create policy vehicles_read on public.vehicles for select to authenticated
  using (private.has_role(station_id, array['owner','manager','cashier']::public.member_role[])
         or private.has_support_grant(station_id));
create policy vehicle_owner_history_read on public.vehicle_owner_history for select to authenticated
  using (private.has_role(station_id, array['owner','manager','cashier']::public.member_role[])
         or private.has_support_grant(station_id));
revoke insert, update, delete on public.customers, public.vehicles, public.vehicle_owner_history from anon, authenticated;

create trigger audit_customers after insert or update on public.customers
  for each row execute function private.audit_row();
create trigger audit_vehicles after insert or update on public.vehicles
  for each row execute function private.audit_row();

-- Same rule as packages/core normalizePlate: upper case, single dashes between letter/digit runs.
create or replace function private.normalize_plate(p_raw text)
returns text
language plpgsql immutable
as $$
declare
  t text;
  parts text[];
begin
  t := upper(coalesce(p_raw, ''));
  t := regexp_replace(t, '([A-Z])([0-9])', '\1-\2', 'g');
  t := regexp_replace(t, '([0-9])([A-Z])', '\1-\2', 'g');
  t := regexp_replace(t, '[^A-Z0-9]+', '-', 'g');
  t := trim(both '-' from t);
  if t !~ '^[A-Z]{1,4}(-[A-Z0-9]{1,4}){1,3}$' or t !~ '[0-9]' or length(replace(t, '-', '')) > 10 then
    return null;
  end if;
  return t;
end;
$$;
grant execute on all functions in schema private to authenticated, service_role;

create or replace function public.station_save_customer(
  p_station uuid, p_id uuid, p_name text, p_mobile text, p_email text default null, p_address text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_id uuid := p_id;
  v_mobile text := private.normalize_pk_mobile(p_mobile);
begin
  if not private.has_role(p_station, array['owner','manager','cashier']::public.member_role[]) then
    perform private.fail('FORBIDDEN');
  end if;
  perform private.assert_can_write(p_station);
  if length(trim(coalesce(p_name, ''))) < 2 then perform private.fail('VALIDATION', 'Name missing'); end if;
  if v_mobile is null then perform private.fail('VALIDATION', 'Mobile must be like 0300-1234567'); end if;
  if nullif(trim(p_email), '') is not null and trim(p_email) !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    perform private.fail('VALIDATION', 'Email is not valid');
  end if;
  if exists (select 1 from public.customers where station_id = p_station and mobile = v_mobile and id is distinct from p_id) then
    perform private.fail('VALIDATION', 'A customer with this mobile already exists');
  end if;

  if v_id is null then
    insert into public.customers (station_id, name, mobile, email, address)
    values (p_station, trim(p_name), v_mobile, nullif(trim(p_email), ''), nullif(trim(p_address), ''))
    returning id into v_id;
  else
    update public.customers set name = trim(p_name), mobile = v_mobile,
      email = nullif(trim(p_email), ''), address = nullif(trim(p_address), '')
    where id = v_id and station_id = p_station;
    if not found then perform private.fail('NOT_FOUND'); end if;
  end if;
  return v_id;
end;
$$;

create or replace function public.station_save_vehicle(
  p_station uuid, p_id uuid, p_customer uuid, p_plate text,
  p_make text default null, p_model text default null, p_year integer default null, p_colour text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_id uuid := p_id;
  v_plate text := private.normalize_plate(p_plate);
  v_old_customer uuid;
begin
  if not private.has_role(p_station, array['owner','manager','cashier']::public.member_role[]) then
    perform private.fail('FORBIDDEN');
  end if;
  perform private.assert_can_write(p_station);
  if v_plate is null then perform private.fail('VALIDATION', 'Number plate is not valid (e.g. LEA-1234)'); end if;
  if not exists (select 1 from public.customers where id = p_customer and station_id = p_station) then
    perform private.fail('NOT_FOUND', 'Customer not found');
  end if;
  if exists (select 1 from public.vehicles where station_id = p_station and plate = v_plate and id is distinct from p_id) then
    perform private.fail('VALIDATION', 'This plate is already registered');
  end if;

  if v_id is null then
    insert into public.vehicles (station_id, customer_id, plate, make, model, year, colour)
    values (p_station, p_customer, v_plate, nullif(trim(p_make), ''), nullif(trim(p_model), ''), p_year, nullif(trim(p_colour), ''))
    returning id into v_id;
    insert into public.vehicle_owner_history (station_id, vehicle_id, from_customer_id, to_customer_id)
    values (p_station, v_id, null, p_customer);
  else
    select customer_id into v_old_customer from public.vehicles where id = v_id and station_id = p_station;
    if not found then perform private.fail('NOT_FOUND'); end if;
    update public.vehicles set customer_id = p_customer, plate = v_plate, make = nullif(trim(p_make), ''),
      model = nullif(trim(p_model), ''), year = p_year, colour = nullif(trim(p_colour), '')
    where id = v_id;
    if v_old_customer <> p_customer then
      insert into public.vehicle_owner_history (station_id, vehicle_id, from_customer_id, to_customer_id)
      values (p_station, v_id, v_old_customer, p_customer);
    end if;
  end if;
  return v_id;
end;
$$;

-- REQ-046: search by phone digits, plate part or name. Runs with the caller's rights (RLS).
create or replace function public.station_search_customers(p_station uuid, p_query text, p_limit integer default 30)
returns table (customer_id uuid, name text, mobile text, vehicle_id uuid, plate text, make text, model text)
language sql stable security invoker set search_path = ''
as $$
  with q as (
    select trim(coalesce(p_query, '')) as raw,
           regexp_replace(coalesce(p_query, ''), '[^0-9]', '', 'g') as digits,
           upper(regexp_replace(coalesce(p_query, ''), '[^A-Za-z0-9]', '', 'g')) as plate_key
  )
  select c.id, c.name, c.mobile, v.id, v.plate, v.make, v.model
  from public.customers c
  left join public.vehicles v on v.customer_id = c.id
  cross join q
  where c.station_id = p_station
    and length(q.raw) >= 2
    and (
      (length(q.digits) >= 3 and right(c.mobile, 10) like '%' || ltrim(q.digits, '0') || '%')
      or (length(q.plate_key) >= 2 and replace(v.plate, '-', '') like '%' || q.plate_key || '%')
      or lower(c.name) like '%' || lower(q.raw) || '%'
    )
  order by c.name, v.plate
  limit greatest(1, least(coalesce(p_limit, 30), 100));
$$;

-- REQ-048: vehicle timeline, newest first. Jobs and invoices join this in Phase 3/4;
-- until then it shows registration and ownership changes.
create or replace function public.station_vehicle_history(p_vehicle uuid)
returns table (at timestamptz, kind text, title text, odometer integer, total_paisa bigint, ref_id uuid)
language sql stable security invoker set search_path = ''
as $$
  select h.changed_at, 'owner',
         case when h.from_customer_id is null then 'Registered to ' || c.name else 'Owner changed to ' || c.name end,
         null::integer, null::bigint, h.to_customer_id
  from public.vehicle_owner_history h
  join public.customers c on c.id = h.to_customer_id
  where h.vehicle_id = p_vehicle
  order by h.changed_at desc, h.id desc;
$$;

revoke execute on function
  public.station_save_customer(uuid, uuid, text, text, text, text),
  public.station_save_vehicle(uuid, uuid, uuid, text, text, text, integer, text),
  public.station_search_customers(uuid, text, integer),
  public.station_vehicle_history(uuid)
from public, anon;
grant execute on function
  public.station_save_customer(uuid, uuid, text, text, text, text),
  public.station_save_vehicle(uuid, uuid, uuid, text, text, text, integer, text),
  public.station_search_customers(uuid, text, integer),
  public.station_vehicle_history(uuid)
to authenticated;

-- ===== supabase/migrations/20261114000010_import.sql =====
-- TASK-027 · REQ-034
-- Excel import: the app reads the sheet and sends rows as JSON; the database validates
-- each row and returns imported / rejected counts with a reason per rejected row.
-- Re-importing the same item code (or customer mobile) updates instead of duplicating.

-- Items: [{row, code, name, barcode, category, unit, selling_price, purchase_price, min_stock, opening_qty, warranty_days}]
-- Prices are in rupees (as typed in Excel); stored as paisa.
create or replace function public.station_import_items(p_station uuid, p_rows jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  r jsonb;
  v_row integer;
  v_id uuid;
  v_exists boolean;
  v_unit public.item_unit;
  v_open numeric;
  v_cost bigint;
  v_added integer := 0;
  v_updated integer := 0;
  v_rejected jsonb := '[]'::jsonb;
  v_reason text;
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then
    perform private.fail('FORBIDDEN');
  end if;
  perform private.assert_can_write(p_station);
  if jsonb_array_length(coalesce(p_rows, '[]'::jsonb)) > 5000 then
    perform private.fail('VALIDATION', 'At most 5,000 rows per import');
  end if;

  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    v_row := coalesce((r ->> 'row')::integer, 0);
    v_reason := null;
    begin
      -- Each row in its own sub-transaction: a bad row is rejected, the rest continue.
      if length(trim(coalesce(r ->> 'name', ''))) < 2 then v_reason := 'Name missing';
      elsif length(trim(coalesce(r ->> 'code', ''))) < 1 then v_reason := 'Code missing';
      elsif lower(coalesce(nullif(trim(r ->> 'unit'), ''), 'piece')) not in ('piece', 'litre', 'kit') then
        v_reason := 'Unit must be piece, litre or kit';
      elsif lower(coalesce(nullif(trim(r ->> 'unit'), ''), 'piece')) = 'kit' then
        v_reason := 'Kits must be created in the app (they need components)';
      elsif (r ->> 'selling_price') is not null and (r ->> 'selling_price') !~ '^\s*[0-9]+(\.[0-9]{1,2})?\s*$' then
        v_reason := 'Selling price must be a number';
      elsif (r ->> 'purchase_price') is not null and (r ->> 'purchase_price') !~ '^\s*[0-9]+(\.[0-9]{1,2})?\s*$' then
        v_reason := 'Purchase price must be a number';
      elsif (r ->> 'opening_qty') is not null and (r ->> 'opening_qty') !~ '^\s*-?[0-9]+(\.[0-9]{1,3})?\s*$' then
        v_reason := 'Opening quantity must be a number';
      end if;

      if v_reason is null then
        v_unit := lower(coalesce(nullif(trim(r ->> 'unit'), ''), 'piece'))::public.item_unit;
        v_open := coalesce(nullif(trim(r ->> 'opening_qty'), '')::numeric, 0);
        if not private.valid_qty(v_unit, v_open) then
          v_reason := case when v_unit = 'litre' then 'Litres allow at most 2 decimals' else 'Quantity must be a whole number' end;
        end if;
      end if;

      if v_reason is not null then
        v_rejected := v_rejected || jsonb_build_object('row', v_row, 'reason', v_reason);
        continue;
      end if;

      select id into v_id from public.items where station_id = p_station and code = trim(r ->> 'code');
      v_exists := v_id is not null;

      v_id := public.station_save_item(p_station, jsonb_build_object(
        'id', v_id,
        'code', trim(r ->> 'code'),
        'name', trim(r ->> 'name'),
        'barcode', r ->> 'barcode',
        'category', r ->> 'category',
        'unit', v_unit,
        'is_bulk', v_unit = 'litre',
        'selling_price_paisa', round(coalesce(nullif(trim(r ->> 'selling_price'), '')::numeric, 0) * 100),
        'min_stock', coalesce(nullif(trim(r ->> 'min_stock'), '')::numeric, 0),
        'warranty_days', coalesce(nullif(trim(r ->> 'warranty_days'), '')::integer, 0)));

      v_cost := round(coalesce(nullif(trim(r ->> 'purchase_price'), '')::numeric, 0) * 100);
      if nullif(trim(r ->> 'purchase_price'), '') is not null then
        update public.item_costs set avg_cost_paisa = v_cost, last_cost_paisa = v_cost, updated_at = now()
        where item_id = v_id;
      end if;

      -- Opening stock only for new items; existing items keep their movement history.
      if not v_exists and v_open <> 0 then
        perform private.move_stock(p_station, v_id, v_open, 'opening', null, v_cost, 'Excel import');
      end if;

      if v_exists then v_updated := v_updated + 1; else v_added := v_added + 1; end if;
    exception when others then
      get stacked diagnostics v_reason = pg_exception_detail;
      v_rejected := v_rejected || jsonb_build_object('row', v_row, 'reason', coalesce(nullif(v_reason, ''), sqlerrm));
    end;
  end loop;

  return jsonb_build_object('added', v_added, 'updated', v_updated,
                            'rejected', jsonb_array_length(v_rejected), 'rejected_rows', v_rejected);
end;
$$;

-- Customers and vehicles: [{row, name, mobile, email, address, plate, make, model, year, colour}]
create or replace function public.station_import_customers(p_station uuid, p_rows jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  r jsonb;
  v_row integer;
  v_customer uuid;
  v_vehicle uuid;
  v_mobile text;
  v_plate text;
  v_exists boolean;
  v_added integer := 0;
  v_updated integer := 0;
  v_rejected jsonb := '[]'::jsonb;
  v_reason text;
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then
    perform private.fail('FORBIDDEN');
  end if;
  perform private.assert_can_write(p_station);
  if jsonb_array_length(coalesce(p_rows, '[]'::jsonb)) > 5000 then
    perform private.fail('VALIDATION', 'At most 5,000 rows per import');
  end if;

  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    v_row := coalesce((r ->> 'row')::integer, 0);
    v_mobile := private.normalize_pk_mobile(r ->> 'mobile');
    v_plate := case when nullif(trim(r ->> 'plate'), '') is null then null else private.normalize_plate(r ->> 'plate') end;
    if length(trim(coalesce(r ->> 'name', ''))) < 2 then
      v_rejected := v_rejected || jsonb_build_object('row', v_row, 'reason', 'Name missing'); continue;
    elsif v_mobile is null then
      v_rejected := v_rejected || jsonb_build_object('row', v_row, 'reason', 'Mobile must be like 0300-1234567'); continue;
    elsif nullif(trim(r ->> 'plate'), '') is not null and v_plate is null then
      v_rejected := v_rejected || jsonb_build_object('row', v_row, 'reason', 'Number plate is not valid'); continue;
    end if;
    begin
      select id into v_customer from public.customers where station_id = p_station and mobile = v_mobile;
      v_exists := v_customer is not null;
      v_customer := public.station_save_customer(p_station, v_customer, r ->> 'name', v_mobile, r ->> 'email', r ->> 'address');
      if v_plate is not null then
        select id into v_vehicle from public.vehicles where station_id = p_station and plate = v_plate;
        perform public.station_save_vehicle(p_station, v_vehicle, v_customer, v_plate,
          r ->> 'make', r ->> 'model', nullif(trim(r ->> 'year'), '')::integer, r ->> 'colour');
      end if;
      if v_exists then v_updated := v_updated + 1; else v_added := v_added + 1; end if;
    exception when others then
      get stacked diagnostics v_reason = pg_exception_detail;
      v_rejected := v_rejected || jsonb_build_object('row', v_row, 'reason', coalesce(nullif(v_reason, ''), sqlerrm));
    end;
  end loop;

  return jsonb_build_object('added', v_added, 'updated', v_updated,
                            'rejected', jsonb_array_length(v_rejected), 'rejected_rows', v_rejected);
end;
$$;

revoke execute on function public.station_import_items(uuid, jsonb), public.station_import_customers(uuid, jsonb)
  from public, anon;
grant execute on function public.station_import_items(uuid, jsonb), public.station_import_customers(uuid, jsonb)
  to authenticated;

-- ===== supabase/migrations/20261115000011_jobs.sql =====
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

-- ===== supabase/migrations/20261115000012_rework_warranty.sql =====
-- TASK-037 · REQ-026, REQ-027
-- Rework (comeback) jobs and warranty claims, linked to the original job.
-- Until invoices exist (Phase 4) the warranty period counts from the original job's delivery.

create or replace function private.new_job_from(
  p_parent public.job_cards, p_kind public.job_kind, p_parts_free boolean,
  p_odometer integer, p_fuel public.fuel_level, p_complaints text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_no integer;
  v_id uuid;
begin
  insert into public.job_counters (station_id) values (p_parent.station_id) on conflict do nothing;
  update public.job_counters set last_no = last_no + 1 where station_id = p_parent.station_id returning last_no into v_no;
  insert into public.job_cards (station_id, job_no, kind, parent_job_id, customer_id, vehicle_id, odometer_km,
                                fuel_level, complaints, parts_free)
  select p_parent.station_id, v_no, p_kind, p_parent.id, v.customer_id, p_parent.vehicle_id,
         coalesce(p_odometer, p_parent.odometer_km), coalesce(p_fuel, p_parent.fuel_level),
         nullif(trim(p_complaints), ''), coalesce(p_parts_free, false)
  from public.vehicles v where v.id = p_parent.vehicle_id
  returning id into v_id;
  insert into public.job_checklist_items (station_id, job_id, name, sort_order)
  select p_parent.station_id, v_id, t.name, t.sort_order from public.checklist_templates t
  where t.station_id = p_parent.station_id and t.active order by t.sort_order;
  perform private.log_job(p_parent.station_id, v_id, 'stage', null, 'intake',
    format('%s of job %s', initcap(p_kind::text), p_parent.job_no));
  return v_id;
end;
$$;
grant execute on all functions in schema private to authenticated, service_role;

-- REQ-026: labour is free; parts charged or free as chosen; counts against the original mechanics.
create or replace function public.station_create_rework(
  p_parent uuid, p_parts_free boolean, p_odometer integer, p_fuel public.fuel_level, p_complaints text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  j public.job_cards := private.job_for(p_parent, array['owner','manager','cashier']::public.member_role[]);
begin
  perform private.assert_can_write(j.station_id);
  if j.stage <> 'delivered' then perform private.fail('VALIDATION', 'Rework is created from a delivered job'); end if;
  if length(trim(coalesce(p_complaints, ''))) < 3 then perform private.fail('VALIDATION', 'Describe the problem'); end if;
  return private.new_job_from(j, 'rework', p_parts_free, p_odometer, p_fuel, p_complaints);
end;
$$;

-- REQ-027: warranty status of an original line.
create or replace function public.station_warranty_status(p_line uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  l public.job_lines;
  j public.job_cards;
  v_expires date;
begin
  select * into l from public.job_lines where id = p_line;
  if l.id is null then perform private.fail('NOT_FOUND'); end if;
  j := private.job_for(l.job_id, array['owner','manager','cashier']::public.member_role[]);
  if j.stage <> 'delivered' or l.status <> 'approved' or l.warranty_days <= 0 then
    return jsonb_build_object('valid', false, 'reason', 'No warranty on this line');
  end if;
  v_expires := (j.delivered_at at time zone 'Asia/Karachi')::date + l.warranty_days;
  return jsonb_build_object(
    'valid', current_date <= v_expires,
    'expires_on', v_expires,
    'days_left', greatest(v_expires - (now() at time zone 'Asia/Karachi')::date, 0),
    'sold_on', (j.delivered_at at time zone 'Asia/Karachi')::date,
    'original_job_no', j.job_no);
end;
$$;

-- REQ-027: claim. Inside the period: labour free, replacement part charged 0. The faulty
-- part may go back to the supplier, which lowers the supplier due (Standard+).
create or replace function public.station_create_warranty_claim(
  p_line uuid, p_odometer integer, p_fuel public.fuel_level, p_complaints text,
  p_return_supplier uuid default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  l public.job_lines;
  j public.job_cards;
  w jsonb;
  v_job uuid;
  v_cost bigint;
begin
  select * into l from public.job_lines where id = p_line;
  if l.id is null then perform private.fail('NOT_FOUND'); end if;
  j := private.job_for(l.job_id, array['owner','manager','cashier']::public.member_role[]);
  perform private.assert_can_write(j.station_id);
  w := public.station_warranty_status(p_line);
  if not (w ->> 'valid')::boolean then
    if w ? 'expires_on' then
      perform private.fail('WARRANTY_EXPIRED', format('Warranty expired on %s', to_char((w ->> 'expires_on')::date, 'DD-MM-YYYY')));
    end if;
    perform private.fail('VALIDATION', w ->> 'reason');
  end if;

  v_job := private.new_job_from(j, 'warranty', true, p_odometer, p_fuel,
    coalesce(nullif(trim(p_complaints), ''), 'Warranty claim: ' || l.description));
  insert into public.job_lines (station_id, job_id, kind, item_id, description, qty, unit_price_paisa, status,
                                warranty_days, warranty_of_line)
  values (j.station_id, v_job, l.kind, l.item_id, l.description || ' (warranty)', l.qty, 0, 'estimate', l.warranty_days, l.id);

  if p_return_supplier is not null then
    if l.kind <> 'part' then perform private.fail('VALIDATION', 'Only parts go back to a supplier'); end if;
    if not private.has_feature(j.station_id, 'supplier_ledger') then perform private.fail('FEATURE_LOCKED', 'supplier_ledger'); end if;
    if not exists (select 1 from public.suppliers where id = p_return_supplier and station_id = j.station_id) then
      perform private.fail('NOT_FOUND', 'Supplier not found');
    end if;
    select avg_cost_paisa into v_cost from public.item_costs where item_id = l.item_id;
    if coalesce(v_cost, 0) > 0 then
      insert into public.supplier_ledger (station_id, supplier_id, kind, amount_paisa, ref_id, note)
      values (j.station_id, p_return_supplier, 'return', -round(v_cost * l.qty)::bigint, v_job,
              'Faulty part returned: ' || l.description);
    end if;
  end if;
  return v_job;
end;
$$;

revoke execute on function
  public.station_create_rework(uuid, boolean, integer, public.fuel_level, text),
  public.station_warranty_status(uuid),
  public.station_create_warranty_claim(uuid, integer, public.fuel_level, text, uuid)
from public, anon;
grant execute on function
  public.station_create_rework(uuid, boolean, integer, public.fuel_level, text),
  public.station_warranty_status(uuid),
  public.station_create_warranty_claim(uuid, integer, public.fuel_level, text, uuid)
to authenticated;

-- ===== supabase/migrations/20261115000013_sync.sql =====
-- TASK-034 · REQ-023 · DEC-031 (own sync engine; PowerSync later behind the same interface)
-- sync_pull: everything a mechanic's phone needs offline — assigned open jobs, their
--            checklist and part lines (no prices), and the item list (name, unit, stock).
-- sync_apply: queued phone changes, applied in order through the same rules as online.
--   * idempotent by client_change_id (a repeat is reported as "duplicate")
--   * last change wins by client time; the loser is kept in history and managers are told
--   * changes refused because the station is read-only come back as "held" (kept on the phone)

create table public.sync_changes (
  client_change_id uuid primary key,
  station_id       uuid not null references public.stations(id) on delete cascade,
  user_id          uuid not null default auth.uid(),
  op               text not null,
  status           text not null,       -- applied | conflict | rejected
  message          text,
  client_time      timestamptz,
  applied_at       timestamptz not null default now()
);
alter table public.sync_changes enable row level security;
create policy sync_changes_read on public.sync_changes for select to authenticated
  using (user_id = auth.uid() or private.has_role(station_id, array['owner','manager']::public.member_role[]));
revoke insert, update, delete on public.sync_changes from anon, authenticated;

create or replace function public.sync_pull(p_station uuid, p_since timestamptz default null)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_jobs uuid[];
begin
  if not private.has_role(p_station, array['owner','manager','cashier','mechanic']::public.member_role[]) then
    perform private.fail('FORBIDDEN');
  end if;
  -- Full snapshot of the (small) open set each time; p_since is reserved for delta pulls.
  select coalesce(array_agg(j.id), '{}') into v_jobs
  from public.job_cards j
  join public.job_assignments a on a.job_id = j.id and a.user_id = v_uid
  where j.station_id = p_station and j.stage in ('approved', 'in_progress', 'quality_check');

  return jsonb_build_object(
    'server_time', now(),
    'jobs', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', j.id, 'job_no', j.job_no, 'kind', j.kind, 'stage', j.stage, 'complaints', j.complaints,
        'odometer_km', j.odometer_km, 'fuel_level', j.fuel_level, 'qc_note', j.qc_note,
        'expected_delivery', j.expected_delivery, 'updated_at', j.updated_at,
        'customer_name', c.name, 'plate', v.plate, 'make', v.make, 'model', v.model, 'year', v.year)
        order by j.job_no)
      from public.job_cards j
      join public.customers c on c.id = j.customer_id
      join public.vehicles v on v.id = j.vehicle_id
      where j.id = any(v_jobs)), '[]'::jsonb),
    'checklist', coalesce((
      select jsonb_agg(jsonb_build_object('id', k.id, 'job_id', k.job_id, 'name', k.name, 'sort_order', k.sort_order,
                                          'status', k.status, 'note', k.note, 'changed_at', k.changed_at)
                       order by k.job_id, k.sort_order)
      from public.job_checklist_items k where k.job_id = any(v_jobs)), '[]'::jsonb),
    -- No prices for mechanics (REQ-002).
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object('id', l.id, 'job_id', l.job_id, 'kind', l.kind, 'item_id', l.item_id,
                                          'description', l.description, 'qty', l.qty, 'status', l.status,
                                          'mine', l.added_by = v_uid) order by l.created_at)
      from public.job_lines l where l.job_id = any(v_jobs) and l.status not in ('removed', 'rejected')), '[]'::jsonb),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object('id', i.id, 'code', i.code, 'name', i.name, 'unit', i.unit,
                                          'barcode', i.barcode, 'on_hand', s.on_hand) order by i.name)
      from public.items i join public.item_stock s on s.item_id = i.id
      where i.station_id = p_station and i.active), '[]'::jsonb));
end;
$$;

-- Last stage change time for the conflict rule (client time when it came from a phone).
create or replace function private.last_stage_time(p_job uuid)
returns timestamptz
language sql stable security definer set search_path = ''
as $$
  select max(coalesce(h.client_time, h.created_at)) from public.job_history h
  where h.job_id = p_job and h.field in ('stage', 'qc') and not h.conflict;
$$;
grant execute on all functions in schema private to authenticated, service_role;

-- p_changes: [{client_change_id, client_time, op, args}] in the order they were made.
--   op 'check'       args {check_id, status, note}
--   op 'stage'       args {job_id, stage}
--   op 'part_add'    args {line_id, job_id, item_id, qty}
--   op 'part_remove' args {line_id}
create or replace function public.sync_apply(p_station uuid, p_changes jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  ch jsonb;
  a jsonb;
  v_id uuid;
  v_time timestamptz;
  v_op text;
  v_status text;
  v_msg text;
  v_detail text;
  v_out jsonb := '[]'::jsonb;
  j public.job_cards;
begin
  if not private.has_role(p_station, array['owner','manager','cashier','mechanic']::public.member_role[]) then
    perform private.fail('FORBIDDEN');
  end if;
  if jsonb_array_length(coalesce(p_changes, '[]'::jsonb)) > 500 then
    perform private.fail('VALIDATION', 'At most 500 changes per sync');
  end if;

  for ch in select * from jsonb_array_elements(coalesce(p_changes, '[]'::jsonb)) loop
    v_id := (ch ->> 'client_change_id')::uuid;
    v_time := coalesce((ch ->> 'client_time')::timestamptz, now());
    v_op := ch ->> 'op';
    a := coalesce(ch -> 'args', '{}'::jsonb);
    v_msg := null;

    if exists (select 1 from public.sync_changes where client_change_id = v_id) then
      v_out := v_out || jsonb_build_object('client_change_id', v_id, 'status', 'duplicate');
      continue;
    end if;

    begin
      -- A phone clock far in the future must not win every conflict.
      if v_time > now() + interval '5 minutes' then v_time := now(); end if;

      if v_op = 'check' then
        v_status := private.set_check((a ->> 'check_id')::uuid, (a ->> 'status')::public.check_status, a ->> 'note', v_time, 'sync');
      elsif v_op = 'stage' then
        select * into j from public.job_cards where id = (a ->> 'job_id')::uuid and station_id = p_station;
        if j.id is null then perform private.fail('NOT_FOUND', 'Job card not found'); end if;
        if private.last_stage_time(j.id) > v_time then
          perform private.log_job(p_station, j.id, 'stage', j.stage::text, a ->> 'stage',
            'Offline stage change lost to a later change', v_time, 'sync', true);
          perform private.notify(p_station, null, 'conflict', 'Offline change overwritten',
            format('Job %s: stage %s from a phone was older than the current %s', j.job_no, a ->> 'stage', j.stage), j.id);
          v_status := 'conflict';
        else
          perform private.set_stage(j.id, (a ->> 'stage')::public.job_stage, null, v_time, 'sync');
          v_status := 'applied';
        end if;
      elsif v_op = 'part_add' then
        perform private.add_line((a ->> 'job_id')::uuid, 'part', (a ->> 'item_id')::uuid, null,
          (a ->> 'qty')::numeric, null, (a ->> 'line_id')::uuid, null, v_time, 'sync');
        v_status := 'applied';
      elsif v_op = 'part_remove' then
        perform private.remove_line((a ->> 'line_id')::uuid, v_time, 'sync');
        v_status := 'applied';
      else
        perform private.fail('VALIDATION', 'Unknown change type ' || coalesce(v_op, ''));
      end if;
    exception when others then
      get stacked diagnostics v_detail = pg_exception_detail;
      if sqlerrm = 'READ_ONLY' then
        -- Not recorded: the phone keeps it and retries when the plan is active again (REQ-009).
        v_out := v_out || jsonb_build_object('client_change_id', v_id, 'status', 'held', 'message', v_detail);
        continue;
      end if;
      v_status := 'rejected';
      v_msg := coalesce(nullif(v_detail, ''), sqlerrm);
    end;

    insert into public.sync_changes (client_change_id, station_id, op, status, message, client_time)
    values (v_id, p_station, coalesce(v_op, '?'), v_status, v_msg, v_time);
    v_out := v_out || jsonb_build_object('client_change_id', v_id, 'status', v_status, 'message', v_msg);
  end loop;
  return v_out;
end;
$$;

revoke execute on function public.sync_pull(uuid, timestamptz), public.sync_apply(uuid, jsonb) from public, anon;
grant execute on function public.sync_pull(uuid, timestamptz), public.sync_apply(uuid, jsonb) to authenticated;

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

-- ===== supabase/migrations/20261117000016_subscription.sql =====
-- TASK-047…052 · REQ-007, REQ-008, REQ-009, REQ-010, REQ-012, REQ-013
-- Subscription payments (wallet/card through a provider webhook; bank/cash verified by
-- the super admin), trial reminders and extension, upgrade with proration, downgrade at
-- renewal, suspension, super-admin tenant views, account closing and 90-day deletion.

alter table public.subscriptions
  add column pending_plan_code text references public.plans(code),   -- downgrade at next renewal
  add column suspended_from public.subscription_state,                -- state to return to
  add column suspend_reason text,
  add column closed_at timestamptz,
  add column deletion_due_at timestamptz;

create type public.sub_pay_method as enum ('jazzcash', 'easypaisa', 'card', 'bank', 'cash');
create type public.sub_pay_status as enum ('pending', 'pending_verification', 'succeeded', 'failed', 'rejected');
create sequence public.platform_receipt_no start 1;

create table public.subscription_payments (
  id               uuid primary key default gen_random_uuid(),
  station_id       uuid not null references public.stations(id) on delete cascade,
  kind             text not null check (kind in ('renewal', 'upgrade')),
  plan_code        text not null references public.plans(code),
  billing_cycle    public.billing_cycle not null,
  method           public.sub_pay_method not null,
  amount_paisa     bigint not null check (amount_paisa > 0),
  status           public.sub_pay_status not null,
  reference        text,
  receipt_path     text,                      -- bank receipt image in payment-receipts/<station>/...
  provider_txn_id  text unique,               -- wallet/card: idempotency key from the provider
  reject_reason    text,
  period_from      date,
  period_to        date,
  receipt_no       bigint,                    -- platform receipt number once paid
  created_by       uuid default auth.uid(),
  created_at       timestamptz not null default now(),
  decided_by       uuid,
  decided_at       timestamptz
);
create index subscription_payments_station_idx on public.subscription_payments(station_id, created_at desc);

-- Tombstones so the platform still lists deleted tenants ("Closed — deleted").
create table public.deleted_stations (
  station_id  uuid primary key,
  name        text not null,
  city        text,
  closed_at   timestamptz,
  deleted_at  timestamptz not null default now()
);

alter table public.subscription_payments enable row level security;
alter table public.deleted_stations      enable row level security;
create policy subscription_payments_read on public.subscription_payments for select to authenticated
  using (private.has_role(station_id, array['owner']::public.member_role[]) or private.is_super_admin());
create policy deleted_stations_read on public.deleted_stations for select to authenticated
  using (private.is_super_admin());
revoke insert, update, delete on public.subscription_payments, public.deleted_stations from anon, authenticated;
create trigger audit_subscription_payments after insert or update on public.subscription_payments
  for each row execute function private.audit_row();

-- Bank receipts: private bucket; owner uploads to <station_id>/, super admin reads.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('payment-receipts', 'payment-receipts', false, 5242880, array['image/png', 'image/jpeg', 'application/pdf'])
on conflict (id) do nothing;
create policy payment_receipts_owner_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'payment-receipts'
              and private.has_role(((storage.foldername(name))[1])::uuid, array['owner']::public.member_role[]));
create policy payment_receipts_read on storage.objects for select to authenticated
  using (bucket_id = 'payment-receipts'
         and (private.is_super_admin()
              or private.has_role(((storage.foldername(name))[1])::uuid, array['owner']::public.member_role[])));

-- Audit rows are skipped while a closed station is being purged (its rows are going away).
create or replace function private.audit_row()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_old jsonb := case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end;
  v_new jsonb := case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end;
  v_row jsonb := coalesce(v_new, v_old);
  v_station uuid;
  v_changes jsonb := '{}'::jsonb;
  k text;
begin
  if current_setting('app.purge_station', true) = 'on' then
    return coalesce(new, old);
  end if;
  v_station := coalesce((v_row ->> 'station_id')::uuid,
    case when tg_table_name = 'stations' then (v_row ->> 'id')::uuid end);
  if tg_op = 'UPDATE' then
    for k in select jsonb_object_keys(v_new) loop
      if (v_new -> k) is distinct from (v_old -> k) then
        v_changes := v_changes || jsonb_build_object(k, jsonb_build_object('old', v_old -> k, 'new', v_new -> k));
      end if;
    end loop;
    if v_changes = '{}'::jsonb then return new; end if;
  elsif tg_op = 'INSERT' then
    v_changes := jsonb_build_object('new', v_new);
  else
    v_changes := jsonb_build_object('old', v_old);
  end if;
  insert into public.audit_log (station_id, actor_id, table_name, record_id, action, changes)
  values (v_station, auth.uid(), tg_table_name, coalesce(v_row ->> 'id', v_row ->> 'station_id'), lower(tg_op), v_changes);
  return coalesce(new, old);
end;
$$;

-- Helpers ---------------------------------------------------------------------------------
create or replace function private.station_owner(p_station uuid)
returns uuid
language sql stable security definer set search_path = ''
as $$ select user_id from public.station_members where station_id = p_station and role = 'owner' limit 1; $$;

create or replace function private.cycle_interval(p_cycle public.billing_cycle)
returns interval
language sql immutable
as $$ select case when p_cycle = 'yearly' then interval '1 year' else interval '1 month' end; $$;

create or replace function private.plan_price(p_plan text, p_cycle public.billing_cycle)
returns bigint
language sql stable security definer set search_path = ''
as $$
  select (case when p_cycle = 'yearly' then yearly_price_pkr else monthly_price_pkr end)::bigint * 100
  from public.plans where code = p_plan;
$$;

-- Renewal date: end of the paid period, or the trial end.
create or replace function private.renewal_date(s public.subscriptions)
returns date
language sql immutable
as $$
  select ((case when s.state = 'trial' then s.trial_ends_at else coalesce(s.current_period_end, s.trial_ends_at) end)
          at time zone 'Asia/Karachi')::date;
$$;

-- REQ-008: start the new period from the renewal date (grace/read-only days count, TEST-104),
-- or from today when the station lapsed for more than a full cycle or was closed.
create or replace function private.activate_period(p_payment uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  p public.subscription_payments;
  s public.subscriptions;
  v_from date;
  v_to date;
  v_today date := (now() at time zone 'Asia/Karachi')::date;
begin
  select * into p from public.subscription_payments where id = p_payment for update;
  select * into s from public.subscriptions where station_id = p.station_id for update;

  if p.kind = 'upgrade' then
    update public.subscriptions set plan_code = p.plan_code, pending_plan_code = null, updated_at = now()
    where station_id = p.station_id;
    update public.subscription_payments set receipt_no = nextval('public.platform_receipt_no'),
      period_from = v_today, period_to = private.renewal_date(s) where id = p_payment;
    return;
  end if;

  v_from := private.renewal_date(s);
  if v_from is null or s.state = 'closed' or (v_from + private.cycle_interval(p.billing_cycle))::date <= v_today then
    v_from := v_today;
  end if;
  v_to := (v_from + private.cycle_interval(p.billing_cycle))::date;

  update public.subscriptions set
    state = 'active', plan_code = p.plan_code, billing_cycle = p.billing_cycle, pending_plan_code = null,
    current_period_end = (v_to::timestamp at time zone 'Asia/Karachi'),
    closed_at = null, deletion_due_at = null, suspended_from = null, updated_at = now()
  where station_id = p.station_id;
  update public.subscription_payments set period_from = v_from, period_to = v_to,
    receipt_no = nextval('public.platform_receipt_no') where id = p_payment;
end;
$$;

-- REQ-010: price difference for the remaining days of the current period.
create or replace function private.upgrade_amount(p_station uuid, p_new_plan text)
returns bigint
language plpgsql stable security definer set search_path = ''
as $$
declare
  s public.subscriptions;
  v_left integer;
  v_len integer;
  v_diff bigint;
begin
  select * into s from public.subscriptions where station_id = p_station;
  if s.state <> 'active' then return null; end if;
  v_left := private.renewal_date(s) - (now() at time zone 'Asia/Karachi')::date;
  v_len := case when s.billing_cycle = 'yearly' then 365 else 30 end;
  v_diff := private.plan_price(p_new_plan, s.billing_cycle) - private.plan_price(s.plan_code, s.billing_cycle);
  if v_left <= 0 or v_diff <= 0 then return 0; end if;
  return private.whole_rupees(round(v_diff * least(v_left, v_len)::numeric / v_len)::bigint);
end;
$$;
grant execute on all functions in schema private to authenticated, service_role;

-- Owner RPCs ------------------------------------------------------------------------------
create or replace function public.station_subscription_quote(p_station uuid, p_plan text, p_cycle public.billing_cycle)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare s public.subscriptions;
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then perform private.fail('FORBIDDEN'); end if;
  select * into s from public.subscriptions where station_id = p_station;
  return jsonb_build_object(
    'renewal_amount', private.plan_price(p_plan, p_cycle),
    'upgrade_amount', case when s.state = 'active' and p_cycle = s.billing_cycle then private.upgrade_amount(p_station, p_plan) end,
    'renewal_date', private.renewal_date(s),
    'current_plan', s.plan_code, 'state', s.state, 'cycle', s.billing_cycle, 'pending_plan', s.pending_plan_code);
end;
$$;

-- Bank transfer (reference + receipt image) or cash: waits for super-admin verification.
create or replace function public.station_submit_manual_payment(
  p_station uuid, p_kind text, p_plan text, p_cycle public.billing_cycle, p_method public.sub_pay_method,
  p_reference text, p_receipt_path text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  s public.subscriptions;
  v_amount bigint;
  v_id uuid;
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then perform private.fail('FORBIDDEN'); end if;
  if p_method not in ('bank', 'cash') then perform private.fail('VALIDATION', 'Wallet and card payments go through checkout'); end if;
  if p_kind not in ('renewal', 'upgrade') then perform private.fail('VALIDATION', 'Unknown payment type'); end if;
  if not exists (select 1 from public.plans where code = p_plan) then perform private.fail('NOT_FOUND', 'Plan not found'); end if;
  select * into s from public.subscriptions where station_id = p_station;
  if s.state = 'suspended' then perform private.fail('STATION_SUSPENDED'); end if;
  if p_method = 'bank' and (length(trim(coalesce(p_reference, ''))) < 3 or p_receipt_path is null) then
    perform private.fail('VALIDATION', 'Bank transfer needs the reference number and a receipt image');
  end if;
  if p_receipt_path is not null and split_part(p_receipt_path, '/', 1) <> p_station::text then
    perform private.fail('VALIDATION', 'Receipt must be uploaded to this station''s folder');
  end if;
  if exists (select 1 from public.subscription_payments where station_id = p_station and status = 'pending_verification') then
    perform private.fail('VALIDATION', 'A payment is already waiting for verification');
  end if;
  if p_kind = 'upgrade' then
    if s.state <> 'active' or p_cycle <> s.billing_cycle then perform private.fail('VALIDATION', 'Upgrade applies to an active plan on the same cycle'); end if;
    v_amount := private.upgrade_amount(p_station, p_plan);
    if coalesce(v_amount, 0) <= 0 then perform private.fail('VALIDATION', 'Choose a higher plan to upgrade'); end if;
  else
    v_amount := private.plan_price(p_plan, p_cycle);
  end if;
  insert into public.subscription_payments (station_id, kind, plan_code, billing_cycle, method, amount_paisa, status, reference, receipt_path)
  values (p_station, p_kind, p_plan, p_cycle, p_method, v_amount, 'pending_verification', nullif(trim(p_reference), ''), p_receipt_path)
  returning id into v_id;
  return v_id;
end;
$$;

-- Wallet / card: the app creates a pending payment, the checkout Edge Function sends the
-- customer to the provider, and the webhook confirms it (admin_confirm_provider_payment).
create or replace function public.station_start_checkout(
  p_station uuid, p_kind text, p_plan text, p_cycle public.billing_cycle, p_method public.sub_pay_method)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_amount bigint;
  v_id uuid;
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then perform private.fail('FORBIDDEN'); end if;
  if p_method not in ('jazzcash', 'easypaisa', 'card') then perform private.fail('VALIDATION', 'Use bank transfer or cash instead'); end if;
  v_amount := case when p_kind = 'upgrade' then private.upgrade_amount(p_station, p_plan) else private.plan_price(p_plan, p_cycle) end;
  if coalesce(v_amount, 0) <= 0 then perform private.fail('VALIDATION', 'Nothing to pay for this choice'); end if;
  insert into public.subscription_payments (station_id, kind, plan_code, billing_cycle, method, amount_paisa, status)
  values (p_station, p_kind, p_plan, p_cycle, p_method, v_amount, 'pending')
  returning id into v_id;
  return jsonb_build_object('payment_id', v_id, 'amount_paisa', v_amount);
end;
$$;

-- REQ-010: downgrade takes effect at the next renewal.
create or replace function public.station_schedule_downgrade(p_station uuid, p_plan text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare s public.subscriptions;
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then perform private.fail('FORBIDDEN'); end if;
  select * into s from public.subscriptions where station_id = p_station;
  if private.plan_price(p_plan, 'monthly') >= private.plan_price(s.plan_code, 'monthly') then
    perform private.fail('VALIDATION', 'Choose a lower plan to downgrade');
  end if;
  update public.subscriptions set pending_plan_code = p_plan, updated_at = now() where station_id = p_station;
end;
$$;

-- REQ-013: close with a typed confirmation (the station name). Data kept 90 days.
create or replace function public.station_close_account(p_station uuid, p_confirm text)
returns timestamptz
language plpgsql security definer set search_path = ''
as $$
declare v_name text;
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then perform private.fail('FORBIDDEN'); end if;
  select name into v_name from public.stations where id = p_station;
  if lower(trim(coalesce(p_confirm, ''))) <> lower(v_name) then
    perform private.fail('VALIDATION', 'Type the station name exactly to confirm');
  end if;
  update public.subscriptions set state = 'closed', closed_at = now(), deletion_due_at = now() + interval '90 days', updated_at = now()
  where station_id = p_station;
  update public.stations set closed_at = now() where id = p_station;
  return now() + interval '90 days';
end;
$$;

-- Super admin RPCs (SCR-021…023) ----------------------------------------------------------
create or replace function private.assert_super_admin()
returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.is_super_admin() then perform private.fail('FORBIDDEN'); end if;
end;
$$;
grant execute on all functions in schema private to authenticated, service_role;

-- REQ-012: tenants with plan, status, dates and usage counts only — no station records.
create or replace function public.admin_tenants()
returns table (station_id uuid, name text, city text, created_at timestamptz, plan_code text, status text,
               trial_ends_at timestamptz, renews_at timestamptz, users integer, jobs_this_month integer,
               whatsapp_connected boolean, pending_payments integer, owner_name text, owner_mobile text,
               support_active boolean, deletion_due_at timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform private.assert_super_admin();
  return query
  select st.id, st.name, st.city, st.created_at, s.plan_code,
         private.effective_status(s.state, s.trial_ends_at, s.current_period_end),
         s.trial_ends_at, case when s.state = 'trial' then s.trial_ends_at else s.current_period_end end,
         (select count(*)::int from public.station_members m where m.station_id = st.id and m.active),
         (select count(*)::int from public.job_cards j where j.station_id = st.id and j.created_at >= date_trunc('month', now())),
         false,   -- WhatsApp connection arrives in Phase 7
         (select count(*)::int from public.subscription_payments p where p.station_id = st.id and p.status = 'pending_verification'),
         pr.full_name, pr.mobile,
         private.has_support_grant(st.id),
         s.deletion_due_at
  from public.stations st
  join public.subscriptions s on s.station_id = st.id
  left join public.profiles pr on pr.id = private.station_owner(st.id)
  order by st.created_at desc;
end;
$$;

create or replace function public.admin_verify_payment(p_payment uuid, p_approve boolean, p_reason text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare p public.subscription_payments;
begin
  perform private.assert_super_admin();
  select * into p from public.subscription_payments where id = p_payment for update;
  if p.id is null then perform private.fail('NOT_FOUND'); end if;
  if p.status <> 'pending_verification' then perform private.fail('VALIDATION', 'This payment is not waiting for verification'); end if;
  if not p_approve and length(trim(coalesce(p_reason, ''))) < 3 then perform private.fail('VALIDATION', 'Give the owner a reason'); end if;
  update public.subscription_payments set status = case when p_approve then 'succeeded'::public.sub_pay_status else 'rejected'::public.sub_pay_status end,
    reject_reason = case when p_approve then null else trim(p_reason) end, decided_by = auth.uid(), decided_at = now()
  where id = p_payment;
  if p_approve then
    perform private.activate_period(p_payment);
    perform private.notify(p.station_id, private.station_owner(p.station_id), 'subscription', 'Payment verified',
      format('Your %s plan is active. Thank you.', initcap(p.plan_code)), p_payment);
  else
    perform private.notify(p.station_id, private.station_owner(p.station_id), 'subscription', 'Payment not accepted', trim(p_reason), p_payment);
  end if;
end;
$$;

-- Called only by the payment webhook Edge Function (service role) after it has checked the
-- provider signature and re-queried the status. Idempotent by provider transaction id.
create or replace function public.admin_confirm_provider_payment(p_payment uuid, p_provider_txn text, p_success boolean)
returns text
language plpgsql security definer set search_path = ''
as $$
declare p public.subscription_payments;
begin
  select * into p from public.subscription_payments where id = p_payment for update;
  if p.id is null then perform private.fail('NOT_FOUND'); end if;
  if p.status in ('succeeded', 'failed') then return 'duplicate'; end if;
  if p.status <> 'pending' then perform private.fail('VALIDATION', 'Not a checkout payment'); end if;
  if exists (select 1 from public.subscription_payments where provider_txn_id = p_provider_txn and id <> p_payment) then
    perform private.fail('VALIDATION', 'Transaction already used');
  end if;
  update public.subscription_payments set status = case when p_success then 'succeeded'::public.sub_pay_status else 'failed'::public.sub_pay_status end,
    provider_txn_id = p_provider_txn, decided_at = now()
  where id = p_payment;
  if p_success then perform private.activate_period(p_payment); end if;
  return case when p_success then 'activated' else 'failed' end;
end;
$$;

create or replace function public.admin_extend_trial(p_station uuid, p_days integer)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform private.assert_super_admin();
  if p_days not between 1 and 60 then perform private.fail('VALIDATION', 'Extend by 1 to 60 days'); end if;
  update public.subscriptions set trial_ends_at = greatest(trial_ends_at, now()) + make_interval(days => p_days), updated_at = now()
  where station_id = p_station and state = 'trial';
  if not found then perform private.fail('VALIDATION', 'Only a trial can be extended'); end if;
end;
$$;

create or replace function public.admin_set_suspended(p_station uuid, p_suspend boolean, p_reason text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare s public.subscriptions;
begin
  perform private.assert_super_admin();
  if length(trim(coalesce(p_reason, ''))) < 3 then perform private.fail('VALIDATION', 'A reason is required'); end if;
  select * into s from public.subscriptions where station_id = p_station for update;
  if s.station_id is null then perform private.fail('NOT_FOUND'); end if;
  if p_suspend then
    if s.state = 'suspended' then return; end if;
    update public.subscriptions set suspended_from = s.state, state = 'suspended', suspend_reason = trim(p_reason), updated_at = now()
    where station_id = p_station;
  else
    if s.state <> 'suspended' then return; end if;
    update public.subscriptions set state = coalesce(s.suspended_from, 'active'), suspended_from = null, suspend_reason = trim(p_reason), updated_at = now()
    where station_id = p_station;
  end if;
end;
$$;

-- SCR-023: plan prices. Each tenant pays the new price from its next renewal.
create or replace function public.admin_update_plan(p_code text, p_monthly integer, p_yearly integer)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform private.assert_super_admin();
  if p_monthly <= 0 or p_yearly <= 0 then perform private.fail('VALIDATION', 'Prices must be above 0'); end if;
  update public.plans set monthly_price_pkr = p_monthly, yearly_price_pkr = p_yearly where code = p_code;
  if not found then perform private.fail('NOT_FOUND'); end if;
end;
$$;

-- Daily jobs: trial reminders (day 11, 13), grace reminders, day-80 closing reminder,
-- day-90 deletion. Safe to run twice a day.
create or replace function private.daily_subscription_jobs()
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  r record;
  v_reminders integer := 0;
  v_deleted integer := 0;
begin
  for r in select s.*, private.effective_status(s.state, s.trial_ends_at, s.current_period_end) as eff
           from public.subscriptions s loop
    if r.state = 'trial' and ((r.trial_ends_at at time zone 'Asia/Karachi')::date - (now() at time zone 'Asia/Karachi')::date) in (1, 3) then
      perform private.notify(r.station_id, private.station_owner(r.station_id), 'subscription', 'Trial ending soon',
        format('Your free trial ends on %s. Choose a plan to keep working.', to_char(r.trial_ends_at at time zone 'Asia/Karachi', 'DD-MM-YYYY')), null);
      v_reminders := v_reminders + 1;
    elsif r.eff = 'grace' then
      perform private.notify(r.station_id, private.station_owner(r.station_id), 'subscription', 'Payment due',
        'Renew now — the station becomes read-only after 7 days.', null);
      v_reminders := v_reminders + 1;
    elsif r.state = 'closed' and r.deletion_due_at is not null
          and ((r.deletion_due_at at time zone 'Asia/Karachi')::date - (now() at time zone 'Asia/Karachi')::date) = 10 then
      perform private.notify(r.station_id, private.station_owner(r.station_id), 'subscription', 'Data will be deleted in 10 days',
        'Pay any plan to restore the account, or download your export now.', null);
      v_reminders := v_reminders + 1;
    end if;
  end loop;

  for r in select s.station_id, st.name, st.city, s.closed_at from public.subscriptions s join public.stations st on st.id = s.station_id
           where s.state = 'closed' and s.deletion_due_at <= now() loop
    perform private.purge_station(r.station_id);
    v_deleted := v_deleted + 1;
  end loop;
  return jsonb_build_object('reminders', v_reminders, 'deleted', v_deleted);
end;
$$;

-- REQ-013: permanent deletion of a closed station (rows and files); a tombstone remains.
create or replace function private.purge_station(p_station uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare st public.stations;
begin
  select * into st from public.stations where id = p_station;
  if st.id is null then return; end if;
  if not exists (select 1 from public.subscriptions where station_id = p_station and state = 'closed') then
    perform private.fail('VALIDATION', 'Only closed stations can be deleted');
  end if;
  perform set_config('app.purge_station', 'on', true);
  insert into public.deleted_stations (station_id, name, city, closed_at) values (st.id, st.name, st.city, st.closed_at)
  on conflict (station_id) do nothing;
  delete from storage.objects where bucket_id in ('station-logos', 'payment-receipts') and name like p_station::text || '/%';
  delete from public.stations where id = p_station;
  perform set_config('app.purge_station', 'off', true);
end;
$$;
grant execute on all functions in schema private to authenticated, service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('daily-subscription-jobs', '30 4 * * *', 'select private.daily_subscription_jobs()');
  end if;
end $$;

revoke execute on function
  public.station_subscription_quote(uuid, text, public.billing_cycle),
  public.station_submit_manual_payment(uuid, text, text, public.billing_cycle, public.sub_pay_method, text, text),
  public.station_start_checkout(uuid, text, text, public.billing_cycle, public.sub_pay_method),
  public.station_schedule_downgrade(uuid, text),
  public.station_close_account(uuid, text),
  public.admin_tenants(),
  public.admin_verify_payment(uuid, boolean, text),
  public.admin_confirm_provider_payment(uuid, text, boolean),
  public.admin_extend_trial(uuid, integer),
  public.admin_set_suspended(uuid, boolean, text),
  public.admin_update_plan(text, integer, integer)
from public, anon;
grant execute on function
  public.station_subscription_quote(uuid, text, public.billing_cycle),
  public.station_submit_manual_payment(uuid, text, text, public.billing_cycle, public.sub_pay_method, text, text),
  public.station_start_checkout(uuid, text, text, public.billing_cycle, public.sub_pay_method),
  public.station_schedule_downgrade(uuid, text),
  public.station_close_account(uuid, text),
  public.admin_tenants(),
  public.admin_verify_payment(uuid, boolean, text),
  public.admin_extend_trial(uuid, integer),
  public.admin_set_suspended(uuid, boolean, text),
  public.admin_update_plan(text, integer, integer)
to authenticated;
grant execute on function public.admin_confirm_provider_payment(uuid, text, boolean) to service_role;

-- Security fix: Supabase grants EXECUTE on new public functions to "authenticated" by
-- default, so service-role-only functions must revoke it explicitly. admin_add_member
-- (Phase 1) let a logged-in user add themselves to a station if they knew the owner's id.
revoke execute on function public.admin_add_member(uuid, uuid, uuid, text, text, public.member_role) from authenticated;
revoke execute on function public.admin_confirm_provider_payment(uuid, text, boolean) from authenticated;

-- ===== supabase/migrations/20261117000017_purge_files.sql =====
-- TASK-052 · REQ-013 follow-up
-- Supabase blocks deleting storage.objects with SQL ("use the Storage API"), so the day-90
-- purge now queues the station's file folders; the storage-cleanup Edge Function (service
-- role) removes them through the Storage API.

create table public.storage_cleanup_queue (
  id          bigint generated always as identity primary key,
  bucket_id   text not null,
  prefix      text not null,
  queued_at   timestamptz not null default now(),
  done_at     timestamptz
);
alter table public.storage_cleanup_queue enable row level security;   -- no policy: service role only
revoke all on public.storage_cleanup_queue from anon, authenticated;

create or replace function private.purge_station(p_station uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare st public.stations;
begin
  select * into st from public.stations where id = p_station;
  if st.id is null then return; end if;
  if not exists (select 1 from public.subscriptions where station_id = p_station and state = 'closed') then
    perform private.fail('VALIDATION', 'Only closed stations can be deleted');
  end if;
  perform set_config('app.purge_station', 'on', true);
  insert into public.deleted_stations (station_id, name, city, closed_at) values (st.id, st.name, st.city, st.closed_at)
  on conflict (station_id) do nothing;
  insert into public.storage_cleanup_queue (bucket_id, prefix)
  values ('station-logos', p_station::text || '/'), ('payment-receipts', p_station::text || '/');
  delete from public.stations where id = p_station;
  perform set_config('app.purge_station', 'off', true);
end;
$$;
grant execute on all functions in schema private to authenticated, service_role;

-- ===== supabase/migrations/20261118000018_booking.sql =====
-- TASK-053…057 · REQ-014…017
-- Booking settings (bays, slot length, hours, off-days), slots with capacity, staff and
-- customer bookings with capacity locking, reschedule/cancel rules, no-shows and blocks.
-- Times: hours and days are Pakistan local time (Asia/Karachi); slot_start is a timestamptz.

create type public.booking_status as enum ('booked', 'arrived', 'no_show', 'cancelled');

create table public.booking_settings (
  station_id     uuid primary key references public.stations(id) on delete cascade,
  bays           integer not null default 2 check (bays between 1 and 50),
  slot_minutes   integer not null default 60 check (slot_minutes in (30, 60, 90, 120)),
  no_show_limit  integer not null default 3 check (no_show_limit between 1 and 20),
  days_ahead     integer not null default 30 check (days_ahead between 1 and 90),
  updated_at     timestamptz not null default now()
);

-- One row per open weekday (ISO: 1 = Monday … 7 = Sunday). No row = closed that day.
create table public.booking_hours (
  station_id uuid not null references public.stations(id) on delete cascade,
  weekday    integer not null check (weekday between 1 and 7),
  opens      time not null,
  closes     time not null check (closes > opens),
  primary key (station_id, weekday)
);

create table public.booking_off_days (
  station_id uuid not null references public.stations(id) on delete cascade,
  day        date not null,
  note       text,
  primary key (station_id, day)
);

-- Services customers may pick when booking (REQ-014 "bookable services").
alter table public.services add column bookable boolean not null default false;

create table public.bookings (
  id            uuid primary key default gen_random_uuid(),
  station_id    uuid not null references public.stations(id) on delete cascade,
  customer_id   uuid not null references public.customers(id),
  vehicle_id    uuid not null references public.vehicles(id),
  service_id    uuid references public.services(id),
  slot_start    timestamptz not null,
  slot_end      timestamptz not null,
  status        public.booking_status not null default 'booked',
  source        text not null check (source in ('app', 'staff')),
  note          text,
  overbooked    boolean not null default false,
  job_id        uuid references public.job_cards(id),
  cancel_reason text,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index bookings_slot_idx on public.bookings(station_id, slot_start) where status in ('booked', 'arrived');
create index bookings_customer_idx on public.bookings(customer_id, slot_start desc);

-- REQ-017: no-show count per customer per station; blocked at the station's limit.
create table public.no_show_counters (
  station_id  uuid not null references public.stations(id) on delete cascade,
  customer_id uuid primary key references public.customers(id) on delete cascade,
  no_shows    integer not null default 0,
  blocked     boolean not null default false,
  updated_at  timestamptz not null default now()
);

-- Messages for customers (app inbox now; push/WhatsApp delivery reads this in Phase 7).
create table public.customer_notifications (
  id          bigint generated always as identity primary key,
  station_id  uuid not null references public.stations(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  kind        text not null,      -- booking | estimate | extra_work | reminder
  title       text not null,
  body        text,
  ref_id      uuid,
  created_at  timestamptz not null default now(),
  read_at     timestamptz
);
create index customer_notifications_idx on public.customer_notifications(customer_id, created_at desc);

alter table public.booking_settings       enable row level security;
alter table public.booking_hours          enable row level security;
alter table public.booking_off_days       enable row level security;
alter table public.bookings               enable row level security;
alter table public.no_show_counters       enable row level security;
alter table public.customer_notifications enable row level security;

-- Staff read through RLS; customers read only through customer_* functions below.
create policy booking_settings_read on public.booking_settings for select to authenticated
  using (private.can_read_station(station_id));
create policy booking_hours_read on public.booking_hours for select to authenticated
  using (private.can_read_station(station_id));
create policy booking_off_days_read on public.booking_off_days for select to authenticated
  using (private.can_read_station(station_id));
create policy bookings_read on public.bookings for select to authenticated
  using (private.has_role(station_id, array['owner','manager','cashier']::public.member_role[]) or private.has_support_grant(station_id));
create policy no_show_counters_read on public.no_show_counters for select to authenticated
  using (private.has_role(station_id, array['owner','manager','cashier']::public.member_role[]) or private.has_support_grant(station_id));
create policy customer_notifications_read on public.customer_notifications for select to authenticated
  using (private.has_role(station_id, array['owner','manager','cashier']::public.member_role[]) or private.has_support_grant(station_id));
revoke insert, update, delete on public.booking_settings, public.booking_hours, public.booking_off_days,
  public.bookings, public.no_show_counters, public.customer_notifications from anon, authenticated;

create trigger audit_bookings after insert or update on public.bookings
  for each row execute function private.audit_row();
create trigger audit_booking_settings after insert or update on public.booking_settings
  for each row execute function private.audit_row();

-- Helpers ---------------------------------------------------------------------------
-- Verified phone of the logged-in user, as 03XXXXXXXXX.
create or replace function private.my_mobile()
returns text
language sql stable security definer set search_path = ''
as $$
  select private.normalize_pk_mobile(u.phone) from auth.users u
  where u.id = auth.uid() and u.phone_confirmed_at is not null;
$$;

-- REQ-047: the caller's customer record at a station, only where the station offers the app.
create or replace function private.my_customer(p_station uuid)
returns uuid
language sql stable security definer set search_path = ''
as $$
  select c.id from public.customers c
  where c.station_id = p_station and c.mobile = private.my_mobile()
    and private.has_feature(p_station, 'booking');
$$;

-- All slots of one local day with capacity and booked count (REQ-014).
create or replace function private.day_slots(p_station uuid, p_day date)
returns table (slot_start timestamptz, slot_end timestamptz, capacity integer, booked integer)
language sql stable security definer set search_path = ''
as $$
  with s as (select * from public.booking_settings where station_id = p_station),
  h as (select * from public.booking_hours where station_id = p_station and weekday = extract(isodow from p_day)::int),
  g as (
    select (gs at time zone 'Asia/Karachi') as st, s.slot_minutes, s.bays
    from s cross join h
    cross join lateral generate_series(p_day + h.opens, p_day + h.closes - make_interval(mins => s.slot_minutes),
                                       make_interval(mins => s.slot_minutes)) gs
    where not exists (select 1 from public.booking_off_days o where o.station_id = p_station and o.day = p_day)
  )
  select g.st, g.st + make_interval(mins => g.slot_minutes), g.bays,
         (select count(*)::int from public.bookings b
          where b.station_id = p_station and b.slot_start = g.st and b.status in ('booked', 'arrived'))
  from g order by g.st;
$$;

-- Validates a slot and locks the station's booking settings so two confirmations of the
-- same slot run one after the other (REQ-015). Returns the slot end.
create or replace function private.lock_slot(
  p_station uuid, p_slot timestamptz, p_exclude uuid, p_allow_full boolean, p_customer_rules boolean)
returns timestamptz
language plpgsql security definer set search_path = ''
as $$
declare
  st public.booking_settings;
  v_day date := (p_slot at time zone 'Asia/Karachi')::date;
  v_end timestamptz;
  v_taken integer;
begin
  select * into st from public.booking_settings where station_id = p_station for update;
  if st.station_id is null then perform private.fail('VALIDATION', 'Booking is not set up at this station'); end if;
  select d.slot_end into v_end from private.day_slots(p_station, v_day) d where d.slot_start = p_slot;
  if v_end is null then perform private.fail('VALIDATION', 'This time is not a bookable slot'); end if;
  if p_customer_rules then
    if p_slot <= now() then perform private.fail('VALIDATION', 'Pick a time in the future'); end if;
    if v_day > private.today_pk() + st.days_ahead then
      perform private.fail('VALIDATION', format('Bookings open up to %s days ahead', st.days_ahead));
    end if;
  end if;
  select count(*) into v_taken from public.bookings
  where station_id = p_station and slot_start = p_slot and status in ('booked', 'arrived') and id is distinct from p_exclude;
  if v_taken >= st.bays and not p_allow_full then
    if p_customer_rules then perform private.fail('SLOT_TAKEN', 'Slot just filled, pick another'); end if;
    perform private.fail('SLOT_FULL', 'This slot is full — book anyway?');
  end if;
  return v_end;
end;
$$;

create or replace function private.notify_customer(p_station uuid, p_customer uuid, p_kind text, p_title text, p_body text, p_ref uuid)
returns void
language sql security definer set search_path = ''
as $$
  insert into public.customer_notifications (station_id, customer_id, kind, title, body, ref_id)
  values (p_station, p_customer, p_kind, p_title, p_body, p_ref);
$$;

create or replace function private.slot_label(p_slot timestamptz)
returns text
language sql stable
as $$ select to_char(p_slot at time zone 'Asia/Karachi', 'DD-MM-YYYY HH24:MI'); $$;

grant execute on all functions in schema private to authenticated, service_role;

-- REQ-014: booking settings (owner) ------------------------------------------------------
-- p_hours: [{"weekday":1,"opens":"09:00","closes":"18:00"}, …]. Returns the number of future
-- bookings that no longer fit (they are kept and listed for staff, never cancelled).
create or replace function public.station_save_booking_settings(
  p_station uuid, p_bays integer, p_slot_minutes integer, p_no_show_limit integer,
  p_hours jsonb, p_off_days date[] default '{}', p_days_ahead integer default 30)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare h jsonb;
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then perform private.fail('FORBIDDEN'); end if;
  perform private.assert_can_write(p_station, 'booking');
  if p_bays is null or p_bays not between 1 and 50 then perform private.fail('VALIDATION', 'Bays must be 1 to 50'); end if;
  if p_slot_minutes is null or p_slot_minutes not in (30, 60, 90, 120) then
    perform private.fail('VALIDATION', 'Slot length must be 30, 60, 90 or 120 minutes');
  end if;
  if coalesce(p_no_show_limit, 0) not between 1 and 20 then perform private.fail('VALIDATION', 'No-show limit must be 1 to 20'); end if;
  if coalesce(p_days_ahead, 0) not between 1 and 90 then perform private.fail('VALIDATION', 'Days ahead must be 1 to 90'); end if;

  insert into public.booking_settings (station_id, bays, slot_minutes, no_show_limit, days_ahead)
  values (p_station, p_bays, p_slot_minutes, p_no_show_limit, p_days_ahead)
  on conflict (station_id) do update set bays = excluded.bays, slot_minutes = excluded.slot_minutes,
    no_show_limit = excluded.no_show_limit, days_ahead = excluded.days_ahead, updated_at = now();

  delete from public.booking_hours where station_id = p_station;
  for h in select * from jsonb_array_elements(coalesce(p_hours, '[]'::jsonb)) loop
    if (h->>'weekday')::int not between 1 and 7 or (h->>'closes')::time <= (h->>'opens')::time then
      perform private.fail('VALIDATION', 'Closing time must be after opening time');
    end if;
    insert into public.booking_hours (station_id, weekday, opens, closes)
    values (p_station, (h->>'weekday')::int, (h->>'opens')::time, (h->>'closes')::time)
    on conflict (station_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
  end loop;

  delete from public.booking_off_days where station_id = p_station and day >= private.today_pk();
  insert into public.booking_off_days (station_id, day)
  select p_station, d from unnest(coalesce(p_off_days, '{}')) d where d >= private.today_pk()
  on conflict do nothing;

  return (select count(*)::int from public.station_booking_conflicts(p_station));
end;
$$;

-- Future bookings that no longer match a slot, or exceed the bays.
create or replace function public.station_booking_conflicts(p_station uuid)
returns table (booking_id uuid, slot_start timestamptz, reason text)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.has_role(p_station, array['owner','manager','cashier']::public.member_role[]) then perform private.fail('FORBIDDEN'); end if;
  return query
  select b.id, b.slot_start,
         case when d.slot_start is null then 'Outside working hours or slot length' else 'More bookings than bays' end
  from public.bookings b
  left join lateral private.day_slots(p_station, (b.slot_start at time zone 'Asia/Karachi')::date) d on d.slot_start = b.slot_start
  where b.station_id = p_station and b.status = 'booked' and b.slot_start > now()
    and (d.slot_start is null or d.booked > d.capacity)
  order by b.slot_start;
end;
$$;

create or replace function public.station_set_service_bookable(p_service uuid, p_bookable boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
declare v_station uuid;
begin
  select station_id into v_station from public.services where id = p_service;
  if v_station is null or not private.has_role(v_station, array['owner','manager']::public.member_role[]) then
    perform private.fail('NOT_FOUND');
  end if;
  perform private.assert_can_write(v_station, 'booking');
  update public.services set bookable = coalesce(p_bookable, false) where id = p_service;
end;
$$;

-- Free slots of a day: staff of the station, or a linked customer (REQ-014, REQ-015).
create or replace function public.booking_slots(p_station uuid, p_day date)
returns table (slot_start timestamptz, slot_end timestamptz, capacity integer, booked integer, free integer)
language plpgsql stable security definer set search_path = ''
as $$
declare v_customer boolean;
begin
  v_customer := not private.can_read_station(p_station);
  if v_customer and private.my_customer(p_station) is null then perform private.fail('NOT_FOUND'); end if;
  return query
  select d.slot_start, d.slot_end, d.capacity, d.booked, greatest(d.capacity - d.booked, 0)
  from private.day_slots(p_station, p_day) d
  where not v_customer or (d.slot_start > now() and d.booked < d.capacity)
  order by d.slot_start;
end;
$$;

-- REQ-016: staff bookings ----------------------------------------------------------------
create or replace function public.station_create_booking(
  p_station uuid, p_customer uuid, p_vehicle uuid, p_service uuid, p_slot timestamptz,
  p_note text default null, p_overbook boolean default false)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_end timestamptz; v_id uuid; v_full boolean;
begin
  if not private.has_role(p_station, array['owner','manager','cashier']::public.member_role[]) then perform private.fail('FORBIDDEN'); end if;
  perform private.assert_can_write(p_station, 'booking');
  if not exists (select 1 from public.vehicles where id = p_vehicle and customer_id = p_customer and station_id = p_station) then
    perform private.fail('VALIDATION', 'Choose the customer''s vehicle');
  end if;
  if p_service is not null and not exists (select 1 from public.services where id = p_service and station_id = p_station) then
    perform private.fail('VALIDATION', 'Service not found');
  end if;
  v_end := private.lock_slot(p_station, p_slot, null, coalesce(p_overbook, false), false);
  select d.booked >= d.capacity into v_full from private.day_slots(p_station, (p_slot at time zone 'Asia/Karachi')::date) d where d.slot_start = p_slot;
  insert into public.bookings (station_id, customer_id, vehicle_id, service_id, slot_start, slot_end, source, note, overbooked)
  values (p_station, p_customer, p_vehicle, p_service, p_slot, v_end, 'staff', nullif(trim(p_note), ''), v_full)
  returning id into v_id;
  perform private.notify_customer(p_station, p_customer, 'booking', 'Booking confirmed', private.slot_label(p_slot), v_id);
  return v_id;
end;
$$;

create or replace function public.station_reschedule_booking(p_booking uuid, p_slot timestamptz, p_overbook boolean default false)
returns void
language plpgsql security definer set search_path = ''
as $$
declare b public.bookings; v_end timestamptz;
begin
  select * into b from public.bookings where id = p_booking;
  if b.id is null or not private.has_role(b.station_id, array['owner','manager','cashier']::public.member_role[]) then
    perform private.fail('NOT_FOUND', 'Booking not found');
  end if;
  perform private.assert_can_write(b.station_id, 'booking');
  if b.status <> 'booked' then perform private.fail('VALIDATION', 'Only open bookings can be moved'); end if;
  v_end := private.lock_slot(b.station_id, p_slot, p_booking, coalesce(p_overbook, false), false);
  update public.bookings set slot_start = p_slot, slot_end = v_end, overbooked = coalesce(p_overbook, false), updated_at = now()
  where id = p_booking;
  perform private.notify_customer(b.station_id, b.customer_id, 'booking', 'Booking moved', private.slot_label(p_slot), p_booking);
end;
$$;

create or replace function public.station_cancel_booking(p_booking uuid, p_reason text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare b public.bookings;
begin
  select * into b from public.bookings where id = p_booking;
  if b.id is null or not private.has_role(b.station_id, array['owner','manager','cashier']::public.member_role[]) then
    perform private.fail('NOT_FOUND', 'Booking not found');
  end if;
  perform private.assert_can_write(b.station_id, 'booking');
  if b.status <> 'booked' then perform private.fail('VALIDATION', 'Only open bookings can be cancelled'); end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then perform private.fail('VALIDATION', 'A reason is required'); end if;
  update public.bookings set status = 'cancelled', cancel_reason = trim(p_reason), updated_at = now() where id = p_booking;
  perform private.notify_customer(b.station_id, b.customer_id, 'booking', 'Booking cancelled by the station',
    private.slot_label(b.slot_start) || ' — ' || trim(p_reason), p_booking);
end;
$$;

-- Customer arrived: opens the job card from the booking (SCR-004 → SCR-006).
create or replace function public.station_mark_arrived(
  p_booking uuid, p_odometer integer, p_fuel public.fuel_level, p_complaints text default null,
  p_confirm_odometer boolean default false)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare b public.bookings; v_job uuid; v_service text;
begin
  select * into b from public.bookings where id = p_booking for update;
  if b.id is null or not private.has_role(b.station_id, array['owner','manager','cashier']::public.member_role[]) then
    perform private.fail('NOT_FOUND', 'Booking not found');
  end if;
  if b.status not in ('booked', 'no_show') then perform private.fail('VALIDATION', 'This booking is already closed'); end if;
  select name into v_service from public.services where id = b.service_id;
  v_job := public.station_create_job(b.station_id, b.customer_id, b.vehicle_id, p_odometer, p_fuel,
    coalesce(nullif(trim(p_complaints), ''), concat_ws(' — ', v_service, b.note)), null, p_confirm_odometer, p_booking);
  -- A late arrival after the no-show mark takes the count back.
  if b.status = 'no_show' then
    update public.no_show_counters set no_shows = greatest(no_shows - 1, 0), updated_at = now() where customer_id = b.customer_id;
  end if;
  update public.bookings set status = 'arrived', job_id = v_job, updated_at = now() where id = p_booking;
  return v_job;
end;
$$;

-- REQ-017: manager/owner unblocks; the count starts again from zero.
create or replace function public.station_unblock_customer(p_customer uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare v_station uuid;
begin
  select station_id into v_station from public.customers where id = p_customer;
  if v_station is null or not private.has_role(v_station, array['owner','manager']::public.member_role[]) then
    perform private.fail('FORBIDDEN');
  end if;
  perform private.assert_can_write(v_station, 'booking');
  update public.no_show_counters set no_shows = 0, blocked = false, updated_at = now() where customer_id = p_customer;
end;
$$;

-- REQ-017: bookings not marked arrived 30 minutes after the slot start become No-show
-- and free the slot. Runs every 5 minutes; safe to run twice.
create or replace function private.mark_no_shows()
returns integer
language plpgsql security definer set search_path = ''
as $$
declare b record; n integer := 0; v_limit integer; p_at timestamptz := now();
begin
  for b in
    select * from public.bookings
    where status = 'booked' and slot_start + interval '30 minutes' <= p_at
    for update skip locked
  loop
    update public.bookings set status = 'no_show', updated_at = now() where id = b.id;
    select coalesce(no_show_limit, 3) into v_limit from public.booking_settings where station_id = b.station_id;
    insert into public.no_show_counters (station_id, customer_id, no_shows) values (b.station_id, b.customer_id, 1)
    on conflict (customer_id) do update set no_shows = public.no_show_counters.no_shows + 1, updated_at = now();
    update public.no_show_counters set blocked = true
    where customer_id = b.customer_id and no_shows >= coalesce(v_limit, 3) and not blocked;
    perform private.notify_customer(b.station_id, b.customer_id, 'booking', 'Missed booking', private.slot_label(b.slot_start), b.id);
    n := n + 1;
  end loop;
  return n;
end;
$$;

-- REQ-047 / REQ-015 / REQ-016: customer app ------------------------------------------------
-- Linked stations: every station with the caller's verified mobile on a customer record and
-- the booking feature (Standard/Premium).
create or replace function public.customer_stations()
returns table (station_id uuid, name text, city text, phone text, station_code text, customer_id uuid,
               customer_name text, blocked boolean, read_only boolean)
language sql stable security definer set search_path = ''
as $$
  select s.id, s.name, s.city, s.phone, s.station_code, c.id, c.name,
         coalesce(n.blocked, false),
         private.effective_status(sub.state, sub.trial_ends_at, sub.current_period_end) in ('read_only', 'suspended', 'closed')
  from public.customers c
  join public.stations s on s.id = c.station_id
  join public.subscriptions sub on sub.station_id = s.id
  left join public.no_show_counters n on n.customer_id = c.id
  where c.mobile = private.my_mobile() and private.has_feature(s.id, 'booking') and sub.state <> 'closed'
  order by s.name;
$$;

-- Link by the station's code: creates the customer record there if it does not exist yet.
create or replace function public.customer_link_station(p_code text, p_name text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_station uuid; v_mobile text := private.my_mobile(); v_id uuid;
begin
  if v_mobile is null then perform private.fail('FORBIDDEN', 'Log in with your mobile number first'); end if;
  select id into v_station from public.stations where station_code = upper(trim(coalesce(p_code, '')));
  if v_station is null then perform private.fail('NOT_FOUND', 'No station has this code'); end if;
  if not private.has_feature(v_station, 'booking') then
    perform private.fail('FEATURE_LOCKED', 'This station doesn''t offer the app yet');
  end if;
  select id into v_id from public.customers where station_id = v_station and mobile = v_mobile;
  if v_id is not null then return v_station; end if;
  perform private.assert_can_write(v_station, 'booking');
  if length(trim(coalesce(p_name, ''))) < 2 then perform private.fail('VALIDATION', 'Enter your name'); end if;
  insert into public.customers (station_id, name, mobile) values (v_station, trim(p_name), v_mobile);
  return v_station;
end;
$$;

-- Loads the caller's customer id at a station or fails with NOT_FOUND.
create or replace function private.customer_at(p_station uuid)
returns uuid
language plpgsql stable security definer set search_path = ''
as $$
declare v uuid := private.my_customer(p_station);
begin
  if v is null then perform private.fail('NOT_FOUND', 'Station not linked'); end if;
  return v;
end;
$$;
grant execute on all functions in schema private to authenticated, service_role;

create or replace function public.customer_station_data(p_station uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare v_c uuid := private.customer_at(p_station);
begin
  return jsonb_build_object(
    'vehicles', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'plate', v.plate, 'make', v.make, 'model', v.model) order by v.plate)
                 from public.vehicles v where v.customer_id = v_c), '[]'::jsonb),
    'services', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'rate_paisa', s.rate_paisa) order by s.name)
                 from public.services s where s.station_id = p_station and s.active and s.bookable), '[]'::jsonb),
    'bookings', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'slot_start', b.slot_start, 'slot_end', b.slot_end,
                   'status', b.status, 'plate', v.plate, 'service', s.name, 'note', b.note) order by b.slot_start desc)
                 from public.bookings b join public.vehicles v on v.id = b.vehicle_id left join public.services s on s.id = b.service_id
                 where b.customer_id = v_c), '[]'::jsonb),
    'jobs', coalesce((select jsonb_agg(jsonb_build_object('id', j.id, 'job_no', j.job_no, 'stage', j.stage, 'plate', v.plate,
                   'created_at', j.created_at, 'extra_pending', exists (select 1 from public.job_lines l where l.job_id = j.id and l.status = 'extra_pending'))
                   order by j.created_at desc)
                 from public.job_cards j join public.vehicles v on v.id = j.vehicle_id where j.customer_id = v_c), '[]'::jsonb),
    'invoices', coalesce((select jsonb_agg(jsonb_build_object('id', b.invoice_id, 'invoice_no', b.invoice_no, 'issued_at', b.issued_at,
                   'total_paisa', b.total_paisa, 'paid_paisa', b.paid_paisa, 'due_paisa', b.due_paisa, 'status', b.status,
                   'job_no', j.job_no, 'plate', v.plate) order by b.issued_at desc)
                 from public.invoice_balances b join public.job_cards j on j.id = b.job_id join public.vehicles v on v.id = j.vehicle_id
                 where b.customer_id = v_c), '[]'::jsonb),
    'dues_paisa', coalesce((select dues_paisa from public.customer_balances where customer_id = v_c), 0)
  );
end;
$$;

create or replace function public.customer_add_vehicle(p_station uuid, p_plate text, p_make text default null, p_model text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_c uuid := private.customer_at(p_station); v_plate text := private.normalize_plate(p_plate); v_id uuid; v_owner uuid;
begin
  perform private.assert_can_write(p_station, 'booking');
  if v_plate is null then perform private.fail('VALIDATION', 'Number plate is not valid (e.g. LEA-1234)'); end if;
  select id, customer_id into v_id, v_owner from public.vehicles where station_id = p_station and plate = v_plate;
  if v_id is not null then
    if v_owner = v_c then return v_id; end if;
    perform private.fail('VALIDATION', 'This plate is registered to someone else — please call the station');
  end if;
  insert into public.vehicles (station_id, customer_id, plate, make, model)
  values (p_station, v_c, v_plate, nullif(trim(p_make), ''), nullif(trim(p_model), ''))
  returning id into v_id;
  insert into public.vehicle_owner_history (station_id, vehicle_id, from_customer_id, to_customer_id, changed_by)
  values (p_station, v_id, null, v_c, auth.uid());
  return v_id;
end;
$$;

create or replace function public.customer_book(
  p_station uuid, p_vehicle uuid, p_service uuid, p_slot timestamptz, p_note text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_c uuid := private.customer_at(p_station); v_end timestamptz; v_id uuid;
begin
  if exists (select 1 from public.no_show_counters where customer_id = v_c and blocked) then
    perform private.fail('BOOKING_BLOCKED', 'Please call the station');
  end if;
  perform private.assert_can_write(p_station, 'booking');
  if not exists (select 1 from public.vehicles where id = p_vehicle and customer_id = v_c) then
    perform private.fail('VALIDATION', 'Choose your vehicle');
  end if;
  if p_service is not null and not exists (select 1 from public.services where id = p_service and station_id = p_station and bookable and active) then
    perform private.fail('VALIDATION', 'Service not found');
  end if;
  v_end := private.lock_slot(p_station, p_slot, null, false, true);
  if exists (select 1 from public.bookings where vehicle_id = p_vehicle and slot_start = p_slot and status = 'booked') then
    perform private.fail('VALIDATION', 'This vehicle is already booked for this time');
  end if;
  insert into public.bookings (station_id, customer_id, vehicle_id, service_id, slot_start, slot_end, source, note, created_by)
  values (p_station, v_c, p_vehicle, p_service, p_slot, v_end, 'app', nullif(trim(p_note), ''), auth.uid())
  returning id into v_id;
  perform private.notify(p_station, null, 'booking', 'New app booking',
    (select plate from public.vehicles where id = p_vehicle) || ' · ' || private.slot_label(p_slot), v_id);
  perform private.notify_customer(p_station, v_c, 'booking', 'Booking confirmed', private.slot_label(p_slot), v_id);
  return v_id;
end;
$$;

-- Loads the caller's own open booking, applying the 1-hour rule (REQ-016).
create or replace function private.my_open_booking(p_booking uuid)
returns public.bookings
language plpgsql stable security definer set search_path = ''
as $$
declare b public.bookings;
begin
  select * into b from public.bookings where id = p_booking;
  if b.id is null or b.customer_id is distinct from private.my_customer(b.station_id) then
    perform private.fail('NOT_FOUND', 'Booking not found');
  end if;
  if b.status <> 'booked' then perform private.fail('VALIDATION', 'This booking is already closed'); end if;
  if now() > b.slot_start - interval '1 hour' then
    perform private.fail('TOO_LATE', 'Too late to change online — call the station');
  end if;
  return b;
end;
$$;
grant execute on function private.my_open_booking(uuid) to authenticated, service_role;

create or replace function public.customer_cancel_booking(p_booking uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare b public.bookings := private.my_open_booking(p_booking);
begin
  update public.bookings set status = 'cancelled', cancel_reason = 'Cancelled by customer in app', updated_at = now() where id = p_booking;
  perform private.notify(b.station_id, null, 'booking', 'Booking cancelled by customer', private.slot_label(b.slot_start), p_booking);
end;
$$;

create or replace function public.customer_reschedule_booking(p_booking uuid, p_slot timestamptz)
returns void
language plpgsql security definer set search_path = ''
as $$
declare b public.bookings := private.my_open_booking(p_booking); v_end timestamptz;
begin
  if exists (select 1 from public.no_show_counters where customer_id = b.customer_id and blocked) then
    perform private.fail('BOOKING_BLOCKED', 'Please call the station');
  end if;
  perform private.assert_can_write(b.station_id, 'booking');
  v_end := private.lock_slot(b.station_id, p_slot, p_booking, false, true);
  update public.bookings set slot_start = p_slot, slot_end = v_end, updated_at = now() where id = p_booking;
  perform private.notify(b.station_id, null, 'booking', 'Booking moved by customer',
    private.slot_label(b.slot_start) || ' → ' || private.slot_label(p_slot), p_booking);
end;
$$;

create or replace function public.customer_notifications_list()
returns table (id bigint, station_name text, kind text, title text, body text, ref_id uuid, created_at timestamptz, read_at timestamptz)
language sql stable security definer set search_path = ''
as $$
  select n.id, s.name, n.kind, n.title, n.body, n.ref_id, n.created_at, n.read_at
  from public.customer_notifications n
  join public.customers c on c.id = n.customer_id
  join public.stations s on s.id = n.station_id
  where c.mobile = private.my_mobile() and private.has_feature(n.station_id, 'booking')
  order by n.created_at desc
  limit 100;
$$;

create or replace function public.customer_mark_notifications_read()
returns void
language sql security definer set search_path = ''
as $$
  update public.customer_notifications n set read_at = now()
  from public.customers c
  where c.id = n.customer_id and c.mobile = private.my_mobile() and n.read_at is null;
$$;

-- Grants -----------------------------------------------------------------------------------
revoke execute on function
  public.station_save_booking_settings(uuid, integer, integer, integer, jsonb, date[], integer),
  public.station_booking_conflicts(uuid),
  public.station_set_service_bookable(uuid, boolean),
  public.booking_slots(uuid, date),
  public.station_create_booking(uuid, uuid, uuid, uuid, timestamptz, text, boolean),
  public.station_reschedule_booking(uuid, timestamptz, boolean),
  public.station_cancel_booking(uuid, text),
  public.station_mark_arrived(uuid, integer, public.fuel_level, text, boolean),
  public.station_unblock_customer(uuid),
  public.customer_stations(),
  public.customer_link_station(text, text),
  public.customer_station_data(uuid),
  public.customer_add_vehicle(uuid, text, text, text),
  public.customer_book(uuid, uuid, uuid, timestamptz, text),
  public.customer_cancel_booking(uuid),
  public.customer_reschedule_booking(uuid, timestamptz),
  public.customer_notifications_list(),
  public.customer_mark_notifications_read()
from public, anon;
grant execute on function
  public.station_save_booking_settings(uuid, integer, integer, integer, jsonb, date[], integer),
  public.station_booking_conflicts(uuid),
  public.station_set_service_bookable(uuid, boolean),
  public.booking_slots(uuid, date),
  public.station_create_booking(uuid, uuid, uuid, uuid, timestamptz, text, boolean),
  public.station_reschedule_booking(uuid, timestamptz, boolean),
  public.station_cancel_booking(uuid, text),
  public.station_mark_arrived(uuid, integer, public.fuel_level, text, boolean),
  public.station_unblock_customer(uuid),
  public.customer_stations(),
  public.customer_link_station(text, text),
  public.customer_station_data(uuid),
  public.customer_add_vehicle(uuid, text, text, text),
  public.customer_book(uuid, uuid, uuid, timestamptz, text),
  public.customer_cancel_booking(uuid),
  public.customer_reschedule_booking(uuid, timestamptz),
  public.customer_notifications_list(),
  public.customer_mark_notifications_read()
to authenticated;

-- No-show marking every 5 minutes when pg_cron is enabled on the project.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('booking-no-shows', '*/5 * * * *', 'select private.mark_no_shows()');
  end if;
end $$;
-- ===== supabase/migrations/20261118000019_customer_jobs.sql =====
-- TASK-058, TASK-059, TASK-028 · REQ-020, REQ-022, REQ-048, REQ-049
-- Customer job tracking with estimate / extra-work approval in the app, invoices and
-- vehicle history, next-service reminders (customer inbox on Standard/Premium; a staff
-- "Due for service" list on every plan).

alter table public.job_cards
  add column next_service_date date,
  add column next_service_km   integer check (next_service_km is null or next_service_km > 0),
  add column reminder_sent_at  timestamptz;
create index job_cards_next_service_idx on public.job_cards(station_id, next_service_date) where next_service_date is not null;

-- Shared approval and cancel logic (staff recording, or the customer in the app) ----------
create or replace function private.cancel_job(p_job uuid, p_reason text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  j public.job_cards;
  v_fee bigint;
  v_work_started boolean;
begin
  select * into j from public.job_cards where id = p_job;
  if j.stage in ('delivered', 'cancelled') then perform private.fail('VALIDATION', 'This job card is closed'); end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then perform private.fail('VALIDATION', 'A reason is required'); end if;
  v_work_started := j.stage in ('in_progress', 'quality_check', 'ready');
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

create or replace function private.decide_job(
  p_job uuid, p_approve boolean, p_via public.approval_via, p_by_name text, p_extra boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
declare j public.job_cards;
begin
  select * into j from public.job_cards where id = p_job;
  if not p_extra then
    if j.stage not in ('intake', 'awaiting_approval') then perform private.fail('VALIDATION', 'Estimate already decided'); end if;
    if not exists (select 1 from public.job_lines where job_id = p_job and status = 'estimate') then
      perform private.fail('VALIDATION', 'Add at least one line to the estimate');
    end if;
    if not p_approve then
      perform private.cancel_job(p_job, 'Estimate rejected by ' || trim(p_by_name));
      return;
    end if;
    update public.job_lines set status = 'approved' where job_id = p_job and status = 'estimate';
    update public.job_cards set stage = 'approved', approved_via = p_via, approved_by_name = trim(p_by_name),
      approved_at = now(), updated_at = now() where id = p_job;
    perform private.log_job(j.station_id, p_job, 'stage', j.stage::text, 'approved',
      case when p_via = 'app' then 'Approved by customer in app'
           else format('Approved by %s (%s)', trim(p_by_name), replace(p_via::text, '_', ' ')) end);
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
grant execute on all functions in schema private to authenticated, service_role;

create or replace function public.job_record_approval(
  p_job uuid, p_approve boolean, p_via public.approval_via, p_by_name text, p_extra boolean default false)
returns void
language plpgsql security definer set search_path = ''
as $$
declare j public.job_cards := private.job_for(p_job, array['owner','manager','cashier']::public.member_role[]);
begin
  perform private.assert_can_write(j.station_id);
  if length(trim(coalesce(p_by_name, ''))) < 2 then perform private.fail('VALIDATION', 'Enter who approved'); end if;
  if p_via = 'app' then perform private.fail('VALIDATION', 'App approval comes from the customer''s app'); end if;
  perform private.decide_job(p_job, p_approve, p_via, p_by_name, coalesce(p_extra, false));
end;
$$;

create or replace function public.job_cancel(p_job uuid, p_reason text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare j public.job_cards := private.job_for(p_job, array['owner','manager','cashier']::public.member_role[]);
begin
  if not private.has_role(j.station_id, array['owner','manager']::public.member_role[])
     and not (j.stage in ('intake', 'awaiting_approval')) then
    perform private.fail('FORBIDDEN', 'Only the owner or manager can cancel a job in progress');
  end if;
  perform private.assert_can_write(j.station_id);
  perform private.cancel_job(p_job, p_reason);
end;
$$;

-- REQ-020: sending the estimate now also tells the customer (inbox; push/WhatsApp in Phase 7).
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
  if private.has_feature(j.station_id, 'booking') then
    perform private.notify_customer(j.station_id, j.customer_id, 'estimate', format('Estimate for job %s', j.job_no),
      'Please review and approve', p_job);
  end if;
end;
$$;

-- REQ-022: a new line after approval is extra work — tell the customer once per request.
create or replace function private.notify_extra_work()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare j public.job_cards;
begin
  if new.status = 'extra_pending' and not exists (
       select 1 from public.job_lines where job_id = new.job_id and status = 'extra_pending' and id <> new.id) then
    select * into j from public.job_cards where id = new.job_id;
    if private.has_feature(j.station_id, 'booking') then
      perform private.notify_customer(j.station_id, j.customer_id, 'extra_work', format('Extra work on job %s', j.job_no),
        'New work needs your approval', j.id);
    end if;
  end if;
  return new;
end;
$$;
create trigger job_lines_notify_extra after insert on public.job_lines
  for each row execute function private.notify_extra_work();

-- Customer job tracking (SCR-043) --------------------------------------------------------
create or replace function private.my_job(p_job uuid)
returns public.job_cards
language plpgsql stable security definer set search_path = ''
as $$
declare j public.job_cards;
begin
  select * into j from public.job_cards where id = p_job;
  if j.id is null or j.customer_id is distinct from private.my_customer(j.station_id) then
    perform private.fail('NOT_FOUND', 'Job card not found');
  end if;
  return j;
end;
$$;
grant execute on function private.my_job(uuid) to authenticated, service_role;

-- Stage timeline, estimate and extra-work lines with prices, approval and invoice.
create or replace function public.customer_job(p_job uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare j public.job_cards := private.my_job(p_job);
begin
  return jsonb_build_object(
    'id', j.id, 'job_no', j.job_no, 'stage', j.stage, 'created_at', j.created_at,
    'odometer_km', j.odometer_km, 'complaints', j.complaints, 'expected_delivery', j.expected_delivery,
    'approved_via', j.approved_via, 'approved_by_name', j.approved_by_name, 'approved_at', j.approved_at,
    'cancel_reason', j.cancel_reason, 'next_service_date', j.next_service_date, 'next_service_km', j.next_service_km,
    'station_name', (select name from public.stations where id = j.station_id),
    'plate', (select plate from public.vehicles where id = j.vehicle_id),
    'timeline', coalesce((select jsonb_agg(jsonb_build_object('stage', h.new_value, 'at', h.created_at, 'note', h.note) order by h.created_at, h.id)
                 from public.job_history h where h.job_id = j.id and h.field = 'stage' and not h.conflict), '[]'::jsonb),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'kind', l.kind, 'description', l.description, 'qty', l.qty,
                   'unit_price_paisa', l.unit_price_paisa, 'total_paisa', round(l.qty * l.unit_price_paisa)::bigint, 'status', l.status)
                   order by l.created_at, l.id)
                 from public.job_lines l where l.job_id = j.id and l.status <> 'removed'), '[]'::jsonb),
    'invoice', (select jsonb_build_object('id', b.invoice_id, 'invoice_no', b.invoice_no, 'total_paisa', b.total_paisa,
                  'paid_paisa', b.paid_paisa, 'due_paisa', b.due_paisa, 'status', b.status)
                from public.invoice_balances b where b.job_id = j.id)
  );
end;
$$;

-- REQ-020 / REQ-022: approve or reject in the app. p_extra = false: the estimate.
create or replace function public.customer_decide(p_job uuid, p_approve boolean, p_extra boolean default false)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  j public.job_cards := private.my_job(p_job);
  v_name text := (select name from public.customers where id = j.customer_id);
begin
  perform private.assert_can_write(j.station_id, 'booking');
  if not coalesce(p_extra, false) and j.stage <> 'awaiting_approval' then
    perform private.fail('VALIDATION', 'There is no estimate waiting for you');
  end if;
  perform private.decide_job(p_job, coalesce(p_approve, false), 'app', v_name, coalesce(p_extra, false));
  perform private.notify(j.station_id, null, 'customer_decision',
    format('Job %s: %s %s', j.job_no, case when p_extra then 'extra work' else 'estimate' end,
           case when p_approve then 'approved' else 'rejected' end),
    v_name || ' (app)', p_job);
end;
$$;

-- Invoice detail for the customer (SCR-044); the PDF is built in the app from this.
create or replace function public.customer_invoice(p_invoice uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare i public.invoices; j public.job_cards;
begin
  select * into i from public.invoices where id = p_invoice;
  if i.id is null then perform private.fail('NOT_FOUND', 'Invoice not found'); end if;
  j := private.my_job(i.job_id);
  return jsonb_build_object(
    'id', i.id, 'invoice_no', i.invoice_no, 'issued_at', i.issued_at, 'job_no', j.job_no,
    'parts_paisa', i.parts_paisa, 'labour_paisa', i.labour_paisa,
    'discount_paisa', case when i.discount_state = 'applied' then i.discount_paisa else 0 end,
    'tax_paisa', i.tax_parts_paisa + i.tax_services_paisa, 'total_paisa', i.total_paisa,
    'station', (select jsonb_build_object('name', s.name, 'city', s.city, 'address', s.address, 'phone', s.phone, 'ntn', s.ntn, 'strn', s.strn)
                from public.stations s where s.id = i.station_id),
    'customer', (select name from public.customers where id = i.customer_id),
    'plate', (select plate from public.vehicles where id = i.vehicle_id),
    'balance', (select jsonb_build_object('paid_paisa', b.paid_paisa, 'due_paisa', b.due_paisa, 'status', b.status)
                from public.invoice_balances b where b.invoice_id = i.id),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('description', l.description, 'qty', l.qty,
                   'unit_price_paisa', l.unit_price_paisa, 'total_paisa', l.total_paisa, 'warranty_days', l.warranty_days) order by l.id)
                 from public.invoice_lines l where l.invoice_id = i.id), '[]'::jsonb)
  );
end;
$$;

-- REQ-048: vehicle history (staff and customer) ------------------------------------------
-- Jobs newest first with odometer and invoice total, warranty items still valid, and ownership.
create or replace function private.vehicle_timeline(p_vehicle uuid, p_customer uuid default null)
returns table (at timestamptz, kind text, title text, odometer integer, total_paisa bigint, ref_id uuid)
language sql stable security definer set search_path = ''
as $$
  select t.at, t.kind, t.title, t.odometer, t.total_paisa, t.ref_id from (
    select j.created_at as at, 'job' as kind,
           format('Job %s — %s', j.job_no, replace(j.stage::text, '_', ' '))
             || coalesce(' · ' || (select string_agg(l.description, ', ' order by l.created_at)
                                   from public.job_lines l where l.job_id = j.id and l.status = 'approved'), '')
             || coalesce(' · warranty valid: ' || (select string_agg(il.description, ', ')
                                   from public.invoices i2 join public.invoice_lines il on il.invoice_id = i2.id
                                   where i2.job_id = j.id and il.warranty_days > 0
                                     and coalesce(j.delivered_at, i2.issued_at) + make_interval(days => il.warranty_days) > now()), '') as title,
           j.odometer_km as odometer, i.total_paisa, j.id as ref_id, 0::bigint as seq
    from public.job_cards j left join public.invoices i on i.job_id = j.id
    where j.vehicle_id = p_vehicle and (p_customer is null or j.customer_id = p_customer)
    union all
    select h.changed_at, 'owner',
           case when h.from_customer_id is null then 'Registered to ' || c.name else 'Owner changed to ' || c.name end,
           null::integer, null::bigint, h.to_customer_id, h.id
    from public.vehicle_owner_history h join public.customers c on c.id = h.to_customer_id
    where h.vehicle_id = p_vehicle and p_customer is null
  ) t order by t.at desc, t.seq desc;
$$;
grant execute on function private.vehicle_timeline(uuid, uuid) to authenticated, service_role;

create or replace function public.station_vehicle_history(p_vehicle uuid)
returns table (at timestamptz, kind text, title text, odometer integer, total_paisa bigint, ref_id uuid)
language plpgsql stable security definer set search_path = ''
as $$
declare v_station uuid;
begin
  select station_id into v_station from public.vehicles where id = p_vehicle;
  if v_station is null or not (private.has_role(v_station, array['owner','manager','cashier']::public.member_role[])
                               or private.has_support_grant(v_station)) then
    return;
  end if;
  return query select * from private.vehicle_timeline(p_vehicle);
end;
$$;

create or replace function public.customer_vehicle_history(p_vehicle uuid)
returns table (at timestamptz, kind text, title text, odometer integer, total_paisa bigint, ref_id uuid)
language plpgsql stable security definer set search_path = ''
as $$
declare v public.vehicles; v_c uuid;
begin
  select * into v from public.vehicles where id = p_vehicle;
  v_c := private.my_customer(v.station_id);
  if v.id is null or v_c is null or v.customer_id <> v_c then perform private.fail('NOT_FOUND', 'Vehicle not found'); end if;
  return query select * from private.vehicle_timeline(p_vehicle, v_c) t where t.kind = 'job';
end;
$$;

-- REQ-049: next service -----------------------------------------------------------------------
create or replace function public.job_set_next_service(p_job uuid, p_date date, p_km integer default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare j public.job_cards := private.job_for(p_job, array['owner','manager','cashier']::public.member_role[]);
begin
  perform private.assert_can_write(j.station_id);
  if p_date is null and p_km is null then perform private.fail('VALIDATION', 'Enter a date or an odometer reading'); end if;
  if p_date is not null and p_date <= private.today_pk() then perform private.fail('VALIDATION', 'Next service date must be in the future'); end if;
  if p_km is not null and p_km <= j.odometer_km then
    perform private.fail('VALIDATION', format('Next service km must be above %s', to_char(j.odometer_km, 'FM999,999,999')));
  end if;
  update public.job_cards set next_service_date = p_date, next_service_km = p_km, reminder_sent_at = null, updated_at = now()
  where id = p_job;
  perform private.log_job(j.station_id, p_job, 'next_service', null,
    concat_ws(' / ', to_char(p_date, 'DD-MM-YYYY'), to_char(p_km, 'FM999,999,999') || ' km'));
end;
$$;

-- Latest next-service per vehicle due within p_days (staff call list; every plan).
create or replace function public.station_due_for_service(p_station uuid, p_days integer default 7)
returns table (job_id uuid, vehicle_id uuid, plate text, customer_id uuid, customer_name text, mobile text,
               next_service_date date, next_service_km integer, last_odometer integer, reminder_sent boolean)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.has_role(p_station, array['owner','manager','cashier']::public.member_role[]) then perform private.fail('FORBIDDEN'); end if;
  return query
  select j.id, v.id, v.plate, c.id, c.name, c.mobile, j.next_service_date, j.next_service_km, j.odometer_km, j.reminder_sent_at is not null
  from public.job_cards j
  join public.vehicles v on v.id = j.vehicle_id
  join public.customers c on c.id = v.customer_id
  where j.station_id = p_station and j.next_service_date is not null
    and j.next_service_date <= private.today_pk() + greatest(coalesce(p_days, 7), 0)
    and not exists (select 1 from public.job_cards n where n.vehicle_id = j.vehicle_id and n.created_at > j.created_at and n.stage <> 'cancelled')
  order by j.next_service_date, v.plate;
end;
$$;

-- Daily (09:00 PKT): reminder 3 days before the next-service date to customers of stations
-- with the app (Standard/Premium). Basic stations use the staff list above. Safe to run twice.
create or replace function private.daily_service_reminders(p_today date default null)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare r record; n integer := 0; v_today date := coalesce(p_today, private.today_pk());
begin
  -- Scheduler / service role only: never through the API as a logged-in user.
  if session_user = 'authenticator'
     and coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '') <> 'service_role' then
    perform private.fail('FORBIDDEN');
  end if;
  for r in
    select j.id, j.station_id, j.next_service_date, v.customer_id, v.plate
    from public.job_cards j join public.vehicles v on v.id = j.vehicle_id
    where j.next_service_date = v_today + 3 and j.reminder_sent_at is null
      and private.has_feature(j.station_id, 'booking')
      and not exists (select 1 from public.job_cards x where x.vehicle_id = j.vehicle_id and x.created_at > j.created_at and x.stage <> 'cancelled')
    for update of j skip locked
  loop
    perform private.notify_customer(r.station_id, r.customer_id, 'reminder', 'Service due soon',
      format('%s is due for service on %s', r.plate, to_char(r.next_service_date, 'DD-MM-YYYY')), r.id);
    update public.job_cards set reminder_sent_at = now() where id = r.id;
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke execute on function private.daily_service_reminders(date) from public, anon, authenticated;

revoke execute on function
  public.customer_job(uuid),
  public.customer_decide(uuid, boolean, boolean),
  public.customer_invoice(uuid),
  public.customer_vehicle_history(uuid),
  public.job_set_next_service(uuid, date, integer),
  public.station_due_for_service(uuid, integer)
from public, anon;
grant execute on function
  public.customer_job(uuid),
  public.customer_decide(uuid, boolean, boolean),
  public.customer_invoice(uuid),
  public.customer_vehicle_history(uuid),
  public.job_set_next_service(uuid, date, integer),
  public.station_due_for_service(uuid, integer)
to authenticated;

-- Next-service reminders daily at 09:00 PKT (04:00 UTC) when pg_cron is enabled.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('service-reminders', '0 4 * * *', 'select private.daily_service_reminders()');
  end if;
end $$;
-- ===== supabase/migrations/20261119000020_messages.sql =====
-- TASK-060…062 · REQ-055, REQ-056, REQ-061, REQ-062
-- Customer messages by event (push + WhatsApp), per-event switches, the station's own
-- WhatsApp Business connection, a message outbox with one retry, the manual
-- "Messages to send" list, staff push for in-app notifications, and device tokens.
--
-- Flow: a business event (trigger or scheduler) calls private.customer_event(). It writes
--   * a push row (channel 'push') when the station has the customer app and the customer
--     has a phone with the app,
--   * a WhatsApp row (channel 'whatsapp'): 'queued' for automatic sending when the station's
--     own account and the event's template are approved, otherwise 'manual' for staff.
-- The notify-dispatch Edge Function claims queued rows with the service role (svc_* functions),
-- sends them and reports the result. A failed WhatsApp send is retried once after 5 minutes,
-- then moved to the manual list with the reason.

-- Standard English message set (TASK-004 submits these to Meta as templates "csm_<code>").
create table public.message_events (
  code     text primary key,
  label    text not null,
  title    text not null,          -- push title
  template text not null,          -- {placeholders}; Meta parameters follow their order
  inbox    text,                   -- customer-app inbox kind written here (null = written elsewhere)
  sort     integer not null
);
insert into public.message_events (code, label, title, template, inbox, sort) values
  ('booking_confirmed', 'Booking confirmed', 'Booking confirmed',
   'Your booking at {station} is confirmed for {slot} ({plate}).', null, 1),
  ('booking_changed', 'Booking changed', 'Booking moved',
   'Your booking at {station} has moved to {slot} ({plate}).', null, 2),
  ('booking_cancelled', 'Booking cancelled', 'Booking cancelled',
   'Your booking at {station} for {slot} ({plate}) is cancelled.', null, 3),
  ('estimate_ready', 'Estimate ready', 'Estimate ready',
   'The estimate for your vehicle {plate} at {station} is Rs {amount}. Please confirm so we can start the work.', null, 4),
  ('extra_work', 'Extra work needs approval', 'Extra work needs approval',
   'Extra work is needed on your vehicle {plate} at {station}: Rs {amount}. Please confirm before we continue.', null, 5),
  ('vehicle_ready', 'Vehicle ready', 'Vehicle ready',
   'Your vehicle {plate} is ready at {station}.', 'ready', 6),
  ('invoice_issued', 'Invoice issued', 'Invoice issued',
   'Your invoice {invoice_no} from {station}: Rs {amount}. Thank you!', 'invoice', 7),
  ('dues_reminder', 'Dues reminder', 'Payment reminder',
   'Reminder from {station}: Rs {amount} is due on your account.', 'dues', 8),
  ('service_reminder', 'Next-service reminder', 'Service due soon',
   'Your vehicle {plate} is due for service at {station} on {date}.', null, 9),
  ('storage_started', 'Storage charge started', 'Storage charge started',
   'Your vehicle {plate} is waiting at {station}. A storage charge of Rs {amount} per day now applies.', 'storage', 10);

-- REQ-055: the owner switches each event on or off. No row = on.
create table public.message_event_settings (
  station_id uuid not null references public.stations(id) on delete cascade,
  event      text not null references public.message_events(code),
  enabled    boolean not null,
  updated_at timestamptz not null default now(),
  primary key (station_id, event)
);

-- REQ-061: the station's own WhatsApp Business account (Meta Embedded Signup).
create table public.whatsapp_accounts (
  station_id      uuid primary key references public.stations(id) on delete cascade,
  status          text not null default 'not_connected'
                  check (status in ('not_connected', 'pending', 'connected', 'payment_problem', 'disconnected')),
  status_reason   text,
  waba_id         text unique,
  phone_number_id text,
  display_phone   text,
  connected_at    timestamptz,
  updated_at      timestamptz not null default now()
);
create table public.whatsapp_templates (
  station_id uuid not null references public.stations(id) on delete cascade,
  event      text not null references public.message_events(code),
  status     text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  reason     text,
  updated_at timestamptz not null default now(),
  primary key (station_id, event)
);
-- The Meta access token never leaves the server: private schema, not exposed by the API.
create table private.whatsapp_tokens (
  station_id   uuid primary key references public.stations(id) on delete cascade,
  access_token text not null,
  updated_at   timestamptz not null default now()
);

create table public.message_outbox (
  id                  bigint generated always as identity primary key,
  station_id          uuid not null references public.stations(id) on delete cascade,
  customer_id         uuid references public.customers(id) on delete cascade,
  event               text not null references public.message_events(code),
  channel             text not null check (channel in ('whatsapp', 'push')),
  ref_id              uuid,              -- booking, job, invoice or customer
  to_mobile           text,              -- 03XXXXXXXXX, null = no valid number
  title               text not null,
  body                text not null,
  vars                jsonb not null default '{}'::jsonb,
  -- queued → sending → sent | failed (push) ; manual → opened → sent | skipped (staff)
  status              text not null check (status in ('queued', 'sending', 'sent', 'failed', 'manual', 'opened', 'skipped')),
  manual_reason       text,
  attempts            integer not null default 0,
  next_attempt_at     timestamptz not null default now(),
  last_error          text,
  provider_message_id text,
  handled_by          uuid references public.profiles(id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index message_outbox_queue_idx on public.message_outbox(next_attempt_at) where status in ('queued', 'sending');
create index message_outbox_manual_idx on public.message_outbox(station_id, created_at desc) where status in ('manual', 'opened');
create index message_outbox_ref_idx on public.message_outbox(ref_id);

-- Phones that receive push (FCM). One row per device token.
create table public.device_tokens (
  token      text primary key check (length(token) between 20 and 4096),
  user_id    uuid not null references auth.users(id) on delete cascade,
  app        text not null check (app in ('staff', 'customer')),
  platform   text not null default 'android',
  updated_at timestamptz not null default now()
);
create index device_tokens_user_idx on public.device_tokens(user_id);

-- REQ-056: staff push for in-app notifications. null = not yet pushed.
alter table public.notifications add column push_state text check (push_state in ('sending', 'sent', 'failed', 'none'));
alter table public.notifications add column pushed_at timestamptz;
create index notifications_push_idx on public.notifications(created_at) where push_state is null or push_state = 'sending';

alter table public.message_events         enable row level security;
alter table public.message_event_settings enable row level security;
alter table public.whatsapp_accounts      enable row level security;
alter table public.whatsapp_templates     enable row level security;
alter table public.message_outbox         enable row level security;
alter table public.device_tokens          enable row level security;
alter table private.whatsapp_tokens       enable row level security;

create policy message_events_read on public.message_events for select to authenticated using (true);
create policy message_event_settings_read on public.message_event_settings for select to authenticated
  using (private.has_role(station_id, array['owner','manager']::public.member_role[]) or private.has_support_grant(station_id));
create policy whatsapp_accounts_read on public.whatsapp_accounts for select to authenticated
  using (private.has_role(station_id, array['owner','manager']::public.member_role[]) or private.has_support_grant(station_id));
create policy whatsapp_templates_read on public.whatsapp_templates for select to authenticated
  using (private.has_role(station_id, array['owner','manager']::public.member_role[]) or private.has_support_grant(station_id));
create policy message_outbox_read on public.message_outbox for select to authenticated
  using (private.has_role(station_id, array['owner','manager','cashier']::public.member_role[]) or private.has_support_grant(station_id));
create policy device_tokens_read on public.device_tokens for select to authenticated
  using (user_id = auth.uid());
revoke insert, update, delete on public.message_events, public.message_event_settings, public.whatsapp_accounts,
  public.whatsapp_templates, public.message_outbox, public.device_tokens from anon, authenticated;
revoke all on private.whatsapp_tokens from public, anon, authenticated;

create trigger audit_message_event_settings after insert or update on public.message_event_settings
  for each row execute function private.audit_row();
create trigger audit_whatsapp_accounts after insert or update on public.whatsapp_accounts
  for each row execute function private.audit_row();

-- Helpers ---------------------------------------------------------------------------
-- Whole rupees with thousands separators: 950000 paisa → '9,500'.
create or replace function private.rs(p_paisa bigint)
returns text
language sql immutable
as $$ select to_char(round(coalesce(p_paisa, 0) / 100.0), 'FM999,999,999,990'); $$;

create or replace function private.invoice_label(p_no integer)
returns text
language sql immutable
as $$ select 'INV-' || lpad(p_no::text, 4, '0'); $$;

-- Replaces {name} with vars ->> name.
create or replace function private.render_message(p_template text, p_vars jsonb)
returns text
language plpgsql immutable
as $$
declare r record; v text := p_template;
begin
  for r in select key, value from jsonb_each_text(p_vars) loop
    v := replace(v, '{' || r.key || '}', coalesce(r.value, ''));
  end loop;
  return v;
end;
$$;

-- Meta template parameters in the order the placeholders appear.
create or replace function private.message_params(p_event text, p_vars jsonb)
returns text[]
language sql stable security definer set search_path = ''
as $$
  select coalesce(array_agg(p_vars ->> m.name[1] order by m.n), '{}')
  from public.message_events e,
       lateral regexp_matches(e.template, '\{(\w+)\}', 'g') with ordinality as m(name, n)
  where e.code = p_event;
$$;

create or replace function private.event_enabled(p_station uuid, p_event text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((select enabled from public.message_event_settings where station_id = p_station and event = p_event), true);
$$;

-- Why a WhatsApp message of this event cannot go automatically (null = it can).
create or replace function private.wa_block_reason(p_station uuid, p_event text)
returns text
language sql stable security definer set search_path = ''
as $$
  select case
    when not private.has_feature(p_station, 'whatsapp_auto') then null       -- Basic: manual is the normal way
    when a.status is null or a.status in ('not_connected', 'disconnected') then 'WhatsApp not connected'
    when a.status = 'pending' then 'WhatsApp connection pending'
    when a.status = 'payment_problem' then 'Payment problem in Meta — add a payment method'
    when coalesce(t.status, 'pending') <> 'approved' then 'Template not approved yet'
  end
  from (select 1) one
  left join public.whatsapp_accounts a on a.station_id = p_station
  left join public.whatsapp_templates t on t.station_id = p_station and t.event = p_event;
$$;

create or replace function private.wa_auto_ready(p_station uuid, p_event text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select private.has_feature(p_station, 'whatsapp_auto') and private.wa_block_reason(p_station, p_event) is null;
$$;

-- Customer-app phones of a customer (verified phone = the customer's mobile).
create or replace function private.customer_push_tokens(p_customer uuid)
returns text[]
language sql stable security definer set search_path = ''
as $$
  select coalesce(array_agg(d.token), '{}')
  from public.customers c
  join auth.users u on u.phone_confirmed_at is not null and private.normalize_pk_mobile(u.phone) = c.mobile
  join public.device_tokens d on d.user_id = u.id and d.app = 'customer'
  where c.id = p_customer;
$$;

-- REQ-055: one customer event → push (app stations) + WhatsApp (automatic or manual).
-- p_merge: update a not-yet-sent message of the same event and record instead of adding one
-- (extra-work lines added one by one become one message with the running total).
create or replace function private.customer_event(
  p_station uuid, p_customer uuid, p_event text, p_ref uuid, p_vars jsonb, p_merge boolean default false)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  e public.message_events;
  c public.customers;
  v_vars jsonb;
  v_body text;
  v_mobile text;
  v_reason text;
begin
  select * into e from public.message_events where code = p_event;
  select * into c from public.customers where id = p_customer and station_id = p_station;
  if e.code is null or c.id is null or not private.event_enabled(p_station, p_event) then return; end if;
  if exists (select 1 from public.stations where id = p_station and closed_at is not null) then return; end if;

  v_vars := jsonb_build_object('station', (select name from public.stations where id = p_station), 'customer', c.name) || coalesce(p_vars, '{}');
  v_body := private.render_message(e.template, v_vars);
  v_mobile := private.normalize_pk_mobile(c.mobile);

  if p_merge then
    update public.message_outbox set body = v_body, vars = v_vars, updated_at = now()
    where station_id = p_station and event = p_event and ref_id is not distinct from p_ref
      and status in ('queued', 'manual') and created_at > now() - interval '2 hours';
    if found then return; end if;
  end if;

  -- Customer-app inbox for events not already written by the booking/job functions.
  if e.inbox is not null and private.has_feature(p_station, 'booking') then
    perform private.notify_customer(p_station, p_customer, e.inbox, e.title, v_body, p_ref);
  end if;

  -- Push to the customer app (Standard/Premium) when the customer has it on a phone.
  if private.has_feature(p_station, 'booking') and cardinality(private.customer_push_tokens(p_customer)) > 0 then
    insert into public.message_outbox (station_id, customer_id, event, channel, ref_id, to_mobile, title, body, vars, status)
    values (p_station, p_customer, p_event, 'push', p_ref, v_mobile, e.title, v_body, v_vars, 'queued');
  end if;

  -- WhatsApp: automatic from the station's own number, otherwise the manual list (REQ-062).
  if v_mobile is null then
    v_reason := 'No WhatsApp number';
  else
    v_reason := private.wa_block_reason(p_station, p_event);
  end if;
  insert into public.message_outbox (station_id, customer_id, event, channel, ref_id, to_mobile, title, body, vars, status, manual_reason)
  values (p_station, p_customer, p_event, 'whatsapp', p_ref, v_mobile, e.title, v_body, v_vars,
          case when v_mobile is not null and private.wa_auto_ready(p_station, p_event) then 'queued' else 'manual' end,
          v_reason);
end;
$$;

-- Queued automatic WhatsApp messages of a station go to the manual list (disconnect, payment problem).
create or replace function private.wa_fallback(p_station uuid, p_reason text)
returns void
language sql security definer set search_path = ''
as $$
  update public.message_outbox set status = 'manual', manual_reason = p_reason, updated_at = now()
  where station_id = p_station and channel = 'whatsapp' and status = 'queued';
$$;

-- Event triggers -------------------------------------------------------------------
create or replace function private.on_booking_event()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_vars jsonb;
begin
  v_vars := jsonb_build_object('slot', private.slot_label(new.slot_start),
                               'plate', (select plate from public.vehicles where id = new.vehicle_id));
  if tg_op = 'INSERT' then
    if new.status = 'booked' then
      perform private.customer_event(new.station_id, new.customer_id, 'booking_confirmed', new.id, v_vars);
    end if;
  elsif new.status = 'cancelled' and old.status <> 'cancelled' then
    v_vars := v_vars || jsonb_build_object('slot', private.slot_label(old.slot_start));
    perform private.customer_event(new.station_id, new.customer_id, 'booking_cancelled', new.id, v_vars);
  elsif new.status = 'booked' and new.slot_start <> old.slot_start then
    perform private.customer_event(new.station_id, new.customer_id, 'booking_changed', new.id, v_vars);
  end if;
  return null;
end;
$$;
create trigger bookings_customer_messages after insert or update on public.bookings
  for each row execute function private.on_booking_event();

create or replace function private.job_lines_total(p_job uuid, p_statuses public.line_status[])
returns bigint
language sql stable security definer set search_path = ''
as $$
  select coalesce(round(sum(qty * unit_price_paisa)), 0)::bigint from public.job_lines
  where job_id = p_job and status = any(p_statuses) and kind <> 'customer_part';
$$;

create or replace function private.on_job_stage_event()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_plate text := (select plate from public.vehicles where id = new.vehicle_id);
begin
  if new.stage = old.stage then return null; end if;
  if new.stage = 'awaiting_approval' then
    perform private.customer_event(new.station_id, new.customer_id, 'estimate_ready', new.id,
      jsonb_build_object('plate', v_plate, 'job_no', new.job_no,
                         'amount', private.rs(private.job_lines_total(new.id, array['estimate','approved']::public.line_status[]))));
  elsif new.stage = 'ready' then
    perform private.customer_event(new.station_id, new.customer_id, 'vehicle_ready', new.id,
      jsonb_build_object('plate', v_plate, 'job_no', new.job_no));
  end if;
  return null;
end;
$$;
create trigger job_cards_customer_messages after update of stage on public.job_cards
  for each row execute function private.on_job_stage_event();

create or replace function private.on_job_line_event()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare j public.job_cards; v_plate text;
begin
  select * into j from public.job_cards where id = new.job_id;
  v_plate := (select plate from public.vehicles where id = j.vehicle_id);
  if new.status = 'extra_pending' then
    perform private.customer_event(j.station_id, j.customer_id, 'extra_work', j.id,
      jsonb_build_object('plate', v_plate, 'job_no', j.job_no,
                         'amount', private.rs(private.job_lines_total(j.id, array['extra_pending']::public.line_status[]))), true);
  elsif new.kind = 'fee' and new.description like 'Storage charge%' then
    perform private.customer_event(j.station_id, j.customer_id, 'storage_started', j.id,
      jsonb_build_object('plate', v_plate, 'job_no', j.job_no, 'amount', private.rs(new.unit_price_paisa)));
  end if;
  return null;
end;
$$;
create trigger job_lines_customer_messages after insert on public.job_lines
  for each row execute function private.on_job_line_event();

-- The invoice gets its totals right after it is created; the message goes out the first
-- time the total is known.
create or replace function private.on_invoice_event()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.total_paisa > 0 and coalesce(old.total_paisa, 0) = 0
     and not exists (select 1 from public.message_outbox where ref_id = new.id and event = 'invoice_issued') then
    perform private.customer_event(new.station_id, new.customer_id, 'invoice_issued', new.id,
      jsonb_build_object('invoice_no', private.invoice_label(new.invoice_no), 'amount', private.rs(new.total_paisa),
                         'plate', (select plate from public.vehicles where id = new.vehicle_id)));
  end if;
  return null;
end;
$$;
create trigger invoices_customer_messages after update of total_paisa on public.invoices
  for each row execute function private.on_invoice_event();

-- REQ-056: approval request → approvers; decision → requester.
create or replace function private.on_approval_event()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  m record;
  v_label text := initcap(replace(new.type::text, '_', ' '));
begin
  if tg_op = 'INSERT' and new.status = 'pending' then
    for m in
      select sm.user_id from public.station_members sm
      where sm.station_id = new.station_id and sm.active and sm.user_id <> new.requested_by
        and (sm.role = 'owner'
             or (sm.role = 'manager' and private.has_feature(new.station_id, 'approvals_inbox')
                 and coalesce((select manager_can_approve from public.stations where id = new.station_id), false)))
    loop
      perform private.notify(new.station_id, m.user_id, 'approval_request', format('%s approval needed', v_label),
        coalesce(new.reason, '') || case when new.amount_paisa is not null then ' · Rs ' || private.rs(new.amount_paisa) else '' end,
        new.id);
    end loop;
  elsif tg_op = 'UPDATE' and old.status = 'pending' and new.status <> 'pending'
        and new.decided_by is distinct from new.requested_by then
    perform private.notify(new.station_id, new.requested_by, 'approval_decision',
      format('%s request %s', v_label, new.status::text), new.decision_note, new.id);
  end if;
  return null;
end;
$$;
create trigger approval_requests_notify after insert or update on public.approval_requests
  for each row execute function private.on_approval_event();

-- REQ-033 / REQ-056: an item dropping to its minimum stock tells the owner and managers.
create or replace function private.on_stock_event()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  i public.items;
  v_after numeric;
begin
  select * into i from public.items where id = new.item_id;
  if i.min_stock <= 0 or new.qty >= 0 then return null; end if;
  select coalesce(sum(qty), 0) into v_after from public.stock_movements where item_id = new.item_id;
  if v_after >= 0 and v_after <= i.min_stock and v_after - new.qty > i.min_stock then
    perform private.notify(new.station_id, null, 'low_stock', format('Low stock — %s', i.name),
      format('%s left (minimum %s)', trim(to_char(v_after, 'FM999999990.###')), trim(to_char(i.min_stock, 'FM999999990.###'))), i.id);
  end if;
  return null;
end;
$$;
create trigger stock_movements_low_stock after insert on public.stock_movements
  for each row execute function private.on_stock_event();

-- Schedulers -------------------------------------------------------------------------
-- Next-service reminder (REQ-049) on app stations now also goes by push and WhatsApp.
-- Basic keeps the staff "Due for service" list only. Safe to run twice.
create or replace function private.daily_service_reminders(p_today date default null)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare r record; n integer := 0; v_today date := coalesce(p_today, private.today_pk());
begin
  if session_user = 'authenticator'
     and coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '') <> 'service_role' then
    perform private.fail('FORBIDDEN');
  end if;
  for r in
    select j.id, j.station_id, j.next_service_date, v.customer_id, v.plate
    from public.job_cards j join public.vehicles v on v.id = j.vehicle_id
    where j.next_service_date = v_today + 3 and j.reminder_sent_at is null
      and private.has_feature(j.station_id, 'booking')
      and not exists (select 1 from public.job_cards x where x.vehicle_id = j.vehicle_id and x.created_at > j.created_at and x.stage <> 'cancelled')
    for update of j skip locked
  loop
    perform private.notify_customer(r.station_id, r.customer_id, 'reminder', 'Service due soon',
      format('%s is due for service on %s', r.plate, to_char(r.next_service_date, 'DD-MM-YYYY')), r.id);
    perform private.customer_event(r.station_id, r.customer_id, 'service_reminder', r.id,
      jsonb_build_object('plate', r.plate, 'date', to_char(r.next_service_date, 'DD-MM-YYYY')));
    update public.job_cards set reminder_sent_at = now() where id = r.id;
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke execute on function private.daily_service_reminders(date) from public, anon, authenticated;

-- PRD REQ-040: a dues reminder every 7 days while dues remain (first one 7 days after the
-- oldest unpaid invoice). Safe to run twice a day.
create or replace function private.daily_dues_reminders()
returns integer
language plpgsql security definer set search_path = ''
as $$
declare r record; n integer := 0;
begin
  if session_user = 'authenticator'
     and coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '') <> 'service_role' then
    perform private.fail('FORBIDDEN');
  end if;
  for r in
    select b.station_id, b.customer_id, b.dues_paisa
    from public.customer_balances b
    join public.stations s on s.id = b.station_id and s.closed_at is null
    where b.dues_paisa > 0
      and exists (select 1 from public.invoice_balances ib where ib.customer_id = b.customer_id and ib.due_paisa > 0
                  and ib.issued_at < now() - interval '7 days')
      and not exists (select 1 from public.message_outbox o where o.customer_id = b.customer_id and o.event = 'dues_reminder'
                      and o.created_at > now() - interval '7 days' + interval '1 hour')
  loop
    perform private.customer_event(r.station_id, r.customer_id, 'dues_reminder', r.customer_id,
      jsonb_build_object('amount', private.rs(r.dues_paisa)));
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke execute on function private.daily_dues_reminders() from public, anon, authenticated;

-- Staff and owner functions ------------------------------------------------------------
-- REQ-055: event switches. p_events: {"vehicle_ready": false, …}
create or replace function public.station_set_message_events(p_station uuid, p_events jsonb)
returns void
language plpgsql security definer set search_path = ''
as $$
declare r record;
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then perform private.fail('FORBIDDEN'); end if;
  perform private.assert_can_write(p_station);
  for r in select key, value from jsonb_each(coalesce(p_events, '{}')) loop
    if not exists (select 1 from public.message_events where code = r.key) then
      perform private.fail('VALIDATION', 'Unknown message: ' || r.key);
    end if;
    if jsonb_typeof(r.value) <> 'boolean' then perform private.fail('VALIDATION', 'On or off only'); end if;
    insert into public.message_event_settings (station_id, event, enabled)
    values (p_station, r.key, r.value::boolean)
    on conflict (station_id, event) do update set enabled = excluded.enabled, updated_at = now();
  end loop;
end;
$$;

-- REQ-062: staff open WhatsApp from the list, then mark the message sent or skip it.
create or replace function public.message_mark(p_message bigint, p_action text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare m public.message_outbox;
begin
  select * into m from public.message_outbox where id = p_message;
  if m.id is null or not private.has_role(m.station_id, array['owner','manager','cashier']::public.member_role[]) then
    perform private.fail('NOT_FOUND');
  end if;
  perform private.assert_can_write(m.station_id);
  if m.channel <> 'whatsapp' or m.status not in ('manual', 'opened') then
    perform private.fail('VALIDATION', 'This message is already handled');
  end if;
  if p_action not in ('opened', 'sent', 'skipped') then perform private.fail('VALIDATION', 'Unknown action'); end if;
  if p_action in ('opened', 'sent') and m.to_mobile is null then
    perform private.fail('VALIDATION', 'No WhatsApp number — skip this message');
  end if;
  update public.message_outbox set status = p_action, handled_by = auth.uid(), updated_at = now() where id = p_message;
end;
$$;

-- In-app notifications: mark everything the caller can see as read.
create or replace function public.notifications_mark_read(p_station uuid)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare n integer;
begin
  if not private.has_role(p_station, array['owner','manager','cashier','mechanic']::public.member_role[]) then
    perform private.fail('FORBIDDEN');
  end if;
  update public.notifications set read_at = now()
  where station_id = p_station and read_at is null
    and (user_id = auth.uid() or (user_id is null and private.has_role(p_station, array['owner','manager']::public.member_role[])));
  get diagnostics n = row_count;
  return n;
end;
$$;

-- Push tokens: a phone registers its token after login and removes it on sign-out.
create or replace function public.register_device(p_token text, p_app text, p_platform text default 'android')
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is null then perform private.fail('FORBIDDEN'); end if;
  if p_app not in ('staff', 'customer') or length(coalesce(p_token, '')) not between 20 and 4096 then
    perform private.fail('VALIDATION', 'Bad device token');
  end if;
  insert into public.device_tokens (token, user_id, app, platform)
  values (p_token, auth.uid(), p_app, coalesce(nullif(trim(p_platform), ''), 'android'))
  on conflict (token) do update set user_id = excluded.user_id, app = excluded.app, platform = excluded.platform, updated_at = now();
end;
$$;

create or replace function public.unregister_device(p_token text)
returns void
language sql security definer set search_path = ''
as $$ delete from public.device_tokens where token = p_token and user_id = auth.uid(); $$;

-- REQ-061: the owner starts Meta's sign-up (Standard/Premium). The whatsapp-connect Edge
-- Function finishes it with the code Meta returns.
create or replace function public.whatsapp_begin_connect(p_station uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then perform private.fail('FORBIDDEN'); end if;
  perform private.assert_can_write(p_station, 'whatsapp_auto');
  insert into public.whatsapp_accounts (station_id, status, status_reason)
  values (p_station, 'pending', 'Finish the sign-up in the Meta window')
  on conflict (station_id) do update set status = 'pending', status_reason = excluded.status_reason, updated_at = now()
  where public.whatsapp_accounts.status <> 'connected';
end;
$$;

create or replace function public.station_whatsapp_disconnect(p_station uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then perform private.fail('FORBIDDEN'); end if;
  update public.whatsapp_accounts set status = 'disconnected', status_reason = 'Disconnected by the owner',
    connected_at = null, updated_at = now()
  where station_id = p_station;
  delete from private.whatsapp_tokens where station_id = p_station;
  perform private.wa_fallback(p_station, 'WhatsApp not connected');
end;
$$;

-- Service-role functions (Edge Functions only) ----------------------------------------
-- Saves the account after Meta sign-up or a status change from the webhook.
create or replace function public.svc_whatsapp_set_account(
  p_station uuid, p_status text, p_reason text default null, p_waba text default null,
  p_phone_id text default null, p_display text default null, p_token text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if p_status not in ('not_connected', 'pending', 'connected', 'payment_problem', 'disconnected') then
    perform private.fail('VALIDATION', 'Unknown status');
  end if;
  insert into public.whatsapp_accounts (station_id, status, status_reason, waba_id, phone_number_id, display_phone, connected_at)
  values (p_station, p_status, p_reason, p_waba, p_phone_id, p_display, case when p_status = 'connected' then now() end)
  on conflict (station_id) do update set
    status = excluded.status, status_reason = excluded.status_reason,
    waba_id = coalesce(excluded.waba_id, public.whatsapp_accounts.waba_id),
    phone_number_id = coalesce(excluded.phone_number_id, public.whatsapp_accounts.phone_number_id),
    display_phone = coalesce(excluded.display_phone, public.whatsapp_accounts.display_phone),
    connected_at = case when excluded.status = 'connected' then coalesce(public.whatsapp_accounts.connected_at, now()) end,
    updated_at = now();
  if p_token is not null then
    insert into private.whatsapp_tokens (station_id, access_token) values (p_station, p_token)
    on conflict (station_id) do update set access_token = excluded.access_token, updated_at = now();
  end if;
  -- Templates start as pending the first time the account is saved.
  insert into public.whatsapp_templates (station_id, event)
  select p_station, code from public.message_events on conflict do nothing;
  if p_status in ('not_connected', 'disconnected') then
    delete from private.whatsapp_tokens where station_id = p_station;
    perform private.wa_fallback(p_station, 'WhatsApp not connected');
  elsif p_status = 'payment_problem' then
    perform private.wa_fallback(p_station, 'Payment problem in Meta — add a payment method');
  end if;
end;
$$;

-- Template review result from Meta (webhook message_template_status_update).
-- p_name is "csm_<event>". All approved → the pending account becomes Connected.
create or replace function public.svc_whatsapp_template_status(p_waba text, p_name text, p_status text, p_reason text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_station uuid := (select station_id from public.whatsapp_accounts where waba_id = p_waba);
  v_event text := regexp_replace(p_name, '^csm_', '');
  v_status text := case upper(p_status) when 'APPROVED' then 'approved' when 'REJECTED' then 'rejected'
                                        when 'DISABLED' then 'rejected' else 'pending' end;
begin
  if v_station is null or not exists (select 1 from public.message_events where code = v_event) then return; end if;
  insert into public.whatsapp_templates (station_id, event, status, reason)
  values (v_station, v_event, v_status, nullif(trim(p_reason), ''))
  on conflict (station_id, event) do update set status = excluded.status, reason = excluded.reason, updated_at = now();
  if v_status = 'rejected' then
    update public.whatsapp_accounts set status_reason = format('Template "%s" rejected: %s', v_event, coalesce(nullif(trim(p_reason), ''), 'no reason given')),
      updated_at = now() where station_id = v_station;
    update public.message_outbox set status = 'manual', manual_reason = 'Template not approved yet', updated_at = now()
    where station_id = v_station and channel = 'whatsapp' and status = 'queued' and event = v_event;
  elsif not exists (select 1 from public.whatsapp_templates where station_id = v_station and status <> 'approved') then
    update public.whatsapp_accounts set status = 'connected', status_reason = null, connected_at = coalesce(connected_at, now()),
      updated_at = now() where station_id = v_station and status = 'pending';
  end if;
end;
$$;

-- Claims due messages for the dispatcher. Rows stuck in 'sending' for 10 minutes are retried.
create or replace function public.svc_outbox_claim(p_limit integer default 50)
returns table (id bigint, channel text, event text, to_mobile text, title text, body text, params text[],
               ref_id uuid, phone_number_id text, access_token text, tokens text[])
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
begin
  -- A station that lost its connection since the message was queued: send by hand instead.
  update public.message_outbox o set status = 'manual', manual_reason = private.wa_block_reason(o.station_id, o.event), updated_at = now()
  where o.channel = 'whatsapp' and o.status = 'queued' and not private.wa_auto_ready(o.station_id, o.event);

  return query
  with due as (
    select o.id from public.message_outbox o
    where (o.status = 'queued' and o.next_attempt_at <= now())
       or (o.status = 'sending' and o.updated_at < now() - interval '10 minutes')
    order by o.next_attempt_at
    limit greatest(coalesce(p_limit, 50), 1)
    for update skip locked
  ), upd as (
    update public.message_outbox o set status = 'sending', attempts = o.attempts + 1, updated_at = now()
    from due where o.id = due.id
    returning o.*
  )
  select u.id, u.channel, u.event, u.to_mobile, u.title, u.body, private.message_params(u.event, u.vars),
         u.ref_id, a.phone_number_id, t.access_token,
         case when u.channel = 'push' then private.customer_push_tokens(u.customer_id) end
  from upd u
  left join public.whatsapp_accounts a on a.station_id = u.station_id and u.channel = 'whatsapp'
  left join private.whatsapp_tokens t on t.station_id = u.station_id and u.channel = 'whatsapp';
end;
$$;

-- Result of one send. WhatsApp: retry once after 5 minutes, then the manual list with the
-- reason. Meta error 131042 = payment problem on the station's account.
create or replace function public.svc_outbox_report(
  p_message bigint, p_ok boolean, p_error text default null, p_provider_id text default null, p_error_code integer default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare m public.message_outbox;
begin
  select * into m from public.message_outbox where id = p_message for update;
  if m.id is null or m.status <> 'sending' then return; end if;
  if p_ok then
    update public.message_outbox set status = 'sent', provider_message_id = p_provider_id, last_error = null, updated_at = now()
    where id = p_message;
  elsif m.channel = 'push' then
    update public.message_outbox set status = 'failed', last_error = left(p_error, 500), updated_at = now() where id = p_message;
  elsif p_error_code = 131042 then
    perform public.svc_whatsapp_set_account(m.station_id, 'payment_problem', 'Meta could not charge the station''s payment method');
    update public.message_outbox set status = 'manual', manual_reason = 'Payment problem in Meta — add a payment method',
      last_error = left(p_error, 500), updated_at = now() where id = p_message;
  elsif m.attempts < 2 then
    update public.message_outbox set status = 'queued', next_attempt_at = now() + interval '5 minutes',
      last_error = left(p_error, 500), updated_at = now() where id = p_message;
  else
    update public.message_outbox set status = 'manual', manual_reason = 'Automatic send failed: ' || coalesce(left(p_error, 200), 'unknown error'),
      last_error = left(p_error, 500), updated_at = now() where id = p_message;
  end if;
end;
$$;

-- Staff push: notifications not yet pushed, with the phones of everyone who should get them.
create or replace function public.svc_staff_push_claim(p_limit integer default 100)
returns table (id bigint, kind text, title text, body text, ref_id uuid, tokens text[])
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
begin
  return query
  with due as (
    select n.id from public.notifications n
    where (n.push_state is null or (n.push_state = 'sending' and n.pushed_at < now() - interval '10 minutes'))
      and n.created_at > now() - interval '1 day'
    order by n.created_at
    limit greatest(coalesce(p_limit, 100), 1)
    for update skip locked
  ), rcpt as (
    select n.id, coalesce(array_agg(distinct d.token) filter (where d.token is not null), '{}') as tokens
    from due join public.notifications n on n.id = due.id
    left join public.station_members sm on sm.station_id = n.station_id and sm.active
      and (sm.user_id = n.user_id or (n.user_id is null and sm.role in ('owner', 'manager')))
    left join public.device_tokens d on d.user_id = sm.user_id and d.app = 'staff'
    group by n.id
  ), upd as (
    update public.notifications n
    set push_state = case when cardinality(r.tokens) = 0 then 'none' else 'sending' end, pushed_at = now()
    from rcpt r where n.id = r.id
    returning n.id, n.kind, n.title, n.body, n.ref_id, r.tokens
  )
  select u.id, u.kind, u.title, u.body, u.ref_id, u.tokens from upd u where cardinality(u.tokens) > 0;
end;
$$;

create or replace function public.svc_staff_push_report(p_notification bigint, p_ok boolean)
returns void
language sql security definer set search_path = ''
as $$
  update public.notifications set push_state = case when p_ok then 'sent' else 'failed' end, pushed_at = now()
  where id = p_notification and push_state = 'sending';
$$;

-- FCM said the token is no longer valid.
create or replace function public.svc_drop_device_token(p_token text)
returns void
language sql security definer set search_path = ''
as $$ delete from public.device_tokens where token = p_token; $$;

revoke execute on function
  public.svc_whatsapp_set_account(uuid, text, text, text, text, text, text),
  public.svc_whatsapp_template_status(text, text, text, text),
  public.svc_outbox_claim(integer),
  public.svc_outbox_report(bigint, boolean, text, text, integer),
  public.svc_staff_push_claim(integer),
  public.svc_staff_push_report(bigint, boolean),
  public.svc_drop_device_token(text)
from public, anon, authenticated;
grant execute on function
  public.svc_whatsapp_set_account(uuid, text, text, text, text, text, text),
  public.svc_whatsapp_template_status(text, text, text, text),
  public.svc_outbox_claim(integer),
  public.svc_outbox_report(bigint, boolean, text, text, integer),
  public.svc_staff_push_claim(integer),
  public.svc_staff_push_report(bigint, boolean),
  public.svc_drop_device_token(text)
to service_role;

revoke execute on function
  public.station_set_message_events(uuid, jsonb),
  public.message_mark(bigint, text),
  public.notifications_mark_read(uuid),
  public.register_device(text, text, text),
  public.unregister_device(text),
  public.whatsapp_begin_connect(uuid),
  public.station_whatsapp_disconnect(uuid)
from public, anon;
grant execute on function
  public.station_set_message_events(uuid, jsonb),
  public.message_mark(bigint, text),
  public.notifications_mark_read(uuid),
  public.register_device(text, text, text),
  public.unregister_device(text),
  public.whatsapp_begin_connect(uuid),
  public.station_whatsapp_disconnect(uuid)
to authenticated;

-- Dispatcher kick: pg_cron calls the notify-dispatch Edge Function every minute through
-- pg_net. The project URL and the shared secret live in Vault ("project_url",
-- "dispatch_secret"); until both are set this does nothing.
create or replace function private.kick_dispatch()
returns void
language plpgsql security definer set search_path = ''
as $$
declare v_url text; v_secret text;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_net')
     or not exists (select 1 from pg_namespace where nspname = 'vault') then
    return;
  end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = ''project_url''' into v_url;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = ''dispatch_secret''' into v_secret;
  if v_url is null or v_secret is null then return; end if;
  if not exists (select 1 from public.message_outbox where status in ('queued', 'sending'))
     and not exists (select 1 from public.notifications where push_state is null and created_at > now() - interval '1 day') then
    return;
  end if;
  execute 'select net.http_post(url := $1, headers := $2, body := ''{}''::jsonb)'
    using rtrim(v_url, '/') || '/functions/v1/notify-dispatch',
          jsonb_build_object('Content-Type', 'application/json', 'x-dispatch-secret', v_secret);
end;
$$;
revoke execute on function private.kick_dispatch() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('notify-dispatch', '* * * * *', 'select private.kick_dispatch()');
    perform cron.schedule('dues-reminders', '5 4 * * *', 'select private.daily_dues_reminders()');
  end if;
end $$;

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

-- ===== supabase/migrations/20261121000022_hardening_release.sql =====
-- TASK-068 · TASK-072 — security hardening found by the Phase 9 review, and the app version
-- manifest used by the in-app updater (direct APK distribution, no Play Store).

-- SEC-01 (review finding, Medium): Supabase's default grants give anon/authenticated TRUNCATE
-- on every public table, and write privileges on views. TRUNCATE is not reachable through the
-- REST API and bypasses nothing an API caller can send today, but it ignores RLS, so remove it.
do $$
declare r record;
begin
  for r in select c.relname, c.relkind from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relkind in ('r', 'v', 'm', 'p') loop
    execute format('revoke truncate on public.%I from anon, authenticated', r.relname);
    if r.relkind in ('v', 'm') then
      execute format('revoke insert, update, delete on public.%I from anon, authenticated', r.relname);
    end if;
  end loop;
end $$;

-- REQ-045 / TASK-072: latest APK per app. Apps compare their build number on start and offer
-- the download; below min_build they must update.
create table public.app_versions (
  app        text primary key check (app in ('staff', 'customer')),
  build      integer not null check (build > 0),
  version    text not null,
  min_build  integer not null default 1 check (min_build > 0),
  apk_url    text not null check (apk_url ~ '^https://'),
  notes      text,
  updated_at timestamptz not null default now()
);
alter table public.app_versions enable row level security;
create policy app_versions_read on public.app_versions for select to anon, authenticated using (true);
revoke insert, update, delete, truncate on public.app_versions from anon, authenticated;
create trigger audit_app_versions after insert or update on public.app_versions
  for each row execute function private.audit_row();

-- Super admin publishes a new build (after uploading the signed APK).
create or replace function public.admin_publish_app_version(
  p_app text, p_build integer, p_version text, p_apk_url text, p_min_build integer default null, p_notes text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform private.assert_super_admin();
  if p_app not in ('staff', 'customer') then perform private.fail('VALIDATION', 'Unknown app'); end if;
  if coalesce(p_build, 0) <= 0 or p_apk_url !~ '^https://' then perform private.fail('VALIDATION', 'Build number and an https link are required'); end if;
  if exists (select 1 from public.app_versions where app = p_app and build >= p_build) then
    perform private.fail('VALIDATION', 'Build number must be higher than the published one');
  end if;
  insert into public.app_versions (app, build, version, min_build, apk_url, notes)
  values (p_app, p_build, p_version, coalesce(p_min_build, 1), p_apk_url, nullif(trim(p_notes), ''))
  on conflict (app) do update set build = excluded.build, version = excluded.version,
    min_build = coalesce(p_min_build, public.app_versions.min_build), apk_url = excluded.apk_url, notes = excluded.notes, updated_at = now();
end;
$$;
revoke execute on function public.admin_publish_app_version(text, integer, text, text, integer, text) from public, anon;
grant execute on function public.admin_publish_app_version(text, integer, text, text, integer, text) to authenticated;

-- ===== supabase/migrations/20261122000023_sms_gateway.sql =====
-- TASK-005 · REQ-001, REQ-047 — login codes by SMS through the platform's own Android
-- "SMS gateway" phone (a SIM with an SMS bundle), instead of a paid SMS aggregator.
--
-- Supabase Auth → Send SMS hook → Edge Function send-sms → svc_sms_enqueue() → this queue.
-- The gateway phone polls the sms-gateway Edge Function (shared GATEWAY_SECRET), which claims
-- due messages with svc_sms_claim(), sends them from the SIM, and reports with svc_sms_report().
-- Codes older than 5 minutes are never sent (the OTP has expired by then).

create table private.sms_queue (
  id         bigint generated always as identity primary key,
  phone      text not null check (phone ~ '^\+?[0-9]{10,15}$'),
  body       text not null check (length(body) between 1 and 320),
  kind       text not null default 'otp',
  status     text not null default 'queued' check (status in ('queued', 'sending', 'sent', 'failed', 'expired', 'dropped')),
  attempts   integer not null default 0,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index sms_queue_due_idx on private.sms_queue(created_at) where status in ('queued', 'sending');
create index sms_queue_phone_idx on private.sms_queue(phone, created_at desc);

-- Last contact from each gateway phone (shown to the platform admin).
create table private.sms_gateways (
  device     text primary key,
  last_seen  timestamptz not null default now(),
  info       jsonb not null default '{}'::jsonb
);

alter table private.sms_queue    enable row level security;
alter table private.sms_gateways enable row level security;
revoke all on private.sms_queue, private.sms_gateways from public, anon, authenticated;

-- Called by the send-sms hook. Protects the SIM bundle: at most 5 messages per number per hour.
create or replace function public.svc_sms_enqueue(p_phone text, p_body text, p_kind text default 'otp')
returns text
language plpgsql security definer set search_path = ''
as $$
declare v_phone text := '+' || regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
begin
  if v_phone !~ '^\+[0-9]{10,15}$' then perform private.fail('VALIDATION', 'Bad phone number'); end if;
  if (select count(*) from private.sms_queue where phone = v_phone and created_at > now() - interval '1 hour') >= 5 then
    insert into private.sms_queue (phone, body, kind, status, last_error)
    values (v_phone, left(p_body, 320), coalesce(p_kind, 'otp'), 'dropped', 'More than 5 messages to this number in an hour');
    return 'dropped';
  end if;
  insert into private.sms_queue (phone, body, kind) values (v_phone, left(p_body, 320), coalesce(p_kind, 'otp'));
  return 'queued';
end;
$$;

-- Called by the gateway phone (through sms-gateway). Expires stale codes, then hands out due
-- messages; a message stuck in 'sending' for 2 minutes is offered again (max 3 attempts).
create or replace function public.svc_sms_claim(p_device text, p_limit integer default 10, p_info jsonb default '{}'::jsonb)
returns table (id bigint, phone text, body text)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
begin
  insert into private.sms_gateways (device, last_seen, info) values (left(coalesce(p_device, 'gateway'), 80), now(), coalesce(p_info, '{}'))
  on conflict (device) do update set last_seen = now(), info = excluded.info;

  update private.sms_queue q set status = 'expired', updated_at = now()
  where q.status in ('queued', 'sending') and q.kind = 'otp' and q.created_at < now() - interval '5 minutes';

  return query
  with due as (
    select q.id from private.sms_queue q
    where (q.status = 'queued' or (q.status = 'sending' and q.updated_at < now() - interval '2 minutes'))
      and q.attempts < 3
    order by q.created_at
    limit greatest(least(coalesce(p_limit, 10), 50), 1)
    for update skip locked
  )
  update private.sms_queue q set status = 'sending', attempts = q.attempts + 1, updated_at = now()
  from due where q.id = due.id
  returning q.id, q.phone, q.body;
end;
$$;

create or replace function public.svc_sms_report(p_id bigint, p_ok boolean, p_error text default null)
returns void
language sql security definer set search_path = ''
as $$
  update private.sms_queue
  set status = case when p_ok then 'sent' when attempts >= 3 then 'failed' else 'queued' end,
      last_error = case when p_ok then null else left(p_error, 300) end,
      updated_at = now()
  where id = p_id and status = 'sending';
$$;

-- Platform admin: is the gateway alive and is it keeping up?
create or replace function public.admin_sms_status()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform private.assert_super_admin();
  return jsonb_build_object(
    'last_seen', (select max(last_seen) from private.sms_gateways),
    'devices', (select coalesce(jsonb_agg(jsonb_build_object('device', device, 'last_seen', last_seen, 'info', info) order by last_seen desc), '[]')
                from private.sms_gateways),
    'waiting', (select count(*) from private.sms_queue where status in ('queued', 'sending')),
    'sent_today', (select count(*) from private.sms_queue where status = 'sent' and updated_at >= date_trunc('day', now() at time zone 'Asia/Karachi') at time zone 'Asia/Karachi'),
    'failed_today', (select count(*) from private.sms_queue where status in ('failed', 'expired', 'dropped')
                       and updated_at >= date_trunc('day', now() at time zone 'Asia/Karachi') at time zone 'Asia/Karachi')
  );
end;
$$;

revoke execute on function
  public.svc_sms_enqueue(text, text, text), public.svc_sms_claim(text, integer, jsonb), public.svc_sms_report(bigint, boolean, text)
from public, anon, authenticated;
grant execute on function
  public.svc_sms_enqueue(text, text, text), public.svc_sms_claim(text, integer, jsonb), public.svc_sms_report(bigint, boolean, text)
to service_role;
revoke execute on function public.admin_sms_status() from public, anon;
grant execute on function public.admin_sms_status() to authenticated;
