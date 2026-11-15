-- Phase 7 migration (customer messages by push and WhatsApp, the station's own WhatsApp
-- connection, "Messages to send" list, staff push notifications) for the Supabase dashboard
-- SQL Editor. Run once, AFTER the Phase 1-6 files.
--
-- Works at once without any outside account: every customer event lands in the staff
-- "Messages to send" list with a WhatsApp link. Automatic sending and push start later, when
--   * the Edge Functions notify-dispatch, whatsapp-connect and whatsapp-webhook are deployed,
--   * their secrets are set (DISPATCH_SECRET, META_APP_ID, META_APP_SECRET,
--     WHATSAPP_VERIFY_TOKEN, FCM_SERVICE_ACCOUNT),
--   * pg_net is enabled and Vault holds "project_url" and "dispatch_secret" (the cron job
--     "notify-dispatch" does nothing until both exist).

-- ===== supabase/migrations/20261119000020_messages.sql =====
-- TASK-060…062 · REQ-055, REQ-056, REQ-061, REQ-062
-- Customer messages by event (push + WhatsApp), per-event switches, the station's own
-- WhatsApp Business connection, a message outbox with one retry, the manual
-- "Messages to send" list, staff push for in-app notifications, and device tokens.
--
-- Flow: a business event (trigger or scheduler) calls private.customer_event(). It writes
--   * a push row (channel 'push') when the station has the customer app and the customer
--     has a phone with the app,
--   * a WhatsApp row (channel 'whatsapp'): 'queued' for automatic sending when the station's
--     own account and the event's template are approved, otherwise 'manual' for staff.
-- The notify-dispatch Edge Function claims queued rows with the service role (svc_* functions),
-- sends them and reports the result. A failed WhatsApp send is retried once after 5 minutes,
-- then moved to the manual list with the reason.

-- Standard English message set (TASK-004 submits these to Meta as templates "csm_<code>").
create table public.message_events (
  code     text primary key,
  label    text not null,
  title    text not null,          -- push title
  template text not null,          -- {placeholders}; Meta parameters follow their order
  inbox    text,                   -- customer-app inbox kind written here (null = written elsewhere)
  sort     integer not null
);
insert into public.message_events (code, label, title, template, inbox, sort) values
  ('booking_confirmed', 'Booking confirmed', 'Booking confirmed',
   'Your booking at {station} is confirmed for {slot} ({plate}).', null, 1),
  ('booking_changed', 'Booking changed', 'Booking moved',
   'Your booking at {station} has moved to {slot} ({plate}).', null, 2),
  ('booking_cancelled', 'Booking cancelled', 'Booking cancelled',
   'Your booking at {station} for {slot} ({plate}) is cancelled.', null, 3),
  ('estimate_ready', 'Estimate ready', 'Estimate ready',
   'The estimate for your vehicle {plate} at {station} is Rs {amount}. Please confirm so we can start the work.', null, 4),
  ('extra_work', 'Extra work needs approval', 'Extra work needs approval',
   'Extra work is needed on your vehicle {plate} at {station}: Rs {amount}. Please confirm before we continue.', null, 5),
  ('vehicle_ready', 'Vehicle ready', 'Vehicle ready',
   'Your vehicle {plate} is ready at {station}.', 'ready', 6),
  ('invoice_issued', 'Invoice issued', 'Invoice issued',
   'Your invoice {invoice_no} from {station}: Rs {amount}. Thank you!', 'invoice', 7),
  ('dues_reminder', 'Dues reminder', 'Payment reminder',
   'Reminder from {station}: Rs {amount} is due on your account.', 'dues', 8),
  ('service_reminder', 'Next-service reminder', 'Service due soon',
   'Your vehicle {plate} is due for service at {station} on {date}.', null, 9),
  ('storage_started', 'Storage charge started', 'Storage charge started',
   'Your vehicle {plate} is waiting at {station}. A storage charge of Rs {amount} per day now applies.', 'storage', 10);

-- REQ-055: the owner switches each event on or off. No row = on.
create table public.message_event_settings (
  station_id uuid not null references public.stations(id) on delete cascade,
  event      text not null references public.message_events(code),
  enabled    boolean not null,
  updated_at timestamptz not null default now(),
  primary key (station_id, event)
);

-- REQ-061: the station's own WhatsApp Business account (Meta Embedded Signup).
create table public.whatsapp_accounts (
  station_id      uuid primary key references public.stations(id) on delete cascade,
  status          text not null default 'not_connected'
                  check (status in ('not_connected', 'pending', 'connected', 'payment_problem', 'disconnected')),
  status_reason   text,
  waba_id         text unique,
  phone_number_id text,
  display_phone   text,
  connected_at    timestamptz,
  updated_at      timestamptz not null default now()
);
create table public.whatsapp_templates (
  station_id uuid not null references public.stations(id) on delete cascade,
  event      text not null references public.message_events(code),
  status     text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  reason     text,
  updated_at timestamptz not null default now(),
  primary key (station_id, event)
);
-- The Meta access token never leaves the server: private schema, not exposed by the API.
create table private.whatsapp_tokens (
  station_id   uuid primary key references public.stations(id) on delete cascade,
  access_token text not null,
  updated_at   timestamptz not null default now()
);

create table public.message_outbox (
  id                  bigint generated always as identity primary key,
  station_id          uuid not null references public.stations(id) on delete cascade,
  customer_id         uuid references public.customers(id) on delete cascade,
  event               text not null references public.message_events(code),
  channel             text not null check (channel in ('whatsapp', 'push')),
  ref_id              uuid,              -- booking, job, invoice or customer
  to_mobile           text,              -- 03XXXXXXXXX, null = no valid number
  title               text not null,
  body                text not null,
  vars                jsonb not null default '{}'::jsonb,
  -- queued → sending → sent | failed (push) ; manual → opened → sent | skipped (staff)
  status              text not null check (status in ('queued', 'sending', 'sent', 'failed', 'manual', 'opened', 'skipped')),
  manual_reason       text,
  attempts            integer not null default 0,
  next_attempt_at     timestamptz not null default now(),
  last_error          text,
  provider_message_id text,
  handled_by          uuid references public.profiles(id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index message_outbox_queue_idx on public.message_outbox(next_attempt_at) where status in ('queued', 'sending');
create index message_outbox_manual_idx on public.message_outbox(station_id, created_at desc) where status in ('manual', 'opened');
create index message_outbox_ref_idx on public.message_outbox(ref_id);

-- Phones that receive push (FCM). One row per device token.
create table public.device_tokens (
  token      text primary key check (length(token) between 20 and 4096),
  user_id    uuid not null references auth.users(id) on delete cascade,
  app        text not null check (app in ('staff', 'customer')),
  platform   text not null default 'android',
  updated_at timestamptz not null default now()
);
create index device_tokens_user_idx on public.device_tokens(user_id);

-- REQ-056: staff push for in-app notifications. null = not yet pushed.
alter table public.notifications add column push_state text check (push_state in ('sending', 'sent', 'failed', 'none'));
alter table public.notifications add column pushed_at timestamptz;
create index notifications_push_idx on public.notifications(created_at) where push_state is null or push_state = 'sending';

alter table public.message_events         enable row level security;
alter table public.message_event_settings enable row level security;
alter table public.whatsapp_accounts      enable row level security;
alter table public.whatsapp_templates     enable row level security;
alter table public.message_outbox         enable row level security;
alter table public.device_tokens          enable row level security;
alter table private.whatsapp_tokens       enable row level security;

create policy message_events_read on public.message_events for select to authenticated using (true);
create policy message_event_settings_read on public.message_event_settings for select to authenticated
  using (private.has_role(station_id, array['owner','manager']::public.member_role[]) or private.has_support_grant(station_id));
create policy whatsapp_accounts_read on public.whatsapp_accounts for select to authenticated
  using (private.has_role(station_id, array['owner','manager']::public.member_role[]) or private.has_support_grant(station_id));
create policy whatsapp_templates_read on public.whatsapp_templates for select to authenticated
  using (private.has_role(station_id, array['owner','manager']::public.member_role[]) or private.has_support_grant(station_id));
create policy message_outbox_read on public.message_outbox for select to authenticated
  using (private.has_role(station_id, array['owner','manager','cashier']::public.member_role[]) or private.has_support_grant(station_id));
create policy device_tokens_read on public.device_tokens for select to authenticated
  using (user_id = auth.uid());
revoke insert, update, delete on public.message_events, public.message_event_settings, public.whatsapp_accounts,
  public.whatsapp_templates, public.message_outbox, public.device_tokens from anon, authenticated;
revoke all on private.whatsapp_tokens from public, anon, authenticated;

create trigger audit_message_event_settings after insert or update on public.message_event_settings
  for each row execute function private.audit_row();
create trigger audit_whatsapp_accounts after insert or update on public.whatsapp_accounts
  for each row execute function private.audit_row();

-- Helpers ---------------------------------------------------------------------------
-- Whole rupees with thousands separators: 950000 paisa → '9,500'.
create or replace function private.rs(p_paisa bigint)
returns text
language sql immutable
as $$ select to_char(round(coalesce(p_paisa, 0) / 100.0), 'FM999,999,999,990'); $$;

create or replace function private.invoice_label(p_no integer)
returns text
language sql immutable
as $$ select 'INV-' || lpad(p_no::text, 4, '0'); $$;

-- Replaces {name} with vars ->> name.
create or replace function private.render_message(p_template text, p_vars jsonb)
returns text
language plpgsql immutable
as $$
declare r record; v text := p_template;
begin
  for r in select key, value from jsonb_each_text(p_vars) loop
    v := replace(v, '{' || r.key || '}', coalesce(r.value, ''));
  end loop;
  return v;
end;
$$;

-- Meta template parameters in the order the placeholders appear.
create or replace function private.message_params(p_event text, p_vars jsonb)
returns text[]
language sql stable security definer set search_path = ''
as $$
  select coalesce(array_agg(p_vars ->> m.name[1] order by m.n), '{}')
  from public.message_events e,
       lateral regexp_matches(e.template, '\{(\w+)\}', 'g') with ordinality as m(name, n)
  where e.code = p_event;
$$;

create or replace function private.event_enabled(p_station uuid, p_event text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((select enabled from public.message_event_settings where station_id = p_station and event = p_event), true);
$$;

-- Why a WhatsApp message of this event cannot go automatically (null = it can).
create or replace function private.wa_block_reason(p_station uuid, p_event text)
returns text
language sql stable security definer set search_path = ''
as $$
  select case
    when not private.has_feature(p_station, 'whatsapp_auto') then null       -- Basic: manual is the normal way
    when a.status is null or a.status in ('not_connected', 'disconnected') then 'WhatsApp not connected'
    when a.status = 'pending' then 'WhatsApp connection pending'
    when a.status = 'payment_problem' then 'Payment problem in Meta — add a payment method'
    when coalesce(t.status, 'pending') <> 'approved' then 'Template not approved yet'
  end
  from (select 1) one
  left join public.whatsapp_accounts a on a.station_id = p_station
  left join public.whatsapp_templates t on t.station_id = p_station and t.event = p_event;
$$;

create or replace function private.wa_auto_ready(p_station uuid, p_event text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select private.has_feature(p_station, 'whatsapp_auto') and private.wa_block_reason(p_station, p_event) is null;
$$;

-- Customer-app phones of a customer (verified phone = the customer's mobile).
create or replace function private.customer_push_tokens(p_customer uuid)
returns text[]
language sql stable security definer set search_path = ''
as $$
  select coalesce(array_agg(d.token), '{}')
  from public.customers c
  join auth.users u on u.phone_confirmed_at is not null and private.normalize_pk_mobile(u.phone) = c.mobile
  join public.device_tokens d on d.user_id = u.id and d.app = 'customer'
  where c.id = p_customer;
$$;

-- REQ-055: one customer event → push (app stations) + WhatsApp (automatic or manual).
-- p_merge: update a not-yet-sent message of the same event and record instead of adding one
-- (extra-work lines added one by one become one message with the running total).
create or replace function private.customer_event(
  p_station uuid, p_customer uuid, p_event text, p_ref uuid, p_vars jsonb, p_merge boolean default false)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  e public.message_events;
  c public.customers;
  v_vars jsonb;
  v_body text;
  v_mobile text;
  v_reason text;
begin
  select * into e from public.message_events where code = p_event;
  select * into c from public.customers where id = p_customer and station_id = p_station;
  if e.code is null or c.id is null or not private.event_enabled(p_station, p_event) then return; end if;
  if exists (select 1 from public.stations where id = p_station and closed_at is not null) then return; end if;

  v_vars := jsonb_build_object('station', (select name from public.stations where id = p_station), 'customer', c.name) || coalesce(p_vars, '{}');
  v_body := private.render_message(e.template, v_vars);
  v_mobile := private.normalize_pk_mobile(c.mobile);

  if p_merge then
    update public.message_outbox set body = v_body, vars = v_vars, updated_at = now()
    where station_id = p_station and event = p_event and ref_id is not distinct from p_ref
      and status in ('queued', 'manual') and created_at > now() - interval '2 hours';
    if found then return; end if;
  end if;

  -- Customer-app inbox for events not already written by the booking/job functions.
  if e.inbox is not null and private.has_feature(p_station, 'booking') then
    perform private.notify_customer(p_station, p_customer, e.inbox, e.title, v_body, p_ref);
  end if;

  -- Push to the customer app (Standard/Premium) when the customer has it on a phone.
  if private.has_feature(p_station, 'booking') and cardinality(private.customer_push_tokens(p_customer)) > 0 then
    insert into public.message_outbox (station_id, customer_id, event, channel, ref_id, to_mobile, title, body, vars, status)
    values (p_station, p_customer, p_event, 'push', p_ref, v_mobile, e.title, v_body, v_vars, 'queued');
  end if;

  -- WhatsApp: automatic from the station's own number, otherwise the manual list (REQ-062).
  if v_mobile is null then
    v_reason := 'No WhatsApp number';
  else
    v_reason := private.wa_block_reason(p_station, p_event);
  end if;
  insert into public.message_outbox (station_id, customer_id, event, channel, ref_id, to_mobile, title, body, vars, status, manual_reason)
  values (p_station, p_customer, p_event, 'whatsapp', p_ref, v_mobile, e.title, v_body, v_vars,
          case when v_mobile is not null and private.wa_auto_ready(p_station, p_event) then 'queued' else 'manual' end,
          v_reason);
end;
$$;

-- Queued automatic WhatsApp messages of a station go to the manual list (disconnect, payment problem).
create or replace function private.wa_fallback(p_station uuid, p_reason text)
returns void
language sql security definer set search_path = ''
as $$
  update public.message_outbox set status = 'manual', manual_reason = p_reason, updated_at = now()
  where station_id = p_station and channel = 'whatsapp' and status = 'queued';
$$;

-- Event triggers -------------------------------------------------------------------
create or replace function private.on_booking_event()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_vars jsonb;
begin
  v_vars := jsonb_build_object('slot', private.slot_label(new.slot_start),
                               'plate', (select plate from public.vehicles where id = new.vehicle_id));
  if tg_op = 'INSERT' then
    if new.status = 'booked' then
      perform private.customer_event(new.station_id, new.customer_id, 'booking_confirmed', new.id, v_vars);
    end if;
  elsif new.status = 'cancelled' and old.status <> 'cancelled' then
    v_vars := v_vars || jsonb_build_object('slot', private.slot_label(old.slot_start));
    perform private.customer_event(new.station_id, new.customer_id, 'booking_cancelled', new.id, v_vars);
  elsif new.status = 'booked' and new.slot_start <> old.slot_start then
    perform private.customer_event(new.station_id, new.customer_id, 'booking_changed', new.id, v_vars);
  end if;
  return null;
end;
$$;
create trigger bookings_customer_messages after insert or update on public.bookings
  for each row execute function private.on_booking_event();

create or replace function private.job_lines_total(p_job uuid, p_statuses public.line_status[])
returns bigint
language sql stable security definer set search_path = ''
as $$
  select coalesce(round(sum(qty * unit_price_paisa)), 0)::bigint from public.job_lines
  where job_id = p_job and status = any(p_statuses) and kind <> 'customer_part';
$$;

create or replace function private.on_job_stage_event()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_plate text := (select plate from public.vehicles where id = new.vehicle_id);
begin
  if new.stage = old.stage then return null; end if;
  if new.stage = 'awaiting_approval' then
    perform private.customer_event(new.station_id, new.customer_id, 'estimate_ready', new.id,
      jsonb_build_object('plate', v_plate, 'job_no', new.job_no,
                         'amount', private.rs(private.job_lines_total(new.id, array['estimate','approved']::public.line_status[]))));
  elsif new.stage = 'ready' then
    perform private.customer_event(new.station_id, new.customer_id, 'vehicle_ready', new.id,
      jsonb_build_object('plate', v_plate, 'job_no', new.job_no));
  end if;
  return null;
end;
$$;
create trigger job_cards_customer_messages after update of stage on public.job_cards
  for each row execute function private.on_job_stage_event();

create or replace function private.on_job_line_event()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare j public.job_cards; v_plate text;
begin
  select * into j from public.job_cards where id = new.job_id;
  v_plate := (select plate from public.vehicles where id = j.vehicle_id);
  if new.status = 'extra_pending' then
    perform private.customer_event(j.station_id, j.customer_id, 'extra_work', j.id,
      jsonb_build_object('plate', v_plate, 'job_no', j.job_no,
                         'amount', private.rs(private.job_lines_total(j.id, array['extra_pending']::public.line_status[]))), true);
  elsif new.kind = 'fee' and new.description like 'Storage charge%' then
    perform private.customer_event(j.station_id, j.customer_id, 'storage_started', j.id,
      jsonb_build_object('plate', v_plate, 'job_no', j.job_no, 'amount', private.rs(new.unit_price_paisa)));
  end if;
  return null;
end;
$$;
create trigger job_lines_customer_messages after insert on public.job_lines
  for each row execute function private.on_job_line_event();

-- The invoice gets its totals right after it is created; the message goes out the first
-- time the total is known.
create or replace function private.on_invoice_event()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.total_paisa > 0 and coalesce(old.total_paisa, 0) = 0
     and not exists (select 1 from public.message_outbox where ref_id = new.id and event = 'invoice_issued') then
    perform private.customer_event(new.station_id, new.customer_id, 'invoice_issued', new.id,
      jsonb_build_object('invoice_no', private.invoice_label(new.invoice_no), 'amount', private.rs(new.total_paisa),
                         'plate', (select plate from public.vehicles where id = new.vehicle_id)));
  end if;
  return null;
end;
$$;
create trigger invoices_customer_messages after update of total_paisa on public.invoices
  for each row execute function private.on_invoice_event();

-- REQ-056: approval request → approvers; decision → requester.
create or replace function private.on_approval_event()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  m record;
  v_label text := initcap(replace(new.type::text, '_', ' '));
begin
  if tg_op = 'INSERT' and new.status = 'pending' then
    for m in
      select sm.user_id from public.station_members sm
      where sm.station_id = new.station_id and sm.active and sm.user_id <> new.requested_by
        and (sm.role = 'owner'
             or (sm.role = 'manager' and private.has_feature(new.station_id, 'approvals_inbox')
                 and coalesce((select manager_can_approve from public.stations where id = new.station_id), false)))
    loop
      perform private.notify(new.station_id, m.user_id, 'approval_request', format('%s approval needed', v_label),
        coalesce(new.reason, '') || case when new.amount_paisa is not null then ' · Rs ' || private.rs(new.amount_paisa) else '' end,
        new.id);
    end loop;
  elsif tg_op = 'UPDATE' and old.status = 'pending' and new.status <> 'pending'
        and new.decided_by is distinct from new.requested_by then
    perform private.notify(new.station_id, new.requested_by, 'approval_decision',
      format('%s request %s', v_label, new.status::text), new.decision_note, new.id);
  end if;
  return null;
end;
$$;
create trigger approval_requests_notify after insert or update on public.approval_requests
  for each row execute function private.on_approval_event();

-- REQ-033 / REQ-056: an item dropping to its minimum stock tells the owner and managers.
create or replace function private.on_stock_event()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  i public.items;
  v_after numeric;
begin
  select * into i from public.items where id = new.item_id;
  if i.min_stock <= 0 or new.qty >= 0 then return null; end if;
  select coalesce(sum(qty), 0) into v_after from public.stock_movements where item_id = new.item_id;
  if v_after >= 0 and v_after <= i.min_stock and v_after - new.qty > i.min_stock then
    perform private.notify(new.station_id, null, 'low_stock', format('Low stock — %s', i.name),
      format('%s left (minimum %s)', trim(to_char(v_after, 'FM999999990.###')), trim(to_char(i.min_stock, 'FM999999990.###'))), i.id);
  end if;
  return null;
end;
$$;
create trigger stock_movements_low_stock after insert on public.stock_movements
  for each row execute function private.on_stock_event();

-- Schedulers -------------------------------------------------------------------------
-- Next-service reminder (REQ-049) on app stations now also goes by push and WhatsApp.
-- Basic keeps the staff "Due for service" list only. Safe to run twice.
create or replace function private.daily_service_reminders(p_today date default null)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare r record; n integer := 0; v_today date := coalesce(p_today, private.today_pk());
begin
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
    perform private.customer_event(r.station_id, r.customer_id, 'service_reminder', r.id,
      jsonb_build_object('plate', r.plate, 'date', to_char(r.next_service_date, 'DD-MM-YYYY')));
    update public.job_cards set reminder_sent_at = now() where id = r.id;
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke execute on function private.daily_service_reminders(date) from public, anon, authenticated;

-- PRD REQ-040: a dues reminder every 7 days while dues remain (first one 7 days after the
-- oldest unpaid invoice). Safe to run twice a day.
create or replace function private.daily_dues_reminders()
returns integer
language plpgsql security definer set search_path = ''
as $$
declare r record; n integer := 0;
begin
  if session_user = 'authenticator'
     and coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '') <> 'service_role' then
    perform private.fail('FORBIDDEN');
  end if;
  for r in
    select b.station_id, b.customer_id, b.dues_paisa
    from public.customer_balances b
    join public.stations s on s.id = b.station_id and s.closed_at is null
    where b.dues_paisa > 0
      and exists (select 1 from public.invoice_balances ib where ib.customer_id = b.customer_id and ib.due_paisa > 0
                  and ib.issued_at < now() - interval '7 days')
      and not exists (select 1 from public.message_outbox o where o.customer_id = b.customer_id and o.event = 'dues_reminder'
                      and o.created_at > now() - interval '7 days' + interval '1 hour')
  loop
    perform private.customer_event(r.station_id, r.customer_id, 'dues_reminder', r.customer_id,
      jsonb_build_object('amount', private.rs(r.dues_paisa)));
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke execute on function private.daily_dues_reminders() from public, anon, authenticated;

-- Staff and owner functions ------------------------------------------------------------
-- REQ-055: event switches. p_events: {"vehicle_ready": false, …}
create or replace function public.station_set_message_events(p_station uuid, p_events jsonb)
returns void
language plpgsql security definer set search_path = ''
as $$
declare r record;
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then perform private.fail('FORBIDDEN'); end if;
  perform private.assert_can_write(p_station);
  for r in select key, value from jsonb_each(coalesce(p_events, '{}')) loop
    if not exists (select 1 from public.message_events where code = r.key) then
      perform private.fail('VALIDATION', 'Unknown message: ' || r.key);
    end if;
    if jsonb_typeof(r.value) <> 'boolean' then perform private.fail('VALIDATION', 'On or off only'); end if;
    insert into public.message_event_settings (station_id, event, enabled)
    values (p_station, r.key, r.value::boolean)
    on conflict (station_id, event) do update set enabled = excluded.enabled, updated_at = now();
  end loop;
end;
$$;

-- REQ-062: staff open WhatsApp from the list, then mark the message sent or skip it.
create or replace function public.message_mark(p_message bigint, p_action text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare m public.message_outbox;
begin
  select * into m from public.message_outbox where id = p_message;
  if m.id is null or not private.has_role(m.station_id, array['owner','manager','cashier']::public.member_role[]) then
    perform private.fail('NOT_FOUND');
  end if;
  perform private.assert_can_write(m.station_id);
  if m.channel <> 'whatsapp' or m.status not in ('manual', 'opened') then
    perform private.fail('VALIDATION', 'This message is already handled');
  end if;
  if p_action not in ('opened', 'sent', 'skipped') then perform private.fail('VALIDATION', 'Unknown action'); end if;
  if p_action in ('opened', 'sent') and m.to_mobile is null then
    perform private.fail('VALIDATION', 'No WhatsApp number — skip this message');
  end if;
  update public.message_outbox set status = p_action, handled_by = auth.uid(), updated_at = now() where id = p_message;
end;
$$;

-- In-app notifications: mark everything the caller can see as read.
create or replace function public.notifications_mark_read(p_station uuid)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare n integer;
begin
  if not private.has_role(p_station, array['owner','manager','cashier','mechanic']::public.member_role[]) then
    perform private.fail('FORBIDDEN');
  end if;
  update public.notifications set read_at = now()
  where station_id = p_station and read_at is null
    and (user_id = auth.uid() or (user_id is null and private.has_role(p_station, array['owner','manager']::public.member_role[])));
  get diagnostics n = row_count;
  return n;
end;
$$;

-- Push tokens: a phone registers its token after login and removes it on sign-out.
create or replace function public.register_device(p_token text, p_app text, p_platform text default 'android')
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is null then perform private.fail('FORBIDDEN'); end if;
  if p_app not in ('staff', 'customer') or length(coalesce(p_token, '')) not between 20 and 4096 then
    perform private.fail('VALIDATION', 'Bad device token');
  end if;
  insert into public.device_tokens (token, user_id, app, platform)
  values (p_token, auth.uid(), p_app, coalesce(nullif(trim(p_platform), ''), 'android'))
  on conflict (token) do update set user_id = excluded.user_id, app = excluded.app, platform = excluded.platform, updated_at = now();
end;
$$;

create or replace function public.unregister_device(p_token text)
returns void
language sql security definer set search_path = ''
as $$ delete from public.device_tokens where token = p_token and user_id = auth.uid(); $$;

-- REQ-061: the owner starts Meta's sign-up (Standard/Premium). The whatsapp-connect Edge
-- Function finishes it with the code Meta returns.
create or replace function public.whatsapp_begin_connect(p_station uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then perform private.fail('FORBIDDEN'); end if;
  perform private.assert_can_write(p_station, 'whatsapp_auto');
  insert into public.whatsapp_accounts (station_id, status, status_reason)
  values (p_station, 'pending', 'Finish the sign-up in the Meta window')
  on conflict (station_id) do update set status = 'pending', status_reason = excluded.status_reason, updated_at = now()
  where public.whatsapp_accounts.status <> 'connected';
end;
$$;

create or replace function public.station_whatsapp_disconnect(p_station uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then perform private.fail('FORBIDDEN'); end if;
  update public.whatsapp_accounts set status = 'disconnected', status_reason = 'Disconnected by the owner',
    connected_at = null, updated_at = now()
  where station_id = p_station;
  delete from private.whatsapp_tokens where station_id = p_station;
  perform private.wa_fallback(p_station, 'WhatsApp not connected');
end;
$$;

-- Service-role functions (Edge Functions only) ----------------------------------------
-- Saves the account after Meta sign-up or a status change from the webhook.
create or replace function public.svc_whatsapp_set_account(
  p_station uuid, p_status text, p_reason text default null, p_waba text default null,
  p_phone_id text default null, p_display text default null, p_token text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if p_status not in ('not_connected', 'pending', 'connected', 'payment_problem', 'disconnected') then
    perform private.fail('VALIDATION', 'Unknown status');
  end if;
  insert into public.whatsapp_accounts (station_id, status, status_reason, waba_id, phone_number_id, display_phone, connected_at)
  values (p_station, p_status, p_reason, p_waba, p_phone_id, p_display, case when p_status = 'connected' then now() end)
  on conflict (station_id) do update set
    status = excluded.status, status_reason = excluded.status_reason,
    waba_id = coalesce(excluded.waba_id, public.whatsapp_accounts.waba_id),
    phone_number_id = coalesce(excluded.phone_number_id, public.whatsapp_accounts.phone_number_id),
    display_phone = coalesce(excluded.display_phone, public.whatsapp_accounts.display_phone),
    connected_at = case when excluded.status = 'connected' then coalesce(public.whatsapp_accounts.connected_at, now()) end,
    updated_at = now();
  if p_token is not null then
    insert into private.whatsapp_tokens (station_id, access_token) values (p_station, p_token)
    on conflict (station_id) do update set access_token = excluded.access_token, updated_at = now();
  end if;
  -- Templates start as pending the first time the account is saved.
  insert into public.whatsapp_templates (station_id, event)
  select p_station, code from public.message_events on conflict do nothing;
  if p_status in ('not_connected', 'disconnected') then
    delete from private.whatsapp_tokens where station_id = p_station;
    perform private.wa_fallback(p_station, 'WhatsApp not connected');
  elsif p_status = 'payment_problem' then
    perform private.wa_fallback(p_station, 'Payment problem in Meta — add a payment method');
  end if;
end;
$$;

-- Template review result from Meta (webhook message_template_status_update).
-- p_name is "csm_<event>". All approved → the pending account becomes Connected.
create or replace function public.svc_whatsapp_template_status(p_waba text, p_name text, p_status text, p_reason text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_station uuid := (select station_id from public.whatsapp_accounts where waba_id = p_waba);
  v_event text := regexp_replace(p_name, '^csm_', '');
  v_status text := case upper(p_status) when 'APPROVED' then 'approved' when 'REJECTED' then 'rejected'
                                        when 'DISABLED' then 'rejected' else 'pending' end;
begin
  if v_station is null or not exists (select 1 from public.message_events where code = v_event) then return; end if;
  insert into public.whatsapp_templates (station_id, event, status, reason)
  values (v_station, v_event, v_status, nullif(trim(p_reason), ''))
  on conflict (station_id, event) do update set status = excluded.status, reason = excluded.reason, updated_at = now();
  if v_status = 'rejected' then
    update public.whatsapp_accounts set status_reason = format('Template "%s" rejected: %s', v_event, coalesce(nullif(trim(p_reason), ''), 'no reason given')),
      updated_at = now() where station_id = v_station;
    update public.message_outbox set status = 'manual', manual_reason = 'Template not approved yet', updated_at = now()
    where station_id = v_station and channel = 'whatsapp' and status = 'queued' and event = v_event;
  elsif not exists (select 1 from public.whatsapp_templates where station_id = v_station and status <> 'approved') then
    update public.whatsapp_accounts set status = 'connected', status_reason = null, connected_at = coalesce(connected_at, now()),
      updated_at = now() where station_id = v_station and status = 'pending';
  end if;
end;
$$;

-- Claims due messages for the dispatcher. Rows stuck in 'sending' for 10 minutes are retried.
create or replace function public.svc_outbox_claim(p_limit integer default 50)
returns table (id bigint, channel text, event text, to_mobile text, title text, body text, params text[],
               ref_id uuid, phone_number_id text, access_token text, tokens text[])
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
begin
  -- A station that lost its connection since the message was queued: send by hand instead.
  update public.message_outbox o set status = 'manual', manual_reason = private.wa_block_reason(o.station_id, o.event), updated_at = now()
  where o.channel = 'whatsapp' and o.status = 'queued' and not private.wa_auto_ready(o.station_id, o.event);

  return query
  with due as (
    select o.id from public.message_outbox o
    where (o.status = 'queued' and o.next_attempt_at <= now())
       or (o.status = 'sending' and o.updated_at < now() - interval '10 minutes')
    order by o.next_attempt_at
    limit greatest(coalesce(p_limit, 50), 1)
    for update skip locked
  ), upd as (
    update public.message_outbox o set status = 'sending', attempts = o.attempts + 1, updated_at = now()
    from due where o.id = due.id
    returning o.*
  )
  select u.id, u.channel, u.event, u.to_mobile, u.title, u.body, private.message_params(u.event, u.vars),
         u.ref_id, a.phone_number_id, t.access_token,
         case when u.channel = 'push' then private.customer_push_tokens(u.customer_id) end
  from upd u
  left join public.whatsapp_accounts a on a.station_id = u.station_id and u.channel = 'whatsapp'
  left join private.whatsapp_tokens t on t.station_id = u.station_id and u.channel = 'whatsapp';
end;
$$;

-- Result of one send. WhatsApp: retry once after 5 minutes, then the manual list with the
-- reason. Meta error 131042 = payment problem on the station's account.
create or replace function public.svc_outbox_report(
  p_message bigint, p_ok boolean, p_error text default null, p_provider_id text default null, p_error_code integer default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare m public.message_outbox;
begin
  select * into m from public.message_outbox where id = p_message for update;
  if m.id is null or m.status <> 'sending' then return; end if;
  if p_ok then
    update public.message_outbox set status = 'sent', provider_message_id = p_provider_id, last_error = null, updated_at = now()
    where id = p_message;
  elsif m.channel = 'push' then
    update public.message_outbox set status = 'failed', last_error = left(p_error, 500), updated_at = now() where id = p_message;
  elsif p_error_code = 131042 then
    perform public.svc_whatsapp_set_account(m.station_id, 'payment_problem', 'Meta could not charge the station''s payment method');
    update public.message_outbox set status = 'manual', manual_reason = 'Payment problem in Meta — add a payment method',
      last_error = left(p_error, 500), updated_at = now() where id = p_message;
  elsif m.attempts < 2 then
    update public.message_outbox set status = 'queued', next_attempt_at = now() + interval '5 minutes',
      last_error = left(p_error, 500), updated_at = now() where id = p_message;
  else
    update public.message_outbox set status = 'manual', manual_reason = 'Automatic send failed: ' || coalesce(left(p_error, 200), 'unknown error'),
      last_error = left(p_error, 500), updated_at = now() where id = p_message;
  end if;
end;
$$;

-- Staff push: notifications not yet pushed, with the phones of everyone who should get them.
create or replace function public.svc_staff_push_claim(p_limit integer default 100)
returns table (id bigint, kind text, title text, body text, ref_id uuid, tokens text[])
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
begin
  return query
  with due as (
    select n.id from public.notifications n
    where (n.push_state is null or (n.push_state = 'sending' and n.pushed_at < now() - interval '10 minutes'))
      and n.created_at > now() - interval '1 day'
    order by n.created_at
    limit greatest(coalesce(p_limit, 100), 1)
    for update skip locked
  ), rcpt as (
    select n.id, coalesce(array_agg(distinct d.token) filter (where d.token is not null), '{}') as tokens
    from due join public.notifications n on n.id = due.id
    left join public.station_members sm on sm.station_id = n.station_id and sm.active
      and (sm.user_id = n.user_id or (n.user_id is null and sm.role in ('owner', 'manager')))
    left join public.device_tokens d on d.user_id = sm.user_id and d.app = 'staff'
    group by n.id
  ), upd as (
    update public.notifications n
    set push_state = case when cardinality(r.tokens) = 0 then 'none' else 'sending' end, pushed_at = now()
    from rcpt r where n.id = r.id
    returning n.id, n.kind, n.title, n.body, n.ref_id, r.tokens
  )
  select u.id, u.kind, u.title, u.body, u.ref_id, u.tokens from upd u where cardinality(u.tokens) > 0;
end;
$$;

create or replace function public.svc_staff_push_report(p_notification bigint, p_ok boolean)
returns void
language sql security definer set search_path = ''
as $$
  update public.notifications set push_state = case when p_ok then 'sent' else 'failed' end, pushed_at = now()
  where id = p_notification and push_state = 'sending';
$$;

-- FCM said the token is no longer valid.
create or replace function public.svc_drop_device_token(p_token text)
returns void
language sql security definer set search_path = ''
as $$ delete from public.device_tokens where token = p_token; $$;

revoke execute on function
  public.svc_whatsapp_set_account(uuid, text, text, text, text, text, text),
  public.svc_whatsapp_template_status(text, text, text, text),
  public.svc_outbox_claim(integer),
  public.svc_outbox_report(bigint, boolean, text, text, integer),
  public.svc_staff_push_claim(integer),
  public.svc_staff_push_report(bigint, boolean),
  public.svc_drop_device_token(text)
from public, anon, authenticated;
grant execute on function
  public.svc_whatsapp_set_account(uuid, text, text, text, text, text, text),
  public.svc_whatsapp_template_status(text, text, text, text),
  public.svc_outbox_claim(integer),
  public.svc_outbox_report(bigint, boolean, text, text, integer),
  public.svc_staff_push_claim(integer),
  public.svc_staff_push_report(bigint, boolean),
  public.svc_drop_device_token(text)
to service_role;

revoke execute on function
  public.station_set_message_events(uuid, jsonb),
  public.message_mark(bigint, text),
  public.notifications_mark_read(uuid),
  public.register_device(text, text, text),
  public.unregister_device(text),
  public.whatsapp_begin_connect(uuid),
  public.station_whatsapp_disconnect(uuid)
from public, anon;
grant execute on function
  public.station_set_message_events(uuid, jsonb),
  public.message_mark(bigint, text),
  public.notifications_mark_read(uuid),
  public.register_device(text, text, text),
  public.unregister_device(text),
  public.whatsapp_begin_connect(uuid),
  public.station_whatsapp_disconnect(uuid)
to authenticated;

-- Dispatcher kick: pg_cron calls the notify-dispatch Edge Function every minute through
-- pg_net. The project URL and the shared secret live in Vault ("project_url",
-- "dispatch_secret"); until both are set this does nothing.
create or replace function private.kick_dispatch()
returns void
language plpgsql security definer set search_path = ''
as $$
declare v_url text; v_secret text;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_net')
     or not exists (select 1 from pg_namespace where nspname = 'vault') then
    return;
  end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = ''project_url''' into v_url;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = ''dispatch_secret''' into v_secret;
  if v_url is null or v_secret is null then return; end if;
  if not exists (select 1 from public.message_outbox where status in ('queued', 'sending'))
     and not exists (select 1 from public.notifications where push_state is null and created_at > now() - interval '1 day') then
    return;
  end if;
  execute 'select net.http_post(url := $1, headers := $2, body := ''{}''::jsonb)'
    using rtrim(v_url, '/') || '/functions/v1/notify-dispatch',
          jsonb_build_object('Content-Type', 'application/json', 'x-dispatch-secret', v_secret);
end;
$$;
revoke execute on function private.kick_dispatch() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('notify-dispatch', '* * * * *', 'select private.kick_dispatch()');
    perform cron.schedule('dues-reminders', '5 4 * * *', 'select private.daily_dues_reminders()');
  end if;
end $$;
