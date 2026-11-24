-- =====================================================================
-- Release proof 4.13 (مصفوفة الأدوار المالية) — synthetic end-to-end role scenarios. Beyond the capability probes
-- of tests/sql/finance_role_matrix_tests.sql: each role EXECUTES its allowed operations with valid data (they must
-- succeed, not merely pass the capability check) and is refused on the forbidden ones. Plus the owner's phase-4
-- acceptance attempts by a supervisor: arrival without payment, a 99,999 receipt, a 999,999 expense.
-- Runs AFTER tests/release-proof/phase4_anomaly_six_rules_tests.sql on the same database (its RP- rooms/category).
-- The live role-by-role run waits for permission: acceptance/release-proof/live-role-scenarios-4.13.md.
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
create or replace function t_count(p_sql text) returns bigint language plpgsql security definer as $$ declare n bigint; begin execute p_sql into n; return n; end $$;
create or replace function t_fails(p_sql text, p_like text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'accepted';
exception when others then
  return case when sqlerrm like p_like then 'ok' else sqlerrm end;
end $$;

create or replace function t_rs_stay(p_room uuid, p_phone text, p_name text, p_offset int) returns uuid language plpgsql as $$
declare r jsonb;
begin
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_id', p_room,
         'check_in', fn_branch_today('00000000-0000-0000-0000-000000000010') + p_offset, 'check_out', fn_branch_today('00000000-0000-0000-0000-000000000010') + p_offset + 1,
         'guest_phone', p_phone, 'guest_name', p_name, 'source_id', '00000000-0000-0000-0000-000000000021'));
  return (r->>'id')::uuid;
end $$;

-- fixtures (as the owner): a 300.00/night type, three rooms, an expense category
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; begin
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'name_ar', 'نوع سيناريو الأدوار', 'base_capacity', 2, 'max_capacity', 3,
         'base_price_halalas', 30000, 'min_nightly_halalas', 10000));
  insert into ids values ('cat', (r->>'id')::uuid);
  for i in 1..3 loop
    r := fn_admin_upsert_room(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_number', 'RS-' || i));
    execute format('insert into ids values (%L, %L)', 'room' || i, r->>'id');
  end loop;
  r := fn_admin_upsert_expense_category(jsonb_build_object('name', 'مصروفات سيناريو الأدوار'));
  insert into ids values ('expcat', (r->>'id')::uuid);
end $$;

-- ---------------------------------------------------------------- المشرف: يملك القبض والمصروف والوصول
do $$ declare rid uuid; r jsonb; att jsonb; begin
  att := jsonb_build_array(jsonb_build_object('file_name', 'r.png', 'data_base64', 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='));
  rid := t_rs_stay(t_id('room1'), '0571300001', 'حجز المشرف', 500);
  insert into ids values ('res-sup', rid);
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  r := fn_create_voucher(jsonb_build_object('reservation_id', rid, 'kind', 'receipt', 'amount_halalas', 30000, 'method', 'cash', 'received_confirmed', true, 'idempotency_key', 'rs-sup-rcpt'));
  perform t_record('RS13-01 the supervisor EXECUTES a receipt (with the explicit receipt confirmation), not merely passes the capability check',
    (r->>'ok')::boolean, r::text);
  r := fn_expense_create(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('expcat'),
         'account_id', (select id from cash_accounts where branch_id = '00000000-0000-0000-0000-000000000010' and kind = 'cash_box' and is_default), 'amount_halalas', 10000, 'description', 'مصروف مشرف', 'attachments', att, 'idempotency_key', 'rs-sup-exp'));
  perform t_record('RS13-02 the supervisor EXECUTES an expense under his role limit, approved at once',
    (r->>'ok')::boolean and r->>'status' = 'approved', r::text);
exception when others then perform t_record('RS13-01/02 supervisor allowed paths', false, sqlerrm); end $$;

do $$ declare e text; begin
  e := t_fails(format('select fn_refund(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res-sup'), 'kind', 'refund', 'amount_halalas', 1000, 'reason', 'x', 'idempotency_key', 'rs-sup-rf')), 'FORBIDDEN%');
  perform t_record('RS13-03 the supervisor is refused a refund (money out is not his)',
    e = 'ok' and t_count(format('select count(*) from financial_vouchers where reservation_id = %L and kind = ''refund''', t_id('res-sup'))) = 0, e);
exception when others then perform t_record('RS13-03 supervisor refund refused', false, sqlerrm); end $$;

-- arrival without payment: the supervisor cannot check in a stay that was neither collected nor explicitly confirmed
-- (the gate answers ok:false with its reasons; it does not raise)
do $$ declare r jsonb; rid uuid; begin
  rid := t_rs_stay(t_id('room2'), '0571300002', 'وصول بلا دفع', 0);       -- arrival day is today: only the money blocks
  insert into ids values ('res-nopay', rid);
  r := fn_staff_check_in(jsonb_build_object('reservation_id', rid));
  perform t_record('RS13-04 auditor attempt 1: arrival without payment is refused for the supervisor (the stay stays reserved)',
    coalesce((r->>'ok')::boolean, false) = false
    and t_count(format('select count(*) from reservations where id = %L and actual_check_in is not null', rid)) = 0, r::text);
exception when others then perform t_record('RS13-04 arrival without payment refused', false, sqlerrm); end $$;

-- a 99,999 receipt: over the threshold it needs the reasoned advance path; without it the server refuses
do $$ declare e text; begin
  e := t_fails(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res-sup'), 'kind', 'receipt', 'amount_halalas', 9999900,
        'method', 'cash', 'received_confirmed', true, 'idempotency_key', 'rs-sup-big')), 'VALIDATION: amount_exceeds_short%');
  perform t_record('RS13-05 auditor attempt 2: the 99,999 receipt is refused without the reasoned advance path, and nothing is written',
    e = 'ok' and t_count(format('select count(*) from financial_vouchers where reservation_id = %L and amount_halalas = 9999900', t_id('res-sup'))) = 0, e);
exception when others then perform t_record('RS13-05 99,999 receipt refused', false, sqlerrm); end $$;

-- a 999,999 expense: over the supervisor's role limit it never spends at once; and over the box it is refused outright
do $$ declare e text; att jsonb; r jsonb; begin
  att := jsonb_build_array(jsonb_build_object('file_name', 'r.png', 'data_base64', 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='));
  r := fn_expense_create(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('expcat'),
         'account_id', (select id from cash_accounts where branch_id = '00000000-0000-0000-0000-000000000010' and kind = 'cash_box' and is_default), 'amount_halalas', 99999900, 'description', 'مصروف ضخم', 'attachments', att, 'idempotency_key', 'rs-sup-bigexp'));
  e := case when (r->>'pending_approval')::boolean then 'pending' else 'not-pending: ' || coalesce(r->>'status', r::text) end;
  perform t_record('RS13-06 auditor attempt 3: the 999,999 expense is refused by the box floor or held «بانتظار اعتماد» — never spent at once',
    e in ('pending') or (r is null),
    coalesce(e, 'exception'));
exception when others then
  perform t_record('RS13-06 auditor attempt 3: the 999,999 expense is refused by the box floor or held «بانتظار اعتماد» — never spent at once',
    sqlerrm like 'CASH_BOX_NEGATIVE%' or sqlerrm like 'FORBIDDEN%', sqlerrm);
end $$;

-- ---------------------------------------------------------------- المالية: يملك القبض والاسترداد والمصروف؛ لا يملك الوصول
do $$ declare r jsonb; e text; begin
  perform t_login('a0000000-0000-0000-0000-000000000004', 'fin@test.local');
  r := fn_refund(jsonb_build_object('reservation_id', t_id('res-sup'), 'kind', 'refund', 'amount_halalas', 5000, 'reason', 'تراجع عن دفعة',
        'method', 'cash', 'idempotency_key', 'rs-fin-rf'));
  perform t_record('RS13-07 finance EXECUTES a refund the supervisor was refused',
    (r->>'ok')::boolean, r::text);
  e := t_fails(format('select fn_staff_check_in(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res-sup'))), 'FORBIDDEN%');
  perform t_record('RS13-08 finance is refused the arrival (the desk is not his)',
    e = 'ok' and t_count(format('select count(*) from reservations where id = %L and actual_check_in is not null', t_id('res-sup'))) = 0, e);
exception when others then perform t_record('RS13-07/08 finance paths', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- النظافة: لا مال له
do $$ declare e1 text; e2 text; att jsonb; begin
  perform t_login('a0000000-0000-0000-0000-000000000003', 'hk@test.local');
  e1 := t_fails(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res-sup'), 'kind', 'receipt', 'amount_halalas', 1000,
        'method', 'cash', 'received_confirmed', true, 'idempotency_key', 'rs-hk-rcpt')), 'FORBIDDEN%');
  att := jsonb_build_array(jsonb_build_object('file_name', 'r.png', 'data_base64', 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='));
  e2 := t_fails(format('select fn_expense_create(%L::jsonb)', jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('expcat'),
        'account_id', (select id from cash_accounts where branch_id = '00000000-0000-0000-0000-000000000010' and kind = 'cash_box' and is_default), 'amount_halalas', 1000, 'description', 'مصروف نظافة', 'attachments', att, 'idempotency_key', 'rs-hk-exp')), 'FORBIDDEN%');
  perform t_record('RS13-09 housekeeping is refused both the receipt and the expense',
    e1 = 'ok' and e2 = 'ok', e1 || ' / ' || e2);
exception when others then perform t_record('RS13-09 housekeeping refused money', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- المالك: يملك الكل (عينة: الاسترداد على حجز المشرف)
do $$ declare r jsonb; begin
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  r := fn_refund(jsonb_build_object('reservation_id', t_id('res-sup'), 'kind', 'refund', 'amount_halalas', 1000, 'reason', 'استرداد مالك',
        'method', 'cash', 'idempotency_key', 'rs-own-rf'));
  perform t_record('RS13-10 the owner EXECUTES the same refund',
    (r->>'ok')::boolean, r::text);
exception when others then perform t_record('RS13-10 owner refund', false, sqlerrm); end $$;

-- =====================================================================
-- RESULTS
-- =====================================================================
reset role;
select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),150) as detail from test_results order by name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if (select count(*) from test_results) < 10 then raise exception 'RS13 TESTS INCOMPLETE: % of 10 checks ran', (select count(*) from test_results); end if;
  if exists (select 1 from test_results where ok is not true) then raise exception 'RS13 FINANCE ROLE SCENARIOS FAILED'; end if;
end $$;
