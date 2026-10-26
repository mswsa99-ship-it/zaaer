-- =====================================================================
-- The permissions matrix, editable by the owner (decision 71, migration 0043; decision 44 for self-escalation).
-- PM01–PM03  the catalogue is the approved matrix; with no change every role can do exactly its approved cells.
-- PM04–PM08  the owner ticks and unticks: the next request follows the matrix (operations, money, the log, discounts).
-- PM09–PM11  conditions stay with their cells; a role ticked for a conditioned operation gets the conditioned version.
-- PM12–PM14  no one but the owner touches an owner (staff editing, invitation, forced sign-out) — decision 44.
-- PM15–PM19  the guards: the owner's column, the locked row, a reason, the editor is the owner's, the audit row,
--            reset to the approved matrix, one organisation never moves another.
-- Runs after lists_reports_tests.sql on the same database (its organisation, branch 010, staff).
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
create or replace function t_set(p_k text, p_v uuid) returns void language sql security definer as $$ insert into ids values (p_k, p_v) on conflict (k) do update set v = excluded.v $$;
create or replace function t_count(p_sql text) returns bigint language plpgsql security definer as $$ declare n bigint; begin execute p_sql into n; return n; end $$;
create or replace function t_today() returns date language sql security definer as $$ select fn_branch_today('00000000-0000-0000-0000-000000000010') $$;
create or replace function t_fails(p_sql text, p_like text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'accepted';
exception when others then
  return case when sqlerrm like p_like then 'ok' else sqlerrm end;
end $$;
create or replace function t_last_perm_audit() returns audit_events language sql security definer as $$
  select * from audit_events where action in ('permissions.updated', 'permissions.reset') order by created_at desc, id desc limit 1;
$$;
create or replace function t_staff(p uuid) returns staff_profiles language sql security definer as $$ select * from staff_profiles where id = p $$;
-- a booking on a unit type of branch 010, far ahead, as the current user (no unit: a type booking)
create or replace function t_book(p_days int) returns uuid language plpgsql as $$
declare r jsonb;
begin
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'),
         'check_in', t_today() + p_days, 'check_out', t_today() + p_days + 1, 'guest_name', 'ضيف المصفوفة',
         'guest_phone', '0500006' || lpad((floor(random() * 1000))::int::text, 3, '0'), 'source_id', '00000000-0000-0000-0000-000000000021'));
  return (r->>'id')::uuid;
end $$;
-- the owner sets cells (as the owner), then the session returns to whoever was signed in
create or replace function t_set_cells(p_changes jsonb) returns jsonb language plpgsql as $$
declare r jsonb; sub text := current_setting('request.jwt.claims', true);
begin
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  r := fn_admin_set_permissions(jsonb_build_object('changes', p_changes, 'reason', 'اختبار المصفوفة'));
  perform set_config('request.jwt.claims', sub, false);
  perform set_config('request.jwt.claim.sub', coalesce(sub::jsonb->>'sub', ''), false);
  return r;
end $$;
create or replace function t_reset() returns void language plpgsql as $$
declare sub text := current_setting('request.jwt.claims', true);
begin
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  perform fn_admin_reset_permissions('عودة إلى المعتمدة بعد الاختبار');
  perform set_config('request.jwt.claims', sub, false);
  perform set_config('request.jwt.claim.sub', coalesce(sub::jsonb->>'sub', ''), false);
end $$;

-- ---------------------------------------------------------------- fixtures
select t_set('cat', (select id from room_categories where branch_id = '00000000-0000-0000-0000-000000000010' and archived_at is null order by created_at limit 1));
set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
select t_set('res_pm', t_book(310));

-- ---------------------------------------------------------------- PM01–PM03: the approved matrix, unchanged
do $$ declare n int; codes int; o int; lk text[]; begin
  select count(*), count(distinct c.code), count(*) filter (where 'owner' = any(c.default_roles)), array_agg(c.code) filter (where c.locked)
    into n, codes, o, lk from fn_permission_catalog() c;
  perform t_record('PM01 the catalogue is the approved matrix: 55 operations, unique codes, the owner allowed in every row, only «تعديل مصفوفة الصلاحيات» locked',
    n = 55 and codes = 55 and o = 55 and lk = array['admin.permissions'], n || ' rows, ' || codes || ' codes, locked ' || lk::text);
exception when others then perform t_record('PM01 the catalogue is the approved matrix: 55 operations, unique codes, the owner allowed in every row, only «تعديل مصفوفة الصلاحيات» locked', false, sqlerrm); end $$;

do $$ declare bad text := ''; r record; mine jsonb; begin
  for r in select * from (values ('a0000000-0000-0000-0000-000000000008'::uuid, 'manager'::role_code), ('a0000000-0000-0000-0000-000000000002', 'supervisor'),
                                 ('a0000000-0000-0000-0000-000000000004', 'finance'), ('a0000000-0000-0000-0000-000000000003', 'housekeeping')) v(uid, role) loop
    perform t_login(r.uid, 'x@test.local');
    mine := fn_my_permissions();
    if mine->>'role' <> r.role::text then bad := bad || r.role || ': signed in as ' || coalesce(mine->>'role', 'nobody') || '; '; continue; end if;
    if (select coalesce(array_agg(x order by x), '{}') from jsonb_array_elements_text(mine->'allowed') x)
       is distinct from (select coalesce(array_agg(code order by code), '{}') from fn_permission_catalog() where r.role = any(default_roles) and not locked) then
      bad := bad || r.role || ' differs; ';
    end if;
    if (mine->>'sees_money')::boolean is distinct from (r.role in ('manager', 'supervisor', 'finance')) then bad := bad || r.role || ' money; '; end if;
  end loop;
  perform t_record('PM02 with no change every role can do exactly its approved cells, and sees money exactly as before (manager, supervisor, finance; not housekeeping)', bad = '', bad);
exception when others then perform t_record('PM02 with no change every role can do exactly its approved cells, and sees money exactly as before (manager, supervisor, finance; not housekeeping)', false, sqlerrm); end $$;

do $$ declare m jsonb; begin
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  m := fn_permissions_matrix();
  perform t_record('PM03 the owner reads the matrix: every row with five columns, the owner''s always allowed, the defaults marked, the conditions where the approved matrix had them, nothing changed yet',
    jsonb_array_length(m->'rows') = 55 and (m->>'changed')::int = 0
    and not exists (select 1 from jsonb_array_elements(m->'rows') x where (x->'cells'->'owner'->>'allowed')::boolean is not true)
    and (select (x->'cells'->'supervisor'->>'limited')::boolean from jsonb_array_elements(m->'rows') x where x->>'code' = 'voucher.correct')
    and (select x->>'limit_note' from jsonb_array_elements(m->'rows') x where x->>'code' = 'voucher.correct') = 'سنداته خلال 24 ساعة'
    and (select (x->'cells'->'finance'->>'allowed')::boolean from jsonb_array_elements(m->'rows') x where x->>'code' = 'res.create') = false,
    'rows ' || jsonb_array_length(m->'rows') || ', changed ' || (m->>'changed'));
exception when others then perform t_record('PM03 the owner reads the matrix: every row with five columns, the owner''s always allowed, the defaults marked, the conditions where the approved matrix had them, nothing changed yet', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- PM04–PM08: the next request follows the matrix
do $$ declare a text; b text; c uuid; begin
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  c := t_book(300);
  perform t_set_cells('[{"code": "res.create", "role": "supervisor", "allowed": false}]');
  a := t_fails('select t_book(302)', 'FORBIDDEN: res.create%');
  perform t_set_cells('[{"code": "res.create", "role": "supervisor", "allowed": true}]');
  b := case when t_book(304) is not null then 'ok' else 'no id' end;
  perform t_record('PM04 the owner unticks «إنشاء حجز» for the supervisor: the supervisor''s next booking is refused; ticked again, the next one goes through',
    c is not null and a = 'ok' and b = 'ok', a || ' / ' || b);
exception when others then perform t_record('PM04 the owner unticks «إنشاء حجز» for the supervisor: the supervisor''s next booking is refused; ticked again, the next one goes through', false, sqlerrm); end $$;

do $$ declare r jsonb; v jsonb; before_money boolean; after_money boolean; seen bigint; begin
  perform t_login('a0000000-0000-0000-0000-000000000003', 'hk@test.local');
  before_money := fn_sees_money();
  perform t_set_cells('[{"code": "voucher.receipt", "role": "housekeeping", "allowed": true}]');
  after_money := fn_sees_money();
  v := fn_create_voucher(jsonb_build_object('reservation_id', t_id('res_pm'), 'kind', 'receipt', 'amount_halalas', 1000, 'method', 'cash', 'idempotency_key', 'pm05-' || gen_random_uuid()));
  seen := (select count(*) from financial_vouchers where id = (v->>'voucher_id')::uuid);
  perform t_record('PM05 ticking «سند قبض» for housekeeping: they issue a receipt on their next request, and from then on see money (the voucher reads back through the table''s own rule)',
    not before_money and after_money and (v->>'ok')::boolean and seen = 1,
    'money ' || before_money || ' → ' || after_money || ', ' || coalesce(v->>'number', v::text));
exception when others then perform t_record('PM05 ticking «سند قبض» for housekeeping: they issue a receipt on their next request, and from then on see money (the voucher reads back through the table''s own rule)', false, sqlerrm); end $$;
select t_reset();

do $$ declare n_before bigint; n_after bigint; seen_after bigint; a text; begin
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  n_before := (select count(*) from financial_vouchers);
  perform t_set_cells('[{"code": "voucher.receipt", "role": "supervisor", "allowed": false}, {"code": "deposit.refund", "role": "supervisor", "allowed": false},
                        {"code": "deposit.apply", "role": "supervisor", "allowed": false}, {"code": "voucher.correct", "role": "supervisor", "allowed": false},
                        {"code": "pos.settle", "role": "supervisor", "allowed": false}, {"code": "invoice.issue", "role": "supervisor", "allowed": false},
                        {"code": "invoice.edit", "role": "supervisor", "allowed": false}, {"code": "reports.finance", "role": "supervisor", "allowed": false}]');
  seen_after := (select count(*) from financial_vouchers);
  a := t_fails('select fn_voucher_list(jsonb_build_object(''branch_id'', ''00000000-0000-0000-0000-000000000010''))', 'FORBIDDEN: money%');
  perform t_record('PM06 every money cell unticked for the supervisor: the vouchers table shows them nothing and the ledger is refused — money follows the matrix, not the role name',
    n_before > 0 and seen_after = 0 and a = 'ok' and not fn_sees_money(), n_before || ' → ' || seen_after || ', ledger ' || a);
exception when others then perform t_record('PM06 every money cell unticked for the supervisor: the vouchers table shows them nothing and the ledger is refused — money follows the matrix, not the role name', false, sqlerrm); end $$;
select t_reset();

do $$ declare a text; rows_rls bigint; begin
  perform t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
  perform t_set_cells('[{"code": "audit.log", "role": "manager", "allowed": false}]');
  a := t_fails('select fn_audit_list(''{}''::jsonb)', 'FORBIDDEN: audit.log%');
  rows_rls := (select count(*) from audit_events);
  perform t_record('PM07 «سجل الإجراءات» unticked for the manager: the log is refused and the table itself shows them no row', a = 'ok' and rows_rls = 0, a || ', rows ' || rows_rls);
exception when others then perform t_record('PM07 «سجل الإجراءات» unticked for the manager: the log is refused and the table itself shows them no row', false, sqlerrm); end $$;
select t_reset();

do $$ declare a text; al jsonb; begin
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  perform t_set_cells('[{"code": "disc.before", "role": "supervisor", "allowed": false}]');
  a := t_fails('select fn_discount_allowance(t_id(''res_pm''))', 'FORBIDDEN: disc.before / disc.after%');
  perform t_set_cells('[{"code": "disc.before", "role": "supervisor", "allowed": true}, {"code": "disc.after", "role": "supervisor", "allowed": true}]');
  al := fn_discount_allowance(t_id('res_pm'));
  perform t_record('PM08 discounts follow their two cells: without «خصم قبل الوصول» the supervisor has no discount at all; with «خصم بعد الوصول أو فوق الحدين» ticked their allowance is unlimited, like the manager''s',
    a = 'ok' and (al->>'unlimited')::boolean, a || ' / ' || coalesce(al::text, '-'));
exception when others then perform t_record('PM08 discounts follow their two cells: without «خصم قبل الوصول» the supervisor has no discount at all; with «خصم بعد الوصول أو فوق الحدين» ticked their allowance is unlimited, like the manager''s', false, sqlerrm); end $$;
select t_reset();

-- ---------------------------------------------------------------- PM09–PM11: conditions stay with their cells
do $$ declare rep jsonb; a text; begin
  perform t_login('a0000000-0000-0000-0000-000000000003', 'hk@test.local');
  perform t_set_cells('[{"code": "reports.finance", "role": "housekeeping", "allowed": true}]');
  rep := fn_reports_discounts('00000000-0000-0000-0000-000000000010', t_today() - 30, t_today(), '{}'::jsonb);
  a := t_fails('select fn_reports_finance(''00000000-0000-0000-0000-000000000010'', null, null, ''{}''::jsonb)', 'FORBIDDEN: reports.finance (limited)%');
  perform t_record('PM09 a role ticked for a conditioned report gets the conditioned version: housekeeping reads the discounts summary (no rows) and is refused the full finance report',
    rep ? 'by_staff' and rep->'rows' = 'null'::jsonb and a = 'ok', a);
exception when others then perform t_record('PM09 a role ticked for a conditioned report gets the conditioned version: housekeeping reads the discounts summary (no rows) and is refused the full finance report', false, sqlerrm); end $$;
select t_reset();

do $$ declare v jsonb; a text; begin
  -- a receipt the supervisor did not issue: the owner's
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  v := fn_create_voucher(jsonb_build_object('reservation_id', t_id('res_pm'), 'kind', 'receipt', 'amount_halalas', 1500, 'method', 'cash', 'idempotency_key', 'pm10-' || gen_random_uuid()));
  perform t_set('v_owner', (v->>'voucher_id')::uuid);
  perform t_login('a0000000-0000-0000-0000-000000000004', 'fin@test.local');
  perform t_set_cells('[{"code": "voucher.correct", "role": "finance", "allowed": true}]');
  a := t_fails('select fn_staff_correct_voucher(jsonb_build_object(''voucher_id'', t_id(''v_owner''), ''amount_halalas'', 1400, ''reason'', ''تصحيح'', ''idempotency_key'', ''pm10-c''))', 'FORBIDDEN: a supervisor corrects only the vouchers they issued%');
  perform t_record('PM10 finance ticked for «تصحيح سند» works under its condition (their own vouchers, within 24 hours): a voucher someone else issued is refused',
    a = 'ok', a);
exception when others then perform t_record('PM10 finance ticked for «تصحيح سند» works under its condition (their own vouchers, within 24 hours): a voucher someone else issued is refused', false, sqlerrm); end $$;
select t_reset();

do $$ declare a text; b text; begin
  perform t_login('a0000000-0000-0000-0000-000000000004', 'fin@test.local');
  a := t_fails('select fn_platform_unsettled(''00000000-0000-0000-0000-000000000010'')', 'zzz');
  b := t_fails('select fn_platform_payout_cancel(gen_random_uuid(), ''سبب'')', 'FORBIDDEN: platform.payouts (limited)%');
  perform t_record('PM11 a cell''s condition holds with the approved defaults too: finance reconciles platform payouts but cannot cancel a confirmed one',
    a = 'accepted' and b = 'ok', a || ' / ' || b);
exception when others then perform t_record('PM11 a cell''s condition holds with the approved defaults too: finance reconciles platform payouts but cannot cancel a confirmed one', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- PM12–PM14: no one but the owner touches an owner (decision 44)
do $$ declare inv jsonb; a text; b text; c text; begin
  perform t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
  perform t_set_cells('[{"code": "staff.manage", "role": "manager", "allowed": true}]');
  inv := fn_staff_invite('pm12-sup@test.local', 'مشرف المصفوفة', 'supervisor', array['00000000-0000-0000-0000-000000000010'::uuid]);
  a := t_fails('select fn_staff_invite(''pm12-owner@test.local'', ''مالك ثان'', ''owner'', ''{}''::uuid[])', 'FORBIDDEN: only the owner changes an owner%');
  b := t_fails('select fn_admin_update_staff(jsonb_build_object(''staff_id'', ''10000000-0000-0000-0000-000000000001'', ''full_name'', ''اسم آخر'', ''reason'', ''سبب''))', 'FORBIDDEN: only the owner changes an owner%');
  c := t_fails('select fn_admin_update_staff(jsonb_build_object(''staff_id'', ''' || (inv->>'staff_id') || ''', ''role'', ''owner'', ''reason'', ''سبب''))', 'FORBIDDEN: only the owner changes an owner%');
  perform t_record('PM12 a manager ticked for «دعوة موظف وتعديله» invites a supervisor, but cannot invite an owner, edit the owner, or promote anyone to owner',
    (inv->>'ok')::boolean and a = 'ok' and b = 'ok' and c = 'ok', a || ' / ' || b || ' / ' || c);
  perform t_set('pm12_staff', (inv->>'staff_id')::uuid);
exception when others then perform t_record('PM12 a manager ticked for «دعوة موظف وتعديله» invites a supervisor, but cannot invite an owner, edit the owner, or promote anyone to owner', false, sqlerrm); end $$;

do $$ declare a text; r jsonb; begin
  perform t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
  a := t_fails('select fn_admin_set_staff_active(''10000000-0000-0000-0000-000000000001'', false, ''سبب'')', 'FORBIDDEN: only the owner changes an owner%');
  r := fn_admin_set_staff_active(t_id('pm12_staff'), false, 'لم يعد يعمل');
  perform t_record('PM13 the same manager cannot deactivate the owner, and deactivates the supervisor they invited',
    a = 'ok' and (r->>'ok')::boolean and not (t_staff(t_id('pm12_staff'))).is_active, a);
exception when others then perform t_record('PM13 the same manager cannot deactivate the owner, and deactivates the supervisor they invited', false, sqlerrm); end $$;
select t_reset();

do $$ declare a text; b text; r jsonb; begin
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  perform t_set_cells('[{"code": "staff.force_logout", "role": "supervisor", "allowed": true}]');
  a := t_fails('select fn_admin_force_logout(''10000000-0000-0000-0000-000000000008'', ''سبب'')', 'FORBIDDEN: a manager signs out neither an owner nor a manager%');
  b := t_fails('select fn_admin_force_logout(''10000000-0000-0000-0000-000000000001'', ''سبب'')', 'FORBIDDEN: a manager signs out neither an owner nor a manager%');
  r := fn_admin_force_logout('10000000-0000-0000-0000-000000000003', 'اختبار المصفوفة');
  perform t_record('PM14 a supervisor ticked for «خروج إجباري» works under its condition: signs out housekeeping, never a manager or the owner',
    a = 'ok' and b = 'ok' and (r->>'ok')::boolean, a || ' / ' || b);
exception when others then perform t_record('PM14 a supervisor ticked for «خروج إجباري» works under its condition: signs out housekeeping, never a manager or the owner', false, sqlerrm); end $$;
select t_reset();

-- ---------------------------------------------------------------- PM15–PM19: the guards
do $$ declare a text; b text; c text; d text; e text; begin
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  a := t_fails('select fn_admin_set_permissions(''{"reason": "سبب", "changes": [{"code": "res.create", "role": "owner", "allowed": false}]}''::jsonb)', 'VALIDATION: role%');
  b := t_fails('select fn_admin_set_permissions(''{"reason": "سبب", "changes": [{"code": "admin.permissions", "role": "manager", "allowed": true}]}''::jsonb)', 'PERMISSION_LOCKED%');
  c := t_fails('select fn_admin_set_permissions(''{"reason": " ", "changes": [{"code": "res.create", "role": "finance", "allowed": true}]}''::jsonb)', 'VALIDATION: reason%');
  d := t_fails('select fn_admin_set_permissions(''{"reason": "سبب", "changes": [{"code": "no.such", "role": "finance", "allowed": true}]}''::jsonb)', 'UNKNOWN_PERMISSION%');
  e := t_fails('select fn_admin_set_permissions(''{"reason": "سبب", "changes": [{"code": "res.create", "role": "finance", "allowed": "yes"}]}''::jsonb)', 'VALIDATION: allowed%');
  perform t_record('PM15 the owner''s column cannot be changed, «تعديل مصفوفة الصلاحيات» cannot be given, a reason is required, an unknown operation or a value that is not yes/no is refused',
    a = 'ok' and b = 'ok' and c = 'ok' and d = 'ok' and e = 'ok', a || ' / ' || b || ' / ' || c || ' / ' || d || ' / ' || e);
exception when others then perform t_record('PM15 the owner''s column cannot be changed, «تعديل مصفوفة الصلاحيات» cannot be given, a reason is required, an unknown operation or a value that is not yes/no is refused', false, sqlerrm); end $$;

do $$ declare a text; b text; c text; begin
  perform t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
  perform t_set_cells('[{"code": "staff.manage", "role": "manager", "allowed": true}, {"code": "security", "role": "manager", "allowed": true}]');
  a := t_fails('select fn_permissions_matrix()', 'FORBIDDEN: admin.permissions%');
  b := t_fails('select fn_admin_set_permissions(''{"reason": "سبب", "changes": [{"code": "res.create", "role": "finance", "allowed": true}]}''::jsonb)', 'FORBIDDEN: admin.permissions%');
  c := t_fails('select fn_admin_reset_permissions(''سبب'')', 'FORBIDDEN: admin.permissions%');
  perform t_record('PM16 the matrix is the owner''s alone: a manager with every other administration cell ticked still cannot read, change or reset it',
    a = 'ok' and b = 'ok' and c = 'ok' and not fn_can('admin.permissions'), a || ' / ' || b || ' / ' || c);
exception when others then perform t_record('PM16 the matrix is the owner''s alone: a manager with every other administration cell ticked still cannot read, change or reset it', false, sqlerrm); end $$;
select t_reset();

do $$ declare r jsonb; e audit_events; same jsonb; n_before bigint; begin
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  r := fn_admin_set_permissions('{"reason": "المالية تتابع البلاغات", "changes": [{"code": "maintenance.create", "role": "finance", "allowed": true}, {"code": "res.create", "role": "manager", "allowed": true}]}'::jsonb);
  e := t_last_perm_audit();
  n_before := t_count('select count(*) from audit_events where action like ''permissions.%''');
  same := fn_admin_set_permissions('{"reason": "لا شيء", "changes": [{"code": "maintenance.create", "role": "finance", "allowed": true}]}'::jsonb);
  perform t_record('PM17 one audit row per change set, in the security category, with each changed cell before and after and the reason; a cell already so (the manager''s booking) is not listed; nothing changed writes nothing',
    (r->>'changed')::int = 1 and e.action = 'permissions.updated' and e.category = 'security' and e.details->>'reason' = 'المالية تتابع البلاغات'
    and jsonb_array_length(e.details->'changes') = 1 and e.details->'changes'->0->>'code' = 'maintenance.create'
    and (e.details->'changes'->0->>'before')::boolean = false and (e.details->'changes'->0->>'after')::boolean = true
    and (same->>'unchanged')::boolean and t_count('select count(*) from audit_events where action like ''permissions.%''') = n_before,
    coalesce(e.action, '-') || ' ' || coalesce(e.category, '-'));
exception when others then perform t_record('PM17 one audit row per change set, in the security category, with each changed cell before and after and the reason; a cell already so (the manager''s booking) is not listed; nothing changed writes nothing', false, sqlerrm); end $$;

do $$ declare r jsonb; m jsonb; e audit_events; begin
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  r := fn_admin_reset_permissions('العودة إلى المصفوفة المعتمدة');
  m := fn_permissions_matrix();
  e := t_last_perm_audit();
  perform t_record('PM18 «استعادة المصفوفة المعتمدة» returns every cell to the approved matrix, with a reason and an audit row listing what changed back',
    (r->>'changed')::int = 1 and (m->>'changed')::int = 0 and e.action = 'permissions.reset' and jsonb_array_length(e.details->'changes') = 1
    and m->'last_change'->>'reason' = 'العودة إلى المصفوفة المعتمدة', r::text);
exception when others then perform t_record('PM18 «استعادة المصفوفة المعتمدة» returns every cell to the approved matrix, with a reason and an audit row listing what changed back', false, sqlerrm); end $$;

do $$ declare mine jsonb; begin
  perform t_login('a0000000-0000-0000-0000-000000000005', 'owner2@test.local');
  perform fn_admin_set_permissions('{"reason": "منشأة أخرى", "changes": [{"code": "res.create", "role": "supervisor", "allowed": false}]}'::jsonb);
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  mine := fn_my_permissions();
  perform t_record('PM19 one organisation''s matrix never moves another''s: the second owner unticks a cell, the first organisation''s supervisor keeps it',
    mine->'allowed' ? 'res.create', mine->>'role');
exception when others then perform t_record('PM19 one organisation''s matrix never moves another''s: the second owner unticks a cell, the first organisation''s supervisor keeps it', false, sqlerrm); end $$;

-- =====================================================================
-- RESULTS
-- =====================================================================
reset role;
select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),150) as detail from test_results order by ok, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if (select count(*) from test_results) < 19 then raise exception 'PERMISSIONS TESTS INCOMPLETE: % of 19 checks ran', (select count(*) from test_results); end if;
  if exists (select 1 from test_results where ok is not true) then raise exception 'PERMISSIONS TESTS FAILED'; end if;
end $$;
