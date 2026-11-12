-- Test helpers. Loaded after migrations, before each test file.
-- Tests are plain SQL with ASSERT so they run on PGlite (local, no Docker)
-- and on a real Supabase database (CI) with the same runner.
create schema if not exists tests;
grant usage on schema tests to anon, authenticated, service_role;

-- Creates an auth user with a confirmed (or unconfirmed) Pakistani phone.
create or replace function tests.create_user(p_phone text, p_confirmed boolean default true)
returns uuid language sql as $$
  insert into auth.users (phone, phone_confirmed_at)
  values (p_phone, case when p_confirmed then now() end)
  returning id;
$$;

-- Sets the JWT subject for the session (role is switched with SET ROLE in the test).
create or replace function tests.as_user(p_uid uuid)
returns void language sql as $$
  select set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), false);
$$;

-- Asserts that a statement fails with the given error code (our private.fail message).
create or replace function tests.throws(p_sql text, p_code text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm = p_code then return; end if;
    raise exception 'expected % but got: % (%)', p_code, sqlerrm, p_sql;
  end;
  raise exception 'expected % but statement succeeded: %', p_code, p_sql;
end;
$$;

-- Shared fixture values live in a session table readable by every role.
create table if not exists tests.fx (k text primary key, v uuid);
grant select, insert on tests.fx to anon, authenticated, service_role;
create or replace function tests.id(p_key text) returns uuid language sql stable as $$
  select v from tests.fx where k = p_key
$$;
grant execute on all functions in schema tests to anon, authenticated, service_role;
