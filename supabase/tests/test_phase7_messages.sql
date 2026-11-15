-- TEST-055, 056, 061, 062 · TASK-060…062
-- Station A: Standard (customer app + automatic WhatsApp). Station C: Basic (manual WhatsApp only).
insert into tests.fx values
  ('owner',   tests.create_user('923421111111')),
  ('manager', tests.create_user('923422222222')),
  ('cashier', tests.create_user('923423333333')),
  ('mech',    tests.create_user('923424444444')),
  ('ownerC',  tests.create_user('923425555555')),
  ('ali',     tests.create_user('923001234567'));   -- Ali uses the customer app

set role authenticated;
select tests.as_user(tests.id('owner'));
insert into tests.fx values ('A', public.station_signup('Alpha Service', 'Lahore', 'Owner A'));
select tests.as_user(tests.id('ownerC'));
insert into tests.fx values ('C', public.station_signup('Basic Garage', 'Multan', 'Owner C'));
reset role;
set role service_role;
select public.admin_add_member(tests.id('owner'), tests.id('A'), tests.id('manager'), 'Man Ager', '03422222222', 'manager');
select public.admin_add_member(tests.id('owner'), tests.id('A'), tests.id('cashier'), 'Cash Ier', '03423333333', 'cashier');
select public.admin_add_member(tests.id('owner'), tests.id('A'), tests.id('mech'), 'Mech Anic', '03424444444', 'mechanic');
reset role;
update public.subscriptions set state = 'active', plan_code = 'standard', current_period_end = now() + interval '30 days'
  where station_id = tests.id('A');
update public.subscriptions set state = 'active', plan_code = 'basic', current_period_end = now() + interval '30 days'
  where station_id = tests.id('C');

-- A job with one labour line, approved by phone; optionally moved to Ready by the owner.
create or replace function tests.job7(p_station uuid, p_customer uuid, p_car uuid, p_price bigint, p_ready boolean default true)
returns uuid language plpgsql as $$
declare v_job uuid;
begin
  v_job := public.station_create_job(p_station, p_customer, p_car,
    (select coalesce(max(odometer_km), 0) + 100 from public.job_cards where vehicle_id = p_car), 'H');
  perform public.job_add_line(v_job, 'labour', null, 'Service', 1, p_price);
  perform public.job_record_approval(v_job, true, 'phone', 'Customer');
  if p_ready then
    perform public.job_set_stage(v_job, 'in_progress');
    perform public.job_set_stage(v_job, 'quality_check');
    perform public.job_quality_check(v_job, true);
  end if;
  return v_job;
end $$;
grant execute on all functions in schema tests to authenticated, service_role;

set role authenticated;
select tests.as_user(tests.id('owner'));
insert into tests.fx values ('aliA', public.station_save_customer(tests.id('A'), null, 'Ali Raza', '0300-1234567'));
insert into tests.fx values ('carA', public.station_save_vehicle(tests.id('A'), null, tests.id('aliA'), 'LEA-1234'));
select public.station_save_booking_settings(tests.id('A'), 2, 60, 3,
  (select jsonb_agg(jsonb_build_object('weekday', d, 'opens', '09:00', 'closes', '18:00')) from generate_series(1, 7) d), '{}');
select tests.as_user(tests.id('ownerC'));
insert into tests.fx values ('bilalC', public.station_save_customer(tests.id('C'), null, 'Bilal', '0321-5550000'));
insert into tests.fx values ('carC', public.station_save_vehicle(tests.id('C'), null, tests.id('bilalC'), 'MUL-42'));
-- Ali's phone has the customer app.
select tests.as_user(tests.id('ali'));
select public.register_device('fcm-token-ali-0000000000000', 'customer');
select tests.throws($q$select public.register_device('short', 'customer')$q$, 'VALIDATION');
reset role;
update public.job_checklist_items set status = 'ok';

-- Service-role functions are not callable from the apps ---------------------------------------
do $$
declare r record;
begin
  for r in select p.oid, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'svc\_%' loop
    assert not has_function_privilege('authenticated', r.oid, 'execute') and not has_function_privilege('anon', r.oid, 'execute'),
      'svc function callable by users: ' || r.proname;
    assert has_function_privilege('service_role', r.oid, 'execute'), 'svc function not callable by service role: ' || r.proname;
  end loop;
  assert (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and p.proname like 'svc\_%') >= 7, 'svc functions exist';
end $$;

-- TEST-061 Not connected → manual; connect states -----------------------------------------------
set role authenticated;
select tests.as_user(tests.id('owner'));
insert into tests.fx values ('bk1', public.station_create_booking(tests.id('A'), tests.id('aliA'), tests.id('carA'), null,
  ((private.today_pk() + 2) + time '10:00') at time zone 'Asia/Karachi'));
do $$ begin
  assert (select status || '|' || manual_reason from public.message_outbox
          where ref_id = tests.id('bk1') and channel = 'whatsapp' and event = 'booking_confirmed') = 'manual|WhatsApp not connected',
    'TEST-061: not connected → manual list';
  assert (select body from public.message_outbox where ref_id = tests.id('bk1') and channel = 'whatsapp')
         = format('Your booking at Alpha Service is confirmed for %s (LEA-1234).',
                  to_char((private.today_pk() + 2) + time '10:00', 'DD-MM-YYYY HH24:MI')),
    'TEST-055: booking confirmed text';
  assert (select count(*) from public.message_outbox where ref_id = tests.id('bk1') and channel = 'push' and status = 'queued') = 1,
    'TEST-055: push to the customer app';
end $$;

select tests.as_user(tests.id('cashier'));
select tests.throws(format('select public.whatsapp_begin_connect(%L)', tests.id('A')), 'FORBIDDEN');
select tests.as_user(tests.id('ownerC'));
select tests.throws(format('select public.whatsapp_begin_connect(%L)', tests.id('C')), 'FEATURE_LOCKED');
select tests.as_user(tests.id('owner'));
select public.whatsapp_begin_connect(tests.id('A'));
reset role;
set role service_role;
-- whatsapp-connect Edge Function after Meta sign-up: number registered, templates submitted.
select public.svc_whatsapp_set_account(tests.id('A'), 'pending', 'Templates in review', 'WABA-1', 'PHONE-1', '+92 300 0000000', 'meta-token-A');
select public.svc_whatsapp_template_status('WABA-1', 'csm_' || code, 'APPROVED') from public.message_events where code <> 'vehicle_ready';
select public.svc_whatsapp_template_status('WABA-1', 'csm_vehicle_ready', 'REJECTED', 'INVALID_FORMAT');
reset role;
do $$ begin
  assert (select status from public.whatsapp_accounts where station_id = tests.id('A')) = 'pending', 'TEST-061: still pending with a rejected template';
  assert (select status_reason from public.whatsapp_accounts where station_id = tests.id('A')) like '%vehicle_ready%INVALID_FORMAT%',
    'TEST-061: rejection reason shown';
end $$;
set role service_role;
select public.svc_whatsapp_template_status('WABA-1', 'csm_vehicle_ready', 'APPROVED');
select public.svc_whatsapp_template_status('WABA-OTHER', 'csm_vehicle_ready', 'REJECTED');   -- unknown account: ignored
reset role;
do $$ begin
  assert (select status from public.whatsapp_accounts where station_id = tests.id('A')) = 'connected', 'TEST-061: all approved → Connected';
end $$;
-- The token is never readable by users.
set role authenticated;
select tests.as_user(tests.id('owner'));
do $$ begin
  begin
    perform count(*) from private.whatsapp_tokens;
    raise exception 'token table readable';
  exception when insufficient_privilege then null;
  end;
  assert (select count(*) from public.whatsapp_accounts where station_id = tests.id('A')) = 1, 'owner sees the status';
end $$;
select tests.as_user(tests.id('mech'));
do $$ begin
  assert (select count(*) from public.whatsapp_accounts) = 0, 'mechanic does not see WhatsApp settings';
  assert (select count(*) from public.message_outbox) = 0, 'mechanic does not see messages';
end $$;

-- TEST-055 Connected Standard station: vehicle ready → push + automatic WhatsApp ----------------
select tests.as_user(tests.id('owner'));
insert into tests.fx values ('job1', tests.job7(tests.id('A'), tests.id('aliA'), tests.id('carA'), 650000));
do $$ begin
  assert (select status from public.message_outbox where ref_id = tests.id('job1') and event = 'vehicle_ready' and channel = 'whatsapp') = 'queued',
    'TEST-055: automatic WhatsApp queued';
  assert (select body from public.message_outbox where ref_id = tests.id('job1') and event = 'vehicle_ready' and channel = 'whatsapp')
         = 'Your vehicle LEA-1234 is ready at Alpha Service.', 'TEST-055: vehicle ready text';
  assert (select count(*) from public.message_outbox where ref_id = tests.id('job1') and event = 'vehicle_ready' and channel = 'push') = 1,
    'TEST-055: vehicle ready push';
  assert (select count(*) from public.customer_notifications where ref_id = tests.id('job1') and kind = 'ready') = 1,
    'TEST-055: vehicle ready in the app inbox';
end $$;
reset role;

-- Dispatcher claims both rows with what it needs to send them.
set role service_role;
do $$
declare r record; n int := 0;
begin
  for r in select * from public.svc_outbox_claim(100) where ref_id = tests.id('job1') loop
    n := n + 1;
    if r.channel = 'whatsapp' then
      assert r.params = array['LEA-1234', 'Alpha Service'], 'TEST-055: template parameters in order: ' || r.params::text;
      assert r.phone_number_id = 'PHONE-1' and r.access_token = 'meta-token-A' and r.to_mobile = '03001234567', 'TEST-055: sender and recipient';
      perform public.svc_outbox_report(r.id, true, null, 'wamid.1');
    else
      assert r.tokens = array['fcm-token-ali-0000000000000'], 'TEST-055: push tokens';
      perform public.svc_outbox_report(r.id, true);
    end if;
  end loop;
  assert n = 2, 'TEST-055: two messages claimed, got ' || n;
  assert (select count(*) from public.svc_outbox_claim(100) where ref_id = tests.id('job1')) = 0, 'TEST-055: sent rows are not claimed again';
end $$;
reset role;
do $$ begin
  assert (select bool_and(status = 'sent') from public.message_outbox where ref_id = tests.id('job1') and event = 'vehicle_ready'),
    'TEST-055: both sent';
end $$;

-- Failure: retried once after 5 minutes, then the manual list with the reason.
set role authenticated;
select tests.as_user(tests.id('owner'));
insert into tests.fx values ('job2', tests.job7(tests.id('A'), tests.id('aliA'), tests.id('carA'), 100000));
reset role;
set role service_role;
do $$
declare r record;
begin
  select * into r from public.svc_outbox_claim(100) c where c.ref_id = tests.id('job2') and c.channel = 'whatsapp';
  perform public.svc_outbox_report(r.id, false, 'Meta timeout');
  assert (select status from public.message_outbox where id = r.id) = 'queued', 'TEST-055: first failure → retry';
  assert (select next_attempt_at from public.message_outbox where id = r.id) > now() + interval '4 minutes', 'TEST-055: retry after 5 minutes';
  assert (select count(*) from public.svc_outbox_claim(100) c where c.id = r.id) = 0, 'TEST-055: not retried before 5 minutes';
end $$;
reset role;
update public.message_outbox set next_attempt_at = now() - interval '1 second' where ref_id = tests.id('job2') and channel = 'whatsapp';
set role service_role;
do $$
declare r record;
begin
  select * into r from public.svc_outbox_claim(100) c where c.ref_id = tests.id('job2') and c.channel = 'whatsapp';
  assert r.id is not null, 'TEST-055: claimed again after 5 minutes';
  perform public.svc_outbox_report(r.id, false, 'Meta timeout');
end $$;
reset role;
do $$ begin
  assert (select status || '|' || manual_reason from public.message_outbox where ref_id = tests.id('job2') and channel = 'whatsapp' and event = 'vehicle_ready')
         = 'manual|Automatic send failed: Meta timeout', 'TEST-055: second failure → manual list with reason';
end $$;

-- Event switched off → no message at all.
set role authenticated;
select tests.as_user(tests.id('manager'));
select tests.throws(format($q$select public.station_set_message_events(%L, '{"vehicle_ready": false}')$q$, tests.id('A')), 'FORBIDDEN');
select tests.as_user(tests.id('owner'));
select tests.throws(format($q$select public.station_set_message_events(%L, '{"nope": false}')$q$, tests.id('A')), 'VALIDATION');
select public.station_set_message_events(tests.id('A'), '{"vehicle_ready": false}');
insert into tests.fx values ('job3', tests.job7(tests.id('A'), tests.id('aliA'), tests.id('carA'), 100000));
do $$ begin
  assert (select count(*) from public.message_outbox where ref_id = tests.id('job3') and event = 'vehicle_ready') = 0, 'TEST-055: switched-off event sends nothing';
end $$;
select public.station_set_message_events(tests.id('A'), '{"vehicle_ready": true}');

-- Estimate and extra work: one extra-work message with the running total.
insert into tests.fx values ('job4', public.station_create_job(tests.id('A'), tests.id('aliA'), tests.id('carA'), 900000, 'H'));
select public.job_add_line(tests.id('job4'), 'labour', null, 'Brake pads', 1, 400000);
select public.job_send_estimate(tests.id('job4'));
select public.job_record_approval(tests.id('job4'), true, 'phone', 'Ali');
select public.job_add_line(tests.id('job4'), 'labour', null, 'Disc skim', 1, 150000);
select public.job_add_line(tests.id('job4'), 'labour', null, 'Brake fluid', 1, 100000);
do $$ begin
  assert (select body from public.message_outbox where ref_id = tests.id('job4') and event = 'estimate_ready' and channel = 'whatsapp')
         = 'The estimate for your vehicle LEA-1234 at Alpha Service is Rs 4,000. Please confirm so we can start the work.', 'TEST-055: estimate text';
  assert (select count(*) from public.message_outbox where ref_id = tests.id('job4') and event = 'extra_work' and channel = 'whatsapp') = 1,
    'TEST-055: one extra-work message';
  assert (select body from public.message_outbox where ref_id = tests.id('job4') and event = 'extra_work' and channel = 'whatsapp')
         like '%: Rs 2,500.%', 'TEST-055: extra work running total';
end $$;

-- Booking moved and cancelled.
select public.station_reschedule_booking(tests.id('bk1'), ((private.today_pk() + 2) + time '11:00') at time zone 'Asia/Karachi');
select public.station_cancel_booking(tests.id('bk1'), 'Customer called');
do $$ begin
  assert (select count(*) from public.message_outbox where ref_id = tests.id('bk1') and channel = 'whatsapp'
          and event in ('booking_changed', 'booking_cancelled')) = 2, 'TEST-055: moved and cancelled messages';
  assert (select body from public.message_outbox where ref_id = tests.id('bk1') and channel = 'whatsapp' and event = 'booking_cancelled')
         like '%' || to_char((private.today_pk() + 2) + time '11:00', 'DD-MM-YYYY HH24:MI') || '%', 'TEST-055: cancel names the slot';
end $$;
reset role;

-- TEST-061 Payment problem and disconnect --------------------------------------------------------
set role service_role;
do $$
declare r record;
begin
  -- the estimate / extra-work / booking rows of job4 and bk1 are queued; Meta answers with its payment error
  for r in select * from public.svc_outbox_claim(100) c loop
    if r.channel = 'whatsapp' then
      perform public.svc_outbox_report(r.id, false, 'Business eligibility payment issue', null, 131042);
    else
      perform public.svc_outbox_report(r.id, true);
    end if;
  end loop;
end $$;
reset role;
do $$ begin
  assert (select status from public.whatsapp_accounts where station_id = tests.id('A')) = 'payment_problem', 'TEST-061: payment problem status';
  assert (select count(*) from public.message_outbox where station_id = tests.id('A') and channel = 'whatsapp' and status in ('queued', 'sending')) = 0,
    'TEST-061: payment problem → everything to the manual list';
  assert (select count(*) from public.message_outbox where station_id = tests.id('A') and manual_reason like 'Payment problem%') >= 1,
    'TEST-061: reason shown';
end $$;
set role authenticated;
select tests.as_user(tests.id('owner'));
select tests.as_user(tests.id('owner'));
insert into tests.fx values ('bk2', public.station_create_booking(tests.id('A'), tests.id('aliA'), tests.id('carA'), null,
  ((private.today_pk() + 3) + time '10:00') at time zone 'Asia/Karachi'));
reset role;
do $$ begin
  assert (select manual_reason from public.message_outbox where ref_id = tests.id('bk2') and channel = 'whatsapp')
         = 'Payment problem in Meta — add a payment method', 'TEST-061: new events stay manual during a payment problem';
end $$;
set role service_role;
select public.svc_whatsapp_set_account(tests.id('A'), 'connected');
reset role;
set role authenticated;
select tests.as_user(tests.id('owner'));
select public.station_reschedule_booking(tests.id('bk2'), ((private.today_pk() + 3) + time '12:00') at time zone 'Asia/Karachi');
do $$ begin
  assert (select status from public.message_outbox where ref_id = tests.id('bk2') and event = 'booking_changed' and channel = 'whatsapp') = 'queued',
    'TEST-061: connected again → automatic';
end $$;
select tests.as_user(tests.id('manager'));
select tests.throws(format('select public.station_whatsapp_disconnect(%L)', tests.id('A')), 'FORBIDDEN');
select tests.as_user(tests.id('owner'));
select public.station_whatsapp_disconnect(tests.id('A'));
do $$ begin
  assert (select status from public.whatsapp_accounts where station_id = tests.id('A')) = 'disconnected', 'TEST-061: disconnected';
  assert (select status || '|' || manual_reason from public.message_outbox where ref_id = tests.id('bk2') and event = 'booking_changed' and channel = 'whatsapp')
         = 'manual|WhatsApp not connected', 'TEST-061: disconnect returns queued messages to manual sending';
end $$;
reset role;
do $$ begin
  assert (select count(*) from private.whatsapp_tokens where station_id = tests.id('A')) = 0, 'TEST-061: token removed on disconnect';
end $$;

-- TEST-062 Basic station: invoice → manual WhatsApp with prefilled text ----------------------------
set role authenticated;
select tests.as_user(tests.id('ownerC'));
insert into tests.fx values ('jobC', tests.job7(tests.id('C'), tests.id('bilalC'), tests.id('carC'), 950000));
insert into tests.fx values ('invC', public.station_create_invoice(tests.id('jobC')));
do $$ begin
  assert (select status from public.message_outbox where ref_id = tests.id('invC') and channel = 'whatsapp' and event = 'invoice_issued') = 'manual',
    'TEST-062: Basic → manual list';
  assert (select manual_reason is null from public.message_outbox where ref_id = tests.id('invC') and channel = 'whatsapp'), 'TEST-062: no error reason on Basic';
  assert (select body from public.message_outbox where ref_id = tests.id('invC') and channel = 'whatsapp')
         ~ '^Your invoice INV-[0-9]{4} from Basic Garage: Rs 9,500\. Thank you!$', 'TEST-062: invoice text';
  assert (select to_mobile from public.message_outbox where ref_id = tests.id('invC') and channel = 'whatsapp') = '03215550000', 'TEST-062: customer number';
  assert (select count(*) from public.message_outbox where station_id = tests.id('C') and channel = 'push') = 0, 'TEST-062: no customer push on Basic';
  assert (select count(*) from public.customer_notifications where station_id = tests.id('C')) = 0, 'TEST-062: no app inbox on Basic';
end $$;
-- Opened from the list, then marked sent; handled messages can't be marked again.
do $$
declare v bigint := (select id from public.message_outbox where ref_id = tests.id('invC') and channel = 'whatsapp');
begin
  perform public.message_mark(v, 'opened');
  assert (select status from public.message_outbox where id = v) = 'opened', 'TEST-062: opened';
  perform public.message_mark(v, 'sent');
  assert (select status from public.message_outbox where id = v) = 'sent', 'TEST-062: marked sent';
  perform tests.throws(format('select public.message_mark(%s, ''skipped'')', v), 'VALIDATION');
  perform tests.throws(format('select public.message_mark(%s, ''deleted'')',
    (select id from public.message_outbox where ref_id = tests.id('jobC') and event = 'vehicle_ready')), 'VALIDATION');
  perform public.message_mark((select id from public.message_outbox where ref_id = tests.id('jobC') and event = 'vehicle_ready'), 'skipped');
end $$;
-- Another station's staff, and mechanics, can't touch messages.
reset role;
create temp table msg_ids as
  select 'invC' as k, id from public.message_outbox where ref_id = tests.id('invC') and channel = 'whatsapp'
  union all
  select 'bk2', id from public.message_outbox where ref_id = tests.id('bk2') and channel = 'whatsapp' and event = 'booking_changed';
grant select on msg_ids to authenticated;
set role authenticated;
select tests.as_user(tests.id('cashier'));
do $$ begin
  perform tests.throws(format('select public.message_mark(%s, ''sent'')', (select id from msg_ids where k = 'invC')), 'NOT_FOUND');
  assert (select count(*) from public.message_outbox where station_id = tests.id('C')) = 0, 'TEST-062: cashier of A sees nothing of C';
end $$;
select tests.as_user(tests.id('mech'));
select tests.throws(format('select public.message_mark(%s, ''sent'')', (select id from msg_ids where k = 'bk2')), 'NOT_FOUND');
select tests.as_user(tests.id('cashier'));
select public.message_mark((select id from msg_ids where k = 'bk2'), 'opened');
reset role;

-- Next-service reminder: push + WhatsApp on the app station; Basic keeps the staff list only (REQ-049).
set role authenticated;
select tests.as_user(tests.id('ownerC'));
select public.job_set_next_service(tests.id('jobC'), private.today_pk() + 3);
select tests.as_user(tests.id('owner'));
select public.job_set_next_service(tests.id('job3'), private.today_pk() + 3);
reset role;
do $$ begin
  assert private.daily_service_reminders() = 1, 'service reminder sent on Standard only';
  assert (select body from public.message_outbox where ref_id = tests.id('job3') and event = 'service_reminder' and channel = 'whatsapp')
         = format('Your vehicle LEA-1234 is due for service at Alpha Service on %s.', to_char(private.today_pk() + 3, 'DD-MM-YYYY')),
    'TEST-055: next-service reminder text';
  assert (select count(*) from public.message_outbox where ref_id = tests.id('job3') and event = 'service_reminder' and channel = 'push') = 1,
    'TEST-055: next-service reminder push';
  assert (select count(*) from public.message_outbox where ref_id = tests.id('jobC') and event = 'service_reminder') = 0, 'REQ-049: Basic → staff list only';
end $$;

-- Dues reminder every 7 days while dues remain.
update public.invoices set on_credit = true, issued_at = now() - interval '8 days' where id = tests.id('invC');
do $$ begin
  assert private.daily_dues_reminders() = 1, 'dues reminder after 7 days';
  assert private.daily_dues_reminders() = 0, 'only one per 7 days';
  assert (select body from public.message_outbox where customer_id = tests.id('bilalC') and event = 'dues_reminder')
         = 'Reminder from Basic Garage: Rs 9,500 is due on your account.', 'dues text';
end $$;

-- TEST-056 Staff notifications and push -----------------------------------------------------------
set role authenticated;
select tests.as_user(tests.id('owner'));
select public.register_device('fcm-token-owner-000000000000', 'staff');
select tests.as_user(tests.id('manager'));
select public.register_device('fcm-token-manager-0000000000', 'staff');
-- New job assigned → mechanic.
select tests.as_user(tests.id('owner'));
select public.job_assign(tests.id('job4'), array[tests.id('mech')]);
-- Cashier asks for a discount above the limit → owner and manager are told.
select tests.as_user(tests.id('cashier'));
insert into tests.fx values ('invA', public.station_create_invoice(tests.id('job1')));
do $$ begin
  assert public.invoice_set_discount(tests.id('invA'), 200000, 'Old customer') = 'pending', 'discount needs approval';
end $$;
reset role;
do $$ begin
  assert (select count(*) from public.notifications where kind = 'approval_request' and station_id = tests.id('A')
          and user_id in (tests.id('owner'), tests.id('manager'))) = 2, 'TEST-056: owner and manager get the approval request';
  assert (select count(*) from public.notifications where kind = 'approval_request' and user_id = tests.id('cashier')) = 0,
    'TEST-056: the requester is not asked';
  assert (select count(*) from public.notifications where kind = 'assigned' and user_id = tests.id('mech')) = 1, 'TEST-056: assignment';
end $$;
set role authenticated;
select tests.as_user(tests.id('manager'));
select public.station_decide_approval((select id from public.approval_requests where record_id = tests.id('invA') and status = 'pending'), false, 'Too much');
reset role;
do $$ begin
  assert (select title from public.notifications where kind = 'approval_decision' and user_id = tests.id('cashier')) = 'Discount request rejected',
    'TEST-056: requester hears the decision';
end $$;

-- Low stock: crossing the minimum tells owners/managers once.
set role authenticated;
select tests.as_user(tests.id('owner'));
insert into tests.fx values ('filter', public.station_save_item(tests.id('A'), '{"code":"F1","name":"Oil filter","min_stock":5}'::jsonb));
reset role;
insert into public.stock_movements (station_id, item_id, qty, kind) values (tests.id('A'), tests.id('filter'), 8, 'opening');
insert into public.stock_movements (station_id, item_id, qty, kind) values (tests.id('A'), tests.id('filter'), -2, 'job_use');
insert into public.stock_movements (station_id, item_id, qty, kind) values (tests.id('A'), tests.id('filter'), -2, 'job_use');
insert into public.stock_movements (station_id, item_id, qty, kind) values (tests.id('A'), tests.id('filter'), -1, 'job_use');
do $$ begin
  assert (select count(*) from public.notifications where kind = 'low_stock' and ref_id = tests.id('filter')) = 1, 'TEST-056: low stock once';
  assert (select body from public.notifications where kind = 'low_stock' and ref_id = tests.id('filter')) = '4 left (minimum 5)', 'TEST-056: low stock text';
end $$;

-- Push claim: each notification with the phones of its recipients.
set role service_role;
do $$
declare r record; n int := 0;
begin
  for r in select * from public.svc_staff_push_claim(500) loop
    n := n + 1;
    if r.kind = 'approval_request' then
      assert cardinality(r.tokens) = 1, 'TEST-056: one phone per approver row';
    elsif r.kind = 'low_stock' then
      assert r.tokens @> array['fcm-token-owner-000000000000', 'fcm-token-manager-0000000000'] and cardinality(r.tokens) = 2,
        'TEST-056: owner and manager phones for a station-wide notice';
    end if;
    perform public.svc_staff_push_report(r.id, true);
  end loop;
  assert n >= 3, 'TEST-056: notifications to push, got ' || n;
  assert (select count(*) from public.svc_staff_push_claim(500)) = 0, 'TEST-056: pushed once';
end $$;
reset role;
do $$ begin
  assert (select push_state from public.notifications where kind = 'assigned' and user_id = tests.id('mech')) = 'none',
    'TEST-056: no phone registered → nothing to push';
  assert (select push_state from public.notifications where kind = 'low_stock' and ref_id = tests.id('filter')) = 'sent', 'TEST-056: pushed';
end $$;

-- Inbox: mark read; device tokens are private to their user.
set role authenticated;
select tests.as_user(tests.id('cashier'));
do $$ begin
  assert public.notifications_mark_read(tests.id('A')) = 1, 'cashier marks own decision read';
  assert (select count(*) from public.device_tokens) = 0, 'cashier sees no device tokens';
end $$;
select tests.as_user(tests.id('owner'));
select public.unregister_device('fcm-token-owner-000000000000');
do $$ begin
  assert (select count(*) from public.device_tokens) = 0, 'owner token removed on sign-out';
end $$;
select tests.as_user(tests.id('ownerC'));
select tests.throws(format('select public.notifications_mark_read(%L)', tests.id('A')), 'FORBIDDEN');
reset role;
