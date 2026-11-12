-- TEST-003 · REQ-003 · TASK-011
-- Cross-station isolation over EVERY public table and view, discovered from the catalog,
-- so a new table without a correct policy fails this test automatically.

-- Every public table has RLS on; every public view runs with the caller's rights.
do $$
declare r record;
begin
  for r in
    select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity
  loop
    raise exception 'TEST-003: table public.% has no row-level security', r.relname;
  end loop;
  for r in
    select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'v'
      and not coalesce(c.reloptions @> array['security_invoker=true'], false)
  loop
    raise exception 'TEST-003: view public.% is not security_invoker', r.relname;
  end loop;
end $$;

-- Fixture: two stations A and B, each with an owner; A also has a mechanic.
insert into tests.fx values
  ('ownerA', tests.create_user('923001111111')),
  ('ownerB', tests.create_user('923002222222')),
  ('mechA',  tests.create_user('923003333333'));

set role authenticated;
select tests.as_user(tests.id('ownerA'));
insert into tests.fx values ('A', public.station_signup('Alpha Autos', 'Lahore', 'Owner A'));
select public.station_grant_support(tests.id('A'), 24);
select tests.as_user(tests.id('ownerB'));
insert into tests.fx values ('B', public.station_signup('Bravo Motors', 'Karachi', 'Owner B'));
select public.station_grant_support(tests.id('B'), 24);
reset role;

set role service_role;
select public.admin_add_member(tests.id('ownerA'), tests.id('A'), tests.id('mechA'), 'Mech A', '0300-3333333', 'mechanic');
reset role;

-- Generic check: as each user, no row of the other station is visible anywhere.
create or replace function tests.leaks(p_other uuid)
returns table (relation text, leaked bigint) language plpgsql as $$
declare r record; n bigint;
begin
  for r in
    select c.table_name, c.column_name from information_schema.columns c
    join information_schema.tables t on t.table_schema = c.table_schema and t.table_name = c.table_name
    where c.table_schema = 'public'
      and (c.column_name = 'station_id' or (c.table_name = 'stations' and c.column_name = 'id'))
  loop
    execute format('select count(*) from public.%I where %I = $1', r.table_name, r.column_name)
      into n using p_other;
    relation := r.table_name; leaked := n;
    return next;
  end loop;
end $$;
grant execute on function tests.leaks(uuid) to authenticated, anon;

set role authenticated;

select tests.as_user(tests.id('ownerA'));
do $$
declare r record; checked int := 0;
begin
  for r in select * from tests.leaks(tests.id('B')) loop
    checked := checked + 1;
    assert r.leaked = 0, format('TEST-003: owner A sees %s rows of station B in %s', r.leaked, r.relation);
  end loop;
  assert checked >= 5, 'TEST-003: expected at least 5 tenant relations, found ' || checked;
  assert (select count(*) from public.stations where id = tests.id('A')) = 1, 'owner A must see own station';
end $$;

select tests.as_user(tests.id('mechA'));
do $$
declare r record;
begin
  for r in select * from tests.leaks(tests.id('B')) loop
    assert r.leaked = 0, format('TEST-003: mechanic A sees %s rows of station B in %s', r.leaked, r.relation);
  end loop;
end $$;

select tests.as_user(tests.id('ownerB'));
do $$
declare r record;
begin
  for r in select * from tests.leaks(tests.id('A')) loop
    assert r.leaked = 0, format('TEST-003: owner B sees %s rows of station A in %s', r.leaked, r.relation);
  end loop;
  -- Another station's record returns "not found", with no data leaked.
  perform tests.throws(format('select public.station_update_profile(%L, ''X Y'', null, null, null, null, false, 0, 0)', tests.id('A')), 'FORBIDDEN');
  assert (select count(*) from public.profiles where mobile = '03001111111') = 0, 'owner B must not see owner A profile';
end $$;

reset role;
set role anon;
select tests.as_user(null);
do $$
begin
  assert (select count(*) from public.stations) = 0, 'anon must see no stations';
  assert (select count(*) from public.plans) = 3, 'anon may read the public plan catalogue';
end $$;
reset role;
