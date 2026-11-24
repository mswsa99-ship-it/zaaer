create or replace function t_today(p uuid) returns date language sql security definer as $$ select fn_branch_today(p) $$;  -- 0127: authenticated cannot call fn_branch_today directly
-- =====================================================================
-- Release proof 4.6 (M6 رصد الشذوذ): the six anomaly rules, each with a case that fires (review item + immediate
-- owner-side alert) and a case that does not, plus the imported-negative-cash path the acceptance text names.
-- Runs on the shared synthetic database AFTER tests/sql/phase4_money_controls_tests.sql (organisation 00..01,
-- branch 010, source 00..21, owner a0000000-...-001; discount threshold 2000 bp already set by that file).
-- Invented data only (RP- markers). No production or staging database is touched.
-- Expected state at commit 1325919: every check passes EXCEPT RP46-14 (the imported negative opening balance opens
-- no «صندوق سالب» item and sends no alert today). That red row is the acceptance gap for 4.6: rule 1's detection
-- does not cover the import path, so the item stays OPEN until product code flags it.
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
create or replace function t_rp_stay(p_room uuid, p_phone text, p_name text, p_offset int default 410) returns uuid language plpgsql as $$
declare r jsonb;
begin
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_id', p_room,
         'check_in', t_today('00000000-0000-0000-0000-000000000010') + p_offset, 'check_out', t_today('00000000-0000-0000-0000-000000000010') + p_offset + 2,
         'guest_phone', p_phone, 'guest_name', p_name, 'source_id', '00000000-0000-0000-0000-000000000021'));
  return (r->>'id')::uuid;
end $$;
-- one open review item of the kind for the thing
create or replace function t_flags(p_kind text, p_entity_type text, p_entity uuid) returns bigint language sql security definer as $$
  select count(*) from review_items where kind = p_kind and entity_type = p_entity_type and entity_id = p_entity and reviewed_at is null
$$;
-- immediate alerts created at or after a mark (fn_phase4_flag alerts the branch's managers at once)
create or replace function t_alerts(p_branch uuid, p_mark timestamptz) returns bigint language sql security definer as $$
  select count(*) from notifications where branch_id = p_branch and audience = 'manager' and title like 'شذوذ مالي:%' and created_at >= p_mark
$$;

-- ---------------------------------------------------------------- fixtures: a 300.00/night type, four rooms, an expense category, a second branch with an empty box
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; begin
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'name_ar', 'نوع إثبات الشذوذ', 'base_capacity', 2, 'max_capacity', 3,
         'base_price_halalas', 30000, 'min_nightly_halalas', 10000));
  insert into ids values ('cat', (r->>'id')::uuid);
  for i in 1..4 loop
    r := fn_admin_upsert_room(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_number', 'RP-' || i));
    execute format('insert into ids values (%L, %L)', 'room' || i, r->>'id');
  end loop;
  r := fn_admin_upsert_expense_category(jsonb_build_object('name', 'مصروفات إثبات الشذوذ'));
  insert into ids values ('expcat', (r->>'id')::uuid);
  r := fn_admin_upsert_branch(jsonb_build_object('name_ar', 'فرع إثبات الاستيراد', 'name_en', 'RP import branch'));
  insert into ids values ('branch2', (r->>'id')::uuid);
  insert into ids values ('box2', (select id from cash_accounts where branch_id = (r->>'id')::uuid and kind = 'cash_box' and is_default));
  insert into ids values ('box1', (select id from cash_accounts where branch_id = '00000000-0000-0000-0000-000000000010' and kind = 'cash_box' and is_default));
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', (r->>'id')::uuid, 'name_ar', 'نوع إثبات السالب', 'base_capacity', 2, 'max_capacity', 3,
         'base_price_halalas', 30000, 'min_nightly_halalas', 10000));
  insert into ids values ('cat2', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', t_id('branch2'), 'category_id', t_id('cat2'), 'room_number', 'RPB-1'));
  insert into ids values ('room-b2', (r->>'id')::uuid);
  r := fn_admin_upsert_branch(jsonb_build_object('name_ar', 'فرع إثبات الاستيراد ٢', 'name_en', 'RP import branch 2'));
  insert into ids values ('branch3', (r->>'id')::uuid);
  insert into ids values ('box3', (select id from cash_accounts where branch_id = (r->>'id')::uuid and kind = 'cash_box' and is_default));
  insert into ids values ('bank1', (select id from cash_accounts where branch_id = '00000000-0000-0000-0000-000000000010' and kind = 'bank_account' and is_default));
end $$;
reset role;
insert into branch_memberships(staff_id, branch_id)
  select '10000000-0000-0000-0000-000000000001', v from ids where k in ('branch2', 'branch3')
  on conflict do nothing;
set role authenticated;

-- ---------------------------------------------------------------- rule «مصروف أو قبض فوق عتبة» and «قبض فوق المستحق»: receipts
do $$ declare rid uuid; v uuid; m timestamptz := now(); begin
  rid := t_rp_stay(t_id('room1'), '0571000001', 'قبض فوق العتبة');
  insert into ids values ('res-rcpt', rid);
  v := (select (fn_create_voucher(jsonb_build_object('reservation_id', rid, 'kind', 'receipt', 'amount_halalas', 500001, 'method', 'cash', 'received_confirmed', true, 'advance_ok', true, 'reason', 'دفعة مقدمة لإثبات القاعدة', 'idempotency_key', 'rp46-rcpt-over'))->>'voucher_id')::uuid);
  perform t_record('RP46-01 a receipt one halala over the hotel''s threshold opens receipt_over_threshold with an immediate alert',
    t_flags('receipt_over_threshold', 'voucher', v) = 1 and t_alerts('00000000-0000-0000-0000-000000000010', m) >= 1, null);
exception when others then perform t_record('RP46-01 receipt over threshold positive', false, sqlerrm); end $$;

do $$ declare rid uuid; v uuid; begin
  rid := t_rp_stay(t_id('room2'), '0571000002', 'قبض عند العتبة');
  v := (select (fn_create_voucher(jsonb_build_object('reservation_id', rid, 'kind', 'receipt', 'amount_halalas', 500000, 'method', 'cash', 'received_confirmed', true, 'advance_ok', true, 'reason', 'دفعة مقدمة لإثبات القاعدة', 'idempotency_key', 'rp46-rcpt-at'))->>'voucher_id')::uuid);
  perform t_record('RP46-02 a receipt exactly at the threshold fires no receipt_over_threshold (negative case)',
    t_flags('receipt_over_threshold', 'voucher', v) = 0, null);
exception when others then perform t_record('RP46-02 receipt at threshold negative', false, sqlerrm); end $$;

-- the same two receipts also isolate «قبض فوق المستحق»: raise the receipt threshold so only the due rule can fire
-- (settings writes are RLS-gated; they run as the suite superuser between blocks)
reset role;
update system_settings set anomaly_receipt_threshold_halalas = 100000000 where organization_id = '00000000-0000-0000-0000-000000000001';
set role authenticated;
do $$ declare rid uuid; v uuid; m timestamptz; begin
  m := now();
  rid := t_rp_stay(t_id('room3'), '0571000003', 'قبض فوق المستحق');           -- rent 2 x 300.00 = 600.00
  insert into ids values ('res-due', rid);
  v := (select (fn_create_voucher(jsonb_build_object('reservation_id', rid, 'kind', 'receipt', 'amount_halalas', 60001, 'method', 'cash', 'received_confirmed', true, 'advance_ok', true, 'reason', 'دفعة مقدمة لإثبات القاعدة', 'idempotency_key', 'rp46-due-over'))->>'voucher_id')::uuid);
  perform t_record('RP46-03 a receipt one halala over what the stay is owed opens receipt_over_due with an immediate alert',
    t_flags('receipt_over_due', 'voucher', v) = 1 and t_flags('receipt_over_threshold', 'voucher', v) = 0
    and t_alerts('00000000-0000-0000-0000-000000000010', m) >= 1, null);
exception when others then perform t_record('RP46-03 receipt over due positive', false, sqlerrm); end $$;

reset role;
update system_settings set anomaly_receipt_threshold_halalas = 500000 where organization_id = '00000000-0000-0000-0000-000000000001';
set role authenticated;
do $$ declare rid uuid; v uuid; begin
  rid := t_rp_stay(t_id('room4'), '0571000009', 'قبض داخل المستحق', 430);
  v := (select (fn_create_voucher(jsonb_build_object('reservation_id', rid, 'kind', 'receipt', 'amount_halalas', 100, 'method', 'cash', 'received_confirmed', true, 'idempotency_key', 'rp46-due-in'))->>'voucher_id')::uuid);
  perform t_record('RP46-04 a receipt inside what is owed fires no receipt_over_due (negative case)',
    t_flags('receipt_over_due', 'voucher', v) = 0, null);
exception when others then perform t_record('RP46-04 receipt within due negative', false, sqlerrm); end $$;

-- rule off: a null threshold flags nothing even far above the proposed default
reset role;
update system_settings set anomaly_receipt_threshold_halalas = null where organization_id = '00000000-0000-0000-0000-000000000001';
set role authenticated;
do $$ declare rid uuid; v uuid; begin
  rid := t_rp_stay(t_id('room4'), '0571000004', 'قبض بلا عتبة', 440);
  v := (select (fn_create_voucher(jsonb_build_object('reservation_id', rid, 'kind', 'receipt', 'amount_halalas', 900000, 'method', 'cash', 'received_confirmed', true, 'advance_ok', true, 'reason', 'دفعة مقدمة لإثبات القاعدة', 'idempotency_key', 'rp46-rcpt-off'))->>'voucher_id')::uuid);
  perform t_record('RP46-05 with the threshold switched off (null) even a 9,000.00 receipt flags nothing (negative case)',
    t_flags('receipt_over_threshold', 'voucher', v) = 0, null);
exception when others then perform t_record('RP46-05 threshold off negative', false, sqlerrm); end $$;
reset role;
update system_settings set anomaly_receipt_threshold_halalas = 500000 where organization_id = '00000000-0000-0000-0000-000000000001';
set role authenticated;

-- ---------------------------------------------------------------- rule «مصروف فوق عتبة»: the box holds enough by now (cash receipts above); one attachment, 1x1 PNG
do $$ declare r jsonb; m timestamptz := now(); att jsonb; begin
  att := jsonb_build_array(jsonb_build_object('file_name', 'r.png', 'data_base64', 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='));
  r := fn_expense_create(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'account_id', t_id('box1'), 'category_id', t_id('expcat'),
         'amount_halalas', 500001, 'description', 'مصروف فوق العتبة', 'attachments', att, 'idempotency_key', 'rp46-exp-over'));
  insert into ids values ('exp-over', (r->>'id')::uuid);
  perform t_record('RP46-06 an expense one halala over the threshold opens expense_over_threshold with an immediate alert',
    (r->>'ok')::boolean and t_flags('expense_over_threshold', 'expense_voucher', t_id('exp-over')) = 1
    and t_alerts('00000000-0000-0000-0000-000000000010', m) >= 1, r::text);
exception when others then perform t_record('RP46-06 expense over threshold positive', false, sqlerrm); end $$;

do $$ declare r jsonb; att jsonb; begin
  att := jsonb_build_array(jsonb_build_object('file_name', 'r.png', 'data_base64', 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='));
  r := fn_expense_create(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'account_id', t_id('box1'), 'category_id', t_id('expcat'),
         'amount_halalas', 500000, 'description', 'مصروف عند العتبة', 'attachments', att, 'idempotency_key', 'rp46-exp-at'));
  perform t_record('RP46-07 an expense exactly at the threshold fires no expense_over_threshold (negative case)',
    (r->>'ok')::boolean and t_flags('expense_over_threshold', 'expense_voucher', (r->>'id')::uuid) = 0, r::text);
exception when others then perform t_record('RP46-07 expense at threshold negative', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- rule «تأمين مكرر»: a reasoned top-up flags once; the standing deposit alone does not
do $$ declare rid uuid; v uuid; m timestamptz; begin
  rid := t_rp_stay(t_id('room1'), '0571000005', 'تأمين مكرر', 420);
  insert into ids values ('res-dep', rid);
  perform fn_create_voucher(jsonb_build_object('reservation_id', rid, 'kind', 'deposit', 'amount_halalas', 10000, 'method', 'cash', 'idempotency_key', 'rp46-dep1'));
  v := (select id from financial_vouchers where reservation_id = rid and kind = 'deposit' order by occurred_at limit 1);
  perform t_record('RP46-08 the first standing deposit alone opens no deposit_duplicate item (negative case)',
    t_flags('deposit_duplicate', 'voucher', v) = 0, null);
  perform fn_create_voucher(jsonb_build_object('reservation_id', rid, 'kind', 'deposit', 'amount_halalas', 5000, 'method', 'cash',
        'reason', 'تكملة تأمين — كسر في الغرفة', 'idempotency_key', 'rp46-dep2'));
exception when others then perform t_record('RP46-08/09 deposit duplicate', false, sqlerrm); end $$;

-- (its own block: the duplicate-deposit flag trigger is deferred to the commit, so the item is read after the write commits)
do $$ begin
  perform t_record('RP46-09 the reasoned top-up opens deposit_duplicate with an immediate alert, and the standing deposit is never flagged',
    t_flags('deposit_duplicate', 'voucher', (select id from financial_vouchers where idempotency_key = 'rp46-dep2')) = 1
    and t_count(format('select count(*) from review_items where kind = ''deposit_duplicate'' and reservation_id = %L', t_id('res-dep'))) = 1
    and t_count('select count(*) from notifications n join review_items ri on ri.branch_id = n.branch_id and n.created_at >= ri.created_at
                 where ri.kind = ''deposit_duplicate'' and ri.reservation_id = ''' || (select v from ids where k = 'res-dep') || ''' and n.title like ''%شذوذ مالي%''') >= 1, null);
exception when others then perform t_record('RP46-09 deposit duplicate flag after commit', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- rule «سعر صفر»: the owner''s approved free stay flags once per stay; a priced night never does
do $$ declare r jsonb; rid uuid; m timestamptz := now(); begin
  r := fn_staff_create_free_stay(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_id', t_id('room2'),
         'check_in', t_today('00000000-0000-0000-0000-000000000010') + 450, 'check_out', t_today('00000000-0000-0000-0000-000000000010') + 451,
         'guest_phone', '0571000006', 'guest_name', 'إقامة مجانية', 'source_id', '00000000-0000-0000-0000-000000000021', 'reason', 'تعويض نزيل عن إزعاج'));
  rid := (r->>'id')::uuid;
  perform t_record('RP46-10 the approved free stay opens zero_price with an immediate alert, once for the stay',
    (r->>'ok')::boolean and t_flags('zero_price', 'reservation', rid) = 1 and t_alerts('00000000-0000-0000-0000-000000000010', m) >= 1, r::text);
  perform t_record('RP46-11 the priced stays of this file carry no zero_price item (negative case)',
    t_count(format('select count(*) from review_items where kind = ''zero_price'' and reservation_id in (%L, %L, %L)',
                   t_id('res-rcpt'), t_id('res-due'), t_id('res-dep'))) = 0, null);
exception when others then perform t_record('RP46-10/11 zero price', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- rule «خصم كبير»: over the 20% threshold needs the owner''s prior approval, then flags with the amount
do $$ declare rid uuid; e text; a jsonb; r jsonb; v int; m timestamptz; begin
  rid := t_rp_stay(t_id('room3'), '0571000007', 'خصم كبير', 420);                 -- rent 600.00; threshold 20% = 120.00
  insert into ids values ('res-disc', rid);
  select version into v from reservations where id = rid;
  e := t_fails(format('select fn_staff_adjust_price(%L, %L, %s, %L, %L, %s)', rid, 'discount', 15000, 'خصم كبير', 'طلب الضيف', v), 'DISCOUNT_APPROVAL_REQUIRED%');
  perform t_record('RP46-12 an over-threshold discount without the owner''s approval is refused and writes nothing (negative case)',
    e = 'ok' and t_count(format('select count(*) from reservation_charges where reservation_id = %L and kind = ''discount''', rid)) = 0, e);
  m := now();
  a := fn_approve_discount(jsonb_build_object('reservation_id', rid, 'amount_halalas', 15000, 'reason', 'اعتماد إثبات الشذوذ'));
  select version into v from reservations where id = rid;
  r := fn_staff_adjust_price(rid, 'discount', 15000, 'خصم معتمد', 'طلب الضيف', v);
  perform t_record('RP46-13 with the approval the same discount posts and opens discount_over_threshold carrying the amount, with an immediate alert',
    (a->>'ok')::boolean and (r->>'ok')::boolean
    and t_count(format('select count(*) from review_items where kind = ''discount_over_threshold'' and reservation_id = %L and (details->>''amount_halalas'')::bigint = 15000', rid)) = 1
    and t_alerts('00000000-0000-0000-0000-000000000010', m) >= 1, r::text);
exception when others then perform t_record('RP46-12/13 large discount', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- rule «صندوق سالب»: the voucher path still reaches it
-- (a cash receipt, the box drained by an expense, then the stay is cancelled and the cash refund has no box to come from:
-- refunds carry no floor of their own, so the anomaly rule is the safety net and must fire)
do $$ declare rid uuid; v uuid; m timestamptz; att jsonb; bal bigint; r jsonb; begin
  att := jsonb_build_array(jsonb_build_object('file_name', 'r.png', 'data_base64', 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='));
  -- the import branch's box starts empty: a cash receipt, an expense that drains it, then the cancelled stay's cash refund
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', t_id('branch2'), 'category_id', t_id('cat2'), 'room_id', t_id('room-b2'),
         'check_in', t_today(t_id('branch2')) + 410, 'check_out', t_today(t_id('branch2')) + 412,
         'guest_phone', '0571000008', 'guest_name', 'صندوق سالب', 'source_id', '00000000-0000-0000-0000-000000000021'));
  rid := (r->>'id')::uuid;
  insert into ids values ('res-neg', rid);
  perform fn_create_voucher(jsonb_build_object('reservation_id', rid, 'kind', 'receipt', 'amount_halalas', 60000, 'method', 'cash',
         'account_id', t_id('box2'), 'received_confirmed', true, 'idempotency_key', 'rp46-neg-in'));
  perform fn_expense_create(jsonb_build_object('branch_id', t_id('branch2'), 'account_id', t_id('box2'), 'category_id', t_id('expcat'),
         'amount_halalas', 60000, 'description', 'صرف رصيد الصندوق', 'attachments', att, 'idempotency_key', 'rp46-neg-exp'));
  bal := t_count(format('select (select opening_balance_halalas from cash_accounts where id = %L) + coalesce((select sum(in_halalas - out_halalas) from fn_account_movements(%L)), 0)', t_id('box2'), t_id('box2')));
  m := now();
  v := (select (fn_refund(jsonb_build_object('reservation_id', rid, 'kind', 'refund', 'amount_halalas', 60000, 'reason', 'إلغاء الحجز',
        'method', 'cash', 'account_id', t_id('box2'), 'idempotency_key', 'rp46-neg-out'))->>'voucher_id')::uuid);
  perform t_record('RP46-14a a cash refund the box cannot cover leaves it negative and opens negative_cash_box with an immediate alert',
    bal = 0
    and t_flags('negative_cash_box', 'cash_account', t_id('box2')) = 1
    and t_alerts(t_id('branch2'), m) >= 1,
    'box balance before refund: ' || bal || '; refund: 60000');
exception when others then perform t_record('RP46-14a voucher-path negative box', false, sqlerrm); end $$;

-- the import path the acceptance text names: a negative opening balance imported into a box (no voucher, no expense)
do $$ declare r jsonb; m timestamptz := now(); begin
  r := fn_admin_set_account_opening(t_id('box3'), -50000, t_today(t_id('branch3')), 'استيراد رصيد افتتاحي سالب');
  perform t_record('RP46-14b an imported negative opening balance opens «صندوق سالب» (negative_cash_box) with an immediate alert',
    (r->>'ok')::boolean and t_flags('negative_cash_box', 'cash_account', t_id('box3')) = 1
    and t_alerts(t_id('branch3'), m) >= 1,
    'opening set ok=' || (r->>'ok')::text || '; negative_cash_box items=' || t_flags('negative_cash_box', 'cash_account', t_id('box3'))
      || '; alerts=' || t_alerts(t_id('branch3'), m)
      || '; account_opening_set items=' || t_flags('account_opening_set', 'cash_account', t_id('box3')));
exception when others then perform t_record('RP46-14b imported negative opening', false, sqlerrm); end $$;
-- leave the branch as found
do $$ begin
  perform fn_admin_set_account_opening(t_id('box3'), 0, t_today(t_id('branch3')), 'إعادة الرصيد بعد الاختبار');
exception when others then null; end $$;

-- =====================================================================
-- RESULTS
-- =====================================================================
reset role;
select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),150) as detail from test_results order by name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if (select count(*) from test_results) < 15 then raise exception 'RP46 TESTS INCOMPLETE: % of 15 checks ran', (select count(*) from test_results); end if;
  if exists (select 1 from test_results where ok is not true) then raise exception 'RP46 ANOMALY SIX-RULE TESTS FAILED'; end if;
end $$;
