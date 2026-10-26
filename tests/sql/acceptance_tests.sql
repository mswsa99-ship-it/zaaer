-- =====================================================================
-- Phase 7 acceptance: the owner's decisions 37, 38, 44 and 53, tested on the server.
-- X04a–X04f  branch isolation (decision 37): another branch's lists and reports refused to a manager with every
--            permission, the log of the own branch never carries another's, roles and memberships unchangeable from
--            the browser, a membership taken away stops the very next operation of the session already open.
-- SE01–SE05  no self-escalation (decision 44): no role changes its own role or branches, by a direct write or by any
--            function, even with «دعوة موظف وتعديله» ticked; an invitation's completion keeps the invited role; the
--            owner does not change their own role from the editor.
-- PG01–PG03  G20 with manual payments (decision 38): no voucher from a guest's session or a role without the cell,
--            no «مدفوع» written from outside the server, the guest's «مدفوع» comes from the server's own state.
-- D05        a facility untouched for a month stays in the administration (decision 53): nothing is removed for
--            not being used.
-- AX01       a visitor with no account executes only the fourteen functions the guest pages call (0045).
-- Runs after permissions_tests.sql on the same database (its organisation, branches 010 and 012, staff).
-- =====================================================================
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create temp table ids(k text primary key, v uuid);
grant all on ids to public;
create or replace function t_login(p_uid uuid, p_email text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), false);
  perform set_config('request.jwt.claims', case when p_uid is null then '' else json_build_object('sub', p_uid, 'email', p_email)::text end, false);
end $$;
create or replace function t_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;
create or replace function t_id(p_k text) returns uuid language sql security definer as $$ select v from ids where k = p_k $$;
create or replace function t_set(p_k text, p_v uuid) returns void language sql security definer as $$ insert into ids values (p_k, p_v) on conflict (k) do update set v = excluded.v $$;
create or replace function t_count(p_sql text) returns bigint language plpgsql security definer as $$ declare n bigint; begin execute p_sql into n; return n; end $$;
create or replace function t_today() returns date language sql security definer as $$ select fn_branch_today('00000000-0000-0000-0000-000000000010') $$;
-- 'ok' when the statement is refused with the expected message, 'accepted' when it ran, else the other error
create or replace function t_fails(p_sql text, p_like text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'accepted';
exception when others then
  return case when sqlerrm like p_like then 'ok' else sqlerrm end;
end $$;
create or replace function t_staff(p uuid) returns staff_profiles language sql security definer as $$ select * from staff_profiles where id = p $$;
create or replace function t_branches(p uuid) returns uuid[] language sql security definer as $$
  select coalesce(array_agg(branch_id order by branch_id), '{}') from branch_memberships where staff_id = p and removed_at is null $$;
create or replace function t_res(p uuid) returns reservations language sql security definer as $$ select * from reservations where id = p $$;
-- a facility's last change moved back by p_days (as if nobody touched it since)
create or replace function t_age_facility(p uuid, p_days int) returns void language sql security definer as $$
  update facilities set created_at = now() - make_interval(days => p_days), updated_at = now() - make_interval(days => p_days) where id = p $$;
-- the owner does something, then the session returns to whoever was signed in
create or replace function t_as_owner(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; sub text := current_setting('request.jwt.claims', true);
begin
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  execute p_sql into r;
  perform set_config('request.jwt.claims', coalesce(sub, ''), false);
  perform set_config('request.jwt.claim.sub', coalesce(nullif(sub, '')::jsonb->>'sub', ''), false);
  return r;
end $$;

-- ---------------------------------------------------------------- fixtures
select t_set('cat', (select id from room_categories where branch_id = '00000000-0000-0000-0000-000000000010' and archived_at is null order by created_at limit 1));
set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
-- a booking of branch 010 with the platform number the guest looks it up by, and an action in branch 012 for the log
select t_set('res_g20', (fn_staff_create_reservation(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'),
  'check_in', t_today() + 320, 'check_out', t_today() + 322, 'guest_name', 'ضيف الاعتماد', 'guest_phone', '0500009876',
  'external_ref', 'ACC-G20-1', 'source_id', '00000000-0000-0000-0000-000000000021'))->>'id')::uuid);
select t_set('blk012', (fn_admin_upsert_block(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000012', 'name', 'مبنى عزل الفروع'))->>'id')::uuid);

-- ---------------------------------------------------------------- X04: branch isolation (decision 37)
-- the manager of branch 010 holds every permission of a manager; branch 012 is not theirs
select t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
do $$ declare b text := '''00000000-0000-0000-0000-000000000012'''; f text := quote_literal(t_today() - 30); t text := quote_literal(t_today()); res text[] := '{}'; s text; q text; begin
  foreach q in array array[
    'select fn_voucher_list(jsonb_build_object(''branch_id'', ' || b || '))',
    'select fn_reports_finance(' || b || ', ' || f || ', ' || t || ', ''{}'')',
    'select fn_reports_discounts(' || b || ', ' || f || ', ' || t || ', ''{}'')',
    'select fn_reports_identities(' || b || ', ' || f || ', ' || t || ', ''all'', ''{}'')',
    'select fn_audit_list(jsonb_build_object(''branch_id'', ' || b || '))',
    'select fn_reservation_calendar(' || b || ', ' || t || ', ' || t || ')',
    'select fn_rate_calendar(' || b || ', ' || t || ', ' || t || ')',
    'select fn_stay_followups(' || b || ')',
    'select fn_staff_day_summary(' || b || ', ' || t || ')',
    'select fn_platform_unsettled(' || b || ')',
    'select fn_keybox_board(' || b || ')'] loop
    s := t_fails(q, '%FORBIDDEN%');
    if s <> 'ok' then res := res || (left(q, 40) || ' → ' || s); end if;
  end loop;
  perform t_record('X04a another branch''s lists and reports — everything an export is made from — are refused on the server to a manager holding every manager permission',
    cardinality(res) = 0 and (fn_reservation_list('00000000-0000-0000-0000-000000000012', '{}', 1000, 0)->>'total')::int = 0, array_to_string(res, ' | '));
exception when others then perform t_record('X04a another branch''s lists and reports — everything an export is made from — are refused on the server to a manager holding every manager permission', false, sqlerrm); end $$;

do $$ declare a jsonb; n012 bigint; begin
  n012 := t_count('select count(*) from audit_events where branch_id = ''00000000-0000-0000-0000-000000000012''');
  a := fn_audit_list(jsonb_build_object('limit', 500));
  perform t_record('X04b the log the manager exports carries their own branch only: no row of branch 012, though branch 012 has rows',
    n012 > 0 and not exists (select 1 from jsonb_array_elements(a->'rows') x where x->>'branch_id' = '00000000-0000-0000-0000-000000000012'),
    n012 || ' rows in 012; ' || (a->>'total') || ' listed');
exception when others then perform t_record('X04b the log the manager exports carries their own branch only: no row of branch 012, though branch 012 has rows', false, sqlerrm); end $$;

-- the browser writes straight to the tables: the role and the memberships do not move
do $$ declare before staff_profiles; n int; s text; begin
  before := t_staff('10000000-0000-0000-0000-000000000008');
  update staff_profiles set role = 'owner' where id = '10000000-0000-0000-0000-000000000008';
  update staff_profiles set role = 'housekeeping' where id = '10000000-0000-0000-0000-000000000002';
  s := t_fails('insert into branch_memberships(staff_id, branch_id) values (''10000000-0000-0000-0000-000000000008'', ''00000000-0000-0000-0000-000000000012'')', '%');
  update branch_memberships set removed_at = now() where staff_id = '10000000-0000-0000-0000-000000000002';
  perform t_record('X04c a role or a membership written from the browser does not move: the manager stays manager of 010 only, the supervisor keeps role and branches',
    (t_staff('10000000-0000-0000-0000-000000000008')).role = 'manager' and (t_staff('10000000-0000-0000-0000-000000000002')).role = 'supervisor'
    and t_branches('10000000-0000-0000-0000-000000000008') = array['00000000-0000-0000-0000-000000000010'::uuid]
    and cardinality(t_branches('10000000-0000-0000-0000-000000000002')) = 2 and s <> 'accepted', s);
exception when others then perform t_record('X04c a role or a membership written from the browser does not move: the manager stays manager of 010 only, the supervisor keeps role and branches', false, sqlerrm); end $$;

-- the membership taken away while the manager's session is open
do $$ declare before_list int; ok_block boolean; after_list int; s text; begin
  before_list := (fn_reservation_list('00000000-0000-0000-0000-000000000010', '{}', 1000, 0)->>'total')::int;
  ok_block := (fn_admin_upsert_block(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'name', 'مبنى قبل السحب'))->>'ok')::boolean;
  perform t_as_owner('select fn_admin_update_staff(jsonb_build_object(''staff_id'', ''10000000-0000-0000-0000-000000000008'', ''branch_ids'', jsonb_build_array(''00000000-0000-0000-0000-000000000012''), ''reason'', ''نقل المدير إلى فرع B''))');
  after_list := (fn_reservation_list('00000000-0000-0000-0000-000000000010', '{}', 1000, 0)->>'total')::int;
  s := t_fails('select fn_admin_upsert_block(jsonb_build_object(''branch_id'', ''00000000-0000-0000-0000-000000000010'', ''name'', ''مبنى بعد السحب''))', '%FORBIDDEN%');
  perform t_record('X04d a membership taken away stops the next operation of the session already open: the list of 010 empties and a change in 010 is refused, with no new sign-in',
    before_list > 0 and ok_block and after_list = 0 and s = 'ok', before_list || ' → ' || after_list || '; ' || s);
exception when others then perform t_record('X04d a membership taken away stops the next operation of the session already open: the list of 010 empties and a change in 010 is refused, with no new sign-in', false, sqlerrm); end $$;

do $$ declare n int; s text; begin
  -- and the branch now theirs answers at once
  n := (fn_reservation_list('00000000-0000-0000-0000-000000000012', '{}', 1000, 0)->>'total')::int;
  s := t_fails('select fn_voucher_list(jsonb_build_object(''branch_id'', ''00000000-0000-0000-0000-000000000010''))', '%FORBIDDEN%');
  perform t_as_owner('select fn_admin_update_staff(jsonb_build_object(''staff_id'', ''10000000-0000-0000-0000-000000000008'', ''branch_ids'', jsonb_build_array(''00000000-0000-0000-0000-000000000010''), ''reason'', ''عودة المدير إلى فرعه''))');
  perform t_record('X04e after the move the old branch''s ledger is refused and the new branch answers; moved back, the manager has branch 010 alone again',
    s = 'ok' and n >= 0 and t_branches('10000000-0000-0000-0000-000000000008') = array['00000000-0000-0000-0000-000000000010'::uuid]
    and (fn_reservation_list('00000000-0000-0000-0000-000000000010', '{}', 1000, 0)->>'total')::int > 0, s);
exception when others then perform t_record('X04e after the move the old branch''s ledger is refused and the new branch answers; moved back, the manager has branch 010 alone again', false, sqlerrm); end $$;

do $$ declare s text; begin
  -- a deactivated person's open session: refused at the next call (decision 34's forced sign-out kept, A12 the arrival case)
  perform t_as_owner('select fn_admin_set_staff_active(''10000000-0000-0000-0000-000000000004'', false, ''إيقاف مؤقت للاختبار'')');
  perform t_login('a0000000-0000-0000-0000-000000000004', 'fin@test.local');
  s := t_fails('select fn_voucher_list(jsonb_build_object(''branch_id'', ''00000000-0000-0000-0000-000000000010''))', '%FORBIDDEN%');
  perform t_as_owner('select fn_admin_set_staff_active(''10000000-0000-0000-0000-000000000004'', true, ''عودة بعد الاختبار'')');
  perform t_record('X04f a person stopped while signed in is refused at their next call (the ledger here), and works again once reactivated',
    s = 'ok' and (fn_voucher_list(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010'))->>'total') is not null, s);
exception when others then perform t_record('X04f a person stopped while signed in is refused at their next call (the ledger here), and works again once reactivated', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- SE: no self-escalation (decision 44)
-- «دعوة موظف وتعديله» ticked for every other role: the editor is theirs, their own role and branches are not
select t_as_owner('select fn_admin_set_permissions(''{"reason": "اختبار التصعيد الذاتي", "changes": [{"code": "staff.manage", "role": "manager", "allowed": true}, {"code": "staff.manage", "role": "supervisor", "allowed": true}, {"code": "staff.manage", "role": "finance", "allowed": true}, {"code": "staff.manage", "role": "housekeeping", "allowed": true}]}''::jsonb)');

do $$ declare who record; bad text[] := '{}'; s1 text; s2 text; s3 text; before_b uuid[]; begin
  for who in select * from (values ('a0000000-0000-0000-0000-000000000002'::uuid, 'sup@test.local', '10000000-0000-0000-0000-000000000002'::uuid, 'supervisor'),
                                   ('a0000000-0000-0000-0000-000000000008'::uuid, 'mgr@test.local', '10000000-0000-0000-0000-000000000008'::uuid, 'manager'),
                                   ('a0000000-0000-0000-0000-000000000004'::uuid, 'fin@test.local', '10000000-0000-0000-0000-000000000004'::uuid, 'finance'),
                                   ('a0000000-0000-0000-0000-000000000003'::uuid, 'hk@test.local', '10000000-0000-0000-0000-000000000003'::uuid, 'housekeeping')) v(uid, email, sid, role) loop
    perform t_login(who.uid, who.email);
    before_b := t_branches(who.sid);
    -- another role than one's own (for the manager, any other: the only one above is the owner's, tried next)
    s1 := t_fails(format('select fn_admin_update_staff(jsonb_build_object(''staff_id'', %L, ''role'', %L, ''reason'', ''ترقية نفسي''))', who.sid,
                         case when who.role = 'manager' then 'supervisor' else 'manager' end), '%SELF_ROLE_OR_BRANCHES%');
    s2 := t_fails(format('select fn_admin_update_staff(jsonb_build_object(''staff_id'', %L, ''role'', ''owner'', ''reason'', ''ترقية نفسي''))', who.sid), '%FORBIDDEN%');
    s3 := t_fails(format('select fn_admin_update_staff(jsonb_build_object(''staff_id'', %L, ''branch_ids'', jsonb_build_array(''00000000-0000-0000-0000-000000000010'', ''00000000-0000-0000-0000-000000000012''), ''reason'', ''فروع أكثر''))', who.sid), '%SELF_ROLE_OR_BRANCHES%');
    if s1 <> 'ok' or s2 <> 'ok' or s3 <> 'ok'
       or (t_staff(who.sid)).role::text <> who.role or t_branches(who.sid) <> before_b then
      bad := bad || (who.role || ': ' || s1 || ' / ' || s2 || ' / ' || s3);
    end if;
  end loop;
  perform t_record('SE01 with «دعوة موظف وتعديله» ticked, the supervisor, the manager, finance and housekeeping each cannot change their own role (to manager or to owner) or their own branches',
    cardinality(bad) = 0, array_to_string(bad, ' | '));
exception when others then perform t_record('SE01 with «دعوة موظف وتعديله» ticked, the supervisor, the manager, finance and housekeeping each cannot change their own role (to manager or to owner) or their own branches', false, sqlerrm); end $$;

do $$ declare s text; n int; begin
  -- the supervisor invites a profile with their own address as manager: the session stays a supervisor's
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  s := t_fails('select fn_staff_invite(''sup@test.local'', ''المشرف مرة أخرى'', ''manager'', array[''00000000-0000-0000-0000-000000000010''::uuid])', '%');
  perform fn_claim_staff_profile('المشرف');
  n := t_count('select count(*) from staff_profiles where auth_user_id = ''a0000000-0000-0000-0000-000000000002''');
  perform t_record('SE02 an invitation to one''s own address in a higher role changes nothing: the session keeps its supervisor profile alone, and the claim does not pick up the invitation',
    n = 1 and (t_staff('10000000-0000-0000-0000-000000000002')).role = 'supervisor' and fn_my_permissions()->>'role' = 'supervisor'
    and not (fn_my_permissions()->'allowed' ? 'admin.permissions'), s || ', ' || n || ' profiles');
exception when others then perform t_record('SE02 an invitation to one''s own address in a higher role changes nothing: the session keeps its supervisor profile alone, and the claim does not pick up the invitation', false, sqlerrm); end $$;

do $$ declare r jsonb; begin
  -- the invited person completes the invitation: the role is the one invited with, whatever the sign-up sends
  perform t_login('a0000000-0000-0000-0000-0000000000c1', 'at-invite@test.local');
  perform set_config('request.jwt.claims', json_build_object('sub', 'a0000000-0000-0000-0000-0000000000c1', 'email', 'at-invite@test.local',
                                                             'user_metadata', json_build_object('role', 'owner'), 'role', 'owner')::text, false);
  r := fn_claim_staff_profile('مدعو جديد');
  perform t_record('SE03 completing an invitation keeps the invited role: a sign-up that sends «owner» in its claims is still the supervisor it was invited as',
    (r->>'claimed')::boolean and r->>'role' = 'supervisor' and fn_my_permissions()->>'role' = 'supervisor', r::text);
exception when others then perform t_record('SE03 completing an invitation keeps the invited role: a sign-up that sends «owner» in its claims is still the supervisor it was invited as', false, sqlerrm); end $$;

do $$ declare s text; begin
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  s := t_fails('select fn_admin_update_staff(jsonb_build_object(''staff_id'', ''10000000-0000-0000-0000-000000000001'', ''role'', ''manager'', ''reason'', ''تغيير دوري''))', '%SELF_ROLE_OR_BRANCHES%');
  perform t_record('SE04 the owner does not change their own role from the staff editor', s = 'ok' and (t_staff('10000000-0000-0000-0000-000000000001')).role = 'owner', s);
exception when others then perform t_record('SE04 the owner does not change their own role from the staff editor', false, sqlerrm); end $$;

do $$ declare bad text[] := '{}'; who record; s text; begin
  -- the matrix itself: no one but the owner reads or writes it, whatever else they hold (a supervisor with the staff editor here)
  for who in select * from (values ('a0000000-0000-0000-0000-000000000002'::uuid, 'sup@test.local'), ('a0000000-0000-0000-0000-000000000008'::uuid, 'mgr@test.local')) v(uid, email) loop
    perform t_login(who.uid, who.email);
    s := t_fails('select fn_admin_set_permissions(''{"reason": "لنفسي", "changes": [{"code": "res.create", "role": "supervisor", "allowed": true}]}''::jsonb)', '%FORBIDDEN%');
    if s <> 'ok' then bad := bad || (who.email || ': ' || s); end if;
    s := t_fails('insert into role_permissions(organization_id, capability, role, allowed) values (''00000000-0000-0000-0000-000000000001'', ''admin.permissions'', ''manager'', true)', '%');
    if s = 'accepted' then bad := bad || (who.email || ': direct insert accepted'); end if;
  end loop;
  perform t_record('SE05 no role gives itself a cell: the matrix function refuses everyone but the owner, and its table refuses a direct write',
    cardinality(bad) = 0 and t_count('select count(*) from role_permissions where capability = ''admin.permissions''') = 0, array_to_string(bad, ' | '));
exception when others then perform t_record('SE05 no role gives itself a cell: the matrix function refuses everyone but the owner, and its table refuses a direct write', false, sqlerrm); end $$;

select t_as_owner('select fn_admin_reset_permissions(''عودة إلى المعتمدة بعد اختبار التصعيد'')');

-- ---------------------------------------------------------------- PG: G20 with manual payments (decision 38)
-- a visitor with no account (the guest's browser): no voucher, no payment, no «مدفوع» written
reset role;
set role anon;
select t_login(null, null);
do $$ declare bad text[] := '{}'; s text; q text; rid text := quote_literal(t_id('res_g20')); before reservations; begin
  before := t_res(t_id('res_g20'));
  foreach q in array array[
    'select fn_create_voucher(jsonb_build_object(''reservation_id'', ' || rid || ', ''kind'', ''receipt'', ''amount_halalas'', 100, ''method'', ''cash'', ''idempotency_key'', ''g20-anon''))',
    'select fn_staff_confirm_payment(' || rid || ', ''bank_transfer'', 100, ''TRX-1'', ''g20-anon-2'')',
    'select fn_refund(jsonb_build_object(''reservation_id'', ' || rid || ', ''kind'', ''refund'', ''amount_halalas'', 1, ''method'', ''cash'', ''reason'', ''x'', ''idempotency_key'', ''g20-anon-3''))',
    'insert into financial_vouchers(organization_id, branch_id, reservation_id, number, kind, amount_halalas, method, idempotency_key, content_hash) values (''00000000-0000-0000-0000-000000000001'', ''00000000-0000-0000-0000-000000000010'', ' || rid || ', ''X'', ''receipt'', 1, ''cash'', ''g20-anon-4'', ''h'')',
    'insert into payment_transactions(reservation_id, method, amount_halalas, status, idempotency_key) values (' || rid || ', ''cash'', 1, ''paid'', ''g20-anon-5'')'] loop
    s := t_fails(q, '%');
    if s = 'accepted' then bad := bad || left(q, 50); end if;
  end loop;
  s := t_fails(format('update reservations set payment_status = ''paid'', paid_halalas = total_halalas where id = %L', t_id('res_g20')), '%');
  perform t_record('PG01 a visitor''s browser cannot issue a voucher, record a payment or refund, or write «مدفوع» on a booking',
    cardinality(bad) = 0 and (t_res(t_id('res_g20'))).payment_status = before.payment_status and (t_res(t_id('res_g20'))).paid_halalas = before.paid_halalas
    and t_count(format('select count(*) from financial_vouchers where reservation_id = %L', t_id('res_g20'))) = 0, array_to_string(bad, ' | '));
exception when others then perform t_record('PG01 a visitor''s browser cannot issue a voucher, record a payment or refund, or write «مدفوع» on a booking', false, sqlerrm); end $$;

-- the guest's own session (looked up by platform number and phone): it reads the status, it never sets it
do $$ declare r jsonb; tok text; s jsonb; before reservations; begin
  r := fn_guest_lookup('ACC-G20-1', '9876', null, 'fp-g20');
  tok := r->>'token';
  s := fn_guest_session(tok);
  before := t_res(t_id('res_g20'));
  perform set_config('t.tok_g20', tok, false);
  perform t_record('PG02 the guest''s session shows the server''s state: unpaid before any voucher (not «مدفوع», first night not paid)',
    r->>'status' = 'ok' and s->'reservation'->>'payment_status' = before.payment_status::text and before.payment_status::text <> 'paid'
    and not (s->'reservation'->>'first_night_paid')::boolean and (s->'reservation'->>'paid_halalas')::bigint = 0, (s->'reservation')::text);
exception when others then perform t_record('PG02 the guest''s session shows the server''s state: unpaid before any voucher (not «مدفوع», first night not paid)', false, sqlerrm); end $$;

-- a role without the cell, signed in: housekeeping holds no money cell
reset role;
set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000003', 'hk@test.local');
do $$ declare s1 text; s2 text; begin
  s1 := t_fails(format('select fn_create_voucher(jsonb_build_object(''reservation_id'', %L, ''kind'', ''receipt'', ''amount_halalas'', 100, ''method'', ''cash'', ''idempotency_key'', ''g20-hk''))', t_id('res_g20')), '%FORBIDDEN%');
  s2 := t_fails(format('select fn_staff_confirm_payment(%L, ''bank_transfer'', 100, ''TRX-2'', ''g20-hk-2'')', t_id('res_g20')), '%FORBIDDEN%');
  perform t_record('PG03a housekeeping, signed in to the same branch, cannot issue a voucher or confirm a payment', s1 = 'ok' and s2 = 'ok', s1 || ' / ' || s2);
exception when others then perform t_record('PG03a housekeeping, signed in to the same branch, cannot issue a voucher or confirm a payment', false, sqlerrm); end $$;

-- the supervisor records the transfer the guest made: the guest sees «مدفوع» only now, from the server
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
do $$ declare total bigint; v jsonb; s jsonb; begin
  total := (t_res(t_id('res_g20'))).total_halalas;
  v := fn_staff_confirm_payment(t_id('res_g20'), 'bank_transfer', total, 'TRX-G20-1', 'g20-sup-1');
  reset role; set role anon; perform t_login(null, null);
  s := fn_guest_session(current_setting('t.tok_g20'));
  reset role; set role authenticated; perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  perform t_record('PG03 once the supervisor records the payment on the server, the guest''s session shows «مدفوع» with the amount the voucher holds',
    (v->>'ok')::boolean and v->>'voucher' is not null and s->'reservation'->>'payment_status' = 'paid'
    and (s->'reservation'->>'paid_halalas')::bigint = total and (s->'reservation'->>'first_night_paid')::boolean, (s->'reservation')::text);
exception when others then perform t_record('PG03 once the supervisor records the payment on the server, the guest''s session shows «مدفوع» with the amount the voucher holds', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- D05: untouched is not unused (decision 53)
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
do $$ declare fid uuid; n_before bigint; u jsonb; row jsonb; f record; begin
  fid := (fn_admin_upsert_facility(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'name', 'المصلى — لم يُعدَّل منذ شهر')) ->>'id')::uuid;
  perform t_age_facility(fid, 40);
  n_before := t_count(format('select count(*) from audit_events where entity_id = %L', fid));
  perform fn_monitors_if_due('00000000-0000-0000-0000-000000000010');
  u := fn_reports_capability_usage('{"weeks": 4}');
  select x into row from jsonb_array_elements(u->'rows') x where x->>'code' = 'admin.facilities';
  select id, is_active, archived_at, updated_at into f from facilities where id = fid;
  perform t_record('D05 a facility nobody changed for 40 days stays in the administration: still listed, active, not archived; the checks and the usage report touch nothing',
    f.id is not null and f.is_active and f.archived_at is null and f.updated_at < now() - interval '30 days'
    and t_count(format('select count(*) from audit_events where entity_id = %L', fid)) = n_before
    and row is not null and row->>'status' <> 'removed', coalesce(row->>'status', 'no row'));
exception when others then perform t_record('D05 a facility nobody changed for 40 days stays in the administration: still listed, active, not archived; the checks and the usage report touch nothing', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- AX: what a visitor with no account can call (0045)
reset role;
do $$ declare guest text[] := array['fn_guest_lookup', 'fn_guest_phone_verify', 'fn_guest_phone_verify_ref', 'fn_guest_phone_reservations',
                        'fn_guest_phone_open', 'fn_guest_session', 'fn_guest_submit', 'fn_guest_submit_checkin', 'fn_guest_access_code',
                        'fn_guest_stay_summary', 'fn_guest_acknowledge', 'fn_public_branch', 'fn_branch_media', 'fn_public_whatsapp'];
  extra text[]; missing text[]; s text; begin
  select coalesce(array_agg(p.proname order by p.proname), '{}') into extra from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname !~ '^t_' and not (p.proname = any(guest))
     and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
     and has_function_privilege('anon', p.oid, 'execute');
  select coalesce(array_agg(g), '{}') into missing from unnest(guest) g
   where not exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = g and has_function_privilege('anon', p.oid, 'execute'));
  set local role anon;
  s := t_fails('select fn_staff_check_in(''{}''::jsonb)', '%permission denied%');
  reset role;
  perform t_record('AX01 a visitor with no account executes the fourteen functions the guest pages call and nothing else: a staff function is refused before it runs',
    cardinality(extra) = 0 and cardinality(missing) = 0 and s = 'ok', 'extra ' || extra::text || ' missing ' || missing::text || ' / ' || s);
exception when others then perform t_record('AX01 a visitor with no account executes the fourteen functions the guest pages call and nothing else: a staff function is refused before it runs', false, sqlerrm); end $$;

-- =====================================================================
-- RESULTS
-- =====================================================================
reset role;
select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),150) as detail from test_results order by ok, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if (select count(*) from test_results) < 17 then raise exception 'ACCEPTANCE TESTS INCOMPLETE: % of 17 checks ran', (select count(*) from test_results); end if;
  if exists (select 1 from test_results where ok is not true) then raise exception 'ACCEPTANCE TESTS FAILED'; end if;
end $$;
