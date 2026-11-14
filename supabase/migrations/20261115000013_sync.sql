-- TASK-034 · REQ-023 · DEC-031 (own sync engine; PowerSync later behind the same interface)
-- sync_pull: everything a mechanic's phone needs offline — assigned open jobs, their
--            checklist and part lines (no prices), and the item list (name, unit, stock).
-- sync_apply: queued phone changes, applied in order through the same rules as online.
--   * idempotent by client_change_id (a repeat is reported as "duplicate")
--   * last change wins by client time; the loser is kept in history and managers are told
--   * changes refused because the station is read-only come back as "held" (kept on the phone)

create table public.sync_changes (
  client_change_id uuid primary key,
  station_id       uuid not null references public.stations(id) on delete cascade,
  user_id          uuid not null default auth.uid(),
  op               text not null,
  status           text not null,       -- applied | conflict | rejected
  message          text,
  client_time      timestamptz,
  applied_at       timestamptz not null default now()
);
alter table public.sync_changes enable row level security;
create policy sync_changes_read on public.sync_changes for select to authenticated
  using (user_id = auth.uid() or private.has_role(station_id, array['owner','manager']::public.member_role[]));
revoke insert, update, delete on public.sync_changes from anon, authenticated;

create or replace function public.sync_pull(p_station uuid, p_since timestamptz default null)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_jobs uuid[];
begin
  if not private.has_role(p_station, array['owner','manager','cashier','mechanic']::public.member_role[]) then
    perform private.fail('FORBIDDEN');
  end if;
  -- Full snapshot of the (small) open set each time; p_since is reserved for delta pulls.
  select coalesce(array_agg(j.id), '{}') into v_jobs
  from public.job_cards j
  join public.job_assignments a on a.job_id = j.id and a.user_id = v_uid
  where j.station_id = p_station and j.stage in ('approved', 'in_progress', 'quality_check');

  return jsonb_build_object(
    'server_time', now(),
    'jobs', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', j.id, 'job_no', j.job_no, 'kind', j.kind, 'stage', j.stage, 'complaints', j.complaints,
        'odometer_km', j.odometer_km, 'fuel_level', j.fuel_level, 'qc_note', j.qc_note,
        'expected_delivery', j.expected_delivery, 'updated_at', j.updated_at,
        'customer_name', c.name, 'plate', v.plate, 'make', v.make, 'model', v.model, 'year', v.year)
        order by j.job_no)
      from public.job_cards j
      join public.customers c on c.id = j.customer_id
      join public.vehicles v on v.id = j.vehicle_id
      where j.id = any(v_jobs)), '[]'::jsonb),
    'checklist', coalesce((
      select jsonb_agg(jsonb_build_object('id', k.id, 'job_id', k.job_id, 'name', k.name, 'sort_order', k.sort_order,
                                          'status', k.status, 'note', k.note, 'changed_at', k.changed_at)
                       order by k.job_id, k.sort_order)
      from public.job_checklist_items k where k.job_id = any(v_jobs)), '[]'::jsonb),
    -- No prices for mechanics (REQ-002).
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object('id', l.id, 'job_id', l.job_id, 'kind', l.kind, 'item_id', l.item_id,
                                          'description', l.description, 'qty', l.qty, 'status', l.status,
                                          'mine', l.added_by = v_uid) order by l.created_at)
      from public.job_lines l where l.job_id = any(v_jobs) and l.status not in ('removed', 'rejected')), '[]'::jsonb),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object('id', i.id, 'code', i.code, 'name', i.name, 'unit', i.unit,
                                          'barcode', i.barcode, 'on_hand', s.on_hand) order by i.name)
      from public.items i join public.item_stock s on s.item_id = i.id
      where i.station_id = p_station and i.active), '[]'::jsonb));
end;
$$;

-- Last stage change time for the conflict rule (client time when it came from a phone).
create or replace function private.last_stage_time(p_job uuid)
returns timestamptz
language sql stable security definer set search_path = ''
as $$
  select max(coalesce(h.client_time, h.created_at)) from public.job_history h
  where h.job_id = p_job and h.field in ('stage', 'qc') and not h.conflict;
$$;
grant execute on all functions in schema private to authenticated, service_role;

-- p_changes: [{client_change_id, client_time, op, args}] in the order they were made.
--   op 'check'       args {check_id, status, note}
--   op 'stage'       args {job_id, stage}
--   op 'part_add'    args {line_id, job_id, item_id, qty}
--   op 'part_remove' args {line_id}
create or replace function public.sync_apply(p_station uuid, p_changes jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  ch jsonb;
  a jsonb;
  v_id uuid;
  v_time timestamptz;
  v_op text;
  v_status text;
  v_msg text;
  v_detail text;
  v_out jsonb := '[]'::jsonb;
  j public.job_cards;
begin
  if not private.has_role(p_station, array['owner','manager','cashier','mechanic']::public.member_role[]) then
    perform private.fail('FORBIDDEN');
  end if;
  if jsonb_array_length(coalesce(p_changes, '[]'::jsonb)) > 500 then
    perform private.fail('VALIDATION', 'At most 500 changes per sync');
  end if;

  for ch in select * from jsonb_array_elements(coalesce(p_changes, '[]'::jsonb)) loop
    v_id := (ch ->> 'client_change_id')::uuid;
    v_time := coalesce((ch ->> 'client_time')::timestamptz, now());
    v_op := ch ->> 'op';
    a := coalesce(ch -> 'args', '{}'::jsonb);
    v_msg := null;

    if exists (select 1 from public.sync_changes where client_change_id = v_id) then
      v_out := v_out || jsonb_build_object('client_change_id', v_id, 'status', 'duplicate');
      continue;
    end if;

    begin
      -- A phone clock far in the future must not win every conflict.
      if v_time > now() + interval '5 minutes' then v_time := now(); end if;

      if v_op = 'check' then
        v_status := private.set_check((a ->> 'check_id')::uuid, (a ->> 'status')::public.check_status, a ->> 'note', v_time, 'sync');
      elsif v_op = 'stage' then
        select * into j from public.job_cards where id = (a ->> 'job_id')::uuid and station_id = p_station;
        if j.id is null then perform private.fail('NOT_FOUND', 'Job card not found'); end if;
        if private.last_stage_time(j.id) > v_time then
          perform private.log_job(p_station, j.id, 'stage', j.stage::text, a ->> 'stage',
            'Offline stage change lost to a later change', v_time, 'sync', true);
          perform private.notify(p_station, null, 'conflict', 'Offline change overwritten',
            format('Job %s: stage %s from a phone was older than the current %s', j.job_no, a ->> 'stage', j.stage), j.id);
          v_status := 'conflict';
        else
          perform private.set_stage(j.id, (a ->> 'stage')::public.job_stage, null, v_time, 'sync');
          v_status := 'applied';
        end if;
      elsif v_op = 'part_add' then
        perform private.add_line((a ->> 'job_id')::uuid, 'part', (a ->> 'item_id')::uuid, null,
          (a ->> 'qty')::numeric, null, (a ->> 'line_id')::uuid, null, v_time, 'sync');
        v_status := 'applied';
      elsif v_op = 'part_remove' then
        perform private.remove_line((a ->> 'line_id')::uuid, v_time, 'sync');
        v_status := 'applied';
      else
        perform private.fail('VALIDATION', 'Unknown change type ' || coalesce(v_op, ''));
      end if;
    exception when others then
      get stacked diagnostics v_detail = pg_exception_detail;
      if sqlerrm = 'READ_ONLY' then
        -- Not recorded: the phone keeps it and retries when the plan is active again (REQ-009).
        v_out := v_out || jsonb_build_object('client_change_id', v_id, 'status', 'held', 'message', v_detail);
        continue;
      end if;
      v_status := 'rejected';
      v_msg := coalesce(nullif(v_detail, ''), sqlerrm);
    end;

    insert into public.sync_changes (client_change_id, station_id, op, status, message, client_time)
    values (v_id, p_station, coalesce(v_op, '?'), v_status, v_msg, v_time);
    v_out := v_out || jsonb_build_object('client_change_id', v_id, 'status', v_status, 'message', v_msg);
  end loop;
  return v_out;
end;
$$;

revoke execute on function public.sync_pull(uuid, timestamptz), public.sync_apply(uuid, jsonb) from public, anon;
grant execute on function public.sync_pull(uuid, timestamptz), public.sync_apply(uuid, jsonb) to authenticated;
