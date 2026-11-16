-- Releases bucket (APK download links). Run once in the Supabase SQL Editor.

-- TASK-072 · REQ-045 — public download links for the Android APKs (direct distribution and
-- the in-app updater). Anyone can download; only the platform super admin can upload.
-- APKs are split per phone type (arm64 / armeabi-v7a), ~20 MB each, under the 50 MB limit.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('releases', 'releases', true, 52428800,
        array['application/vnd.android.package-archive', 'application/octet-stream'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists releases_admin_insert on storage.objects;
drop policy if exists releases_admin_update on storage.objects;
drop policy if exists releases_admin_delete on storage.objects;
create policy releases_admin_insert on storage.objects
  for insert to authenticated with check (bucket_id = 'releases' and private.is_super_admin());
create policy releases_admin_update on storage.objects
  for update to authenticated using (bucket_id = 'releases' and private.is_super_admin());
create policy releases_admin_delete on storage.objects
  for delete to authenticated using (bucket_id = 'releases' and private.is_super_admin());
