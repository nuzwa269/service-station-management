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

-- Function privileges: service-role-only functions are not callable by logged-in users,
-- and every admin_* function a logged-in user can call checks for the super admin.
do $$
declare r record;
begin
  for r in
    select p.proname, p.prosrc, p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'admin\_%'
  loop
    if r.proname in ('admin_add_member', 'admin_confirm_provider_payment') then
      if has_function_privilege('authenticated', r.oid, 'execute') or has_function_privilege('anon', r.oid, 'execute') then
        raise exception 'TEST-003: % must be callable by the service role only', r.proname;
      end if;
    elsif has_function_privilege('authenticated', r.oid, 'execute')
          and r.prosrc not like '%assert_super_admin%' and r.prosrc not like '%has_support_grant%' then
      raise exception 'TEST-003: % is callable by users but does not check for the super admin', r.proname;
    end if;
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
-- Give station B a row in every Phase 2 table so a leak would show up.
insert into tests.fx values ('itemB', public.station_save_item(tests.id('B'), '{"code":"B1","name":"B filter"}'::jsonb));
insert into tests.fx values ('supB', public.station_save_supplier(tests.id('B'), null, 'B Supplier', null));
select public.station_post_purchase(tests.id('B'), tests.id('supB'), null, 'B-1', current_date,
  jsonb_build_array(jsonb_build_object('item_id', tests.id('itemB'), 'qty', 5, 'unit_cost_paisa', 100)), 0);
select public.station_request_stock_adjustment(tests.id('B'), tests.id('itemB'), -1, 'damaged');
insert into tests.fx values ('custB', public.station_save_customer(tests.id('B'), null, 'B Customer', '03009990000'));
insert into tests.fx values ('carB', public.station_save_vehicle(tests.id('B'), null, tests.id('custB'), 'KHI-1'));
-- Phase 3: a job card with checklist, line, history and a notification.
select public.station_save_checklist_template(tests.id('B'), array['Brakes']);
insert into tests.fx values ('jobB', public.station_create_job(tests.id('B'), tests.id('custB'), tests.id('carB'), 1000, 'H', 'B job'));
select public.job_add_line(tests.id('jobB'), 'part', tests.id('itemB'), null, 1);
select public.job_record_approval(tests.id('jobB'), true, 'phone', 'B Customer');
select public.job_add_line(tests.id('jobB'), 'part', tests.id('itemB'), null, 10);  -- extra, drives stock negative -> notification
-- Phase 4: service, invoice, payments, credit note, day closing.
select public.station_save_service(tests.id('B'), null, 'B labour', 50000, 0);
insert into tests.fx values ('jobB2', public.station_create_job(tests.id('B'), tests.id('custB'), tests.id('carB'), 2000, 'H'));
select public.job_add_line(tests.id('jobB2'), 'labour', null, 'B work', 1, 100000);
select public.job_record_approval(tests.id('jobB2'), true, 'phone', 'B Customer');
insert into tests.fx values ('invB', public.station_create_invoice(tests.id('jobB2')));
select public.invoice_record_payment(tests.id('invB'), 100000, 'cash');
select public.invoice_request_refund(tests.id('invB'), 10000, 'credit', 'Goodwill');
select public.job_record_advance(tests.id('jobB'), 5000, 'cash');
select public.station_close_day(tests.id('B'), private.today_pk(), 105000, null);  -- 1,000 + 50 advance
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
  assert checked >= 20, 'TEST-003: expected at least 20 tenant relations, found ' || checked;
  assert (select count(*) from public.station_search_customers(tests.id('B'), 'B Customer')) = 0, 'TEST-003: search across stations';
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
