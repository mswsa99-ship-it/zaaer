-- =====================================================================
-- The review of 31 October, Phase 1 as the owner decided it (QS*, QF*, QM*; migrations 0052–0054).
-- Two branches of their own: «فرع التدقيق» (supervisor a…02, housekeeping a…03, finance a…04 are members) and
-- «فرع آخر» (no members). Each check builds what it needs through the normal functions.
-- =====================================================================
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create temp table ids(k text primary key, v uuid);
grant all on ids to public;
create or replace function t_login(p_uid uuid, p_email text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email)::text, false);
end $$;
create or replace function t_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;
create or replace function t_id(p_k text) returns uuid language sql security definer as $$ select v from ids where k = p_k $$;

-- ---------------------------------------------------------------- fixtures (the owner, through the normal functions)
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; b uuid; b2 uuid; cat uuid; cat2 uuid; begin
  r := fn_admin_upsert_branch('{"name_ar":"فرع التدقيق","name_en":"Audit branch","tax_rate_bp":0}'); b := (r->>'id')::uuid;
  r := fn_admin_upsert_branch('{"name_ar":"فرع آخر للتدقيق","name_en":"Other audit branch","tax_rate_bp":0}'); b2 := (r->>'id')::uuid;
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', b, 'name_ar', 'استوديو التدقيق', 'base_price_halalas', 20000)); cat := (r->>'id')::uuid;
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', b2, 'name_ar', 'استوديو الفرع الآخر', 'base_price_halalas', 20000)); cat2 := (r->>'id')::uuid;
  insert into ids values ('b', b), ('b2', b2), ('cat', cat), ('cat2', cat2);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', 'Q-1')); insert into ids values ('q1', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', 'Q-2')); insert into ids values ('q2', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', b2, 'category_id', cat2, 'room_number', 'Z-1')); insert into ids values ('z1', (r->>'id')::uuid);
  -- a resident with a balance in Q-1, and a stay in the other branch
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_id', t_id('q1'), 'check_in', (current_date - 1)::text,
         'check_out', (current_date + 2)::text, 'guest_phone', '0551000031', 'guest_name', 'ضيف التدقيق', 'source_id', '00000000-0000-0000-0000-000000000021'));
  insert into ids values ('res', (r->>'id')::uuid);
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b2, 'category_id', cat2, 'room_id', t_id('z1'), 'check_in', current_date::text,
         'check_out', (current_date + 1)::text, 'guest_phone', '0551000032', 'guest_name', 'ضيف الفرع الآخر', 'source_id', '00000000-0000-0000-0000-000000000021'));
  insert into ids values ('res2', (r->>'id')::uuid);
end $$;
reset role;
insert into branch_memberships(staff_id, branch_id)
select s, t_id('b') from unnest(array['10000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000004']::uuid[]) s
on conflict do nothing;
update reservations set status = 'checked_in', actual_check_in = now() where id = t_id('res');
update rooms set status = 'occupied' where id = t_id('q1');
insert into registration_sessions(reservation_id) values (t_id('res')), (t_id('res2'));
insert into conversations(channel, status, branch_id, guest_token) values ('screen', 'active', t_id('b'), 'TOKEN-OF-A-GUEST-1');

-- ---------------------------------------------------------------- QS01–QS02 the guest tokens (SEC-01)
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
set role authenticated;
do $$ declare n_own int; n_other int; tok_refused boolean := false; begin
  select count(*) into n_own from registration_sessions where reservation_id = t_id('res');
  select count(*) into n_other from registration_sessions where reservation_id = t_id('res2');
  begin perform token from registration_sessions limit 1; exception when insufficient_privilege then tok_refused := true; end;
  perform t_record('QS01 the supervisor sees the registration sessions of their own branch only, and never the token',
    n_own = 1 and n_other = 0 and tok_refused, n_own || '/' || n_other || ' token refused: ' || tok_refused);
exception when others then perform t_record('QS01 the supervisor sees the registration sessions of their own branch only, and never the token', false, sqlerrm);
end $$;
do $$ declare v boolean; tok_refused boolean := false; begin
  select guest_verified into v from conversations where branch_id = t_id('b') limit 1;
  begin perform guest_token from conversations limit 1; exception when insufficient_privilege then tok_refused := true; end;
  perform t_record('QS02 a conversation reads «متحقق» (guest_verified) but its guest token is refused to staff', v and tok_refused, v || ' ' || tok_refused);
exception when others then perform t_record('QS02 a conversation reads «متحقق» (guest_verified) but its guest token is refused to staff', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- QS04–QS06 money only for a role that sees it (PERM-01/02, SEC-06)
update reservations set total_halalas = 60000, paid_halalas = 20000, balance_due_halalas = 40000 where id = t_id('res');
select t_login('a0000000-0000-0000-0000-000000000003', 'hk@test.local');
set role authenticated;
do $$ declare s jsonb; b jsonb; f jsonb; begin
  s := fn_ops_daily_summary(t_id('b'));
  perform t_record('QS04 housekeeping''s day summary has no money: no finance, no unpaid arrivals, no departures with a balance',
    s is not null and not (s ? 'finance') and not (s->'arrivals' ? 'unpaid') and not (s->'departures' ? 'with_balance') and (s->>'money_hidden')::boolean
    and s->'units' is not null, s::text);
  b := fn_ops_units_board(t_id('b'));
  perform t_record('QS05 housekeeping''s units board shows the resident without the balance due',
    exists (select 1 from jsonb_array_elements(b) e where e->>'room_id' = t_id('q1')::text and e->'current'->>'internal_ref' is not null and e->'current'->'balance_due' = 'null'::jsonb), b::text);
  f := fn_ai_ops_find_reservation(t_id('b'), 'ضيف التدقيق');
  perform t_record('QS06 the old assistant search gives housekeeping no balance, deposit or payment status',
    jsonb_array_length(f) = 1 and f->0->'balance_due' = 'null'::jsonb and f->0->'deposit_balance' = 'null'::jsonb and f->0->'payment_status' = 'null'::jsonb, f::text);
exception when others then perform t_record('QS04 housekeeping''s day summary has no money: no finance, no unpaid arrivals, no departures with a balance', false, sqlerrm);
end $$;
reset role;
select t_login('a0000000-0000-0000-0000-000000000004', 'fin@test.local');
set role authenticated;
do $$ declare s jsonb; b jsonb; begin
  s := fn_ops_daily_summary(t_id('b'));
  b := fn_ops_units_board(t_id('b'));
  perform t_record('QS04b finance (a money role) keeps the money in the summary and the board',
    (s->'finance'->>'outstanding_in_house')::bigint = 40000 and s->'arrivals' ? 'unpaid'
    and exists (select 1 from jsonb_array_elements(b) e where e->>'room_id' = t_id('q1')::text and (e->'current'->>'balance_due')::bigint = 40000), s::text);
exception when others then perform t_record('QS04b finance (a money role) keeps the money in the summary and the board', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- QS07–QS08 the AI guard (SEC-02)
do $$ declare c uuid; g jsonb; g2 jsonb; n int; i int; begin
  insert into conversations(channel, status, branch_id) values ('screen', 'active', t_id('b')) returning id into c;
  for i in 1..3 loop insert into conversation_messages(conversation_id, sender, content, created_at) values (c, 'guest', 'كم السعر؟  ', now() + make_interval(secs => i)); end loop;
  g := fn_ai_conversation_guard(c);
  insert into conversation_messages(conversation_id, sender, content) values (c, 'guest', 'كم السعر؟');
  g2 := fn_ai_conversation_guard(c);
  select count(*) into n from human_handoff_tickets where conversation_id = c;
  perform t_record('QS07 the same message three times stops the AI: handed to the supervisor with one ticket, recorded; asking again opens no second ticket',
    (g->>'stop')::boolean and g->>'kind' = 'repeat' and (g2->>'stop')::boolean and n = 1
    and (select status from conversations where id = c) = 'handed_off'
    and exists (select 1 from ai_guardrail_events where conversation_id = c and rule = 'anomaly:repeat'), g::text || ' ' || n);
exception when others then perform t_record('QS07 the same message three times stops the AI: handed to the supervisor with one ticket, recorded; asking again opens no second ticket', false, sqlerrm);
end $$;
do $$ declare c uuid; c2 uuid; g jsonb; quiet jsonb; i int; begin
  insert into conversations(channel, status, branch_id) values ('screen', 'active', t_id('b')) returning id into c;
  for i in 1..16 loop insert into conversation_messages(conversation_id, sender, content, created_at) values (c, 'guest', 'سؤال رقم ' || i, now() + make_interval(secs => i)); end loop;
  g := fn_ai_conversation_guard(c);
  insert into conversations(channel, status, branch_id) values ('screen', 'active', t_id('b')) returning id into c2;
  insert into conversation_messages(conversation_id, sender, content, meta) values (c2, 'guest', 'متى وقت الدخول؟', null), (c2, 'assistant', 'من الساعة 4', '{"tokens":{"in":900,"out":100}}'::jsonb);
  quiet := fn_ai_conversation_guard(c2);
  update conversation_messages set meta = '{"tokens":{"in":45000,"out":100}}'::jsonb where conversation_id = c2 and sender = 'assistant';
  perform t_record('QS08 sixteen messages in ten minutes, or a conversation past its token number, stops the AI; a normal conversation goes on',
    (g->>'stop')::boolean and g->>'kind' = 'burst' and not (quiet->>'stop')::boolean and (fn_ai_conversation_guard(c2)->>'kind') = 'tokens', g::text || ' ' || quiet::text);
exception when others then perform t_record('QS08 sixteen messages in ten minutes, or a conversation past its token number, stops the AI; a normal conversation goes on', false, sqlerrm);
end $$;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare msg text := ''; ok_saved boolean; begin
  begin perform fn_admin_update_ai_settings('{"guard_repeat_limit": 1}'); exception when others then msg := sqlerrm; end;
  perform fn_admin_update_ai_settings('{"guard_repeat_limit": 4, "guard_conversation_tokens": 60000}');
  reset role;
  select guard_repeat_limit = 4 and guard_conversation_tokens = 60000 into ok_saved from ai_settings where organization_id = '00000000-0000-0000-0000-000000000001';
  perform t_record('QS09 the four guard numbers are the owner''s settings: out of range is refused, in range is saved', msg like 'VALIDATION: ai_guard%' and ok_saved, msg);
  update ai_settings set guard_repeat_limit = 3, guard_conversation_tokens = 40000 where organization_id = '00000000-0000-0000-0000-000000000001';
exception when others then perform t_record('QS09 the four guard numbers are the owner''s settings: out of range is refused, in range is saved', false, sqlerrm);
end $$;
reset role;
-- the guard is the edge function's (service role) only
set role authenticated;
do $$ begin
  begin perform fn_ai_conversation_guard(gen_random_uuid()); perform t_record('QS09b no signed-in staff member or visitor calls the guard', false);
  exception when insufficient_privilege then perform t_record('QS09b no signed-in staff member or visitor calls the guard', true); end;
end $$;
reset role;

-- ---------------------------------------------------------------- QS10–QS11 the reception computer's key (SEC-05)
insert into staff_profiles(id, auth_user_id, organization_id, full_name, email, role)
values ('10000000-0000-0000-0000-0000000000a7', 'a0000000-0000-0000-0000-0000000000a7', '00000000-0000-0000-0000-000000000001', 'موظف يغادر', 'leaver@test.local', 'supervisor')
on conflict do nothing;
insert into branch_memberships(staff_id, branch_id) values ('10000000-0000-0000-0000-0000000000a7', t_id('b')) on conflict do nothing;
insert into branch_whatsapp_channels(branch_id, organization_id, mode, display_phone, bridge_key_hash, bridge_key_last4, bridge_key_created_at)
values (t_id('b'), '00000000-0000-0000-0000-000000000001', 'web_bridge', '966551000000', encode(digest('zb_' || repeat('a', 64), 'sha256'), 'hex'), 'aaaa', now() - interval '3 days')
on conflict (branch_id) do nothing;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare s jsonb; s2 jsonb; n int; begin
  perform fn_admin_set_staff_active('10000000-0000-0000-0000-0000000000a7', false, 'انتهى عمله');
  s := fn_admin_whatsapp_security(t_id('b'));
  reset role;
  select count(*) into n from review_items where branch_id = t_id('b') and kind = 'security:bridge_key_rotation';
  set role authenticated;
  perform fn_admin_whatsapp_save(t_id('b'), '{"regenerate_bridge_key": true}');
  s2 := fn_admin_whatsapp_security(t_id('b'));
  perform t_record('QS10 a staff member leaving the branch marks its reception-computer key «يجب تغييره» with a review item; a new key clears it',
    s->>'rotation_due_at' is not null and s->>'rotation_reason' like 'موظف يغادر%' and n = 1 and s2->>'rotation_due_at' is null, s::text || ' ' || s2::text);
exception when others then perform t_record('QS10 a staff member leaving the branch marks its reception-computer key «يجب تغييره» with a review item; a new key clears it', false, sqlerrm);
end $$;
do $$ declare msg text := ''; s jsonb; n int; i int; begin
  begin perform fn_admin_whatsapp_security(t_id('b'), '{"alert_new_contacts_per_hour": 2}'); exception when others then msg := sqlerrm; end;
  s := fn_admin_whatsapp_security(t_id('b'), '{"alert_new_contacts_per_hour": 5}');
  reset role;
  for i in 1..8 loop insert into conversations(channel, status, branch_id, wa_contact) values ('whatsapp', 'active', t_id('b'), '9665510000' || lpad(i::text, 2, '0')); end loop;
  select count(*) into n from review_items where branch_id = t_id('b') and kind = 'security:whatsapp_burst';
  perform t_record('QS11 more new WhatsApp contacts in an hour than the owner''s number raises one review item (and the number keeps its range)',
    msg like 'VALIDATION: alert_new_contacts_per_hour%' and (s->>'alert_new_contacts_per_hour')::int = 5 and n = 1, msg || ' n=' || n);
exception when others then perform t_record('QS11 more new WhatsApp contacts in an hour than the owner''s number raises one review item (and the number keeps its range)', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- QF01–QF04 the front desk (0053)
-- Q-2 holds a resident who should have left yesterday
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; begin
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', t_id('b'), 'category_id', t_id('cat'), 'room_id', t_id('q2'), 'check_in', (current_date - 1)::text,
         'check_out', (current_date + 1)::text, 'guest_phone', '0551000033', 'guest_name', 'ضيف تجاوز موعده', 'source_id', '00000000-0000-0000-0000-000000000021'));
  insert into ids values ('over', (r->>'id')::uuid);
  r := fn_admin_upsert_service(jsonb_build_object('branch_id', t_id('b'), 'name_ar', 'تنظيف إضافي', 'billing_unit', 'once', 'price_halalas', 5000));
  insert into ids values ('svc', (r->>'id')::uuid);
end $$;
reset role;
update reservations set check_in = current_date - 3, check_out = current_date - 1, status = 'checked_in', actual_check_in = now() - interval '3 days' where id = t_id('over');
update reservation_allocations set from_date = current_date - 3, to_date = current_date - 1 where reservation_id = t_id('over');
update rooms set status = 'occupied' where id = t_id('q2');
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
set role authenticated;
do $$ declare offered boolean; msg text := ''; r jsonb; tomorrow_ok boolean := false; begin
  select exists (select 1 from fn_available_rooms(t_id('b'), current_date, current_date + 1, t_id('cat')) where room_id = t_id('q2')) into offered;
  begin
    r := fn_staff_create_reservation(jsonb_build_object('branch_id', t_id('b'), 'category_id', t_id('cat'), 'room_id', t_id('q2'), 'check_in', current_date::text,
           'check_out', (current_date + 1)::text, 'guest_phone', '0551000034', 'guest_name', 'ضيف الليلة', 'source_id', '00000000-0000-0000-0000-000000000021'));
  exception when others then msg := sqlerrm; end;
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', t_id('b'), 'category_id', t_id('cat'), 'room_id', t_id('q2'), 'check_in', (current_date + 1)::text,
         'check_out', (current_date + 2)::text, 'guest_phone', '0551000035', 'guest_name', 'ضيف الغد', 'source_id', '00000000-0000-0000-0000-000000000021'));
  tomorrow_ok := (r->>'id') is not null;
  perform t_record('QF01 a unit whose resident is past their departure is not offered or sold for tonight (ROOM_OCCUPIED_OVERSTAY); tomorrow stays sellable',
    not offered and (msg like 'ROOM_OCCUPIED_OVERSTAY%' or msg like 'ROOM_NOT_AVAILABLE%') and tomorrow_ok, offered || ' ' || msg);
exception when others then perform t_record('QF01 a unit whose resident is past their departure is not offered or sold for tonight (ROOM_OCCUPIED_OVERSTAY); tomorrow stays sellable', false, sqlerrm);
end $$;
do $$ declare r jsonb; st0 text; st1 text; n int; begin
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', t_id('b'), 'category_id', t_id('cat'), 'check_in', (current_date + 5)::text,
         'check_out', (current_date + 6)::text, 'guest_phone', '0551000036', 'guest_name', 'ضيف منصة', 'confirm', false, 'source_id', '00000000-0000-0000-0000-000000000021'));
  insert into ids values ('pv', (r->>'id')::uuid);
  reset role;
  select status into st0 from reservations where id = t_id('pv');
  update reservations set identity_status = 'verified' where id = t_id('pv');
  select status into st1 from reservations where id = t_id('pv');
  select count(*) into n from audit_events where entity_id = t_id('pv') and action = 'reservation.confirmed';
  perform t_record('QF02 a booking «بانتظار التحقق» is confirmed by itself when its identity is verified, with an audit row',
    st0 = 'pending_verification' and st1 = 'confirmed' and n = 1, st0 || '→' || st1 || ' audits ' || n);
exception when others then perform t_record('QF02 a booking «بانتظار التحقق» is confirmed by itself when its identity is verified, with an audit row', false, sqlerrm);
end $$;
reset role;
-- an early departure: Q-1's resident (yesterday → in two days) leaves today
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
set role authenticated;
do $$ declare r1 jsonb; r2 jsonb; msg text := ''; co date; adj bigint; begin
  r1 := fn_staff_check_out(jsonb_build_object('reservation_id', t_id('res')));
  begin perform fn_staff_check_out(jsonb_build_object('reservation_id', t_id('res'), 'early_departure', 'keep')); exception when others then msg := sqlerrm; end;
  r2 := fn_staff_check_out(jsonb_build_object('reservation_id', t_id('res'), 'early_departure', 'shorten', 'reason', 'ظرف عائلي'));
  reset role;
  select check_out into co from reservations where id = t_id('res');
  select coalesce(sum(total_halalas), 0) into adj from reservation_charges where reservation_id = t_id('res') and kind = 'adjustment' and description like 'مغادرة مبكرة%';
  perform t_record('QF03 leaving before the departure date asks first (nights and amount), needs a reason, and «تقصير» ends the stay today with the nights left as an adjustment',
    not (r1->>'ok')::boolean and (r1->>'early_departure')::boolean and (r1->>'unused_nights')::int = 2 and msg like 'VALIDATION: reason%'
    and co = current_date and adj < 0, r1::text || ' / ' || msg || ' / ' || co || ' ' || adj || ' / ' || r2::text);
exception when others then perform t_record('QF03 leaving before the departure date asks first (nights and amount), needs a reason, and «تقصير» ends the stay today with the nights left as an adjustment', false, sqlerrm);
end $$;
reset role;
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
set role authenticated;
do $$ declare msg text := ''; r jsonb; n int; begin
  perform fn_staff_add_service(t_id('pv'), t_id('svc'), 1, null);
  begin perform fn_staff_add_service(t_id('pv'), t_id('svc'), 1, null); exception when others then msg := sqlerrm; end;
  r := fn_staff_add_service(t_id('pv'), t_id('svc'), 1, 'طلب النزيل تنظيفًا ثانيًا');
  reset role;
  select count(*) into n from reservation_charges where reservation_id = t_id('pv') and kind = 'addon' and service_definition_id = t_id('svc');
  perform t_record('QF04 the same once-only service a second time is refused without a reason, and added with one',
    msg like 'SERVICE_ALREADY_ADDED%' and (r->>'ok')::boolean and n = 2, msg || ' n=' || n);
exception when others then perform t_record('QF04 the same once-only service a second time is refused without a reason, and added with one', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- QM01–QM07 money (0054), as the owner
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; begin
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', t_id('b'), 'category_id', t_id('cat'), 'check_in', (current_date + 10)::text,
         'check_out', (current_date + 13)::text, 'guest_phone', '0551000041', 'guest_name', 'ضيف المال', 'source_id', '00000000-0000-0000-0000-000000000021'));
  insert into ids values ('m1', (r->>'id')::uuid);
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', t_id('b'), 'category_id', t_id('cat'), 'check_in', (current_date + 20)::text,
         'check_out', (current_date + 22)::text, 'guest_phone', '0551000042', 'guest_name', 'ضيف المال الثاني', 'source_id', '00000000-0000-0000-0000-000000000021'));
  insert into ids values ('m2', (r->>'id')::uuid);
end $$;
do $$ declare r jsonb; c jsonb; acc uuid; v0 financial_vouchers%rowtype; n_rev int; st text; ritem int; begin
  r := fn_create_voucher(jsonb_build_object('reservation_id', t_id('m1'), 'kind', 'receipt', 'amount_halalas', 30000, 'method', 'pos', 'reference', 'TRX-QM-1', 'idempotency_key', 'qm-1'));
  reset role; select * into v0 from financial_vouchers where id = (r->>'voucher_id')::uuid; set role authenticated;
  perform fn_pos_settle(jsonb_build_object('branch_id', t_id('b'), 'account_id', v0.account_id, 'business_date', fn_branch_today(t_id('b'))::text, 'terminal_total_halalas', 30000));
  c := fn_staff_correct_voucher(jsonb_build_object('voucher_id', v0.id, 'amount_halalas', 25000, 'reason', 'المبلغ الصحيح 250', 'idempotency_key', 'qm-1c'));
  reset role;
  select status into st from financial_vouchers where id = v0.id;
  select count(*) into n_rev from financial_vouchers where reversal_of = v0.id and kind = 'refund' and amount_halalas = 30000 and status = 'approved';
  select count(*) into ritem from review_items where kind = 'voucher_reversed' and entity_id = (c->>'voucher_id')::uuid;
  perform t_record('QM01 a voucher of a settled day is not touched: a reversing voucher and the correct one are issued, with a review item',
    (c->>'settled')::boolean and st = 'approved' and n_rev = 1 and ritem = 1
    and (select amount_halalas from financial_vouchers where id = (c->>'voucher_id')::uuid) = 25000, c::text || ' ' || st || ' ' || n_rev);
  set role authenticated;
  begin perform fn_staff_correct_voucher(jsonb_build_object('voucher_id', v0.id, 'amount_halalas', 20000, 'reason', 'مرة ثانية', 'idempotency_key', 'qm-1d'));
        perform t_record('QM01b a reversed voucher is not corrected a second time', false, 'accepted');
  exception when others then perform t_record('QM01b a reversed voucher is not corrected a second time', sqlerrm like 'VOUCHER_ALREADY_REVERSED%', sqlerrm); end;
exception when others then perform t_record('QM01 a voucher of a settled day is not touched: a reversing voucher and the correct one are issued, with a review item', false, sqlerrm);
end $$;
do $$ declare r jsonb; c jsonb; t0 timestamptz; t1 timestamptz; begin
  r := fn_create_voucher(jsonb_build_object('reservation_id', t_id('m1'), 'kind', 'receipt', 'amount_halalas', 5000, 'method', 'cash', 'idempotency_key', 'qm-2',
         'occurred_at', (now() - interval '2 days')::text));
  c := fn_staff_correct_voucher(jsonb_build_object('voucher_id', (r->>'voucher_id')::uuid, 'amount_halalas', 4000, 'reason', 'خطأ في المبلغ', 'idempotency_key', 'qm-2c'));
  reset role;
  select occurred_at into t0 from financial_vouchers where id = (r->>'voucher_id')::uuid;
  select occurred_at into t1 from financial_vouchers where id = (c->>'voucher_id')::uuid;
  perform t_record('QM01c a voucher not settled is re-issued on its own business date, not today',
    not (c->>'settled')::boolean and t1 = t0 and (select status from financial_vouchers where id = (r->>'voucher_id')::uuid) = 'cancelled', t0 || ' / ' || t1);
  set role authenticated;
exception when others then perform t_record('QM01c a voucher not settled is re-issued on its own business date, not today', false, sqlerrm);
end $$;
do $$ declare r jsonb; acc uuid; n int; n2 int; begin
  reset role; acc := fn_voucher_account(t_id('b'), 'pos', null); set role authenticated;
  perform fn_pos_settle(jsonb_build_object('branch_id', t_id('b'), 'account_id', acc, 'business_date', (fn_branch_today(t_id('b')) - 1)::text, 'terminal_total_halalas', 1200, 'note', 'فرق في الجهاز'));
  reset role;
  select count(*) into n from review_items where kind = 'pos_difference' and branch_id = t_id('b');
  set role authenticated;
  perform fn_pos_settle(jsonb_build_object('branch_id', t_id('b'), 'account_id', acc, 'business_date', (fn_branch_today(t_id('b')) - 1)::text, 'terminal_total_halalas', 1500, 'note', 'تصحيح المبلغ', 'version', 1));
  reset role;
  select count(*) into n2 from review_items where kind = 'pos_difference' and branch_id = t_id('b');
  perform t_record('QM02 a POS settlement with a difference raises a review item for the owner, and again when the difference changes', n = 1 and n2 = 2, n || ' → ' || n2);
  set role authenticated;
exception when others then perform t_record('QM02 a POS settlement with a difference raises a review item for the owner, and again when the difference changes', false, sqlerrm);
end $$;
do $$ declare msg text := ''; r jsonb; n int; begin
  begin perform fn_create_voucher(jsonb_build_object('reservation_id', t_id('m2'), 'kind', 'receipt', 'amount_halalas', 1000, 'method', 'pos', 'reference', 'trx-qm-1', 'idempotency_key', 'qm-3'));
  exception when others then msg := sqlerrm; end;
  r := fn_create_voucher(jsonb_build_object('reservation_id', t_id('m2'), 'kind', 'receipt', 'amount_halalas', 1000, 'method', 'pos', 'reference', 'trx-qm-1', 'idempotency_key', 'qm-3b', 'duplicate_reference_ok', true));
  reset role;
  select count(*) into n from review_items where kind = 'voucher_duplicate_reference' and entity_id = (r->>'voucher_id')::uuid;
  perform t_record('QM03 a terminal number already on another stay is a warning naming it; confirmed, it is recorded with a review item',
    msg like 'DUPLICATE_REFERENCE:%' and position((select internal_ref from reservations where id = t_id('m1')) in msg) > 0 and (r->>'ok')::boolean and n = 1, msg);
  set role authenticated;
exception when others then perform t_record('QM03 a terminal number already on another stay is a warning naming it; confirmed, it is recorded with a review item', false, sqlerrm);
end $$;
do $$ declare d jsonb; a jsonb; dv financial_vouchers%rowtype; av financial_vouchers%rowtype; begin
  d := fn_create_voucher(jsonb_build_object('reservation_id', t_id('m2'), 'kind', 'deposit', 'amount_halalas', 5000, 'method', 'pos', 'reference', 'TRX-QM-DEP', 'idempotency_key', 'qm-4'));
  a := fn_refund(jsonb_build_object('reservation_id', t_id('m2'), 'kind', 'deposit_apply', 'amount_halalas', 2000, 'reason', 'تغطية رسوم', 'idempotency_key', 'qm-4b'));
  reset role;
  select * into dv from financial_vouchers where id = (d->>'voucher_id')::uuid;
  select * into av from financial_vouchers where id = (a->>'voucher_id')::uuid;
  perform t_record('QM04 applying the deposit carries the method and account of the deposit (POS here), not cash',
    av.method = 'pos' and av.account_id = dv.account_id, av.method || ' ' || coalesce(av.account_id::text, '-'));
  set role authenticated;
exception when others then perform t_record('QM04 applying the deposit carries the method and account of the deposit (POS here), not cash', false, sqlerrm);
end $$;
do $$ declare msg text := ''; r jsonb; n int; begin
  begin perform fn_refund(jsonb_build_object('reservation_id', t_id('m1'), 'kind', 'refund', 'amount_halalas', 1000, 'method', 'bank_transfer', 'reference', 'TR-QM-6', 'reason', 'تعويض', 'idempotency_key', 'qm-6'));
  exception when others then msg := sqlerrm; end;
  r := fn_refund(jsonb_build_object('reservation_id', t_id('m1'), 'kind', 'refund', 'amount_halalas', 1000, 'method', 'bank_transfer', 'reference', 'TR-QM-6', 'reason', 'تعويض', 'method_reason', 'طلب النزيل تحويلًا', 'idempotency_key', 'qm-6b'));
  reset role;
  select count(*) into n from review_items where kind = 'refund_other_method' and entity_id = (r->>'voucher_id')::uuid;
  perform t_record('QM06 a stay refund in another method than the payment is refused without a reason, and raises a review item with one',
    msg like 'REFUND_METHOD_DIFFERS%' and (r->>'ok')::boolean and n = 1, msg);
  set role authenticated;
exception when others then perform t_record('QM06 a stay refund in another method than the payment is refused without a reason, and raises a review item with one', false, sqlerrm);
end $$;
reset role;
do $$ declare acc uuid; n int; rep jsonb; begin
  acc := (select id from cash_accounts where branch_id = t_id('b') and kind = 'bank_account' order by created_at limit 1);
  insert into platform_payouts(organization_id, branch_id, source_id, account_id, expected_halalas, commission_bp, commission_halalas, received_halalas, difference_halalas, voucher_count, received_on, reference, note)
  values ('00000000-0000-0000-0000-000000000001', t_id('b'), '00000000-0000-0000-0000-000000000021', acc, 100000, 1500, 15000, 80000, -5000, 2, current_date, 'PAY-QM-1', 'رسوم تحويل');
  select count(*) into n from review_items where kind = 'platform_payout_difference' and branch_id = t_id('b');
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local'); set local role authenticated;
  rep := fn_reports_platforms(t_id('b'), current_date - 1, current_date);
  reset role;
  perform t_record('QM05 a platform payout with a difference raises a review item, and the period''s payouts are reported with commission and difference',
    n = 1 and (rep->>'received_halalas')::bigint = 80000 and (rep->>'commission_halalas')::bigint = 15000 and (rep->>'difference_halalas')::bigint = -5000
    and jsonb_array_length(rep->'by_source') = 1, rep::text);
exception when others then perform t_record('QM05 a platform payout with a difference raises a review item, and the period''s payouts are reported with commission and difference', false, sqlerrm);
end $$;
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
set role authenticated;
do $$ declare o jsonb; begin
  o := fn_organization_info();
  perform t_record('QM07 the staff read the organisation''s own name (the invoice header comes from it, not from the code)',
    o->>'name_ar' is not null and o->>'name_ar' = (select name_ar from organizations where id = '00000000-0000-0000-0000-000000000001'), o::text);
exception when others then perform t_record('QM07 the staff read the organisation''s own name (the invoice header comes from it, not from the code)', false, sqlerrm);
end $$;
reset role;

-- a check that comes out NULL counts as a failure here
select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),160) as detail from test_results order by ok nulls first, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from test_results where ok is not true) then raise exception 'REVIEW PHASE 1 TESTS FAILED'; end if;
  if (select count(*) from test_results) < 25 then raise exception 'REVIEW PHASE 1 TESTS INCOMPLETE: % of 25 checks ran', (select count(*) from test_results); end if;
end $$;
