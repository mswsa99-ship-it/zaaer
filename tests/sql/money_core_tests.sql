-- =====================================================================
-- Core money (Phase 1, migration 0028).
-- MC01–MC15: the four payment methods, cash boxes and bank accounts, transaction numbers, the daily card-terminal
-- settlement, the monthly platform payout matching, tax zero owned by the owner, the 50 SAR deposit default, a deposit
-- that never goes through the platform.
-- F09a–F09e: zero, negative, fractional or non-numeric halalas are refused for every kind of voucher (decision 47).
-- A04 / A08: a unit type with old reservations keeps their prices; a service on a charge line is archived, not removed.
-- Runs after core_tests.sql on the same database (uses its synthetic organisation, branches and staff).
-- =====================================================================
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create temp table ids(k text primary key, v uuid);
grant all on ids to public;
create temp table nums(k text primary key, v bigint);
grant all on nums to public;
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
create or replace function t_ver(p_table text, p_id uuid) returns int language plpgsql security definer as $$ declare v int; begin execute format('select version from %I where id = $1', p_table) into v using p_id; return v; end $$;
create or replace function t_fin(p uuid) returns jsonb language sql security definer as $$ select fn_reservation_finance_internal(p) $$;
create or replace function t_nightly(p uuid) returns bigint language sql security definer as $$ select nightly_rate_halalas from reservations where id = p $$;
create or replace function t_voucher(p uuid) returns financial_vouchers language sql security definer as $$ select * from financial_vouchers where id = p $$;
create or replace function t_account(p_branch uuid, p_kind text) returns uuid language sql security definer as $$
  select id from cash_accounts where branch_id = p_branch and kind = p_kind and is_default and archived_at is null
$$;
-- an error is expected: true when the call failed with a message starting with p_like
create or replace function t_fails(p_sql text, p_like text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'accepted';
exception when others then
  return case when sqlerrm like p_like then 'ok' else sqlerrm end;
end $$;

-- ---------------------------------------------------------------- fixtures
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; begin
  r := fn_staff_create_reservation(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','category_id','00000000-0000-0000-0000-000000000030',
         'check_in', (current_date + 60)::text, 'check_out', (current_date + 63)::text, 'guest_phone', '0551000019', 'guest_name', 'ضيف المال', 'source_id', '00000000-0000-0000-0000-000000000021'));
  insert into ids values ('res', (r->>'id')::uuid);
  r := fn_staff_create_reservation(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','category_id','00000000-0000-0000-0000-000000000030',
         'check_in', (current_date + 64)::text, 'check_out', (current_date + 66)::text, 'guest_phone', '0551000020', 'guest_name', 'ضيف منصة', 'source_id', '00000000-0000-0000-0000-000000000020',
         'external_ref', 'BK-MC-1', 'platform_collects', false, 'platform_booked_on', current_date::text));
  insert into ids values ('resOTA1', (r->>'id')::uuid);
  r := fn_staff_create_reservation(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','category_id','00000000-0000-0000-0000-000000000030',
         'check_in', (current_date + 67)::text, 'check_out', (current_date + 69)::text, 'guest_phone', '0551000021', 'guest_name', 'ضيف منصة', 'source_id', '00000000-0000-0000-0000-000000000020',
         'external_ref', 'BK-MC-2', 'platform_collects', false, 'platform_booked_on', current_date::text));
  insert into ids values ('resOTA2', (r->>'id')::uuid);
end $$;
reset role;
insert into ids values ('cash10', t_account('00000000-0000-0000-0000-000000000010', 'cash_box'));
insert into ids values ('bank10', t_account('00000000-0000-0000-0000-000000000010', 'bank_account'));
insert into ids values ('bank12', t_account('00000000-0000-0000-0000-000000000012', 'bank_account'));

-- ---------------------------------------------------------------- MC01–MC06: methods, accounts, transaction numbers
set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
do $$ begin
  perform t_record('MC01 every branch has a default cash box and a default bank account — the seeded ones and a branch created later',
    t_id('cash10') is not null and t_id('bank10') is not null and t_id('bank12') is not null
    and t_count('select count(*) from branches b where not exists (select 1 from cash_accounts a where a.branch_id = b.id and a.kind = ''cash_box'' and a.is_default)
                 or not exists (select 1 from cash_accounts a where a.branch_id = b.id and a.kind = ''bank_account'' and a.is_default)') = 0,
    t_id('cash10')::text || ' / ' || t_id('bank10')::text || ' / ' || coalesce(t_id('bank12')::text, 'none'));
end $$;
do $$ declare a jsonb; b jsonb; c jsonb; begin
  a := fn_create_voucher(jsonb_build_object('reservation_id', t_id('res'), 'kind','receipt', 'amount_halalas', 10000, 'method','cash', 'idempotency_key','mc-02a'));
  b := fn_create_voucher(jsonb_build_object('reservation_id', t_id('res'), 'kind','receipt', 'amount_halalas', 5000, 'method','pos', 'reference','TRX-5501', 'idempotency_key','mc-02b'));
  c := fn_create_voucher(jsonb_build_object('reservation_id', t_id('resOTA1'), 'kind','receipt', 'amount_halalas', 40000, 'method','ota_deferred', 'idempotency_key','mc-02c'));
  insert into ids values ('vPos1', (b->>'voucher_id')::uuid), ('vOta1', (c->>'voucher_id')::uuid);
  perform t_record('MC02 cash goes to the default cash box, the terminal to the default bank account, the platform to none',
    (t_voucher((a->>'voucher_id')::uuid)).account_id = t_id('cash10') and (t_voucher((b->>'voucher_id')::uuid)).account_id = t_id('bank10')
    and (t_voucher((c->>'voucher_id')::uuid)).account_id is null and (t_voucher((b->>'voucher_id')::uuid)).reference = 'TRX-5501', a::text);
exception when others then perform t_record('MC02 cash goes to the default cash box, the terminal to the default bank account, the platform to none', false, sqlerrm); end $$;
do $$ declare r1 text; r2 text; r3 text; r4 text; legacy bigint; begin
  r1 := t_fails(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res'), 'kind','receipt', 'amount_halalas', 100, 'method','mada', 'reference','X-1', 'idempotency_key','mc-03a')), 'VALIDATION: method_retired%');
  r2 := t_fails(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res'), 'kind','deposit', 'amount_halalas', 100, 'method','card', 'reference','X-2', 'idempotency_key','mc-03b')), 'VALIDATION: method_retired%');
  r3 := t_fails(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res'), 'kind','receipt', 'amount_halalas', 100, 'method','booking_platform', 'idempotency_key','mc-03c')), 'VALIDATION: method_retired%');
  r4 := t_fails(format('select fn_refund(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res'), 'kind','refund', 'amount_halalas', 100, 'method','payment_link', 'reference','X-4', 'reason','x', 'idempotency_key','mc-03d')), 'VALIDATION: method_retired%');
  -- an old voucher keeps its method and still counts
  legacy := t_count('select count(*) from financial_vouchers where method in (''mada'', ''card'', ''booking_platform'') and status = ''approved''');
  perform t_record('MC03 the retired methods are refused for new vouchers; vouchers that already used them keep them',
    r1 = 'ok' and r2 = 'ok' and r3 = 'ok' and r4 = 'ok' and legacy >= 0, r1 || ' / ' || r2 || ' / ' || r3 || ' / ' || r4);
end $$;
do $$ declare r1 text; r2 text; r3 text; ok jsonb; begin
  r1 := t_fails(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res'), 'kind','receipt', 'amount_halalas', 100, 'method','pos', 'idempotency_key','mc-04a')), 'VALIDATION: reference_required%');
  r2 := t_fails(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res'), 'kind','receipt', 'amount_halalas', 100, 'method','bank_transfer', 'reference','  ', 'idempotency_key','mc-04b')), 'VALIDATION: reference_required%');
  r3 := t_fails(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res'), 'kind','receipt', 'amount_halalas', 100, 'method','bank_transfer', 'reference','X', 'idempotency_key','mc-04c')), 'VALIDATION: reference%');
  ok := fn_create_voucher(jsonb_build_object('reservation_id', t_id('res'), 'kind','receipt', 'amount_halalas', 2500, 'method','bank_transfer', 'reference','TR-778899', 'idempotency_key','mc-04d'));
  perform t_record('MC04 the terminal and the transfer need their transaction number; a transfer counts at once with it',
    r1 = 'ok' and r2 = 'ok' and r3 = 'ok' and (ok->>'ok')::boolean and (t_voucher((ok->>'voucher_id')::uuid)).status = 'approved'
    and (t_voucher((ok->>'voucher_id')::uuid)).account_id = t_id('bank10'), r1 || ' / ' || r2 || ' / ' || r3);
exception when others then perform t_record('MC04 the terminal and the transfer need their transaction number; a transfer counts at once with it', false, sqlerrm); end $$;
do $$ declare r1 text; r2 text; r3 text; begin
  r1 := t_fails(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res'), 'kind','receipt', 'amount_halalas', 100, 'method','cash', 'account_id', t_id('bank10'), 'idempotency_key','mc-05a')), 'VALIDATION: account_kind%');
  r2 := t_fails(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res'), 'kind','receipt', 'amount_halalas', 100, 'method','pos', 'reference','T-555', 'account_id', t_id('bank12'), 'idempotency_key','mc-05b')), 'BRANCH_MISMATCH%');
  r3 := t_fails(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id', t_id('resOTA1'), 'kind','receipt', 'amount_halalas', 100, 'method','ota_deferred', 'account_id', t_id('bank10'), 'idempotency_key','mc-05c')), 'VALIDATION: account_not_allowed%');
  perform t_record('MC05 cash never lands in a bank account, an account of another branch is refused, the platform takes no account',
    r1 = 'ok' and r2 = 'ok' and r3 = 'ok', r1 || ' / ' || r2 || ' / ' || r3);
end $$;
do $$ declare r1 text; r2 text; begin
  r1 := t_fails(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id', t_id('resOTA1'), 'kind','deposit', 'amount_halalas', 5000, 'method','ota_deferred', 'idempotency_key','mc-15a')), 'VALIDATION: deposit_method%');
  r2 := t_fails(format('select fn_refund(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res'), 'kind','deposit_refund', 'amount_halalas', 100, 'method','ota_deferred', 'reason','x', 'idempotency_key','mc-15b')), 'VALIDATION: deposit_method%');
  perform t_record('MC15 the deposit is taken and returned at the property, never through the platform', r1 = 'ok' and r2 = 'ok', r1 || ' / ' || r2);
end $$;
do $$ declare r1 text; res jsonb; r2 text; begin
  perform fn_admin_archive_cash_account(t_id('cash10'), true, 'اختبار: بلا صندوق افتراضي');
  r1 := t_fails(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res'), 'kind','receipt', 'amount_halalas', 100, 'method','cash', 'idempotency_key','mc-06a')), 'VALIDATION: account_required%');
  r2 := t_fails(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res'), 'kind','receipt', 'amount_halalas', 100, 'method','cash', 'account_id', t_id('cash10'), 'idempotency_key','mc-06b')), 'VALIDATION: account_archived%');
  res := fn_admin_archive_cash_account(t_id('cash10'), false, 'إعادة');
  perform fn_admin_upsert_cash_account(jsonb_build_object('id', t_id('cash10'), 'name', 'الصندوق الرئيسي', 'is_default', true, 'version', t_ver('cash_accounts', t_id('cash10'))));
  perform t_record('MC06 with no default and no account a cash receipt is refused with a clear reason; an archived box is refused; restoring brings it back',
    r1 = 'ok' and r2 = 'ok' and (res->>'ok')::boolean and t_account('00000000-0000-0000-0000-000000000010', 'cash_box') = t_id('cash10'), r1 || ' / ' || r2);
exception when others then perform t_record('MC06 with no default and no account a cash receipt is refused with a clear reason; an archived box is refused; restoring brings it back', false, sqlerrm); end $$;
reset role;

-- ---------------------------------------------------------------- MC07–MC09: who manages accounts; archive keeps history; refunds
set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
do $$ declare r1 text; begin
  r1 := t_fails(format('select fn_admin_upsert_cash_account(%L::jsonb)', jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010', 'kind','cash_box', 'name','صندوق المشرف')), 'FORBIDDEN%');
  perform t_record('MC07a a supervisor cannot define cash boxes or bank accounts', r1 = 'ok', r1);
end $$;
select t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
do $$ declare a jsonb; b jsonb; dup text; v_id uuid; begin
  a := fn_admin_upsert_cash_account(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010', 'kind','bank_account', 'name','حساب الراجحي', 'bank_name','مصرف اختبار', 'account_last4','1234', 'is_default', true));
  v_id := (a->>'id')::uuid; insert into ids values ('bank10b', v_id);
  dup := t_fails(format('select fn_admin_upsert_cash_account(%L::jsonb)', jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010', 'kind','cash_box', 'name','حساب الراجحي')), 'DUPLICATE%');
  b := fn_create_voucher(jsonb_build_object('reservation_id', t_id('res'), 'kind','deposit', 'amount_halalas', 5000, 'method','pos', 'reference','TRX-7001', 'idempotency_key','mc-07b'));
  perform fn_admin_upsert_cash_account(jsonb_build_object('id', v_id, 'name', 'حساب الراجحي — الفرع', 'is_default', true, 'version', t_ver('cash_accounts', v_id), 'bank_name','مصرف اختبار', 'account_last4','1234'));
  perform t_record('MC07b a manager adds an account and makes it the default; the old default steps down; a duplicate name is refused; renaming keeps the voucher on it',
    t_account('00000000-0000-0000-0000-000000000010', 'bank_account') = v_id
    and (select is_default from cash_accounts where id = t_id('bank10')) = false and dup = 'ok'
    and (t_voucher((b->>'voucher_id')::uuid)).account_id = v_id
    and (select name from cash_accounts where id = v_id) = 'حساب الراجحي — الفرع', dup);
exception when others then perform t_record('MC07b a manager adds an account and makes it the default; the old default steps down; a duplicate name is refused; renaming keeps the voucher on it', false, sqlerrm); end $$;
do $$ declare r jsonb; used bigint; refused text; begin
  r := fn_admin_archive_cash_account(t_id('bank10b'), true, 'أُغلق الحساب');
  used := t_count(format('select count(*) from financial_vouchers where account_id = %L', t_id('bank10b')));
  refused := t_fails(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res'), 'kind','receipt', 'amount_halalas', 100, 'method','pos', 'reference','TRX-7002', 'account_id', t_id('bank10b'), 'idempotency_key','mc-08a')), 'VALIDATION: account_archived%');
  perform t_record('MC08 a used account is archived with its reason, keeps its vouchers, is no longer offered, and the change is audited',
    (r->>'used_by_vouchers')::int >= 1 and used >= 1 and refused = 'ok' and (r->>'default_missing')::boolean
    and (select archived_at is not null from cash_accounts where id = t_id('bank10b'))
    and t_count(format('select count(*) from audit_events where entity_id = %L and action = ''cash_account.archived''', t_id('bank10b'))) = 1, r::text || ' / ' || refused);
  -- the first bank account becomes the default again
  perform fn_admin_upsert_cash_account(jsonb_build_object('id', t_id('bank10'), 'name', 'الحساب البنكي الرئيسي', 'is_default', true, 'version', t_ver('cash_accounts', t_id('bank10'))));
exception when others then perform t_record('MC08 a used account is archived with its reason, keeps its vouchers, is no longer offered, and the change is audited', false, sqlerrm); end $$;
do $$ declare a jsonb; b jsonb; c jsonb; r1 text; begin
  a := fn_refund(jsonb_build_object('reservation_id', t_id('res'), 'kind','refund', 'amount_halalas', 1000, 'method','cash', 'reason','رد جزء نقدًا', 'idempotency_key','mc-09a'));
  r1 := t_fails(format('select fn_refund(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res'), 'kind','deposit_refund', 'amount_halalas', 1000, 'method','bank_transfer', 'reason','رد تأمين', 'idempotency_key','mc-09b')), 'VALIDATION: reference_required%');
  b := fn_refund(jsonb_build_object('reservation_id', t_id('res'), 'kind','deposit_refund', 'amount_halalas', 1000, 'method','bank_transfer', 'reference','TR-RET-1', 'reason','رد تأمين', 'idempotency_key','mc-09c'));
  c := fn_refund(jsonb_build_object('reservation_id', t_id('res'), 'kind','deposit_apply', 'amount_halalas', 1000, 'reason','تغطية من التأمين', 'idempotency_key','mc-09d'));
  perform t_record('MC09 a refund leaves through an account too (cash box, or bank with its number); applying the deposit to the stay takes none',
    (t_voucher((a->>'voucher_id')::uuid)).account_id = t_id('cash10') and r1 = 'ok' and (t_voucher((b->>'voucher_id')::uuid)).account_id = t_id('bank10')
    and (t_voucher((c->>'voucher_id')::uuid)).account_id is null, r1);
exception when others then perform t_record('MC09 a refund leaves through an account too (cash box, or bank with its number); applying the deposit to the stay takes none', false, sqlerrm); end $$;
reset role;

-- ---------------------------------------------------------------- F09: whole, positive halalas for every kind (decision 47)
set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
do $$ declare kinds text[] := array['receipt', 'deposit', 'refund', 'deposit_refund', 'deposit_apply']; k text; bad text; out text := ''; n int := 0; fn text; i int := 0; begin
  foreach k in array kinds loop
    fn := case when k in ('receipt', 'deposit') then 'fn_create_voucher' else 'fn_refund' end;
    foreach bad in array array['0', '-100', '10.5', 'abc'] loop
      i := i + 1;
      if t_fails(format('select %s(%s)', fn, quote_literal(format('{"reservation_id":"%s","kind":"%s","amount_halalas":%s,"method":"cash","reason":"x","idempotency_key":"f09-%s"}',
                 t_id('res'), k, case when bad = 'abc' then '"abc"' else bad end, i)) || '::jsonb'), 'VALIDATION: amount%') = 'ok' then n := n + 1; else out := out || k || ':' || bad || ' '; end if;
    end loop;
  end loop;
  perform t_record('F09a–F09e zero, negative, fractional and non-numeric amounts are refused for receipts, deposits, refunds, deposit refunds and deposit use',
    n = 20, n || ' of 20 refused; accepted or other error: ' || out);
end $$;
reset role;

-- ---------------------------------------------------------------- MC10–MC11: the daily card-terminal settlement (decision 13)
set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
do $$ declare p jsonb; begin
  -- what other suites already put on this account today is the baseline; this suite adds to it
  p := fn_pos_settlement_preview('00000000-0000-0000-0000-000000000010', t_id('bank10'), fn_branch_today('00000000-0000-0000-0000-000000000010'));
  insert into nums values ('pos_total0', (p->>'system_total_halalas')::bigint), ('pos_count0', (p->>'voucher_count')::bigint);
end $$;
do $$ declare p jsonb; s jsonb; s2 jsonb; nonote text; d date := fn_branch_today('00000000-0000-0000-0000-000000000010'); refund_id uuid; begin
  -- today on the default bank account: 50.00 (MC02) + 25.00 + a refund of 10.00 by terminal
  perform fn_create_voucher(jsonb_build_object('reservation_id', t_id('res'), 'kind','receipt', 'amount_halalas', 2500, 'method','pos', 'reference','TRX-9001', 'idempotency_key','mc-10a'));
  reset role;
  perform set_config('request.jwt.claim.sub', 'a0000000-0000-0000-0000-000000000001', false);
  perform set_config('request.jwt.claims', json_build_object('sub', 'a0000000-0000-0000-0000-000000000001', 'email', 'owner@test.local')::text, false);
  set role authenticated;
  perform fn_refund(jsonb_build_object('reservation_id', t_id('res'), 'kind','refund', 'amount_halalas', 1000, 'method','pos', 'reference','TRX-9002', 'reason','رد عبر الجهاز', 'idempotency_key','mc-10b'));
  reset role;
  perform set_config('request.jwt.claim.sub', 'a0000000-0000-0000-0000-000000000002', false);
  perform set_config('request.jwt.claims', json_build_object('sub', 'a0000000-0000-0000-0000-000000000002', 'email', 'sup@test.local')::text, false);
  set role authenticated;
  p := fn_pos_settlement_preview('00000000-0000-0000-0000-000000000010', t_id('bank10'), d);
  s := fn_pos_settle(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010', 'account_id', t_id('bank10'), 'business_date', d, 'terminal_total_halalas', (p->>'system_total_halalas')::bigint));
  nonote := t_fails(format('select fn_pos_settle(%L::jsonb)', jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010', 'account_id', t_id('bank10'), 'business_date', d,
                       'terminal_total_halalas', (p->>'system_total_halalas')::bigint + 500, 'version', (s->'settlement'->>'version')::int)), 'VALIDATION: note_required%');
  s2 := fn_pos_settle(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010', 'account_id', t_id('bank10'), 'business_date', d,
                       'terminal_total_halalas', (p->>'system_total_halalas')::bigint + 500, 'note', 'عملية مكررة في الجهاز، تُراجع مع البنك', 'version', (s->'settlement'->>'version')::int));
  perform t_record('MC10 the supervisor settles the day: the terminal vouchers net (taken in − paid back) against the terminal total; equal is matched',
    (p->>'system_total_halalas')::bigint = (select v from nums where k = 'pos_total0') + 2500 - 1000
    and (p->>'voucher_count')::int = (select v from nums where k = 'pos_count0') + 2 and (select v from nums where k = 'pos_total0') >= 5000
    and s->'settlement'->>'status' = 'matched' and (s->'settlement'->>'difference_halalas')::bigint = 0, p::text);
  perform t_record('MC11 a difference must be explained, is kept with its sign for the owner''s review, and the change is audited',
    nonote = 'ok' and s2->'settlement'->>'status' = 'difference' and (s2->'settlement'->>'difference_halalas')::bigint = 500
    and t_count(format('select count(*) from audit_events where entity_id = %L and action = ''pos.settled''', (s->'settlement'->>'id')::uuid)) = 2, nonote || ' / ' || s2::text);
exception when others then perform t_record('MC10 the supervisor settles the day: the terminal vouchers net (taken in − paid back) against the terminal total; equal is matched', false, sqlerrm); end $$;
select t_login('a0000000-0000-0000-0000-000000000003', 'hk@test.local');
do $$ declare r1 text; r2 text; begin
  r1 := t_fails(format('select fn_pos_settlement_preview(%L, %L, current_date)', '00000000-0000-0000-0000-000000000010', t_id('bank10')), 'FORBIDDEN%');
  reset role;
  perform set_config('request.jwt.claim.sub', 'a0000000-0000-0000-0000-000000000001', false);
  perform set_config('request.jwt.claims', json_build_object('sub', 'a0000000-0000-0000-0000-000000000001', 'email', 'owner@test.local')::text, false);
  set role authenticated;
  r2 := t_fails(format('select fn_pos_settle(%L::jsonb)', jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010', 'account_id', t_id('bank10'),
                  'business_date', fn_branch_today('00000000-0000-0000-0000-000000000010') + 1, 'terminal_total_halalas', 0)), 'VALIDATION: business_date%');
  perform t_record('MC11b housekeeping cannot see the settlement; a day that has not come yet cannot be settled', r1 = 'ok' and r2 = 'ok', r1 || ' / ' || r2);
end $$;
reset role;

-- ---------------------------------------------------------------- MC12: the monthly platform payout matching (decision 24)
set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000004', 'fin@test.local');
do $$ declare u jsonb; c jsonb; nonote text; mixed text; after jsonb; v2 jsonb; begin
  -- a second deferred platform payment, then the platform pays both less its commission
  reset role;
  perform set_config('request.jwt.claim.sub', 'a0000000-0000-0000-0000-000000000001', false);
  perform set_config('request.jwt.claims', json_build_object('sub', 'a0000000-0000-0000-0000-000000000001', 'email', 'owner@test.local')::text, false);
  set role authenticated;
  v2 := fn_create_voucher(jsonb_build_object('reservation_id', t_id('resOTA2'), 'kind','receipt', 'amount_halalas', 30000, 'method','ota_deferred', 'idempotency_key','mc-12a'));
  insert into ids values ('vOta2', (v2->>'voucher_id')::uuid);
  reset role;
  perform set_config('request.jwt.claim.sub', 'a0000000-0000-0000-0000-000000000004', false);
  perform set_config('request.jwt.claims', json_build_object('sub', 'a0000000-0000-0000-0000-000000000004', 'email', 'fin@test.local')::text, false);
  set role authenticated;
  u := fn_platform_unsettled('00000000-0000-0000-0000-000000000010');
  mixed := t_fails(format('select fn_platform_payout_confirm(%L::jsonb)', jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010', 'source_id','00000000-0000-0000-0000-000000000021',
              'voucher_ids', jsonb_build_array(t_id('vOta1')), 'received_halalas', 40000, 'received_on', current_date, 'reference', 'PAYOUT-0')), 'VALIDATION: payout_vouchers%');
  nonote := t_fails(format('select fn_platform_payout_confirm(%L::jsonb)', jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010', 'source_id','00000000-0000-0000-0000-000000000020',
              'voucher_ids', jsonb_build_array(t_id('vOta1'), t_id('vOta2')), 'received_halalas', 63000, 'received_on', current_date, 'reference', 'PAYOUT-1')), 'VALIDATION: note_required%');
  c := fn_platform_payout_confirm(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010', 'source_id','00000000-0000-0000-0000-000000000020',
              'voucher_ids', jsonb_build_array(t_id('vOta1'), t_id('vOta2')), 'received_halalas', 63000, 'received_on', current_date, 'reference', 'PAYOUT-1',
              'note', 'عمولة المنصة 10%'));
  insert into ids values ('payout', (c->'payout'->>'id')::uuid);
  after := fn_platform_unsettled('00000000-0000-0000-0000-000000000010');
  perform t_record('MC12 finance matches the platform''s payout to its deferred payments: both listed, the wrong platform refused, the commission explained, then none left',
    jsonb_array_length(u) >= 2 and mixed = 'ok' and nonote = 'ok' and (c->'payout'->>'expected_halalas')::bigint = 70000
    and (c->'payout'->>'difference_halalas')::bigint = -7000 and (t_voucher(t_id('vOta1'))).payout_id = (c->'payout'->>'id')::uuid
    and not exists (select 1 from jsonb_array_elements(after) x where (x->>'id')::uuid in (t_id('vOta1'), t_id('vOta2'))), mixed || ' / ' || nonote || ' / ' || c::text);
exception when others then perform t_record('MC12 finance matches the platform''s payout to its deferred payments: both listed, the wrong platform refused, the commission explained, then none left', false, sqlerrm); end $$;
do $$ declare r1 text; begin
  r1 := t_fails(format('select fn_platform_payout_cancel(%L, %L)', t_id('payout'), 'خطأ'), 'FORBIDDEN%');
  reset role;
  perform set_config('request.jwt.claim.sub', 'a0000000-0000-0000-0000-000000000008', false);
  perform set_config('request.jwt.claims', json_build_object('sub', 'a0000000-0000-0000-0000-000000000008', 'email', 'mgr@test.local')::text, false);
  set role authenticated;
  perform fn_platform_payout_cancel(t_id('payout'), 'المبلغ نُسب لشهر آخر');
  perform t_record('MC12b only the owner or manager cancels a payout; the payments return to the unmatched list and the payout stays as cancelled',
    r1 = 'ok' and (t_voucher(t_id('vOta1'))).payout_id is null
    and (select status from platform_payouts where id = t_id('payout')) = 'cancelled', r1);
exception when others then perform t_record('MC12b only the owner or manager cancels a payout; the payments return to the unmatched list and the payout stays as cancelled', false, sqlerrm); end $$;
reset role;

-- ---------------------------------------------------------------- MC13–MC14: tax zero owned by the owner; the 50 SAR deposit
set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
do $$ declare r1 text; ok jsonb; begin
  r1 := t_fails(format('select fn_admin_upsert_branch(%L::jsonb)', jsonb_build_object('id','00000000-0000-0000-0000-000000000010', 'name_ar', (select name_ar from branches where id = '00000000-0000-0000-0000-000000000010'),
              'tax_rate_bp', 1500, 'version', t_ver('branches', '00000000-0000-0000-0000-000000000010'))), 'FORBIDDEN%');
  ok := fn_admin_upsert_branch(jsonb_build_object('id','00000000-0000-0000-0000-000000000010', 'name_ar', (select name_ar from branches where id = '00000000-0000-0000-0000-000000000010'),
              'phone', '+966500000099', 'tax_rate_bp', 0, 'version', t_ver('branches', '00000000-0000-0000-0000-000000000010')));
  perform t_record('MC13a the tax policy is the owner''s alone: a manager cannot change it, but saves the branch''s other settings',
    r1 = 'ok' and (ok->>'ok')::boolean and (select tax_rate_bp from branches where id = '00000000-0000-0000-0000-000000000010') = 0, r1);
exception when others then perform t_record('MC13a the tax policy is the owner''s alone: a manager cannot change it, but saves the branch''s other settings', false, sqlerrm); end $$;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
do $$ declare b jsonb; nb uuid; begin
  b := fn_admin_upsert_branch(jsonb_build_object('name_ar', 'فرع المال الجديد', 'name_en', 'Test branch'));
  nb := (b->>'id')::uuid;
  perform t_record('MC13b a new branch starts at zero tax, a 50.00 deposit, a cash box and a bank account',
    (select tax_rate_bp from branches where id = nb) = 0 and (select default_deposit_halalas from branches where id = nb) = 5000
    and t_account(nb, 'cash_box') is not null and t_account(nb, 'bank_account') is not null, b::text);
exception when others then perform t_record('MC13b a new branch starts at zero tax, a 50.00 deposit, a cash box and a bank account', false, sqlerrm); end $$;
reset role;
do $$ begin
  perform t_record('MC14 every branch the migration found is at zero tax with a 50.00 deposit default, and the change was audited',
    t_count('select count(*) from branches where id = ''00000000-0000-0000-0000-000000000010'' and default_deposit_halalas = 5000') = 1
    and (select column_default from information_schema.columns where table_name = 'branches' and column_name = 'tax_rate_bp') = '0'
    and (select column_default from information_schema.columns where table_name = 'branches' and column_name = 'default_deposit_halalas') = '5000'
    and t_count('select count(*) from audit_events where action = ''branch.money_defaults''') >= 1, '');
end $$;

-- ---------------------------------------------------------------- A04 / A08 (decision 48)
set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
do $$ declare rent_before record; rent_after record; nightly bigint; cat jsonb; begin
  select unit_price_halalas, description, total_halalas into rent_before from reservation_charges where reservation_id = t_id('res') and kind = 'rent' order by created_at limit 1;
  nightly := t_nightly(t_id('res'));
  cat := fn_admin_upsert_room_category(jsonb_build_object('id','00000000-0000-0000-0000-000000000030', 'branch_id','00000000-0000-0000-0000-000000000010',
           'name_ar', 'جناح بعد التعديل', 'base_capacity', 2, 'max_capacity', 4, 'base_price_halalas', 99900, 'version', t_ver('room_categories', '00000000-0000-0000-0000-000000000030')));
  select unit_price_halalas, description, total_halalas into rent_after from reservation_charges where reservation_id = t_id('res') and kind = 'rent' order by created_at limit 1;
  perform t_record('A04 changing a unit type that has reservations keeps their nightly price, charge lines and description',
    rent_after.unit_price_halalas = rent_before.unit_price_halalas and rent_after.description = rent_before.description and rent_after.total_halalas = rent_before.total_halalas
    and t_nightly(t_id('res')) = nightly and (cat->>'ok')::boolean, rent_before::text || ' → ' || rent_after::text);
exception when others then perform t_record('A04 changing a unit type that has reservations keeps their nightly price, charge lines and description', false, sqlerrm); end $$;
do $$ declare s jsonb; svc uuid; refused jsonb; deps jsonb; begin
  s := fn_admin_upsert_service(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010', 'name_ar', 'غسيل ملابس للاختبار', 'price_halalas', 2500, 'billing_unit', 'quantity'));
  svc := (s->>'id')::uuid;
  perform fn_staff_add_service(t_id('res'), svc, 2, null);
  refused := fn_admin_delete_definition('service', svc);
  deps := fn_definition_dependencies('service', svc);
  perform fn_admin_archive_definition('service', svc, 'لم تعد تُقدَّم', true);
  perform t_record('A08 a service on a reservation''s charge line cannot be removed: the refusal names its uses and archiving keeps the line',
    exists (select 1 from service_definitions where id = svc and archived_at is not null)
    and exists (select 1 from reservation_charges where reservation_id = t_id('res') and service_definition_id = svc)
    and refused->>'error' = 'HAS_DEPENDENCIES' and (refused->'dependencies'->>'charges')::int = 1 and (deps->>'charges')::int = 1, refused::text);
exception when others then perform t_record('A08 a service on a reservation''s charge line cannot be removed: the refusal names its uses and archiving keeps the line', false, sqlerrm); end $$;
reset role;

select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),140) as detail from test_results order by ok nulls first, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from test_results where ok is not true) then raise exception 'MONEY CORE TESTS FAILED'; end if;
  if (select count(*) from test_results) < 22 then raise exception 'MONEY CORE TESTS INCOMPLETE: % of 22 checks ran', (select count(*) from test_results); end if;
end $$;
