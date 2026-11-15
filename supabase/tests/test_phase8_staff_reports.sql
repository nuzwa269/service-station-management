-- TEST-050…054, 059, 060, 105 · TASK-063…067
insert into tests.fx values
  ('owner',   tests.create_user('923431111111')),
  ('manager', tests.create_user('923432222222')),
  ('cashier', tests.create_user('923433333333')),
  ('mech',    tests.create_user('923434444444')),
  ('ownerS',  tests.create_user('923435555555'));

set role authenticated;
select tests.as_user(tests.id('owner'));
insert into tests.fx values ('P', public.station_signup('Premium Motors', 'Lahore', 'Owner P'));
select tests.as_user(tests.id('ownerS'));
insert into tests.fx values ('S', public.station_signup('Standard Garage', 'Lahore', 'Owner S'));
reset role;
set role service_role;
select public.admin_add_member(tests.id('owner'), tests.id('P'), tests.id('manager'), 'Man Ager', '03432222222', 'manager');
select public.admin_add_member(tests.id('owner'), tests.id('P'), tests.id('cashier'), 'Cash Ier', '03433333333', 'cashier');
select public.admin_add_member(tests.id('owner'), tests.id('P'), tests.id('mech'), 'Bilal Mechanic', '03434444444', 'mechanic');
reset role;
update public.subscriptions set state = 'active', plan_code = 'premium', current_period_end = now() + interval '30 days'
  where station_id = tests.id('P');
update public.subscriptions set state = 'active', plan_code = 'standard', current_period_end = now() + interval '30 days'
  where station_id = tests.id('S');

-- The latest finished month with 30 days (PRD example), and a day inside it.
create or replace function tests.m30() returns date language sql stable as $$
  select m::date from generate_series(date_trunc('month', private.today_pk()) - interval '1 month',
                                      date_trunc('month', private.today_pk()) - interval '12 months', interval '-1 month') m
  where extract(day from m + interval '1 month - 1 day') = 30 limit 1
$$;
grant execute on all functions in schema tests to authenticated, service_role;

-- TEST-050 Staff record: salary and commission visible to the owner only ---------------------
set role authenticated;
select tests.as_user(tests.id('owner'));
insert into tests.fx values ('stBilal', public.station_save_staff(tests.id('P'),
  jsonb_build_object('user_id', tests.id('mech'), 'name', 'Bilal', 'mobile', '0343-4444444', 'role', 'mechanic',
                     'salary_paisa', 3000000, 'commission_pct', 10, 'joined_on', tests.m30() - 100)));
insert into tests.fx values ('stHelper', public.station_save_staff(tests.id('P'),
  jsonb_build_object('name', 'Helper Asif', 'role', 'helper', 'salary_paisa', 2000000, 'joined_on', tests.m30() - 100)));
select tests.throws(format($q$select public.station_save_staff(%L, '{"name":"X Y","role":"mechanic","commission_pct":150}')$q$, tests.id('P')), 'VALIDATION');
do $$ begin
  assert (select salary_paisa from public.station_staff_pay(tests.id('P')) where staff_id = tests.id('stBilal')) = 3000000, 'TEST-050: salary';
  assert (select commission_pct from public.station_staff_pay(tests.id('P')) where staff_id = tests.id('stBilal')) = 10, 'TEST-050: commission';
end $$;
select tests.as_user(tests.id('manager'));
select tests.throws(format('select count(*) from public.station_staff_pay(%L)', tests.id('P')), 'FORBIDDEN');
select tests.throws(format($q$select public.station_save_staff(%L, '{"name":"X Y","role":"helper"}')$q$, tests.id('P')), 'FORBIDDEN');
do $$ begin
  assert (select count(*) from public.staff where station_id = tests.id('P')) = 2, 'manager sees the staff list';
  begin
    perform salary_paisa from public.staff limit 1;
    raise exception 'TEST-050: manager read the salary column';
  exception when insufficient_privilege then null;
  end;
end $$;
select tests.as_user(tests.id('ownerS'));
select tests.throws(format($q$select public.station_save_staff(%L, '{"name":"X Y","role":"helper"}')$q$, tests.id('S')), 'FEATURE_LOCKED');

-- TEST-051 Attendance: manager today only, owner any day ------------------------------------
select tests.as_user(tests.id('manager'));
select public.station_set_attendance(tests.id('stHelper'), private.today_pk(), 'present');
select tests.throws(format($q$select public.station_set_attendance(%L, %L, 'absent')$q$, tests.id('stHelper'), private.today_pk() - 1), 'FORBIDDEN');
select tests.throws(format($q$select public.station_set_attendance(%L, %L, 'absent')$q$, tests.id('stHelper'), private.today_pk() + 1), 'VALIDATION');
select tests.as_user(tests.id('owner'));
select public.station_set_attendance(tests.id('stHelper'), private.today_pk() - 1, 'leave', 'Wedding');
-- PRD example: 2 absent days in the 30-day month.
select public.station_set_attendance(tests.id('stBilal'), tests.m30() + 4, 'absent');
select public.station_set_attendance(tests.id('stBilal'), tests.m30() + 11, 'absent');
select public.station_set_attendance(tests.id('stBilal'), tests.m30() + 12, 'off');
select tests.as_user(tests.id('cashier'));
select tests.throws(format($q$select public.station_set_attendance(%L, %L, 'present')$q$, tests.id('stHelper'), private.today_pk()), 'NOT_FOUND');

-- TEST-052 Advance of 5,000 in the month → deducted in that month ---------------------------
select tests.as_user(tests.id('manager'));
select tests.throws(format('select public.station_add_advance(%L, 500000)', tests.id('stBilal')), 'NOT_FOUND');
select tests.as_user(tests.id('owner'));
select tests.throws(format('select public.station_add_advance(%L, 0)', tests.id('stBilal')), 'VALIDATION');
select public.station_add_advance(tests.id('stBilal'), 500000, 'cash', tests.m30() + 9);
-- An advance split over 2 months for the helper: half this month.
select public.station_add_advance(tests.id('stHelper'), 300001, 'cash', tests.m30() + 2, 2);

-- Commission: Rs 50,000 labour on Bilal's job, invoice paid in that month.
insert into tests.fx values ('cust', public.station_save_customer(tests.id('P'), null, 'Ali Raza', '0300-1112223'));
insert into tests.fx values ('car', public.station_save_vehicle(tests.id('P'), null, tests.id('cust'), 'LEA-1234'));
insert into tests.fx values ('job1', public.station_create_job(tests.id('P'), tests.id('cust'), tests.id('car'), 50000, 'H'));
select public.job_add_line(tests.id('job1'), 'labour', null, 'Engine work', 1, 5000000);
select public.job_record_approval(tests.id('job1'), true, 'phone', 'Ali');
select public.job_assign(tests.id('job1'), array[tests.id('mech')]);
select public.job_set_stage(tests.id('job1'), 'in_progress');
reset role;
update public.job_checklist_items set status = 'ok';
set role authenticated;
select tests.as_user(tests.id('owner'));
select public.job_set_stage(tests.id('job1'), 'quality_check');
select public.job_quality_check(tests.id('job1'), true);
insert into tests.fx values ('inv1', public.station_create_invoice(tests.id('job1')));
select public.invoice_record_payment(tests.id('inv1'), 5000000, 'cash');
reset role;
-- The payment belongs to the 30-day month (payments are append-only in normal use).
alter table public.payments disable trigger payments_append_only;
update public.payments set paid_on = tests.m30() + 20 where invoice_id = tests.id('inv1');
alter table public.payments enable trigger payments_append_only;

-- TEST-053 / TEST-105 Payroll: 28,000 + 5,000 − 5,000 = Rs 28,000 ----------------------------
set role authenticated;
select tests.as_user(tests.id('manager'));
select tests.throws(format('select public.payroll_generate(%L, %L)', tests.id('P'), tests.m30()), 'FORBIDDEN');
select tests.as_user(tests.id('owner'));
insert into tests.fx values ('run', public.payroll_generate(tests.id('P'), tests.m30()));
do $$
declare l public.payroll_lines;
begin
  select * into l from public.payroll_lines where run_id = tests.id('run') and staff_id = tests.id('stBilal');
  assert l.days_in_month = 30 and l.paid_days = 28, format('TEST-053: paid days %s of %s', l.paid_days, l.days_in_month);
  assert l.salary_paisa = 2800000, 'TEST-053: salary earned 28,000, got ' || l.salary_paisa;
  assert l.labour_paisa = 5000000 and l.commission_paisa = 500000, 'TEST-053: commission 5,000, got ' || l.commission_paisa;
  assert l.advances_paisa = 500000, 'TEST-052: advance 5,000 deducted';
  assert l.net_paisa = 2800000, 'TEST-105: net Rs 28,000, got ' || l.net_paisa;
  assert (select advances_paisa from public.payroll_lines where run_id = tests.id('run') and staff_id = tests.id('stHelper')) = 150000,
    'TEST-052: split advance, first half';
end $$;
-- Adjustment needs a note; regenerating keeps it.
select tests.throws(format('select public.payroll_set_adjustment(%L, 100000, null)',
  (select id from public.payroll_lines where run_id = tests.id('run') and staff_id = tests.id('stBilal'))), 'VALIDATION');
select public.payroll_set_adjustment((select id from public.payroll_lines where run_id = tests.id('run') and staff_id = tests.id('stBilal')), 100000, 'Eid bonus');
select public.payroll_generate(tests.id('P'), tests.m30());
do $$ begin
  assert (select net_paisa from public.payroll_lines where run_id = tests.id('run') and staff_id = tests.id('stBilal')) = 2900000,
    'TEST-053: adjustment kept after regenerate';
end $$;
select public.payroll_set_adjustment((select id from public.payroll_lines where run_id = tests.id('run') and staff_id = tests.id('stBilal')), 0, null);
select public.payroll_finalize(tests.id('run'));
-- TEST-105: locked after finalise.
select tests.throws(format('select public.payroll_generate(%L, %L)', tests.id('P'), tests.m30()), 'VALIDATION');
select tests.throws(format('select public.payroll_set_adjustment(%L, 1, ''Late fix'')',
  (select id from public.payroll_lines where run_id = tests.id('run') and staff_id = tests.id('stBilal'))), 'VALIDATION');
select tests.throws(format($q$select public.station_set_attendance(%L, %L, 'absent')$q$, tests.id('stBilal'), tests.m30() + 1), 'VALIDATION');
select tests.throws(format('select public.station_add_advance(%L, 1000, ''cash'', %L)', tests.id('stBilal'), tests.m30() + 3), 'VALIDATION');
select tests.throws(format('select public.payroll_finalize(%L)', tests.id('run')), 'VALIDATION');
-- The current month can be drafted but not finalised before it ends.
insert into tests.fx values ('runNow', public.payroll_generate(tests.id('P'), private.today_pk()));
select tests.throws(format('select public.payroll_finalize(%L)', tests.id('runNow')), 'VALIDATION');
select tests.as_user(tests.id('manager'));
do $$ begin
  assert (select count(*) from public.payroll_lines) = 0, 'manager does not see payroll';
end $$;
-- Split advance: the second half (with the remainder) comes the next month.
select tests.as_user(tests.id('owner'));
insert into tests.fx values ('runNext', public.payroll_generate(tests.id('P'), (tests.m30() + interval '1 month')::date));
do $$ begin
  assert (select advances_paisa from public.payroll_lines where run_id = tests.id('runNext') and staff_id = tests.id('stHelper')) = 150001,
    'TEST-052: split advance, second half';
end $$;
reset role;

-- TEST-054 Mechanic performance -------------------------------------------------------------
set role authenticated;
select tests.as_user(tests.id('manager'));
do $$
declare r record;
begin
  select * into r from public.report_mechanics(tests.id('P'), private.today_pk() - 1, private.today_pk()) where user_id = tests.id('mech');
  assert r.jobs_completed = 1 and r.labour_paisa = 5000000 and r.rework_jobs = 0 and r.rework_pct = 0,
    format('TEST-054: %s jobs, labour %s', r.jobs_completed, r.labour_paisa);
  assert r.avg_hours is not null, 'TEST-054: in progress → QC time';
end $$;
select tests.as_user(tests.id('ownerS'));
select tests.throws(format('select count(*) from public.report_mechanics(%L, %L, %L)', tests.id('S'), private.today_pk(), private.today_pk()), 'FEATURE_LOCKED');

-- TEST-059 Revenue: parts 300,000 + labour 120,000 − discount 10,000 = net 410,000 ------------
select tests.as_user(tests.id('ownerS'));
insert into tests.fx values ('custS', public.station_save_customer(tests.id('S'), null, 'Sara', '0300-7654321'));
insert into tests.fx values ('carS', public.station_save_vehicle(tests.id('S'), null, tests.id('custS'), 'LEB-555'));
insert into tests.fx values ('engine', public.station_save_item(tests.id('S'), '{"code":"E1","name":"Engine kit","selling_price_paisa":30000000}'::jsonb));
insert into tests.fx values ('supS', public.station_save_supplier(tests.id('S'), null, 'Supplier S', null));
select public.station_post_purchase(tests.id('S'), tests.id('supS'), null, 'S-1', private.today_pk(),
  jsonb_build_array(jsonb_build_object('item_id', tests.id('engine'), 'qty', 2, 'unit_cost_paisa', 20000000)), 0);
insert into tests.fx values ('jobS', public.station_create_job(tests.id('S'), tests.id('custS'), tests.id('carS'), 1000, 'H'));
select public.job_add_line(tests.id('jobS'), 'part', tests.id('engine'), null, 1, 30000000);
select public.job_add_line(tests.id('jobS'), 'labour', null, 'Fitting', 1, 12000000);
select public.job_record_approval(tests.id('jobS'), true, 'phone', 'Sara');
select public.job_set_stage(tests.id('jobS'), 'in_progress');
reset role;
update public.job_checklist_items set status = 'ok';
set role authenticated;
select tests.as_user(tests.id('ownerS'));
select public.job_set_stage(tests.id('jobS'), 'quality_check');
select public.job_quality_check(tests.id('jobS'), true);
insert into tests.fx values ('invS', public.station_create_invoice(tests.id('jobS')));
do $$
declare r record;
begin
  assert public.invoice_set_discount(tests.id('invS'), 1000000, 'Regular') = 'applied', 'discount applied';
  select * into r from public.report_revenue(tests.id('S'), private.today_pk() - 30, private.today_pk());
  assert r.parts_paisa = 30000000 and r.labour_paisa = 12000000 and r.discount_paisa = 1000000, 'TEST-059: totals';
  assert r.net_paisa = 41000000, 'TEST-059: net 410,000, got ' || r.net_paisa;
  assert (select count(*) from public.report_revenue(tests.id('S'), private.today_pk() + 1, private.today_pk() + 2) where invoices = 0) = 1,
    'TEST-059: date range';
  -- Stock value at cost: 1 left × 200,000.
  assert (select value_paisa from public.report_stock_value(tests.id('S')) where item_id = tests.id('engine')) = 20000000, 'stock value';
  -- Profit reports are Premium.
  perform tests.throws(format('select count(*) from public.report_job_profit(%L, %L, %L)', tests.id('S'), private.today_pk(), private.today_pk()), 'FEATURE_LOCKED');
  assert (select count(*) from public.report_messages(tests.id('S'), private.today_pk() - 1, private.today_pk())) = 10, 'message usage rows';
  assert (select sum(amount_paisa) from public.report_collections(tests.id('S'), private.today_pk(), private.today_pk())) is null, 'nothing collected';
end $$;
-- Premium profit per job: revenue 50,000 labour − 0 parts.
select tests.as_user(tests.id('owner'));
do $$ begin
  assert (select profit_paisa from public.report_job_profit(tests.id('P'), private.today_pk() - 1, private.today_pk()) where job_id = tests.id('job1')) = 5000000,
    'job profit';
end $$;
select tests.as_user(tests.id('cashier'));
select tests.throws(format('select count(*) from public.report_revenue(%L, %L, %L)', tests.id('P'), private.today_pk(), private.today_pk()), 'FORBIDDEN');
select tests.throws(format('select count(*) from public.report_stock_value(%L)', tests.id('P')), 'FORBIDDEN');
select tests.as_user(tests.id('manager'));
select tests.throws(format('select count(*) from public.report_job_profit(%L, %L, %L)', tests.id('P'), private.today_pk(), private.today_pk()), 'FORBIDDEN');
select tests.as_user(tests.id('ownerS'));
select tests.throws(format('select count(*) from public.report_revenue(%L, %L, %L)', tests.id('P'), private.today_pk(), private.today_pk()), 'FORBIDDEN');

-- TEST-060 Dashboard tiles: 5 In progress and 2 Ready ---------------------------------------
select tests.as_user(tests.id('ownerS'));
do $$
declare i int; v uuid; d jsonb;
begin
  for i in 1..7 loop
    v := public.station_create_job(tests.id('S'), tests.id('custS'), tests.id('carS'), 2000 + i * 10, 'H');
    perform public.job_add_line(v, 'labour', null, 'Wash', 1, 50000);
    perform public.job_record_approval(v, true, 'phone', 'Sara');
    perform public.job_set_stage(v, 'in_progress');
  end loop;
end $$;
reset role;
update public.job_checklist_items set status = 'ok';
set role authenticated;
select tests.as_user(tests.id('ownerS'));
do $$
declare v uuid; d jsonb;
begin
  for v in select id from public.job_cards where station_id = tests.id('S') and stage = 'in_progress' order by job_no desc limit 2 loop
    perform public.job_set_stage(v, 'quality_check');
    perform public.job_quality_check(v, true);
  end loop;
  d := public.station_dashboard_totals(tests.id('S'));
  assert (d -> 'jobs_by_stage' ->> 'in_progress')::int = 5, 'TEST-060: 5 in progress, got ' || (d -> 'jobs_by_stage')::text;
  assert (d -> 'jobs_by_stage' ->> 'ready')::int = 3, 'TEST-060: ready (2 + the invoiced job)';
  assert (d ->> 'messages_to_send')::int >= 1, 'TEST-060: WhatsApp messages waiting';
end $$;
reset role;
