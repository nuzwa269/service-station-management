-- TASK-037 · REQ-026, REQ-027
-- Rework (comeback) jobs and warranty claims, linked to the original job.
-- Until invoices exist (Phase 4) the warranty period counts from the original job's delivery.

create or replace function private.new_job_from(
  p_parent public.job_cards, p_kind public.job_kind, p_parts_free boolean,
  p_odometer integer, p_fuel public.fuel_level, p_complaints text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_no integer;
  v_id uuid;
begin
  insert into public.job_counters (station_id) values (p_parent.station_id) on conflict do nothing;
  update public.job_counters set last_no = last_no + 1 where station_id = p_parent.station_id returning last_no into v_no;
  insert into public.job_cards (station_id, job_no, kind, parent_job_id, customer_id, vehicle_id, odometer_km,
                                fuel_level, complaints, parts_free)
  select p_parent.station_id, v_no, p_kind, p_parent.id, v.customer_id, p_parent.vehicle_id,
         coalesce(p_odometer, p_parent.odometer_km), coalesce(p_fuel, p_parent.fuel_level),
         nullif(trim(p_complaints), ''), coalesce(p_parts_free, false)
  from public.vehicles v where v.id = p_parent.vehicle_id
  returning id into v_id;
  insert into public.job_checklist_items (station_id, job_id, name, sort_order)
  select p_parent.station_id, v_id, t.name, t.sort_order from public.checklist_templates t
  where t.station_id = p_parent.station_id and t.active order by t.sort_order;
  perform private.log_job(p_parent.station_id, v_id, 'stage', null, 'intake',
    format('%s of job %s', initcap(p_kind::text), p_parent.job_no));
  return v_id;
end;
$$;
grant execute on all functions in schema private to authenticated, service_role;

-- REQ-026: labour is free; parts charged or free as chosen; counts against the original mechanics.
create or replace function public.station_create_rework(
  p_parent uuid, p_parts_free boolean, p_odometer integer, p_fuel public.fuel_level, p_complaints text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  j public.job_cards := private.job_for(p_parent, array['owner','manager','cashier']::public.member_role[]);
begin
  perform private.assert_can_write(j.station_id);
  if j.stage <> 'delivered' then perform private.fail('VALIDATION', 'Rework is created from a delivered job'); end if;
  if length(trim(coalesce(p_complaints, ''))) < 3 then perform private.fail('VALIDATION', 'Describe the problem'); end if;
  return private.new_job_from(j, 'rework', p_parts_free, p_odometer, p_fuel, p_complaints);
end;
$$;

-- REQ-027: warranty status of an original line.
create or replace function public.station_warranty_status(p_line uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  l public.job_lines;
  j public.job_cards;
  v_expires date;
begin
  select * into l from public.job_lines where id = p_line;
  if l.id is null then perform private.fail('NOT_FOUND'); end if;
  j := private.job_for(l.job_id, array['owner','manager','cashier']::public.member_role[]);
  if j.stage <> 'delivered' or l.status <> 'approved' or l.warranty_days <= 0 then
    return jsonb_build_object('valid', false, 'reason', 'No warranty on this line');
  end if;
  v_expires := (j.delivered_at at time zone 'Asia/Karachi')::date + l.warranty_days;
  return jsonb_build_object(
    'valid', current_date <= v_expires,
    'expires_on', v_expires,
    'days_left', greatest(v_expires - (now() at time zone 'Asia/Karachi')::date, 0),
    'sold_on', (j.delivered_at at time zone 'Asia/Karachi')::date,
    'original_job_no', j.job_no);
end;
$$;

-- REQ-027: claim. Inside the period: labour free, replacement part charged 0. The faulty
-- part may go back to the supplier, which lowers the supplier due (Standard+).
create or replace function public.station_create_warranty_claim(
  p_line uuid, p_odometer integer, p_fuel public.fuel_level, p_complaints text,
  p_return_supplier uuid default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  l public.job_lines;
  j public.job_cards;
  w jsonb;
  v_job uuid;
  v_cost bigint;
begin
  select * into l from public.job_lines where id = p_line;
  if l.id is null then perform private.fail('NOT_FOUND'); end if;
  j := private.job_for(l.job_id, array['owner','manager','cashier']::public.member_role[]);
  perform private.assert_can_write(j.station_id);
  w := public.station_warranty_status(p_line);
  if not (w ->> 'valid')::boolean then
    if w ? 'expires_on' then
      perform private.fail('WARRANTY_EXPIRED', format('Warranty expired on %s', to_char((w ->> 'expires_on')::date, 'DD-MM-YYYY')));
    end if;
    perform private.fail('VALIDATION', w ->> 'reason');
  end if;

  v_job := private.new_job_from(j, 'warranty', true, p_odometer, p_fuel,
    coalesce(nullif(trim(p_complaints), ''), 'Warranty claim: ' || l.description));
  insert into public.job_lines (station_id, job_id, kind, item_id, description, qty, unit_price_paisa, status,
                                warranty_days, warranty_of_line)
  values (j.station_id, v_job, l.kind, l.item_id, l.description || ' (warranty)', l.qty, 0, 'estimate', l.warranty_days, l.id);

  if p_return_supplier is not null then
    if l.kind <> 'part' then perform private.fail('VALIDATION', 'Only parts go back to a supplier'); end if;
    if not private.has_feature(j.station_id, 'supplier_ledger') then perform private.fail('FEATURE_LOCKED', 'supplier_ledger'); end if;
    if not exists (select 1 from public.suppliers where id = p_return_supplier and station_id = j.station_id) then
      perform private.fail('NOT_FOUND', 'Supplier not found');
    end if;
    select avg_cost_paisa into v_cost from public.item_costs where item_id = l.item_id;
    if coalesce(v_cost, 0) > 0 then
      insert into public.supplier_ledger (station_id, supplier_id, kind, amount_paisa, ref_id, note)
      values (j.station_id, p_return_supplier, 'return', -round(v_cost * l.qty)::bigint, v_job,
              'Faulty part returned: ' || l.description);
    end if;
  end if;
  return v_job;
end;
$$;

revoke execute on function
  public.station_create_rework(uuid, boolean, integer, public.fuel_level, text),
  public.station_warranty_status(uuid),
  public.station_create_warranty_claim(uuid, integer, public.fuel_level, text, uuid)
from public, anon;
grant execute on function
  public.station_create_rework(uuid, boolean, integer, public.fuel_level, text),
  public.station_warranty_status(uuid),
  public.station_create_warranty_claim(uuid, integer, public.fuel_level, text, uuid)
to authenticated;
