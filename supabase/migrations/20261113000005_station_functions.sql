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
