-- TASK-068 · REQ-003, REQ-005, REQ-008 — threat-model checks over the whole schema, so a new
-- table or function that breaks a rule fails CI.

-- T1 SECURITY DEFINER functions must pin search_path (no schema-hijack through a user table).
do $$
declare r record; bad text := '';
begin
  for r in
    select n.nspname || '.' || p.proname as fn from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'private') and p.prosecdef
      and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')
  loop
    bad := bad || r.fn || ' ';
  end loop;
  assert bad = '', 'T1: SECURITY DEFINER without search_path: ' || bad;
end $$;

-- T2 Apps never write tables directly: every write goes through a checked function.
do $$
declare r record; bad text := '';
begin
  for r in
    select c.relname, x.priv, y.role from pg_class c join pg_namespace n on n.oid = c.relnamespace
    cross join (values ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) x(priv)
    cross join (values ('anon'), ('authenticated')) y(role)
    where n.nspname = 'public' and c.relkind in ('r', 'v', 'm')
      and has_table_privilege(y.role, c.oid, x.priv)
  loop
    bad := bad || format('%s:%s:%s ', r.relname, r.role, r.priv);
  end loop;
  assert bad = '', 'T2: direct write privilege: ' || bad;
end $$;

-- T3 Logged-out callers (anon) can run only the public sign-up / pricing helpers.
do $$
declare r record; bad text := '';
begin
  for r in
    select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
      and p.prokind = 'f'
      and p.proname not in ('station_code_available')       -- allowlist; keep it short
      and p.prorettype <> 'trigger'::regtype
  loop
    bad := bad || r.proname || ' ';
  end loop;
  assert bad = '', 'T3: callable without login: ' || bad;
end $$;

-- T4 The private schema (tokens, helpers) is not reachable as data by app roles.
do $$
declare r record; bad text := '';
begin
  for r in
    select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'private' and c.relkind = 'r'
      and (has_table_privilege('authenticated', c.oid, 'SELECT') or has_table_privilege('anon', c.oid, 'SELECT'))
  loop
    bad := bad || r.relname || ' ';
  end loop;
  assert bad = '', 'T4: private table readable: ' || bad;
end $$;

-- T5 Append-only ledgers: money and stock history can't be changed even by a definer bug.
do $$
declare t text;
begin
  foreach t in array array['stock_movements', 'payments', 'credit_notes', 'job_history', 'salary_advances', 'audit_log'] loop
    assert exists (select 1 from pg_trigger g join pg_class c on c.oid = g.tgrelid
                   where c.relname = t and not g.tgisinternal and g.tgtype & 16 = 16),   -- fires on UPDATE
      'T5: ' || t || ' has no append-only trigger';
  end loop;
end $$;

-- T6 Super admin sees no station data without a support grant (REQ-005).
insert into tests.fx values
  ('sa',    tests.create_user('923441111111')),
  ('owner', tests.create_user('923442222222'));
update auth.users set phone = phone where false;
set role authenticated;
select tests.as_user(tests.id('owner'));
insert into tests.fx values ('S', public.station_signup('Secure Motors', 'Lahore', 'Owner'));
insert into tests.fx values ('cust', public.station_save_customer(tests.id('S'), null, 'Private Person', '0300-5556667'));
reset role;
insert into public.profiles (id, full_name, is_super_admin) values (tests.id('sa'), 'Platform Admin', true)
  on conflict (id) do update set is_super_admin = true;
set role authenticated;
select tests.as_user(tests.id('sa'));
do $$ begin
  assert (select count(*) from public.customers where station_id = tests.id('S')) = 0, 'T6: SA read customers without a grant';
  assert (select count(*) from public.invoices where station_id = tests.id('S')) = 0, 'T6: SA read invoices without a grant';
end $$;
reset role;

-- TASK-072 App releases: only the super admin publishes; build numbers only go up; anyone reads.
set role authenticated;
select tests.as_user(tests.id('owner'));
select tests.throws($q$select public.admin_publish_app_version('staff', 2, '1.0.1', 'https://example.test/staff.apk')$q$, 'FORBIDDEN');
select tests.as_user(tests.id('sa'));
select public.admin_publish_app_version('staff', 2, '1.0.1', 'https://example.test/staff.apk', 1, 'Payroll and reports');
select tests.throws($q$select public.admin_publish_app_version('staff', 2, '1.0.1', 'https://example.test/staff.apk')$q$, 'VALIDATION');
select tests.throws($q$select public.admin_publish_app_version('staff', 3, '1.0.2', 'http://insecure.test/staff.apk')$q$, 'VALIDATION');
reset role;
set role anon;
select tests.as_user(null);
do $$ begin
  assert (select build from public.app_versions where app = 'staff') = 2, 'phones read the latest build before login';
end $$;
reset role;
