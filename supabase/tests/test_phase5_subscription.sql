-- TEST-007, 008, 009, 010, 012, 013, 104 · TASK-047…052
insert into tests.fx values
  ('owner',   tests.create_user('923401111111')),
  ('cashier', tests.create_user('923402222222')),
  ('admin',   tests.create_user('923403333333')),
  ('o2',      tests.create_user('923404444444')),
  ('o3',      tests.create_user('923405555555')),
  ('o4',      tests.create_user('923406666666'));
insert into public.profiles (id, full_name, mobile, is_super_admin)
values (tests.id('admin'), 'Platform Admin', '03403333333', true);

set role authenticated;
select tests.as_user(tests.id('owner'));
insert into tests.fx values ('S', public.station_signup('Subscribe Motors', 'Lahore', 'Sub Owner'));
select tests.as_user(tests.id('o2'));
insert into tests.fx values ('S2', public.station_signup('Trial Two', 'Karachi', 'Owner Two'));
select tests.as_user(tests.id('o3'));
insert into tests.fx values ('S3', public.station_signup('Trial Three', 'Multan', 'Owner Three'));
select tests.as_user(tests.id('o4'));
insert into tests.fx values ('S4', public.station_signup('Trial Four', 'Quetta', 'Owner Four'));
reset role;
set role service_role;
select public.admin_add_member(tests.id('owner'), tests.id('S'), tests.id('cashier'), 'Cash Ier', '03402222222', 'cashier');
reset role;

-- TEST-007 Trial: day 15 -> grace with full use; SA can extend --------------------------------
update public.subscriptions set trial_ends_at = now() - interval '1 day' where station_id = tests.id('S');
do $$ begin
  assert (select status from public.station_entitlements where station_id = tests.id('S')) = 'grace', 'TEST-007: grace after trial';
  perform private.assert_can_write(tests.id('S'), 'payroll');   -- all Premium features still work
end $$;
set role authenticated;
select tests.as_user(tests.id('owner'));
select tests.throws(format('select public.admin_extend_trial(%L, 7)', tests.id('S')), 'FORBIDDEN');
select tests.as_user(tests.id('admin'));
select public.admin_extend_trial(tests.id('S'), 7);
reset role;
do $$ begin
  assert (select status from public.station_entitlements where station_id = tests.id('S')) = 'trial', 'TEST-007: extended';
end $$;

-- TEST-012 Tenants: 3 trials ending this week are exactly those listed --------------------------
update public.subscriptions set trial_ends_at = now() + interval '3 days' where station_id in (tests.id('S2'), tests.id('S3'));
update public.subscriptions set trial_ends_at = now() + interval '6 days' where station_id = tests.id('S');
update public.subscriptions set trial_ends_at = now() + interval '12 days' where station_id = tests.id('S4');
set role authenticated;
select tests.as_user(tests.id('admin'));
do $$ begin
  assert (select count(*) from public.admin_tenants() t where t.status = 'trial' and t.trial_ends_at <= now() + interval '7 days'
          and t.station_id in (tests.id('S'), tests.id('S2'), tests.id('S3'), tests.id('S4'))) = 3, 'TEST-012: 3 trials end within 7 days';
  assert (select owner_name from public.admin_tenants() where station_id = tests.id('S')) = 'Sub Owner', 'TEST-012: owner shown';
  assert (select count(*) from public.stations) = 0, 'TEST-012: no station records without a grant';
end $$;
select tests.as_user(tests.id('owner'));
select tests.throws('select count(*) from public.admin_tenants()', 'FORBIDDEN');
reset role;

-- TEST-008 Standard yearly by bank transfer -> renewal 12 months ahead, PKR 50,000 ----------------
update public.subscriptions set state = 'active', plan_code = 'standard', billing_cycle = 'yearly',
  current_period_end = now() + interval '5 days' where station_id = tests.id('S');
set role authenticated;
select tests.as_user(tests.id('owner'));
select tests.throws(format($q$select public.station_submit_manual_payment(%L, 'renewal', 'standard', 'yearly', 'bank', 'TT-1', null)$q$, tests.id('S')), 'VALIDATION');
insert into tests.fx values ('pay1', public.station_submit_manual_payment(tests.id('S'), 'renewal', 'standard', 'yearly', 'bank', 'TT-778899',
  tests.id('S')::text || '/receipt-1.jpg'));
select tests.throws(format($q$select public.station_submit_manual_payment(%L, 'renewal', 'standard', 'yearly', 'cash', 'x', null)$q$, tests.id('S')), 'VALIDATION');  -- one pending at a time
select tests.throws(format('select public.admin_verify_payment(%L, true)', tests.id('pay1')), 'FORBIDDEN');
select tests.as_user(tests.id('admin'));
do $$
declare v_old date; v_new date;
begin
  v_old := (select (current_period_end at time zone 'Asia/Karachi')::date from public.subscriptions where station_id = tests.id('S'));
  perform public.admin_verify_payment(tests.id('pay1'), true);
  v_new := (select (current_period_end at time zone 'Asia/Karachi')::date from public.subscriptions where station_id = tests.id('S'));
  assert v_new = (v_old + interval '1 year')::date, format('TEST-008: renewal +12 months (%s -> %s)', v_old, v_new);
  assert (select amount_paisa from public.subscription_payments where id = tests.id('pay1')) = 5000000, 'TEST-008: PKR 50,000';
  assert (select receipt_no from public.subscription_payments where id = tests.id('pay1')) is not null, 'TEST-008: platform receipt';
end $$;
select tests.as_user(tests.id('owner'));
do $$ begin
  assert exists (select 1 from public.notifications where kind = 'subscription' and title = 'Payment verified'), 'owner notified';
end $$;
reset role;

-- TEST-104 Renewal unpaid -> grace -> read-only -> bank receipt verified -> active, renewal +1 month ----
update public.subscriptions set billing_cycle = 'monthly', plan_code = 'standard', current_period_end = now() - interval '8 days'
 where station_id = tests.id('S');
do $$ begin
  assert (select status from public.station_entitlements where station_id = tests.id('S')) = 'read_only', 'TEST-104: day 8 read-only';
end $$;
set role authenticated;
select tests.as_user(tests.id('cashier'));
select tests.throws(format($q$select public.station_save_customer(%L, null, 'New Guy', '03009998887')$q$, tests.id('S')), 'READ_ONLY');
select tests.as_user(tests.id('owner'));
insert into tests.fx values ('pay2', public.station_submit_manual_payment(tests.id('S'), 'renewal', 'standard', 'monthly', 'bank', 'TT-104',
  tests.id('S')::text || '/receipt-104.jpg'));
select tests.as_user(tests.id('admin'));
do $$
declare v_renewal date;
begin
  v_renewal := ((now() - interval '8 days') at time zone 'Asia/Karachi')::date;
  perform public.admin_verify_payment(tests.id('pay2'), true);
  assert (select status from public.station_entitlements where station_id = tests.id('S')) = 'active', 'TEST-104: full access again';
  assert (select (current_period_end at time zone 'Asia/Karachi')::date from public.subscriptions where station_id = tests.id('S'))
         = (v_renewal + interval '1 month')::date, 'TEST-104: renewal moves one month from the old renewal date';
end $$;
select tests.as_user(tests.id('cashier'));
select public.station_save_customer(tests.id('S'), null, 'New Guy', '03009998887');
reset role;

-- Rejected receipt -> owner told the reason
set role authenticated;
select tests.as_user(tests.id('owner'));
insert into tests.fx values ('pay3', public.station_submit_manual_payment(tests.id('S'), 'renewal', 'premium', 'monthly', 'cash', 'Handed to team', null));
select tests.as_user(tests.id('admin'));
select tests.throws(format('select public.admin_verify_payment(%L, false, %L)', tests.id('pay3'), ''), 'VALIDATION');
select public.admin_verify_payment(tests.id('pay3'), false, 'Cash not received');
select tests.as_user(tests.id('owner'));
do $$ begin
  assert exists (select 1 from public.notifications where title = 'Payment not accepted' and body = 'Cash not received'), 'rejection reason to owner';
  assert (select plan_code from public.subscriptions where station_id = tests.id('S')) = 'standard', 'no change on rejection';
end $$;
reset role;

-- TEST-010 Upgrade Basic -> Standard with 15 of 30 days left = PKR 1,250 ----------------------------
update public.subscriptions set plan_code = 'basic', billing_cycle = 'monthly', current_period_end = now() + interval '15 days'
 where station_id = tests.id('S');
set role authenticated;
select tests.as_user(tests.id('owner'));
do $$
declare q jsonb; v_pay uuid;
begin
  q := public.station_subscription_quote(tests.id('S'), 'standard', 'monthly');
  assert (q ->> 'upgrade_amount')::bigint = 125000, 'TEST-010: upgrade costs PKR 1,250, got ' || q::text;
  perform tests.throws(format('select private.assert_can_write(%L, %L)', tests.id('S'), 'booking'), 'FEATURE_LOCKED');
  -- Wallet checkout, confirmed by the webhook (service role).
  v_pay := (public.station_start_checkout(tests.id('S'), 'upgrade', 'standard', 'monthly', 'jazzcash') ->> 'payment_id')::uuid;
  insert into tests.fx values ('pay4', v_pay);
end $$;
reset role;
set role service_role;
do $$ begin
  assert public.admin_confirm_provider_payment(tests.id('pay4'), 'JC-123', true) = 'activated', 'webhook activates';
  assert public.admin_confirm_provider_payment(tests.id('pay4'), 'JC-123', true) = 'duplicate', 'webhook replay ignored';
end $$;
reset role;
do $$ begin
  assert (select plan_code from public.subscriptions where station_id = tests.id('S')) = 'standard', 'TEST-010: Standard at once';
  perform private.assert_can_write(tests.id('S'), 'booking');
  assert (select (current_period_end at time zone 'Asia/Karachi')::date from public.subscriptions where station_id = tests.id('S'))
         = ((now() + interval '15 days') at time zone 'Asia/Karachi')::date, 'upgrade keeps the renewal date';
end $$;
set role authenticated;
select tests.as_user(tests.id('owner'));
select tests.throws(format('select public.station_schedule_downgrade(%L, %L)', tests.id('S'), 'premium'), 'VALIDATION');
select public.station_schedule_downgrade(tests.id('S'), 'basic');
do $$ begin
  assert (select pending_plan_code from public.subscriptions where station_id = tests.id('S')) = 'basic', 'downgrade at next renewal';
  assert (select plan_code from public.subscriptions where station_id = tests.id('S')) = 'standard', 'still Standard until renewal';
end $$;
-- Authenticated users cannot call the webhook function.
select tests.throws(format('select public.admin_confirm_provider_payment(%L, %L, true)', tests.id('pay4'), 'x'), 'permission denied for function admin_confirm_provider_payment');
reset role;

-- Suspension ------------------------------------------------------------------------------------
set role authenticated;
select tests.as_user(tests.id('admin'));
select public.admin_set_suspended(tests.id('S2'), true, 'Fraud check');
reset role;
do $$ begin
  assert (select status from public.station_entitlements where station_id = tests.id('S2')) = 'suspended', 'suspended';
  perform tests.throws(format('select private.assert_can_write(%L)', tests.id('S2')), 'READ_ONLY');
end $$;
set role authenticated;
select tests.as_user(tests.id('admin'));
select public.admin_set_suspended(tests.id('S2'), false, 'Cleared');
reset role;
do $$ begin
  assert (select status from public.station_entitlements where station_id = tests.id('S2')) = 'trial', 'restored to trial';
end $$;

-- TEST-013 Close account, restore by paying, then deletion after 90 days ----------------------------
set role authenticated;
select tests.as_user(tests.id('o3'));
select tests.throws(format('select public.station_close_account(%L, %L)', tests.id('S3'), 'wrong name'), 'VALIDATION');
select public.station_close_account(tests.id('S3'), 'trial three');
do $$ begin
  assert (select status from public.station_entitlements where station_id = tests.id('S3')) = 'closed', 'TEST-013: closed';
end $$;
insert into tests.fx values ('pay5', public.station_submit_manual_payment(tests.id('S3'), 'renewal', 'basic', 'monthly', 'cash', 'Paid at office', null));
select tests.as_user(tests.id('admin'));
select public.admin_verify_payment(tests.id('pay5'), true);
reset role;
do $$ begin
  assert (select status from public.station_entitlements where station_id = tests.id('S3')) = 'active', 'TEST-013: restorable by paying';
end $$;
set role authenticated;
select tests.as_user(tests.id('o3'));
select public.station_save_checklist_template(tests.id('S3'), array['Brakes']);
select public.station_close_account(tests.id('S3'), 'Trial Three');
reset role;
update public.subscriptions set deletion_due_at = now() - interval '1 minute' where station_id = tests.id('S3');
do $$
declare res jsonb;
begin
  res := private.daily_subscription_jobs();
  assert (res ->> 'deleted')::int = 1, 'TEST-013: deleted on day 90 ' || res::text;
  assert not exists (select 1 from public.stations where id = tests.id('S3')), 'TEST-013: station rows gone';
  assert not exists (select 1 from public.station_members where station_id = tests.id('S3')), 'TEST-013: members gone';
  assert not exists (select 1 from public.audit_log where station_id = tests.id('S3')), 'TEST-013: audit gone with the station';
  assert exists (select 1 from public.deleted_stations where station_id = tests.id('S3')), 'TEST-013: shows Closed — deleted';
  assert (select count(*) from public.storage_cleanup_queue where prefix = tests.id('S3')::text || '/') = 2, 'TEST-013: logo and receipt folders queued for the Storage API';
  assert exists (select 1 from public.stations where id = tests.id('S')), 'other stations untouched';
end $$;
