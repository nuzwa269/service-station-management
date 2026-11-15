-- TEST-014, 015, 016, 017, 020, 022, 047, 048, 049 · TASK-053…059
insert into tests.fx values
  ('owner',   tests.create_user('923411111111')),
  ('manager', tests.create_user('923412222222')),
  ('cashier', tests.create_user('923413333333')),
  ('mech',    tests.create_user('923414444444')),
  ('ownerB',  tests.create_user('923415555555')),
  ('ownerC',  tests.create_user('923416666666')),
  ('ali',     tests.create_user('923001234567')),   -- customer at A and B
  ('sara',    tests.create_user('923007654321')),   -- customer at A only
  ('nomad',   tests.create_user('923009999999'));   -- links by code

set role authenticated;
select tests.as_user(tests.id('owner'));
insert into tests.fx values ('A', public.station_signup('Alpha Service', 'Lahore', 'Owner A'));
select tests.as_user(tests.id('ownerB'));
insert into tests.fx values ('B', public.station_signup('Bravo Service', 'Lahore', 'Owner B'));
select tests.as_user(tests.id('ownerC'));
insert into tests.fx values ('C', public.station_signup('Basic Garage', 'Multan', 'Owner C'));
reset role;
set role service_role;
select public.admin_add_member(tests.id('owner'), tests.id('A'), tests.id('manager'), 'Man Ager', '03412222222', 'manager');
select public.admin_add_member(tests.id('owner'), tests.id('A'), tests.id('cashier'), 'Cash Ier', '03413333333', 'cashier');
select public.admin_add_member(tests.id('owner'), tests.id('A'), tests.id('mech'), 'Mech Anic', '03414444444', 'mechanic');
reset role;
-- A and B on Standard, C on Basic.
update public.subscriptions set state = 'active', plan_code = 'standard', current_period_end = now() + interval '30 days'
  where station_id in (tests.id('A'), tests.id('B'));
update public.subscriptions set state = 'active', plan_code = 'basic', current_period_end = now() + interval '30 days'
  where station_id = tests.id('C');

-- Next Tuesday (from tomorrow) and its 10:00 slot, Pakistan time.
create or replace function tests.tue() returns date language sql stable as $$
  select (private.today_pk() + 1) + ((2 - extract(isodow from private.today_pk() + 1)::int + 7) % 7)
$$;
create or replace function tests.slot(p_hour int) returns timestamptz language sql stable as $$
  select (tests.tue() + make_time(p_hour, 0, 0)) at time zone 'Asia/Karachi'
$$;
grant execute on all functions in schema tests to authenticated, service_role;
create temp table codes as select id, station_code from public.stations;
grant select on codes to authenticated;

set role authenticated;
select tests.as_user(tests.id('owner'));
insert into tests.fx values ('aliA',  public.station_save_customer(tests.id('A'), null, 'Ali Raza', '0300-1234567'));
insert into tests.fx values ('saraA', public.station_save_customer(tests.id('A'), null, 'Sara Khan', '0300-7654321'));
insert into tests.fx values ('carA',  public.station_save_vehicle(tests.id('A'), null, tests.id('aliA'), 'LEA-1234', 'Toyota', 'Corolla'));
insert into tests.fx values ('carS',  public.station_save_vehicle(tests.id('A'), null, tests.id('saraA'), 'LEB-555', 'Honda', 'City'));
insert into tests.fx values ('oil',   public.station_save_service(tests.id('A'), null, 'Oil change', 150000, 0));
select public.station_set_service_bookable(tests.id('oil'), true);
select tests.as_user(tests.id('ownerB'));
insert into tests.fx values ('aliB',  public.station_save_customer(tests.id('B'), null, 'Ali R.', '03001234567'));
insert into tests.fx values ('carB',  public.station_save_vehicle(tests.id('B'), null, tests.id('aliB'), 'KHI-777'));
select tests.as_user(tests.id('ownerC'));
select public.station_save_customer(tests.id('C'), null, 'Ali at Basic', '03001234567');

-- TEST-014 Capacity: 4 bays, 60 min, 09:00–18:00 → 9 slots of 4 ---------------------------------
select tests.as_user(tests.id('cashier'));
select tests.throws(format($q$select public.station_save_booking_settings(%L, 4, 60, 3, '[]')$q$, tests.id('A')), 'FORBIDDEN');
select tests.as_user(tests.id('owner'));
select tests.throws(format($q$select public.station_save_booking_settings(%L, 4, 45, 3, '[]')$q$, tests.id('A')), 'VALIDATION');
select public.station_save_booking_settings(tests.id('A'), 4, 60, 3,
  (select jsonb_agg(jsonb_build_object('weekday', d, 'opens', '09:00', 'closes', '18:00')) from generate_series(1, 6) d),
  array[tests.tue() + 7]);
do $$ begin
  assert (select count(*) from public.booking_slots(tests.id('A'), tests.tue())) = 9, 'TEST-014: 9 slots on Tuesday';
  assert (select bool_and(capacity = 4) from public.booking_slots(tests.id('A'), tests.tue())), 'TEST-014: capacity 4 each';
  assert (select count(*) from public.booking_slots(tests.id('A'), tests.tue() + 7)) = 0, 'TEST-014: off-day has no slots';
  assert (select count(*) from public.booking_slots(tests.id('A'), tests.tue() + 5)) = 0, 'TEST-014: Sunday closed';
end $$;
-- Basic station cannot turn booking on.
select tests.as_user(tests.id('ownerC'));
select tests.throws(format($q$select public.station_save_booking_settings(%L, 2, 60, 3, '[]')$q$, tests.id('C')), 'FEATURE_LOCKED');

-- TEST-047 Customer links: Ali sees A and B (both Standard), not Basic C; only own records ---------
select tests.as_user(tests.id('ali'));
do $$ begin
  assert (select count(*) from public.customer_stations()) = 2, 'TEST-047: two linked stations';
  assert not exists (select 1 from public.customer_stations() where station_id = tests.id('C')), 'TEST-047: Basic station not listed';
  assert (select jsonb_array_length(public.customer_station_data(tests.id('A'))->'vehicles')) = 1, 'TEST-047: own vehicle at A';
  assert (public.customer_station_data(tests.id('A'))->'vehicles'->0->>'plate') = 'LEA-1234', 'TEST-047: A vehicle';
  assert (public.customer_station_data(tests.id('B'))->'vehicles'->0->>'plate') = 'KHI-777', 'TEST-047: B vehicle';
  assert (select count(*) from public.customers) = 0, 'TEST-047: no direct table reads';
  assert (select count(*) from public.bookings) = 0, 'TEST-047: no direct booking reads';
end $$;
select tests.throws(format('select public.customer_station_data(%L)', tests.id('C')), 'NOT_FOUND');
select tests.throws(format($q$select public.customer_link_station(%L, 'Ali')$q$,
  (select station_code from codes where id = tests.id('C'))), 'FEATURE_LOCKED');
-- A new customer links station B by its code; a customer record is created there.
select tests.as_user(tests.id('nomad'));
select tests.throws($q$select public.customer_link_station('ZZZZZZ', 'Nomad')$q$, 'NOT_FOUND');
select tests.as_user(tests.id('nomad'));
select tests.throws(format($q$select public.customer_link_station(%L, '')$q$, (select station_code from codes where id = tests.id('B'))), 'VALIDATION');
select public.customer_link_station(lower((select station_code from codes where id = tests.id('B'))), 'Nomad Khan');
do $$ begin
  assert (select count(*) from public.customer_stations()) = 1, 'TEST-047: linked by code';
end $$;
insert into tests.fx values ('carN', public.customer_add_vehicle(tests.id('B'), 'isb 42', 'Suzuki', 'Alto'));
select tests.throws(format($q$select public.customer_add_vehicle(%L, 'KHI-777')$q$, tests.id('B')), 'VALIDATION');  -- Ali's plate

-- TEST-015 Booking with capacity: last free bay goes to the first confirmation -----------------
select tests.as_user(tests.id('cashier'));
select public.station_create_booking(tests.id('A'), tests.id('saraA'), tests.id('carS'), null, tests.slot(10), 'phone');
select public.station_create_booking(tests.id('A'), tests.id('saraA'), tests.id('carS'), null, tests.slot(10), 'phone 2');
select public.station_create_booking(tests.id('A'), tests.id('saraA'), tests.id('carS'), null, tests.slot(10), 'walk-in');
select tests.throws(format('select public.station_create_booking(%L, %L, %L, null, %L)', tests.id('A'), tests.id('aliA'), tests.id('carS'), tests.slot(10)), 'VALIDATION');
select tests.as_user(tests.id('ali'));
do $$ begin
  assert (select free from public.booking_slots(tests.id('A'), tests.tue()) where slot_start = tests.slot(10)) = 1, 'TEST-015: one bay free';
end $$;
select tests.throws(format('select public.customer_book(%L, %L, null, %L)', tests.id('A'), tests.id('carS'), tests.slot(10)), 'VALIDATION');  -- not his car
select tests.throws(format('select public.customer_book(%L, %L, null, %L)', tests.id('A'), tests.id('carA'), tests.slot(10) + interval '15 minutes'), 'VALIDATION');
insert into tests.fx values ('bk1', public.customer_book(tests.id('A'), tests.id('carA'), tests.id('oil'), tests.slot(10), 'Oil please'));
select tests.as_user(tests.id('sara'));
select tests.throws(format('select public.customer_book(%L, %L, null, %L)', tests.id('A'), tests.id('carS'), tests.slot(10)), 'SLOT_TAKEN');
do $$ begin
  assert not exists (select 1 from public.booking_slots(tests.id('A'), tests.tue()) where slot_start = tests.slot(10)), 'TEST-015: full slot hidden from customers';
end $$;
-- Staff may overbook a full slot after a warning (REQ-016).
select tests.as_user(tests.id('cashier'));
select tests.throws(format('select public.station_create_booking(%L, %L, %L, null, %L)', tests.id('A'), tests.id('saraA'), tests.id('carS'), tests.slot(10)), 'SLOT_FULL');
insert into tests.fx values ('bkOver', public.station_create_booking(tests.id('A'), tests.id('saraA'), tests.id('carS'), null, tests.slot(10), 'VIP', true));
reset role;
do $$ begin
  assert (select overbooked from public.bookings where id = tests.id('bkOver')), 'TEST-015: overbook flagged';
  assert (select count(*) from public.notifications where station_id = tests.id('A') and kind = 'booking') = 1, 'TEST-015: staff told of app booking';
  assert (select count(*) from public.customer_notifications where customer_id = tests.id('aliA') and title = 'Booking confirmed') = 1, 'TEST-015: confirmation';
end $$;
-- Read-only station: booking disabled.
update public.subscriptions set current_period_end = now() - interval '10 days' where station_id = tests.id('A');
set role authenticated;
select tests.as_user(tests.id('ali'));
select tests.throws(format('select public.customer_book(%L, %L, null, %L)', tests.id('A'), tests.id('carA'), tests.slot(11)), 'READ_ONLY');
do $$ begin
  assert (select read_only from public.customer_stations() where station_id = tests.id('A')), 'TEST-015: read-only shown';
end $$;
reset role;
update public.subscriptions set current_period_end = now() + interval '30 days' where station_id = tests.id('A');

-- TEST-016 Reschedule and the 1-hour cancel rule ----------------------------------------------
set role authenticated;
select tests.as_user(tests.id('ali'));
select public.customer_reschedule_booking(tests.id('bk1'), tests.slot(12));
reset role;
do $$ begin
  assert (select slot_start from public.bookings where id = tests.id('bk1')) = tests.slot(12), 'TEST-016: moved';
end $$;
-- A booking at "10:00" cancelled at "09:30": too late.
update public.bookings set slot_start = now() + interval '30 minutes', slot_end = now() + interval '90 minutes' where id = tests.id('bk1');
set role authenticated;
select tests.as_user(tests.id('ali'));
select tests.throws(format('select public.customer_cancel_booking(%L)', tests.id('bk1')), 'TOO_LATE');
select tests.as_user(tests.id('sara'));
select tests.throws(format('select public.customer_cancel_booking(%L)', tests.id('bk1')), 'NOT_FOUND');   -- not hers
select tests.as_user(tests.id('ali'));
insert into tests.fx values ('bk2', public.customer_book(tests.id('A'), tests.id('carA'), null, tests.slot(15)));
select public.customer_cancel_booking(tests.id('bk2'));
select tests.as_user(tests.id('cashier'));
select tests.throws(format($q$select public.station_cancel_booking(%L, 'x')$q$, tests.id('bk1')), 'VALIDATION');
reset role;
do $$ begin
  assert (select status from public.bookings where id = tests.id('bk2')) = 'cancelled', 'TEST-016: cancelled online';
  assert exists (select 1 from public.notifications where kind = 'booking' and title = 'Booking cancelled by customer'), 'TEST-016: staff told';
end $$;

-- TEST-017 No-shows: limit 3, 2 earlier no-shows, third blocks; manager unblocks ------------------
insert into public.no_show_counters (station_id, customer_id, no_shows) values (tests.id('A'), tests.id('aliA'), 2);
update public.bookings set slot_start = now() - interval '31 minutes', slot_end = now() + interval '29 minutes' where id = tests.id('bk1');
select private.mark_no_shows();
select private.mark_no_shows();   -- safe to run twice
do $$ begin
  assert (select status from public.bookings where id = tests.id('bk1')) = 'no_show', 'TEST-017: no-show';
  assert (select no_shows from public.no_show_counters where customer_id = tests.id('aliA')) = 3, 'TEST-017: counted once';
  assert (select blocked from public.no_show_counters where customer_id = tests.id('aliA')), 'TEST-017: blocked at limit';
end $$;
set role authenticated;
select tests.as_user(tests.id('ali'));
select tests.throws(format('select public.customer_book(%L, %L, null, %L)', tests.id('A'), tests.id('carA'), tests.slot(14)), 'BOOKING_BLOCKED');
do $$ begin
  assert (select blocked from public.customer_stations() where station_id = tests.id('A')), 'TEST-017: app shows blocked';
  assert not (select blocked from public.customer_stations() where station_id = tests.id('B')), 'TEST-017: only at that station';
end $$;
select tests.as_user(tests.id('cashier'));
select tests.throws(format('select public.station_unblock_customer(%L)', tests.id('aliA')), 'FORBIDDEN');
select tests.as_user(tests.id('manager'));
select public.station_unblock_customer(tests.id('aliA'));
select tests.as_user(tests.id('ali'));
insert into tests.fx values ('bk3', public.customer_book(tests.id('A'), tests.id('carA'), tests.id('oil'), tests.slot(14)));

-- Arrival opens a job card from the booking.
select tests.as_user(tests.id('cashier'));
insert into tests.fx values ('job1', public.station_mark_arrived(tests.id('bk3'), 84200, 'H'));
reset role;
do $$ begin
  assert (select status from public.bookings where id = tests.id('bk3')) = 'arrived', 'arrived';
  assert (select booking_id from public.job_cards where id = tests.id('job1')) = tests.id('bk3'), 'job from booking';
  assert (select complaints from public.job_cards where id = tests.id('job1')) = 'Oil change', 'service as complaint';
  assert (select no_shows from public.no_show_counters where customer_id = tests.id('aliA')) = 0, 'unblock resets count';
end $$;

-- TEST-020 Estimate PKR 6,500 approved in the app; mechanic can start ---------------------------
set role authenticated;
select tests.as_user(tests.id('cashier'));
select public.job_add_line(tests.id('job1'), 'labour', null, 'Oil change and filter', 1, 650000);
select public.job_assign(tests.id('job1'), array[tests.id('mech')]);
select tests.throws(format($q$select public.job_record_approval(%L, true, 'app', 'Ali')$q$, tests.id('job1')), 'VALIDATION');
select tests.as_user(tests.id('ali'));
select tests.throws(format('select public.customer_decide(%L, true)', tests.id('job1')), 'VALIDATION');   -- not sent yet
select tests.as_user(tests.id('cashier'));
select public.job_send_estimate(tests.id('job1'));
select tests.as_user(tests.id('sara'));
select tests.throws(format('select public.customer_job(%L)', tests.id('job1')), 'NOT_FOUND');
select tests.throws(format('select public.customer_decide(%L, true)', tests.id('job1')), 'NOT_FOUND');
select tests.as_user(tests.id('ali'));
do $$ begin
  assert (public.customer_job(tests.id('job1'))->>'stage') = 'awaiting_approval', 'TEST-020: waiting';
  assert (public.customer_job(tests.id('job1'))->'lines'->0->>'total_paisa')::bigint = 650000, 'TEST-020: PKR 6,500';
  assert exists (select 1 from public.customer_notifications_list() where kind = 'estimate'), 'TEST-020: customer told';
end $$;
select public.customer_decide(tests.id('job1'), true);
select tests.as_user(tests.id('mech'));
select public.job_set_stage(tests.id('job1'), 'in_progress');
reset role;
do $$ begin
  assert (select approved_via from public.job_cards where id = tests.id('job1')) = 'app', 'TEST-020: via app';
  assert (select approved_at from public.job_cards where id = tests.id('job1')) is not null, 'TEST-020: time';
  assert exists (select 1 from public.job_history where job_id = tests.id('job1') and note = 'Approved by customer in app'), 'TEST-020: shown on job card';
  assert (select stage from public.job_cards where id = tests.id('job1')) = 'in_progress', 'TEST-020: mechanic started';
end $$;

-- TEST-022 Extra work PKR 3,000 waits for the customer, then approved in the app -----------------
set role authenticated;
select tests.as_user(tests.id('cashier'));
insert into tests.fx values ('xl', public.job_add_line(tests.id('job1'), 'labour', null, 'Clutch plate', 1, 300000));
select tests.as_user(tests.id('ali'));
do $$ begin
  assert (select l->>'status' from jsonb_array_elements(public.customer_job(tests.id('job1'))->'lines') l
          where l->>'description' = 'Clutch plate') = 'extra_pending', 'TEST-022: awaiting customer approval';
  assert exists (select 1 from public.customer_notifications_list() where kind = 'extra_work'), 'TEST-022: customer told';
end $$;
select public.customer_decide(tests.id('job1'), true, true);
reset role;
do $$ begin
  assert (select status from public.job_lines where id = tests.id('xl')) = 'approved', 'TEST-022: approved';
  assert exists (select 1 from public.notifications where kind = 'customer_decision'), 'TEST-022: staff told';
end $$;

-- TEST-048 History: 3 past jobs newest first with odometer and invoice totals ------------------
set role authenticated;
select tests.as_user(tests.id('cashier'));
insert into tests.fx values ('j2', public.station_create_job(tests.id('A'), tests.id('aliA'), tests.id('carA'), 90000, 'F'));
select public.job_add_line(tests.id('j2'), 'labour', null, 'Tuning', 1, 200000);
select public.job_record_approval(tests.id('j2'), true, 'phone', 'Ali');
insert into tests.fx values ('inv2', public.station_create_invoice(tests.id('j2')));
insert into tests.fx values ('j3', public.station_create_job(tests.id('A'), tests.id('aliA'), tests.id('carA'), 95000, 'F'));
reset role;
update public.job_cards set created_at = now() - interval '200 days' where id = tests.id('job1');
update public.job_cards set created_at = now() - interval '100 days' where id = tests.id('j2');
set role authenticated;
select tests.as_user(tests.id('cashier'));
do $$ begin
  assert (select count(*) from public.station_vehicle_history(tests.id('carA')) where kind = 'job') = 3, 'TEST-048: 3 jobs';
  assert (select odometer from public.station_vehicle_history(tests.id('carA')) where kind = 'job' limit 1) = 95000, 'TEST-048: newest first';
  assert (select total_paisa from public.station_vehicle_history(tests.id('carA')) where ref_id = tests.id('j2')) = 200000, 'TEST-048: invoice total';
end $$;
select tests.as_user(tests.id('ownerB'));
do $$ begin
  assert (select count(*) from public.station_vehicle_history(tests.id('carA'))) = 0, 'TEST-048: other station sees nothing';
end $$;
select tests.as_user(tests.id('ali'));
do $$ begin
  assert (select array_agg(odometer order by at desc) from public.customer_vehicle_history(tests.id('carA'))) = array[95000, 90000, 84200], 'TEST-048: customer history';
  assert (public.customer_invoice(tests.id('inv2'))->>'total_paisa')::bigint = 200000, 'customer invoice';
  assert (select jsonb_array_length(public.customer_station_data(tests.id('A'))->'invoices')) = 1, 'customer invoices';
end $$;
select tests.as_user(tests.id('sara'));
select tests.throws(format('select public.customer_invoice(%L)', tests.id('inv2')), 'NOT_FOUND');
select tests.throws(format('select count(*) from public.customer_vehicle_history(%L)', tests.id('carA')), 'NOT_FOUND');

-- TEST-049 Next service: reminder 3 days before on Standard; Basic gets the staff list only --------
select tests.as_user(tests.id('cashier'));
select tests.throws(format('select public.job_set_next_service(%L, %L, 90000)', tests.id('j3'), private.today_pk() + 30), 'VALIDATION');
select public.job_set_next_service(tests.id('j3'), private.today_pk() + 10, 100000);
reset role;
do $$ begin
  assert private.daily_service_reminders(private.today_pk() + 6) = 0, 'TEST-049: not yet';
  assert private.daily_service_reminders(private.today_pk() + 7) = 1, 'TEST-049: 3 days before';
  assert private.daily_service_reminders(private.today_pk() + 7) = 0, 'TEST-049: once';
  assert exists (select 1 from public.customer_notifications where customer_id = tests.id('aliA') and kind = 'reminder'), 'TEST-049: sent';
end $$;
-- Basic station: no message, but the job shows in "Due for service".
set role authenticated;
select tests.as_user(tests.id('ownerC'));
insert into tests.fx values ('custC', (select id from public.customers where station_id = tests.id('C')));
insert into tests.fx values ('carC', public.station_save_vehicle(tests.id('C'), null, tests.id('custC'), 'MUL-9'));
insert into tests.fx values ('jC', public.station_create_job(tests.id('C'), tests.id('custC'), tests.id('carC'), 1000, 'H'));
select public.job_set_next_service(tests.id('jC'), private.today_pk() + 3);
reset role;
do $$ begin
  assert private.daily_service_reminders() = 0, 'TEST-049: Basic sends nothing';
end $$;
set role authenticated;
select tests.as_user(tests.id('ownerC'));
do $$ begin
  assert (select count(*) from public.station_due_for_service(tests.id('C'), 7)) = 1, 'TEST-049: Basic staff list';
end $$;
select tests.as_user(tests.id('owner'));
do $$ begin
  assert (select count(*) from public.station_due_for_service(tests.id('A'), 30)) = 1, 'TEST-049: latest job per vehicle only';
end $$;
select tests.throws(format('select count(*) from public.station_due_for_service(%L)', tests.id('C')), 'FORBIDDEN');

-- A customer cannot use staff functions.
select tests.as_user(tests.id('ali'));
select tests.throws(format('select public.station_create_booking(%L, %L, %L, null, %L)', tests.id('A'), tests.id('aliA'), tests.id('carA'), tests.slot(16)), 'FORBIDDEN');
select tests.throws(format('select public.station_mark_arrived(%L, 1, %L)', tests.id('bk3'), 'H'), 'NOT_FOUND');
reset role;
