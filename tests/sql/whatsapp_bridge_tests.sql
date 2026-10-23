-- =====================================================================
-- WhatsApp Web bridge on the reception computer (WB01–WB17, migration 0023).
-- A branch of its own in org 1 ("فرع الجسر"), so the Cloud API tests (whatsapp_purge_tests.sql) keep theirs.
-- org 1: owner a…01, supervisor a…02 (member of branch …010 only), housekeeping a…03; org 2: owner a…05.
-- =====================================================================
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create temp table kv(k text primary key, v text);
grant all on kv to public;
create or replace function t_blogin(p_uid uuid, p_email text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email, 'iat', extract(epoch from now())::bigint)::text, false);
end $$;
create or replace function t_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;
create or replace function t_kv(p_k text) returns text language sql security definer as $$ select v from kv where k = p_k $$;
create or replace function t_bb() returns uuid language sql as $$ select '00000000-0000-0000-0000-0000000000b1'::uuid $$;
create or replace function t_row(p_branch uuid) returns jsonb language sql security definer as $$
  select to_jsonb(c) from branch_whatsapp_channels c where branch_id = p_branch
$$;

insert into branches(id, organization_id, name_ar, phone) values (t_bb(), '00000000-0000-0000-0000-000000000001', 'فرع الجسر', '0112223344') on conflict do nothing;

-- ---------------------------------------------------------------- owner sets the branch up for the reception computer
select t_blogin('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; l jsonb; me jsonb; begin
  r := fn_admin_whatsapp_save(t_bb(), '{"display_phone": "0559998877"}'::jsonb);
  begin
    perform fn_admin_whatsapp_save(t_bb(), '{"enabled": true}'::jsonb);
    perform t_record('WB01 a new branch defaults to the reception-computer link and cannot go live without its key', false, 'accepted');
  exception when others then
    perform t_record('WB01 a new branch defaults to the reception-computer link and cannot go live without its key',
      sqlerrm like 'VALIDATION: channel_incomplete%' and r->>'mode' = 'web_bridge' and r->>'status' = 'not_configured', sqlerrm || ' ' || r::text);
  end;

  r := fn_admin_whatsapp_save(t_bb(), '{"regenerate_bridge_key": true}'::jsonb);
  insert into kv values ('key', r->>'bridge_key');
  l := fn_admin_whatsapp_channels();
  select x into me from jsonb_array_elements(l) x where (x->>'branch_id')::uuid = t_bb();
  perform t_record('WB02 the bridge key is returned once (zb_ + 64 hex), then only "has key ••••last4"',
    r->>'bridge_key' ~ '^zb_[0-9a-f]{64}$' and r->>'status' = 'configured' and (me->>'has_bridge_key')::boolean
    and me->>'bridge_key_last4' = right(r->>'bridge_key', 4) and l::text not like '%' || (r->>'bridge_key') || '%'
    and fn_admin_whatsapp_save(t_bb(), '{}'::jsonb)::text not like '%zb_%', me::text);

  r := fn_admin_whatsapp_save(t_bb(), '{"enabled": true}'::jsonb);
  perform t_record('WB03 with number and key the branch goes live', (r->>'enabled')::boolean and r->>'status' = 'configured', r::text);
end $$;
reset role;

select t_record('WB04 only the key''s SHA-256 is stored, and the audit holds no key',
  (t_row(t_bb())->>'bridge_key_hash') = encode(extensions.digest(t_kv('key'), 'sha256'), 'hex')
  and t_row(t_bb())::text not like '%' || t_kv('key') || '%'
  and not exists (select 1 from audit_events where details::text like '%' || t_kv('key') || '%')
  and exists (select 1 from audit_events where action = 'whatsapp_channel_updated' and entity_id = t_bb() and details->'changed' ? 'bridge_key'));

set role anon;
do $$ declare p jsonb; begin
  p := fn_public_whatsapp(t_bb());
  perform t_record('WB05 the website shows the QR of the bridge number', (p->>'active')::boolean and p->>'wa_phone' = '966559998877', p::text);
  begin perform fn_wa_bridge_auth(t_kv('key')); perform t_record('WB06 the website cannot use the bridge functions', false);
  exception when insufficient_privilege then perform t_record('WB06 the website cannot use the bridge functions', true); end;
end $$;
reset role;

-- ---------------------------------------------------------------- the program: key, heartbeat
set role service_role;
do $$ declare a jsonb; b jsonb; begin
  a := fn_wa_bridge_auth(t_kv('key'));
  perform t_record('WB07 the program''s key finds its branch; a wrong or malformed key finds nothing',
    (a->>'branch_id')::uuid = t_bb() and (a->>'auto_reply')::boolean and (a->>'enabled')::boolean
    and fn_wa_bridge_auth('zb_' || repeat('0', 64)) is null and fn_wa_bridge_auth('x') is null and fn_wa_bridge_auth(null) is null, a::text);

  b := fn_wa_bridge_beat(t_bb(), 'connected', '+966 55 999 8877', 'منازل الراحة', '1.0.0');
  perform t_record('WB08 "connected" makes the channel active and records the linked number',
    t_row(t_bb())->>'status' = 'active' and t_row(t_bb())->>'bridge_phone' = '966559998877' and (b->>'enabled')::boolean, t_row(t_bb())::text);
  perform fn_wa_bridge_beat(t_bb(), 'disconnected', null, null, null, 'LOGOUT');
  perform t_record('WB09 a logged-out WhatsApp shows as an error, yet the QR stays for guests (the phone still receives)',
    t_row(t_bb())->>'status' = 'error' and t_row(t_bb())->>'last_error' = 'LOGOUT', t_row(t_bb())::text);
  perform fn_wa_bridge_beat(t_bb(), 'connected', '966559998877', null, null);
  begin perform fn_wa_bridge_beat(t_bb(), 'hacked'); perform t_record('WB10 heartbeat states are a closed list', false);
  exception when others then perform t_record('WB10 heartbeat states are a closed list', sqlerrm like 'VALIDATION%', sqlerrm); end;
end $$;
reset role;
set role anon;
select t_record('WB09b public QR while the link reports an error', (fn_public_whatsapp(t_bb())->>'active')::boolean);
reset role;

-- ---------------------------------------------------------------- owner: settings, new key, mode
select t_blogin('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; me jsonb; bad int := 0; begin
  select x into me from jsonb_array_elements(fn_admin_whatsapp_channels()) x where (x->>'branch_id')::uuid = t_bb();
  perform t_record('WB11 the owner sees the link live (online, connected, linked number)',
    (me->>'bridge_online')::boolean and me->>'bridge_status' = 'connected' and me->>'bridge_phone' = '966559998877', me::text);

  r := fn_admin_whatsapp_save(t_bb(), '{"auto_reply": false, "human_pause_minutes": 90}'::jsonb);
  begin perform fn_admin_whatsapp_save(t_bb(), '{"human_pause_minutes": 3}'::jsonb); exception when others then if sqlerrm like 'VALIDATION%' then bad := bad + 1; end if; end;
  begin perform fn_admin_whatsapp_save(t_bb(), '{"human_pause_minutes": "x"}'::jsonb); exception when others then if sqlerrm like 'VALIDATION%' then bad := bad + 1; end if; end;
  begin perform fn_admin_whatsapp_save(t_bb(), '{"auto_reply": "yes"}'::jsonb); exception when others then if sqlerrm like 'VALIDATION%' then bad := bad + 1; end if; end;
  begin perform fn_admin_whatsapp_save(t_bb(), '{"mode": "telegram"}'::jsonb); exception when others then if sqlerrm like 'VALIDATION%' then bad := bad + 1; end if; end;
  perform t_record('WB12 auto-reply and the takeover pause are saved; bad values are refused',
    r->'changed' ? 'auto_reply' and r->'changed' ? 'human_pause_minutes' and bad = 4, r::text || ' refused=' || bad);
  perform fn_admin_whatsapp_save(t_bb(), '{"auto_reply": true}'::jsonb);

  r := fn_admin_whatsapp_save(t_bb(), '{"regenerate_bridge_key": true}'::jsonb);
  insert into kv values ('key2', r->>'bridge_key');
  perform t_record('WB13 a new key starts the link over (status configured, no old heartbeat)',
    r->>'bridge_key' <> t_kv('key') and r->>'status' = 'configured' and (r->>'enabled')::boolean, r::text);

  r := fn_admin_whatsapp_save(t_bb(), '{"mode": "cloud_api"}'::jsonb);
  perform t_record('WB14 switching to Cloud API without its details takes the branch offline',
    r->>'mode' = 'cloud_api' and r->>'status' = 'not_configured' and not (r->>'enabled')::boolean, r::text);
end $$;
reset role;

set role service_role;
select t_record('WB15 the old key is refused after a new one, and every key is refused outside bridge mode',
  fn_wa_bridge_auth(t_kv('key')) is null and fn_wa_bridge_auth(t_kv('key2')) is null);
reset role;

select t_blogin('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; begin
  r := fn_admin_whatsapp_save(t_bb(), '{"mode": "web_bridge", "enabled": true}'::jsonb);
  perform t_record('WB16 back to bridge mode the current key works again', r->>'status' = 'configured' and (r->>'enabled')::boolean, r::text);
end $$;
reset role;
set role service_role;
select t_record('WB16b current key accepted', (fn_wa_bridge_auth(t_kv('key2'))->>'branch_id')::uuid = t_bb());
reset role;

-- ---------------------------------------------------------------- staff replies through the reception computer
insert into conversations(id, channel, status, branch_id, wa_contact, wa_chat_id, last_message_at)
values ('c0000000-0000-0000-0000-0000000000b1', 'whatsapp', 'active', t_bb(), '966501110006', '966501110006@c.us', now()),
       ('c0000000-0000-0000-0000-0000000000b2', 'whatsapp', 'active', t_bb(), '966501110007', '966501110007@c.us', now() - interval '25 hours');
insert into conversation_messages(id, conversation_id, sender, content, created_at) values
  ('d0000000-0000-0000-0000-0000000000b1', 'c0000000-0000-0000-0000-0000000000b1', 'guest', 'متى الدخول؟', now() - interval '5 minutes'),
  ('d0000000-0000-0000-0000-0000000000b2', 'c0000000-0000-0000-0000-0000000000b1', 'supervisor', 'أهلًا، الدخول من الساعة 4 عصرًا', now()),
  ('d0000000-0000-0000-0000-0000000000b3', 'c0000000-0000-0000-0000-0000000000b2', 'guest', 'شكرًا', now() - interval '25 hours'),
  ('d0000000-0000-0000-0000-0000000000b4', 'c0000000-0000-0000-0000-0000000000b2', 'supervisor', 'العفو', now());

set role service_role;
do $$ declare q jsonb; p jsonb; p2 jsonb; ok boolean; begin
  q := fn_wa_bridge_enqueue('d0000000-0000-0000-0000-0000000000b2');
  perform t_record('WB17 a staff reply is queued for the computer and the assistant steps back in that chat',
    (q->>'queued')::boolean and (select human_active_until between now() + interval '89 minutes' and now() + interval '91 minutes'
                                 from conversations where id = 'c0000000-0000-0000-0000-0000000000b1')
    and (select meta->>'delivery' from conversation_messages where id = 'd0000000-0000-0000-0000-0000000000b2') = 'queued', q::text);

  p := fn_wa_bridge_poll(t_bb());
  p2 := fn_wa_bridge_poll(t_bb());
  perform t_record('WB18 the computer gets the text and the chat once (a second poll does not repeat it)',
    jsonb_array_length(p) = 1 and p->0->>'chat_id' = '966501110006@c.us' and p->0->>'text' = 'أهلًا، الدخول من الساعة 4 عصرًا'
    and jsonb_array_length(p2) = 0, p::text || p2::text);
  insert into kv values ('ob', p->0->>'id');

  ok := fn_wa_bridge_ack(t_bb(), (t_kv('ob'))::uuid, true, 'true_966501110006@c.us_ABC');
  perform t_record('WB19 a confirmed send marks the reply sent in the inbox; a second confirmation changes nothing',
    ok and not fn_wa_bridge_ack(t_bb(), (t_kv('ob'))::uuid, false, null, 'x')
    and (select meta->>'delivery' from conversation_messages where id = 'd0000000-0000-0000-0000-0000000000b2') = 'sent'
    and (select status from whatsapp_outbox where id = (t_kv('ob'))::uuid) = 'sent', null);

  q := fn_wa_bridge_enqueue('d0000000-0000-0000-0000-0000000000b4');
  perform t_record('WB20 no free text to a guest silent for more than 24 hours (as WhatsApp''s own rule for businesses)',
    not (q->>'queued')::boolean and q->>'error' = 'window_closed'
    and (select meta->>'error' from conversation_messages where id = 'd0000000-0000-0000-0000-0000000000b4') = 'window_closed', q::text);
end $$;
reset role;

-- a pick never confirmed is reported failed (never typed twice); a reply that waited 12 hours is not sent late
insert into conversation_messages(id, conversation_id, sender, content) values
  ('d0000000-0000-0000-0000-0000000000b5', 'c0000000-0000-0000-0000-0000000000b1', 'supervisor', 'رد قديم'),
  ('d0000000-0000-0000-0000-0000000000b6', 'c0000000-0000-0000-0000-0000000000b1', 'supervisor', 'رد معلق');
insert into whatsapp_outbox(branch_id, message_id, status, picked_at, created_at) values
  (t_bb(), 'd0000000-0000-0000-0000-0000000000b5', 'sending', now() - interval '6 minutes', now() - interval '7 minutes'),
  (t_bb(), 'd0000000-0000-0000-0000-0000000000b6', 'pending', null, now() - interval '13 hours');
set role service_role;
do $$ declare p jsonb; begin
  p := fn_wa_bridge_poll(t_bb());
  perform t_record('WB21 an unconfirmed pick becomes "failed", a 12-hour-old reply "expired" — neither is sent',
    jsonb_array_length(p) = 0
    and (select meta->>'error' from conversation_messages where id = 'd0000000-0000-0000-0000-0000000000b5') = 'no_ack'
    and (select meta->>'error' from conversation_messages where id = 'd0000000-0000-0000-0000-0000000000b6') = 'expired', p::text);
end $$;
reset role;

select t_blogin('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
set role authenticated;
do $$ declare n int; begin
  begin select count(*) into n from whatsapp_outbox; perform t_record('WB22 staff cannot read the outbox directly', false, n::text);
  exception when insufficient_privilege then perform t_record('WB22 staff cannot read the outbox directly', true); end;
end $$;
reset role;

-- ---------------------------------------------------------------- inbox: take / return (audited, per branch)
select t_blogin('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; begin
  r := fn_conversation_take('c0000000-0000-0000-0000-0000000000b1', false);
  perform t_record('WB23 "return to the assistant" ends the pause at once',
    r->>'status' = 'active' and (select human_active_until is null from conversations where id = 'c0000000-0000-0000-0000-0000000000b1'), r::text);
  r := fn_conversation_take('c0000000-0000-0000-0000-0000000000b1', true);
  perform t_record('WB24 taking a WhatsApp conversation silences the assistant for the branch''s pause (90 min) — audited',
    r->>'status' = 'handed_off' and (select human_active_until > now() + interval '89 minutes' from conversations where id = 'c0000000-0000-0000-0000-0000000000b1')
    and exists (select 1 from audit_events where action = 'conversation_taken' and entity_id = 'c0000000-0000-0000-0000-0000000000b1'), r::text);
end $$;
reset role;

select t_blogin('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
set role authenticated;
do $$ begin
  begin perform fn_conversation_take('c0000000-0000-0000-0000-0000000000b1', false); perform t_record('WB25 a supervisor of another branch cannot take or return this chat', false);
  exception when others then perform t_record('WB25 a supervisor of another branch cannot take or return this chat', sqlerrm like 'FORBIDDEN%', sqlerrm); end;
end $$;
reset role;
select t_blogin('a0000000-0000-0000-0000-000000000003', 'hk@test.local');
set role authenticated;
do $$ begin
  begin perform fn_conversation_take('c0000000-0000-0000-0000-0000000000b1', true); perform t_record('WB26 housekeeping cannot take guest chats', false);
  exception when others then perform t_record('WB26 housekeeping cannot take guest chats', sqlerrm like 'FORBIDDEN%', sqlerrm); end;
end $$;
reset role;
select t_blogin('a0000000-0000-0000-0000-000000000005', 'owner2@test.local');
set role authenticated;
do $$ begin
  begin perform fn_conversation_take('c0000000-0000-0000-0000-0000000000b1', true); perform t_record('WB27 another organisation''s owner cannot touch this chat', false);
  exception when others then perform t_record('WB27 another organisation''s owner cannot touch this chat', sqlerrm like 'FORBIDDEN%', sqlerrm); end;
  begin perform fn_admin_whatsapp_save(t_bb(), '{"regenerate_bridge_key": true}'::jsonb); perform t_record('WB28 another organisation''s owner cannot create a key for this branch', false);
  exception when others then perform t_record('WB28 another organisation''s owner cannot create a key for this branch', sqlerrm like 'NOT_FOUND%', sqlerrm); end;
end $$;
reset role;

-- a check that comes out NULL counts as a failure here
select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),140) as detail from test_results order by ok nulls first, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from test_results where ok is not true) then raise exception 'WHATSAPP BRIDGE TESTS FAILED'; end if;
  -- a statement that errors before recording its check would otherwise just be missing
  if (select count(*) from test_results) < 30 then raise exception 'WHATSAPP BRIDGE TESTS INCOMPLETE: % of 30 checks ran', (select count(*) from test_results); end if;
end $$;
