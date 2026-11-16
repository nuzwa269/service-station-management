-- SMS gateway (login codes from the platform's own Android phone) for the Supabase dashboard
-- SQL Editor on STAGING. Run once, AFTER dashboard_phase9.sql.

-- ===== supabase/migrations/20261122000023_sms_gateway.sql =====
-- TASK-005 · REQ-001, REQ-047 — login codes by SMS through the platform's own Android
-- "SMS gateway" phone (a SIM with an SMS bundle), instead of a paid SMS aggregator.
--
-- Supabase Auth → Send SMS hook → Edge Function send-sms → svc_sms_enqueue() → this queue.
-- The gateway phone polls the sms-gateway Edge Function (shared GATEWAY_SECRET), which claims
-- due messages with svc_sms_claim(), sends them from the SIM, and reports with svc_sms_report().
-- Codes older than 5 minutes are never sent (the OTP has expired by then).

create table private.sms_queue (
  id         bigint generated always as identity primary key,
  phone      text not null check (phone ~ '^\+?[0-9]{10,15}$'),
  body       text not null check (length(body) between 1 and 320),
  kind       text not null default 'otp',
  status     text not null default 'queued' check (status in ('queued', 'sending', 'sent', 'failed', 'expired', 'dropped')),
  attempts   integer not null default 0,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index sms_queue_due_idx on private.sms_queue(created_at) where status in ('queued', 'sending');
create index sms_queue_phone_idx on private.sms_queue(phone, created_at desc);

-- Last contact from each gateway phone (shown to the platform admin).
create table private.sms_gateways (
  device     text primary key,
  last_seen  timestamptz not null default now(),
  info       jsonb not null default '{}'::jsonb
);

alter table private.sms_queue    enable row level security;
alter table private.sms_gateways enable row level security;
revoke all on private.sms_queue, private.sms_gateways from public, anon, authenticated;

-- Called by the send-sms hook. Protects the SIM bundle: at most 5 messages per number per hour.
create or replace function public.svc_sms_enqueue(p_phone text, p_body text, p_kind text default 'otp')
returns text
language plpgsql security definer set search_path = ''
as $$
declare v_phone text := '+' || regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
begin
  if v_phone !~ '^\+[0-9]{10,15}$' then perform private.fail('VALIDATION', 'Bad phone number'); end if;
  if (select count(*) from private.sms_queue where phone = v_phone and created_at > now() - interval '1 hour') >= 5 then
    insert into private.sms_queue (phone, body, kind, status, last_error)
    values (v_phone, left(p_body, 320), coalesce(p_kind, 'otp'), 'dropped', 'More than 5 messages to this number in an hour');
    return 'dropped';
  end if;
  insert into private.sms_queue (phone, body, kind) values (v_phone, left(p_body, 320), coalesce(p_kind, 'otp'));
  return 'queued';
end;
$$;

-- Called by the gateway phone (through sms-gateway). Expires stale codes, then hands out due
-- messages; a message stuck in 'sending' for 2 minutes is offered again (max 3 attempts).
create or replace function public.svc_sms_claim(p_device text, p_limit integer default 10, p_info jsonb default '{}'::jsonb)
returns table (id bigint, phone text, body text)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
begin
  insert into private.sms_gateways (device, last_seen, info) values (left(coalesce(p_device, 'gateway'), 80), now(), coalesce(p_info, '{}'))
  on conflict (device) do update set last_seen = now(), info = excluded.info;

  update private.sms_queue q set status = 'expired', updated_at = now()
  where q.status in ('queued', 'sending') and q.kind = 'otp' and q.created_at < now() - interval '5 minutes';

  return query
  with due as (
    select q.id from private.sms_queue q
    where (q.status = 'queued' or (q.status = 'sending' and q.updated_at < now() - interval '2 minutes'))
      and q.attempts < 3
    order by q.created_at
    limit greatest(least(coalesce(p_limit, 10), 50), 1)
    for update skip locked
  )
  update private.sms_queue q set status = 'sending', attempts = q.attempts + 1, updated_at = now()
  from due where q.id = due.id
  returning q.id, q.phone, q.body;
end;
$$;

create or replace function public.svc_sms_report(p_id bigint, p_ok boolean, p_error text default null)
returns void
language sql security definer set search_path = ''
as $$
  update private.sms_queue
  set status = case when p_ok then 'sent' when attempts >= 3 then 'failed' else 'queued' end,
      last_error = case when p_ok then null else left(p_error, 300) end,
      updated_at = now()
  where id = p_id and status = 'sending';
$$;

-- Platform admin: is the gateway alive and is it keeping up?
create or replace function public.admin_sms_status()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform private.assert_super_admin();
  return jsonb_build_object(
    'last_seen', (select max(last_seen) from private.sms_gateways),
    'devices', (select coalesce(jsonb_agg(jsonb_build_object('device', device, 'last_seen', last_seen, 'info', info) order by last_seen desc), '[]')
                from private.sms_gateways),
    'waiting', (select count(*) from private.sms_queue where status in ('queued', 'sending')),
    'sent_today', (select count(*) from private.sms_queue where status = 'sent' and updated_at >= date_trunc('day', now() at time zone 'Asia/Karachi') at time zone 'Asia/Karachi'),
    'failed_today', (select count(*) from private.sms_queue where status in ('failed', 'expired', 'dropped')
                       and updated_at >= date_trunc('day', now() at time zone 'Asia/Karachi') at time zone 'Asia/Karachi')
  );
end;
$$;

revoke execute on function
  public.svc_sms_enqueue(text, text, text), public.svc_sms_claim(text, integer, jsonb), public.svc_sms_report(bigint, boolean, text)
from public, anon, authenticated;
grant execute on function
  public.svc_sms_enqueue(text, text, text), public.svc_sms_claim(text, integer, jsonb), public.svc_sms_report(bigint, boolean, text)
to service_role;
revoke execute on function public.admin_sms_status() from public, anon;
grant execute on function public.admin_sms_status() to authenticated;
