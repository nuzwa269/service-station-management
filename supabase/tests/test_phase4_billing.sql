-- TEST-035…044 · TASK-038…045
insert into tests.fx values
  ('owner',   tests.create_user('923301111111')),
  ('manager', tests.create_user('923302222222')),
  ('cashier', tests.create_user('923303333333'));

set role authenticated;
select tests.as_user(tests.id('owner'));
insert into tests.fx values ('S', public.station_signup('Billing Motors', 'Lahore', 'Bill Owner'));
reset role;
set role service_role;
select public.admin_add_member(tests.id('owner'), tests.id('S'), tests.id('manager'), 'Man Ager', '03302222222', 'manager');
select public.admin_add_member(tests.id('owner'), tests.id('S'), tests.id('cashier'), 'Cash Ier', '03303333333', 'cashier');
reset role;
update public.subscriptions set state = 'active', plan_code = 'standard', current_period_end = now() + interval '30 days'
 where station_id = tests.id('S');

-- Helper: a job with the given lines, approved by phone and moved to Ready.
create or replace function tests.ready_job(p_lines jsonb, p_ready boolean default true)
returns uuid language plpgsql as $$
declare v_job uuid; l jsonb;
begin
  v_job := public.station_create_job(tests.id('S'), tests.id('cust'), tests.id('car'),
    (select coalesce(max(odometer_km), 0) + 100 from public.job_cards where vehicle_id = tests.id('car')), 'H');
  for l in select * from jsonb_array_elements(p_lines) loop
    perform public.job_add_line(v_job, (l ->> 'kind')::public.line_kind, (l ->> 'item')::uuid, l ->> 'desc',
      coalesce((l ->> 'qty')::numeric, 1), (l ->> 'price')::bigint);
  end loop;
  perform public.job_record_approval(v_job, true, 'phone', 'Customer');
  if p_ready then
    perform public.job_set_stage(v_job, 'in_progress');
    perform public.job_set_stage(v_job, 'quality_check');
    perform set_config('request.jwt.claim.sub', tests.id('manager')::text, false);
    perform public.job_quality_check(v_job, true);
    perform set_config('request.jwt.claim.sub', tests.id('cashier')::text, false);
  end if;
  return v_job;
end $$;
grant execute on function tests.ready_job(jsonb, boolean) to authenticated;

set role authenticated;
select tests.as_user(tests.id('owner'));
insert into tests.fx values ('filter', public.station_save_item(tests.id('S'), '{"code":"F1","name":"Oil filter","selling_price_paisa":80000}'::jsonb));
insert into tests.fx values ('parts8k', public.station_save_item(tests.id('S'), '{"code":"P8","name":"Shock absorber","selling_price_paisa":800000}'::jsonb));
select public.station_request_stock_adjustment(tests.id('S'), tests.id('filter'), 20, 'count_difference');
select public.station_request_stock_adjustment(tests.id('S'), tests.id('parts8k'), 20, 'count_difference');
insert into tests.fx values ('cust', public.station_save_customer(tests.id('S'), null, 'Hamza', '03111234567'));
insert into tests.fx values ('car', public.station_save_vehicle(tests.id('S'), null, tests.id('cust'), 'LEB-555'));

-- TEST-035 Service list ------------------------------------------------------------------
insert into tests.fx values ('oilsvc', public.station_save_service(tests.id('S'), null, 'Oil change labour', 50000, 30));
select tests.as_user(tests.id('cashier'));
select tests.throws(format($q$select public.station_save_service(%L, null, 'X Y', 1, 0)$q$, tests.id('S')), 'FORBIDDEN');
do $$
declare v_job uuid; v_line uuid;
begin
  v_job := public.station_create_job(tests.id('S'), tests.id('cust'), tests.id('car'), 1000, 'H');
  v_line := public.job_add_service(v_job, tests.id('oilsvc'));
  assert (select unit_price_paisa from public.job_lines where id = v_line) = 50000, 'TEST-035: rate 500 filled in';
  assert (select warranty_days from public.job_lines where id = v_line) = 30, 'TEST-035: warranty carried';
  v_line := public.job_add_service(v_job, tests.id('oilsvc'), 1, 45000);
  assert (select unit_price_paisa from public.job_lines where id = v_line) = 45000, 'TEST-035: rate editable';
end $$;

-- TEST-036 Invoice: parts 8,000 + labour 1,500, tax off -> Rs 9,500, next number --------------
do $$
declare v_job uuid; v_inv uuid; v_inv2 uuid;
begin
  v_job := tests.ready_job(jsonb_build_array(
    jsonb_build_object('kind', 'part', 'item', tests.id('parts8k')),
    jsonb_build_object('kind', 'labour', 'desc', 'Fitting', 'price', 150000),
    jsonb_build_object('kind', 'customer_part', 'desc', 'Own wiper')));
  v_inv := public.station_create_invoice(v_job);
  assert (select total_paisa from public.invoices where id = v_inv) = 950000, 'TEST-036: total Rs 9,500';
  assert (select invoice_no from public.invoices where id = v_inv) = 1, 'TEST-036: first invoice number';
  assert (select count(*) from public.invoice_lines where invoice_id = v_inv) = 2, 'TEST-036: approved lines only, no customer part';
  assert public.station_create_invoice(v_job) = v_inv, 'TEST-036: one invoice per job card';
  v_inv2 := public.station_create_invoice(tests.ready_job(jsonb_build_array(jsonb_build_object('kind', 'labour', 'desc', 'Wash', 'price', 50000))));
  assert (select invoice_no from public.invoices where id = v_inv2) = 2, 'TEST-036: sequential';
  insert into tests.fx values ('inv9500', v_inv), ('job9500', v_job);
end $$;

-- TEST-004 tax per category, whole rupees
reset role;
update public.stations set sales_tax_enabled = true, parts_tax_pct = 18, services_tax_pct = 16 where id = tests.id('S');
set role authenticated;
select tests.as_user(tests.id('cashier'));
do $$
declare v_inv uuid;
begin
  v_inv := public.station_create_invoice(tests.ready_job(jsonb_build_array(
    jsonb_build_object('kind', 'part', 'item', tests.id('parts8k')),
    jsonb_build_object('kind', 'labour', 'desc', 'Fitting', 'price', 150000))));
  assert (select tax_parts_paisa from public.invoices where id = v_inv) = 144000, 'TEST-004: 18% of 8,000 = 1,440';
  assert (select tax_services_paisa from public.invoices where id = v_inv) = 24000, 'TEST-004: 16% of 1,500 = 240';
  assert (select total_paisa from public.invoices where id = v_inv) = 1118000, 'TEST-004: 9,500 + 1,680 = 11,180';
end $$;
reset role;
update public.stations set sales_tax_enabled = false where id = tests.id('S');
set role authenticated;
select tests.as_user(tests.id('cashier'));

-- TEST-037 Discount limit: 5% of 10,000; 800 needs approval --------------------------------
do $$
declare v_inv uuid;
begin
  v_inv := public.station_create_invoice(tests.ready_job(jsonb_build_array(jsonb_build_object('kind', 'labour', 'desc', 'Overhaul', 'price', 1000000))));
  insert into tests.fx values ('inv10k', v_inv);
  assert public.invoice_set_discount(v_inv, 50000, 'Regular') = 'applied', 'TEST-037: 500 within 5% applies';
  assert public.invoice_set_discount(v_inv, 80000, 'Loyal customer') = 'pending', 'TEST-037: 800 awaits approval';
  assert (select status from public.invoice_balances where invoice_id = v_inv) = 'discount_pending', 'TEST-037: shows Discount awaiting approval';
  perform tests.throws(format('select public.invoice_record_payment(%L, 1000, %L)', v_inv, 'cash'), 'VALIDATION');
end $$;
select tests.as_user(tests.id('manager'));
do $$
declare v_req uuid;
begin
  select id into v_req from public.approval_requests where record_id = tests.id('inv10k') and type = 'discount' and status = 'pending';
  perform public.station_decide_approval(v_req, true);
  assert (select total_paisa from public.invoices where id = tests.id('inv10k')) = 920000, 'TEST-037: approved -> 9,200';
end $$;
reset role;
update public.subscriptions set plan_code = 'basic' where station_id = tests.id('S');
set role authenticated;
select tests.as_user(tests.id('cashier'));
do $$
declare v_inv uuid;
begin
  v_inv := public.station_create_invoice(tests.ready_job(jsonb_build_array(jsonb_build_object('kind', 'labour', 'desc', 'Basic job', 'price', 1000000))));
  perform tests.throws(format('select public.invoice_set_discount(%L, 80000)', v_inv), 'OWNER_ONLY');
  perform set_config('request.jwt.claim.sub', tests.id('owner')::text, false);
  assert public.invoice_set_discount(v_inv, 80000) = 'applied', 'TEST-102: owner login applies 8% on Basic';
  assert (select total_paisa from public.invoices where id = v_inv) = 920000, 'TEST-102: Rs 9,200';
end $$;
reset role;
update public.subscriptions set plan_code = 'standard' where station_id = tests.id('S');
set role authenticated;
select tests.as_user(tests.id('cashier'));

-- TEST-038 Split payment 5,000 cash + 4,500 JazzCash --------------------------------------------
select tests.throws(format('select public.invoice_record_payment(%L, 450000, %L)', tests.id('inv9500'), 'jazzcash'), 'VALIDATION');  -- reference required
select tests.throws(format('select public.invoice_record_payment(%L, 960000, %L)', tests.id('inv9500'), 'cash'), 'VALIDATION');     -- more than due
select public.invoice_record_payment(tests.id('inv9500'), 500000, 'cash');
select public.invoice_record_payment(tests.id('inv9500'), 450000, 'jazzcash', '7781');
do $$ begin
  assert (select status from public.invoice_balances where invoice_id = tests.id('inv9500')) = 'paid', 'TEST-038: paid';
  assert (public.station_day_summary(tests.id('S')) -> 'expected' ->> 'jazzcash')::bigint = 450000, 'TEST-038: JazzCash shown separately';
  assert (select locked from public.invoices where id = tests.id('inv9500')), 'invoice fixed after payment';
  perform tests.throws(format('select public.invoice_set_discount(%L, 100)', tests.id('inv9500')), 'VALIDATION');
end $$;
select public.job_set_stage(tests.id('job9500'), 'delivered');

-- Advance before the invoice is counted on it
do $$
declare v_job uuid; v_inv uuid;
begin
  v_job := tests.ready_job(jsonb_build_array(jsonb_build_object('kind', 'labour', 'desc', 'Paint', 'price', 300000)));
  perform public.job_record_advance(v_job, 100000, 'cash');
  v_inv := public.station_create_invoice(v_job);
  assert (select due_paisa from public.invoice_balances where invoice_id = v_inv) = 200000, 'advance applied: due 2,000';
end $$;

-- TEST-039 Handover rule and credit release: due 3,000 ---------------------------------------
do $$
declare v_job uuid; v_inv uuid;
begin
  v_job := tests.ready_job(jsonb_build_array(jsonb_build_object('kind', 'labour', 'desc', 'Denting', 'price', 300000)));
  v_inv := public.station_create_invoice(v_job);
  insert into tests.fx values ('job3k', v_job), ('inv3k', v_inv);
  perform tests.throws(format('select public.job_set_stage(%L, %L)', v_job, 'delivered'), 'PAYMENT_DUE');
  assert public.invoice_request_credit(v_inv, 'Pays next week') = 'pending', 'TEST-039: request created';
end $$;
select tests.as_user(tests.id('owner'));
select public.station_decide_approval((select id from public.approval_requests where record_id = tests.id('inv3k') and type = 'credit_release'), true);
select tests.as_user(tests.id('cashier'));
select public.job_set_stage(tests.id('job3k'), 'delivered');
do $$ begin
  assert (select stage from public.job_cards where id = tests.id('job3k')) = 'delivered', 'TEST-039: delivered on credit';
  assert (select dues_paisa from public.customer_balances where customer_id = tests.id('cust')) = 300000, 'TEST-039: dues +3,000';
end $$;

-- TEST-040 Dues 3,000 + 2,000; pay 4,000 -> first cleared, 1,000 left on second ---------------------
do $$
declare v_job uuid; v_inv uuid;
begin
  v_job := tests.ready_job(jsonb_build_array(jsonb_build_object('kind', 'labour', 'desc', 'Tuning', 'price', 200000)));
  v_inv := public.station_create_invoice(v_job);
  perform public.invoice_request_credit(v_inv, 'Regular');
  perform set_config('request.jwt.claim.sub', tests.id('owner')::text, false);
  perform public.station_decide_approval((select id from public.approval_requests where record_id = v_inv and type = 'credit_release'), true);
  perform set_config('request.jwt.claim.sub', tests.id('cashier')::text, false);
  perform public.job_set_stage(v_job, 'delivered');
  assert (select dues_paisa from public.customer_balances where customer_id = tests.id('cust')) = 500000, 'TEST-040: dues 5,000';
  perform public.customer_collect_dues(tests.id('cust'), 400000, 'cash');
  assert (select due_paisa from public.invoice_balances where invoice_id = tests.id('inv3k')) = 0, 'TEST-040: oldest cleared';
  assert (select due_paisa from public.invoice_balances where invoice_id = v_inv) = 100000, 'TEST-040: 1,000 remains on the second';
end $$;

-- TEST-041 Refund 800 as credit with the unused filter back to stock -----------------------------
do $$
declare v_job uuid; v_inv uuid; v_line uuid; v_stock numeric;
begin
  v_job := tests.ready_job(jsonb_build_array(
    jsonb_build_object('kind', 'part', 'item', tests.id('filter')),
    jsonb_build_object('kind', 'labour', 'desc', 'Service', 'price', 100000)));
  v_inv := public.station_create_invoice(v_job);
  perform public.invoice_record_payment(v_inv, 180000, 'cash');
  select id into v_line from public.invoice_lines where invoice_id = v_inv and kind = 'part';
  select on_hand into v_stock from public.item_stock where item_id = tests.id('filter');
  assert public.invoice_request_refund(v_inv, 80000, 'credit', 'Filter not used',
    jsonb_build_array(jsonb_build_object('invoice_line_id', v_line, 'qty', 1))) = 'pending', 'TEST-041: needs approval';
  perform set_config('request.jwt.claim.sub', tests.id('manager')::text, false);
  perform public.station_decide_approval((select id from public.approval_requests where record_id = v_inv and type = 'refund'), true);
  perform set_config('request.jwt.claim.sub', tests.id('cashier')::text, false);
  assert (select amount_paisa from public.credit_notes where invoice_id = v_inv) = 80000, 'TEST-041: credit note 800';
  assert (select cn_no from public.credit_notes where invoice_id = v_inv) = 1, 'TEST-041: numbered';
  assert (select on_hand from public.item_stock where item_id = tests.id('filter')) = v_stock + 1, 'TEST-041: filter back in stock';
  assert (select credit_paisa from public.customer_balances where customer_id = tests.id('cust')) = 80000, 'TEST-041: 800 credit';
  assert (select total_paisa from public.invoices where id = v_inv) = 180000, 'TEST-041: original invoice unchanged';
  -- Credit used on the next invoice.
  v_inv := public.station_create_invoice(tests.ready_job(jsonb_build_array(jsonb_build_object('kind', 'labour', 'desc', 'Check', 'price', 50000))));
  perform public.invoice_use_credit(v_inv, 50000);
  assert (select status from public.invoice_balances where invoice_id = v_inv) = 'paid', 'credit pays an invoice';
  assert (select credit_paisa from public.customer_balances where customer_id = tests.id('cust')) = 30000, 'credit left 300';
end $$;

-- TEST-042 Reversal: 5,000 entered instead of 500 ------------------------------------------------
do $$
declare v_inv uuid; v_pay uuid; v_cash_before bigint;
begin
  v_inv := public.station_create_invoice(tests.ready_job(jsonb_build_array(jsonb_build_object('kind', 'labour', 'desc', 'Polish', 'price', 600000))));
  v_cash_before := coalesce((public.station_day_summary(tests.id('S')) -> 'expected' ->> 'cash')::bigint, 0);
  v_pay := public.invoice_record_payment(v_inv, 500000, 'cash');
  perform tests.throws(format('select public.payment_reverse(%L, %L)', v_pay, 'typing error'), 'NOT_FOUND');  -- cashier cannot reverse
  perform set_config('request.jwt.claim.sub', tests.id('manager')::text, false);
  perform tests.throws(format('select public.payment_reverse(%L, %L)', v_pay, ''), 'VALIDATION');
  perform public.payment_reverse(v_pay, 'typing error');
  perform tests.throws(format('select public.payment_reverse(%L, %L)', v_pay, 'again'), 'VALIDATION');
  perform public.invoice_record_payment(v_inv, 50000, 'cash');
  assert (select count(*) from public.payments where invoice_id = v_inv) = 3, 'TEST-042: original, reversal and new visible';
  assert (public.station_day_summary(tests.id('S')) -> 'expected' ->> 'cash')::bigint - v_cash_before = 50000, 'TEST-042: day counts 500';
  perform set_config('request.jwt.claim.sub', tests.id('cashier')::text, false);
end $$;

-- TEST-043 Storage: 3 free days, Rs 300/day, collected on day 6 -> Rs 900 -------------------------
reset role;
update public.stations set storage_free_days = 3, storage_charge_paisa = 30000 where id = tests.id('S');
set role authenticated;
select tests.as_user(tests.id('cashier'));
insert into tests.fx values ('jobst', tests.ready_job(jsonb_build_array(jsonb_build_object('kind', 'labour', 'desc', 'Engine work', 'price', 100000))));
reset role;
update public.job_cards set ready_at = now() - interval '6 days' where id = tests.id('jobst');
select private.daily_ready_jobs();
set role authenticated;
select tests.as_user(tests.id('cashier'));
do $$
declare v_inv uuid;
begin
  v_inv := public.station_create_invoice(tests.id('jobst'));
  assert (select total_paisa from public.invoice_lines where invoice_id = v_inv and description like 'Storage%') = 90000, 'TEST-043: storage Rs 900';
  assert (select total_paisa from public.invoices where id = v_inv) = 190000, 'TEST-043: invoice 1,000 + 900';
end $$;
select tests.as_user(tests.id('owner'));
do $$ begin
  assert exists (select 1 from public.notifications where ref_id = tests.id('jobst') and kind = 'uncollected'), 'TEST-043: reminder to staff';
end $$;

-- TEST-044 Day closing: expected cash vs counted ----------------------------------------------------
select tests.as_user(tests.id('cashier'));
do $$
declare v_exp bigint; v_diff bigint; v_inv uuid;
begin
  v_exp := (public.station_day_summary(tests.id('S')) -> 'expected' ->> 'cash')::bigint;
  perform tests.throws(format('select public.station_close_day(%L, %L, %s)', tests.id('S'), private.today_pk(), v_exp - 50000), 'VALIDATION');
  v_diff := public.station_close_day(tests.id('S'), private.today_pk(), v_exp - 50000, 'Short by 500, checked twice');
  assert v_diff = -50000, 'TEST-044: difference −500';
  v_inv := public.station_create_invoice(tests.ready_job(jsonb_build_array(jsonb_build_object('kind', 'labour', 'desc', 'After close', 'price', 10000))));
  perform tests.throws(format('select public.invoice_record_payment(%L, 10000, %L)', v_inv, 'cash'), 'DAY_CLOSED');
  perform tests.throws(format('select public.station_reopen_day(%L, %L, %L)', tests.id('S'), private.today_pk(), 'mistake'), 'FORBIDDEN');
  perform set_config('request.jwt.claim.sub', tests.id('owner')::text, false);
  perform public.station_reopen_day(tests.id('S'), private.today_pk(), 'Late payment to add');
  perform public.invoice_record_payment(v_inv, 10000, 'cash');
  assert exists (select 1 from public.audit_log where table_name = 'day_closings' and action = 'update'), 'TEST-044: reopen logged';
end $$;
reset role;

-- Payments are append-only even for the database owner (REQ-042).
do $$ begin
  perform tests.throws('delete from public.payments', 'APPEND_ONLY');
  perform tests.throws('update public.credit_notes set amount_paisa = 1', 'APPEND_ONLY');
end $$;
