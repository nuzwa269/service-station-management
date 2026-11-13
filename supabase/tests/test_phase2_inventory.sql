-- TEST-028…034, TEST-046, TEST-048, TEST-057 · TASK-020…028
insert into tests.fx values
  ('owner',   tests.create_user('923101111111')),
  ('manager', tests.create_user('923102222222')),
  ('cashier', tests.create_user('923103333333')),
  ('mech',    tests.create_user('923104444444'));

set role authenticated;
select tests.as_user(tests.id('owner'));
insert into tests.fx values ('S', public.station_signup('Inventory Autos', 'Lahore', 'Inv Owner'));
reset role;
set role service_role;
select public.admin_add_member(tests.id('owner'), tests.id('S'), tests.id('manager'), 'Man Ager', '03102222222', 'manager');
select public.admin_add_member(tests.id('owner'), tests.id('S'), tests.id('cashier'), 'Cash Ier', '03103333333', 'cashier');
select public.admin_add_member(tests.id('owner'), tests.id('S'), tests.id('mech'),    'Mech Anic', '03104444444', 'mechanic');
reset role;
-- Standard plan, active.
update public.subscriptions set state = 'active', plan_code = 'standard', current_period_end = now() + interval '30 days'
 where station_id = tests.id('S');

-- TEST-028 Item master ---------------------------------------------------------
set role authenticated;
select tests.as_user(tests.id('manager'));
insert into tests.fx values ('filter', public.station_save_item(tests.id('S'),
  '{"code":"F-01","name":"Oil filter","unit":"piece","selling_price_paisa":90000,"min_stock":5}'::jsonb));
insert into tests.fx values ('oil', public.station_save_item(tests.id('S'),
  '{"code":"OIL-5W30","name":"Engine oil 5W-30 (drum)","unit":"litre","is_bulk":true,"selling_price_paisa":250000}'::jsonb));
select tests.throws(format($q$select public.station_save_item(%L, '{"code":"F-01","name":"Dup"}'::jsonb)$q$, tests.id('S')), 'VALIDATION');
select tests.throws(format($q$select public.station_save_item(%L, '{"code":"X","name":"Bulk piece","unit":"piece","is_bulk":true}'::jsonb)$q$, tests.id('S')), 'VALIDATION');
insert into tests.fx values ('kit', public.station_save_item(tests.id('S'),
  '{"code":"KIT-SVC","name":"Service kit","unit":"kit","selling_price_paisa":400000}'::jsonb,
  jsonb_build_array(jsonb_build_object('item_id', tests.id('filter'), 'qty', 1), jsonb_build_object('item_id', tests.id('oil'), 'qty', 4))));
select tests.as_user(tests.id('cashier'));
select tests.throws(format($q$select public.station_save_item(%L, '{"code":"C1","name":"Cashier item"}'::jsonb)$q$, tests.id('S')), 'FORBIDDEN');
do $$ begin
  assert (select count(*) from public.items where station_id = tests.id('S')) = 3, 'TEST-028: cashier reads items';
  assert (select count(*) from public.item_costs) = 0, 'TEST-028: cashier cannot see purchase cost';
end $$;
select tests.as_user(tests.id('mech'));
do $$ begin
  assert (select count(*) from public.items) = 0, 'TEST-028: mechanic sees no prices';
end $$;
reset role;

-- TEST-029 Purchases and weighted average cost ---------------------------------
set role authenticated;
select tests.as_user(tests.id('manager'));
insert into tests.fx values ('sup', public.station_save_supplier(tests.id('S'), null, 'Auto Parts Co', '0300-5555555'));
insert into tests.fx values ('p1', public.station_post_purchase(tests.id('S'), tests.id('sup'), null, 'B-1', current_date,
  jsonb_build_array(jsonb_build_object('item_id', tests.id('filter'), 'qty', 10, 'unit_cost_paisa', 40000),
                    jsonb_build_object('item_id', tests.id('oil'), 'qty', 200, 'unit_cost_paisa', 150000)), 0));
insert into tests.fx values ('p2', public.station_post_purchase(tests.id('S'), tests.id('sup'), null, 'B-2', current_date,
  jsonb_build_array(jsonb_build_object('item_id', tests.id('filter'), 'qty', 10, 'unit_cost_paisa', 50000)), 0));
select tests.throws(format($q$select public.station_post_purchase(%L, null, null, 'B-3', null, '[{"item_id":"%s","qty":1,"unit_cost_paisa":1}]'::jsonb)$q$,
  tests.id('S'), tests.id('filter')), 'VALIDATION');  -- supplier name required
select tests.throws(format($q$select public.station_post_purchase(%L, %L, null, 'B-4', null, '[{"item_id":"%s","qty":1.5,"unit_cost_paisa":1}]'::jsonb)$q$,
  tests.id('S'), tests.id('sup'), tests.id('filter')), 'VALIDATION');  -- pieces are whole numbers
select tests.as_user(tests.id('owner'));
do $$ begin
  assert (select on_hand from public.item_stock where item_id = tests.id('filter')) = 20, 'TEST-029: stock 20';
  assert (select avg_cost_paisa from public.item_costs where item_id = tests.id('filter')) = 45000, 'TEST-029: average cost 450';
end $$;
select tests.as_user(tests.id('cashier'));
select tests.throws(format($q$select public.station_post_purchase(%L, null, 'X Y', 'B-9', null, '[{"item_id":"%s","qty":1,"unit_cost_paisa":1}]'::jsonb)$q$,
  tests.id('S'), tests.id('filter')), 'FORBIDDEN');
reset role;

-- TEST-028 Bulk litres: 3.5 L used drops stock by 3.50 (job use arrives in Phase 3; same movement)
select private.move_stock(tests.id('S'), tests.id('oil'), -3.5, 'job_use');
do $$ begin
  assert (select on_hand from public.item_stock where item_id = tests.id('oil')) = 196.5, 'TEST-028: 200 - 3.5 L = 196.50';
  perform tests.throws(format('select private.move_stock(%L, %L, -0.125, %L)', tests.id('S'), tests.id('oil'), 'job_use'), 'VALIDATION');
  perform tests.throws(format('select private.move_stock(%L, %L, -1, %L)', tests.id('S'), tests.id('kit'), 'job_use'), 'VALIDATION');
  perform tests.throws('update public.stock_movements set qty = 1', 'APPEND_ONLY');
  perform tests.throws('delete from public.stock_movements', 'APPEND_ONLY');
end $$;

-- TEST-030 Supplier ledger: purchases 50,000, payments 30,000 -> due 20,000 -----------
set role authenticated;
select tests.as_user(tests.id('manager'));
insert into tests.fx values ('sup2', public.station_save_supplier(tests.id('S'), null, 'Lubes Ltd', null));
select public.station_post_purchase(tests.id('S'), tests.id('sup2'), null, 'L-1', current_date,
  jsonb_build_array(jsonb_build_object('item_id', tests.id('filter'), 'qty', 50, 'unit_cost_paisa', 100000)), 1000000);
select public.station_pay_supplier(tests.id('sup2'), 2000000, 'bank', 'TRX-77');
select tests.throws(format('select public.station_pay_supplier(%L, 0, %L)', tests.id('sup2'), 'cash'), 'VALIDATION');
do $$ begin
  assert (select purchases_paisa from public.supplier_balances where supplier_id = tests.id('sup2')) = 5000000, 'TEST-030: purchases 50,000';
  assert (select payments_paisa from public.supplier_balances where supplier_id = tests.id('sup2')) = 3000000, 'TEST-030: payments 30,000';
  assert (select due_paisa from public.supplier_balances where supplier_id = tests.id('sup2')) = 2000000, 'TEST-030: due 20,000';
end $$;

-- REQ-042 reversal with reason
select tests.throws(format('select public.station_reverse_purchase(%L, %L)', tests.id('p2'), ''), 'VALIDATION');
select public.station_reverse_purchase(tests.id('p2'), 'Wrong bill entered');
select tests.throws(format('select public.station_reverse_purchase(%L, %L)', tests.id('p2'), 'again'), 'VALIDATION');
do $$ begin
  assert (select on_hand from public.item_stock where item_id = tests.id('filter')) = 60, 'reversal: 20 + 50 - 10 = 60';
  assert (select status from public.purchases where id = tests.id('p2')) = 'reversed', 'reversal: status';
  assert (select due_paisa from public.supplier_balances where supplier_id = tests.id('sup')) = 400000 + 30000000, 'reversal: due = bill 1 only (filters 4,000 + oil 300,000)';
end $$;
reset role;

-- TEST-032 / TEST-057 Stock adjustment through approvals (Standard) -------------------
set role authenticated;
select tests.as_user(tests.id('cashier'));
insert into tests.fx values ('adj1', public.station_request_stock_adjustment(tests.id('S'), tests.id('filter'), -2, 'damaged'));
select tests.throws(format('select public.station_request_stock_adjustment(%L, %L, -1, %L)', tests.id('S'), tests.id('filter'), 'other'), 'VALIDATION');
select tests.throws(format('select public.station_decide_approval(%L, true)', tests.id('adj1')), 'NOT_FOUND');  -- cashier cannot approve
select tests.as_user(tests.id('owner'));
select public.station_decide_approval(tests.id('adj1'), false, 'Count again');
select tests.throws(format('select public.station_decide_approval(%L, true)', tests.id('adj1')), 'VALIDATION');  -- final
select tests.as_user(tests.id('cashier'));
do $$ begin
  assert (select on_hand from public.item_stock where item_id = tests.id('filter')) = 60, 'TEST-032: rejected -> stock unchanged';
  assert (select decision_note from public.approval_requests where id = tests.id('adj1')) = 'Count again', 'TEST-032: requester sees note';
end $$;
insert into tests.fx values ('adj2', public.station_request_stock_adjustment(tests.id('S'), tests.id('filter'), -2, 'damaged'));
select tests.as_user(tests.id('manager'));  -- delegated approval rights (default on)
select public.station_decide_approval(tests.id('adj2'), true);
do $$ begin
  assert (select on_hand from public.item_stock where item_id = tests.id('filter')) = 58, 'TEST-032: approved -> stock 58';
  assert (select decided_by_name from public.approval_inbox where id = tests.id('adj2')) = 'Man Ager', 'TEST-057: shows approver';
end $$;
-- Manager cannot decide own request; owner turns delegation off.
insert into tests.fx values ('adj3', public.station_request_stock_adjustment(tests.id('S'), tests.id('filter'), 1, 'count_difference'));
select tests.throws(format('select public.station_decide_approval(%L, true)', tests.id('adj3')), 'VALIDATION');
select tests.as_user(tests.id('owner'));
select public.station_set_manager_can_approve(tests.id('S'), false);
select tests.as_user(tests.id('manager'));
do $$ begin
  assert (select count(*) from public.approval_requests where status = 'pending' and requested_by <> tests.id('manager')) = 0,
    'without delegation the manager no longer sees others'' requests';
end $$;
reset role;

-- Basic plan: no inbox; only the owner can adjust (PRD §3).
update public.subscriptions set plan_code = 'basic' where station_id = tests.id('S');
set role authenticated;
select tests.as_user(tests.id('cashier'));
select tests.throws(format('select public.station_request_stock_adjustment(%L, %L, -1, %L)', tests.id('S'), tests.id('filter'), 'expired'), 'OWNER_ONLY');
select tests.as_user(tests.id('owner'));
select public.station_request_stock_adjustment(tests.id('S'), tests.id('filter'), -1, 'expired');
do $$ begin
  assert (select on_hand from public.item_stock where item_id = tests.id('filter')) = 57, 'Basic: owner adjustment applies at once';
end $$;
-- Basic: free-text supplier name; supplier list is Standard+.
select tests.throws(format($q$select public.station_save_supplier(%L, null, 'New Sup', null)$q$, tests.id('S')), 'FEATURE_LOCKED');
select public.station_post_purchase(tests.id('S'), null, 'Bazaar shop', 'X-1', current_date,
  jsonb_build_array(jsonb_build_object('item_id', tests.id('filter'), 'qty', 1, 'unit_cost_paisa', 45000)));
reset role;
update public.subscriptions set plan_code = 'standard' where station_id = tests.id('S');

-- TEST-033 Low stock: minimum 5, stock 6, use 1 -> listed ----------------------------
set role authenticated;
select tests.as_user(tests.id('owner'));
insert into tests.fx values ('plug', public.station_save_item(tests.id('S'), '{"code":"SP-1","name":"Spark plug","min_stock":5}'::jsonb));
select public.station_request_stock_adjustment(tests.id('S'), tests.id('plug'), 6, 'count_difference');
do $$ begin
  assert not exists (select 1 from public.low_stock_items where item_id = tests.id('plug')), 'TEST-033: 6 > 5 not low';
end $$;
reset role;
select private.move_stock(tests.id('S'), tests.id('plug'), -1, 'job_use');
select private.move_stock(tests.id('S'), tests.id('plug'), -6, 'job_use');
set role authenticated;
select tests.as_user(tests.id('owner'));
do $$ begin
  assert exists (select 1 from public.low_stock_items where item_id = tests.id('plug') and negative), 'TEST-031/033: negative stock listed';
end $$;

-- TEST-034 Import 1,000 items, 3 without a name -------------------------------------
do $$
declare res jsonb;
begin
  res := public.station_import_items(tests.id('S'), (
    select jsonb_agg(jsonb_build_object(
      'row', g + 1, 'code', 'IMP-' || g,
      'name', case when g in (10, 500, 999) then '' else 'Imported part ' || g end,
      'unit', case when g % 10 = 0 then 'litre' else 'piece' end,
      'selling_price', '1200', 'purchase_price', '800.50', 'opening_qty', '4'))
    from generate_series(0, 999) g));
  assert (res ->> 'added')::int = 997, 'TEST-034: 997 added, got ' || res::text;
  assert (res ->> 'rejected')::int = 3, 'TEST-034: 3 rejected';
  assert (select count(*) from jsonb_array_elements(res -> 'rejected_rows') e where e ->> 'reason' = 'Name missing') = 3, 'TEST-034: reason Name missing';
  assert (select avg_cost_paisa from public.item_costs c join public.items i on i.id = c.item_id where i.code = 'IMP-1') = 80050, 'TEST-034: cost imported';
  -- Re-import updates instead of duplicating.
  res := public.station_import_items(tests.id('S'), '[{"row":2,"code":"IMP-1","name":"Renamed part","selling_price":"1300"}]'::jsonb);
  assert (res ->> 'updated')::int = 1 and (res ->> 'added')::int = 0, 'TEST-034: re-import updates';
  assert (select count(*) from public.items where code = 'IMP-1') = 1, 'TEST-034: no duplicate';
  assert (select on_hand from public.item_stock s join public.items i on i.id = s.item_id where i.code = 'IMP-1') = 4, 'TEST-034: opening stock not doubled';
end $$;
reset role;

-- TEST-046 Customers and vehicles, search -------------------------------------------
set role authenticated;
select tests.as_user(tests.id('cashier'));
insert into tests.fx values ('cust', public.station_save_customer(tests.id('S'), null, 'Ali Raza', '0300-1234567'));
insert into tests.fx values ('car', public.station_save_vehicle(tests.id('S'), null, tests.id('cust'), 'lea 1234', 'Toyota', 'Corolla', 2018));
select tests.throws(format($q$select public.station_save_customer(%L, null, 'Other', '03001234567')$q$, tests.id('S')), 'VALIDATION');
select tests.throws(format($q$select public.station_save_vehicle(%L, null, %L, 'LEA-1234')$q$, tests.id('S'), tests.id('cust')), 'VALIDATION');
do $$ begin
  assert (select plate from public.vehicles where id = tests.id('car')) = 'LEA-1234', 'TEST-046: plate normalised';
  assert exists (select 1 from public.station_search_customers(tests.id('S'), '1234') where plate = 'LEA-1234' and name = 'Ali Raza'), 'TEST-046: search 1234';
  assert exists (select 1 from public.station_search_customers(tests.id('S'), '0300-1234567')), 'TEST-046: search phone';
  assert exists (select 1 from public.station_search_customers(tests.id('S'), 'ali')), 'TEST-046: search name';
end $$;
insert into tests.fx values ('cust2', public.station_save_customer(tests.id('S'), null, 'Sara Khan', '03211234567'));
select public.station_save_vehicle(tests.id('S'), tests.id('car'), tests.id('cust2'), 'LEA-1234', 'Toyota', 'Corolla', 2018);
do $$ begin
  -- TEST-048 (partial): timeline shows ownership, newest first.
  assert (select title from public.station_vehicle_history(tests.id('car')) limit 1) = 'Owner changed to Sara Khan', 'TEST-048: newest first';
  assert (select count(*) from public.station_vehicle_history(tests.id('car'))) = 2, 'TEST-048: 2 events';
end $$;
select tests.as_user(tests.id('mech'));
do $$ begin
  assert (select count(*) from public.customers) = 0, 'mechanic sees no customer list';
end $$;
reset role;

-- TEST-034 customers import
set role authenticated;
select tests.as_user(tests.id('owner'));
do $$
declare res jsonb;
begin
  res := public.station_import_customers(tests.id('S'),
    '[{"row":2,"name":"Imran","mobile":"0333-1112223","plate":"KHI 999"},
      {"row":3,"name":"","mobile":"03331112224"},
      {"row":4,"name":"Bad Plate","mobile":"03331112225","plate":"!!!"}]'::jsonb);
  assert (res ->> 'added')::int = 1 and (res ->> 'rejected')::int = 2, 'customer import counts: ' || res::text;
end $$;
reset role;
