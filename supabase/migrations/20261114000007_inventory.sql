-- TASK-020, TASK-021, TASK-022, TASK-025 · REQ-028, REQ-029, REQ-030, REQ-031, REQ-033
-- Items, kits, append-only stock movements with weighted average cost, suppliers,
-- purchases and the supplier ledger. Money = integer paisa. Quantities = numeric(12,3).

create type public.item_unit as enum ('piece', 'litre', 'kit');
create type public.stock_move_kind as enum
  ('opening', 'purchase', 'purchase_reversal', 'adjustment', 'job_use', 'job_return', 'supplier_return');

-- Generic guard for append-only tables (money and stock: corrections by reversal, REQ-042).
create or replace function private.append_only()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' and current_setting('app.purge_station', true) = 'on' then
    return old;
  end if;
  raise exception using errcode = 'P0001', message = 'APPEND_ONLY',
    detail = 'Saved entries cannot be changed or deleted. Reverse them with a reason.';
end;
$$;

-- Quantity rule: litres up to 2 decimals; pieces and kits whole numbers.
create or replace function private.valid_qty(p_unit public.item_unit, p_qty numeric)
returns boolean
language sql immutable
as $$
  select p_qty is not null and case
    when p_unit = 'litre' then p_qty = round(p_qty, 2)
    else p_qty = trunc(p_qty)
  end;
$$;

-- Items ----------------------------------------------------------------------
create table public.items (
  id                  uuid primary key default gen_random_uuid(),
  station_id          uuid not null references public.stations(id) on delete cascade,
  code                text not null check (length(trim(code)) between 1 and 40),
  name                text not null check (length(trim(name)) between 2 and 120),
  barcode             text,
  category            text,
  unit                public.item_unit not null default 'piece',
  is_bulk             boolean not null default false,  -- partial drum: decimal use allowed
  selling_price_paisa bigint not null default 0 check (selling_price_paisa >= 0),
  min_stock           numeric(12,3) not null default 0 check (min_stock >= 0),
  warranty_days       integer not null default 0 check (warranty_days >= 0),
  active              boolean not null default true,
  created_at          timestamptz not null default now(),
  unique (station_id, code),
  check (not is_bulk or unit = 'litre')
);
create unique index items_barcode_uq on public.items(station_id, barcode) where barcode is not null;
create index items_name_idx on public.items(station_id, lower(name));

-- Purchase cost is owner-only (REQ-028), so it lives in its own table.
create table public.item_costs (
  item_id             uuid primary key references public.items(id) on delete cascade,
  station_id          uuid not null references public.stations(id) on delete cascade,
  avg_cost_paisa      bigint not null default 0 check (avg_cost_paisa >= 0),
  last_cost_paisa     bigint not null default 0 check (last_cost_paisa >= 0),
  updated_at          timestamptz not null default now()
);

create table public.kit_components (
  station_id        uuid not null references public.stations(id) on delete cascade,
  kit_item_id       uuid not null references public.items(id) on delete cascade,
  component_item_id uuid not null references public.items(id),
  qty               numeric(12,3) not null check (qty > 0),
  primary key (kit_item_id, component_item_id),
  check (kit_item_id <> component_item_id)
);

create table public.stock_movements (
  id              bigint generated always as identity primary key,
  station_id      uuid not null references public.stations(id) on delete cascade,
  item_id         uuid not null references public.items(id),
  qty             numeric(12,3) not null check (qty <> 0),
  kind            public.stock_move_kind not null,
  ref_id          uuid,
  unit_cost_paisa bigint,
  note            text,
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now()
);
create index stock_movements_item_idx on public.stock_movements(item_id);
create trigger stock_movements_append_only before update or delete on public.stock_movements
  for each row execute function private.append_only();

-- Stock on hand = sum of movements (ARCHITECTURE §5).
create or replace view public.item_stock
with (security_invoker = true)
as
select i.station_id, i.id as item_id, coalesce(sum(m.qty), 0)::numeric(12,3) as on_hand
from public.items i
left join public.stock_movements m on m.item_id = i.id
group by i.station_id, i.id;

-- REQ-033: at or below minimum; REQ-031: negative stock is shown too.
create or replace view public.low_stock_items
with (security_invoker = true)
as
select i.station_id, i.id as item_id, i.code, i.name, i.unit, i.min_stock, s.on_hand,
       (s.on_hand < 0) as negative
from public.items i
join public.item_stock s on s.item_id = i.id
where i.active and i.unit <> 'kit' and (s.on_hand < 0 or (i.min_stock > 0 and s.on_hand <= i.min_stock));

-- Suppliers and purchases --------------------------------------------------------
create table public.suppliers (
  id         uuid primary key default gen_random_uuid(),
  station_id uuid not null references public.stations(id) on delete cascade,
  name       text not null check (length(trim(name)) between 2 and 120),
  phone      text,
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  unique (station_id, name)
);

create type public.purchase_status as enum ('posted', 'reversed');

create table public.purchases (
  id               uuid primary key default gen_random_uuid(),
  station_id       uuid not null references public.stations(id) on delete cascade,
  supplier_id      uuid references public.suppliers(id),
  supplier_name    text not null,          -- free text on Basic; copied from supplier on Standard+
  bill_no          text,
  bill_date        date not null default current_date,
  total_paisa      bigint not null check (total_paisa >= 0),
  paid_now_paisa   bigint not null default 0 check (paid_now_paisa >= 0),
  status           public.purchase_status not null default 'posted',
  reversal_reason  text,
  reversed_at      timestamptz,
  reversed_by      uuid,
  created_by       uuid default auth.uid(),
  created_at       timestamptz not null default now()
);
create index purchases_station_idx on public.purchases(station_id, bill_date desc);

create table public.purchase_lines (
  id              uuid primary key default gen_random_uuid(),
  station_id      uuid not null references public.stations(id) on delete cascade,
  purchase_id     uuid not null references public.purchases(id) on delete cascade,
  item_id         uuid not null references public.items(id),
  qty             numeric(12,3) not null check (qty > 0),
  unit_cost_paisa bigint not null check (unit_cost_paisa >= 0)
);
create index purchase_lines_purchase_idx on public.purchase_lines(purchase_id);

create type public.supplier_entry_kind as enum ('purchase', 'payment', 'purchase_reversal', 'payment_reversal', 'return');

-- Positive amount = station owes more; negative = owes less.
create table public.supplier_ledger (
  id           bigint generated always as identity primary key,
  station_id   uuid not null references public.stations(id) on delete cascade,
  supplier_id  uuid not null references public.suppliers(id),
  kind         public.supplier_entry_kind not null,
  amount_paisa bigint not null check (amount_paisa <> 0),
  ref_id       uuid,
  method       text,
  reference    text,
  note         text,
  created_by   uuid default auth.uid(),
  created_at   timestamptz not null default now()
);
create index supplier_ledger_supplier_idx on public.supplier_ledger(supplier_id, created_at);
create trigger supplier_ledger_append_only before update or delete on public.supplier_ledger
  for each row execute function private.append_only();

create or replace view public.supplier_balances
with (security_invoker = true)
as
select s.station_id, s.id as supplier_id, s.name,
       coalesce(sum(l.amount_paisa) filter (where l.kind in ('purchase','purchase_reversal','return')), 0)::bigint as purchases_paisa,
       coalesce(-sum(l.amount_paisa) filter (where l.kind in ('payment','payment_reversal')), 0)::bigint as payments_paisa,
       coalesce(sum(l.amount_paisa), 0)::bigint as due_paisa
from public.suppliers s
left join public.supplier_ledger l on l.supplier_id = s.id
group by s.station_id, s.id, s.name;

-- RLS (PRD §3 matrix) -----------------------------------------------------------
alter table public.items           enable row level security;
alter table public.item_costs      enable row level security;
alter table public.kit_components  enable row level security;
alter table public.stock_movements enable row level security;
alter table public.suppliers       enable row level security;
alter table public.purchases       enable row level security;
alter table public.purchase_lines  enable row level security;
alter table public.supplier_ledger enable row level security;

-- Items and prices: OW, MG, CA (mechanics get name/stock only via sync in Phase 3).
create policy items_read on public.items for select to authenticated
  using (private.has_role(station_id, array['owner','manager','cashier']::public.member_role[])
         or private.has_support_grant(station_id));
create policy kit_components_read on public.kit_components for select to authenticated
  using (private.has_role(station_id, array['owner','manager','cashier']::public.member_role[])
         or private.has_support_grant(station_id));
create policy stock_movements_read on public.stock_movements for select to authenticated
  using (private.has_role(station_id, array['owner','manager','cashier']::public.member_role[])
         or private.has_support_grant(station_id));
-- Purchase cost: owner only.
create policy item_costs_read on public.item_costs for select to authenticated
  using (private.has_role(station_id, array['owner']::public.member_role[]));
-- Purchases and suppliers: OW, MG.
create policy suppliers_read on public.suppliers for select to authenticated
  using (private.has_role(station_id, array['owner','manager']::public.member_role[])
         or private.has_support_grant(station_id));
create policy purchases_read on public.purchases for select to authenticated
  using (private.has_role(station_id, array['owner','manager']::public.member_role[])
         or private.has_support_grant(station_id));
create policy purchase_lines_read on public.purchase_lines for select to authenticated
  using (private.has_role(station_id, array['owner','manager']::public.member_role[])
         or private.has_support_grant(station_id));
create policy supplier_ledger_read on public.supplier_ledger for select to authenticated
  using (private.has_role(station_id, array['owner','manager']::public.member_role[])
         or private.has_support_grant(station_id));

revoke insert, update, delete on public.items, public.item_costs, public.kit_components, public.stock_movements,
  public.suppliers, public.purchases, public.purchase_lines, public.supplier_ledger from anon, authenticated;
grant select on public.item_stock, public.low_stock_items, public.supplier_balances to authenticated;

-- Audit (REQ-058: prices, stock, purchases) ---------------------------------------
create trigger audit_items after insert or update on public.items
  for each row execute function private.audit_row();
create trigger audit_item_costs after update on public.item_costs
  for each row execute function private.audit_row();
create trigger audit_purchases after insert or update on public.purchases
  for each row execute function private.audit_row();
create trigger audit_stock_movements after insert on public.stock_movements
  for each row execute function private.audit_row();
create trigger audit_supplier_ledger after insert on public.supplier_ledger
  for each row execute function private.audit_row();

grant execute on all functions in schema private to authenticated, service_role;

-- Functions --------------------------------------------------------------------
-- Create or update an item (REQ-028). Cost is set only through purchases or by the owner.
create or replace function public.station_save_item(
  p_station uuid,
  p_item jsonb,                 -- {id?, code, name, barcode, category, unit, is_bulk, selling_price_paisa, min_stock, warranty_days, active}
  p_components jsonb default null)  -- for kits: [{item_id, qty}]
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_id   uuid := nullif(p_item ->> 'id', '')::uuid;
  v_unit public.item_unit := coalesce(p_item ->> 'unit', 'piece')::public.item_unit;
  v_bar  text := nullif(trim(p_item ->> 'barcode'), '');
  c      jsonb;
begin
  if not private.has_role(p_station, array['owner','manager']::public.member_role[]) then
    perform private.fail('FORBIDDEN');
  end if;
  perform private.assert_can_write(p_station);

  if length(trim(coalesce(p_item ->> 'name', ''))) < 2 then
    perform private.fail('VALIDATION', 'Name missing');
  end if;
  if length(trim(coalesce(p_item ->> 'code', ''))) < 1 then
    perform private.fail('VALIDATION', 'Code missing');
  end if;
  if coalesce((p_item ->> 'selling_price_paisa')::bigint, 0) < 0 then
    perform private.fail('VALIDATION', 'Selling price cannot be negative');
  end if;
  if coalesce((p_item ->> 'is_bulk')::boolean, false) and v_unit <> 'litre' then
    perform private.fail('VALIDATION', 'Only litre items can be bulk containers');
  end if;
  if not private.valid_qty(v_unit, coalesce((p_item ->> 'min_stock')::numeric, 0)) then
    perform private.fail('VALIDATION', 'Minimum stock must be a whole number (2 decimals for litres)');
  end if;
  if exists (select 1 from public.items where station_id = p_station and code = trim(p_item ->> 'code')
             and id is distinct from v_id) then
    perform private.fail('VALIDATION', 'Another item already uses this code');
  end if;
  if v_bar is not null and exists (select 1 from public.items where station_id = p_station and barcode = v_bar
             and id is distinct from v_id) then
    perform private.fail('VALIDATION', 'Another item already uses this barcode');
  end if;

  if v_id is null then
    insert into public.items (station_id, code, name, barcode, category, unit, is_bulk,
                              selling_price_paisa, min_stock, warranty_days)
    values (p_station, trim(p_item ->> 'code'), trim(p_item ->> 'name'), v_bar,
            nullif(trim(p_item ->> 'category'), ''), v_unit,
            coalesce((p_item ->> 'is_bulk')::boolean, false),
            coalesce((p_item ->> 'selling_price_paisa')::bigint, 0),
            coalesce((p_item ->> 'min_stock')::numeric, 0),
            coalesce((p_item ->> 'warranty_days')::integer, 0))
    returning id into v_id;
    insert into public.item_costs (item_id, station_id) values (v_id, p_station);
  else
    if not exists (select 1 from public.items where id = v_id and station_id = p_station) then
      perform private.fail('NOT_FOUND');
    end if;
    if (select unit from public.items where id = v_id) <> v_unit
       and exists (select 1 from public.stock_movements where item_id = v_id) then
      perform private.fail('VALIDATION', 'Unit cannot change after stock was recorded');
    end if;
    update public.items set
      code = trim(p_item ->> 'code'), name = trim(p_item ->> 'name'), barcode = v_bar,
      category = nullif(trim(p_item ->> 'category'), ''), unit = v_unit,
      is_bulk = coalesce((p_item ->> 'is_bulk')::boolean, false),
      selling_price_paisa = coalesce((p_item ->> 'selling_price_paisa')::bigint, 0),
      min_stock = coalesce((p_item ->> 'min_stock')::numeric, 0),
      warranty_days = coalesce((p_item ->> 'warranty_days')::integer, 0),
      active = coalesce((p_item ->> 'active')::boolean, true)
    where id = v_id;
  end if;

  if v_unit = 'kit' then
    delete from public.kit_components where kit_item_id = v_id;
    for c in select * from jsonb_array_elements(coalesce(p_components, '[]'::jsonb)) loop
      if not exists (select 1 from public.items where id = (c ->> 'item_id')::uuid
                     and station_id = p_station and unit <> 'kit') then
        perform private.fail('VALIDATION', 'Kit components must be non-kit items of this station');
      end if;
      insert into public.kit_components (station_id, kit_item_id, component_item_id, qty)
      values (p_station, v_id, (c ->> 'item_id')::uuid, (c ->> 'qty')::numeric);
    end loop;
    if not exists (select 1 from public.kit_components where kit_item_id = v_id) then
      perform private.fail('VALIDATION', 'A kit needs at least one component');
    end if;
  end if;
  return v_id;
end;
$$;

-- Owner sets/corrects the cost directly (e.g. opening stock value).
create or replace function public.station_set_item_cost(p_item uuid, p_cost_paisa bigint)
returns void
language plpgsql security definer set search_path = ''
as $$
declare v_station uuid;
begin
  select station_id into v_station from public.items where id = p_item;
  if v_station is null or not private.has_role(v_station, array['owner']::public.member_role[]) then
    perform private.fail('NOT_FOUND');
  end if;
  perform private.assert_can_write(v_station);
  if p_cost_paisa < 0 then perform private.fail('VALIDATION', 'Cost cannot be negative'); end if;
  update public.item_costs set avg_cost_paisa = p_cost_paisa, updated_at = now() where item_id = p_item;
end;
$$;

-- Internal: record a stock movement after checks done by the caller.
create or replace function private.move_stock(
  p_station uuid, p_item uuid, p_qty numeric, p_kind public.stock_move_kind,
  p_ref uuid default null, p_cost bigint default null, p_note text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare v_unit public.item_unit;
begin
  select unit into v_unit from public.items where id = p_item and station_id = p_station;
  if v_unit is null then perform private.fail('NOT_FOUND', 'Item not found'); end if;
  if v_unit = 'kit' then perform private.fail('VALIDATION', 'Kits have no own stock; use their components'); end if;
  if not private.valid_qty(v_unit, p_qty) then
    perform private.fail('VALIDATION', case when v_unit = 'litre' then 'Litres allow at most 2 decimals'
                                            else 'Quantity must be a whole number' end);
  end if;
  insert into public.stock_movements (station_id, item_id, qty, kind, ref_id, unit_cost_paisa, note)
  values (p_station, p_item, p_qty, p_kind, p_ref, p_cost, p_note);
end;
$$;

create or replace function private.on_hand(p_item uuid)
returns numeric
language sql stable security definer set search_path = ''
as $$ select coalesce(sum(qty), 0) from public.stock_movements where item_id = p_item; $$;

grant execute on all functions in schema private to authenticated, service_role;

-- REQ-029: post a supplier bill. Stock up, weighted average cost, supplier due (Standard+).
create or replace function public.station_post_purchase(
  p_station uuid,
  p_supplier_id uuid,      -- Standard+ (null on Basic)
  p_supplier_name text,    -- Basic free text
  p_bill_no text,
  p_bill_date date,
  p_lines jsonb,           -- [{item_id, qty, unit_cost_paisa}]
  p_paid_now_paisa bigint default 0)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_id uuid;
  v_total bigint := 0;
  v_name text;
  l jsonb;
  v_item uuid;
  v_qty numeric;
  v_cost bigint;
  v_old_qty numeric;
  v_old_avg bigint;
  v_has_ledger boolean := private.has_feature(p_station, 'supplier_ledger');
begin
  if not private.has_role(p_station, array['owner','manager']::public.member_role[]) then
    perform private.fail('FORBIDDEN');
  end if;
  perform private.assert_can_write(p_station);
  if jsonb_array_length(coalesce(p_lines, '[]'::jsonb)) = 0 then
    perform private.fail('VALIDATION', 'Add at least one line');
  end if;

  if p_supplier_id is not null then
    if not v_has_ledger then perform private.fail('FEATURE_LOCKED', 'supplier_ledger'); end if;
    select name into v_name from public.suppliers where id = p_supplier_id and station_id = p_station;
    if v_name is null then perform private.fail('NOT_FOUND', 'Supplier not found'); end if;
  else
    v_name := nullif(trim(p_supplier_name), '');
    if v_name is null then perform private.fail('VALIDATION', 'Supplier name is required'); end if;
  end if;

  for l in select * from jsonb_array_elements(p_lines) loop
    v_qty := (l ->> 'qty')::numeric;
    v_cost := (l ->> 'unit_cost_paisa')::bigint;
    if v_qty is null or v_qty <= 0 or v_cost is null or v_cost < 0 then
      perform private.fail('VALIDATION', 'Each line needs a quantity above 0 and a price');
    end if;
    v_total := v_total + round(v_qty * v_cost)::bigint;
  end loop;
  if coalesce(p_paid_now_paisa, 0) < 0 or coalesce(p_paid_now_paisa, 0) > v_total then
    perform private.fail('VALIDATION', 'Amount paid must be between 0 and the bill total');
  end if;

  insert into public.purchases (station_id, supplier_id, supplier_name, bill_no, bill_date, total_paisa, paid_now_paisa)
  values (p_station, p_supplier_id, v_name, nullif(trim(p_bill_no), ''), coalesce(p_bill_date, current_date),
          v_total, coalesce(p_paid_now_paisa, 0))
  returning id into v_id;

  for l in select * from jsonb_array_elements(p_lines) loop
    v_item := (l ->> 'item_id')::uuid;
    v_qty := (l ->> 'qty')::numeric;
    v_cost := (l ->> 'unit_cost_paisa')::bigint;

    -- Weighted average: (old qty × old avg + new qty × new cost) / total qty.
    -- When stock is zero or negative the new cost becomes the average.
    v_old_qty := private.on_hand(v_item);
    select avg_cost_paisa into v_old_avg from public.item_costs where item_id = v_item;

    perform private.move_stock(p_station, v_item, v_qty, 'purchase', v_id, v_cost);
    insert into public.purchase_lines (station_id, purchase_id, item_id, qty, unit_cost_paisa)
    values (p_station, v_id, v_item, v_qty, v_cost);

    update public.item_costs set
      avg_cost_paisa = case when v_old_qty <= 0 then v_cost
                            else round((v_old_qty * coalesce(v_old_avg, 0) + v_qty * v_cost) / (v_old_qty + v_qty))::bigint end,
      last_cost_paisa = v_cost,
      updated_at = now()
    where item_id = v_item;
  end loop;

  if p_supplier_id is not null then
    insert into public.supplier_ledger (station_id, supplier_id, kind, amount_paisa, ref_id, note)
    values (p_station, p_supplier_id, 'purchase', v_total, v_id, 'Bill ' || coalesce(p_bill_no, ''));
    if coalesce(p_paid_now_paisa, 0) > 0 then
      insert into public.supplier_ledger (station_id, supplier_id, kind, amount_paisa, ref_id, method, note)
      values (p_station, p_supplier_id, 'payment', -p_paid_now_paisa, v_id, 'cash', 'Paid with bill');
    end if;
  end if;
  return v_id;
end;
$$;

-- REQ-029/REQ-042: reverse a posted purchase with a reason. Average cost is left as is.
create or replace function public.station_reverse_purchase(p_purchase uuid, p_reason text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  p public.purchases;
  l public.purchase_lines;
begin
  select * into p from public.purchases where id = p_purchase;
  if p.id is null or not private.has_role(p.station_id, array['owner','manager']::public.member_role[]) then
    perform private.fail('NOT_FOUND');
  end if;
  perform private.assert_can_write(p.station_id);
  if p.status = 'reversed' then perform private.fail('VALIDATION', 'Already reversed'); end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then
    perform private.fail('VALIDATION', 'A reason is required');
  end if;

  for l in select * from public.purchase_lines where purchase_id = p_purchase loop
    perform private.move_stock(p.station_id, l.item_id, -l.qty, 'purchase_reversal', p_purchase, l.unit_cost_paisa, p_reason);
  end loop;
  if p.supplier_id is not null then
    insert into public.supplier_ledger (station_id, supplier_id, kind, amount_paisa, ref_id, note)
    values (p.station_id, p.supplier_id, 'purchase_reversal', -p.total_paisa, p_purchase, p_reason);
    if p.paid_now_paisa > 0 then
      insert into public.supplier_ledger (station_id, supplier_id, kind, amount_paisa, ref_id, note)
      values (p.station_id, p.supplier_id, 'payment_reversal', p.paid_now_paisa, p_purchase, p_reason);
    end if;
  end if;
  update public.purchases set status = 'reversed', reversal_reason = trim(p_reason),
    reversed_at = now(), reversed_by = auth.uid()
  where id = p_purchase;
end;
$$;

-- REQ-030 (Standard+) -----------------------------------------------------------
create or replace function public.station_save_supplier(p_station uuid, p_id uuid, p_name text, p_phone text, p_active boolean default true)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_id uuid := p_id;
begin
  if not private.has_role(p_station, array['owner','manager']::public.member_role[]) then
    perform private.fail('FORBIDDEN');
  end if;
  perform private.assert_can_write(p_station, 'supplier_ledger');
  if length(trim(coalesce(p_name, ''))) < 2 then perform private.fail('VALIDATION', 'Supplier name is required'); end if;
  if exists (select 1 from public.suppliers where station_id = p_station and lower(name) = lower(trim(p_name))
             and id is distinct from p_id) then
    perform private.fail('VALIDATION', 'A supplier with this name exists');
  end if;
  if v_id is null then
    insert into public.suppliers (station_id, name, phone) values (p_station, trim(p_name), nullif(trim(p_phone), ''))
    returning id into v_id;
  else
    update public.suppliers set name = trim(p_name), phone = nullif(trim(p_phone), ''), active = coalesce(p_active, true)
    where id = v_id and station_id = p_station;
    if not found then perform private.fail('NOT_FOUND'); end if;
  end if;
  return v_id;
end;
$$;

create or replace function public.station_pay_supplier(
  p_supplier uuid, p_amount_paisa bigint, p_method text, p_reference text default null, p_note text default null)
returns bigint
language plpgsql security definer set search_path = ''
as $$
declare
  v_station uuid;
  v_id bigint;
begin
  select station_id into v_station from public.suppliers where id = p_supplier;
  if v_station is null or not private.has_role(v_station, array['owner','manager']::public.member_role[]) then
    perform private.fail('NOT_FOUND');
  end if;
  perform private.assert_can_write(v_station, 'supplier_ledger');
  if coalesce(p_amount_paisa, 0) <= 0 then perform private.fail('VALIDATION', 'Amount must be above 0'); end if;
  if p_method not in ('cash', 'bank', 'jazzcash', 'easypaisa', 'card', 'cheque') then
    perform private.fail('VALIDATION', 'Choose a payment method');
  end if;
  insert into public.supplier_ledger (station_id, supplier_id, kind, amount_paisa, method, reference, note)
  values (v_station, p_supplier, 'payment', -p_amount_paisa, p_method, nullif(trim(p_reference), ''), nullif(trim(p_note), ''))
  returning id into v_id;
  return v_id;
end;
$$;

-- Function grants -------------------------------------------------------------------
revoke execute on function
  public.station_save_item(uuid, jsonb, jsonb),
  public.station_set_item_cost(uuid, bigint),
  public.station_post_purchase(uuid, uuid, text, text, date, jsonb, bigint),
  public.station_reverse_purchase(uuid, text),
  public.station_save_supplier(uuid, uuid, text, text, boolean),
  public.station_pay_supplier(uuid, bigint, text, text, text)
from public, anon;
grant execute on function
  public.station_save_item(uuid, jsonb, jsonb),
  public.station_set_item_cost(uuid, bigint),
  public.station_post_purchase(uuid, uuid, text, text, date, jsonb, bigint),
  public.station_reverse_purchase(uuid, text),
  public.station_save_supplier(uuid, uuid, text, text, boolean),
  public.station_pay_supplier(uuid, bigint, text, text, text)
to authenticated;
