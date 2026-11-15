-- TASK-070 · PRD §16 end-to-end journeys TEST-101, 102, 103 (TEST-104 is in test_phase5,
-- TEST-105 in test_phase8). Every step goes through the same functions the apps call.
insert into tests.fx values
  ('owner',  tests.create_user('923451111111')),
  ('cash',   tests.create_user('923452222222')),
  ('mech',   tests.create_user('923453333333')),
  ('ownerB', tests.create_user('923454444444')),
  ('cashB',  tests.create_user('923455555555')),
  ('ali',    tests.create_user('923001234567'));    -- customer with the app

set role authenticated;
select tests.as_user(tests.id('owner'));
insert into tests.fx values ('S', public.station_signup('Standard Autos', 'Lahore', 'Owner S'));
select tests.as_user(tests.id('ownerB'));
insert into tests.fx values ('B', public.station_signup('Basic Garage', 'Multan', 'Owner B'));
reset role;
set role service_role;
select public.admin_add_member(tests.id('owner'), tests.id('S'), tests.id('cash'), 'Cash S', '03452222222', 'cashier');
select public.admin_add_member(tests.id('owner'), tests.id('S'), tests.id('mech'), 'Mech S', '03453333333', 'mechanic');
select public.admin_add_member(tests.id('ownerB'), tests.id('B'), tests.id('cashB'), 'Cash B', '03455555555', 'cashier');
-- Station S has connected its own WhatsApp and all templates are approved (REQ-061).
select public.svc_whatsapp_set_account(tests.id('S'), 'pending', null, 'WABA-S', 'PHONE-S', '+92 300 1111111', 'token-S');
select public.svc_whatsapp_template_status('WABA-S', 'csm_' || code, 'APPROVED') from public.message_events;
reset role;
update public.subscriptions set state = 'active', plan_code = 'standard', current_period_end = now() + interval '30 days' where station_id = tests.id('S');
update public.subscriptions set state = 'active', plan_code = 'basic', current_period_end = now() + interval '30 days' where station_id = tests.id('B');

-- TEST-101 (J1, Standard) ---------------------------------------------------------------------
set role authenticated;
select tests.as_user(tests.id('owner'));
select public.station_save_booking_settings(tests.id('S'), 2, 60, 3,
  (select jsonb_agg(jsonb_build_object('weekday', d, 'opens', '09:00', 'closes', '18:00')) from generate_series(1, 7) d), '{}');
insert into tests.fx values ('aliS', public.station_save_customer(tests.id('S'), null, 'Ali Raza', '0300-1234567'));
insert into tests.fx values ('car', public.station_save_vehicle(tests.id('S'), null, tests.id('aliS'), 'LEA-1234', 'Toyota', 'Corolla'));
insert into tests.fx values ('oil', public.station_save_item(tests.id('S'), '{"code":"OIL","name":"Engine oil","unit":"litre","selling_price_paisa":100000}'::jsonb));
insert into tests.fx values ('filter', public.station_save_item(tests.id('S'), '{"code":"OF","name":"Oil filter","selling_price_paisa":90000}'::jsonb));
insert into tests.fx values ('air', public.station_save_item(tests.id('S'), '{"code":"AF","name":"Air filter","selling_price_paisa":160000}'::jsonb));
insert into tests.fx values ('sup', public.station_save_supplier(tests.id('S'), null, 'Parts Co', null));
select public.station_post_purchase(tests.id('S'), tests.id('sup'), null, 'P-1', private.today_pk(), jsonb_build_array(
  jsonb_build_object('item_id', tests.id('oil'), 'qty', 20, 'unit_cost_paisa', 80000),
  jsonb_build_object('item_id', tests.id('filter'), 'qty', 5, 'unit_cost_paisa', 60000),
  jsonb_build_object('item_id', tests.id('air'), 'qty', 5, 'unit_cost_paisa', 120000)), 0);
-- Booking 10:00 tomorrow, arrived, intake 84,200 km.
insert into tests.fx values ('bk', public.station_create_booking(tests.id('S'), tests.id('aliS'), tests.id('car'), null,
  ((private.today_pk() + 1) + time '10:00') at time zone 'Asia/Karachi'));
insert into tests.fx values ('job', public.station_mark_arrived(tests.id('bk'), 84200, 'H', 'Service due'));
-- Estimate Rs 6,500: 3.5 L oil @ 1,000, filter 900, labour 500, air filter 1,600.
select public.job_add_line(tests.id('job'), 'part', tests.id('oil'), null, 3.5);
select public.job_add_line(tests.id('job'), 'part', tests.id('filter'), null, 1);
select public.job_add_line(tests.id('job'), 'labour', null, 'Service labour', 1, 50000);
select public.job_add_line(tests.id('job'), 'part', tests.id('air'), null, 1);
select public.job_send_estimate(tests.id('job'));
-- Approved in the customer app.
select tests.as_user(tests.id('ali'));
select public.customer_decide(tests.id('job'), true);
select tests.as_user(tests.id('owner'));
select public.job_assign(tests.id('job'), array[tests.id('mech')]);
select tests.as_user(tests.id('mech'));
select public.job_set_stage(tests.id('job'), 'in_progress');
reset role;
update public.job_checklist_items set status = 'ok' where job_id = tests.id('job');
set role authenticated;
select tests.as_user(tests.id('mech'));
select public.job_set_stage(tests.id('job'), 'quality_check');
select tests.as_user(tests.id('owner'));
select public.job_quality_check(tests.id('job'), true);
select tests.as_user(tests.id('cash'));
insert into tests.fx values ('inv', public.station_create_invoice(tests.id('job')));
select public.invoice_record_payment(tests.id('inv'), 650000, 'jazzcash', '7781');
select public.job_set_stage(tests.id('job'), 'delivered');
reset role;
do $$ begin
  assert (select total_paisa from public.invoices where id = tests.id('inv')) = 650000, 'TEST-101: invoice Rs 6,500';
  assert (select approved_via from public.job_cards where id = tests.id('job')) = 'app', 'TEST-101: approved in the app';
  assert (select stage from public.job_cards where id = tests.id('job')) = 'delivered', 'TEST-101: delivered';
  assert (select sum(qty) from public.stock_movements where ref_id = tests.id('job') and item_id = tests.id('oil')) = -3.5, 'TEST-101: oil −3.5 L';
  assert (select sum(qty) from public.stock_movements where ref_id = tests.id('job') and item_id = tests.id('filter')) = -1, 'TEST-101: filter −1';
  assert (select sum(qty) from public.stock_movements where ref_id = tests.id('job') and item_id = tests.id('air')) = -1, 'TEST-101: air filter −1';
  -- 4 automatic WhatsApp messages from the station's own number.
  assert (select count(*) from public.message_outbox where station_id = tests.id('S') and channel = 'whatsapp' and status = 'queued'
          and event in ('booking_confirmed', 'estimate_ready', 'vehicle_ready', 'invoice_issued')) = 4,
    'TEST-101: 4 automatic WhatsApp messages, got ' ||
    (select string_agg(event || ':' || status, ', ') from public.message_outbox where station_id = tests.id('S') and channel = 'whatsapp');
end $$;
set role authenticated;
select tests.as_user(tests.id('cash'));
do $$ begin
  assert (public.station_day_summary(tests.id('S'), private.today_pk()) -> 'expected' ->> 'jazzcash')::bigint = 650000,
    'TEST-101: day closing shows JazzCash 6,500';
end $$;

-- TEST-102 (J2, Basic): discount 8% on Rs 10,000 → owner only; manual WhatsApp; Rs 9,200 -----------
select tests.as_user(tests.id('ownerB'));
insert into tests.fx values ('custB', public.station_save_customer(tests.id('B'), null, 'Walk-in Bilal', '0321-5550000'));
insert into tests.fx values ('carB', public.station_save_vehicle(tests.id('B'), null, tests.id('custB'), 'MUL-42'));
select tests.as_user(tests.id('cashB'));
insert into tests.fx values ('jobB', public.station_create_job(tests.id('B'), tests.id('custB'), tests.id('carB'), 50000, 'H'));
select public.job_add_line(tests.id('jobB'), 'labour', null, 'Suspension work', 1, 1000000);
select public.job_record_approval(tests.id('jobB'), true, 'phone', 'Bilal');
select public.job_set_stage(tests.id('jobB'), 'in_progress');
reset role;
update public.job_checklist_items set status = 'ok' where job_id = tests.id('jobB');
set role authenticated;
select tests.as_user(tests.id('cashB'));
select public.job_set_stage(tests.id('jobB'), 'quality_check');
select tests.as_user(tests.id('ownerB'));
select public.job_quality_check(tests.id('jobB'), true);
select tests.as_user(tests.id('cashB'));
insert into tests.fx values ('invB', public.station_create_invoice(tests.id('jobB')));
select tests.throws(format('select public.invoice_set_discount(%L, 80000, ''Regular'')', tests.id('invB')), 'OWNER_ONLY');
select tests.as_user(tests.id('ownerB'));
do $$ begin
  assert public.invoice_set_discount(tests.id('invB'), 80000, 'Regular') = 'applied', 'TEST-102: owner applies 8%';
  assert (select total_paisa from public.invoices where id = tests.id('invB')) = 920000, 'TEST-102: receipt Rs 9,200';
  assert (select count(*) from public.message_outbox where station_id = tests.id('B') and status in ('queued', 'sending')) = 0,
    'TEST-102: no automatic sending on Basic';
  assert (select count(*) from public.message_outbox where ref_id = tests.id('invB') and channel = 'whatsapp' and status = 'manual') = 1,
    'TEST-102: manual prefilled message for the invoice';
end $$;

-- TEST-103 (J4): invoice 15,000, paid 12,000, credit release → delivered, dues 3,000, reminder,
-- later 3,000 clears it.
select tests.as_user(tests.id('owner'));
insert into tests.fx values ('j3', public.station_create_job(tests.id('S'), tests.id('aliS'), tests.id('car'), 85000, 'H'));
select public.job_add_line(tests.id('j3'), 'labour', null, 'Gearbox', 1, 1500000);
select public.job_record_approval(tests.id('j3'), true, 'phone', 'Ali');
select public.job_set_stage(tests.id('j3'), 'in_progress');
reset role;
update public.job_checklist_items set status = 'ok' where job_id = tests.id('j3');
set role authenticated;
select tests.as_user(tests.id('owner'));
select public.job_set_stage(tests.id('j3'), 'quality_check');
select public.job_quality_check(tests.id('j3'), true);
select tests.as_user(tests.id('cash'));
insert into tests.fx values ('inv3', public.station_create_invoice(tests.id('j3')));
select public.invoice_record_payment(tests.id('inv3'), 1200000, 'cash');
select tests.throws(format('select public.job_set_stage(%L, ''delivered'')', tests.id('j3')), 'PAYMENT_DUE');
select public.invoice_request_credit(tests.id('inv3'), 'Regular customer, pays Friday');
select tests.as_user(tests.id('owner'));
select public.station_decide_approval((select id from public.approval_requests where record_id = tests.id('inv3') and status = 'pending'), true);
select tests.as_user(tests.id('cash'));
select public.job_set_stage(tests.id('j3'), 'delivered');
do $$ begin
  assert (select stage from public.job_cards where id = tests.id('j3')) = 'delivered', 'TEST-103: delivered on credit';
  assert (select dues_paisa from public.customer_balances where customer_id = tests.id('aliS')) = 300000, 'TEST-103: dues 3,000';
end $$;
reset role;
update public.invoices set issued_at = now() - interval '8 days' where id = tests.id('inv3');
do $$ begin
  assert private.daily_dues_reminders() = 1, 'TEST-103: dues reminder after 7 days';
  assert (select body from public.message_outbox where customer_id = tests.id('aliS') and event = 'dues_reminder')
         = 'Reminder from Standard Autos: Rs 3,000 is due on your account.', 'TEST-103: reminder text';
end $$;
set role authenticated;
select tests.as_user(tests.id('cash'));
select public.customer_collect_dues(tests.id('aliS'), 300000, 'cash');
do $$ begin
  assert (select dues_paisa from public.customer_balances where customer_id = tests.id('aliS')) = 0, 'TEST-103: later payment clears dues';
end $$;
reset role;
