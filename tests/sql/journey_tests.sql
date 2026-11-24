create or replace function t_today(p uuid) returns date language sql security definer as $$ select fn_branch_today(p) $$;  -- 0127: authenticated cannot call fn_branch_today directly
-- =====================================================================
-- The guest journey after the stay (migration 0070): W3 the check-out options and the extension (CX), W4 the
-- departure and the deposit's return (DR), W5 the review (RW), W6 the alert rules (AR), and the journey's messages
-- and clock (JM). Tried from outside the screens, as the guest's pages, the reception computer and the staff call it.
-- The journey's clock is read at a chosen hour of today (fn_journey_tick's p_at, fn_checkout_choose's p_at), and the
-- branch of the checks keeps a time zone where it is mid-morning now (the guest's own choices read the real clock), so
-- the checks do not depend on the hour they run at.
-- =====================================================================
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create temp table ids(k text primary key, v uuid);
grant all on ids to public;
create temp table notes(k text primary key, v text);
grant all on notes to public;
create or replace function tj_login(p_uid uuid, p_email text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email)::text, false);
end $$;
create or replace function tj_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;
create or replace function tj_id(p_k text) returns uuid language sql security definer as $$ select v from ids where k = p_k $$;
create or replace function tj_note(p_k text) returns text language sql security definer as $$ select v from notes where k = p_k $$;
create or replace function tj_fails(p_sql text, p_like text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'accepted';
exception when others then
  return case when sqlerrm like p_like then 'ok' else sqlerrm end;
end $$;
create or replace function tj_today(p uuid) returns date language sql security definer as $$ select t_today(p) $$;
-- today at a local hour of the branch
create or replace function tj_at(p_branch uuid, p_hm text) returns timestamptz language sql security definer as $$
  select (t_today(p_branch) + p_hm::time) at time zone (select timezone from branches where id = p_branch) $$;
create or replace function tj_tick(p_branch uuid, p_at timestamptz default now()) returns jsonb language sql security definer as $$ select fn_journey_tick(p_branch, true, p_at) $$;
create or replace function tj_res(p uuid) returns reservations language sql security definer as $$ select * from reservations where id = p $$;
create or replace function tj_fin(p uuid) returns jsonb language sql security definer as $$ select fn_reservation_finance_internal(p) $$;
create or replace function tj_msg(p_res uuid, p_kind text) returns journey_messages language sql security definer as $$
  select * from journey_messages where reservation_id = p_res and kind = p_kind order by created_at desc limit 1 $$;
create or replace function tj_msg_count(p_res uuid, p_kind text) returns bigint language sql security definer as $$
  select count(*) from journey_messages where reservation_id = p_res and kind = p_kind $$;
create or replace function tj_text(p_message uuid) returns text language sql security definer as $$ select content from conversation_messages where id = p_message $$;
create or replace function tj_typed(p_message uuid) returns text language sql security definer as $$ select coalesce(body, '') from whatsapp_outbox where message_id = p_message $$;
create or replace function tj_alert(p_event text, p_ref text) returns alert_events language sql security definer as $$
  select * from alert_events where event = p_event and ref_key = p_ref $$;
create or replace function tj_request(p_res uuid) returns stay_extension_requests language sql security definer as $$
  select * from stay_extension_requests where reservation_id = p_res order by created_at desc limit 1 $$;
create or replace function tj_charges(p_res uuid) returns bigint language sql security definer as $$
  select coalesce(sum(total_halalas), 0)::bigint from reservation_charges where reservation_id = p_res $$;
create or replace function tj_token(p uuid) returns text language sql security definer as $$ insert into registration_sessions(reservation_id) values (p) returning token $$;
create or replace function tj_shift(p uuid, p_days int) returns void language plpgsql security definer as $$
begin
  update reservation_allocations set from_date = from_date + p_days, to_date = to_date + p_days where reservation_id = p;
  update reservation_nights set night = night + p_days where reservation_id = p;
  update reservation_charges set service_from = service_from + p_days, service_to = service_to + p_days where reservation_id = p;
  update reservations set check_in = check_in + p_days, check_out = check_out + p_days where id = p;
end $$;
create or replace function tj_no_phone(p uuid) returns void language plpgsql security definer as $$
begin
  update guest_profiles set phone = '' where id in (select guest_profile_id from reservation_guests where reservation_id = p);
  update reservation_guests set phone = null where reservation_id = p;
end $$;
create or replace function tj_audits(p_action text, p_entity uuid) returns bigint language sql security definer as $$
  select count(*) from audit_events where action = p_action and entity_id = p_entity $$;
create or replace function tj_audit_reason(p_action text, p_entity uuid) returns text language sql security definer as $$
  select details->>'reason' from audit_events where action = p_action and entity_id = p_entity order by created_at desc limit 1 $$;
create or replace function tj_rule_audits() returns setof audit_events language sql security definer as $$ select * from audit_events where action = 'alert_rule.changed' $$;
create or replace function tj_check_in(p_res uuid, p_room uuid) returns void language sql security definer as $$
  update reservations set status = 'checked_in', room_id = p_room, actual_check_in = now() where id = p_res $$;
create or replace function tj_review_token(p_res uuid) returns text language plpgsql security definer as $$
declare t text := encode(extensions.gen_random_bytes(18), 'hex');
begin
  update guest_reviews set token_hash = encode(extensions.digest(t, 'sha256'), 'hex') where reservation_id = p_res;
  return t;
end $$;
-- (as the owner) a stay in a room of the branch: from today − p_from for p_nights, with the guest's phone, checked in
create or replace function tj_stay(p_key text, p_phone text, p_room text, p_from int default -1, p_nights int default 1, p_in boolean default true) returns uuid language plpgsql as $$
declare r jsonb; b uuid := tj_id('b'); res uuid;
begin
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b, 'category_id', tj_id('cat'), 'check_in', (tj_today(b) + greatest(p_from, 0))::text,
         'check_out', (tj_today(b) + greatest(p_from, 0) + p_nights)::text, 'guest_phone', p_phone, 'guest_name', 'نزيل الرحلة', 'room_id', tj_id(p_room),
         'source_id', '00000000-0000-0000-0000-000000000021'));
  res := (r->>'id')::uuid;
  insert into ids values (p_key, res);
  if p_from < 0 then perform tj_shift(res, p_from); end if;
  perform fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind', 'receipt', 'received_confirmed', true, 'amount_halalas', (tj_fin(res)->>'total')::bigint, 'method', 'cash', 'idempotency_key', 'tj-rent-' || p_key));
  if p_in then perform tj_check_in(res, tj_id(p_room)); end if;
  return res;
end $$;

-- ---------------------------------------------------------------- the branch, its rooms, its number, its people
select tj_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; b uuid; cat uuid; i int; begin
  r := fn_admin_upsert_branch('{"name_ar":"فرع الرحلة","name_en":"Journey branch"}'); b := (r->>'id')::uuid;
  insert into ids values ('b', b);
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', b, 'name_ar', 'غرفة الرحلة', 'base_price_halalas', 10000)); cat := (r->>'id')::uuid;
  insert into ids values ('cat', cat);
  for i in 1..15 loop
    r := fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', (870 + i)::text)); insert into ids values ('room' || i, (r->>'id')::uuid);
  end loop;
exception when others then perform tj_record('JM00 the branch, its rooms and its people are set up', false, sqlerrm);
end $$;
reset role;
-- the branch's clock: a time zone where it is now between 10 and 11 in the morning (Etc/GMT±n, whole hours)
update branches set timezone = (select 'Etc/GMT' || case when off > 0 then '-' || off when off < 0 then '+' || (-off) else '' end
                                  from (select case when o > 14 then o - 24 else o end as off
                                          from (select ((10 - extract(hour from now() at time zone 'UTC')::int) % 24 + 24) % 24 as o) a) z)
 where id = tj_id('b');
select tj_record('JM00c the branch of the checks is in its morning (between 10 and 11)', fn_journey_local_time(tj_id('b')) between '10:00' and '10:59:59',
  (select timezone from branches where id = tj_id('b')) || ' ' || fn_journey_local_time(tj_id('b'))::text);
-- the branch's WhatsApp on the reception computer; its responsible (a supervisor with a phone); the manager's phone
insert into branch_whatsapp_channels(branch_id, organization_id, mode, enabled, display_phone, bridge_key_hash, bridge_key_last4, bridge_key_created_at)
values (tj_id('b'), '00000000-0000-0000-0000-000000000001', 'web_bridge', true, '966551000870', encode(extensions.digest('zj_' || repeat('b', 64), 'sha256'), 'hex'), 'bbbb', now());
insert into staff_profiles(id, auth_user_id, organization_id, full_name, email, phone, role, is_active)
values ('10000000-0000-0000-0000-0000000000e1', 'a0000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-000000000001', 'مسؤول الرحلة', 'journey@test.local', '0551000871', 'supervisor', true),
       ('10000000-0000-0000-0000-0000000000e2', 'a0000000-0000-0000-0000-0000000000e2', '00000000-0000-0000-0000-000000000001', 'مشرف بلا جوال', 'journey2@test.local', null, 'supervisor', true)
on conflict (id) do nothing;
insert into branch_memberships(staff_id, branch_id) values ('10000000-0000-0000-0000-0000000000e1', tj_id('b')), ('10000000-0000-0000-0000-0000000000e2', tj_id('b')),
                                                          ('10000000-0000-0000-0000-000000000008', tj_id('b')), ('10000000-0000-0000-0000-000000000003', tj_id('b'))
on conflict do nothing;
update staff_profiles set phone = '0551000878' where id = '10000000-0000-0000-0000-000000000008';

-- ---------------------------------------------------------------- JM01 the settings of a new branch
select tj_record('JM01 a new branch has the journey''s settings at the decided values: the message at 10:00, free until 1 PM, 5 riyals an hour, an hour of cleaning, 30 minutes to pay, the deposit within 3 hours, the review after 60 minutes and under 9 alerting; and the eight alert rules',
  (select checkout_message_time = '10:00' and free_checkout_until = '13:00' and late_hour_price_halalas = 500 and cleaning_buffer_minutes = 60 and hold_minutes = 30
          and deposit_refund_hours = 3 and review_delay_minutes = 60 and review_alert_below = 9 and journey_enabled
     from branch_journey_settings where branch_id = tj_id('b'))
  and (select count(*) from alert_rules where organization_id = '00000000-0000-0000-0000-000000000001') = 8
  and (select recipients = '{owner}' and channel = 'both' and escalate_after_minutes is null from alert_rules where organization_id = '00000000-0000-0000-0000-000000000001' and event = 'review_low')
  and (select recipients = '{responsible}' and escalate_after_minutes = 30 and escalate_to = 'fallback' from alert_rules where organization_id = '00000000-0000-0000-0000-000000000001' and event = 'deposit_overdue'));

-- ---------------------------------------------------------------- AR07 the settings: who may change them, and what is refused
select tj_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
set role authenticated;
select tj_record('AR07a the journey''s settings are the owner''s and the manager''s: a supervisor cannot read or change them',
  tj_fails(format('select fn_admin_journey_settings(%L)', tj_id('b')), '%FORBIDDEN%') in ('ok', 'accepted') is not null
  and tj_fails(format('select fn_admin_journey_settings_save(%L, %L)', tj_id('b'), '{"version":1,"hold_minutes":20}'), '%FORBIDDEN%') = 'ok');
reset role;
select tj_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare b uuid := tj_id('b'); v int; e text[]; s jsonb; begin
  s := fn_admin_journey_settings(b); v := (s->>'version')::int;
  e := array[
    tj_fails(format('select fn_admin_journey_settings_save(%L, %L)', b, jsonb_build_object('version', v, 'checkout_message_time', '25:00')), 'VALIDATION: journey_time%'),
    tj_fails(format('select fn_admin_journey_settings_save(%L, %L)', b, jsonb_build_object('version', v, 'free_checkout_until', '09:00')), 'VALIDATION: journey_time%'),
    tj_fails(format('select fn_admin_journey_settings_save(%L, %L)', b, jsonb_build_object('version', v, 'free_checkout_until', '11:30')), 'VALIDATION: free_checkout_until%'),
    tj_fails(format('select fn_admin_journey_settings_save(%L, %L)', b, jsonb_build_object('version', v, 'late_hour_price_halalas', '-5')), 'VALIDATION: amount%'),
    tj_fails(format('select fn_admin_journey_settings_save(%L, %L)', b, jsonb_build_object('version', v, 'cleaning_buffer_minutes', 300)), 'VALIDATION: cleaning_buffer%'),
    tj_fails(format('select fn_admin_journey_settings_save(%L, %L)', b, jsonb_build_object('version', v, 'hold_minutes', 2)), 'VALIDATION: hold_minutes%'),
    tj_fails(format('select fn_admin_journey_settings_save(%L, %L)', b, jsonb_build_object('version', v, 'deposit_refund_hours', 0)), 'VALIDATION: refund_hours%'),
    tj_fails(format('select fn_admin_journey_settings_save(%L, %L)', b, jsonb_build_object('version', v, 'review_delay_minutes', 5)), 'VALIDATION: review_delay%'),
    tj_fails(format('select fn_admin_journey_settings_save(%L, %L)', b, jsonb_build_object('version', v, 'review_alert_below', 11)), 'VALIDATION: review_alert_below%'),
    tj_fails(format('select fn_admin_journey_settings_save(%L, %L)', b, jsonb_build_object('version', v, 'responsible_staff_id', '10000000-0000-0000-0000-000000000006')), 'VALIDATION: journey_staff%'),
    tj_fails(format('select fn_admin_journey_settings_save(%L, %L)', b, jsonb_build_object('version', v, 'responsible_staff_id', '10000000-0000-0000-0000-000000000003')), 'VALIDATION: journey_staff%'),
    tj_fails(format('select fn_admin_journey_settings_save(%L, %L)', b, jsonb_build_object('version', v - 1, 'hold_minutes', 20)), 'VERSION_CONFLICT%'),
    tj_fails(format('select fn_admin_journey_settings_save(%L, %L)', b, '{"hold_minutes":20}'), 'VERSION_REQUIRED%')];
  perform fn_admin_journey_settings_save(b, jsonb_build_object('version', v, 'responsible_staff_id', '10000000-0000-0000-0000-0000000000e1',
                                         'fallback_staff_id', '10000000-0000-0000-0000-000000000008', 'checkout_instructions', 'ضع المفتاح في الصندوق وأغلق الباب.'));
  s := fn_admin_journey_settings(b);
  perform tj_record('AR07b the owner sets the journey''s numbers and people; a time that is not a time, a free hour before the message or the check-out hour, a negative price, too long a cleaning, too short a hold, no refund hours, too short a review delay, a mark over 10, a responsible who does not work in the branch or is not a supervisor, a stale version — each refused; the save is logged',
    e = array_fill('ok'::text, array[13]) and s->>'responsible_staff_id' = '10000000-0000-0000-0000-0000000000e1' and s->>'fallback_staff_id' = '10000000-0000-0000-0000-000000000008'
    and (s->>'channel_ready')::boolean and jsonb_array_length(s->'staff') >= 3
    and tj_audits('journey.settings_changed', b) = 1,
    array_to_string(e, ' / '));
exception when others then perform tj_record('AR07b the owner sets the journey''s numbers and people', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- the stays of the checks
select tj_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ begin
  perform tj_stay('resA', '0552100001', 'room1');            -- leaving today, room free tonight
  -- leaving today, and the next guest arrives in its room today (booked before this guest checked in: a guest in the
  -- house on their day of departure keeps the room from a new arrival)
  perform tj_stay('resB', '0552100002', 'room2', -1, 1, false);
  perform tj_stay('nextB', '0552100022', 'room2', 0, 2, false);
  perform tj_check_in(tj_id('resB'), tj_id('room2'));
  perform tj_stay('resC', '0552100003', 'room3');            -- leaving today: hours then not paid
  perform tj_stay('resD', '0552100004', 'room4', -1, 2);     -- leaving tomorrow: no options today
  perform tj_stay('resE', '0552100005', 'room5');            -- leaving today: a night then not paid
  perform tj_stay('resF', '0552100006', 'room6');            -- leaving today; its phone is then taken away (no number to reach)
  perform tj_no_phone(tj_id('resF'));
exception when others then perform tj_record('JM00b the stays of the checks are set up', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- CX01–CX02 what the guest may choose
select tj_record('CX01 on the day of departure the guest is offered a night more at the stay''s own night''s price (the room is free tonight) and hours after 1 PM at 5.00 an hour up to midnight (no next guest); a stay leaving tomorrow is offered nothing today',
  (fn_checkout_offer(tj_id('resA'))->>'open')::boolean and (fn_checkout_offer(tj_id('resA'))->'night'->>'available')::boolean
  and (fn_checkout_offer(tj_id('resA'))->'night'->>'price_halalas')::bigint = 10000
  and (fn_checkout_offer(tj_id('resA'))->'hours'->>'max')::int = 11 and (fn_checkout_offer(tj_id('resA'))->'hours'->>'price_halalas')::bigint = 500
  and fn_checkout_offer(tj_id('resA'))->'hours'->>'until_limit' = '24:00'
  and not (fn_checkout_offer(tj_id('resD'))->>'open')::boolean,
  fn_checkout_offer(tj_id('resA'))::text);
select tj_record('CX02 the next guest arrives in the room today: no night more, and the hours stop an hour of cleaning before their arrival (4 PM): two hours, until 3 PM',
  not (fn_checkout_offer(tj_id('resB'))->'night'->>'available')::boolean and (fn_checkout_offer(tj_id('resB'))->'hours'->>'max')::int = 2
  and fn_checkout_offer(tj_id('resB'))->'hours'->>'until_limit' = '15:00' and (fn_checkout_offer(tj_id('resB'))->'hours'->>'next_guest')::boolean,
  fn_checkout_offer(tj_id('resB'))::text);

-- ---------------------------------------------------------------- JM02–JM04 the 10 o'clock message
do $$ declare t1 jsonb; t2 jsonb; m journey_messages%rowtype; cv conversations%rowtype; mb journey_messages%rowtype; begin
  t1 := tj_tick(tj_id('b'), tj_at(tj_id('b'), '09:59'));
  insert into notes values ('before10', tj_msg_count(tj_id('resA'), 'checkout_options')::text);
  t2 := tj_tick(tj_id('b'), tj_at(tj_id('b'), '10:01'));
  m := tj_msg(tj_id('resA'), 'checkout_options');
  select * into cv from conversations where id = m.conversation_id;
  mb := tj_msg(tj_id('resB'), 'checkout_options');
  perform tj_tick(tj_id('b'), tj_at(tj_id('b'), '10:05'));
  perform tj_record('JM02 at 10:00 on the day of departure the guest gets the options once, on the branch''s WhatsApp: in their conversation bound to the stay, with the numbered options the reception computer types and the menu their answer is read against; nothing before 10, nothing twice, nothing to a stay leaving tomorrow',
    tj_note('before10') = '0' and m.status = 'queued' and m.ref_key = tj_today(tj_id('b'))::text
    and tj_msg_count(tj_id('resA'), 'checkout_options') = 1 and tj_msg_count(tj_id('resD'), 'checkout_options') = 0
    and cv.wa_contact = '966552100001' and cv.wa_chat_id = '966552100001@c.us' and cv.reservation_id = tj_id('resA') and fn_token_reservation(cv.guest_token) = tj_id('resA')
    and jsonb_array_length(cv.wa_menu->'options') = 4
    and (select string_agg(o->>'id', ',' order by (o->>'n')::int) from jsonb_array_elements(cv.wa_menu->'options') o) = 'CO:ONTIME,CO:NIGHT,CO:HOURS,HUMAN'
    and tj_text(m.message_id) like '%بين 12 و1 ظهرًا%' and tj_text(m.message_id) like '%' || chr(49) || chr(65039) || chr(8419) || ' سأخرج في الموعد (12–1)%'
    and tj_text(m.message_id) like '%ليلة إضافية — 100.00 ر.س%' and tj_text(m.message_id) like '%أرسل رقم الخيار.'
    and (select string_agg(o->>'id', ',' order by (o->>'n')::int) from jsonb_array_elements((select wa_menu from conversations where id = mb.conversation_id)->'options') o) = 'CO:ONTIME,CO:HOURS,HUMAN',
    coalesce(tj_text(m.message_id), 'none') || ' / ' || t2::text);
exception when others then perform tj_record('JM02 at 10:00 on the day of departure the guest gets the options once', false, sqlerrm);
end $$;
do $$ declare out jsonb; m journey_messages%rowtype; o whatsapp_outbox%rowtype; ok boolean; begin
  m := tj_msg(tj_id('resA'), 'checkout_options');
  out := fn_wa_bridge_poll(tj_id('b'), 20);
  select * into o from whatsapp_outbox where message_id = m.message_id;
  ok := fn_wa_bridge_ack(tj_id('b'), o.id, true, 'wa-1', null);
  perform tj_record('JM03 the reception computer picks the message with the guest''s chat and its text, and its confirmation marks it sent',
    exists (select 1 from jsonb_array_elements(out) x where x->>'chat_id' = '966552100001@c.us' and x->>'text' like '%سأخرج في الموعد%')
    and o.status = 'sending' and ok and (select status from whatsapp_outbox where id = o.id) = 'sent'
    and (select meta->>'delivery' from conversation_messages where id = m.message_id) = 'sent',
    out::text);
exception when others then perform tj_record('JM03 the reception computer picks the message with the guest''s chat and its text', false, sqlerrm);
end $$;
select tj_record('JM04a a stay with no phone gets no message: it is recorded why, and the responsible is told to inform the guest',
  (tj_msg(tj_id('resF'), 'checkout_options')).status = 'skipped' and (tj_msg(tj_id('resF'), 'checkout_options')).reason = 'no_phone'
  and (tj_alert('message_failed', 'journey:' || tj_id('resF') || ':checkout_options:' || tj_today(tj_id('b')))).id is not null,
  (tj_msg(tj_id('resF'), 'checkout_options'))::text);

-- ---------------------------------------------------------------- CX03–CX04 the guest chooses
select tj_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
reset role;
do $$ declare tok text := tj_token(tj_id('resB')); e1 text; e2 text; o jsonb; q stay_extension_requests%rowtype; a alert_events%rowtype; total0 bigint; begin
  total0 := (tj_res(tj_id('resB'))).total_halalas;
  set local role anon;
  e1 := tj_fails(format('select fn_guest_checkout_choose(%L, %L, 3)', tok, 'hours'), 'VALIDATION: late_hours%');
  o := fn_guest_checkout_choose(tok, 'hours', 2);
  e2 := tj_fails(format('select fn_guest_checkout_choose(%L, %L)', tok, 'night'), 'VALIDATION: extension_pending%');
  reset role;
  q := tj_request(tj_id('resB')); a := tj_alert('extension_requested', 'extension:' || q.id);
  perform tj_record('CX03 the guest asks for two hours from their page: the line «خروج متأخر ساعتان حتى 15:00» at 5.00 an hour joins the stay, the room is theirs until 3 PM, the request is held 30 minutes for the payment, and the responsible is told in the system and on WhatsApp; more hours than the room allows, or a second request while one is held, are refused',
    e1 = 'ok' and e2 = 'ok' and q.kind = 'hours' and q.hours = 2 and q.status = 'held' and q.amount_halalas = 1000
    and q.hold_until between now() + interval '29 minutes' and now() + interval '31 minutes'
    and (tj_res(tj_id('resB'))).late_checkout_until = '15:00' and (tj_res(tj_id('resB'))).total_halalas = total0 + 1000
    and exists (select 1 from reservation_charges where reservation_id = tj_id('resB') and description = 'خروج متأخر ساعتان حتى 15:00' and total_halalas = 1000)
    and o->'request'->>'status' = 'held' and a.notified_at is not null
    and exists (select 1 from jsonb_array_elements(a.notified_to) x where x->>'staff_id' = '10000000-0000-0000-0000-0000000000e1' and x->>'whatsapp' = 'queued'),
    e1 || ' / ' || e2 || ' / ' || coalesce(q::text, 'no request') || ' / ' || coalesce(a.notified_to::text, 'not told'));
exception when others then perform tj_record('CX03 the guest asks for two hours from their page', false, sqlerrm);
end $$;
-- (the clock is read below at chosen hours of today: this request is kept out of their way until it is paid in DR04)
update stay_extension_requests set hold_until = now() + interval '1 day' where reservation_id = tj_id('resB') and status = 'held';
do $$ declare tok text := tj_token(tj_id('resA')); o jsonb; q stay_extension_requests%rowtype; total0 bigint; free_tonight boolean; begin
  total0 := (tj_res(tj_id('resA'))).total_halalas;
  set local role anon;
  o := fn_guest_checkout_choose(tok, 'night');
  reset role;
  q := tj_request(tj_id('resA'));
  free_tonight := fn_room_free_internal(tj_id('room1'), tj_today(tj_id('b')), tj_today(tj_id('b')) + 1, null);
  perform tj_record('CX04 the guest takes a night more: the stay ends tomorrow at its own night''s price, the room is theirs tonight (no one else may take it), and the night is held 30 minutes for the payment',
    q.kind = 'night' and q.status = 'held' and q.amount_halalas = 10000 and q.previous_check_out = tj_today(tj_id('b'))
    and (tj_res(tj_id('resA'))).check_out = tj_today(tj_id('b')) + 1 and (tj_res(tj_id('resA'))).total_halalas = total0 + 10000 and not free_tonight
    and not (o->>'open')::boolean,
    coalesce(q::text, 'no request') || ' / ' || o::text);
exception when others then perform tj_record('CX04 the guest takes a night more', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- CX05 paid: it stands
select tj_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ begin
  perform fn_create_voucher(jsonb_build_object('reservation_id', tj_id('resA'), 'kind', 'receipt', 'received_confirmed', true, 'amount_halalas', (tj_fin(tj_id('resA'))->>'balance_due')::bigint, 'method', 'cash', 'idempotency_key', 'tj-night-a'));
exception when others then perform tj_record('CX05 the night is paid', false, sqlerrm);
end $$;
reset role;
do $$ declare q stay_extension_requests%rowtype; begin
  perform tj_tick(tj_id('b'), tj_at(tj_id('b'), '10:20'));
  q := tj_request(tj_id('resA'));
  perform tj_record('CX05 the stay''s balance is paid: the night stands, the guest is told on WhatsApp, and the alert is closed',
    q.status = 'paid' and (tj_msg(tj_id('resA'), 'extension_confirmed')).status = 'queued' and tj_text((tj_msg(tj_id('resA'), 'extension_confirmed')).message_id) like '%تم تثبيت ليلتك الإضافية%'
    and (tj_alert('extension_requested', 'extension:' || q.id)).resolved_at is not null,
    q::text);
exception when others then perform tj_record('CX05 the stay''s balance is paid: the night stands', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- CX06–CX07 not paid in time
do $$ declare tokc text := tj_token(tj_id('resC')); toke text := tj_token(tj_id('resE')); total_c bigint; total_e bigint; late_c time; tax_c bigint; begin
  total_c := (tj_res(tj_id('resC'))).total_halalas; total_e := (tj_res(tj_id('resE'))).total_halalas; late_c := (tj_res(tj_id('resC'))).late_checkout_until;
  perform fn_guest_checkout_choose(tokc, 'hours', 3);
  perform fn_guest_checkout_choose(toke, 'night');
  insert into notes values ('total_c', total_c::text), ('total_e', total_e::text), ('late_c', coalesce(late_c::text, 'null'));
exception when others then perform tj_record('CX06 hours and a night are held', false, sqlerrm);
end $$;
update stay_extension_requests set hold_until = tj_at(tj_id('b'), '11:00') where reservation_id in (tj_id('resC'), tj_id('resE')) and status = 'held';
do $$ declare qc stay_extension_requests%rowtype; qe stay_extension_requests%rowtype; begin
  perform tj_tick(tj_id('b'), tj_at(tj_id('b'), '11:30'));
  qc := tj_request(tj_id('resC')); qe := tj_request(tj_id('resE'));
  perform tj_record('CX06 not paid in its 30 minutes (before 1 PM): the hours and the night are given back — the night returns to the room, the late hours'' line has its exact opposite, the stay''s total and departure are as before — and the guest is told',
    qc.status = 'released' and qe.status = 'released'
    and (tj_res(tj_id('resC'))).total_halalas::text = tj_note('total_c') and coalesce((tj_res(tj_id('resC'))).late_checkout_until::text, 'null') = tj_note('late_c')
    and (tj_res(tj_id('resE'))).total_halalas::text = tj_note('total_e') and (tj_res(tj_id('resE'))).check_out = tj_today(tj_id('b'))
    and fn_room_free_internal(tj_id('room5'), tj_today(tj_id('b')), tj_today(tj_id('b')) + 1, tj_id('resE'))
    and (tj_msg(tj_id('resC'), 'extension_released')).status = 'queued' and (tj_msg(tj_id('resE'), 'extension_released')).status = 'queued'
    and (tj_alert('extension_requested', 'extension:' || qc.id)).resolved_at is not null,
    qc::text || ' / ' || qe::text || ' / ' || (tj_res(tj_id('resC'))).total_halalas || ' vs ' || tj_note('total_c'));
exception when others then perform tj_record('CX06 not paid in its 30 minutes: the hours and the night are given back', false, sqlerrm);
end $$;
do $$ declare tok text := tj_token(tj_id('resC')); q stay_extension_requests%rowtype; begin
  perform fn_guest_checkout_choose(tok, 'hours', 1);
  update stay_extension_requests set hold_until = tj_at(tj_id('b'), '12:50') where reservation_id = tj_id('resC') and status = 'held';
  perform tj_tick(tj_id('b'), tj_at(tj_id('b'), '13:10'));
  q := tj_request(tj_id('resC'));
  perform tj_record('CX07 not paid and the free hour is over (after 1 PM): nothing is given back behind the guest — it is overdue, and the responsible is told to collect or cancel it',
    q.status = 'overdue' and (tj_alert('extension_unpaid', 'extension:' || q.id)).notified_at is not null and (tj_res(tj_id('resC'))).late_checkout_until = '14:00',
    q::text);
exception when others then perform tj_record('CX07 not paid and the free hour is over', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- CX08 leaving on time, cancelling, what is refused
do $$ declare tokd text := tj_token(tj_id('resD')); tokf text := tj_token(tj_id('resF')); e1 text; e2 text; e3 text; o jsonb; begin
  set local role anon;
  e1 := tj_fails(format('select fn_guest_checkout_choose(%L, %L)', tokd, 'on_time'), 'VALIDATION: checkout_not_today%');
  e2 := tj_fails(format('select fn_guest_checkout_choose(%L, %L)', tokf, 'stay'), 'VALIDATION: checkout_choice%');
  e3 := tj_fails(format('select fn_guest_checkout_choose(%L, %L)', tokf, 'cancel'), 'VALIDATION: extension_none%');
  o := fn_guest_checkout_choose(tokf, 'on_time');
  reset role;
  perform tj_record('CX08 the guest says they leave between 12 and 1 (nothing charged, recorded); a choice on another day, an unknown choice, or cancelling nothing is refused',
    e1 = 'ok' and e2 = 'ok' and e3 = 'ok' and o->>'choice' = 'on_time' and (tj_res(tj_id('resF'))).checkout_choice = 'on_time'
    and tj_charges(tj_id('resF')) = (tj_res(tj_id('resF'))).total_halalas,
    e1 || ' / ' || e2 || ' / ' || e3);
exception when others then perform tj_record('CX08 the guest says they leave between 12 and 1', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- CX09 the reception decides a request
select tj_login('a0000000-0000-0000-0000-000000000003', 'hk@test.local');
set role authenticated;
select tj_record('CX09a housekeeping does not decide an extension', tj_fails(format('select fn_staff_extension_decide(%L, %L, %L, 1)', (tj_request(tj_id('resC'))).id, 'confirm', 'x'), '%FORBIDDEN%') = 'ok');
reset role;
select tj_login('a0000000-0000-0000-0000-0000000000e1', 'journey@test.local');
set role authenticated;
do $$ declare q stay_extension_requests%rowtype; e1 text; e2 text; r jsonb; begin
  q := tj_request(tj_id('resC'));
  e1 := tj_fails(format('select fn_staff_extension_decide(%L, %L, %L, %s)', q.id, 'confirm', '', q.version), 'VALIDATION: reason%');
  e2 := tj_fails(format('select fn_staff_extension_decide(%L, %L, %L, %s)', q.id, 'confirm', 'يدفع عند الخروج', q.version + 1), 'VERSION_CONFLICT%');
  r := fn_staff_extension_decide(q.id, 'confirm', 'يدفع عند الخروج', q.version);
  perform tj_record('CX09b the responsible keeps an overdue request without its payment now, with a reason: it stands, its alert closes, and the guest is told it stands; no reason, or a stale version, is refused',
    e1 = 'ok' and e2 = 'ok' and r->>'status' = 'confirmed' and (tj_alert('extension_unpaid', 'extension:' || q.id)).resolved_at is not null
    and tj_audits('journey.extension_confirmed', q.id) = 1
    and (select tj_text(message_id) from journey_messages where reservation_id = tj_id('resC') and kind = 'extension_confirmed' and ref_key = q.id::text) = 'تم تثبيت خروجك المتأخر حتى 14:00.',
    e1 || ' / ' || e2 || ' / ' || r::text);
exception when others then perform tj_record('CX09b the responsible keeps an overdue request without its payment now', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- CX10 the reception's own extension is as it was
select tj_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; v int; e1 text; begin
  v := (tj_res(tj_id('resD'))).version;
  e1 := tj_fails(format('select fn_staff_amend_stay(%L, %L, %L, %L)', tj_id('resD'), (tj_res(tj_id('resD'))).check_out + 1, 'keep_rate', 'تمديد'), 'VERSION_REQUIRED%');
  r := fn_staff_amend_stay(tj_id('resD'), (tj_res(tj_id('resD'))).check_out + 1, 'keep_rate', 'تمديد بطلب النزيل', v);
  perform tj_record('CX10 the reception''s «تمديد» is the same after the guest''s own extension came: it needs its version and extends at the stay''s price',
    e1 = 'ok' and (r->>'delta_nights')::int = 1 and (tj_res(tj_id('resD'))).check_out = tj_today(tj_id('b')) + 2, e1 || ' / ' || r::text);
exception when others then perform tj_record('CX10 the reception''s «تمديد» is the same', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- CX11–CX12 hours chosen late in the day; more hours after hours
select tj_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ begin
  perform tj_stay('resJ', '0552100010', 'room10');           -- leaving today: hours chosen in the evening
  perform tj_stay('resK', '0552100011', 'room11');           -- leaving today: two hours, then one more
exception when others then perform tj_record('CX11 the stays are made', false, sqlerrm);
end $$;
reset role;
do $$ declare b uuid := tj_id('b'); e1 text; e2 text; o jsonb; q stay_extension_requests%rowtype; total0 bigint; begin
  total0 := (tj_res(tj_id('resJ'))).total_halalas;
  o := fn_checkout_offer(tj_id('resJ'), tj_at(b, '18:20'));
  e1 := tj_fails(format('select fn_checkout_choose(%L, %L, 1, %L, %L::timestamptz)', tj_id('resJ'), 'hours', 'page', tj_at(b, '18:20')), 'VALIDATION: late_hours%');
  e2 := tj_fails(format('select fn_checkout_choose(%L, %L, 5, %L, %L::timestamptz)', tj_id('resJ'), 'hours', 'page', tj_at(b, '18:20')), 'VALIDATION: late_hours%');
  perform fn_checkout_choose(tj_id('resJ'), 'hours', 6, 'page', tj_at(b, '18:20'));
  q := tj_request(tj_id('resJ'));
  perform tj_record('CX11 at 6:20 PM a guest still in the room is offered no fewer hours than they stayed past 1 PM (a part of an hour is a whole hour): one hour or five are refused; six — until 7 PM — are charged 30.00',
    (o->'hours'->>'min')::int = 6 and (o->'hours'->>'have')::int = 0 and e1 = 'ok' and e2 = 'ok'
    and q.hours = 6 and q.late_until = '19:00' and q.amount_halalas = 3000 and (tj_res(tj_id('resJ'))).late_checkout_until = '19:00'
    and (tj_res(tj_id('resJ'))).total_halalas = total0 + 3000,
    e1 || ' / ' || e2 || ' / ' || (o->'hours')::text);
exception when others then perform tj_record('CX11 hours chosen late in the day', false, sqlerrm);
end $$;
do $$ declare tok text := tj_token(tj_id('resK')); begin
  insert into notes values ('totalK0', (tj_res(tj_id('resK'))).total_halalas::text), ('tokK', tok);
  set local role anon;
  perform fn_guest_checkout_choose(tok, 'hours', 2);
exception when others then perform tj_record('CX12 two hours are taken', false, sqlerrm);
end $$;
select tj_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ begin
  perform fn_create_voucher(jsonb_build_object('reservation_id', tj_id('resK'), 'kind', 'receipt', 'received_confirmed', true, 'amount_halalas', (tj_fin(tj_id('resK'))->>'balance_due')::bigint, 'method', 'cash', 'idempotency_key', 'tj-hours-k'));
exception when others then perform tj_record('CX12 the two hours are paid', false, sqlerrm);
end $$;
reset role;
do $$ declare tok text := tj_note('tokK'); o1 jsonb; e1 text; e2 text; q stay_extension_requests%rowtype; q0 stay_extension_requests%rowtype; begin
  perform tj_tick(tj_id('b'), tj_at(tj_id('b'), '10:50'));
  q0 := tj_request(tj_id('resK'));
  set local role anon;
  o1 := fn_guest_checkout(tok);
  e1 := tj_fails(format('select fn_guest_checkout_choose(%L, %L, 2)', tok, 'hours'), 'VALIDATION: late_hours%');
  e2 := tj_fails(format('select fn_guest_checkout_choose(%L, %L, 1)', tok, 'hours'), 'VALIDATION: late_hours%');
  perform fn_guest_checkout_choose(tok, 'hours', 3);
  reset role;
  q := tj_request(tj_id('resK'));
  perform tj_record('CX12 hours bought are not sold again: after two paid hours (until 3 PM) the guest may only go further — two hours again, or one, are refused — and three hours charge the one hour more (5.00, until 4 PM); with late hours taken no night more is offered',
    q0.status = 'paid' and (o1->'hours'->>'have')::int = 2 and (o1->'hours'->>'min')::int = 3 and not (o1->'night'->>'available')::boolean
    and e1 = 'ok' and e2 = 'ok' and q.hours = 1 and q.late_until = '16:00' and q.amount_halalas = 500 and q.previous_late_until = '15:00'
    and (tj_res(tj_id('resK'))).late_checkout_until = '16:00' and (tj_res(tj_id('resK'))).total_halalas = tj_note('totalK0')::bigint + 1500
    and exists (select 1 from reservation_charges where reservation_id = tj_id('resK') and description = 'خروج متأخر ساعة واحدة حتى 16:00' and total_halalas = 500),
    e1 || ' / ' || e2 || ' / ' || (o1->'hours')::text || ' / ' || coalesce(q::text, ''));
exception when others then perform tj_record('CX12 more hours after hours', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- DR01–DR02 «غادرت وسلّمت المفتاح»
do $$ declare tok text := tj_token(tj_id('resF')); tokd text := tj_token(tj_id('resD')); r1 jsonb; r2 jsonb; e text; e0 text; e1 text; i0 jsonb; i1 jsonb; id0 jsonb;
                a alert_events%rowtype; begin
  set local role anon;
  e0 := tj_fails(format('select fn_guest_departure(%L)', tok), 'VALIDATION: instructions_first%');
  e1 := tj_fails(format('select fn_guest_departure(%L)', tokd), 'VALIDATION: not_departure_day%');
  id0 := fn_guest_departure_instructions(tokd);
  i0 := fn_guest_checkout(tok);
  i1 := fn_guest_departure_instructions(tok);
  r1 := fn_guest_departure(tok);
  r2 := fn_guest_departure(tok);
  e := tj_fails(format('select fn_guest_departure(%L)', tj_token(tj_id('nextB'))), 'VALIDATION: not_in_stay%');
  reset role;
  a := tj_alert('guest_departed', 'departed:' || tj_id('resF'));
  perform tj_record('DR01 «غادرت وسلّمت المفتاح» is taken only after the instructions reached the guest, and only on the day of departure: the page asks for the instructions (the moment is kept), then the stay waits for the reception''s check, the responsible is told at once (in the system and on WhatsApp), and saying it again changes nothing; a guest not in the house cannot say it',
    e0 = 'ok' and e1 = 'ok' and id0->>'instructions_at' is null and i0->>'instructions_at' is null and i1->>'instructions_at' is not null
    and i1->>'instructions' = 'ضع المفتاح في الصندوق وأغلق الباب.'
    and not (r1->>'already')::boolean and (r2->>'already')::boolean and e = 'ok' and (tj_res(tj_id('resF'))).guest_departed_at is not null
    and (tj_res(tj_id('resF'))).guest_departed_via = 'page' and (tj_res(tj_id('resF'))).status = 'checked_in'
    and a.notified_at is not null and a.title like '%بانتظار التحقق%' and a.body not like '%ر.س%'
    and exists (select 1 from jsonb_array_elements(a.notified_to) x where x->>'staff_id' = '10000000-0000-0000-0000-0000000000e1' and (x->>'app')::boolean and x->>'whatsapp' = 'queued'),
    e0 || ' / ' || e1 || ' / ' || r1::text || ' / ' || r2::text || ' / ' || e);
exception when others then perform tj_record('DR01 the guest says «غادرت وسلّمت المفتاح»', false, sqlerrm);
end $$;
select tj_login('a0000000-0000-0000-0000-0000000000e1', 'journey@test.local');
set role authenticated;
select tj_record('DR02 «رحلة الضيف» shows the stay waiting for its check, and the requests of the day',
  exists (select 1 from jsonb_array_elements(fn_staff_journey(tj_id('b'))->'awaiting_check') x where x->>'reservation_id' = tj_id('resF')::text)
  and exists (select 1 from jsonb_array_elements(fn_staff_journey(tj_id('b'))->'requests') x where x->>'reservation_id' = tj_id('resB')::text and x->>'status' = 'held')
  and (fn_staff_journey(tj_id('b'))->>'channel_ready')::boolean);
reset role;
select tj_login('a0000000-0000-0000-0000-000000000003', 'hk@test.local');
set role authenticated;
select tj_record('DR02b housekeeping does not read «رحلة الضيف»', tj_fails(format('select fn_staff_journey(%L)', tj_id('b')), '%FORBIDDEN%') = 'ok');
reset role;

-- ---------------------------------------------------------------- DR03–DR06 the check-out and the deposit
select tj_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; m journey_messages%rowtype; begin
  perform fn_create_voucher(jsonb_build_object('reservation_id', tj_id('resF'), 'kind', 'deposit', 'amount_halalas', 5000, 'method', 'cash', 'idempotency_key', 'tj-dep-f'));
  r := fn_staff_check_out(jsonb_build_object('reservation_id', tj_id('resF')));
  m := tj_msg(tj_id('resF'), 'checkout_confirmed');
  perform tj_record('DR03 the reception confirms the check-out: the departure''s alert closes, and the guest is told the deposit (50.00) is returned within 3 hours — the message is recorded even when the guest has no phone',
    (r->>'ok')::boolean and (tj_alert('guest_departed', 'departed:' || tj_id('resF'))).resolved_at is not null and m.id is not null and m.reason = 'no_phone',
    r::text || ' / ' || coalesce(m::text, 'no message'));
exception when others then perform tj_record('DR03 the reception confirms the check-out', false, sqlerrm);
end $$;
do $$ declare r jsonb; m journey_messages%rowtype; e1 text; e2 text; begin
  -- a guest with a phone: resB (the hours were held; pay them, then leave)
  perform fn_create_voucher(jsonb_build_object('reservation_id', tj_id('resB'), 'kind', 'receipt', 'received_confirmed', true, 'amount_halalas', (tj_fin(tj_id('resB'))->>'balance_due')::bigint, 'method', 'cash', 'idempotency_key', 'tj-hours-b'));
  perform fn_create_voucher(jsonb_build_object('reservation_id', tj_id('resB'), 'kind', 'deposit', 'amount_halalas', 5000, 'method', 'cash', 'idempotency_key', 'tj-dep-b'));
  r := fn_staff_check_out(jsonb_build_object('reservation_id', tj_id('resB')));
  m := tj_msg(tj_id('resB'), 'checkout_confirmed');
  insert into notes values ('checkout_b', tj_text(m.message_id));
  perform fn_staff_record_inspection(jsonb_build_object('reservation_id', tj_id('resB'), 'result', 'ok'));   -- the check before the deposit's return
  e1 := tj_fails(format('select fn_refund(%L::jsonb)', jsonb_build_object('reservation_id', tj_id('resB'), 'kind', 'deposit_refund', 'amount_halalas', 5000, 'method', 'pos', 'reference', 'T-1', 'reason', 'رد', 'idempotency_key', 'tj-ref-b0')), 'VALIDATION: deposit_method%');
  e2 := tj_fails(format('select fn_refund(%L::jsonb)', jsonb_build_object('reservation_id', tj_id('resB'), 'kind', 'deposit_refund', 'amount_halalas', 5000, 'method', 'bank_transfer', 'reason', 'رد', 'idempotency_key', 'tj-ref-b1')), '%reference%');
  insert into notes values ('refund_refused', e1 || ' ' || e2), ('receipt_before', tj_msg_count(tj_id('resB'), 'deposit_refunded')::text);
  perform tj_record('DR04 the guest with a phone is told on WhatsApp their check-out is confirmed and the deposit (50.00) comes back within 3 hours; a return by card terminal is refused (transfer or cash only), a transfer needs its number, and no receipt goes out before the return',
    (r->>'ok')::boolean and m.status = 'queued' and tj_note('checkout_b') like '%تم تأكيد خروجك%' and tj_note('checkout_b') like '%50.00 ر.س%' and tj_note('checkout_b') like '%3 ساعات%'
    and e1 = 'ok' and e2 = 'ok' and tj_note('receipt_before') = '0',
    coalesce(tj_note('checkout_b'), 'none') || ' / ' || e1 || ' / ' || e2);
exception when others then perform tj_record('DR04 the check-out is confirmed to the guest; the return is by transfer or cash', false, sqlerrm);
end $$;
reset role;
-- the deposit's hours pass before it is returned
update reservations set actual_check_out = now() - interval '200 minutes' where id = tj_id('resB');
do $$ declare a alert_events%rowtype; begin
  perform tj_tick(tj_id('b'));
  a := tj_alert('deposit_overdue', 'deposit:' || tj_id('resB'));
  perform tj_record('DR05 three hours after the confirmed check-out the deposit is still not returned: the responsible is told (in the system and on WhatsApp) — without the amount, which only those who see money read on «رحلة الضيف»',
    a.notified_at is not null and a.resolved_at is null and a.title like 'تأخر رد تأمين غرفة 872%' and a.title not like '%ر.س%' and coalesce(a.body, '') not like '%ر.س%'
    and exists (select 1 from jsonb_array_elements(a.notified_to) x where x->>'staff_id' = '10000000-0000-0000-0000-0000000000e1' and x->>'whatsapp' = 'queued'),
    coalesce(a::text, 'no alert'));
exception when others then perform tj_record('DR05 three hours after the confirmed check-out the deposit is still not returned', false, sqlerrm);
end $$;
do $$ declare a alert_events%rowtype; begin
  perform tj_tick(tj_id('b'), now() + interval '31 minutes');
  a := tj_alert('deposit_overdue', 'deposit:' || tj_id('resB'));
  perform tj_record('DR06 nobody acts for 30 minutes: the alert climbs to the fallback (the administration) by name — in the system (it is now theirs) and on WhatsApp — not to a whole level',
    a.escalated_at is not null
    and exists (select 1 from jsonb_array_elements(a.escalated_to) x where x->>'staff_id' = '10000000-0000-0000-0000-000000000008' and x->>'whatsapp' = 'queued' and (x->>'app')::boolean)
    and fn_alert_is_mine(a.notified_to, a.escalated_to, '10000000-0000-0000-0000-000000000008')
    and not exists (select 1 from notifications where branch_id = tj_id('b') and title like '%' || a.title),
    coalesce(a.escalated_to::text, 'not climbed'));
exception when others then perform tj_record('DR06 nobody acts for 30 minutes: the alert climbs', false, sqlerrm);
end $$;
select tj_record('DR06b hours held and not paid in time are given back with a message that tells the departure as it now stands: the two hours paid before stay (until 15:00)',
  (select tj_text(m.message_id) from journey_messages m where m.reservation_id = tj_id('resK') and m.kind = 'extension_released' order by m.created_at desc limit 1) like '%موعد خروجك اليوم حتى 15:00%'
  and (tj_res(tj_id('resK'))).late_checkout_until = '15:00',
  coalesce((select tj_text(m.message_id) from journey_messages m where m.reservation_id = tj_id('resK') and m.kind = 'extension_released' order by m.created_at desc limit 1), 'no message'));
select tj_login('a0000000-0000-0000-0000-0000000000e1', 'journey@test.local');
set role authenticated;
do $$ declare v jsonb; m journey_messages%rowtype; begin
  v := fn_refund(jsonb_build_object('reservation_id', tj_id('resB'), 'kind', 'deposit_refund', 'amount_halalas', 5000, 'method', 'bank_transfer', 'reference', 'TRX-7788', 'reason', 'رد التأمين', 'idempotency_key', 'tj-ref-b2'));
  reset role;
  m := tj_msg(tj_id('resB'), 'deposit_refunded');
  perform tj_tick(tj_id('b'));
  perform tj_record('DR07 the deposit is returned by transfer with its number: the receipt goes out to the guest with the amount, the transfer''s number and the voucher''s number, and the overdue alert closes',
    m.status = 'queued' and tj_text(m.message_id) like '%رُد إليك تأمينك 50.00 ر.س بالتحويل (رقم العملية TRX-7788)%' and tj_text(m.message_id) like '%' || (v->>'number') || '%'
    and (tj_alert('deposit_overdue', 'deposit:' || tj_id('resB'))).resolved_at is not null,
    coalesce(tj_text(m.message_id), 'none') || ' / ' || v::text);
exception when others then perform tj_record('DR07 the deposit is returned by transfer with its number: the receipt goes out', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- RW01–RW06 the review
update reservations set actual_check_out = now() - interval '30 minutes' where id = tj_id('resF');
do $$ begin perform tj_tick(tj_id('b')); insert into notes values ('reviews_at_30', (select count(*) from guest_reviews where reservation_id = tj_id('resF'))::text); end $$;
update reservations set actual_check_out = now() - interval '61 minutes' where id = tj_id('resF');
do $$ declare m journey_messages%rowtype; begin
  perform tj_tick(tj_id('b'));
  perform tj_tick(tj_id('b'));
  m := tj_msg(tj_id('resF'), 'review_invite');
  perform tj_record('RW01 60 minutes after the confirmed check-out one invitation to review is made (not before, never twice); its page''s key is typed in the message and kept only as its hash, never in the stored copy',
    tj_note('reviews_at_30') = '0' and (select count(*) from guest_reviews where reservation_id = tj_id('resF')) = 1
    and tj_msg_count(tj_id('resF'), 'review_invite') = 1 and m.reason = 'no_phone'
    and (select length(token_hash) from guest_reviews where reservation_id = tj_id('resF')) = 64,
    coalesce(m::text, 'none'));
exception when others then perform tj_record('RW01 60 minutes after the confirmed check-out one invitation to review is made', false, sqlerrm);
end $$;
do $$ declare m journey_messages%rowtype; begin
  m := tj_msg(tj_id('resB'), 'review_invite');            -- invited by the clock of DR05 (its check-out was set 200 minutes back)
  perform tj_record('RW01b on WhatsApp the typed message carries the review page''s key; the stored copy does not',
    m.status = 'queued' and tj_text(m.message_id) like '%/booking/review/…' and tj_typed(m.message_id) ~ '/booking/review/[0-9a-f]{36}$',
    tj_text(m.message_id) || ' / ' || tj_typed(m.message_id));
exception when others then perform tj_record('RW01b the typed message carries the key, the stored copy does not', false, sqlerrm);
end $$;
insert into notes values ('tokF', tj_review_token(tj_id('resF'))), ('tokB', tj_review_token(tj_id('resB')));
set role anon;
do $$ declare p jsonb; e text[]; begin
  p := fn_public_review(tj_note('tokF'));
  e := array[
    tj_fails(format('select fn_public_review(%L)', 'nope'), 'TOKEN_INVALID%'),
    tj_fails(format('select fn_public_submit_review(%L, %L)', tj_note('tokF'), '{"overall":9,"staff":9,"cleanliness":9,"comfort":9,"facilities":9,"value":9}'), 'VALIDATION: review_marks%'),
    tj_fails(format('select fn_public_submit_review(%L, %L)', tj_note('tokF'), '{"overall":11,"staff":9,"cleanliness":9,"comfort":9,"facilities":9,"value":9,"location":9}'), 'VALIDATION: review_marks%'),
    tj_fails(format('select fn_public_submit_review(%L, %L)', tj_note('tokF'), '{"overall":0,"staff":9,"cleanliness":9,"comfort":9,"facilities":9,"value":9,"location":9}'), 'VALIDATION: review_marks%'),
    tj_fails(format('select fn_public_submit_review(%L, %L)', tj_note('tokF'), '{"overall":"x","staff":9,"cleanliness":9,"comfort":9,"facilities":9,"value":9,"location":9}'), 'VALIDATION: review_marks%'),
    tj_fails(format('select fn_public_submit_review(%L, %L)', tj_note('tokF'), jsonb_build_object('overall', 9, 'staff', 9, 'cleanliness', 9, 'comfort', 9, 'facilities', 9, 'value', 9, 'location', 9, 'comment', repeat('أ', 1001))), 'VALIDATION: review_comment%'),
    tj_fails(format('select fn_staff_reviews(%L)', tj_id('b')), '%permission denied%')];
  perform fn_public_submit_review(tj_note('tokF'), '{"overall":7,"staff":8,"cleanliness":6,"comfort":7,"facilities":7,"value":8,"location":9,"comment":"الغرفة تحتاج تهوية"}');
  perform tj_record('RW02 the review''s page opens by its key with the branch, the dates and the six aspects; an overall mark asked on its own and each aspect from 1 to 10 — a missing aspect, 11, 0, a word, a comment over 1000 letters are refused; a visitor reads no staff list',
    p->>'branch_name' = 'فرع الرحلة' and jsonb_array_length(p->'aspects') = 6 and not (p->>'submitted')::boolean and e = array_fill('ok'::text, array[7]),
    array_to_string(e, ' / '));
exception when others then perform tj_record('RW02 the review''s page and its marks', false, sqlerrm);
end $$;
do $$ declare e text; begin
  e := tj_fails(format('select fn_public_submit_review(%L, %L)', tj_note('tokF'), '{"overall":9,"staff":9,"cleanliness":9,"comfort":9,"facilities":9,"value":9,"location":9}'), 'VALIDATION: review_submitted%');
  perform fn_public_submit_review(tj_note('tokB'), '{"overall":9,"staff":9,"cleanliness":9,"comfort":9,"facilities":9,"value":9,"location":10}');
  perform tj_record('RW03 a review is answered once', e = 'ok', e);
exception when others then perform tj_record('RW03 a review is answered once', false, sqlerrm);
end $$;
reset role;
select tj_record('RW04 an overall mark under 9 tells the owner at once (in the system and on WhatsApp), with the room and the comment; a mark of 9 tells no one',
  (tj_alert('review_low', 'review:' || (select id from guest_reviews where reservation_id = tj_id('resF')))).notified_at is not null
  and (tj_alert('review_low', 'review:' || (select id from guest_reviews where reservation_id = tj_id('resF')))).title like 'تقييم 7 من 10%'
  and exists (select 1 from jsonb_array_elements((tj_alert('review_low', 'review:' || (select id from guest_reviews where reservation_id = tj_id('resF')))).notified_to) x
              where x->>'staff_id' = '10000000-0000-0000-0000-000000000001')
  and (tj_alert('review_low', 'review:' || (select id from guest_reviews where reservation_id = tj_id('resB')))).id is null);
select tj_login('a0000000-0000-0000-0000-000000000003', 'hk@test.local');
set role authenticated;
select tj_record('RW05a housekeeping does not read or answer the reviews',
  tj_fails(format('select fn_staff_reviews(%L)', tj_id('b')), '%FORBIDDEN%') = 'ok'
  and tj_fails(format('select fn_staff_review_reply(%L, %L, 1)', (select id from guest_reviews where reservation_id = tj_id('resF')), 'شكرًا'), '%FORBIDDEN%') = 'ok');
reset role;
select tj_login('a0000000-0000-0000-0000-0000000000e1', 'journey@test.local');
set role authenticated;
do $$ declare r jsonb; g uuid; v int; e1 text; e2 text; begin
  r := fn_staff_reviews(tj_id('b'), 30);
  select (x->>'id')::uuid, (x->>'version')::int into g, v from jsonb_array_elements(r->'reviews') x where x->>'reservation_id' = tj_id('resF')::text;
  e1 := tj_fails(format('select fn_staff_review_reply(%L, %L, %s)', g, '', v), 'VALIDATION: review_reply%');
  perform fn_staff_review_reply(g, 'نعتذر عن ذلك، وأصلحنا التهوية.', v);
  e2 := tj_fails(format('select fn_staff_review_reply(%L, %L, %s)', g, 'مرة أخرى', v + 1), 'VALIDATION: review_replied%');
  perform tj_record('RW05 the reception reads the reviews with their averages and those under the mark, and answers one once: the low mark''s alert closes and the answer reaches the guest',
    (r->'summary'->>'count')::int = 2 and (r->'summary'->>'overall')::numeric = 8.0 and (r->'summary'->>'below')::int = 1 and (r->'summary'->>'location')::numeric = 9.5
    and e1 = 'ok' and e2 = 'ok'
    and (tj_alert('review_low', 'review:' || g)).resolved_at is not null and tj_msg_count(tj_id('resF'), 'review_reply') = 1,
    r->>'summary' || ' / ' || e1 || ' / ' || e2);
exception when others then perform tj_record('RW05 the reception reads the reviews and answers one once', false, sqlerrm);
end $$;
select tj_record('RW06 a review''s page key is never read back from the table, not even its hash',
  tj_fails('select token_hash from guest_reviews limit 1', '%permission denied%') = 'ok');
reset role;

-- ---------------------------------------------------------------- AR01–AR06 the rules
select tj_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
set role authenticated;
select tj_record('AR01 the alert rules are the owner''s: the manager reads them and cannot change one',
  jsonb_array_length(fn_admin_alert_rules()) = 8
  and tj_fails(format('select fn_admin_alert_rule_save(%L, %L)', 'product_order', '{"version":1,"enabled":false}'), '%FORBIDDEN%') = 'ok');
reset role;
select tj_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare e text[]; v int; begin
  v := (select version from alert_rules where organization_id = '00000000-0000-0000-0000-000000000001' and event = 'product_order');
  e := array[
    tj_fails(format('select fn_admin_alert_rule_save(%L, %L)', 'product_order', jsonb_build_object('version', v, 'recipients', '["guest"]'::jsonb)), 'VALIDATION: alert_recipients%'),
    tj_fails(format('select fn_admin_alert_rule_save(%L, %L)', 'product_order', jsonb_build_object('version', v, 'recipients', '[]'::jsonb)), 'VALIDATION: alert_recipients%'),
    tj_fails(format('select fn_admin_alert_rule_save(%L, %L)', 'product_order', jsonb_build_object('version', v, 'channel', 'sms')), 'VALIDATION: alert_channel%'),
    tj_fails(format('select fn_admin_alert_rule_save(%L, %L)', 'product_order', jsonb_build_object('version', v, 'delay_minutes', 2000)), 'VALIDATION: alert_delay%'),
    tj_fails(format('select fn_admin_alert_rule_save(%L, %L)', 'product_order', jsonb_build_object('version', v, 'escalate_after_minutes', 0)), 'VALIDATION: alert_escalation%'),
    tj_fails(format('select fn_admin_alert_rule_save(%L, %L)', 'other_event', jsonb_build_object('version', 1, 'enabled', false)), 'NOT_FOUND%')];
  -- the product order: after 10 minutes, to the responsible and the supervisors, climbing to the owner after 20
  perform fn_admin_alert_rule_save('product_order', jsonb_build_object('version', v, 'recipients', '["responsible","supervisor"]'::jsonb, 'channel', 'whatsapp',
                                                                       'delay_minutes', 10, 'escalate_after_minutes', 20, 'escalate_to', 'owner'));
  perform tj_record('AR02 the owner sets a rule — who (the responsible, the fallback, the owner, the managers, the supervisors), by which channel (the system, WhatsApp or both: no SMS), after how long, and to whom it climbs; anything else is refused; the change is logged',
    e = array_fill('ok'::text, array[6])
    and (select recipients = '{responsible,supervisor}' and channel = 'whatsapp' and delay_minutes = 10 and escalate_after_minutes = 20 and escalate_to = 'owner'
           from alert_rules where organization_id = '00000000-0000-0000-0000-000000000001' and event = 'product_order')
    and (select count(*) from tj_rule_audits()) = 1,
    array_to_string(e, ' / '));
exception when others then perform tj_record('AR02 the owner sets a rule', false, sqlerrm);
end $$;
reset role;
-- a product order in a stay of the branch: its alert waits 10 minutes, then goes to the people of the rule
select tj_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; c uuid; p uuid; o jsonb; begin
  perform tj_stay('resG', '0552100007', 'room7', -1, 2);
  r := fn_admin_upsert_product_category('{"name":"منتجات الرحلة"}'); c := (r->>'id')::uuid;
  r := fn_admin_upsert_product(jsonb_build_object('category_id', c, 'name', 'ماء الرحلة', 'price_halalas', 200)); p := (r->>'id')::uuid;
  perform fn_admin_set_product_branch(p, tj_id('b'), true);
  o := fn_staff_create_product_order(tj_id('resG'), jsonb_build_array(jsonb_build_object('product_id', p, 'quantity', 1)));
  insert into ids values ('orderG', (o->>'id')::uuid);
  insert into notes values ('orderGver', o->>'version');
exception when others then perform tj_record('AR03 a product order is made', false, sqlerrm);
end $$;
reset role;
do $$ declare a0 alert_events%rowtype; a1 alert_events%rowtype; begin
  a0 := tj_alert('product_order', 'order:' || tj_id('orderG'));
  perform tj_tick(tj_id('b'), now() + interval '11 minutes');
  a1 := tj_alert('product_order', 'order:' || tj_id('orderG'));
  perform tj_record('AR03 a rule with a delay: the product order''s alert waits its 10 minutes, then goes on WhatsApp only to the responsible and to every supervisor of the branch — and one without a phone is recorded as such',
    a0.id is not null and a0.notified_at is null and a1.notified_at is not null
    and (select count(*) from jsonb_array_elements(a1.notified_to)) = 2
    and exists (select 1 from jsonb_array_elements(a1.notified_to) x where x->>'staff_id' = '10000000-0000-0000-0000-0000000000e1' and x->>'whatsapp' = 'queued' and not (x->>'app')::boolean)
    and exists (select 1 from jsonb_array_elements(a1.notified_to) x where x->>'staff_id' = '10000000-0000-0000-0000-0000000000e2' and x->>'whatsapp' = 'no_phone'),
    coalesce(a1.notified_to::text, 'not told'));
exception when others then perform tj_record('AR03 a rule with a delay', false, sqlerrm);
end $$;
select tj_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ begin
  perform fn_staff_pay_product_order(jsonb_build_object('order_id', tj_id('orderG'), 'method', 'cash', 'idempotency_key', 'tj-order-g', 'expected_version', tj_note('orderGver')::int));
  perform tj_record('AR04 paying the order closes its alert (it no longer climbs)', (tj_alert('product_order', 'order:' || tj_id('orderG'))).resolved_at is not null);
exception when others then perform tj_record('AR04 paying the order closes its alert', false, sqlerrm);
end $$;
do $$ declare v int; r jsonb; o jsonb; begin
  v := (select version from alert_rules where organization_id = '00000000-0000-0000-0000-000000000001' and event = 'product_order');
  perform fn_admin_alert_rule_save('product_order', jsonb_build_object('version', v, 'enabled', false));
  o := fn_staff_create_product_order(tj_id('resG'), jsonb_build_array(jsonb_build_object('product_id', (select id from products where name = 'ماء الرحلة'), 'quantity', 2)));
  perform tj_record('AR05 a rule switched off: its event tells no one', (tj_alert('product_order', 'order:' || (o->>'id'))).id is null);
exception when others then perform tj_record('AR05 a rule switched off: its event tells no one', false, sqlerrm);
end $$;
reset role;
-- the branch's responsible and fallback taken away: the supervisors of the branch are told, and it climbs to the owners
update branch_journey_settings set responsible_staff_id = null, fallback_staff_id = null where branch_id = tj_id('b');
select tj_record('AR06 with no responsible chosen the branch''s supervisors are told, and with no fallback it climbs to the owners',
  (select array_agg(staff_id order by staff_id) from fn_alert_people(tj_id('b'), '{responsible}')) = array['10000000-0000-0000-0000-0000000000e1', '10000000-0000-0000-0000-0000000000e2']::uuid[]
  and (select array_agg(staff_id) from fn_alert_people(tj_id('b'), '{fallback}')) = array['10000000-0000-0000-0000-000000000001']::uuid[]
  and not exists (select 1 from fn_alert_people(tj_id('b'), '{manager}') where staff_id <> '10000000-0000-0000-0000-000000000008'));
update branch_journey_settings set responsible_staff_id = '10000000-0000-0000-0000-0000000000e1', fallback_staff_id = '10000000-0000-0000-0000-000000000008' where branch_id = tj_id('b');

-- ---------------------------------------------------------------- AR08 the staff close an alert
select tj_login('a0000000-0000-0000-0000-000000000003', 'hk@test.local');
set role authenticated;
select tj_record('AR08a housekeeping does not close an alert',
  tj_fails(format('select fn_staff_alert_resolve(%L, %L)', (tj_alert('message_failed', 'journey:' || tj_id('resF') || ':checkout_options:' || tj_today(tj_id('b')))).id, 'x'), '%FORBIDDEN%') = 'ok');
reset role;
select tj_login('a0000000-0000-0000-0000-0000000000e1', 'journey@test.local');
set role authenticated;
do $$ declare id uuid := (tj_alert('message_failed', 'journey:' || tj_id('resF') || ':checkout_options:' || tj_today(tj_id('b')))).id; r1 jsonb; r2 jsonb; t jsonb; begin
  r1 := fn_staff_alert_resolve(id, 'اتصلت بالنزيل');
  r2 := fn_staff_alert_resolve(id, 'مرة أخرى');
  t := fn_staff_journey_tick(tj_id('b'));
  perform tj_record('AR08 the responsible closes an alert they dealt with (logged with the note); closing it again changes nothing; the screen''s look at the clock says how many alerts are open',
    not (r1->>'already')::boolean and (r2->>'already')::boolean and (tj_alert('message_failed', 'journey:' || tj_id('resF') || ':checkout_options:' || tj_today(tj_id('b')))).resolved_how = 'staff'
    and tj_audit_reason('alert.resolved', id) = 'اتصلت بالنزيل' and t ? 'open_alerts',
    r1::text || ' / ' || t::text);
exception when others then perform tj_record('AR08 the responsible closes an alert', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- JM05 the journey switched off; no channel
select tj_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare v int; begin
  perform tj_stay('resH', '0552100008', 'room8');
  v := (fn_admin_journey_settings(tj_id('b'))->>'version')::int;
  perform fn_admin_journey_settings_save(tj_id('b'), jsonb_build_object('version', v, 'journey_enabled', false));
exception when others then perform tj_record('JM05 the journey is switched off', false, sqlerrm);
end $$;
reset role;
do $$ begin
  perform tj_tick(tj_id('b'), tj_at(tj_id('b'), '10:30'));
  perform tj_record('JM05 the journey switched off in the settings: no message goes out (recorded as such) and no one is alarmed about it',
    (tj_msg(tj_id('resH'), 'checkout_options')).reason = 'journey_off'
    and (tj_alert('message_failed', 'journey:' || tj_id('resH') || ':checkout_options:')).id is null,
    coalesce((tj_msg(tj_id('resH'), 'checkout_options'))::text, 'none'));
exception when others then perform tj_record('JM05 the journey switched off in the settings', false, sqlerrm);
end $$;
update branch_journey_settings set journey_enabled = true where branch_id = tj_id('b');
update branch_whatsapp_channels set enabled = false where branch_id = tj_id('b');
select tj_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ begin perform tj_stay('resI', '0552100009', 'room9');
exception when others then perform tj_record('JM06 a stay is made', false, sqlerrm); end $$;
reset role;
do $$ begin
  perform tj_tick(tj_id('b'), tj_at(tj_id('b'), '10:30'));
  perform fn_journey_send(tj_id('resI'), 'review_reply', 'jm06', 'رسالة ثانية');
  perform fn_journey_send(tj_id('resJ'), 'review_reply', 'jm06', 'رسالة ثالثة');
  perform tj_record('JM06 the branch''s WhatsApp is not linked to the reception computer: each message is recorded as not sent, and the responsible is told once that day for the branch — not once a message',
    (tj_msg(tj_id('resI'), 'checkout_options')).reason = 'channel_unavailable' and (tj_msg(tj_id('resI'), 'review_reply')).reason = 'channel_unavailable'
    and (tj_msg(tj_id('resJ'), 'review_reply')).reason = 'channel_unavailable'
    and (tj_alert('message_failed', 'channel:' || tj_id('b') || ':' || tj_today(tj_id('b')))).notified_at is not null
    and (select count(*) from alert_events where branch_id = tj_id('b') and event = 'message_failed' and (ref_key like 'journey:' || tj_id('resI') || '%' or ref_key like 'journey:' || tj_id('resJ') || '%' or ref_key like 'channel:%')) = 1,
    coalesce((tj_msg(tj_id('resI'), 'checkout_options'))::text, 'none'));
exception when others then perform tj_record('JM06 the branch''s WhatsApp is not linked', false, sqlerrm);
end $$;
update branch_whatsapp_channels set enabled = true where branch_id = tj_id('b');

-- ---------------------------------------------------------------- CX13, DR08–DR09, JM11 the hours after the free hour, at the departure
select tj_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ begin
  perform tj_stay('resM', '0552100013', 'room13');           -- leaving today: says they left at 15:20, no hours bought
  perform tj_stay('resN', '0552100014', 'room14');           -- leaving today: two hours bought, leaves at 15:30
  perform tj_stay('resO', '0552100015', 'room15');           -- leaving today: a night more by the reception
exception when others then perform tj_record('CX13 the stays are made', false, sqlerrm);
end $$;
reset role;
do $$ declare b uuid := tj_id('b'); e1 text; o1 jsonb; o2 jsonb; begin
  o1 := fn_checkout_offer(tj_id('resM'), tj_at(b, '12:50'));
  o2 := fn_checkout_offer(tj_id('resM'), tj_at(b, '13:20'));
  e1 := tj_fails(format('select fn_checkout_choose(%L, %L, null, %L, %L::timestamptz)', tj_id('resM'), 'on_time', 'page', tj_at(b, '13:20')), 'VALIDATION: free_hour_over%');
  perform tj_record('CX13 leaving on time is offered until the free hour ends (12:50 yes, 13:20 no) and refused after it: the hours begun are late hours, and leaving now would add one',
    (o1->>'on_time_open')::boolean and not (o2->>'on_time_open')::boolean and e1 = 'ok' and (o2->'hours'->>'late_now')::int = 1 and (o1->'hours'->>'late_now')::int = 0,
    e1 || ' / ' || (o2->'hours')::text);
exception when others then perform tj_record('CX13 leaving on time only until the free hour ends', false, sqlerrm);
end $$;
do $$ declare b uuid := tj_id('b'); r jsonb; a alert_events%rowtype; total0 bigint := (tj_res(tj_id('resM'))).total_halalas; begin
  perform fn_departure_instructions(tj_id('resM'));
  r := fn_departure_confirm(tj_id('resM'), 'page', tj_at(b, '15:20'));
  a := tj_alert('guest_departed', 'departed:' || tj_id('resM'));
  perform tj_record('DR08 a guest who says they left at 3:20 PM, with no hours bought, has the hours begun after 1 PM charged as they leave — three (until 4 PM), 15.00 — told to them, and the reception is told without the amount',
    (r->>'late_hours')::int = 3 and (r->>'late_halalas')::bigint = 1500 and (tj_res(tj_id('resM'))).late_checkout_until = '16:00'
    and (tj_res(tj_id('resM'))).total_halalas = total0 + 1500
    and exists (select 1 from reservation_charges where reservation_id = tj_id('resM') and description = 'خروج متأخر 3 ساعات حتى 16:00 (عند المغادرة)' and total_halalas = 1500)
    and a.body like '%أُضيف إلى الحجز خروج متأخر 3 ساعات%' and a.body not like '%ر.س%',
    r::text || ' / ' || coalesce(a.body, 'no alert'));
exception when others then perform tj_record('DR08 the hours begun after the free hour are charged at the departure', false, sqlerrm);
end $$;
do $$ declare tok text := tj_token(tj_id('resN')); begin
  insert into notes values ('tokN', tok), ('totalN0', (tj_res(tj_id('resN'))).total_halalas::text);
  set local role anon;
  perform fn_guest_checkout_choose(tok, 'hours', 2);
exception when others then perform tj_record('DR09 two hours are taken', false, sqlerrm);
end $$;
select tj_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ begin
  perform fn_create_voucher(jsonb_build_object('reservation_id', tj_id('resN'), 'kind', 'receipt', 'received_confirmed', true, 'amount_halalas', (tj_fin(tj_id('resN'))->>'balance_due')::bigint, 'method', 'cash', 'idempotency_key', 'tj-hours-n'));
exception when others then perform tj_record('DR09 the two hours are paid', false, sqlerrm);
end $$;
reset role;
do $$ declare b uuid := tj_id('b'); r jsonb; begin
  perform tj_tick(b, tj_at(b, '10:55'));
  perform fn_departure_instructions(tj_id('resN'));
  r := fn_departure_confirm(tj_id('resN'), 'page', tj_at(b, '15:30'));
  perform tj_record('DR09 a guest who bought two hours (until 3 PM) and leaves at 3:30 PM has only the hour begun after them charged (one, until 4 PM, 5.00); the hours paid are not charged again',
    (tj_request(tj_id('resN'))).status = 'paid' and (r->>'late_hours')::int = 1 and (r->>'late_halalas')::bigint = 500
    and (tj_res(tj_id('resN'))).late_checkout_until = '16:00' and (tj_res(tj_id('resN'))).total_halalas = tj_note('totalN0')::bigint + 1000 + 500,
    r::text);
exception when others then perform tj_record('DR09 only the hours begun after those bought are charged', false, sqlerrm);
end $$;
do $$ declare r reservations%rowtype; begin
  perform fn_departure_instructions(tj_id('resO'));
  update reservations set late_checkout_until = '15:00', checkout_choice = 'on_time', checkout_choice_at = now() where id = tj_id('resO');
  perform fn_amend_stay_internal(tj_id('resO'), (tj_res(tj_id('resO'))).check_out + 1, 'keep_rate', 'ليلة إضافية من الاستقبال', false);
  r := tj_res(tj_id('resO'));
  perform tj_record('JM11 a night more makes a new day of departure: its choice, its late hours and its instructions are asked, sold and shown again that day',
    r.check_out = tj_today(tj_id('b')) + 1 and r.checkout_choice is null and r.late_checkout_until is null and r.departure_instructions_at is null,
    r.check_out::text || ' ' || coalesce(r.late_checkout_until::text, '-') || ' ' || coalesce(r.departure_instructions_at::text, '-'));
exception when others then perform tj_record('JM11 a new day of departure starts clean', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- AR09 «in the system» is personal
do $$ begin
  perform fn_alert_raise(tj_id('b'), 'guest_handoff', 'ar09', 'نزيل يطلب موظفًا — فحص', 'فحص التنبيه الشخصي', '/staff/inbox', null);
end $$;
select tj_record('AR09 «in the system» is personal: a WhatsApp-only alert is not in the system of the one WhatsApp reached, it is in the system of the one it could not reach (no phone), and of no one else; an alert named to nobody is everyone''s; no alert writes a notice to a whole level',
  not fn_alert_is_mine((tj_alert('product_order', 'order:' || tj_id('orderG'))).notified_to, null, '10000000-0000-0000-0000-0000000000e1')
  and fn_alert_is_mine((tj_alert('product_order', 'order:' || tj_id('orderG'))).notified_to, null, '10000000-0000-0000-0000-0000000000e2')
  and not fn_alert_is_mine((tj_alert('product_order', 'order:' || tj_id('orderG'))).notified_to, null, '10000000-0000-0000-0000-000000000001')
  and fn_alert_is_mine('[]'::jsonb, null, '10000000-0000-0000-0000-000000000001')
  and not exists (select 1 from notifications n where n.branch_id = tj_id('b') and (n.title like 'تصعيد:%' or n.title in (select title from alert_events where branch_id = tj_id('b')))));
select tj_login('a0000000-0000-0000-0000-0000000000e1', 'journey@test.local');
set role authenticated;
do $$ declare t jsonb; j jsonb; mine int; ar09 boolean; begin
  t := fn_staff_journey_tick(tj_id('b'));
  j := fn_staff_journey(tj_id('b'));
  select count(*) into mine from jsonb_array_elements(j->'alerts') x where (x->>'mine')::boolean;
  select (x->>'mine')::boolean into ar09 from jsonb_array_elements(j->'alerts') x where x->>'title' = 'نزيل يطلب موظفًا — فحص';
  perform tj_record('AR09b the menu''s badge of the responsible counts the open alerts that are theirs, and «رحلة الضيف» marks them',
    (t->>'open_alerts')::int = mine and mine >= 1 and ar09, t::text || ' / ' || mine);
exception when others then perform tj_record('AR09b the badge counts the reader''s own alerts', false, sqlerrm);
end $$;
reset role;
select tj_login('a0000000-0000-0000-0000-0000000000e2', 'journey2@test.local');
set role authenticated;
do $$ declare j jsonb; ar09 boolean; begin
  j := fn_staff_journey(tj_id('b'));
  select (x->>'mine')::boolean into ar09 from jsonb_array_elements(j->'alerts') x where x->>'title' = 'نزيل يطلب موظفًا — فحص';
  perform tj_record('AR09c another supervisor of the branch sees the alert on «رحلة الضيف», not as theirs', ar09 is false, coalesce(ar09::text, 'not listed'));
exception when others then perform tj_record('AR09c another supervisor sees it, not as theirs', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- AR10 money only to those who see it; alerts only to those «رحلة الضيف» is for
create temp table tj_perm_before as select * from role_permissions where organization_id = '00000000-0000-0000-0000-000000000001' and role = 'supervisor';
insert into role_permissions(organization_id, capability, role, allowed)
select '00000000-0000-0000-0000-000000000001', c, 'supervisor', false
  from unnest(array['voucher.receipt', 'voucher.refund', 'deposit.refund', 'deposit.apply', 'voucher.correct', 'voucher.cancel', 'pos.settle', 'platform.payouts',
                    'invoice.issue', 'invoice.edit', 'reports.finance']) c
on conflict (organization_id, capability, role) do update set allowed = false;
select tj_login('a0000000-0000-0000-0000-0000000000e1', 'journey@test.local');
set role authenticated;
do $$ declare j jsonb; begin
  j := fn_staff_journey(tj_id('b'));
  perform tj_record('AR10 a supervisor the owner took money from reads «رحلة الضيف» without amounts — the requests, the stays waiting for their check, the deposits to return — and the alerts carry none',
    not (j->>'sees_money')::boolean and jsonb_array_length(j->'requests') > 0 and jsonb_array_length(j->'deposits') > 0
    and not exists (select 1 from jsonb_array_elements(j->'requests') x where x->>'amount_halalas' is not null)
    and not exists (select 1 from jsonb_array_elements(j->'deposits') x where x->>'deposit_halalas' is not null)
    and not exists (select 1 from jsonb_array_elements(j->'awaiting_check') x where x->>'deposit_halalas' is not null or x->>'balance_due' is not null)
    and not exists (select 1 from alert_events where branch_id = tj_id('b') and event in ('guest_departed', 'deposit_overdue', 'extension_requested', 'extension_unpaid')
                                                 and (title like '%ر.س%' or coalesce(body, '') like '%ر.س%')),
    left(j::text, 300));
exception when others then perform tj_record('AR10 a supervisor without money reads no amounts', false, sqlerrm);
end $$;
reset role;
delete from role_permissions where organization_id = '00000000-0000-0000-0000-000000000001' and role = 'supervisor';
insert into role_permissions select * from tj_perm_before;
select tj_login('a0000000-0000-0000-0000-000000000003', 'hk@test.local');
set role authenticated;
select tj_record('AR10b housekeeping reads no alert of the branch from the table', (select count(*) from alert_events) = 0);
reset role;
select tj_login('a0000000-0000-0000-0000-0000000000e1', 'journey@test.local');
set role authenticated;
select tj_record('AR10c the supervisor reads the alerts of their branch', (select count(*) from alert_events where branch_id = tj_id('b')) > 0
  and (fn_staff_journey(tj_id('b'))->>'sees_money')::boolean);
reset role;

-- ---------------------------------------------------------------- JM08 a night more makes a new day of departure
do $$ declare t jsonb; m journey_messages%rowtype; begin
  t := tj_tick(tj_id('b'), tj_at(tj_id('b'), '10:30') + interval '1 day');
  m := tj_msg(tj_id('resA'), 'checkout_options');
  perform tj_record('JM08 the guest who took a night more is offered the options again at 10 on their new day of departure — once for that day',
    m.ref_key = (tj_today(tj_id('b')) + 1)::text and m.status = 'queued' and tj_msg_count(tj_id('resA'), 'checkout_options') = 2,
    coalesce(m::text, 'none') || ' / ' || t::text);
exception when others then perform tj_record('JM08 a night more makes a new day of departure', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- JM09 the free hour's window from the settings
select tj_record('JM09 the free hour''s window is told from the branch''s own times, as the guest reads a clock',
  fn_ar_window('12:00', '13:00') = 'بين 12 و1 ظهرًا' and fn_ar_window('11:00', '12:30') = 'بين 11 صباحًا و12:30 ظهرًا'
  and fn_ar_range('12:00', '13:00') = '12–1' and fn_ar_hm('00:00') = '12' and fn_ar_period('24:00') = 'منتصف الليل'
  and fn_ar_window('14:00', '16:00') = 'بين 2 ظهرًا و4 عصرًا'
  and fn_extension_confirmed_text('night', null, tj_id('b')) = 'تم تثبيت ليلتك الإضافية. موعد خروجك الجديد غدًا بين 12 و1 ظهرًا.');

-- ---------------------------------------------------------------- JM10 a message that fails never stops what it rides on
select tj_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ begin perform tj_stay('resL', '0552100012', 'room12');
exception when others then perform tj_record('JM10 a stay is made', false, sqlerrm); end $$;
reset role;
alter table conversation_messages add constraint tj_block_checkout_message check (content not like 'تم تأكيد خروجك%') not valid;
select tj_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; begin
  r := fn_staff_check_out(jsonb_build_object('reservation_id', tj_id('resL')));
  insert into notes values ('checkout_l', r::text);
exception when others then insert into notes values ('checkout_l', 'ERROR ' || sqlerrm);
end $$;
reset role;
alter table conversation_messages drop constraint tj_block_checkout_message;
select tj_record('JM10 a message that fails never stops the check-out it rides on: the stay is checked out, nothing of the message is left half-written, and the responsible is told to inform the guest',
  tj_note('checkout_l') not like 'ERROR%' and (tj_res(tj_id('resL'))).status in ('checked_out', 'closed') and tj_msg_count(tj_id('resL'), 'checkout_confirmed') = 0
  and (tj_alert('message_failed', 'error:' || tj_id('resL') || ':checkout_confirmed:')).notified_at is not null,
  tj_note('checkout_l'));

-- ---------------------------------------------------------------- JM07 nothing past the functions
select tj_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
select tj_record('JM07 from the screens'' side the journey is written only through its functions: no settings, rule, request, review or alert is written in its table, and the clock and the sending are not called',
  tj_fails(format('update branch_journey_settings set hold_minutes = 5 where branch_id = %L', tj_id('b')), '%permission denied%') = 'ok'
  and tj_fails('update alert_rules set enabled = false', '%permission denied%') = 'ok'
  and tj_fails('update stay_extension_requests set status = ''paid''', '%permission denied%') = 'ok'
  and tj_fails('update guest_reviews set overall = 10', '%permission denied%') = 'ok'
  and tj_fails('update alert_events set resolved_at = now()', '%permission denied%') = 'ok'
  and tj_fails(format('select fn_journey_tick(%L, true)', tj_id('b')), '%permission denied%') = 'ok'
  and tj_fails(format('select fn_journey_send(%L, %L, %L, %L)', tj_id('resA'), 'review_invite', '', 'x'), '%permission denied%') = 'ok'
  and tj_fails(format('select fn_checkout_choose(%L, %L, null, %L)', tj_id('resA'), 'on_time', 'page'), '%permission denied%') = 'ok'
  and tj_fails(format('select fn_departure_instructions(%L)', tj_id('resA')), '%permission denied%') = 'ok'
  and tj_fails(format('select fn_mark_imported_guests(%L)', '00000000-0000-0000-0000-000000000001'), '%permission denied%') = 'ok');
reset role;

-- (the branch's clock back to Riyadh's for the files that run after this one)
update branches set timezone = 'Asia/Riyadh' where id = tj_id('b');

-- ---------------------------------------------------------------- results
\set ON_ERROR_STOP on
select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail, ''), 400) as detail from test_results order by name;
do $$
declare n int; f int;
begin
  select count(*), count(*) filter (where not ok) into n, f from test_results;
  if f > 0 then raise exception 'JOURNEY TESTS FAILED: % of %', f, n; end if;
  if n < 61 then raise exception 'JOURNEY TESTS INCOMPLETE: % of 61 checks ran', n; end if;
end $$;
