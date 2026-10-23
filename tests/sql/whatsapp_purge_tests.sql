-- =====================================================================
-- WhatsApp per branch (WA01–WA08, migration 0021) and data purge (DP01–DP12, migration 0022).
-- Runs LAST on the shared suite DB: the purge deletes data the other files rely on.
-- org 1: owner a…01, supervisor a…02; org 2: owner a…05.
-- =====================================================================
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create temp table kv(k text primary key, v text);
grant all on kv to public;
create or replace function t_wlogin(p_uid uuid, p_email text, p_age_s int default 0) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email, 'iat', extract(epoch from now())::bigint - p_age_s)::text, false);
end $$;
create or replace function t_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;
create or replace function t_q(p_sql text) returns bigint language plpgsql security definer as $$
declare n bigint; begin execute p_sql into n; return n; end $$;
create or replace function t_branch() returns uuid language sql security definer as $$
  select id from branches where organization_id = '00000000-0000-0000-0000-000000000001' order by created_at limit 1
$$;

-- ---------------------------------------------------------------- WhatsApp
select t_wlogin('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; l jsonb; begin
  begin
    perform fn_admin_whatsapp_save(t_branch(), '{"enabled": true}'::jsonb);
    perform t_record('WA01 a channel cannot be enabled before number, id, token and secret are set', false, 'accepted');
  exception when others then perform t_record('WA01 a channel cannot be enabled before number, id, token and secret are set', sqlerrm like 'VALIDATION%', sqlerrm); end;

  r := fn_admin_whatsapp_save(t_branch(), jsonb_build_object('display_phone', '0551234567', 'phone_number_id', '123456789012345',
        'access_token', 'EAAGtesttoken0123456789XYZW', 'app_secret', 'abcdef0123456789abcdef', 'otp_template', 'Booking_Code', 'enabled', true));
  l := fn_admin_whatsapp_channels();
  perform t_record('WA02 owner sets up a branch number: phone normalized, enabled, status configured',
    r->>'status' = 'configured' and (r->>'enabled')::boolean
    and (select x->>'display_phone' from jsonb_array_elements(l) x where (x->>'branch_id')::uuid = t_branch()) = '966551234567'
    and (select x->>'otp_template' from jsonb_array_elements(l) x where (x->>'branch_id')::uuid = t_branch()) = 'booking_code', r::text);
  perform t_record('WA03 the token and app secret never come back (only "saved ••••last4")',
    l::text not like '%EAAGtesttoken%' and l::text not like '%abcdef0123456789abcdef%'
    and (select x->>'token_last4' from jsonb_array_elements(l) x where (x->>'branch_id')::uuid = t_branch()) = 'XYZW', null);
  insert into kv values ('verify', (select x->>'verify_token' from jsonb_array_elements(l) x where (x->>'branch_id')::uuid = t_branch()));

  r := fn_admin_whatsapp_save(t_branch(), '{"otp_template": "booking_code_2"}'::jsonb);
  perform t_record('WA04 saving other fields keeps the stored token (write-only fields left empty)',
    (select (x->>'has_token')::boolean and (x->>'has_app_secret')::boolean from jsonb_array_elements(fn_admin_whatsapp_channels()) x where (x->>'branch_id')::uuid = t_branch()), r::text);
end $$;
reset role;

select t_record('WA05 secrets are stored encrypted and the audit holds no secret',
  (select access_token_encrypted is not null and convert_from(access_token_encrypted, 'latin1') not like '%EAAGtesttoken%' from branch_whatsapp_channels where branch_id = t_branch())
  and not exists (select 1 from audit_events where action = 'whatsapp_channel_updated' and (details::text like '%EAAG%' or details::text like '%abcdef0123%' or details::text like '%' || (select v from kv where k = 'verify') || '%')));

set role service_role;
do $$ declare ch jsonb; begin
  ch := fn_whatsapp_channel(null, '123456789012345', null);
  perform t_record('WA06 the webhook (service role) finds the branch by Meta phone number id and gets the decrypted token',
    (ch->>'branch_id')::uuid = t_branch() and ch->>'access_token' = 'EAAGtesttoken0123456789XYZW' and ch->>'app_secret' = 'abcdef0123456789abcdef', null);
end $$;
reset role;

set role anon;
do $$ declare p jsonb; begin
  p := fn_public_whatsapp(t_branch());
  perform t_record('WA07 the website gets only the public number of an enabled branch (no ids, no tokens)',
    (p->>'active')::boolean and p->>'wa_phone' = '966551234567' and p::text not like '%123456789012345%' and p::text not like '%EAAG%', p::text);
  begin perform fn_whatsapp_channel(t_branch(), null, null); perform t_record('WA08 anon cannot read a channel', false);
  exception when insufficient_privilege then perform t_record('WA08 anon cannot read a channel', true); end;
end $$;
reset role;

select t_wlogin('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
set role authenticated;
do $$ begin
  begin perform fn_admin_whatsapp_channels(); perform t_record('WA09 a supervisor cannot see or change WhatsApp settings', false);
  exception when others then perform t_record('WA09 a supervisor cannot see or change WhatsApp settings', sqlerrm like 'FORBIDDEN%', sqlerrm); end;
end $$;
reset role;

-- the WhatsApp sender is the proof: a session for the sender lists that number's bookings and opens one
set role service_role;
do $$ declare t text; l jsonb; o jsonb; begin
  t := fn_whatsapp_phone_session('+966500000111');
  l := fn_guest_phone_reservations(t);
  o := fn_guest_phone_open(t, l->'reservations'->0->>'internal_ref');
  perform t_record('WA10 a WhatsApp sender session lists the sender''s bookings and opens one (audited as whatsapp)',
    jsonb_array_length(l->'reservations') >= 1 and o->>'status' = 'ok'
    and exists (select 1 from audit_events where action = 'guest_verified_lookup' and details->>'channel' = 'whatsapp'), l::text);
end $$;
reset role;

-- ---------------------------------------------------------------- data purge
insert into kv select 'checked_in', count(*)::text from reservations where status = 'checked_in';
insert into kv select 'org2_res', count(*)::text from reservations where organization_id <> '00000000-0000-0000-0000-000000000001';
insert into kv select 'org1_vouchers', count(*)::text from financial_vouchers where organization_id = '00000000-0000-0000-0000-000000000001';
insert into kv select 'res_total', count(*)::text from reservations where organization_id = '00000000-0000-0000-0000-000000000001';

select t_wlogin('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
set role authenticated;
do $$ begin
  begin perform fn_admin_purge_preview(null, current_date - 3650, current_date, array['reservations']);
    perform t_record('DP01 only the owner can purge', false);
  exception when others then perform t_record('DP01 only the owner can purge', sqlerrm like 'FORBIDDEN%', sqlerrm); end;
end $$;
reset role;

select t_wlogin('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare p jsonb; begin
  begin perform fn_admin_purge_preview(null, current_date - 10, current_date + 5, array['reservations']);
    perform t_record('DP02 a period that ends after today is refused', false);
  exception when others then perform t_record('DP02 a period that ends after today is refused', sqlerrm like 'VALIDATION%', sqlerrm); end;
  begin perform fn_admin_purge_preview(null, current_date - 10, current_date, array['branches']);
    perform t_record('DP03 an unknown kind of data is refused (definitions are never purged)', false);
  exception when others then perform t_record('DP03 an unknown kind of data is refused (definitions are never purged)', sqlerrm like 'VALIDATION%', sqlerrm); end;

  p := fn_admin_purge_preview(null, current_date - 3650, current_date, array['reservations', 'conversations']);
  insert into kv values ('tok1', p->>'token'), ('prev1', p->>'counts');
  perform t_record('DP04 the preview counts and deletes nothing',
    t_q('select count(*) from reservations where organization_id = ''00000000-0000-0000-0000-000000000001''')::text = (select v from kv where k = 'res_total')
    and p->'counts' ? 'reservations' and p->>'phrase' = 'احذف نهائيا', p::text);

  begin perform fn_admin_purge_execute(p->>'token', 'نعم');
    perform t_record('DP05 the wrong phrase is refused', false);
  exception when others then perform t_record('DP05 the wrong phrase is refused', sqlerrm like 'VALIDATION%', sqlerrm); end;
end $$;
reset role;

-- a session signed in 30 minutes ago is not a fresh confirmation
select t_wlogin('a0000000-0000-0000-0000-000000000001', 'owner@test.local', 1800);
set role authenticated;
do $$ begin
  begin perform fn_admin_purge_execute((select v from kv where k = 'tok1'), 'احذف نهائيًا');
    perform t_record('DP06 without a fresh sign-in the purge is refused', false);
  exception when others then perform t_record('DP06 without a fresh sign-in the purge is refused', sqlerrm like 'REAUTH_REQUIRED%', sqlerrm); end;
end $$;
reset role;

select t_wlogin('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; begin
  r := fn_admin_purge_execute((select v from kv where k = 'tok1'), ' احذف نهائيًا ');
  perform t_record('DP07 the purge deletes exactly what the preview counted',
    r->'counts'->'reservations' = (select v::jsonb from kv where k = 'prev1')->'reservations'
    and r->'counts'->'conversations' = (select v::jsonb from kv where k = 'prev1')->'conversations', r::text || ' vs ' || (select v from kv where k = 'prev1'));
  insert into kv values ('res1', r->'counts'->>'reservations'), ('skipped1', r->'counts'->>'reservations_skipped_with_money');
  begin perform fn_admin_purge_execute((select v from kv where k = 'tok1'), 'احذف نهائيا');
    perform t_record('DP08 a token works once', false);
  exception when others then perform t_record('DP08 a token works once', sqlerrm like 'VALIDATION%', sqlerrm); end;
end $$;
reset role;

select t_record('DP09 in-house stays, money and the other organization are untouched; stays with money were skipped, not deleted',
  t_q('select count(*) from reservations where status = ''checked_in''')::text = (select v from kv where k = 'checked_in')
  and t_q('select count(*) from reservations where organization_id <> ''00000000-0000-0000-0000-000000000001''')::text = (select v from kv where k = 'org2_res')
  and t_q('select count(*) from financial_vouchers where organization_id = ''00000000-0000-0000-0000-000000000001''')::text = (select v from kv where k = 'org1_vouchers')
  and (select v::int from kv where k = 'res1') + (select v::int from kv where k = 'skipped1') > 0,
  'deleted=' || (select v from kv where k = 'res1') || ' skipped=' || (select v from kv where k = 'skipped1'));

select t_record('DP10 the purge is audited with its period, kinds and counts',
  exists (select 1 from audit_events where action = 'data_purge_executed' and details->'categories' = '["conversations","reservations"]'::jsonb and details ? 'counts'));

-- purging the audit log of the period keeps the record of that very purge (written after the deletion)
select t_wlogin('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare p jsonb; r jsonb; begin
  p := fn_admin_purge_preview(null, current_date - 3650, current_date, array['audit', 'reservations', 'finance', 'guests', 'operations', 'logs']);
  r := fn_admin_purge_execute(p->>'token', 'احذف نهائيا');
  perform t_record('DP11 an audit purge leaves exactly its own record behind; finance with stays removes the skipped ones too',
    t_q('select count(*) from audit_events where organization_id = ''00000000-0000-0000-0000-000000000001''') = 1
    and exists (select 1 from audit_events where action = 'data_purge_executed' and details->'counts' ? 'audit_events')
    and t_q('select count(*) from reservations where status = ''checked_in''')::text = (select v from kv where k = 'checked_in'), r::text);
  perform t_record('DP12 the history lists both purges', jsonb_array_length(fn_admin_purge_history()) = 2, fn_admin_purge_history()::text);
end $$;
reset role;

select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),140) as detail from test_results order by ok, name;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from test_results where not ok) then raise exception 'WHATSAPP/PURGE TESTS FAILED'; end if;
end $$;
