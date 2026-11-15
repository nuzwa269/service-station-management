-- TASK-058, TASK-059, TASK-028 · REQ-020, REQ-022, REQ-048, REQ-049
-- Customer job tracking with estimate / extra-work approval in the app, invoices and
-- vehicle history, next-service reminders (customer inbox on Standard/Premium; a staff
-- "Due for service" list on every plan).

alter table public.job_cards
  add column next_service_date date,
  add column next_service_km   integer check (next_service_km is null or next_service_km > 0),
  add column reminder_sent_at  timestamptz;
create index job_cards_next_service_idx on public.job_cards(station_id, next_service_date) where next_service_date is not null;

-- Shared approval and cancel logic (staff recording, or the customer in the app) ----------
create or replace function private.cancel_job(p_job uuid, p_reason text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  j public.job_cards;
  v_fee bigint;
  v_work_started boolean;
begin
  select * into j from public.job_cards where id = p_job;
  if j.stage in ('delivered', 'cancelled') then perform private.fail('VALIDATION', 'This job card is closed'); end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then perform private.fail('VALIDATION', 'A reason is required'); end if;
  v_work_started := j.stage in ('in_progress', 'quality_check', 'ready');
  update public.job_lines set status = 'removed'
   where job_id = p_job and status in ('estimate', 'extra_pending')
      or (job_id = p_job and not v_work_started and status = 'approved');
  select inspection_fee_paisa into v_fee from public.stations where id = j.station_id;
  if v_fee > 0 then
    insert into public.job_lines (station_id, job_id, kind, description, qty, unit_price_paisa, status)
    values (j.station_id, p_job, 'fee', 'Inspection fee', 1, v_fee, 'approved');
  end if;
  update public.job_cards set stage = 'cancelled', cancel_reason = trim(p_reason), updated_at = now() where id = p_job;
  perform private.sync_job_stock(p_job);
  perform private.log_job(j.station_id, p_job, 'stage', j.stage::text, 'cancelled', p_reason);
end;
$$;

create or replace function private.decide_job(
  p_job uuid, p_approve boolean, p_via public.approval_via, p_by_name text, p_extra boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
declare j public.job_cards;
begin
  select * into j from public.job_cards where id = p_job;
  if not p_extra then
    if j.stage not in ('intake', 'awaiting_approval') then perform private.fail('VALIDATION', 'Estimate already decided'); end if;
    if not exists (select 1 from public.job_lines where job_id = p_job and status = 'estimate') then
      perform private.fail('VALIDATION', 'Add at least one line to the estimate');
    end if;
    if not p_approve then
      perform private.cancel_job(p_job, 'Estimate rejected by ' || trim(p_by_name));
      return;
    end if;
    update public.job_lines set status = 'approved' where job_id = p_job and status = 'estimate';
    update public.job_cards set stage = 'approved', approved_via = p_via, approved_by_name = trim(p_by_name),
      approved_at = now(), updated_at = now() where id = p_job;
    perform private.log_job(j.station_id, p_job, 'stage', j.stage::text, 'approved',
      case when p_via = 'app' then 'Approved by customer in app'
           else format('Approved by %s (%s)', trim(p_by_name), replace(p_via::text, '_', ' ')) end);
    perform private.sync_job_stock(p_job);
  else
    if not exists (select 1 from public.job_lines where job_id = p_job and status = 'extra_pending') then
      perform private.fail('VALIDATION', 'No extra work is waiting');
    end if;
    update public.job_lines set status = case when p_approve then 'approved'::public.line_status else 'rejected'::public.line_status end
    where job_id = p_job and status = 'extra_pending';
    perform private.sync_job_stock(p_job);
    perform private.log_job(j.station_id, p_job, 'approval', null, case when p_approve then 'extra approved' else 'extra rejected' end,
      format('By %s (%s)', trim(p_by_name), replace(p_via::text, '_', ' ')));
  end if;
end;
$$;
grant execute on all functions in schema private to authenticated, service_role;

create or replace function public.job_record_approval(
  p_job uuid, p_approve boolean, p_via public.approval_via, p_by_name text, p_extra boolean default false)
returns void
language plpgsql security definer set search_path = ''
as $$
declare j public.job_cards := private.job_for(p_job, array['owner','manager','cashier']::public.member_role[]);
begin
  perform private.assert_can_write(j.station_id);
  if length(trim(coalesce(p_by_name, ''))) < 2 then perform private.fail('VALIDATION', 'Enter who approved'); end if;
  if p_via = 'app' then perform private.fail('VALIDATION', 'App approval comes from the customer''s app'); end if;
  perform private.decide_job(p_job, p_approve, p_via, p_by_name, coalesce(p_extra, false));
end;
$$;

create or replace function public.job_cancel(p_job uuid, p_reason text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare j public.job_cards := private.job_for(p_job, array['owner','manager','cashier']::public.member_role[]);
begin
  if not private.has_role(j.station_id, array['owner','manager']::public.member_role[])
     and not (j.stage in ('intake', 'awaiting_approval')) then
    perform private.fail('FORBIDDEN', 'Only the owner or manager can cancel a job in progress');
  end if;
  perform private.assert_can_write(j.station_id);
  perform private.cancel_job(p_job, p_reason);
end;
$$;

-- REQ-020: sending the estimate now also tells the customer (inbox; push/WhatsApp in Phase 7).
create or replace function public.job_send_estimate(p_job uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare j public.job_cards := private.job_for(p_job, array['owner','manager','cashier']::public.member_role[]);
begin
  perform private.assert_can_write(j.station_id);
  if j.stage <> 'intake' then perform private.fail('VALIDATION', 'The estimate was already sent'); end if;
  if not exists (select 1 from public.job_lines where job_id = p_job and status = 'estimate') then
    perform private.fail('VALIDATION', 'Add at least one line to the estimate');
  end if;
  update public.job_cards set stage = 'awaiting_approval', updated_at = now() where id = p_job;
  perform private.log_job(j.station_id, p_job, 'stage', 'intake', 'awaiting_approval', 'Estimate sent');
  if private.has_feature(j.station_id, 'booking') then
    perform private.notify_customer(j.station_id, j.customer_id, 'estimate', format('Estimate for job %s', j.job_no),
      'Please review and approve', p_job);
  end if;
end;
$$;

-- REQ-022: a new line after approval is extra work — tell the customer once per request.
create or replace function private.notify_extra_work()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare j public.job_cards;
begin
  if new.status = 'extra_pending' and not exists (
       select 1 from public.job_lines where job_id = new.job_id and status = 'extra_pending' and id <> new.id) then
    select * into j from public.job_cards where id = new.job_id;
    if private.has_feature(j.station_id, 'booking') then
      perform private.notify_customer(j.station_id, j.customer_id, 'extra_work', format('Extra work on job %s', j.job_no),
        'New work needs your approval', j.id);
    end if;
  end if;
  return new;
end;
$$;
create trigger job_lines_notify_extra after insert on public.job_lines
  for each row execute function private.notify_extra_work();

-- Customer job tracking (SCR-043) --------------------------------------------------------
create or replace function private.my_job(p_job uuid)
returns public.job_cards
language plpgsql stable security definer set search_path = ''
as $$
declare j public.job_cards;
begin
  select * into j from public.job_cards where id = p_job;
  if j.id is null or j.customer_id is distinct from private.my_customer(j.station_id) then
    perform private.fail('NOT_FOUND', 'Job card not found');
  end if;
  return j;
end;
$$;
grant execute on function private.my_job(uuid) to authenticated, service_role;

-- Stage timeline, estimate and extra-work lines with prices, approval and invoice.
create or replace function public.customer_job(p_job uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare j public.job_cards := private.my_job(p_job);
begin
  return jsonb_build_object(
    'id', j.id, 'job_no', j.job_no, 'stage', j.stage, 'created_at', j.created_at,
    'odometer_km', j.odometer_km, 'complaints', j.complaints, 'expected_delivery', j.expected_delivery,
    'approved_via', j.approved_via, 'approved_by_name', j.approved_by_name, 'approved_at', j.approved_at,
    'cancel_reason', j.cancel_reason, 'next_service_date', j.next_service_date, 'next_service_km', j.next_service_km,
    'station_name', (select name from public.stations where id = j.station_id),
    'plate', (select plate from public.vehicles where id = j.vehicle_id),
    'timeline', coalesce((select jsonb_agg(jsonb_build_object('stage', h.new_value, 'at', h.created_at, 'note', h.note) order by h.created_at, h.id)
                 from public.job_history h where h.job_id = j.id and h.field = 'stage' and not h.conflict), '[]'::jsonb),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'kind', l.kind, 'description', l.description, 'qty', l.qty,
                   'unit_price_paisa', l.unit_price_paisa, 'total_paisa', round(l.qty * l.unit_price_paisa)::bigint, 'status', l.status)
                   order by l.created_at, l.id)
                 from public.job_lines l where l.job_id = j.id and l.status <> 'removed'), '[]'::jsonb),
    'invoice', (select jsonb_build_object('id', b.invoice_id, 'invoice_no', b.invoice_no, 'total_paisa', b.total_paisa,
                  'paid_paisa', b.paid_paisa, 'due_paisa', b.due_paisa, 'status', b.status)
                from public.invoice_balances b where b.job_id = j.id)
  );
end;
$$;

-- REQ-020 / REQ-022: approve or reject in the app. p_extra = false: the estimate.
create or replace function public.customer_decide(p_job uuid, p_approve boolean, p_extra boolean default false)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  j public.job_cards := private.my_job(p_job);
  v_name text := (select name from public.customers where id = j.customer_id);
begin
  perform private.assert_can_write(j.station_id, 'booking');
  if not coalesce(p_extra, false) and j.stage <> 'awaiting_approval' then
    perform private.fail('VALIDATION', 'There is no estimate waiting for you');
  end if;
  perform private.decide_job(p_job, coalesce(p_approve, false), 'app', v_name, coalesce(p_extra, false));
  perform private.notify(j.station_id, null, 'customer_decision',
    format('Job %s: %s %s', j.job_no, case when p_extra then 'extra work' else 'estimate' end,
           case when p_approve then 'approved' else 'rejected' end),
    v_name || ' (app)', p_job);
end;
$$;

-- Invoice detail for the customer (SCR-044); the PDF is built in the app from this.
create or replace function public.customer_invoice(p_invoice uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare i public.invoices; j public.job_cards;
begin
  select * into i from public.invoices where id = p_invoice;
  if i.id is null then perform private.fail('NOT_FOUND', 'Invoice not found'); end if;
  j := private.my_job(i.job_id);
  return jsonb_build_object(
    'id', i.id, 'invoice_no', i.invoice_no, 'issued_at', i.issued_at, 'job_no', j.job_no,
    'parts_paisa', i.parts_paisa, 'labour_paisa', i.labour_paisa,
    'discount_paisa', case when i.discount_state = 'applied' then i.discount_paisa else 0 end,
    'tax_paisa', i.tax_parts_paisa + i.tax_services_paisa, 'total_paisa', i.total_paisa,
    'station', (select jsonb_build_object('name', s.name, 'city', s.city, 'address', s.address, 'phone', s.phone, 'ntn', s.ntn, 'strn', s.strn)
                from public.stations s where s.id = i.station_id),
    'customer', (select name from public.customers where id = i.customer_id),
    'plate', (select plate from public.vehicles where id = i.vehicle_id),
    'balance', (select jsonb_build_object('paid_paisa', b.paid_paisa, 'due_paisa', b.due_paisa, 'status', b.status)
                from public.invoice_balances b where b.invoice_id = i.id),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('description', l.description, 'qty', l.qty,
                   'unit_price_paisa', l.unit_price_paisa, 'total_paisa', l.total_paisa, 'warranty_days', l.warranty_days) order by l.id)
                 from public.invoice_lines l where l.invoice_id = i.id), '[]'::jsonb)
  );
end;
$$;

-- REQ-048: vehicle history (staff and customer) ------------------------------------------
-- Jobs newest first with odometer and invoice total, warranty items still valid, and ownership.
create or replace function private.vehicle_timeline(p_vehicle uuid, p_customer uuid default null)
returns table (at timestamptz, kind text, title text, odometer integer, total_paisa bigint, ref_id uuid)
language sql stable security definer set search_path = ''
as $$
  select t.at, t.kind, t.title, t.odometer, t.total_paisa, t.ref_id from (
    select j.created_at as at, 'job' as kind,
           format('Job %s — %s', j.job_no, replace(j.stage::text, '_', ' '))
             || coalesce(' · ' || (select string_agg(l.description, ', ' order by l.created_at)
                                   from public.job_lines l where l.job_id = j.id and l.status = 'approved'), '')
             || coalesce(' · warranty valid: ' || (select string_agg(il.description, ', ')
                                   from public.invoices i2 join public.invoice_lines il on il.invoice_id = i2.id
                                   where i2.job_id = j.id and il.warranty_days > 0
                                     and coalesce(j.delivered_at, i2.issued_at) + make_interval(days => il.warranty_days) > now()), '') as title,
           j.odometer_km as odometer, i.total_paisa, j.id as ref_id, 0::bigint as seq
    from public.job_cards j left join public.invoices i on i.job_id = j.id
    where j.vehicle_id = p_vehicle and (p_customer is null or j.customer_id = p_customer)
    union all
    select h.changed_at, 'owner',
           case when h.from_customer_id is null then 'Registered to ' || c.name else 'Owner changed to ' || c.name end,
           null::integer, null::bigint, h.to_customer_id, h.id
    from public.vehicle_owner_history h join public.customers c on c.id = h.to_customer_id
    where h.vehicle_id = p_vehicle and p_customer is null
  ) t order by t.at desc, t.seq desc;
$$;
grant execute on function private.vehicle_timeline(uuid, uuid) to authenticated, service_role;

create or replace function public.station_vehicle_history(p_vehicle uuid)
returns table (at timestamptz, kind text, title text, odometer integer, total_paisa bigint, ref_id uuid)
language plpgsql stable security definer set search_path = ''
as $$
declare v_station uuid;
begin
  select station_id into v_station from public.vehicles where id = p_vehicle;
  if v_station is null or not (private.has_role(v_station, array['owner','manager','cashier']::public.member_role[])
                               or private.has_support_grant(v_station)) then
    return;
  end if;
  return query select * from private.vehicle_timeline(p_vehicle);
end;
$$;

create or replace function public.customer_vehicle_history(p_vehicle uuid)
returns table (at timestamptz, kind text, title text, odometer integer, total_paisa bigint, ref_id uuid)
language plpgsql stable security definer set search_path = ''
as $$
declare v public.vehicles; v_c uuid;
begin
  select * into v from public.vehicles where id = p_vehicle;
  v_c := private.my_customer(v.station_id);
  if v.id is null or v_c is null or v.customer_id <> v_c then perform private.fail('NOT_FOUND', 'Vehicle not found'); end if;
  return query select * from private.vehicle_timeline(p_vehicle, v_c) t where t.kind = 'job';
end;
$$;

-- REQ-049: next service -----------------------------------------------------------------------
create or replace function public.job_set_next_service(p_job uuid, p_date date, p_km integer default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare j public.job_cards := private.job_for(p_job, array['owner','manager','cashier']::public.member_role[]);
begin
  perform private.assert_can_write(j.station_id);
  if p_date is null and p_km is null then perform private.fail('VALIDATION', 'Enter a date or an odometer reading'); end if;
  if p_date is not null and p_date <= private.today_pk() then perform private.fail('VALIDATION', 'Next service date must be in the future'); end if;
  if p_km is not null and p_km <= j.odometer_km then
    perform private.fail('VALIDATION', format('Next service km must be above %s', to_char(j.odometer_km, 'FM999,999,999')));
  end if;
  update public.job_cards set next_service_date = p_date, next_service_km = p_km, reminder_sent_at = null, updated_at = now()
  where id = p_job;
  perform private.log_job(j.station_id, p_job, 'next_service', null,
    concat_ws(' / ', to_char(p_date, 'DD-MM-YYYY'), to_char(p_km, 'FM999,999,999') || ' km'));
end;
$$;

-- Latest next-service per vehicle due within p_days (staff call list; every plan).
create or replace function public.station_due_for_service(p_station uuid, p_days integer default 7)
returns table (job_id uuid, vehicle_id uuid, plate text, customer_id uuid, customer_name text, mobile text,
               next_service_date date, next_service_km integer, last_odometer integer, reminder_sent boolean)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.has_role(p_station, array['owner','manager','cashier']::public.member_role[]) then perform private.fail('FORBIDDEN'); end if;
  return query
  select j.id, v.id, v.plate, c.id, c.name, c.mobile, j.next_service_date, j.next_service_km, j.odometer_km, j.reminder_sent_at is not null
  from public.job_cards j
  join public.vehicles v on v.id = j.vehicle_id
  join public.customers c on c.id = v.customer_id
  where j.station_id = p_station and j.next_service_date is not null
    and j.next_service_date <= private.today_pk() + greatest(coalesce(p_days, 7), 0)
    and not exists (select 1 from public.job_cards n where n.vehicle_id = j.vehicle_id and n.created_at > j.created_at and n.stage <> 'cancelled')
  order by j.next_service_date, v.plate;
end;
$$;

-- Daily (09:00 PKT): reminder 3 days before the next-service date to customers of stations
-- with the app (Standard/Premium). Basic stations use the staff list above. Safe to run twice.
create or replace function private.daily_service_reminders(p_today date default null)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare r record; n integer := 0; v_today date := coalesce(p_today, private.today_pk());
begin
  -- Scheduler / service role only: never through the API as a logged-in user.
  if session_user = 'authenticator'
     and coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '') <> 'service_role' then
    perform private.fail('FORBIDDEN');
  end if;
  for r in
    select j.id, j.station_id, j.next_service_date, v.customer_id, v.plate
    from public.job_cards j join public.vehicles v on v.id = j.vehicle_id
    where j.next_service_date = v_today + 3 and j.reminder_sent_at is null
      and private.has_feature(j.station_id, 'booking')
      and not exists (select 1 from public.job_cards x where x.vehicle_id = j.vehicle_id and x.created_at > j.created_at and x.stage <> 'cancelled')
    for update of j skip locked
  loop
    perform private.notify_customer(r.station_id, r.customer_id, 'reminder', 'Service due soon',
      format('%s is due for service on %s', r.plate, to_char(r.next_service_date, 'DD-MM-YYYY')), r.id);
    update public.job_cards set reminder_sent_at = now() where id = r.id;
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke execute on function private.daily_service_reminders(date) from public, anon, authenticated;

revoke execute on function
  public.customer_job(uuid),
  public.customer_decide(uuid, boolean, boolean),
  public.customer_invoice(uuid),
  public.customer_vehicle_history(uuid),
  public.job_set_next_service(uuid, date, integer),
  public.station_due_for_service(uuid, integer)
from public, anon;
grant execute on function
  public.customer_job(uuid),
  public.customer_decide(uuid, boolean, boolean),
  public.customer_invoice(uuid),
  public.customer_vehicle_history(uuid),
  public.job_set_next_service(uuid, date, integer),
  public.station_due_for_service(uuid, integer)
to authenticated;

-- Next-service reminders daily at 09:00 PKT (04:00 UTC) when pg_cron is enabled.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('service-reminders', '0 4 * * *', 'select private.daily_service_reminders()');
  end if;
end $$;