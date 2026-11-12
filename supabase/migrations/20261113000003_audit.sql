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
