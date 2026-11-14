-- Phase 5 follow-up (run once, after dashboard_phase5.sql): day-90 purge queues files for the Storage API.

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
