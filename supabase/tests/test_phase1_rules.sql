-- TEST-001, 002, 004, 005, 006, 058 · TASK-014…019
insert into tests.fx values
  ('owner',      tests.create_user('923004444444')),
  ('unverified', tests.create_user('923005555555', false)),
  ('cashier',    tests.create_user('923006666666')),
  ('mech',       tests.create_user('923007777777')),
  ('admin',      tests.create_user('923008888888'));
insert into public.profiles (id, full_name, mobile, is_super_admin)
values (tests.id('admin'), 'Platform Admin', '03008888888', true);

-- TEST-001 Station sign-up --------------------------------------------------
set role authenticated;
select tests.as_user(tests.id('unverified'));
select tests.throws($$select public.station_signup('Charlie Car Care', 'Multan', 'Un Verified')$$, 'PHONE_NOT_VERIFIED');

select tests.as_user(tests.id('owner'));
select tests.throws($$select public.station_signup('X', 'Multan', 'Owner')$$, 'VALIDATION');
insert into tests.fx values ('S', public.station_signup('Delta Service Station', 'Islamabad', 'Danish Owner', 'owner@example.com'));
do $$
begin
  assert (select role from public.station_members where user_id = tests.id('owner')) = 'owner', 'TEST-001: owner membership';
  assert (select status from public.station_entitlements where station_id = tests.id('S')) = 'trial', 'TEST-001: trial status';
  assert (select effective_plan from public.station_entitlements where station_id = tests.id('S')) = 'premium', 'TEST-001: trial has Premium features';
  assert (select renews_at::date - now()::date from public.station_entitlements where station_id = tests.id('S')) = 14, 'TEST-001: 14-day trial';
  assert (select mobile from public.profiles where id = tests.id('owner')) = '03004444444', 'TEST-001: mobile normalised';
  assert (select length(station_code) from public.stations where id = tests.id('S')) = 6, 'station code';
end $$;
select tests.throws($$select public.station_signup('Delta Two', 'Islamabad', 'Danish Owner')$$, 'ALREADY_REGISTERED');
reset role;

-- TEST-002 Users and roles ---------------------------------------------------
set role service_role;
select public.admin_add_member(tests.id('owner'), tests.id('S'), tests.id('cashier'), 'Cash Ier', '0300-6666666', 'cashier');
insert into tests.fx values ('mechMember',
  public.admin_add_member(tests.id('owner'), tests.id('S'), tests.id('mech'), 'Mech Anic', '03007777777', 'mechanic'));
-- A non-owner actor cannot add members, even through the service-role path.
select tests.throws(format($$select public.admin_add_member(%L, %L, gen_random_uuid(), 'Z Z', '03009999999', 'manager')$$,
  tests.id('cashier'), tests.id('S')), 'FORBIDDEN');
select tests.throws(format($$select public.admin_add_member(%L, %L, gen_random_uuid(), 'Z Z', '03009999999', 'owner')$$,
  tests.id('owner'), tests.id('S')), 'VALIDATION');
reset role;

set role authenticated;
select tests.as_user(tests.id('owner'));
do $$
begin
  assert (select count(*) from public.station_members where station_id = tests.id('S')) = 3, 'TEST-002: owner sees 3 members';
end $$;
select tests.as_user(tests.id('mech'));
do $$
begin
  assert (select count(*) from public.station_members) = 1, 'TEST-002: mechanic sees only own membership';
  perform tests.throws(format('select public.station_set_member_active(%L, false)', tests.id('mechMember')), 'NOT_FOUND');
end $$;
select tests.as_user(tests.id('owner'));
select public.station_set_member_role(tests.id('mechMember'), 'manager');
select public.station_set_member_role(tests.id('mechMember'), 'mechanic');
select public.station_set_member_active(tests.id('mechMember'), false);
select tests.as_user(tests.id('mech'));
do $$
begin
  assert (select count(*) from public.stations) = 0, 'TEST-002: deactivated user sees no station';
end $$;
select tests.as_user(tests.id('owner'));
select public.station_set_member_active(tests.id('mechMember'), true);
do $$
declare v_owner_member uuid;
begin
  select id into v_owner_member from public.station_members where user_id = tests.id('owner');
  perform tests.throws(format('select public.station_set_member_active(%L, false)', v_owner_member), 'VALIDATION');
end $$;

-- TEST-004 Station profile and tax --------------------------------------------
select public.station_update_profile(tests.id('S'), 'Delta Service Station', 'G-9 Markaz', '051-1234567',
  '1234567-8', '17-00-1234-567-89', true, 17, 16, tests.id('S')::text || '/logo.png');
select tests.throws(format($$select public.station_update_profile(%L, 'Delta', null, null, null, null, true, 101, 0)$$, tests.id('S')), 'VALIDATION');
select tests.throws(format($$select public.station_update_profile(%L, 'Delta', null, null, null, null, true, 16.555, 0)$$, tests.id('S')), 'VALIDATION');
select tests.throws(format($$select public.station_update_profile(%L, 'Delta', null, null, null, null, false, 0, 0, 'other-station/logo.png')$$, tests.id('S')), 'VALIDATION');
select tests.as_user(tests.id('cashier'));
select tests.throws(format($$select public.station_update_profile(%L, 'Hacked', null, null, null, null, false, 0, 0)$$, tests.id('S')), 'FORBIDDEN');
reset role;
do $$
begin
  assert (select parts_tax_pct from public.stations where id = tests.id('S')) = 17, 'TEST-004: parts tax saved';
  assert (select ntn from public.stations where id = tests.id('S')) = '1234567-8', 'TEST-004: NTN saved';
end $$;

-- TEST-058 Audit log ---------------------------------------------------------
do $$
begin
  assert exists (
    select 1 from public.audit_log
    where table_name = 'stations' and action = 'update' and actor_id = tests.id('owner')
      and changes -> 'parts_tax_pct' ->> 'old' = '0.00' and changes -> 'parts_tax_pct' ->> 'new' = '17.00'
  ), 'TEST-058: tax change recorded old -> new with actor';
  assert exists (select 1 from public.audit_log where table_name = 'station_members' and action = 'update'
                 and changes ? 'active'), 'TEST-058: deactivation recorded';
  perform tests.throws('update public.audit_log set action = ''x''', 'AUDIT_IMMUTABLE');
  perform tests.throws('delete from public.audit_log', 'AUDIT_IMMUTABLE');
end $$;
set role authenticated;
select tests.as_user(tests.id('owner'));
do $$ begin
  assert (select count(*) from public.audit_log) > 0, 'TEST-058: owner (trial = Premium) sees audit log';
end $$;
select tests.as_user(tests.id('cashier'));
do $$ begin
  assert (select count(*) from public.audit_log) = 0, 'TEST-058: cashier cannot see audit log';
end $$;
reset role;

-- TEST-006 Plans and feature gating, REQ-007/009 status -------------------------
update public.subscriptions set state = 'active', plan_code = 'basic', current_period_end = now() + interval '20 days'
 where station_id = tests.id('S');
do $$
begin
  assert (select status from public.station_entitlements where station_id = tests.id('S')) = 'active', 'active';
  assert not exists (select 1 from public.station_entitlements
                     where station_id = tests.id('S') and 'booking' = any(features)), 'TEST-006: Basic has no booking';
  perform private.assert_can_write(tests.id('S'), 'core');
  perform tests.throws(format('select private.assert_can_write(%L, ''booking'')', tests.id('S')), 'FEATURE_LOCKED');
end $$;
set role authenticated;
select tests.as_user(tests.id('owner'));
do $$ begin
  assert (select count(*) from public.audit_log) = 0, 'TEST-058: audit log view is Standard+';
end $$;
reset role;

update public.subscriptions set current_period_end = now() - interval '3 days' where station_id = tests.id('S');
do $$ begin
  assert (select status from public.station_entitlements where station_id = tests.id('S')) = 'grace', 'TEST-009: days 1-7 grace';
  perform private.assert_can_write(tests.id('S'), 'core');
end $$;
update public.subscriptions set current_period_end = now() - interval '8 days' where station_id = tests.id('S');
do $$ begin
  assert (select status from public.station_entitlements where station_id = tests.id('S')) = 'read_only', 'TEST-009: day 8 read-only';
  perform tests.throws(format('select private.assert_can_write(%L, ''core'')', tests.id('S')), 'READ_ONLY');
end $$;
update public.subscriptions set state = 'trial', plan_code = 'premium', trial_ends_at = now() - interval '1 day'
 where station_id = tests.id('S');
do $$ begin
  assert (select status from public.station_entitlements where station_id = tests.id('S')) = 'grace', 'TEST-007: grace after trial end';
end $$;

-- TEST-005 Support access ------------------------------------------------------
set role authenticated;
select tests.as_user(tests.id('admin'));
do $$ begin
  assert (select count(*) from public.stations) = 0, 'TEST-005: no grant -> super admin sees no station data';
  assert (select count(*) from public.subscriptions where station_id = tests.id('S')) = 1, 'TEST-005: super admin sees plan/status';
  perform tests.throws(format('select public.admin_open_support_session(%L)', tests.id('S')), 'NOT_FOUND');
end $$;
select tests.as_user(tests.id('owner'));
select tests.throws(format('select public.station_grant_support(%L, 5)', tests.id('S')), 'VALIDATION');
insert into tests.fx values ('grant', public.station_grant_support(tests.id('S'), 24));
select tests.as_user(tests.id('cashier'));
select tests.throws(format('select public.station_grant_support(%L, 24)', tests.id('S')), 'FORBIDDEN');
select tests.as_user(tests.id('admin'));
select public.admin_open_support_session(tests.id('S'));
do $$ begin
  assert (select count(*) from public.stations where id = tests.id('S')) = 1, 'TEST-005: grant -> super admin can read';
  perform tests.throws(format($q$select public.station_update_profile(%L, 'Edited', null, null, null, null, false, 0, 0)$q$, tests.id('S')), 'FORBIDDEN');
end $$;
select tests.as_user(tests.id('owner'));
select public.station_revoke_support(tests.id('grant'));
select tests.as_user(tests.id('admin'));
do $$ begin
  assert (select count(*) from public.stations where id = tests.id('S')) = 0, 'TEST-005: revoked -> no access';
end $$;
reset role;
do $$ begin
  assert exists (select 1 from public.audit_log where action = 'support_view' and actor_id = tests.id('admin')), 'TEST-005: view session logged';
end $$;
