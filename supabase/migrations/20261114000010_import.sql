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
