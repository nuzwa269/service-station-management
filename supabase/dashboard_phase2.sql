-- Phase 2 migrations (inventory, approvals, customers, import) for the Supabase dashboard SQL Editor.
-- Run once, AFTER dashboard_setup.sql (Phase 1) was run.

-- ===== migrations/20261114000007_inventory.sql =====
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

-- ===== migrations/20261114000008_approvals.sql =====
-- TASK-023, TASK-024 · REQ-057, REQ-032 (and later REQ-037, REQ-039, REQ-041)
-- Approvals engine. Standard+: requests go to the inbox, decided by the owner or a
-- manager with approval rights (on by default). Basic: no inbox, so restricted
-- actions are done only under the owner's login (PRD §3, DEC-027).

alter table public.stations add column manager_can_approve boolean not null default true;

create type public.approval_type as enum ('discount', 'refund', 'stock_adjustment', 'credit_release');
create type public.approval_status as enum ('pending', 'approved', 'rejected');
create type public.adjustment_reason as enum ('count_difference', 'damaged', 'expired', 'other');

create table public.approval_requests (
  id            uuid primary key default gen_random_uuid(),
  station_id    uuid not null references public.stations(id) on delete cascade,
  type          public.approval_type not null,
  status        public.approval_status not null default 'pending',
  requested_by  uuid not null default auth.uid() references public.profiles(id),
  record_table  text,
  record_id     uuid,
  amount_paisa  bigint,
  reason        text not null,
  payload       jsonb not null default '{}'::jsonb,
  decided_by    uuid references public.profiles(id),
  decided_at    timestamptz,
  decision_note text,
  created_at    timestamptz not null default now()
);
create index approval_requests_pending_idx on public.approval_requests(station_id, created_at desc) where status = 'pending';

-- Who may approve: the owner; or a manager when delegated and the plan has the inbox.
create or replace function private.can_approve(p_station uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select private.has_role(p_station, array['owner']::public.member_role[])
      or (private.has_role(p_station, array['manager']::public.member_role[])
          and private.has_feature(p_station, 'approvals_inbox')
          and coalesce((select manager_can_approve from public.stations where id = p_station), false));
$$;
grant execute on all functions in schema private to authenticated, service_role;

alter table public.approval_requests enable row level security;

-- Approvers see the station's requests; everyone sees their own.
create policy approval_requests_read on public.approval_requests for select to authenticated
  using (requested_by = auth.uid() or private.can_approve(station_id) or private.has_support_grant(station_id));
revoke insert, update, delete on public.approval_requests from anon, authenticated;

create trigger audit_approval_requests after insert or update on public.approval_requests
  for each row execute function private.audit_row();

-- Generic request creator used by later phases (discount, refund, credit release).
create or replace function private.create_approval(
  p_station uuid, p_type public.approval_type, p_record_table text, p_record_id uuid,
  p_amount bigint, p_reason text, p_payload jsonb default '{}'::jsonb)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_id uuid;
begin
  if not private.has_feature(p_station, 'approvals_inbox') then
    perform private.fail('OWNER_ONLY', 'On the Basic plan only the owner can do this. Ask the owner to log in.');
  end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then
    perform private.fail('VALIDATION', 'A reason is required');
  end if;
  insert into public.approval_requests (station_id, type, record_table, record_id, amount_paisa, reason, payload)
  values (p_station, p_type, p_record_table, p_record_id, p_amount, trim(p_reason), coalesce(p_payload, '{}'::jsonb))
  returning id into v_id;
  return v_id;
end;
$$;

-- Applies an approved request. Each type adds its effect here as later phases arrive.
create or replace function private.apply_approval(r public.approval_requests)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if r.type = 'stock_adjustment' then
    perform private.move_stock(r.station_id, (r.payload ->> 'item_id')::uuid, (r.payload ->> 'qty')::numeric,
                               'adjustment', r.id, null, r.reason);
  end if;
  -- discount / refund / credit_release: the waiting action checks for an approved request (Phase 4).
end;
$$;
grant execute on all functions in schema private to authenticated, service_role;

-- REQ-032: request a stock adjustment. The owner's own adjustment applies at once
-- (and is logged as an approved request); others wait for approval.
create or replace function public.station_request_stock_adjustment(
  p_station uuid, p_item uuid, p_qty numeric, p_reason public.adjustment_reason, p_note text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_id uuid;
  v_text text;
  v_unit public.item_unit;
  r public.approval_requests;
begin
  if not private.has_role(p_station, array['owner','manager','cashier']::public.member_role[]) then
    perform private.fail('FORBIDDEN');
  end if;
  perform private.assert_can_write(p_station);
  select unit into v_unit from public.items where id = p_item and station_id = p_station;
  if v_unit is null then perform private.fail('NOT_FOUND', 'Item not found'); end if;
  if v_unit = 'kit' then perform private.fail('VALIDATION', 'Adjust the kit''s components instead'); end if;
  if coalesce(p_qty, 0) = 0 or not private.valid_qty(v_unit, p_qty) then
    perform private.fail('VALIDATION', 'Enter a + or − quantity (whole numbers; 2 decimals for litres)');
  end if;
  if p_reason = 'other' and length(trim(coalesce(p_note, ''))) < 3 then
    perform private.fail('VALIDATION', 'Add a note for "other"');
  end if;
  v_text := replace(p_reason::text, '_', ' ') || coalesce(': ' || nullif(trim(p_note), ''), '');

  if private.has_role(p_station, array['owner']::public.member_role[]) then
    insert into public.approval_requests (station_id, type, status, record_table, record_id, reason, payload,
                                          decided_by, decided_at, decision_note)
    values (p_station, 'stock_adjustment', 'approved', 'items', p_item, v_text,
            jsonb_build_object('item_id', p_item, 'qty', p_qty, 'reason', p_reason),
            auth.uid(), now(), 'Owner adjustment')
    returning * into r;
    perform private.apply_approval(r);
    return r.id;
  end if;

  v_id := private.create_approval(p_station, 'stock_adjustment', 'items', p_item, null, v_text,
                                  jsonb_build_object('item_id', p_item, 'qty', p_qty, 'reason', p_reason));
  return v_id;
end;
$$;

-- REQ-057: approve or reject. Final; nobody decides their own request.
create or replace function public.station_decide_approval(p_request uuid, p_approve boolean, p_note text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.approval_requests;
begin
  select * into r from public.approval_requests where id = p_request for update;
  if r.id is null or not private.can_approve(r.station_id) then
    perform private.fail('NOT_FOUND');
  end if;
  perform private.assert_can_write(r.station_id);
  if r.status <> 'pending' then
    perform private.fail('VALIDATION', 'This request was already decided');
  end if;
  if r.requested_by = auth.uid() then
    perform private.fail('VALIDATION', 'You cannot decide your own request');
  end if;

  update public.approval_requests
     set status = case when p_approve then 'approved'::public.approval_status else 'rejected'::public.approval_status end,
         decided_by = auth.uid(), decided_at = now(), decision_note = nullif(trim(p_note), '')
   where id = p_request
  returning * into r;

  if p_approve then
    perform private.apply_approval(r);
  end if;
end;
$$;

create or replace function public.station_set_manager_can_approve(p_station uuid, p_allowed boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then
    perform private.fail('FORBIDDEN');
  end if;
  perform private.assert_station_open(p_station);
  update public.stations set manager_can_approve = coalesce(p_allowed, true) where id = p_station;
end;
$$;

-- Inbox rows with names, for SCR-012 / SCR-034.
create or replace view public.approval_inbox
with (security_invoker = true)
as
select r.*, rq.full_name as requested_by_name, dc.full_name as decided_by_name,
       i.name as item_name, i.unit as item_unit
from public.approval_requests r
left join public.profiles rq on rq.id = r.requested_by
left join public.profiles dc on dc.id = r.decided_by
left join public.items i on i.id = r.record_id and r.record_table = 'items';
grant select on public.approval_inbox to authenticated;

revoke execute on function
  public.station_request_stock_adjustment(uuid, uuid, numeric, public.adjustment_reason, text),
  public.station_decide_approval(uuid, boolean, text),
  public.station_set_manager_can_approve(uuid, boolean)
from public, anon;
grant execute on function
  public.station_request_stock_adjustment(uuid, uuid, numeric, public.adjustment_reason, text),
  public.station_decide_approval(uuid, boolean, text),
  public.station_set_manager_can_approve(uuid, boolean)
to authenticated;

-- ===== migrations/20261114000009_customers.sql =====
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

-- ===== migrations/20261114000010_import.sql =====
-- TASK-027 · REQ-034
-- Excel import: the app reads the sheet and sends rows as JSON; the database validates
-- each row and returns imported / rejected counts with a reason per rejected row.
-- Re-importing the same item code (or customer mobile) updates instead of duplicating.

-- Items: [{row, code, name, barcode, category, unit, selling_price, purchase_price, min_stock, opening_qty, warranty_days}]
-- Prices are in rupees (as typed in Excel); stored as paisa.
create or replace function public.station_import_items(p_station uuid, p_rows jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  r jsonb;
  v_row integer;
  v_id uuid;
  v_exists boolean;
  v_unit public.item_unit;
  v_open numeric;
  v_cost bigint;
  v_added integer := 0;
  v_updated integer := 0;
  v_rejected jsonb := '[]'::jsonb;
  v_reason text;
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then
    perform private.fail('FORBIDDEN');
  end if;
  perform private.assert_can_write(p_station);
  if jsonb_array_length(coalesce(p_rows, '[]'::jsonb)) > 5000 then
    perform private.fail('VALIDATION', 'At most 5,000 rows per import');
  end if;

  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    v_row := coalesce((r ->> 'row')::integer, 0);
    v_reason := null;
    begin
      -- Each row in its own sub-transaction: a bad row is rejected, the rest continue.
      if length(trim(coalesce(r ->> 'name', ''))) < 2 then v_reason := 'Name missing';
      elsif length(trim(coalesce(r ->> 'code', ''))) < 1 then v_reason := 'Code missing';
      elsif lower(coalesce(nullif(trim(r ->> 'unit'), ''), 'piece')) not in ('piece', 'litre', 'kit') then
        v_reason := 'Unit must be piece, litre or kit';
      elsif lower(coalesce(nullif(trim(r ->> 'unit'), ''), 'piece')) = 'kit' then
        v_reason := 'Kits must be created in the app (they need components)';
      elsif (r ->> 'selling_price') is not null and (r ->> 'selling_price') !~ '^\s*[0-9]+(\.[0-9]{1,2})?\s*$' then
        v_reason := 'Selling price must be a number';
      elsif (r ->> 'purchase_price') is not null and (r ->> 'purchase_price') !~ '^\s*[0-9]+(\.[0-9]{1,2})?\s*$' then
        v_reason := 'Purchase price must be a number';
      elsif (r ->> 'opening_qty') is not null and (r ->> 'opening_qty') !~ '^\s*-?[0-9]+(\.[0-9]{1,3})?\s*$' then
        v_reason := 'Opening quantity must be a number';
      end if;

      if v_reason is null then
        v_unit := lower(coalesce(nullif(trim(r ->> 'unit'), ''), 'piece'))::public.item_unit;
        v_open := coalesce(nullif(trim(r ->> 'opening_qty'), '')::numeric, 0);
        if not private.valid_qty(v_unit, v_open) then
          v_reason := case when v_unit = 'litre' then 'Litres allow at most 2 decimals' else 'Quantity must be a whole number' end;
        end if;
      end if;

      if v_reason is not null then
        v_rejected := v_rejected || jsonb_build_object('row', v_row, 'reason', v_reason);
        continue;
      end if;

      select id into v_id from public.items where station_id = p_station and code = trim(r ->> 'code');
      v_exists := v_id is not null;

      v_id := public.station_save_item(p_station, jsonb_build_object(
        'id', v_id,
        'code', trim(r ->> 'code'),
        'name', trim(r ->> 'name'),
        'barcode', r ->> 'barcode',
        'category', r ->> 'category',
        'unit', v_unit,
        'is_bulk', v_unit = 'litre',
        'selling_price_paisa', round(coalesce(nullif(trim(r ->> 'selling_price'), '')::numeric, 0) * 100),
        'min_stock', coalesce(nullif(trim(r ->> 'min_stock'), '')::numeric, 0),
        'warranty_days', coalesce(nullif(trim(r ->> 'warranty_days'), '')::integer, 0)));

      v_cost := round(coalesce(nullif(trim(r ->> 'purchase_price'), '')::numeric, 0) * 100);
      if nullif(trim(r ->> 'purchase_price'), '') is not null then
        update public.item_costs set avg_cost_paisa = v_cost, last_cost_paisa = v_cost, updated_at = now()
        where item_id = v_id;
      end if;

      -- Opening stock only for new items; existing items keep their movement history.
      if not v_exists and v_open <> 0 then
        perform private.move_stock(p_station, v_id, v_open, 'opening', null, v_cost, 'Excel import');
      end if;

      if v_exists then v_updated := v_updated + 1; else v_added := v_added + 1; end if;
    exception when others then
      get stacked diagnostics v_reason = pg_exception_detail;
      v_rejected := v_rejected || jsonb_build_object('row', v_row, 'reason', coalesce(nullif(v_reason, ''), sqlerrm));
    end;
  end loop;

  return jsonb_build_object('added', v_added, 'updated', v_updated,
                            'rejected', jsonb_array_length(v_rejected), 'rejected_rows', v_rejected);
end;
$$;

-- Customers and vehicles: [{row, name, mobile, email, address, plate, make, model, year, colour}]
create or replace function public.station_import_customers(p_station uuid, p_rows jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  r jsonb;
  v_row integer;
  v_customer uuid;
  v_vehicle uuid;
  v_mobile text;
  v_plate text;
  v_exists boolean;
  v_added integer := 0;
  v_updated integer := 0;
  v_rejected jsonb := '[]'::jsonb;
  v_reason text;
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then
    perform private.fail('FORBIDDEN');
  end if;
  perform private.assert_can_write(p_station);
  if jsonb_array_length(coalesce(p_rows, '[]'::jsonb)) > 5000 then
    perform private.fail('VALIDATION', 'At most 5,000 rows per import');
  end if;

  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    v_row := coalesce((r ->> 'row')::integer, 0);
    v_mobile := private.normalize_pk_mobile(r ->> 'mobile');
    v_plate := case when nullif(trim(r ->> 'plate'), '') is null then null else private.normalize_plate(r ->> 'plate') end;
    if length(trim(coalesce(r ->> 'name', ''))) < 2 then
      v_rejected := v_rejected || jsonb_build_object('row', v_row, 'reason', 'Name missing'); continue;
    elsif v_mobile is null then
      v_rejected := v_rejected || jsonb_build_object('row', v_row, 'reason', 'Mobile must be like 0300-1234567'); continue;
    elsif nullif(trim(r ->> 'plate'), '') is not null and v_plate is null then
      v_rejected := v_rejected || jsonb_build_object('row', v_row, 'reason', 'Number plate is not valid'); continue;
    end if;
    begin
      select id into v_customer from public.customers where station_id = p_station and mobile = v_mobile;
      v_exists := v_customer is not null;
      v_customer := public.station_save_customer(p_station, v_customer, r ->> 'name', v_mobile, r ->> 'email', r ->> 'address');
      if v_plate is not null then
        select id into v_vehicle from public.vehicles where station_id = p_station and plate = v_plate;
        perform public.station_save_vehicle(p_station, v_vehicle, v_customer, v_plate,
          r ->> 'make', r ->> 'model', nullif(trim(r ->> 'year'), '')::integer, r ->> 'colour');
      end if;
      if v_exists then v_updated := v_updated + 1; else v_added := v_added + 1; end if;
    exception when others then
      get stacked diagnostics v_reason = pg_exception_detail;
      v_rejected := v_rejected || jsonb_build_object('row', v_row, 'reason', coalesce(nullif(v_reason, ''), sqlerrm));
    end;
  end loop;

  return jsonb_build_object('added', v_added, 'updated', v_updated,
                            'rejected', jsonb_array_length(v_rejected), 'rejected_rows', v_rejected);
end;
$$;

revoke execute on function public.station_import_items(uuid, jsonb), public.station_import_customers(uuid, jsonb)
  from public, anon;
grant execute on function public.station_import_items(uuid, jsonb), public.station_import_customers(uuid, jsonb)
  to authenticated;
