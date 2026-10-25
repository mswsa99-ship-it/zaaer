-- =====================================================================
-- Traceable audit (decision 39, G22) and failure in the middle of an operation (X08).
-- AT01–AT08: correlation, source, actor type, security category, owner-only security events,
-- memberships only through audited functions, audit rows cannot be changed.
-- X08a/X08b: a fault injected after the voucher row and before its audit row, and after the task update and
-- before the cleanliness update, leaves no partial rows; the authorised retry then succeeds.
-- Runs after core_tests.sql on the same database (uses its synthetic organisation and staff).
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
create or replace function t_audit(p_entity uuid, p_action text) returns audit_events language sql security definer as $$
  select * from audit_events where entity_id = p_entity and action = p_action order by created_at desc limit 1
$$;
create or replace function t_count(p_sql text) returns bigint language plpgsql security definer as $$ declare n bigint; begin execute p_sql into n; return n; end $$;
create or replace function t_ver(p_table text, p_id uuid) returns int language plpgsql security definer as $$ declare v int; begin execute format('select version from %I where id = $1', p_table) into v using p_id; return v; end $$;

-- ---------------------------------------------------------------- fixtures: a reservation, a unit with a cleaning task
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; begin
  r := fn_staff_create_reservation(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','category_id','00000000-0000-0000-0000-000000000030',
         'check_in', (current_date + 40)::text, 'check_out', (current_date + 42)::text, 'guest_name', 'ضيف التدقيق', 'source_id', '00000000-0000-0000-0000-000000000021'));
  insert into ids values ('res', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','category_id','00000000-0000-0000-0000-000000000030','room_number','AT-1'));
  insert into ids values ('room', (r->>'id')::uuid);
end $$;
reset role;
insert into ids select 'tt', id from task_types where branch_id = '00000000-0000-0000-0000-000000000010' and code = 'room_cleaning';

-- ---------------------------------------------------------------- AT01–AT04: fields filled for every row
set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
do $$ declare v jsonb; a audit_events; begin
  v := fn_create_voucher(jsonb_build_object('reservation_id', t_id('res'), 'kind','receipt', 'amount_halalas', 1000, 'method','cash', 'idempotency_key','at-01'));
  a := t_audit((v->>'voucher_id')::uuid, 'voucher.receipt_created');
  perform t_record('AT01 an audit row gets a transaction correlation, staff actor, screen source, success, business category',
    a.correlation_id like 'tx-%' and a.actor_type = 'staff' and a.actor_id is not null and a.source = 'screen' and a.result = 'success' and a.category = 'business',
    row_to_json(a)::text);
exception when others then perform t_record('AT01 an audit row gets a transaction correlation, staff actor, screen source, success, business category', false, sqlerrm); end $$;

-- two operations in one transaction share one correlation (one call = one operation in the app)
do $$ declare v1 jsonb; v2 jsonb; c1 text; c2 text; begin
  v1 := fn_create_voucher(jsonb_build_object('reservation_id', t_id('res'), 'kind','receipt', 'amount_halalas', 500, 'method','cash', 'idempotency_key','at-02a'));
  v2 := fn_create_voucher(jsonb_build_object('reservation_id', t_id('res'), 'kind','deposit', 'amount_halalas', 500, 'method','cash', 'idempotency_key','at-02b'));
  c1 := (t_audit((v1->>'voucher_id')::uuid, 'voucher.receipt_created')).correlation_id;
  c2 := (t_audit((v2->>'voucher_id')::uuid, 'voucher.deposit_created')).correlation_id;
  perform t_record('AT02 the rows written by one transaction share its correlation', c1 is not null and c1 = c2, c1 || ' / ' || c2);
exception when others then perform t_record('AT02 the rows written by one transaction share its correlation', false, sqlerrm); end $$;

select set_config('request.headers', '{"x-correlation-id":"AbC-12345678","x-client-source":"staff-app"}', false);
do $$ declare v jsonb; a audit_events; begin
  v := fn_create_voucher(jsonb_build_object('reservation_id', t_id('res'), 'kind','receipt', 'amount_halalas', 100, 'method','cash', 'idempotency_key','at-03'));
  a := t_audit((v->>'voucher_id')::uuid, 'voucher.receipt_created');
  perform t_record('AT03 the app''s correlation and source headers are used when well formed', a.correlation_id = 'AbC-12345678' and a.source = 'staff-app', row_to_json(a)::text);
exception when others then perform t_record('AT03 the app''s correlation and source headers are used when well formed', false, sqlerrm); end $$;
select set_config('request.headers', '{"x-correlation-id":"bad id; select 1","x-client-source":"<script>"}', false);
do $$ declare v jsonb; a audit_events; begin
  v := fn_create_voucher(jsonb_build_object('reservation_id', t_id('res'), 'kind','receipt', 'amount_halalas', 100, 'method','cash', 'idempotency_key','at-04'));
  a := t_audit((v->>'voucher_id')::uuid, 'voucher.receipt_created');
  perform t_record('AT04 malformed headers are ignored (transaction correlation, default source)', a.correlation_id like 'tx-%' and a.source = 'screen', row_to_json(a)::text);
exception when others then perform t_record('AT04 malformed headers are ignored (transaction correlation, default source)', false, sqlerrm); end $$;
select set_config('request.headers', '', false);
select set_config('app.source', 'ops_assistant', false);
do $$ declare v jsonb; a audit_events; begin
  v := fn_create_voucher(jsonb_build_object('reservation_id', t_id('res'), 'kind','receipt', 'amount_halalas', 100, 'method','cash', 'idempotency_key','at-05'));
  a := t_audit((v->>'voucher_id')::uuid, 'voucher.receipt_created');
  perform t_record('AT05 a trusted in-database source (the operations assistant) is recorded', a.source = 'ops_assistant', row_to_json(a)::text);
exception when others then perform t_record('AT05 a trusted in-database source (the operations assistant) is recorded', false, sqlerrm); end $$;
select set_config('app.source', '', false);

-- ---------------------------------------------------------------- AT06: staff changes are security events, owner only
-- since 0040 the profile table is written through fn_admin_set_staff_active only (a direct update changes nothing);
-- the function keeps the trigger's two security events and adds the reason to them
do $$ declare n int; r int; begin
  perform fn_admin_set_staff_active('10000000-0000-0000-0000-000000000006', false, 'اختبار التتبع');
  perform fn_admin_set_staff_active('10000000-0000-0000-0000-000000000006', true, 'اختبار التتبع');
  select count(*), count(*) filter (where details->>'reason' = 'اختبار التتبع') into n, r from audit_events where entity_id = '10000000-0000-0000-0000-000000000006' and action in ('staff.deactivated','staff.activated') and category = 'security';
  perform t_record('AT06a deactivating and reactivating a staff member leaves two security events the owner can read', n = 2 and r = 2, n || ' / with reason ' || r);
exception when others then perform t_record('AT06a deactivating and reactivating a staff member leaves two security events the owner can read', false, sqlerrm); end $$;
select t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
do $$ declare n int; m int; begin
  select count(*) into n from audit_events where entity_id = '10000000-0000-0000-0000-000000000006' and category = 'security';
  select count(*) into m from audit_events where category = 'business';
  perform t_record('AT06b a manager reads business events but no security event', n = 0 and m > 0, n || ' / ' || m);
exception when others then perform t_record('AT06b a manager reads business events but no security event', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- AT07: memberships only through audited functions
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
do $$ declare msg text := 'accepted'; n int; begin
  begin
    insert into branch_memberships(staff_id, branch_id) values ('10000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-000000000010');
  exception when others then msg := sqlerrm; end;
  select t_count('select count(*) from branch_memberships where staff_id = ''10000000-0000-0000-0000-000000000006'' and branch_id = ''00000000-0000-0000-0000-000000000010''') into n;
  perform t_record('AT07a even the owner cannot write a membership directly', n = 0 and msg <> 'accepted', msg);
exception when others then perform t_record('AT07a even the owner cannot write a membership directly', false, sqlerrm); end $$;
do $$ declare r jsonb; a audit_events; begin
  r := fn_staff_invite('at-invite@test.local', 'موظف تدقيق', 'supervisor', array['00000000-0000-0000-0000-000000000010']::uuid[]);
  a := t_audit((r->>'staff_id')::uuid, 'staff_invited');
  perform t_record('AT07b an invite records its branches in a security event',
    a.category = 'security' and a.details->'branch_ids' ? '00000000-0000-0000-0000-000000000010'
    and t_count(format('select count(*) from branch_memberships where staff_id = %L', r->>'staff_id')) = 1, row_to_json(a)::text);
exception when others then perform t_record('AT07b an invite records its branches in a security event', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- AT08: audit rows cannot be changed through the API
do $$ declare n int; begin
  update audit_events set action = 'tampered' where organization_id = '00000000-0000-0000-0000-000000000001';
  get diagnostics n = row_count;
  perform t_record('AT08 nobody can change an audit row through the API', n = 0 and t_count('select count(*) from audit_events where action = ''tampered''') = 0, n::text);
exception when others then perform t_record('AT08 nobody can change an audit row through the API', true, sqlerrm); end $$;
reset role;

-- ---------------------------------------------------------------- CE: trace codes of failed operations (decision 60)
set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
do $$ declare r1 jsonb; r2 jsonb; r3 jsonb; begin
  r1 := fn_log_client_error('K7Q2M9XA', 'ALLOCATION_CONFLICT', 'fn_staff_assign_room');
  r2 := fn_log_client_error('bad code!', 'ALLOCATION_CONFLICT', 'fn_staff_assign_room');
  r3 := fn_log_client_error('K7Q2M9XB', 'room 101 of Ahmed', 'fn_staff_assign_room');
  perform t_record('CE01 a staff member records a failure by its code; a malformed code is ignored and free text never stored',
    (r1->>'ok')::boolean and not (r2->>'ok')::boolean and (r3->>'ok')::boolean
    and t_count('select count(*) from client_errors where trace_id = ''K7Q2M9XB'' and error_code = ''UNKNOWN''') = 1
    and t_count('select count(*) from client_errors where trace_id = ''bad code!''') = 0, r1::text || r2::text || r3::text);
exception when others then perform t_record('CE01 a staff member records a failure by its code; a malformed code is ignored and free text never stored', false, sqlerrm); end $$;
do $$ declare n int; msg text := 'accepted'; begin
  select count(*) into n from client_errors;
  begin perform fn_lookup_trace('K7Q2M9XA'); exception when others then msg := sqlerrm; end;
  perform t_record('CE02 a supervisor neither reads the failures nor looks a code up', n = 0 and msg like 'FORBIDDEN%', n || ' / ' || msg);
exception when others then perform t_record('CE02 a supervisor neither reads the failures nor looks a code up', false, sqlerrm); end $$;
select t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
select set_config('request.headers', '{"x-correlation-id":"OKCODE2345"}', false);
do $$ declare v jsonb; f jsonb; s jsonb; begin
  v := fn_create_voucher(jsonb_build_object('reservation_id', t_id('res'), 'kind','receipt', 'amount_halalas', 100, 'method','cash', 'idempotency_key','ce-03'));
  f := fn_lookup_trace('K7Q2M9XA');
  s := fn_lookup_trace('OKCODE2345');
  perform t_record('CE03 the manager finds a failed code (its error) and a successful one (its audit rows)',
    f->'failure'->>'error_code' = 'ALLOCATION_CONFLICT' and f->'failure'->>'context' = 'fn_staff_assign_room'
    and coalesce(f->'failure'->>'staff_name', '') <> '' and f->'failure' ? 'organization_id' = false
    and jsonb_array_length(s->'events') >= 1 and s->'failure' = 'null'::jsonb
    and s->'events'->0->>'actor_name' is not null and s->'events'->0->>'result' = 'success', f::text || ' / ' || s::text);
exception when others then perform t_record('CE03 the manager finds a failed code (its error) and a successful one (its audit rows)', false, sqlerrm); end $$;
select set_config('request.headers', '', false);
do $$ declare msg text := 'accepted'; begin
  begin insert into client_errors(organization_id, trace_id, error_code) values ('00000000-0000-0000-0000-000000000001', 'FORGED123', 'X'); exception when others then msg := sqlerrm; end;
  perform t_record('CE04 nobody writes a failure row directly', msg <> 'accepted' and t_count('select count(*) from client_errors where trace_id = ''FORGED123''') = 0, msg);
exception when others then perform t_record('CE04 nobody writes a failure row directly', false, sqlerrm); end $$;
reset role;

-- ---------------------------------------------------------------- X08: failure in the middle of an operation
-- Test-only fault injection: armed by a session setting, never present in a migration.
create or replace function t_fail_audit() returns trigger language plpgsql as $$
begin
  if current_setting('test.fail_audit', true) = 'on' then raise exception 'INJECTED_FAULT: audit'; end if;
  return new;
end $$;
create trigger t_fail_audit before insert on audit_events for each row execute function t_fail_audit();
create or replace function t_fail_room() returns trigger language plpgsql as $$
begin
  if current_setting('test.fail_room', true) = 'on' then raise exception 'INJECTED_FAULT: room'; end if;
  return new;
end $$;
create trigger t_fail_room before update on rooms for each row execute function t_fail_room();

set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
do $$ declare msg text := 'accepted'; before_paid bigint; after_paid bigint; v jsonb; begin
  select (fn_reservation_finance(t_id('res'))->>'received')::bigint into before_paid;
  perform set_config('test.fail_audit', 'on', true);
  begin
    perform fn_create_voucher(jsonb_build_object('reservation_id', t_id('res'), 'kind','receipt', 'amount_halalas', 2500, 'method','cash', 'idempotency_key','x08-a'));
  exception when others then msg := sqlerrm; end;
  perform set_config('test.fail_audit', 'off', true);
  select (fn_reservation_finance(t_id('res'))->>'received')::bigint into after_paid;
  perform t_record('X08a a fault after the voucher row and before its audit row leaves no voucher and no change to what was received',
    msg like 'INJECTED_FAULT%' and t_count('select count(*) from financial_vouchers where idempotency_key = ''x08-a''') = 0 and after_paid = before_paid,
    msg || ' / ' || before_paid || ' / ' || after_paid);
  v := fn_create_voucher(jsonb_build_object('reservation_id', t_id('res'), 'kind','receipt', 'amount_halalas', 2500, 'method','cash', 'idempotency_key','x08-a'));
  perform t_record('X08a2 the retry with the same key then succeeds once',
    (v->>'ok')::boolean and not (v->>'duplicate')::boolean and t_count('select count(*) from financial_vouchers where idempotency_key = ''x08-a''') = 1, v::text);
exception when others then perform t_record('X08a a fault after the voucher row and before its audit row leaves no voucher and no change to what was received', false, sqlerrm); end $$;

do $$ declare r jsonb; task uuid; msg text := 'accepted'; st text; cl text; begin
  r := fn_hk_create_task(jsonb_build_object('room_id', t_id('room'), 'task_type_id', t_id('tt')));
  task := (r->>'id')::uuid;
  perform set_config('test.fail_room', 'on', true);
  begin perform fn_hk_complete_task(task, 'تم', t_ver('housekeeping_tasks', task)); exception when others then msg := sqlerrm; end;
  perform set_config('test.fail_room', 'off', true);
  select status into st from housekeeping_tasks where id = task;
  select cleanliness into cl from rooms where id = t_id('room');
  perform t_record('X08b a fault after the task update and before the cleanliness update leaves the task open and the unit as it was',
    msg like 'INJECTED_FAULT%' and st <> 'completed' and cl <> 'clean', msg || ' / ' || st || ' / ' || cl);
  perform fn_hk_complete_task(task, 'تم', t_ver('housekeeping_tasks', task));
  select status into st from housekeeping_tasks where id = task;
  select cleanliness into cl from rooms where id = t_id('room');
  perform t_record('X08b2 the retry completes the task and cleans the unit', st = 'completed' and cl = 'clean', st || ' / ' || cl);
exception when others then perform t_record('X08b a fault after the task update and before the cleanliness update leaves the task open and the unit as it was', false, sqlerrm); end $$;
reset role;

select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),140) as detail from test_results order by ok nulls first, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from test_results where ok is not true) then raise exception 'AUDIT TRACE TESTS FAILED'; end if;
  if (select count(*) from test_results) < 18 then raise exception 'AUDIT TRACE TESTS INCOMPLETE: % of 18 checks ran', (select count(*) from test_results); end if;
end $$;
