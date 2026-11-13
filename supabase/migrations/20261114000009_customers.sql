-- TASK-026, TASK-028 · REQ-046, REQ-048
-- Customers and vehicles per station; search by phone, plate or name.

create table public.customers (
  id         uuid primary key default gen_random_uuid(),
  station_id uuid not null references public.stations(id) on delete cascade,
  name       text not null check (length(trim(name)) between 2 and 120),
  mobile     text not null check (mobile ~ '^03[0-9]{9}$'),
  email      text check (email is null or email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  address    text,
  created_at timestamptz not null default now(),
  unique (station_id, mobile)
);
create index customers_name_idx on public.customers(station_id, lower(name));

create table public.vehicles (
  id          uuid primary key default gen_random_uuid(),
  station_id  uuid not null references public.stations(id) on delete cascade,
  customer_id uuid not null references public.customers(id),
  plate       text not null check (plate ~ '^[A-Z0-9]+(-[A-Z0-9]+)*$'),
  make        text,
  model       text,
  year        integer check (year is null or year between 1950 and 2100),
  colour      text,
  created_at  timestamptz not null default now(),
  unique (station_id, plate)
);
create index vehicles_customer_idx on public.vehicles(customer_id);

-- Ownership history (REQ-046: a vehicle can move to another customer).
create table public.vehicle_owner_history (
  id               bigint generated always as identity primary key,
  station_id       uuid not null references public.stations(id) on delete cascade,
  vehicle_id       uuid not null references public.vehicles(id) on delete cascade,
  from_customer_id uuid references public.customers(id),
  to_customer_id   uuid not null references public.customers(id),
  changed_by       uuid default auth.uid(),
  changed_at       timestamptz not null default now()
);

alter table public.customers             enable row level security;
alter table public.vehicles              enable row level security;
alter table public.vehicle_owner_history enable row level security;

-- OW, MG, CA. Mechanics see the vehicle on their assigned job (Phase 3, via sync).
create policy customers_read on public.customers for select to authenticated
  using (private.has_role(station_id, array['owner','manager','cashier']::public.member_role[])
         or private.has_support_grant(station_id));
create policy vehicles_read on public.vehicles for select to authenticated
  using (private.has_role(station_id, array['owner','manager','cashier']::public.member_role[])
         or private.has_support_grant(station_id));
create policy vehicle_owner_history_read on public.vehicle_owner_history for select to authenticated
  using (private.has_role(station_id, array['owner','manager','cashier']::public.member_role[])
         or private.has_support_grant(station_id));
revoke insert, update, delete on public.customers, public.vehicles, public.vehicle_owner_history from anon, authenticated;

create trigger audit_customers after insert or update on public.customers
  for each row execute function private.audit_row();
create trigger audit_vehicles after insert or update on public.vehicles
  for each row execute function private.audit_row();

-- Same rule as packages/core normalizePlate: upper case, single dashes between letter/digit runs.
create or replace function private.normalize_plate(p_raw text)
returns text
language plpgsql immutable
as $$
declare
  t text;
  parts text[];
begin
  t := upper(coalesce(p_raw, ''));
  t := regexp_replace(t, '([A-Z])([0-9])', '\1-\2', 'g');
  t := regexp_replace(t, '([0-9])([A-Z])', '\1-\2', 'g');
  t := regexp_replace(t, '[^A-Z0-9]+', '-', 'g');
  t := trim(both '-' from t);
  if t !~ '^[A-Z]{1,4}(-[A-Z0-9]{1,4}){1,3}$' or t !~ '[0-9]' or length(replace(t, '-', '')) > 10 then
    return null;
  end if;
  return t;
end;
$$;
grant execute on all functions in schema private to authenticated, service_role;

create or replace function public.station_save_customer(
  p_station uuid, p_id uuid, p_name text, p_mobile text, p_email text default null, p_address text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_id uuid := p_id;
  v_mobile text := private.normalize_pk_mobile(p_mobile);
begin
  if not private.has_role(p_station, array['owner','manager','cashier']::public.member_role[]) then
    perform private.fail('FORBIDDEN');
  end if;
  perform private.assert_can_write(p_station);
  if length(trim(coalesce(p_name, ''))) < 2 then perform private.fail('VALIDATION', 'Name missing'); end if;
  if v_mobile is null then perform private.fail('VALIDATION', 'Mobile must be like 0300-1234567'); end if;
  if nullif(trim(p_email), '') is not null and trim(p_email) !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    perform private.fail('VALIDATION', 'Email is not valid');
  end if;
  if exists (select 1 from public.customers where station_id = p_station and mobile = v_mobile and id is distinct from p_id) then
    perform private.fail('VALIDATION', 'A customer with this mobile already exists');
  end if;

  if v_id is null then
    insert into public.customers (station_id, name, mobile, email, address)
    values (p_station, trim(p_name), v_mobile, nullif(trim(p_email), ''), nullif(trim(p_address), ''))
    returning id into v_id;
  else
    update public.customers set name = trim(p_name), mobile = v_mobile,
      email = nullif(trim(p_email), ''), address = nullif(trim(p_address), '')
    where id = v_id and station_id = p_station;
    if not found then perform private.fail('NOT_FOUND'); end if;
  end if;
  return v_id;
end;
$$;

create or replace function public.station_save_vehicle(
  p_station uuid, p_id uuid, p_customer uuid, p_plate text,
  p_make text default null, p_model text default null, p_year integer default null, p_colour text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_id uuid := p_id;
  v_plate text := private.normalize_plate(p_plate);
  v_old_customer uuid;
begin
  if not private.has_role(p_station, array['owner','manager','cashier']::public.member_role[]) then
    perform private.fail('FORBIDDEN');
  end if;
  perform private.assert_can_write(p_station);
  if v_plate is null then perform private.fail('VALIDATION', 'Number plate is not valid (e.g. LEA-1234)'); end if;
  if not exists (select 1 from public.customers where id = p_customer and station_id = p_station) then
    perform private.fail('NOT_FOUND', 'Customer not found');
  end if;
  if exists (select 1 from public.vehicles where station_id = p_station and plate = v_plate and id is distinct from p_id) then
    perform private.fail('VALIDATION', 'This plate is already registered');
  end if;

  if v_id is null then
    insert into public.vehicles (station_id, customer_id, plate, make, model, year, colour)
    values (p_station, p_customer, v_plate, nullif(trim(p_make), ''), nullif(trim(p_model), ''), p_year, nullif(trim(p_colour), ''))
    returning id into v_id;
    insert into public.vehicle_owner_history (station_id, vehicle_id, from_customer_id, to_customer_id)
    values (p_station, v_id, null, p_customer);
  else
    select customer_id into v_old_customer from public.vehicles where id = v_id and station_id = p_station;
    if not found then perform private.fail('NOT_FOUND'); end if;
    update public.vehicles set customer_id = p_customer, plate = v_plate, make = nullif(trim(p_make), ''),
      model = nullif(trim(p_model), ''), year = p_year, colour = nullif(trim(p_colour), '')
    where id = v_id;
    if v_old_customer <> p_customer then
      insert into public.vehicle_owner_history (station_id, vehicle_id, from_customer_id, to_customer_id)
      values (p_station, v_id, v_old_customer, p_customer);
    end if;
  end if;
  return v_id;
end;
$$;

-- REQ-046: search by phone digits, plate part or name. Runs with the caller's rights (RLS).
create or replace function public.station_search_customers(p_station uuid, p_query text, p_limit integer default 30)
returns table (customer_id uuid, name text, mobile text, vehicle_id uuid, plate text, make text, model text)
language sql stable security invoker set search_path = ''
as $$
  with q as (
    select trim(coalesce(p_query, '')) as raw,
           regexp_replace(coalesce(p_query, ''), '[^0-9]', '', 'g') as digits,
           upper(regexp_replace(coalesce(p_query, ''), '[^A-Za-z0-9]', '', 'g')) as plate_key
  )
  select c.id, c.name, c.mobile, v.id, v.plate, v.make, v.model
  from public.customers c
  left join public.vehicles v on v.customer_id = c.id
  cross join q
  where c.station_id = p_station
    and length(q.raw) >= 2
    and (
      (length(q.digits) >= 3 and right(c.mobile, 10) like '%' || ltrim(q.digits, '0') || '%')
      or (length(q.plate_key) >= 2 and replace(v.plate, '-', '') like '%' || q.plate_key || '%')
      or lower(c.name) like '%' || lower(q.raw) || '%'
    )
  order by c.name, v.plate
  limit greatest(1, least(coalesce(p_limit, 30), 100));
$$;

-- REQ-048: vehicle timeline, newest first. Jobs and invoices join this in Phase 3/4;
-- until then it shows registration and ownership changes.
create or replace function public.station_vehicle_history(p_vehicle uuid)
returns table (at timestamptz, kind text, title text, odometer integer, total_paisa bigint, ref_id uuid)
language sql stable security invoker set search_path = ''
as $$
  select h.changed_at, 'owner',
         case when h.from_customer_id is null then 'Registered to ' || c.name else 'Owner changed to ' || c.name end,
         null::integer, null::bigint, h.to_customer_id
  from public.vehicle_owner_history h
  join public.customers c on c.id = h.to_customer_id
  where h.vehicle_id = p_vehicle
  order by h.changed_at desc, h.id desc;
$$;

revoke execute on function
  public.station_save_customer(uuid, uuid, text, text, text, text),
  public.station_save_vehicle(uuid, uuid, uuid, text, text, text, integer, text),
  public.station_search_customers(uuid, text, integer),
  public.station_vehicle_history(uuid)
from public, anon;
grant execute on function
  public.station_save_customer(uuid, uuid, text, text, text, text),
  public.station_save_vehicle(uuid, uuid, uuid, text, text, text, integer, text),
  public.station_search_customers(uuid, text, integer),
  public.station_vehicle_history(uuid)
to authenticated;
