-- TEST-018…027, TEST-031, TEST-023 (sync suite) · TASK-029…037
insert into tests.fx values
  ('owner',   tests.create_user('923201111111')),
  ('manager', tests.create_user('923202222222')),
  ('cashier', tests.create_user('923203333333')),
  ('bilal',   tests.create_user('923204444444')),
  ('asif',    tests.create_user('923205555555'));

set role authenticated;
select tests.as_user(tests.id('owner'));
insert into tests.fx values ('S', public.station_signup('Jobs Garage', 'Lahore', 'Job Owner'));
reset role;
set role service_role;
select public.admin_add_member(tests.id('owner'), tests.id('S'), tests.id('manager'), 'Man Ager', '03202222222', 'manager');
select public.admin_add_member(tests.id('owner'), tests.id('S'), tests.id('cashier'), 'Cash Ier', '03203333333', 'cashier');
select public.admin_add_member(tests.id('owner'), tests.id('S'), tests.id('bilal'),   'Bilal',    '03204444444', 'mechanic');
select public.admin_add_member(tests.id('owner'), tests.id('S'), tests.id('asif'),    'Asif',     '03205555555', 'mechanic');
reset role;

-- Setup: checklist template, inspection fee, items, customer, vehicle.
set role authenticated;
select tests.as_user(tests.id('owner'));
select public.station_save_checklist_template(tests.id('S'), array['Brake pads', 'Tyres', 'Lights']);
select public.station_set_inspection_fee(tests.id('S'), 50000);
insert into tests.fx values ('filter', public.station_save_item(tests.id('S'),
  '{"code":"F1","name":"Oil filter","selling_price_paisa":90000,"warranty_days":0}'::jsonb));
insert into tests.fx values ('pads', public.station_save_item(tests.id('S'),
  '{"code":"BP1","name":"Brake pads","selling_price_paisa":450000}'::jsonb));
insert into tests.fx values ('battery', public.station_save_item(tests.id('S'),
  '{"code":"BAT","name":"Battery 70Ah","selling_price_paisa":2500000,"warranty_days":180}'::jsonb));
select public.station_request_stock_adjustment(tests.id('S'), tests.id('filter'), 1, 'count_difference');
select public.station_request_stock_adjustment(tests.id('S'), tests.id('pads'), 4, 'count_difference');
insert into tests.fx values ('sup', public.station_save_supplier(tests.id('S'), null, 'Battery House', null));
select public.station_post_purchase(tests.id('S'), tests.id('sup'), null, 'BH-1', current_date,
  jsonb_build_array(jsonb_build_object('item_id', tests.id('battery'), 'qty', 2, 'unit_cost_paisa', 1800000)), 1800000);
insert into tests.fx values ('cust', public.station_save_customer(tests.id('S'), null, 'Ali Raza', '03001234567'));
insert into tests.fx values ('car', public.station_save_vehicle(tests.id('S'), null, tests.id('cust'), 'LEA-1234'));

-- TEST-018 Intake, numbering, odometer check ---------------------------------------
select tests.as_user(tests.id('cashier'));
insert into tests.fx values ('j1', public.station_create_job(tests.id('S'), tests.id('cust'), tests.id('car'), 85000, 'H', 'Brakes noisy'));
do $$ begin
  assert (select job_no from public.job_cards where id = tests.id('j1')) = 1001, 'TEST-018: first job number 1001';
  assert (select stage from public.job_cards where id = tests.id('j1')) = 'intake', 'TEST-018: stage intake';
  assert (select count(*) from public.job_checklist_items where job_id = tests.id('j1')) = 3, 'TEST-019: checklist copied';
  perform tests.throws(format('select public.station_create_job(%L, %L, %L, 84000, %L)', tests.id('S'), tests.id('cust'), tests.id('car'), 'H'), 'ODOMETER_LOWER');
end $$;
insert into tests.fx values ('j2', public.station_create_job(tests.id('S'), tests.id('cust'), tests.id('car'), 84000, 'F', 'Service', null, true));
do $$ begin
  assert (select job_no from public.job_cards where id = tests.id('j2')) = 1002, 'TEST-018: sequential numbering';
end $$;

-- TEST-019 Checklist -> estimate -------------------------------------------------
do $$
declare v_check uuid;
begin
  select id into v_check from public.job_checklist_items where job_id = tests.id('j1') and name = 'Brake pads';
  perform public.job_set_check(v_check, 'attention', 'Worn');
  perform public.job_check_to_estimate(v_check, tests.id('pads'));
  assert exists (select 1 from public.job_lines where job_id = tests.id('j1') and item_id = tests.id('pads') and status = 'estimate'
                 and unit_price_paisa = 450000), 'TEST-019: brake-pad line added to estimate';
end $$;
select public.job_add_line(tests.id('j1'), 'labour', null, 'Brake service', 1, 200000);
do $$ begin
  assert (select on_hand from public.item_stock where item_id = tests.id('pads')) = 4, 'estimate lines take no stock yet';
end $$;

-- TEST-020 Estimate and approval; work cannot start before approval ------------------
select public.job_assign(tests.id('j1'), array[tests.id('bilal')]);
select tests.as_user(tests.id('bilal'));
select tests.throws(format('select public.job_set_stage(%L, %L)', tests.id('j1'), 'in_progress'), 'VALIDATION');
do $$ begin
  assert (select count(*) from public.job_lines) = 0, 'mechanic cannot read priced lines';
  assert (select count(*) from public.job_cards where id = tests.id('j1')) = 1, 'mechanic sees assigned job';
  assert (select count(*) from public.job_cards where id = tests.id('j2')) = 0, 'mechanic does not see unassigned job';
end $$;
select tests.as_user(tests.id('cashier'));
select public.job_send_estimate(tests.id('j1'));
select public.job_record_approval(tests.id('j1'), true, 'phone', 'Ali Raza');
do $$ begin
  assert (select stage from public.job_cards where id = tests.id('j1')) = 'approved', 'TEST-020: approved';
  assert (select approved_by_name from public.job_cards where id = tests.id('j1')) = 'Ali Raza', 'TEST-020: approver recorded';
  assert (select on_hand from public.item_stock where item_id = tests.id('pads')) = 3, 'TEST-031: approval takes stock';
end $$;

-- TEST-021 Stages by the mechanic ------------------------------------------------------
select tests.as_user(tests.id('bilal'));
select public.job_set_stage(tests.id('j1'), 'in_progress');
do $$ begin
  assert (select stage from public.job_cards where id = tests.id('j1')) = 'in_progress', 'TEST-021: started';
  assert (select started_at from public.job_cards where id = tests.id('j1')) is not null, 'TEST-021: time stamped';
end $$;
select tests.throws(format('select public.job_quality_check(%L, true)', tests.id('j1')), 'NOT_FOUND');  -- mechanic cannot QC
select tests.throws(format('select public.job_set_stage(%L, %L)', tests.id('j1'), 'quality_check'), 'VALIDATION');  -- checklist unfinished

-- TEST-022 Extra work after approval ---------------------------------------------------
select tests.as_user(tests.id('cashier'));
insert into tests.fx values ('clutch', public.job_add_line(tests.id('j1'), 'labour', null, 'Clutch plate', 1, 300000));
do $$ begin
  assert (select status from public.job_lines where id = tests.id('clutch')) = 'extra_pending', 'TEST-022: awaiting customer approval';
end $$;
select tests.throws(format('select public.job_set_stage(%L, %L)', tests.id('j1'), 'delivered'), 'VALIDATION');
select public.job_record_approval(tests.id('j1'), false, 'phone', 'Ali Raza', true);
do $$ begin
  assert (select status from public.job_lines where id = tests.id('clutch')) = 'rejected', 'TEST-022: rejected kept, not invoiced';
end $$;

-- TEST-031 Mechanic adds a part (stock drops; extra_pending until approved; customer part has no stock)
select tests.as_user(tests.id('bilal'));
insert into tests.fx values ('used', public.job_add_line(tests.id('j1'), 'part', tests.id('filter'), null, 1));
select tests.throws(format($q$select public.job_add_line(%L, 'labour', null, 'x', 1, 100)$q$, tests.id('j1')), 'FORBIDDEN');
reset role;
do $$ begin
  assert (select unit_price_paisa from public.job_lines where id = tests.id('used')) = 90000, 'mechanic line priced from item';
  assert (select on_hand from public.item_stock where item_id = tests.id('filter')) = 0, 'TEST-031: stock 1 -> 0';
end $$;
set role authenticated;
select tests.as_user(tests.id('cashier'));
select public.job_add_line(tests.id('j1'), 'customer_part', null, 'Customer own air filter', 1);
select public.job_record_approval(tests.id('j1'), true, 'in_person', 'Ali Raza', true);
select tests.as_user(tests.id('bilal'));
do $$
declare r record;
begin
  for r in select id from public.job_checklist_items where job_id = tests.id('j1') and status = 'not_checked' loop
    perform public.job_set_check(r.id, 'ok');
  end loop;
end $$;
select public.job_set_stage(tests.id('j1'), 'quality_check');

-- TEST-024 Quality check -----------------------------------------------------------------
select tests.as_user(tests.id('manager'));
select tests.throws(format('select public.job_quality_check(%L, false, %L)', tests.id('j1'), ''), 'VALIDATION');
select public.job_quality_check(tests.id('j1'), false, 'Oil leak');
do $$ begin
  assert (select stage from public.job_cards where id = tests.id('j1')) = 'in_progress', 'TEST-024: fail -> in progress';
end $$;
select tests.as_user(tests.id('bilal'));
do $$ begin
  assert exists (select 1 from public.notifications where kind = 'qc_fail' and body = 'Oil leak'), 'TEST-024: mechanic gets the note';
end $$;
select public.job_set_stage(tests.id('j1'), 'quality_check');
select tests.as_user(tests.id('manager'));
select public.job_quality_check(tests.id('j1'), true);
select tests.as_user(tests.id('cashier'));
select public.job_set_stage(tests.id('j1'), 'delivered');
do $$ begin
  assert (select stage from public.job_cards where id = tests.id('j1')) = 'delivered', 'delivered';
  assert (select count(*) from public.job_history where job_id = tests.id('j1') and field = 'stage') >= 6, 'every stage change logged';
end $$;

-- TEST-025 Rejected estimate -> inspection fee, cancelled ------------------------------
select public.job_add_line(tests.id('j2'), 'part', tests.id('pads'), null, 1);
select public.job_send_estimate(tests.id('j2'));
select public.job_record_approval(tests.id('j2'), false, 'phone', 'Ali Raza');
do $$ begin
  assert (select stage from public.job_cards where id = tests.id('j2')) = 'cancelled', 'TEST-025: cancelled';
  assert (select sum(qty * unit_price_paisa) from public.job_lines where job_id = tests.id('j2') and status = 'approved') = 50000,
    'TEST-025: only the PKR 500 inspection fee remains';
  assert (select on_hand from public.item_stock where item_id = tests.id('pads')) = 3, 'TEST-025: no stock used';
end $$;

-- TEST-026 Rework: labour free, linked to original ------------------------------------------
insert into tests.fx values ('rw', public.station_create_rework(tests.id('j1'), true, 86000, 'H', 'Noise again'));
select public.job_add_line(tests.id('rw'), 'labour', null, 'Re-check brakes', 1, 200000);
select public.job_add_line(tests.id('rw'), 'part', tests.id('pads'), null, 1, 450000);
do $$ begin
  assert (select parent_job_id from public.job_cards where id = tests.id('rw')) = tests.id('j1'), 'TEST-026: linked';
  assert (select kind from public.job_cards where id = tests.id('rw')) = 'rework', 'TEST-026: rework kind';
  assert (select sum(unit_price_paisa) from public.job_lines where job_id = tests.id('rw')) = 0, 'TEST-026: labour and (chosen) parts free';
  assert exists (select 1 from public.job_assignments a join public.job_cards j on j.parent_job_id = a.job_id
                 where j.id = tests.id('rw') and a.user_id = tests.id('bilal')), 'TEST-026: original mechanic traceable';
end $$;

-- TEST-027 Warranty: battery sold 100 days ago, 180 days -> 80 left -------------------------
insert into tests.fx values ('j3', public.station_create_job(tests.id('S'), tests.id('cust'), tests.id('car'), 90000, 'F', 'Battery'));
insert into tests.fx values ('batline', public.job_add_line(tests.id('j3'), 'part', tests.id('battery'), null, 1));
select public.job_record_approval(tests.id('j3'), true, 'in_person', 'Ali Raza');
reset role;
update public.job_cards set stage = 'delivered', delivered_at = now() - interval '100 days' where id = tests.id('j3');
set role authenticated;
select tests.as_user(tests.id('cashier'));
do $$
declare w jsonb;
begin
  w := public.station_warranty_status(tests.id('batline'));
  assert (w ->> 'valid')::boolean, 'TEST-027: valid';
  assert (w ->> 'days_left')::int = 80, 'TEST-027: 80 days remaining, got ' || w::text;
end $$;
insert into tests.fx values ('wc', public.station_create_warranty_claim(tests.id('batline'), 91000, 'F', null, tests.id('sup')));
do $$ begin
  assert (select kind from public.job_cards where id = tests.id('wc')) = 'warranty', 'TEST-027: warranty job';
  assert (select unit_price_paisa from public.job_lines where job_id = tests.id('wc')) = 0, 'TEST-027: replacement charged 0';
  assert (select warranty_of_line from public.job_lines where job_id = tests.id('wc')) = tests.id('batline'), 'TEST-027: linked to original line';
end $$;
select tests.as_user(tests.id('owner'));
do $$ begin
  assert (select due_paisa from public.supplier_balances where supplier_id = tests.id('sup')) = 0,
    'TEST-027: return to supplier lowers due (18,000 - 18,000)';
end $$;
reset role;
update public.job_cards set delivered_at = now() - interval '200 days' where id = tests.id('j3');
set role authenticated;
select tests.as_user(tests.id('cashier'));
select tests.throws(format('select public.station_create_warranty_claim(%L, 1, %L, null)', tests.id('batline'), 'F'), 'WARRANTY_EXPIRED');

-- TEST-023 Sync suite: offline mechanic ---------------------------------------------------
insert into tests.fx values ('j4', public.station_create_job(tests.id('S'), tests.id('cust'), tests.id('car'), 95000, 'H', 'Service'));
select public.job_add_line(tests.id('j4'), 'labour', null, 'Oil change', 1, 150000);
select public.job_record_approval(tests.id('j4'), true, 'phone', 'Ali Raza');
select public.job_assign(tests.id('j4'), array[tests.id('bilal'), tests.id('asif')]);
reset role;
select private.move_stock(tests.id('S'), tests.id('filter'), 1, 'adjustment');  -- filter stock 1
set role authenticated;

select tests.as_user(tests.id('bilal'));
do $$
declare p jsonb; res jsonb; chk uuid;
begin
  p := public.sync_pull(tests.id('S'));
  assert jsonb_array_length(p -> 'jobs') = 1, 'pull: one assigned open job';
  assert not (p::text like '%price%'), 'pull: no prices for mechanics';
  assert jsonb_array_length(p -> 'items') >= 3, 'pull: item list with stock';
  select (e ->> 'id')::uuid into chk from jsonb_array_elements(p -> 'checklist') e limit 1;

  -- Ordered batch: start, add filter, finish checklist, request QC — as made offline.
  res := public.sync_apply(tests.id('S'), jsonb_build_array(
    jsonb_build_object('client_change_id', '00000000-0000-0000-0000-000000000001', 'client_time', now() + interval '1 minute',
                       'op', 'stage', 'args', jsonb_build_object('job_id', tests.id('j4'), 'stage', 'in_progress')),
    jsonb_build_object('client_change_id', '00000000-0000-0000-0000-000000000002', 'client_time', now() + interval '2 minutes',
                       'op', 'part_add', 'args', jsonb_build_object('line_id', '00000000-0000-0000-0000-0000000000a1',
                       'job_id', tests.id('j4'), 'item_id', tests.id('filter'), 'qty', 1))));
  assert (select count(*) from jsonb_array_elements(res) e where e ->> 'status' = 'applied') = 2, 'sync: applied in order ' || res::text;

  -- Duplicate upload (phone retried after a timeout) is ignored.
  res := public.sync_apply(tests.id('S'), jsonb_build_array(
    jsonb_build_object('client_change_id', '00000000-0000-0000-0000-000000000002', 'client_time', now() + interval '2 minutes',
                       'op', 'part_add', 'args', jsonb_build_object('line_id', '00000000-0000-0000-0000-0000000000a1',
                       'job_id', tests.id('j4'), 'item_id', tests.id('filter'), 'qty', 1))));
  assert res -> 0 ->> 'status' = 'duplicate', 'sync: duplicate ignored';
end $$;

-- Second mechanic also used a filter offline -> stock -1 and managers warned (TEST-031 acceptance).
select tests.as_user(tests.id('asif'));
do $$
declare res jsonb;
begin
  res := public.sync_apply(tests.id('S'), jsonb_build_array(
    jsonb_build_object('client_change_id', '00000000-0000-0000-0000-000000000003', 'client_time', now() + interval '150 seconds',
                       'op', 'part_add', 'args', jsonb_build_object('line_id', '00000000-0000-0000-0000-0000000000a2',
                       'job_id', tests.id('j4'), 'item_id', tests.id('filter'), 'qty', 1))));
  assert res -> 0 ->> 'status' = 'applied', 'sync: second mechanic applied';
end $$;
select tests.as_user(tests.id('manager'));
do $$ begin
  assert (select on_hand from public.item_stock where item_id = tests.id('filter')) = -1, 'TEST-031: two offline uses -> stock -1';
  assert exists (select 1 from public.notifications where kind = 'negative_stock'), 'TEST-031: manager alerted';
end $$;

-- Conflict: both mechanics set the same checklist item; the later client time wins.
select tests.as_user(tests.id('bilal'));
do $$
declare chk uuid; r1 jsonb; r2 jsonb;
begin
  select id into chk from public.job_checklist_items where job_id = tests.id('j4') order by sort_order limit 1;
  r1 := public.sync_apply(tests.id('S'), jsonb_build_array(jsonb_build_object(
    'client_change_id', '00000000-0000-0000-0000-000000000004', 'client_time', now() + interval '4 minutes',
    'op', 'check', 'args', jsonb_build_object('check_id', chk, 'status', 'attention', 'note', 'later'))));
  perform set_config('request.jwt.claim.sub', tests.id('asif')::text, false);
  r2 := public.sync_apply(tests.id('S'), jsonb_build_array(jsonb_build_object(
    'client_change_id', '00000000-0000-0000-0000-000000000005', 'client_time', now() + interval '3 minutes',
    'op', 'check', 'args', jsonb_build_object('check_id', chk, 'status', 'ok', 'note', 'earlier'))));
  assert r2 -> 0 ->> 'status' = 'conflict', 'sync: older change loses';
  assert (select status from public.job_checklist_items where id = chk) = 'attention', 'sync: later change kept';
  assert exists (select 1 from public.job_history where field = 'checklist:' || chk and conflict and new_value = 'ok'), 'sync: loser kept in history';
end $$;
select tests.as_user(tests.id('manager'));
do $$ begin
  assert exists (select 1 from public.notifications where kind = 'conflict'), 'sync: manager notified of conflict';
end $$;
reset role;

-- Read-only station: phone changes are held (kept on the phone), not lost.
update public.subscriptions set state = 'active', plan_code = 'standard', current_period_end = now() - interval '10 days'
 where station_id = tests.id('S');
set role authenticated;
select tests.as_user(tests.id('bilal'));
do $$
declare res jsonb;
begin
  res := public.sync_apply(tests.id('S'), jsonb_build_array(jsonb_build_object(
    'client_change_id', '00000000-0000-0000-0000-000000000006', 'client_time', now(),
    'op', 'part_remove', 'args', jsonb_build_object('line_id', '00000000-0000-0000-0000-0000000000a1'))));
  assert res -> 0 ->> 'status' = 'held', 'TEST-104: held while read-only';
  assert not exists (select 1 from public.sync_changes where client_change_id = '00000000-0000-0000-0000-000000000006'),
    'held change not recorded, so it is retried later';
end $$;
reset role;
