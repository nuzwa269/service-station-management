-- TASK-005 · login codes through the gateway phone.
insert into tests.fx values ('sa', tests.create_user('923461111111')), ('owner', tests.create_user('923462222222'));
insert into public.profiles (id, full_name, is_super_admin) values (tests.id('sa'), 'Platform Admin', true)
  on conflict (id) do update set is_super_admin = true;

-- As the database owner (the Edge Functions use the service role; the queue is private).
do $$
declare r record; n int := 0; v_id bigint;
begin
  assert public.svc_sms_enqueue('923001234567', 'Your code is 123456') = 'queued', 'queued';
  -- Claim gives it to the phone once.
  for r in select * from public.svc_sms_claim('pixel-1', 10, '{"battery":90}') loop
    n := n + 1; v_id := r.id;
    assert r.phone = '+923001234567' and r.body = 'Your code is 123456', 'claimed message';
  end loop;
  assert n = 1, 'one message claimed';
  assert (select count(*) from public.svc_sms_claim('pixel-1')) = 0, 'not handed out twice';
  -- A failure goes back to the queue, success is final.
  perform public.svc_sms_report(v_id, false, 'No signal');
  assert (select status from private.sms_queue where id = v_id) = 'queued', 'retry after failure';
  assert (select count(*) from public.svc_sms_claim('pixel-1')) = 1, 'offered again';
  perform public.svc_sms_report(v_id, true);
  assert (select status from private.sms_queue where id = v_id) = 'sent', 'sent';
  -- Old codes are never sent.
  insert into private.sms_queue (phone, body, created_at) values ('+923009999999', 'old', now() - interval '6 minutes');
  assert (select count(*) from public.svc_sms_claim('pixel-1')) = 0, 'expired code not sent';
  assert (select status from private.sms_queue where body = 'old') = 'expired', 'marked expired';
  -- SIM protection: the 6th message to one number within an hour is dropped.
  for i in 1..4 loop perform public.svc_sms_enqueue('+923001234567', 'x'); end loop;
  assert public.svc_sms_enqueue('923001234567', 'x') = 'dropped', 'rate limit per number';
  perform tests.throws($q$select public.svc_sms_enqueue('12', 'x')$q$, 'VALIDATION');
end $$;
do $$ begin
  assert has_function_privilege('service_role', 'public.svc_sms_claim(text, integer, jsonb)', 'execute'), 'service role can claim';
end $$;

-- Apps can't touch the queue or the service functions; the admin sees the status.
do $$
declare r record;
begin
  for r in select p.oid, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'svc\_sms\_%' loop
    assert not has_function_privilege('authenticated', r.oid, 'execute'), r.proname || ' callable by users';
  end loop;
  assert not has_table_privilege('authenticated', 'private.sms_queue', 'SELECT'), 'queue readable';
end $$;
set role authenticated;
select tests.as_user(tests.id('owner'));
select tests.throws('select public.admin_sms_status()', 'FORBIDDEN');
select tests.as_user(tests.id('sa'));
do $$
declare s jsonb := public.admin_sms_status();
begin
  assert (s ->> 'sent_today')::int = 1, 'sent today ' || s::text;
  assert (s ->> 'failed_today')::int = 2, 'expired + dropped today';
  assert s ->> 'last_seen' is not null and jsonb_array_length(s -> 'devices') = 1, 'gateway seen';
end $$;
reset role;
