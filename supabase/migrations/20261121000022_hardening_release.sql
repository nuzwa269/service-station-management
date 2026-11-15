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
