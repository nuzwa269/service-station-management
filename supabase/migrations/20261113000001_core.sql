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
