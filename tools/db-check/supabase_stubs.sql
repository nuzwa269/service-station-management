-- Minimal stand-ins for the Supabase platform objects our migrations use.
-- Only for running migrations + tests in PGlite (no Docker). Never deployed.
create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;

create schema auth;
create table auth.users (
  id uuid primary key,          -- like Supabase: no default, callers must supply it
  phone text unique,
  phone_confirmed_at timestamptz,
  email text
);
create function auth.uid() returns uuid language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;
grant usage on schema auth to anon, authenticated, service_role;

create schema storage;
create table storage.buckets (
  id text primary key, name text not null, public boolean default false,
  file_size_limit bigint, allowed_mime_types text[]
);
create table storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets(id),
  name text not null,
  owner uuid
);
alter table storage.objects enable row level security;
-- Like Supabase: files are deleted through the Storage API, never with SQL.
create function storage.protect_delete() returns trigger language plpgsql as $$
begin
  raise exception 'Direct deletion from storage tables is not allowed. Use the Storage API instead.';
end $$;
create trigger protect_objects_delete before delete on storage.objects for each statement execute function storage.protect_delete();
create function storage.foldername(name text) returns text[] language sql immutable as $$
  select (string_to_array(name, '/'))[1:array_length(string_to_array(name, '/'), 1) - 1]
$$;
grant usage on schema storage to anon, authenticated, service_role;
grant select, insert, update on storage.objects to authenticated;

-- Supabase grants table privileges in public to these roles by default.
grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
