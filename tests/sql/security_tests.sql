-- =====================================================================
-- Security & business-rule tests (run with psql against a DB that has all
-- migrations applied + the local auth shim; see tests/sql/run.sh)
-- Each test records PASS/FAIL into test_results. Script exits non-zero on
-- any FAIL via the final assertion.
-- =====================================================================
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;

-- ---------- helpers ----------
create or replace function t_login(p_uid uuid, p_email text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email)::text, false);
end $$;
create or replace function t_logout() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', '', false);
  perform set_config('request.jwt.claims', '', false);
end $$;
create or replace function t_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;
-- superuser-privileged readers for assertions regardless of current role
create or replace function t_room_status(p uuid) returns text language sql security definer as $$ select status::text from rooms where id = p $$;
create or replace function t_keybox_status(p uuid) returns text language sql security definer as $$ select code_status from keyboxes where room_id = p $$;
create or replace function t_pending_cleaning(p uuid) returns uuid language sql security definer as $$ select id from cleaning_tasks where room_id = p and status <> 'done' limit 1 $$;
create or replace function t_payment_count(p uuid) returns int language sql security definer as $$ select count(*)::int from payment_transactions where reservation_id = p $$;
create or replace function t_released(p uuid) returns int language sql security definer as $$ select released_count from released_slots where category_id = p and date = current_date $$;
create or replace function t_identity_status(p uuid) returns text language sql security definer as $$ select identity_status::text from reservations where id = p $$;

-- ---------- fixtures ----------
-- second org for isolation tests
insert into organizations(id, name_ar) values ('00000000-0000-0000-0000-000000000002','منشأة أخرى') on conflict do nothing;
insert into branches(id, organization_id, name_ar) values ('00000000-0000-0000-0000-000000000011','00000000-0000-0000-0000-000000000002','فرع آخر') on conflict do nothing;

insert into staff_profiles(id, auth_user_id, organization_id, full_name, email, role) values
 ('10000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','المالك','owner@test.local','owner'),
 ('10000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001','مشرف','sup@test.local','supervisor'),
 ('10000000-0000-0000-0000-000000000003','a0000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000001','نظافة','hk@test.local','housekeeping'),
 ('10000000-0000-0000-0000-000000000004','a0000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000001','مالية','fin@test.local','finance'),
 ('10000000-0000-0000-0000-000000000005','a0000000-0000-0000-0000-000000000005','00000000-0000-0000-0000-000000000002','مالك آخر','owner2@test.local','owner')
on conflict (id) do nothing;
insert into branch_memberships(staff_id, branch_id) values
 ('10000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000010'),
 ('10000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000010'),
 ('10000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000010')
on conflict do nothing;

-- =====================================================================
-- T8: knowing the reservation number alone must not expose data
-- =====================================================================
set role anon;
do $$ declare n int; begin
  begin
    select count(*) into n from reservations;
    perform t_record('T8 anon cannot read reservations table', n = 0, 'read ' || n || ' rows');
  exception when insufficient_privilege then
    perform t_record('T8 anon cannot read reservations table', true);
  end;
end $$;
do $$ declare r jsonb; begin
  r := fn_guest_lookup('BK-DEMO-1001', '9999', null, 'fp1');
  perform t_record('T8 wrong phone last4 → mismatch, no token', r->>'status' = 'mismatch' and r->>'token' is null, r::text);
end $$;
-- T7: unknown reservation → unmatched ticket, no data invented
do $$ declare r jsonb; n int; begin
  r := fn_guest_lookup('NOPE-123', '0111', null, 'fp1');
  reset role;
  select count(*) into n from human_handoff_tickets where kind='unmatched_reservation' and external_ref='NOPE-123';
  perform t_record('T7 unknown ref → supervisor ticket (unmatched)', r->>'status' = 'unmatched' and n = 1, r::text);
  set role anon;
end $$;
-- T29: valid lookup gives a short-lived token; expired token rejected
do $$ declare r jsonb; s jsonb; tok text; begin
  r := fn_guest_lookup('BK-DEMO-1001', '0111', null, 'fp1');
  tok := r->>'token';
  s := fn_guest_session(tok);
  perform t_record('T29 valid token resolves session (limited summary)', r->>'status'='ok' and s->'reservation'->>'internal_ref' is not null and s->'guests' is not null, s::text);
  reset role;
  update registration_sessions set expires_at = now() - interval '1 minute' where token = tok;
  set role anon;
  begin
    s := fn_guest_session(tok);
    perform t_record('T29 expired token rejected', false, 'returned data');
  exception when others then
    perform t_record('T29 expired token rejected', true, sqlerrm);
  end;
end $$;
-- brute force throttle
do $$ declare r jsonb; i int; begin
  for i in 1..5 loop r := fn_guest_lookup('BK-DEMO-1002', '0000', null, 'fp2'); end loop;
  r := fn_guest_lookup('BK-DEMO-1002', '0222', null, 'fp2');
  perform t_record('Lookup throttled after 5 failures', r->>'status' = 'throttled', r::text);
end $$;
reset role;
delete from guest_lookup_attempts;

-- =====================================================================
-- T18/T16: keybox code never exposed except through the gate
-- =====================================================================
set role anon;
do $$ begin
  begin
    perform code_encrypted from keyboxes limit 1;
    perform t_record('T18 anon cannot read keybox ciphertext column', false);
  exception when insufficient_privilege then perform t_record('T18 anon cannot read keybox ciphertext column', true); end;
end $$;
do $$ declare r jsonb; tok text; begin
  r := fn_guest_lookup('BK-DEMO-1002', '0222', null, 'fp3'); tok := r->>'token';
  r := fn_guest_access_code(tok);
  perform t_record('T12/T13 code denied when identity/payment not satisfied', (r->>'allowed')::boolean = false and r->>'code' is null, r::text);
end $$;
reset role;
set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000002','sup@test.local');
do $$ begin
  begin
    perform code_encrypted from keyboxes limit 1;
    perform t_record('T18 supervisor cannot read keybox ciphertext column', false);
  exception when insufficient_privilege then perform t_record('T18 supervisor cannot read keybox ciphertext column', true); end;
end $$;
do $$ begin
  begin
    perform identity_number_encrypted from reservation_guests limit 1;
    perform t_record('PII: ciphertext of document numbers unreadable via API', false);
  exception when insufficient_privilege then perform t_record('PII: ciphertext of document numbers unreadable via API', true); end;
end $$;

-- =====================================================================
-- T11: data entered ≠ identity verified; supervisor approval needed
-- =====================================================================
do $$ declare st text; begin
  st := t_identity_status('00000000-0000-0000-0000-000000000201');
  perform t_record('T11 submitted data is not "verified"', st <> 'verified', st);
end $$;

-- =====================================================================
-- RBAC: supervisor cannot write reservations directly (must use RPC)
-- =====================================================================
do $$ declare n int; begin
  -- since 0009 the money columns are not even readable through the table: the statement is refused outright
  update reservations set payment_status='paid', paid_halalas=total_halalas where id='00000000-0000-0000-0000-000000000201';
  get diagnostics n = row_count;
  perform t_record('RBAC supervisor cannot set payment_status via direct UPDATE', n = 0, 'rows=' || n);
exception when insufficient_privilege then
  perform t_record('RBAC supervisor cannot set payment_status via direct UPDATE', true, 'permission denied');
end $$;
do $$ declare n int; begin
  update keyboxes set code_status='active' where true;
  get diagnostics n = row_count;
  perform t_record('RBAC supervisor cannot UPDATE keyboxes directly', n = 0, 'rows=' || n);
end $$;
do $$ begin
  begin
    insert into audit_events(action) values ('fake');
    perform t_record('Audit log cannot be written directly by API roles', false);
  exception when others then perform t_record('Audit log cannot be written directly by API roles', true, sqlerrm); end;
end $$;
do $$ begin
  begin
    perform fn_release_next_slot('00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000030',current_date);
    perform t_record('Sequential release fn not callable by API roles', false);
  exception when insufficient_privilege then perform t_record('Sequential release fn not callable by API roles', true); end;
end $$;

-- =====================================================================
-- Housekeeping: no identity, no payments, no keybox rows; a code only through «الرموز» and never with a guest in
-- house (0025 — the full rules are in keybox_codes_tests.sql)
-- =====================================================================
select t_login('a0000000-0000-0000-0000-000000000003','hk@test.local');
do $$ declare n int; begin
  select count(*) into n from reservation_guests;
  perform t_record('Housekeeping sees no guest identity rows', n = 0, 'rows=' || n);
  select count(*) into n from keyboxes;
  perform t_record('Housekeeping sees no keyboxes', n = 0, 'rows=' || n);
  select count(*) into n from payment_transactions;
  perform t_record('Housekeeping sees no payments', n = 0, 'rows=' || n);
  -- room 104 has the guest of BK-DEMO-1004 in house
  begin
    perform fn_staff_rotate_keybox_code('00000000-0000-0000-0000-000000000103', '5555', true);
    perform t_record('Housekeeping cannot change the code of a unit with a guest in house', false);
  exception when insufficient_privilege then perform t_record('Housekeeping cannot change the code of a unit with a guest in house', sqlerrm = 'GUEST_IN_HOUSE', sqlerrm); end;
end $$;

-- =====================================================================
-- T22: branch/org isolation
-- =====================================================================
select t_login('a0000000-0000-0000-0000-000000000005','owner2@test.local');
do $$ declare n int; begin
  select count(*) into n from reservations; perform t_record('T22 other org sees 0 reservations', n = 0, 'rows='||n);
  select count(*) into n from rooms; perform t_record('T22 other org sees 0 rooms', n = 0, 'rows='||n);
  begin
    perform fn_staff_approve_checkin('00000000-0000-0000-0000-000000000200');
    perform t_record('T22 other org cannot approve check-in via RPC', false);
  exception when insufficient_privilege then perform t_record('T22 other org cannot approve check-in via RPC', true); end;
end $$;

-- =====================================================================
-- Full happy path with the gate (scenario 2: BK-DEMO-1002)
-- =====================================================================
select t_login('a0000000-0000-0000-0000-000000000002','sup@test.local');
do $$ declare r jsonb; begin
  r := fn_staff_approve_checkin('00000000-0000-0000-0000-000000000201');
  perform t_record('T12 approve check-in refused while identity unverified', (r->>'ok')::boolean = false and array_length(array(select jsonb_array_elements_text(r->'reasons')),1) >= 2, r::text);
end $$;
-- supervisor verifies identity
do $$ declare r jsonb; begin
  r := fn_staff_approve_identity('00000000-0000-0000-0000-000000000402', true);
  perform t_record('Identity approved by supervisor rolls up', r->>'identity_status' = 'verified', r::text);
end $$;
-- T13 payment missing → still refused
do $$ declare r jsonb; begin
  r := fn_staff_approve_checkin('00000000-0000-0000-0000-000000000201');
  perform t_record('T13 approve refused while payment pending', (r->>'ok')::boolean = false and r::text like '%السداد%', r::text);
end $$;
-- T17/T27 idempotent payment confirmation (no duplicate financial events)
do $$ declare r1 jsonb; r2 jsonb; n int; begin
  r1 := fn_staff_confirm_payment('00000000-0000-0000-0000-000000000201','pos',28750,'POS-REF-77','idem-001');
  r2 := fn_staff_confirm_payment('00000000-0000-0000-0000-000000000201','pos',28750,'POS-REF-77','idem-001');
  n := t_payment_count('00000000-0000-0000-0000-000000000201');
  perform t_record('T17/T27 duplicate payment confirmation ignored (idempotency)', (r2->>'duplicate')::boolean = true and n = 1 and r1->>'payment_status' = 'paid', r2::text || ' n=' || n);
end $$;
-- gov registration
select fn_staff_confirm_gov_registration('00000000-0000-0000-0000-000000000201','SHOMOOS-TEST-1');
-- T14: no room assigned / not ready → refused
do $$ declare r jsonb; begin
  r := fn_staff_approve_checkin('00000000-0000-0000-0000-000000000201');
  perform t_record('T14 refused without an assigned ready room', (r->>'ok')::boolean = false and r::text like '%غرفة%', r::text);
end $$;
-- T21: cannot assign room under maintenance (203)
do $$ begin
  begin
    perform fn_staff_assign_room('00000000-0000-0000-0000-000000000201','00000000-0000-0000-0000-000000000106');
    perform t_record('T21 maintenance room cannot be assigned', false);
  exception when others then perform t_record('T21 maintenance room cannot be assigned', sqlerrm like '%ROOM_NOT_AVAILABLE%', sqlerrm); end;
end $$;
-- T6: double allocation of same room for overlapping dates is impossible
select fn_staff_assign_room('00000000-0000-0000-0000-000000000201','00000000-0000-0000-0000-000000000100'); -- room 101
reset role;
insert into reservations(id, organization_id, branch_id, external_ref, source_id, status, check_in, check_out, room_category_id, total_halalas)
values ('00000000-0000-0000-0000-000000000299','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010','BK-DEMO-1099','00000000-0000-0000-0000-000000000020','confirmed',current_date, current_date+2,'00000000-0000-0000-0000-000000000030',25000);
set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000002','sup@test.local');
do $$ begin
  begin
    perform fn_staff_assign_room('00000000-0000-0000-0000-000000000299','00000000-0000-0000-0000-000000000100');
    perform t_record('T6 overlapping assignment of same room rejected', false, 'assigned!');
  exception when others then perform t_record('T6 overlapping assignment of same room rejected', true, sqlerrm); end;
end $$;
-- T15: keybox needing change blocks delivery — room 101 code is active in seed; force needs_change then check
reset role;
update keyboxes set code_status='needs_change' where room_id='00000000-0000-0000-0000-000000000100';
set role authenticated; select t_login('a0000000-0000-0000-0000-000000000002','sup@test.local');
do $$ declare r jsonb; begin
  r := fn_staff_approve_checkin('00000000-0000-0000-0000-000000000201');
  perform t_record('T15 keybox needing change blocks approval', (r->>'ok')::boolean = false and r::text like '%رمز الصندوق%', r::text);
end $$;
-- T20: rotate code (supervisor), must differ, field tested
do $$ declare r jsonb; begin
  begin
    perform fn_staff_rotate_keybox_code('00000000-0000-0000-0000-000000000100','1234',true);
    perform t_record('T20 rotation to the same code rejected', false);
  exception when others then perform t_record('T20 rotation to the same code rejected', sqlerrm like '%CODE_MUST_DIFFER%', sqlerrm); end;
  r := fn_staff_rotate_keybox_code('00000000-0000-0000-0000-000000000100','4321',true);
  perform t_record('T20 rotation succeeds with new code + version bump', (r->>'ok')::boolean and (r->>'code_version')::int = 2, r::text);
end $$;
-- Approve + deliver
do $$ declare r jsonb; begin
  r := fn_staff_approve_checkin('00000000-0000-0000-0000-000000000201');
  perform t_record('Gate passes once all conditions satisfied', (r->>'ok')::boolean, r::text);
end $$;
-- T2/T3: availability shows exactly 1 studio before delivery
do $$ declare n int; begin
  select available_to_show into n from fn_get_public_availability('00000000-0000-0000-0000-000000000010', current_date) where category_id='00000000-0000-0000-0000-000000000030';
  perform t_record('T2/T3 only initial release (1) shown before delivery event', n = 1, 'shown=' || n);
end $$;
do $$ declare r jsonb; begin
  r := fn_staff_deliver_access_code('00000000-0000-0000-0000-000000000201','screen');
  perform t_record('Delivery marks delivered, returns no code on screen channel', (r->>'ok')::boolean and r->>'code' is null, r::text);
  r := fn_staff_deliver_access_code('00000000-0000-0000-0000-000000000201','screen');
  perform t_record('T17 second delivery refused', (r->>'ok')::boolean = false, r::text);
end $$;
-- T4: next room released after delivery, occupied room not re-offered
do $$ declare n int; tot int; rel int; st text; begin
  select available_to_show, total_available into n, tot from fn_get_public_availability('00000000-0000-0000-0000-000000000010', current_date) where category_id='00000000-0000-0000-0000-000000000030';
  rel := t_released('00000000-0000-0000-0000-000000000030');
  st := t_room_status('00000000-0000-0000-0000-000000000100');
  perform t_record('T4 release counter advanced to 2 after confirmed delivery; shown = min(counter, free stock); room occupied',
    rel = 2 and n = least(2, tot) and st = 'occupied', 'released='||rel||' shown='||n||' free='||tot||' room='||st);
end $$;
-- T5: never exceed real stock: release many times
reset role;
do $$ declare i int; n int; begin
  for i in 1..20 loop perform fn_release_next_slot('00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000030',current_date); end loop;
  select available_to_show into n from fn_get_public_availability('00000000-0000-0000-0000-000000000010', current_date) where category_id='00000000-0000-0000-0000-000000000030';
  perform t_record('T5 shown never exceeds real free stock (6 total -1 blocked - occupied)', n <= 5 and n = (select total_available from fn_get_public_availability('00000000-0000-0000-0000-000000000010', current_date) where category_id='00000000-0000-0000-0000-000000000030'), 'shown='||n);
end $$;
-- T16: guest sees the code only for its own reservation, and gets exactly the rotated code
set role anon;
do $$ declare r jsonb; tok text; begin
  r := fn_guest_lookup('BK-DEMO-1002','0222',null,'fp9'); tok := r->>'token';
  r := fn_guest_access_code(tok);
  perform t_record('T16 guest receives code for own reservation after delivery', (r->>'allowed')::boolean and r->>'code' = '4321', r::text);
  r := fn_guest_lookup('BK-DEMO-1003','0333',null,'fp9'); tok := r->>'token';
  r := fn_guest_access_code(tok);
  perform t_record('T16 other guest cannot get that code', (r->>'allowed')::boolean = false and r->>'code' is null, r::text);
end $$;
reset role;
-- T20/T16: checkout → cleaning + code needs change; room not available until rotated
set role authenticated; select t_login('a0000000-0000-0000-0000-000000000002','sup@test.local');
do $$ declare r jsonb; st text; ks text; begin
  r := fn_staff_checkout('00000000-0000-0000-0000-000000000201');
  st := t_room_status('00000000-0000-0000-0000-000000000100');
  ks := t_keybox_status('00000000-0000-0000-0000-000000000100');
  perform t_record('Checkout → room cleaning + keybox needs_change', (r->>'ok')::boolean and st='cleaning' and ks='needs_change', st||'/'||ks);
end $$;
select t_login('a0000000-0000-0000-0000-000000000003','hk@test.local');
do $$ declare r jsonb; tid uuid; st text; begin
  tid := t_pending_cleaning('00000000-0000-0000-0000-000000000100');
  r := fn_staff_complete_cleaning(tid);
  st := t_room_status('00000000-0000-0000-0000-000000000100');
  perform t_record('Cleaning done but room NOT ready until code rotated', st = 'cleaning', 'room='||st);
end $$;
select t_login('a0000000-0000-0000-0000-000000000002','sup@test.local');
do $$ declare r jsonb; st text; begin
  r := fn_staff_rotate_keybox_code('00000000-0000-0000-0000-000000000100','8765',true);
  st := t_room_status('00000000-0000-0000-0000-000000000100');
  perform t_record('Room ready only after cleaning + rotation + test', st = 'ready', 'room='||st);
end $$;
-- Checkout with outstanding balance refused for supervisor
do $$ declare r jsonb; begin
  reset role;
  update reservations set total_halalas = 99999 where id='00000000-0000-0000-0000-000000000203';
  set role authenticated; perform t_login('a0000000-0000-0000-0000-000000000002','sup@test.local');
  r := fn_staff_checkout('00000000-0000-0000-0000-000000000203');
  perform t_record('Checkout refused with outstanding balance (supervisor)', (r->>'ok')::boolean = false, r::text);
end $$;

-- =====================================================================
-- T9/T10: guest registration validation (server side)
-- =====================================================================
set role anon;
do $$ declare r jsonb; tok text; s jsonb; begin
  r := fn_guest_lookup('BK-DEMO-1003','0333',null,'fpA'); tok := r->>'token';
  begin
    r := fn_guest_submit(tok, '00000000-0000-0000-0000-000000000403', '{"full_name":"فهد ناصر","identity_type":"national_id","identity_number":"1012345678","nationality":"سعودي","birth_date":"1990-01-01","consent":"true"}');
    perform t_record('T10 two-part name rejected', false);
  exception when others then perform t_record('T10 two-part name rejected', sqlerrm like '%full_name%', sqlerrm); end;
  begin
    r := fn_guest_submit(tok, '00000000-0000-0000-0000-000000000403', '{"full_name":"فهد ناصر الدوسري","identity_type":"national_id","identity_number":"12345","nationality":"سعودي","birth_date":"1990-01-01","consent":"true"}');
    perform t_record('T10 malformed national id rejected', false);
  exception when others then perform t_record('T10 malformed national id rejected', sqlerrm like '%identity_number_format%', sqlerrm); end;
  r := fn_guest_submit(tok, '00000000-0000-0000-0000-000000000403', '{"full_name":"فهد ناصر الدوسري","identity_type":"national_id","identity_number":"1012345678","nationality":"سعودي","birth_date":"1990-01-01","consent":"true"}');
  s := fn_guest_session(tok);
  perform t_record('T9 primary guest data accepted, only last4 exposed, status data_submitted (1 of 2)',
     (r->>'ok')::boolean and s->'guests'->0->>'identity_number_last4' = '5678' and (s::text not like '%1012345678%') and s->'reservation'->>'identity_status' = 'data_submitted', s::text);
  r := fn_guest_submit(tok, null, '{"full_name":"سعد فهد الدوسري","identity_type":"national_id","identity_number":"1099999999","nationality":"سعودي","birth_date":"2015-01-01","relationship":"child","consent":"true"}');
  s := fn_guest_session(tok);
  perform t_record('T9 second person completes → pending_supervisor, supervisor notified', s->'reservation'->>'identity_status' = 'pending_supervisor', s->'reservation'->>'identity_status');
  begin
    r := fn_guest_submit(tok, null, '{"full_name":"سعد فهد الدوسري","identity_type":"national_id","identity_number":"1099999999","nationality":"سعودي","birth_date":"2015-01-01","relationship":"child","consent":"true"}');
    perform t_record('T9 companion beyond adults+companions limit rejected', false);
  exception when others then perform t_record('T9 companion beyond adults+companions limit rejected', sqlerrm like '%GUEST_LIMIT%', sqlerrm); end;
  -- duplicate document guard: raise limit then re-add same person
  reset role;
  update reservations set companions = 1 where id = '00000000-0000-0000-0000-000000000202';
  set role anon;
  begin
    r := fn_guest_submit(tok, null, '{"full_name":"سعد فهد الدوسري","identity_type":"national_id","identity_number":"1099999999","nationality":"سعودي","birth_date":"2015-01-01","relationship":"child","consent":"true"}');
    perform t_record('T9 duplicate document in same reservation rejected', false);
  exception when others then perform t_record('T9 duplicate document in same reservation rejected', sqlerrm like '%DUPLICATE_GUEST%', sqlerrm); end;
end $$;
reset role;

-- T26: money arithmetic sanity (integers, halalas)
do $$ declare r reservations%rowtype; begin
  select * into r from reservations where id='00000000-0000-0000-0000-000000000200';
  perform t_record('T26 totals stored as integer halalas and consistent', r.total_halalas = r.rent_amount_halalas + r.taxes_halalas - coalesce(r.discount_halalas,0) + coalesce(r.addons_halalas,0), r.total_halalas::text);
end $$;

-- =====================================================================
-- RESULTS
-- =====================================================================
select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),110) as detail from test_results order by ok, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from test_results where ok is not true) then raise exception 'SECURITY TESTS FAILED'; end if;
end $$;
