-- TASK-047…052 · REQ-007, REQ-008, REQ-009, REQ-010, REQ-012, REQ-013
-- Subscription payments (wallet/card through a provider webhook; bank/cash verified by
-- the super admin), trial reminders and extension, upgrade with proration, downgrade at
-- renewal, suspension, super-admin tenant views, account closing and 90-day deletion.

alter table public.subscriptions
  add column pending_plan_code text references public.plans(code),   -- downgrade at next renewal
  add column suspended_from public.subscription_state,                -- state to return to
  add column suspend_reason text,
  add column closed_at timestamptz,
  add column deletion_due_at timestamptz;

create type public.sub_pay_method as enum ('jazzcash', 'easypaisa', 'card', 'bank', 'cash');
create type public.sub_pay_status as enum ('pending', 'pending_verification', 'succeeded', 'failed', 'rejected');
create sequence public.platform_receipt_no start 1;

create table public.subscription_payments (
  id               uuid primary key default gen_random_uuid(),
  station_id       uuid not null references public.stations(id) on delete cascade,
  kind             text not null check (kind in ('renewal', 'upgrade')),
  plan_code        text not null references public.plans(code),
  billing_cycle    public.billing_cycle not null,
  method           public.sub_pay_method not null,
  amount_paisa     bigint not null check (amount_paisa > 0),
  status           public.sub_pay_status not null,
  reference        text,
  receipt_path     text,                      -- bank receipt image in payment-receipts/<station>/...
  provider_txn_id  text unique,               -- wallet/card: idempotency key from the provider
  reject_reason    text,
  period_from      date,
  period_to        date,
  receipt_no       bigint,                    -- platform receipt number once paid
  created_by       uuid default auth.uid(),
  created_at       timestamptz not null default now(),
  decided_by       uuid,
  decided_at       timestamptz
);
create index subscription_payments_station_idx on public.subscription_payments(station_id, created_at desc);

-- Tombstones so the platform still lists deleted tenants ("Closed — deleted").
create table public.deleted_stations (
  station_id  uuid primary key,
  name        text not null,
  city        text,
  closed_at   timestamptz,
  deleted_at  timestamptz not null default now()
);

alter table public.subscription_payments enable row level security;
alter table public.deleted_stations      enable row level security;
create policy subscription_payments_read on public.subscription_payments for select to authenticated
  using (private.has_role(station_id, array['owner']::public.member_role[]) or private.is_super_admin());
create policy deleted_stations_read on public.deleted_stations for select to authenticated
  using (private.is_super_admin());
revoke insert, update, delete on public.subscription_payments, public.deleted_stations from anon, authenticated;
create trigger audit_subscription_payments after insert or update on public.subscription_payments
  for each row execute function private.audit_row();

-- Bank receipts: private bucket; owner uploads to <station_id>/, super admin reads.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('payment-receipts', 'payment-receipts', false, 5242880, array['image/png', 'image/jpeg', 'application/pdf'])
on conflict (id) do nothing;
create policy payment_receipts_owner_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'payment-receipts'
              and private.has_role(((storage.foldername(name))[1])::uuid, array['owner']::public.member_role[]));
create policy payment_receipts_read on storage.objects for select to authenticated
  using (bucket_id = 'payment-receipts'
         and (private.is_super_admin()
              or private.has_role(((storage.foldername(name))[1])::uuid, array['owner']::public.member_role[])));

-- Audit rows are skipped while a closed station is being purged (its rows are going away).
create or replace function private.audit_row()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_old jsonb := case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end;
  v_new jsonb := case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end;
  v_row jsonb := coalesce(v_new, v_old);
  v_station uuid;
  v_changes jsonb := '{}'::jsonb;
  k text;
begin
  if current_setting('app.purge_station', true) = 'on' then
    return coalesce(new, old);
  end if;
  v_station := coalesce((v_row ->> 'station_id')::uuid,
    case when tg_table_name = 'stations' then (v_row ->> 'id')::uuid end);
  if tg_op = 'UPDATE' then
    for k in select jsonb_object_keys(v_new) loop
      if (v_new -> k) is distinct from (v_old -> k) then
        v_changes := v_changes || jsonb_build_object(k, jsonb_build_object('old', v_old -> k, 'new', v_new -> k));
      end if;
    end loop;
    if v_changes = '{}'::jsonb then return new; end if;
  elsif tg_op = 'INSERT' then
    v_changes := jsonb_build_object('new', v_new);
  else
    v_changes := jsonb_build_object('old', v_old);
  end if;
  insert into public.audit_log (station_id, actor_id, table_name, record_id, action, changes)
  values (v_station, auth.uid(), tg_table_name, coalesce(v_row ->> 'id', v_row ->> 'station_id'), lower(tg_op), v_changes);
  return coalesce(new, old);
end;
$$;

-- Helpers ---------------------------------------------------------------------------------
create or replace function private.station_owner(p_station uuid)
returns uuid
language sql stable security definer set search_path = ''
as $$ select user_id from public.station_members where station_id = p_station and role = 'owner' limit 1; $$;

create or replace function private.cycle_interval(p_cycle public.billing_cycle)
returns interval
language sql immutable
as $$ select case when p_cycle = 'yearly' then interval '1 year' else interval '1 month' end; $$;

create or replace function private.plan_price(p_plan text, p_cycle public.billing_cycle)
returns bigint
language sql stable security definer set search_path = ''
as $$
  select (case when p_cycle = 'yearly' then yearly_price_pkr else monthly_price_pkr end)::bigint * 100
  from public.plans where code = p_plan;
$$;

-- Renewal date: end of the paid period, or the trial end.
create or replace function private.renewal_date(s public.subscriptions)
returns date
language sql immutable
as $$
  select ((case when s.state = 'trial' then s.trial_ends_at else coalesce(s.current_period_end, s.trial_ends_at) end)
          at time zone 'Asia/Karachi')::date;
$$;

-- REQ-008: start the new period from the renewal date (grace/read-only days count, TEST-104),
-- or from today when the station lapsed for more than a full cycle or was closed.
create or replace function private.activate_period(p_payment uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  p public.subscription_payments;
  s public.subscriptions;
  v_from date;
  v_to date;
  v_today date := (now() at time zone 'Asia/Karachi')::date;
begin
  select * into p from public.subscription_payments where id = p_payment for update;
  select * into s from public.subscriptions where station_id = p.station_id for update;

  if p.kind = 'upgrade' then
    update public.subscriptions set plan_code = p.plan_code, pending_plan_code = null, updated_at = now()
    where station_id = p.station_id;
    update public.subscription_payments set receipt_no = nextval('public.platform_receipt_no'),
      period_from = v_today, period_to = private.renewal_date(s) where id = p_payment;
    return;
  end if;

  v_from := private.renewal_date(s);
  if v_from is null or s.state = 'closed' or (v_from + private.cycle_interval(p.billing_cycle))::date <= v_today then
    v_from := v_today;
  end if;
  v_to := (v_from + private.cycle_interval(p.billing_cycle))::date;

  update public.subscriptions set
    state = 'active', plan_code = p.plan_code, billing_cycle = p.billing_cycle, pending_plan_code = null,
    current_period_end = (v_to::timestamp at time zone 'Asia/Karachi'),
    closed_at = null, deletion_due_at = null, suspended_from = null, updated_at = now()
  where station_id = p.station_id;
  update public.subscription_payments set period_from = v_from, period_to = v_to,
    receipt_no = nextval('public.platform_receipt_no') where id = p_payment;
end;
$$;

-- REQ-010: price difference for the remaining days of the current period.
create or replace function private.upgrade_amount(p_station uuid, p_new_plan text)
returns bigint
language plpgsql stable security definer set search_path = ''
as $$
declare
  s public.subscriptions;
  v_left integer;
  v_len integer;
  v_diff bigint;
begin
  select * into s from public.subscriptions where station_id = p_station;
  if s.state <> 'active' then return null; end if;
  v_left := private.renewal_date(s) - (now() at time zone 'Asia/Karachi')::date;
  v_len := case when s.billing_cycle = 'yearly' then 365 else 30 end;
  v_diff := private.plan_price(p_new_plan, s.billing_cycle) - private.plan_price(s.plan_code, s.billing_cycle);
  if v_left <= 0 or v_diff <= 0 then return 0; end if;
  return private.whole_rupees(round(v_diff * least(v_left, v_len)::numeric / v_len)::bigint);
end;
$$;
grant execute on all functions in schema private to authenticated, service_role;

-- Owner RPCs ------------------------------------------------------------------------------
create or replace function public.station_subscription_quote(p_station uuid, p_plan text, p_cycle public.billing_cycle)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare s public.subscriptions;
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then perform private.fail('FORBIDDEN'); end if;
  select * into s from public.subscriptions where station_id = p_station;
  return jsonb_build_object(
    'renewal_amount', private.plan_price(p_plan, p_cycle),
    'upgrade_amount', case when s.state = 'active' and p_cycle = s.billing_cycle then private.upgrade_amount(p_station, p_plan) end,
    'renewal_date', private.renewal_date(s),
    'current_plan', s.plan_code, 'state', s.state, 'cycle', s.billing_cycle, 'pending_plan', s.pending_plan_code);
end;
$$;

-- Bank transfer (reference + receipt image) or cash: waits for super-admin verification.
create or replace function public.station_submit_manual_payment(
  p_station uuid, p_kind text, p_plan text, p_cycle public.billing_cycle, p_method public.sub_pay_method,
  p_reference text, p_receipt_path text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  s public.subscriptions;
  v_amount bigint;
  v_id uuid;
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then perform private.fail('FORBIDDEN'); end if;
  if p_method not in ('bank', 'cash') then perform private.fail('VALIDATION', 'Wallet and card payments go through checkout'); end if;
  if p_kind not in ('renewal', 'upgrade') then perform private.fail('VALIDATION', 'Unknown payment type'); end if;
  if not exists (select 1 from public.plans where code = p_plan) then perform private.fail('NOT_FOUND', 'Plan not found'); end if;
  select * into s from public.subscriptions where station_id = p_station;
  if s.state = 'suspended' then perform private.fail('STATION_SUSPENDED'); end if;
  if p_method = 'bank' and (length(trim(coalesce(p_reference, ''))) < 3 or p_receipt_path is null) then
    perform private.fail('VALIDATION', 'Bank transfer needs the reference number and a receipt image');
  end if;
  if p_receipt_path is not null and split_part(p_receipt_path, '/', 1) <> p_station::text then
    perform private.fail('VALIDATION', 'Receipt must be uploaded to this station''s folder');
  end if;
  if exists (select 1 from public.subscription_payments where station_id = p_station and status = 'pending_verification') then
    perform private.fail('VALIDATION', 'A payment is already waiting for verification');
  end if;
  if p_kind = 'upgrade' then
    if s.state <> 'active' or p_cycle <> s.billing_cycle then perform private.fail('VALIDATION', 'Upgrade applies to an active plan on the same cycle'); end if;
    v_amount := private.upgrade_amount(p_station, p_plan);
    if coalesce(v_amount, 0) <= 0 then perform private.fail('VALIDATION', 'Choose a higher plan to upgrade'); end if;
  else
    v_amount := private.plan_price(p_plan, p_cycle);
  end if;
  insert into public.subscription_payments (station_id, kind, plan_code, billing_cycle, method, amount_paisa, status, reference, receipt_path)
  values (p_station, p_kind, p_plan, p_cycle, p_method, v_amount, 'pending_verification', nullif(trim(p_reference), ''), p_receipt_path)
  returning id into v_id;
  return v_id;
end;
$$;

-- Wallet / card: the app creates a pending payment, the checkout Edge Function sends the
-- customer to the provider, and the webhook confirms it (admin_confirm_provider_payment).
create or replace function public.station_start_checkout(
  p_station uuid, p_kind text, p_plan text, p_cycle public.billing_cycle, p_method public.sub_pay_method)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_amount bigint;
  v_id uuid;
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then perform private.fail('FORBIDDEN'); end if;
  if p_method not in ('jazzcash', 'easypaisa', 'card') then perform private.fail('VALIDATION', 'Use bank transfer or cash instead'); end if;
  v_amount := case when p_kind = 'upgrade' then private.upgrade_amount(p_station, p_plan) else private.plan_price(p_plan, p_cycle) end;
  if coalesce(v_amount, 0) <= 0 then perform private.fail('VALIDATION', 'Nothing to pay for this choice'); end if;
  insert into public.subscription_payments (station_id, kind, plan_code, billing_cycle, method, amount_paisa, status)
  values (p_station, p_kind, p_plan, p_cycle, p_method, v_amount, 'pending')
  returning id into v_id;
  return jsonb_build_object('payment_id', v_id, 'amount_paisa', v_amount);
end;
$$;

-- REQ-010: downgrade takes effect at the next renewal.
create or replace function public.station_schedule_downgrade(p_station uuid, p_plan text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare s public.subscriptions;
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then perform private.fail('FORBIDDEN'); end if;
  select * into s from public.subscriptions where station_id = p_station;
  if private.plan_price(p_plan, 'monthly') >= private.plan_price(s.plan_code, 'monthly') then
    perform private.fail('VALIDATION', 'Choose a lower plan to downgrade');
  end if;
  update public.subscriptions set pending_plan_code = p_plan, updated_at = now() where station_id = p_station;
end;
$$;

-- REQ-013: close with a typed confirmation (the station name). Data kept 90 days.
create or replace function public.station_close_account(p_station uuid, p_confirm text)
returns timestamptz
language plpgsql security definer set search_path = ''
as $$
declare v_name text;
begin
  if not private.has_role(p_station, array['owner']::public.member_role[]) then perform private.fail('FORBIDDEN'); end if;
  select name into v_name from public.stations where id = p_station;
  if lower(trim(coalesce(p_confirm, ''))) <> lower(v_name) then
    perform private.fail('VALIDATION', 'Type the station name exactly to confirm');
  end if;
  update public.subscriptions set state = 'closed', closed_at = now(), deletion_due_at = now() + interval '90 days', updated_at = now()
  where station_id = p_station;
  update public.stations set closed_at = now() where id = p_station;
  return now() + interval '90 days';
end;
$$;

-- Super admin RPCs (SCR-021…023) ----------------------------------------------------------
create or replace function private.assert_super_admin()
returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.is_super_admin() then perform private.fail('FORBIDDEN'); end if;
end;
$$;
grant execute on all functions in schema private to authenticated, service_role;

-- REQ-012: tenants with plan, status, dates and usage counts only — no station records.
create or replace function public.admin_tenants()
returns table (station_id uuid, name text, city text, created_at timestamptz, plan_code text, status text,
               trial_ends_at timestamptz, renews_at timestamptz, users integer, jobs_this_month integer,
               whatsapp_connected boolean, pending_payments integer, owner_name text, owner_mobile text,
               support_active boolean, deletion_due_at timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform private.assert_super_admin();
  return query
  select st.id, st.name, st.city, st.created_at, s.plan_code,
         private.effective_status(s.state, s.trial_ends_at, s.current_period_end),
         s.trial_ends_at, case when s.state = 'trial' then s.trial_ends_at else s.current_period_end end,
         (select count(*)::int from public.station_members m where m.station_id = st.id and m.active),
         (select count(*)::int from public.job_cards j where j.station_id = st.id and j.created_at >= date_trunc('month', now())),
         false,   -- WhatsApp connection arrives in Phase 7
         (select count(*)::int from public.subscription_payments p where p.station_id = st.id and p.status = 'pending_verification'),
         pr.full_name, pr.mobile,
         private.has_support_grant(st.id),
         s.deletion_due_at
  from public.stations st
  join public.subscriptions s on s.station_id = st.id
  left join public.profiles pr on pr.id = private.station_owner(st.id)
  order by st.created_at desc;
end;
$$;

create or replace function public.admin_verify_payment(p_payment uuid, p_approve boolean, p_reason text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare p public.subscription_payments;
begin
  perform private.assert_super_admin();
  select * into p from public.subscription_payments where id = p_payment for update;
  if p.id is null then perform private.fail('NOT_FOUND'); end if;
  if p.status <> 'pending_verification' then perform private.fail('VALIDATION', 'This payment is not waiting for verification'); end if;
  if not p_approve and length(trim(coalesce(p_reason, ''))) < 3 then perform private.fail('VALIDATION', 'Give the owner a reason'); end if;
  update public.subscription_payments set status = case when p_approve then 'succeeded'::public.sub_pay_status else 'rejected'::public.sub_pay_status end,
    reject_reason = case when p_approve then null else trim(p_reason) end, decided_by = auth.uid(), decided_at = now()
  where id = p_payment;
  if p_approve then
    perform private.activate_period(p_payment);
    perform private.notify(p.station_id, private.station_owner(p.station_id), 'subscription', 'Payment verified',
      format('Your %s plan is active. Thank you.', initcap(p.plan_code)), p_payment);
  else
    perform private.notify(p.station_id, private.station_owner(p.station_id), 'subscription', 'Payment not accepted', trim(p_reason), p_payment);
  end if;
end;
$$;

-- Called only by the payment webhook Edge Function (service role) after it has checked the
-- provider signature and re-queried the status. Idempotent by provider transaction id.
create or replace function public.admin_confirm_provider_payment(p_payment uuid, p_provider_txn text, p_success boolean)
returns text
language plpgsql security definer set search_path = ''
as $$
declare p public.subscription_payments;
begin
  select * into p from public.subscription_payments where id = p_payment for update;
  if p.id is null then perform private.fail('NOT_FOUND'); end if;
  if p.status in ('succeeded', 'failed') then return 'duplicate'; end if;
  if p.status <> 'pending' then perform private.fail('VALIDATION', 'Not a checkout payment'); end if;
  if exists (select 1 from public.subscription_payments where provider_txn_id = p_provider_txn and id <> p_payment) then
    perform private.fail('VALIDATION', 'Transaction already used');
  end if;
  update public.subscription_payments set status = case when p_success then 'succeeded'::public.sub_pay_status else 'failed'::public.sub_pay_status end,
    provider_txn_id = p_provider_txn, decided_at = now()
  where id = p_payment;
  if p_success then perform private.activate_period(p_payment); end if;
  return case when p_success then 'activated' else 'failed' end;
end;
$$;

create or replace function public.admin_extend_trial(p_station uuid, p_days integer)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform private.assert_super_admin();
  if p_days not between 1 and 60 then perform private.fail('VALIDATION', 'Extend by 1 to 60 days'); end if;
  update public.subscriptions set trial_ends_at = greatest(trial_ends_at, now()) + make_interval(days => p_days), updated_at = now()
  where station_id = p_station and state = 'trial';
  if not found then perform private.fail('VALIDATION', 'Only a trial can be extended'); end if;
end;
$$;

create or replace function public.admin_set_suspended(p_station uuid, p_suspend boolean, p_reason text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare s public.subscriptions;
begin
  perform private.assert_super_admin();
  if length(trim(coalesce(p_reason, ''))) < 3 then perform private.fail('VALIDATION', 'A reason is required'); end if;
  select * into s from public.subscriptions where station_id = p_station for update;
  if s.station_id is null then perform private.fail('NOT_FOUND'); end if;
  if p_suspend then
    if s.state = 'suspended' then return; end if;
    update public.subscriptions set suspended_from = s.state, state = 'suspended', suspend_reason = trim(p_reason), updated_at = now()
    where station_id = p_station;
  else
    if s.state <> 'suspended' then return; end if;
    update public.subscriptions set state = coalesce(s.suspended_from, 'active'), suspended_from = null, suspend_reason = trim(p_reason), updated_at = now()
    where station_id = p_station;
  end if;
end;
$$;

-- SCR-023: plan prices. Each tenant pays the new price from its next renewal.
create or replace function public.admin_update_plan(p_code text, p_monthly integer, p_yearly integer)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform private.assert_super_admin();
  if p_monthly <= 0 or p_yearly <= 0 then perform private.fail('VALIDATION', 'Prices must be above 0'); end if;
  update public.plans set monthly_price_pkr = p_monthly, yearly_price_pkr = p_yearly where code = p_code;
  if not found then perform private.fail('NOT_FOUND'); end if;
end;
$$;

-- Daily jobs: trial reminders (day 11, 13), grace reminders, day-80 closing reminder,
-- day-90 deletion. Safe to run twice a day.
create or replace function private.daily_subscription_jobs()
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  r record;
  v_reminders integer := 0;
  v_deleted integer := 0;
begin
  for r in select s.*, private.effective_status(s.state, s.trial_ends_at, s.current_period_end) as eff
           from public.subscriptions s loop
    if r.state = 'trial' and ((r.trial_ends_at at time zone 'Asia/Karachi')::date - (now() at time zone 'Asia/Karachi')::date) in (1, 3) then
      perform private.notify(r.station_id, private.station_owner(r.station_id), 'subscription', 'Trial ending soon',
        format('Your free trial ends on %s. Choose a plan to keep working.', to_char(r.trial_ends_at at time zone 'Asia/Karachi', 'DD-MM-YYYY')), null);
      v_reminders := v_reminders + 1;
    elsif r.eff = 'grace' then
      perform private.notify(r.station_id, private.station_owner(r.station_id), 'subscription', 'Payment due',
        'Renew now — the station becomes read-only after 7 days.', null);
      v_reminders := v_reminders + 1;
    elsif r.state = 'closed' and r.deletion_due_at is not null
          and ((r.deletion_due_at at time zone 'Asia/Karachi')::date - (now() at time zone 'Asia/Karachi')::date) = 10 then
      perform private.notify(r.station_id, private.station_owner(r.station_id), 'subscription', 'Data will be deleted in 10 days',
        'Pay any plan to restore the account, or download your export now.', null);
      v_reminders := v_reminders + 1;
    end if;
  end loop;

  for r in select s.station_id, st.name, st.city, s.closed_at from public.subscriptions s join public.stations st on st.id = s.station_id
           where s.state = 'closed' and s.deletion_due_at <= now() loop
    perform private.purge_station(r.station_id);
    v_deleted := v_deleted + 1;
  end loop;
  return jsonb_build_object('reminders', v_reminders, 'deleted', v_deleted);
end;
$$;

-- REQ-013: permanent deletion of a closed station (rows and files); a tombstone remains.
create or replace function private.purge_station(p_station uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare st public.stations;
begin
  select * into st from public.stations where id = p_station;
  if st.id is null then return; end if;
  if not exists (select 1 from public.subscriptions where station_id = p_station and state = 'closed') then
    perform private.fail('VALIDATION', 'Only closed stations can be deleted');
  end if;
  perform set_config('app.purge_station', 'on', true);
  insert into public.deleted_stations (station_id, name, city, closed_at) values (st.id, st.name, st.city, st.closed_at)
  on conflict (station_id) do nothing;
  delete from storage.objects where bucket_id in ('station-logos', 'payment-receipts') and name like p_station::text || '/%';
  delete from public.stations where id = p_station;
  perform set_config('app.purge_station', 'off', true);
end;
$$;
grant execute on all functions in schema private to authenticated, service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('daily-subscription-jobs', '30 4 * * *', 'select private.daily_subscription_jobs()');
  end if;
end $$;

revoke execute on function
  public.station_subscription_quote(uuid, text, public.billing_cycle),
  public.station_submit_manual_payment(uuid, text, text, public.billing_cycle, public.sub_pay_method, text, text),
  public.station_start_checkout(uuid, text, text, public.billing_cycle, public.sub_pay_method),
  public.station_schedule_downgrade(uuid, text),
  public.station_close_account(uuid, text),
  public.admin_tenants(),
  public.admin_verify_payment(uuid, boolean, text),
  public.admin_confirm_provider_payment(uuid, text, boolean),
  public.admin_extend_trial(uuid, integer),
  public.admin_set_suspended(uuid, boolean, text),
  public.admin_update_plan(text, integer, integer)
from public, anon;
grant execute on function
  public.station_subscription_quote(uuid, text, public.billing_cycle),
  public.station_submit_manual_payment(uuid, text, text, public.billing_cycle, public.sub_pay_method, text, text),
  public.station_start_checkout(uuid, text, text, public.billing_cycle, public.sub_pay_method),
  public.station_schedule_downgrade(uuid, text),
  public.station_close_account(uuid, text),
  public.admin_tenants(),
  public.admin_verify_payment(uuid, boolean, text),
  public.admin_extend_trial(uuid, integer),
  public.admin_set_suspended(uuid, boolean, text),
  public.admin_update_plan(text, integer, integer)
to authenticated;
grant execute on function public.admin_confirm_provider_payment(uuid, text, boolean) to service_role;

-- Security fix: Supabase grants EXECUTE on new public functions to "authenticated" by
-- default, so service-role-only functions must revoke it explicitly. admin_add_member
-- (Phase 1) let a logged-in user add themselves to a station if they knew the owner's id.
revoke execute on function public.admin_add_member(uuid, uuid, uuid, text, text, public.member_role) from authenticated;
revoke execute on function public.admin_confirm_provider_payment(uuid, text, boolean) from authenticated;
