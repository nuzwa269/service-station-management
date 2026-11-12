-- All Phase 1 migrations in order, for pasting into the Supabase dashboard SQL Editor.
-- Generated from supabase/migrations on 2026-11-13. Run once on an empty project.

-- ===== migrations/20261113000001_core.sql =====
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

-- ===== migrations/20261113000002_plans.sql =====
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

-- ===== migrations/20261113000003_audit.sql =====
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

-- ===== migrations/20261113000004_support_access.sql =====
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

-- ===== migrations/20261113000005_station_functions.sql =====
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

-- ===== migrations/20261113000006_storage.sql =====
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
