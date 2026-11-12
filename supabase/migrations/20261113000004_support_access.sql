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
