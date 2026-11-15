-- TASK-053…057 · REQ-014…017
-- Booking settings (bays, slot length, hours, off-days), slots with capacity, staff and
-- customer bookings with capacity locking, reschedule/cancel rules, no-shows and blocks.
-- Times: hours and days are Pakistan local time (Asia/Karachi); slot_start is a timestamptz.

create type public.booking_status as enum ('booked', 'arrived', 'no_show', 'cancelled');

create table public.booking_settings (
  station_id     uuid primary key references public.stations(id) on delete cascade,
  bays           integer not null default 2 check (bays between 1 and 50),
  slot_minutes   integer not null default 60 check (slot_minutes in (30, 60, 90, 120)),
  no_show_limit  integer not null default 3 check (no_show_limit between 1 and 20),
  days_ahead     integer not null default 30 check (days_ahead between 1 and 90),
  updated_at     timestamptz not null default now()
);

-- One row per open weekday (ISO: 1 = Monday … 7 = Sunday). No row = closed that day.
create table public.booking_hours (
  station_id uuid not null references public.stations(id) on delete cascade,
  weekday    integer not null check (weekday between 1 and 7),
  opens      time not null,
  closes     time not null check (closes > opens),
  primary key (station_id, weekday)
);

create table public.booking_off_days (
  station_id uuid not null references public.stations(id) on delete cascade,
  day        date not null,
  note       text,
  primary key (station_id, day)
);

-- Services customers may pick when booking (REQ-014 "bookable services").
alter table public.services add column bookable boolean not null default false;

create table public.bookings (
  id            uuid primary key default gen_random_uuid(),
  station_id    uuid not null references public.stations(id) on delete cascade,
  customer_id   uuid not null references public.customers(id),
  vehicle_id    uuid not null references public.vehicles(id),
  service_id    uuid references public.services(id),
  slot_start    timestamptz not null,
  slot_end      timestamptz not null,
  status        public.booking_status not null default 'booked',
  source        text not null check (source in ('app', 'staff')),
  note          text,
  overbooked    boolean not null default false,
  job_id        uuid references public.job_cards(id),
  cancel_reason text,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index bookings_slot_idx on public.bookings(station_id, slot_start) where status in ('booked', 'arrived');
create index bookings_customer_idx on public.bookings(customer_id, slot_start desc);

-- REQ-017: no-show count per customer per station; blocked at the station's limit.
create table public.no_show_counters (
  station_id  uuid not null references public.stations(id) on delete cascade,
  customer_id uuid primary key references public.customers(id) on delete cascade,
  no_shows    integer not null default 0,
  blocked     boolean not null default false,
  updated_at  timestamptz not null default now()
);

-- Messages for customers (app inbox now; push/WhatsApp delivery reads this in Phase 7).
create table public.customer_notifications (
  id          bigint generated always as identity primary key,
  station_id  uuid not null references public.stations(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  kind        text not null,      -- booking | estimate | extra_work | reminder
  title       text not null,
  body        text,
  ref_id      uuid,
  created_at  timestamptz not null default now(),
  read_at     timestamptz
);
create index customer_notifications_idx on public.customer_notifications(customer_id, created_at desc);

alter table public.booking_settings       enable row level security;
alter table public.booking_hours          enable row level security;
alter table public.booking_off_days       enable row level security;
alter table public.bookings               enable row level security;
alter table public.no_show_counters       enable row level security;
alter table public.customer_notifications enable row level security;

-- Staff read through RLS; customers read only through customer_* functions below.
create policy booking_settings_read on public.booking_settings for select to authenticated
  using (private.can_read_station(station_id));
create policy booking_hours_read on public.booking_hours for select to authenticated
  using (private.can_read_station(station_id));
create policy booking_off_days_read on public.booking_off_days for select to authenticated
  using (private.can_read_station(station_id));
create policy bookings_read on public.bookings for select to authenticated
  using (private.has_role(station_id, array['owner','manager','cashier']::public.member_role[]) or private.has_support_grant(station_id));
create policy no_show_counters_read on public.no_show_counters for select to authenticated
  using (private.has_role(station_id, array['owner','manager','cashier']::public.member_role[]) or private.has_support_grant(station_id));
create policy customer_notifications_read on public.customer_notifications for select to authenticated
  using (private.has_role(station_id, array['owner','manager','cashier']::public.member_role[]) or private.has_support_grant(station_id));
revoke insert, update, delete on public.booking_settings, public.booking_hours, public.booking_off_days,
  public.bookings, public.no_show_counters, public.customer_notifications from anon, authenticated;

create trigger audit_bookings after insert or update on public.bookings
  for each row execute function private.audit_row();
create trigger audit_booking_settings after insert or update on public.booking_settings
  for each row execute function private.audit_row();

-- Helpers ---------------------------------------------------------------------------
-- Verified phone of the logged-in user, as 03XXXXXXXXX.
create or replace function private.my_mobile()
returns text
language sql stable security definer set search_path = ''
as $$
  select private.normalize_pk_mobile(u.phone) from auth.users u
  where u.id = auth.uid() and u.phone_confirmed_at is not null;
$$;

-- REQ-047: the caller's customer record at a station, only where the station offers the app.
create or replace function private.my_customer(p_station uuid)
returns uuid
language sql stable security definer set search_path = ''
as $$
  select c.id from public.customers c
  where c.station_id = p_station and c.mobile = private.my_mobile()
    and private.has_feature(p_station, 'booking');
$$;

-- All slots of one local day with capacity and booked count (REQ-014).
create or replace function private.day_slots(p_station uuid, p_day date)
returns table (slot_start timestamptz, slot_end timestamptz, capacity integer, booked integer)
language sql stable security definer set search_path = ''
as $$
  with s as (select * from public.booking_settings where station_id = p_station),
  h as (select * from public.booking_hours where station_id = p_station and weekday = extract(isodow from p_day)::int),
  g as (
    select (gs at time zone 'Asia/Karachi') as st, s.slot_minutes, s.bays
    from s cross join h
    cross join lateral generate_series(p_day + h.opens, p_day + h.closes - make_interval(mins => s.slot_minutes),
                                       make_interval(mins => s.slot_minutes)) gs
    where not exists (select 1 from public.booking_off_days o where o.station_id = p_station and o.day = p_day)
  )
  select g.st, g.st + make_interval(mins => g.slot_minutes), g.bays,
         (select count(*)::int from public.bookings b
          where b.station_id = p_station and b.slot_start = g.st and b.status in ('booked', 'arrived'))
  from g order by g.st;
$$;

-- Validates a slot and locks the station's booking settings so two confirmations of the
-- same slot run one after the other (REQ-015). Returns the slot end.
create or replace function private.lock_slot(
  p_station uuid, p_slot timestamptz, p_exclude uuid, p_allow_full boolean, p_customer_rules boolean)
returns timestamptz
language plpgsql security definer set search_path = ''
as $$
declare
  st public.booking_settings;
  v_day date := (p_slot at time zone 'Asia/Karachi')::date;
  v_end timestamptz;
  v_taken integer;
begin
  select * into st from public.booking_settings where station_id = p_station for update;
  if st.station_id is null then perform private.fail('VALIDATION', 'Booking is not set up at this station'); end if;
  select d.slot_end into v_end from private.day_slots(p_station, v_day) d where d.slot_start = p_slot;
  if v_end is null then perform private.fail('VALIDATION', 'This time is not a bookable slot'); end if;
  if p_customer_rules then
    if p_slot <= now() then perform private.fail('VALIDATION', 'Pick a time in the future'); end if;
    if v_day > private.today_pk() + st.days_ahead then
      perform private.fail('VALIDATION', format('Bookings open up to %s days ahead', st.days_ahead));
    end if;
  end if;
  select count(*) into v_taken from public.bookings
  where station_id = p_station and slot_start = p_slot and status in ('booked', 'arrived') and id is distinct from p_exclude;
  if v_taken >= st.bays and not p_allow_full then
    if p_customer_rules then perform private.fail('SLOT_TAKEN', 'Slot just filled, pick another'); end if;
    perform private.fail('SLOT_FULL', 'This slot is full — book anyway?');
  end if;
  return v_end;
end;
$$;

create or replace function private.notify_customer(p_station uuid, p_customer uuid, p_kind text, p_title text, p_body text, p_ref uuid)
returns void
language sql security definer set search_path = ''
as $$
  insert into public.customer_notifications (station_id, customer_id, kind, title, body, ref_id)
  values (p_station, p_customer, p_kind, p_title, p_body, p_ref);
$$;

create or replace function private.slot_label(p_slot timestamptz)
returns text
language sql stable
as $$ select to_char(p_slot at time zone 'Asia/Karachi', 'DD-MM-YYYY HH24:MI'); $$;

grant execute on all functions in schema private to authenticated, service_role;

-- REQ-014: booking settings (owner) ------------------------------------------------------
-- p_hours: [{"weekday":1,"opens":"09:00","closes":"18:00"}, …]. Returns the number of future
-- bookings that no longer fit (they are kept and listed for staff, never cancelled).
create or replace function public.station_save_booking_settings(
  p_station uuid, p_bays integer, p_slot_minutes integer, p_no_show_limit integer,
  p_hours jsonb, p_off_days date[] default '{}', p_days_ahead integer default 30)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare h jsonb;
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then perform private.fail('FORBIDDEN'); end if;
  perform private.assert_can_write(p_station, 'booking');
  if p_bays is null or p_bays not between 1 and 50 then perform private.fail('VALIDATION', 'Bays must be 1 to 50'); end if;
  if p_slot_minutes is null or p_slot_minutes not in (30, 60, 90, 120) then
    perform private.fail('VALIDATION', 'Slot length must be 30, 60, 90 or 120 minutes');
  end if;
  if coalesce(p_no_show_limit, 0) not between 1 and 20 then perform private.fail('VALIDATION', 'No-show limit must be 1 to 20'); end if;
  if coalesce(p_days_ahead, 0) not between 1 and 90 then perform private.fail('VALIDATION', 'Days ahead must be 1 to 90'); end if;

  insert into public.booking_settings (station_id, bays, slot_minutes, no_show_limit, days_ahead)
  values (p_station, p_bays, p_slot_minutes, p_no_show_limit, p_days_ahead)
  on conflict (station_id) do update set bays = excluded.bays, slot_minutes = excluded.slot_minutes,
    no_show_limit = excluded.no_show_limit, days_ahead = excluded.days_ahead, updated_at = now();

  delete from public.booking_hours where station_id = p_station;
  for h in select * from jsonb_array_elements(coalesce(p_hours, '[]'::jsonb)) loop
    if (h->>'weekday')::int not between 1 and 7 or (h->>'closes')::time <= (h->>'opens')::time then
      perform private.fail('VALIDATION', 'Closing time must be after opening time');
    end if;
    insert into public.booking_hours (station_id, weekday, opens, closes)
    values (p_station, (h->>'weekday')::int, (h->>'opens')::time, (h->>'closes')::time)
    on conflict (station_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
  end loop;

  delete from public.booking_off_days where station_id = p_station and day >= private.today_pk();
  insert into public.booking_off_days (station_id, day)
  select p_station, d from unnest(coalesce(p_off_days, '{}')) d where d >= private.today_pk()
  on conflict do nothing;

  return (select count(*)::int from public.station_booking_conflicts(p_station));
end;
$$;

-- Future bookings that no longer match a slot, or exceed the bays.
create or replace function public.station_booking_conflicts(p_station uuid)
returns table (booking_id uuid, slot_start timestamptz, reason text)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.has_role(p_station, array['owner','manager','cashier']::public.member_role[]) then perform private.fail('FORBIDDEN'); end if;
  return query
  select b.id, b.slot_start,
         case when d.slot_start is null then 'Outside working hours or slot length' else 'More bookings than bays' end
  from public.bookings b
  left join lateral private.day_slots(p_station, (b.slot_start at time zone 'Asia/Karachi')::date) d on d.slot_start = b.slot_start
  where b.station_id = p_station and b.status = 'booked' and b.slot_start > now()
    and (d.slot_start is null or d.booked > d.capacity)
  order by b.slot_start;
end;
$$;

create or replace function public.station_set_service_bookable(p_service uuid, p_bookable boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
declare v_station uuid;
begin
  select station_id into v_station from public.services where id = p_service;
  if v_station is null or not private.has_role(v_station, array['owner','manager']::public.member_role[]) then
    perform private.fail('NOT_FOUND');
  end if;
  perform private.assert_can_write(v_station, 'booking');
  update public.services set bookable = coalesce(p_bookable, false) where id = p_service;
end;
$$;

-- Free slots of a day: staff of the station, or a linked customer (REQ-014, REQ-015).
create or replace function public.booking_slots(p_station uuid, p_day date)
returns table (slot_start timestamptz, slot_end timestamptz, capacity integer, booked integer, free integer)
language plpgsql stable security definer set search_path = ''
as $$
declare v_customer boolean;
begin
  v_customer := not private.can_read_station(p_station);
  if v_customer and private.my_customer(p_station) is null then perform private.fail('NOT_FOUND'); end if;
  return query
  select d.slot_start, d.slot_end, d.capacity, d.booked, greatest(d.capacity - d.booked, 0)
  from private.day_slots(p_station, p_day) d
  where not v_customer or (d.slot_start > now() and d.booked < d.capacity)
  order by d.slot_start;
end;
$$;

-- REQ-016: staff bookings ----------------------------------------------------------------
create or replace function public.station_create_booking(
  p_station uuid, p_customer uuid, p_vehicle uuid, p_service uuid, p_slot timestamptz,
  p_note text default null, p_overbook boolean default false)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_end timestamptz; v_id uuid; v_full boolean;
begin
  if not private.has_role(p_station, array['owner','manager','cashier']::public.member_role[]) then perform private.fail('FORBIDDEN'); end if;
  perform private.assert_can_write(p_station, 'booking');
  if not exists (select 1 from public.vehicles where id = p_vehicle and customer_id = p_customer and station_id = p_station) then
    perform private.fail('VALIDATION', 'Choose the customer''s vehicle');
  end if;
  if p_service is not null and not exists (select 1 from public.services where id = p_service and station_id = p_station) then
    perform private.fail('VALIDATION', 'Service not found');
  end if;
  v_end := private.lock_slot(p_station, p_slot, null, coalesce(p_overbook, false), false);
  select d.booked >= d.capacity into v_full from private.day_slots(p_station, (p_slot at time zone 'Asia/Karachi')::date) d where d.slot_start = p_slot;
  insert into public.bookings (station_id, customer_id, vehicle_id, service_id, slot_start, slot_end, source, note, overbooked)
  values (p_station, p_customer, p_vehicle, p_service, p_slot, v_end, 'staff', nullif(trim(p_note), ''), v_full)
  returning id into v_id;
  perform private.notify_customer(p_station, p_customer, 'booking', 'Booking confirmed', private.slot_label(p_slot), v_id);
  return v_id;
end;
$$;

create or replace function public.station_reschedule_booking(p_booking uuid, p_slot timestamptz, p_overbook boolean default false)
returns void
language plpgsql security definer set search_path = ''
as $$
declare b public.bookings; v_end timestamptz;
begin
  select * into b from public.bookings where id = p_booking;
  if b.id is null or not private.has_role(b.station_id, array['owner','manager','cashier']::public.member_role[]) then
    perform private.fail('NOT_FOUND', 'Booking not found');
  end if;
  perform private.assert_can_write(b.station_id, 'booking');
  if b.status <> 'booked' then perform private.fail('VALIDATION', 'Only open bookings can be moved'); end if;
  v_end := private.lock_slot(b.station_id, p_slot, p_booking, coalesce(p_overbook, false), false);
  update public.bookings set slot_start = p_slot, slot_end = v_end, overbooked = coalesce(p_overbook, false), updated_at = now()
  where id = p_booking;
  perform private.notify_customer(b.station_id, b.customer_id, 'booking', 'Booking moved', private.slot_label(p_slot), p_booking);
end;
$$;

create or replace function public.station_cancel_booking(p_booking uuid, p_reason text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare b public.bookings;
begin
  select * into b from public.bookings where id = p_booking;
  if b.id is null or not private.has_role(b.station_id, array['owner','manager','cashier']::public.member_role[]) then
    perform private.fail('NOT_FOUND', 'Booking not found');
  end if;
  perform private.assert_can_write(b.station_id, 'booking');
  if b.status <> 'booked' then perform private.fail('VALIDATION', 'Only open bookings can be cancelled'); end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then perform private.fail('VALIDATION', 'A reason is required'); end if;
  update public.bookings set status = 'cancelled', cancel_reason = trim(p_reason), updated_at = now() where id = p_booking;
  perform private.notify_customer(b.station_id, b.customer_id, 'booking', 'Booking cancelled by the station',
    private.slot_label(b.slot_start) || ' — ' || trim(p_reason), p_booking);
end;
$$;

-- Customer arrived: opens the job card from the booking (SCR-004 → SCR-006).
create or replace function public.station_mark_arrived(
  p_booking uuid, p_odometer integer, p_fuel public.fuel_level, p_complaints text default null,
  p_confirm_odometer boolean default false)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare b public.bookings; v_job uuid; v_service text;
begin
  select * into b from public.bookings where id = p_booking for update;
  if b.id is null or not private.has_role(b.station_id, array['owner','manager','cashier']::public.member_role[]) then
    perform private.fail('NOT_FOUND', 'Booking not found');
  end if;
  if b.status not in ('booked', 'no_show') then perform private.fail('VALIDATION', 'This booking is already closed'); end if;
  select name into v_service from public.services where id = b.service_id;
  v_job := public.station_create_job(b.station_id, b.customer_id, b.vehicle_id, p_odometer, p_fuel,
    coalesce(nullif(trim(p_complaints), ''), concat_ws(' — ', v_service, b.note)), null, p_confirm_odometer, p_booking);
  -- A late arrival after the no-show mark takes the count back.
  if b.status = 'no_show' then
    update public.no_show_counters set no_shows = greatest(no_shows - 1, 0), updated_at = now() where customer_id = b.customer_id;
  end if;
  update public.bookings set status = 'arrived', job_id = v_job, updated_at = now() where id = p_booking;
  return v_job;
end;
$$;

-- REQ-017: manager/owner unblocks; the count starts again from zero.
create or replace function public.station_unblock_customer(p_customer uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare v_station uuid;
begin
  select station_id into v_station from public.customers where id = p_customer;
  if v_station is null or not private.has_role(v_station, array['owner','manager']::public.member_role[]) then
    perform private.fail('FORBIDDEN');
  end if;
  perform private.assert_can_write(v_station, 'booking');
  update public.no_show_counters set no_shows = 0, blocked = false, updated_at = now() where customer_id = p_customer;
end;
$$;

-- REQ-017: bookings not marked arrived 30 minutes after the slot start become No-show
-- and free the slot. Runs every 5 minutes; safe to run twice.
create or replace function private.mark_no_shows()
returns integer
language plpgsql security definer set search_path = ''
as $$
declare b record; n integer := 0; v_limit integer; p_at timestamptz := now();
begin
  for b in
    select * from public.bookings
    where status = 'booked' and slot_start + interval '30 minutes' <= p_at
    for update skip locked
  loop
    update public.bookings set status = 'no_show', updated_at = now() where id = b.id;
    select coalesce(no_show_limit, 3) into v_limit from public.booking_settings where station_id = b.station_id;
    insert into public.no_show_counters (station_id, customer_id, no_shows) values (b.station_id, b.customer_id, 1)
    on conflict (customer_id) do update set no_shows = public.no_show_counters.no_shows + 1, updated_at = now();
    update public.no_show_counters set blocked = true
    where customer_id = b.customer_id and no_shows >= coalesce(v_limit, 3) and not blocked;
    perform private.notify_customer(b.station_id, b.customer_id, 'booking', 'Missed booking', private.slot_label(b.slot_start), b.id);
    n := n + 1;
  end loop;
  return n;
end;
$$;

-- REQ-047 / REQ-015 / REQ-016: customer app ------------------------------------------------
-- Linked stations: every station with the caller's verified mobile on a customer record and
-- the booking feature (Standard/Premium).
create or replace function public.customer_stations()
returns table (station_id uuid, name text, city text, phone text, station_code text, customer_id uuid,
               customer_name text, blocked boolean, read_only boolean)
language sql stable security definer set search_path = ''
as $$
  select s.id, s.name, s.city, s.phone, s.station_code, c.id, c.name,
         coalesce(n.blocked, false),
         private.effective_status(sub.state, sub.trial_ends_at, sub.current_period_end) in ('read_only', 'suspended', 'closed')
  from public.customers c
  join public.stations s on s.id = c.station_id
  join public.subscriptions sub on sub.station_id = s.id
  left join public.no_show_counters n on n.customer_id = c.id
  where c.mobile = private.my_mobile() and private.has_feature(s.id, 'booking') and sub.state <> 'closed'
  order by s.name;
$$;

-- Link by the station's code: creates the customer record there if it does not exist yet.
create or replace function public.customer_link_station(p_code text, p_name text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_station uuid; v_mobile text := private.my_mobile(); v_id uuid;
begin
  if v_mobile is null then perform private.fail('FORBIDDEN', 'Log in with your mobile number first'); end if;
  select id into v_station from public.stations where station_code = upper(trim(coalesce(p_code, '')));
  if v_station is null then perform private.fail('NOT_FOUND', 'No station has this code'); end if;
  if not private.has_feature(v_station, 'booking') then
    perform private.fail('FEATURE_LOCKED', 'This station doesn''t offer the app yet');
  end if;
  select id into v_id from public.customers where station_id = v_station and mobile = v_mobile;
  if v_id is not null then return v_station; end if;
  perform private.assert_can_write(v_station, 'booking');
  if length(trim(coalesce(p_name, ''))) < 2 then perform private.fail('VALIDATION', 'Enter your name'); end if;
  insert into public.customers (station_id, name, mobile) values (v_station, trim(p_name), v_mobile);
  return v_station;
end;
$$;

-- Loads the caller's customer id at a station or fails with NOT_FOUND.
create or replace function private.customer_at(p_station uuid)
returns uuid
language plpgsql stable security definer set search_path = ''
as $$
declare v uuid := private.my_customer(p_station);
begin
  if v is null then perform private.fail('NOT_FOUND', 'Station not linked'); end if;
  return v;
end;
$$;
grant execute on all functions in schema private to authenticated, service_role;

create or replace function public.customer_station_data(p_station uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare v_c uuid := private.customer_at(p_station);
begin
  return jsonb_build_object(
    'vehicles', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'plate', v.plate, 'make', v.make, 'model', v.model) order by v.plate)
                 from public.vehicles v where v.customer_id = v_c), '[]'::jsonb),
    'services', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'rate_paisa', s.rate_paisa) order by s.name)
                 from public.services s where s.station_id = p_station and s.active and s.bookable), '[]'::jsonb),
    'bookings', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'slot_start', b.slot_start, 'slot_end', b.slot_end,
                   'status', b.status, 'plate', v.plate, 'service', s.name, 'note', b.note) order by b.slot_start desc)
                 from public.bookings b join public.vehicles v on v.id = b.vehicle_id left join public.services s on s.id = b.service_id
                 where b.customer_id = v_c), '[]'::jsonb),
    'jobs', coalesce((select jsonb_agg(jsonb_build_object('id', j.id, 'job_no', j.job_no, 'stage', j.stage, 'plate', v.plate,
                   'created_at', j.created_at, 'extra_pending', exists (select 1 from public.job_lines l where l.job_id = j.id and l.status = 'extra_pending'))
                   order by j.created_at desc)
                 from public.job_cards j join public.vehicles v on v.id = j.vehicle_id where j.customer_id = v_c), '[]'::jsonb),
    'invoices', coalesce((select jsonb_agg(jsonb_build_object('id', b.invoice_id, 'invoice_no', b.invoice_no, 'issued_at', b.issued_at,
                   'total_paisa', b.total_paisa, 'paid_paisa', b.paid_paisa, 'due_paisa', b.due_paisa, 'status', b.status,
                   'job_no', j.job_no, 'plate', v.plate) order by b.issued_at desc)
                 from public.invoice_balances b join public.job_cards j on j.id = b.job_id join public.vehicles v on v.id = j.vehicle_id
                 where b.customer_id = v_c), '[]'::jsonb),
    'dues_paisa', coalesce((select dues_paisa from public.customer_balances where customer_id = v_c), 0)
  );
end;
$$;

create or replace function public.customer_add_vehicle(p_station uuid, p_plate text, p_make text default null, p_model text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_c uuid := private.customer_at(p_station); v_plate text := private.normalize_plate(p_plate); v_id uuid; v_owner uuid;
begin
  perform private.assert_can_write(p_station, 'booking');
  if v_plate is null then perform private.fail('VALIDATION', 'Number plate is not valid (e.g. LEA-1234)'); end if;
  select id, customer_id into v_id, v_owner from public.vehicles where station_id = p_station and plate = v_plate;
  if v_id is not null then
    if v_owner = v_c then return v_id; end if;
    perform private.fail('VALIDATION', 'This plate is registered to someone else — please call the station');
  end if;
  insert into public.vehicles (station_id, customer_id, plate, make, model)
  values (p_station, v_c, v_plate, nullif(trim(p_make), ''), nullif(trim(p_model), ''))
  returning id into v_id;
  insert into public.vehicle_owner_history (station_id, vehicle_id, from_customer_id, to_customer_id, changed_by)
  values (p_station, v_id, null, v_c, auth.uid());
  return v_id;
end;
$$;

create or replace function public.customer_book(
  p_station uuid, p_vehicle uuid, p_service uuid, p_slot timestamptz, p_note text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_c uuid := private.customer_at(p_station); v_end timestamptz; v_id uuid;
begin
  if exists (select 1 from public.no_show_counters where customer_id = v_c and blocked) then
    perform private.fail('BOOKING_BLOCKED', 'Please call the station');
  end if;
  perform private.assert_can_write(p_station, 'booking');
  if not exists (select 1 from public.vehicles where id = p_vehicle and customer_id = v_c) then
    perform private.fail('VALIDATION', 'Choose your vehicle');
  end if;
  if p_service is not null and not exists (select 1 from public.services where id = p_service and station_id = p_station and bookable and active) then
    perform private.fail('VALIDATION', 'Service not found');
  end if;
  v_end := private.lock_slot(p_station, p_slot, null, false, true);
  if exists (select 1 from public.bookings where vehicle_id = p_vehicle and slot_start = p_slot and status = 'booked') then
    perform private.fail('VALIDATION', 'This vehicle is already booked for this time');
  end if;
  insert into public.bookings (station_id, customer_id, vehicle_id, service_id, slot_start, slot_end, source, note, created_by)
  values (p_station, v_c, p_vehicle, p_service, p_slot, v_end, 'app', nullif(trim(p_note), ''), auth.uid())
  returning id into v_id;
  perform private.notify(p_station, null, 'booking', 'New app booking',
    (select plate from public.vehicles where id = p_vehicle) || ' · ' || private.slot_label(p_slot), v_id);
  perform private.notify_customer(p_station, v_c, 'booking', 'Booking confirmed', private.slot_label(p_slot), v_id);
  return v_id;
end;
$$;

-- Loads the caller's own open booking, applying the 1-hour rule (REQ-016).
create or replace function private.my_open_booking(p_booking uuid)
returns public.bookings
language plpgsql stable security definer set search_path = ''
as $$
declare b public.bookings;
begin
  select * into b from public.bookings where id = p_booking;
  if b.id is null or b.customer_id is distinct from private.my_customer(b.station_id) then
    perform private.fail('NOT_FOUND', 'Booking not found');
  end if;
  if b.status <> 'booked' then perform private.fail('VALIDATION', 'This booking is already closed'); end if;
  if now() > b.slot_start - interval '1 hour' then
    perform private.fail('TOO_LATE', 'Too late to change online — call the station');
  end if;
  return b;
end;
$$;
grant execute on function private.my_open_booking(uuid) to authenticated, service_role;

create or replace function public.customer_cancel_booking(p_booking uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare b public.bookings := private.my_open_booking(p_booking);
begin
  update public.bookings set status = 'cancelled', cancel_reason = 'Cancelled by customer in app', updated_at = now() where id = p_booking;
  perform private.notify(b.station_id, null, 'booking', 'Booking cancelled by customer', private.slot_label(b.slot_start), p_booking);
end;
$$;

create or replace function public.customer_reschedule_booking(p_booking uuid, p_slot timestamptz)
returns void
language plpgsql security definer set search_path = ''
as $$
declare b public.bookings := private.my_open_booking(p_booking); v_end timestamptz;
begin
  if exists (select 1 from public.no_show_counters where customer_id = b.customer_id and blocked) then
    perform private.fail('BOOKING_BLOCKED', 'Please call the station');
  end if;
  perform private.assert_can_write(b.station_id, 'booking');
  v_end := private.lock_slot(b.station_id, p_slot, p_booking, false, true);
  update public.bookings set slot_start = p_slot, slot_end = v_end, updated_at = now() where id = p_booking;
  perform private.notify(b.station_id, null, 'booking', 'Booking moved by customer',
    private.slot_label(b.slot_start) || ' → ' || private.slot_label(p_slot), p_booking);
end;
$$;

create or replace function public.customer_notifications_list()
returns table (id bigint, station_name text, kind text, title text, body text, ref_id uuid, created_at timestamptz, read_at timestamptz)
language sql stable security definer set search_path = ''
as $$
  select n.id, s.name, n.kind, n.title, n.body, n.ref_id, n.created_at, n.read_at
  from public.customer_notifications n
  join public.customers c on c.id = n.customer_id
  join public.stations s on s.id = n.station_id
  where c.mobile = private.my_mobile() and private.has_feature(n.station_id, 'booking')
  order by n.created_at desc
  limit 100;
$$;

create or replace function public.customer_mark_notifications_read()
returns void
language sql security definer set search_path = ''
as $$
  update public.customer_notifications n set read_at = now()
  from public.customers c
  where c.id = n.customer_id and c.mobile = private.my_mobile() and n.read_at is null;
$$;

-- Grants -----------------------------------------------------------------------------------
revoke execute on function
  public.station_save_booking_settings(uuid, integer, integer, integer, jsonb, date[], integer),
  public.station_booking_conflicts(uuid),
  public.station_set_service_bookable(uuid, boolean),
  public.booking_slots(uuid, date),
  public.station_create_booking(uuid, uuid, uuid, uuid, timestamptz, text, boolean),
  public.station_reschedule_booking(uuid, timestamptz, boolean),
  public.station_cancel_booking(uuid, text),
  public.station_mark_arrived(uuid, integer, public.fuel_level, text, boolean),
  public.station_unblock_customer(uuid),
  public.customer_stations(),
  public.customer_link_station(text, text),
  public.customer_station_data(uuid),
  public.customer_add_vehicle(uuid, text, text, text),
  public.customer_book(uuid, uuid, uuid, timestamptz, text),
  public.customer_cancel_booking(uuid),
  public.customer_reschedule_booking(uuid, timestamptz),
  public.customer_notifications_list(),
  public.customer_mark_notifications_read()
from public, anon;
grant execute on function
  public.station_save_booking_settings(uuid, integer, integer, integer, jsonb, date[], integer),
  public.station_booking_conflicts(uuid),
  public.station_set_service_bookable(uuid, boolean),
  public.booking_slots(uuid, date),
  public.station_create_booking(uuid, uuid, uuid, uuid, timestamptz, text, boolean),
  public.station_reschedule_booking(uuid, timestamptz, boolean),
  public.station_cancel_booking(uuid, text),
  public.station_mark_arrived(uuid, integer, public.fuel_level, text, boolean),
  public.station_unblock_customer(uuid),
  public.customer_stations(),
  public.customer_link_station(text, text),
  public.customer_station_data(uuid),
  public.customer_add_vehicle(uuid, text, text, text),
  public.customer_book(uuid, uuid, uuid, timestamptz, text),
  public.customer_cancel_booking(uuid),
  public.customer_reschedule_booking(uuid, timestamptz),
  public.customer_notifications_list(),
  public.customer_mark_notifications_read()
to authenticated;

-- No-show marking every 5 minutes when pg_cron is enabled on the project.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('booking-no-shows', '*/5 * * * *', 'select private.mark_no_shows()');
  end if;
end $$;