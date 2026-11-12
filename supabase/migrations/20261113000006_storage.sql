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
