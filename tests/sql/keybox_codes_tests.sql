-- =====================================================================
-- «الرموز» — the key-box codes of the units (KC01–KC15, migration 0025).
-- A branch of its own ("فرع الرموز") with three units: K-1 vacant with a code, K-2 with a guest in house, K-3 without
-- a key box; supervisor a…02, housekeeping a…03 and finance a…04 are its members. A second branch has no members.
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
create or replace function t_kb(p_room uuid) returns keyboxes language sql security definer as $$ select * from keyboxes where room_id = p_room $$;
create or replace function t_room(p uuid) returns rooms language sql security definer as $$ select * from rooms where id = p $$;
create or replace function t_row(p_board jsonb, p_room uuid) returns jsonb language sql as $$
  select e from jsonb_array_elements(p_board) e where e->>'room_id' = p_room::text
$$;
create or replace function t_audits(p_room uuid, p_action text) returns bigint language sql security definer as $$
  select count(*) from audit_events where entity_id = p_room and action = p_action
$$;
create or replace function t_last_audit(p_room uuid, p_action text) returns jsonb language sql security definer as $$
  select details from audit_events where entity_id = p_room and action = p_action order by created_at desc limit 1
$$;
create or replace function t_cleaning_task(p_room uuid) returns uuid language sql security definer as $$
  select id from housekeeping_tasks where room_id = p_room and status in ('pending','in_progress') limit 1
$$;
create or replace function t_last_rotation_by(p_room uuid) returns uuid language sql security definer as $$
  select rotated_by from code_rotation_events where room_id = p_room order by created_at desc, to_version desc limit 1
$$;

-- ---------------------------------------------------------------- fixtures (the owner, through the normal functions)
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; b uuid; b2 uuid; cat uuid; cat2 uuid; begin
  r := fn_admin_upsert_branch('{"name_ar":"فرع الرموز","tax_rate_bp":0}'); b := (r->>'id')::uuid;
  r := fn_admin_upsert_branch('{"name_ar":"فرع بلا أعضاء","tax_rate_bp":0}'); b2 := (r->>'id')::uuid;
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', b, 'name_ar', 'استوديو الرموز', 'base_price_halalas', 10000)); cat := (r->>'id')::uuid;
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', b2, 'name_ar', 'استوديو آخر', 'base_price_halalas', 10000)); cat2 := (r->>'id')::uuid;
  insert into ids values ('b', b), ('b2', b2);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', 'K-1')); insert into ids values ('k1', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', 'K-2')); insert into ids values ('k2', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', 'K-3')); insert into ids values ('k3', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', b2, 'category_id', cat2, 'room_number', 'X-1')); insert into ids values ('x1', (r->>'id')::uuid);
  perform fn_staff_rotate_keybox_code(t_id('k1'), '2468', true);
  perform fn_staff_rotate_keybox_code(t_id('k2'), '1357', true);
  perform fn_staff_rotate_keybox_code(t_id('x1'), '9753', true);
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_id', t_id('k2'), 'check_in', (current_date - 1)::text,
         'check_out', (current_date + 1)::text, 'guest_name', 'ضيف الرموز', 'source_id', '00000000-0000-0000-0000-000000000021'));
  insert into ids values ('res', (r->>'id')::uuid);
end $$;
reset role;
insert into branch_memberships(staff_id, branch_id)
select s, t_id('b') from unnest(array['10000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000004']::uuid[]) s
on conflict do nothing;
update reservations set status = 'checked_in', actual_check_in = now() where id = t_id('res');
update rooms set status = 'occupied' where id = t_id('k2');

-- ---------------------------------------------------------------- housekeeping: the screen, and a unit with a guest in house
select t_login('a0000000-0000-0000-0000-000000000003', 'hk@test.local');
set role authenticated;
do $$ declare b jsonb; k1 jsonb; k2 jsonb; k3 jsonb; begin
  b := fn_keybox_board(t_id('b'));
  k1 := t_row(b, t_id('k1')); k2 := t_row(b, t_id('k2')); k3 := t_row(b, t_id('k3'));
  perform t_record('KC01 housekeeping sees every unit and the state of its code (K-1 ok, K-2 guest in house: no view, no change, K-3 no key box) — never a code',
    jsonb_array_length(b) = 3 and k1->>'state' = 'ok' and (k1->>'can_change')::boolean and (k1->>'can_view')::boolean
    and (k2->>'guest_in_house')::boolean and not (k2->>'can_change')::boolean and not (k2->>'can_view')::boolean
    and k3->>'state' = 'none' and not (k3->>'can_view')::boolean and (k3->>'can_change')::boolean
    and not exists (select 1 from jsonb_array_elements(b) e where e ? 'code'), b::text);
exception when others then perform t_record('KC01 housekeeping sees every unit and the state of its code (K-1 ok, K-2 guest in house: no view, no change, K-3 no key box) — never a code', false, sqlerrm); end $$;

do $$ declare n int := 0; msgs text := ''; begin
  begin perform fn_keybox_reveal(t_id('k2')); exception when insufficient_privilege then if sqlerrm = 'GUEST_IN_HOUSE' then n := n + 1; end if; msgs := msgs || sqlerrm || ' '; end;
  begin perform fn_staff_rotate_keybox_code(t_id('k2'), '8642', true); exception when insufficient_privilege then if sqlerrm = 'GUEST_IN_HOUSE' then n := n + 1; end if; msgs := msgs || sqlerrm || ' '; end;
  begin perform fn_staff_mark_keybox_tested(t_id('k2')); exception when insufficient_privilege then if sqlerrm = 'GUEST_IN_HOUSE' then n := n + 1; end if; msgs := msgs || sqlerrm || ' '; end;
  perform t_record('KC02 with a guest in house, housekeeping can neither see, change nor re-test the unit''s code',
    n = 3 and (t_kb(t_id('k2'))).code_version = 1 and t_audits(t_id('k2'), 'keybox.code_viewed') = 0, msgs);
end $$;

do $$ declare n int := 0; msgs text := ''; begin
  begin perform fn_keybox_board(t_id('b2')); exception when insufficient_privilege then if sqlerrm like 'FORBIDDEN%' then n := n + 1; end if; msgs := msgs || sqlerrm || ' '; end;
  begin perform fn_keybox_alerts(t_id('b2')); exception when insufficient_privilege then if sqlerrm like 'FORBIDDEN%' then n := n + 1; end if; msgs := msgs || sqlerrm || ' '; end;
  begin perform fn_keybox_reveal(t_id('x1')); exception when insufficient_privilege then if sqlerrm like 'FORBIDDEN%' then n := n + 1; end if; msgs := msgs || sqlerrm || ' '; end;
  begin perform fn_staff_rotate_keybox_code(t_id('x1'), '1111', true); exception when insufficient_privilege then if sqlerrm like 'FORBIDDEN%' then n := n + 1; end if; msgs := msgs || sqlerrm || ' '; end;
  perform t_record('KC03 another branch''s codes are out of reach (screen, alert, view, change)', n = 4 and (t_kb(t_id('x1'))).code_version = 1, msgs);
end $$;

select t_login('a0000000-0000-0000-0000-000000000004', 'fin@test.local');
do $$ declare n int := 0; msgs text := ''; begin
  begin perform fn_keybox_board(t_id('b')); exception when insufficient_privilege then n := n + 1; msgs := msgs || sqlerrm || ' '; end;
  begin perform fn_keybox_reveal(t_id('k1')); exception when insufficient_privilege then n := n + 1; msgs := msgs || sqlerrm || ' '; end;
  begin perform fn_staff_rotate_keybox_code(t_id('k1'), '1111', true); exception when insufficient_privilege then n := n + 1; msgs := msgs || sqlerrm || ' '; end;
  perform t_record('KC04 finance has no access to the codes (screen, view, change)', n = 3, msgs);
end $$;
reset role;
set role anon;
do $$ declare n int := 0; begin
  begin perform fn_keybox_board(t_id('b')); exception when insufficient_privilege then n := n + 1; end;
  begin perform fn_keybox_alerts(t_id('b')); exception when insufficient_privilege then n := n + 1; end;
  begin perform fn_keybox_reveal(t_id('k1')); exception when insufficient_privilege then n := n + 1; end;
  perform t_record('KC05 the public cannot call the codes functions at all', n = 3, n::text);
end $$;
reset role;

-- ---------------------------------------------------------------- the supervisor may see an in-house unit's code (audited)
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
set role authenticated;
do $$ declare r jsonb; a jsonb; begin
  r := fn_keybox_reveal(t_id('k2'));
  a := t_last_audit(t_id('k2'), 'keybox.code_viewed');
  perform t_record('KC06 the supervisor sees the code of a unit with a guest in house; the view is in the audit trail with its version, never the code',
    r->>'code' = '1357' and t_audits(t_id('k2'), 'keybox.code_viewed') = 1 and (a->'after'->>'code_version')::int = 1
    and (a->'after'->>'guest_in_house')::boolean and a::text not like '%1357%', r::text || ' ' || coalesce(a::text, ''));
exception when others then perform t_record('KC06 the supervisor sees the code of a unit with a guest in house; the view is in the audit trail with its version, never the code', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- the guest leaves: the unit turns red for everyone
do $$ declare r jsonb; f jsonb; begin
  f := fn_reservation_finance(t_id('res'));
  if (f->>'balance_due')::bigint > 0 then
    perform fn_create_voucher(jsonb_build_object('reservation_id', t_id('res'), 'kind', 'receipt', 'amount_halalas', (f->>'balance_due')::bigint, 'method', 'cash', 'idempotency_key', 'kc-pay'));
  end if;
  r := fn_staff_checkout(t_id('res'));
  if not (r->>'ok')::boolean then raise exception 'checkout refused: %', r; end if;
end $$;
select t_login('a0000000-0000-0000-0000-000000000003', 'hk@test.local');
do $$ declare b jsonb; k2 jsonb; al jsonb; since timestamptz; begin
  b := fn_keybox_board(t_id('b')); k2 := t_row(b, t_id('k2'));
  al := fn_keybox_alerts(t_id('b'));
  since := (k2->>'needs_change_since')::timestamptz;
  perform t_record('KC07 check-out turns the unit red at once (since when, counted in the alert) and housekeeping may now act on it',
    k2->>'state' = 'change' and since is not null and since > now() - interval '5 minutes' and not (k2->>'guest_in_house')::boolean
    and (k2->>'can_change')::boolean and (k2->>'can_view')::boolean
    and (al->>'count')::int = 1 and al->'rooms' = '["K-2"]'::jsonb and (al->>'oldest_since')::timestamptz = since, k2::text || ' ' || al::text);
exception when others then perform t_record('KC07 check-out turns the unit red at once (since when, counted in the alert) and housekeeping may now act on it', false, sqlerrm); end $$;

do $$ declare r jsonb; a jsonb; begin
  r := fn_keybox_reveal(t_id('k2'));
  a := t_last_audit(t_id('k2'), 'keybox.code_viewed');
  perform t_record('KC08 housekeeping sees the old code to open the box; audited without the code',
    r->>'code' = '1357' and t_audits(t_id('k2'), 'keybox.code_viewed') = 2 and a->'after'->>'code_status' = 'needs_change' and a::text not like '%1357%', r::text);
exception when others then perform t_record('KC08 housekeeping sees the old code to open the box; audited without the code', false, sqlerrm); end $$;

do $$ declare msg text := ''; begin
  begin perform fn_staff_rotate_keybox_code(t_id('k2'), '1357', true); exception when others then msg := sqlerrm; end;
  perform t_record('KC09 saving the same code again is refused — the unit stays red',
    msg = 'CODE_MUST_DIFFER_FROM_PREVIOUS' and (t_kb(t_id('k2'))).code_status = 'needs_change' and (t_kb(t_id('k2'))).code_version = 1, msg);
end $$;

do $$ declare n int := 0; msgs text := ''; begin
  begin perform fn_staff_rotate_keybox_code(t_id('k2'), '12', true); exception when others then if sqlerrm like 'VALIDATION: code_must_be_4_to_8_digits%' then n := n + 1; end if; msgs := msgs || sqlerrm || ' '; end;
  begin perform fn_staff_rotate_keybox_code(t_id('k2'), '123456789', true); exception when others then if sqlerrm like 'VALIDATION: code_must_be_4_to_8_digits%' then n := n + 1; end if; msgs := msgs || sqlerrm || ' '; end;
  begin perform fn_staff_rotate_keybox_code(t_id('k2'), '12a4', true); exception when others then if sqlerrm like 'VALIDATION: code_must_be_4_to_8_digits%' then n := n + 1; end if; msgs := msgs || sqlerrm || ' '; end;
  begin perform fn_staff_rotate_keybox_code(t_id('k2'), null, true); exception when others then if sqlerrm like 'VALIDATION: code_must_be_4_to_8_digits%' then n := n + 1; end if; msgs := msgs || sqlerrm || ' '; end;
  perform t_record('KC10 a code is 4 to 8 digits', n = 4 and (t_kb(t_id('k2'))).code_version = 1, msgs);
end $$;

do $$ declare r jsonb; begin
  r := fn_staff_complete_cleaning(t_cleaning_task(t_id('k2')));
  perform t_record('KC11 cleaning done is not enough: the unit is not ready while its code must still change',
    (t_room(t_id('k2'))).cleanliness = 'clean' and (t_room(t_id('k2'))).status = 'cleaning' and (t_kb(t_id('k2'))).code_status = 'needs_change', r::text);
exception when others then perform t_record('KC11 cleaning done is not enough: the unit is not ready while its code must still change', false, sqlerrm); end $$;

do $$ declare r jsonb; b jsonb; k2 jsonb; a jsonb; al jsonb; kb keyboxes; begin
  r := fn_staff_rotate_keybox_code(t_id('k2'), '8642', true);
  kb := t_kb(t_id('k2'));
  b := fn_keybox_board(t_id('b')); k2 := t_row(b, t_id('k2'));
  a := t_last_audit(t_id('k2'), 'rotate_keybox_code');
  al := fn_keybox_alerts(t_id('b'));
  perform t_record('KC12 housekeeping saves a new tested code: green, ready, version up, by the housekeeper; audit before/after without the code; the alert clears',
    (r->>'ok')::boolean and r->>'room_status' = 'ready' and (r->>'code_version')::int = 2
    and kb.code_status = 'active' and kb.field_tested and kb.needs_change_since is null and kb.last_reservation_id is null
    and k2->>'state' = 'ok' and k2->>'last_changed_by' = 'نظافة'
    and t_last_rotation_by(t_id('k2')) = '10000000-0000-0000-0000-000000000003'
    and a->'before'->>'code_status' = 'needs_change' and a->'after'->>'code_status' = 'active' and (a->'after'->>'code_version')::int = 2
    and a::text not like '%8642%' and a::text not like '%1357%'
    and (al->>'count')::int = 0 and al->'rooms' = '[]'::jsonb, r::text || ' ' || coalesce(a::text, '') || ' ' || al::text);
exception when others then perform t_record('KC12 housekeeping saves a new tested code: green, ready, version up, by the housekeeper; audit before/after without the code; the alert clears', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- a code not yet tried on the box, and the first code of a unit
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
do $$ declare r jsonb; s1 text; begin
  r := fn_staff_rotate_keybox_code(t_id('k1'), '1122', false);
  s1 := t_row(fn_keybox_board(t_id('b')), t_id('k1'))->>'state';
  perform set_config('kc.untested', s1 || '/' || (r->>'room_status'), false);
end $$;
select t_login('a0000000-0000-0000-0000-000000000003', 'hk@test.local');
do $$ declare r jsonb; s2 text; begin
  r := fn_staff_mark_keybox_tested(t_id('k1'));
  s2 := t_row(fn_keybox_board(t_id('b')), t_id('k1'))->>'state';
  perform t_record('KC13 a new code not yet tried on the box is amber and keeps the unit not ready; housekeeping confirms the test → green and ready',
    current_setting('kc.untested') = 'untested/cleaning' and s2 = 'ok' and r->>'room_status' = 'ready', current_setting('kc.untested') || ' → ' || s2 || ' ' || r::text);
exception when others then perform t_record('KC13 a new code not yet tried on the box is amber and keeps the unit not ready; housekeeping confirms the test → green and ready', false, sqlerrm); end $$;

do $$ declare r jsonb; kb keyboxes; n int; begin
  r := fn_staff_rotate_keybox_code(t_id('k3'), '5678', true);
  kb := t_kb(t_id('k3'));
  select count(*) into n from keyboxes;      -- housekeeping still reads no key box row itself (RLS); the screen goes through the functions
  perform t_record('KC14 housekeeping gives a unit without a key box its first code; the keyboxes table itself stays unreadable to housekeeping',
    (r->>'ok')::boolean and kb.code_version = 1 and kb.code_status = 'active' and kb.field_tested
    and t_row(fn_keybox_board(t_id('b')), t_id('k3'))->>'state' = 'ok' and n = 0, r::text || ' rows=' || n);
exception when others then perform t_record('KC14 housekeeping gives a unit without a key box its first code; the keyboxes table itself stays unreadable to housekeeping', false, sqlerrm); end $$;
reset role;

-- ---------------------------------------------------------------- since when: kept from the first moment, cleared by a new code
update keyboxes set code_status = 'needs_change', field_tested = false where room_id = t_id('k1');
select set_config('kc.since1', (select needs_change_since::text from keyboxes where room_id = t_id('k1')), false);
update keyboxes set code_status = 'needs_change' where room_id = t_id('k1');
set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000003', 'hk@test.local');
do $$ declare s2 timestamptz := (t_kb(t_id('k1'))).needs_change_since; msg text := ''; r jsonb; begin
  begin perform fn_staff_mark_keybox_tested(t_id('k1')); exception when others then msg := sqlerrm; end;
  r := fn_staff_rotate_keybox_code(t_id('k1'), '3344', true);
  perform t_record('KC15 the waiting time is kept from the first moment (a second mark keeps it), a test of the old code is refused, and a new code clears it',
    nullif(current_setting('kc.since1'), '') is not null and s2 = current_setting('kc.since1')::timestamptz
    and msg = 'CODE_NEEDS_CHANGE' and (t_kb(t_id('k1'))).needs_change_since is null and (r->>'ok')::boolean,
    current_setting('kc.since1') || ' / ' || s2 || ' / ' || msg);
exception when others then perform t_record('KC15 the waiting time is kept from the first moment (a second mark keeps it), a test of the old code is refused, and a new code clears it', false, sqlerrm); end $$;
reset role;

-- a check that comes out NULL counts as a failure here
select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),140) as detail from test_results order by ok nulls first, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from test_results where ok is not true) then raise exception 'KEY-BOX CODE TESTS FAILED'; end if;
  -- a statement that errors before recording its check would otherwise just be missing
  if (select count(*) from test_results) < 15 then raise exception 'KEY-BOX CODE TESTS INCOMPLETE: % of 15 checks ran', (select count(*) from test_results); end if;
end $$;
