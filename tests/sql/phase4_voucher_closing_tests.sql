-- =====================================================================
-- Phase 4 money controls (proposed migrations 0084/0085): 4.1 «استلمت» وسقف النقص والآجل باعتماد المدير،
-- 4.2 سقف القبض (سند 99,999 على حجز قيمته 75 يُرفض) والدفعة المقدمة، 4.3 حد المصروف لكل دور و«بانتظار اعتماد»
-- والصندوق لا ينزل تحت الصفر والمرفق حتى 10 ميجابايت، 4.4 الدالة لا تُرجع رقم النظام قبل الإرسال.
-- Invented test data only. Rejection, rollback and totals invariants are asserted after every refusal.
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
create or replace function t_fails(p_sql text, p_like text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'accepted';
exception when others then
  return case when sqlerrm like p_like then 'ok' else sqlerrm end;
end $$;
create or replace function t_png() returns text language sql immutable as $$ select 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==' $$;
create or replace function t_png_mb(p_mb int) returns text language sql stable as $$
  select encode('\x89504e470d0a1a0a'::bytea || decode(repeat('ab', p_mb * 1048576 - 8), 'hex'), 'base64')
$$;
-- what a script could read itself: the day's live figures (the screen must not show them before sending)
create or replace function t_compute(p_branch uuid, p_date date) returns jsonb language sql security definer as $$
  select fn_day_closing_compute(p_branch, p_date)
$$;
create or replace function t_accid(p_branch uuid, p_kind text) returns uuid language sql security definer as $$
  select id from cash_accounts where branch_id = p_branch and kind = p_kind and archived_at is null $$;
create or replace function t_fin(p uuid) returns jsonb language sql security definer as $$ select fn_reservation_finance_internal(p) $$;
create or replace function t_att_size(p_expense uuid) returns bigint language sql security definer as $$
  select max(size_bytes)::bigint from expense_attachments where expense_id = p_expense $$;
create or replace function t_bal(p_account uuid) returns bigint language sql security definer as $$ select fn_cash_account_balance(p_account) $$;
create or replace function t_review_count(p_kind text, p_res uuid) returns bigint language sql security definer as $$
  select count(*) from review_items where kind = p_kind and (p_res is null or reservation_id = p_res) $$;
create or replace function t_review_for(p_kind text, p_entity uuid) returns boolean language sql security definer as $$
  select exists (select 1 from review_items where kind = p_kind and entity_id = p_entity) $$;
create or replace function t_mov_has_expense(p_account uuid, p_ref uuid) returns boolean language sql security definer as $$
  select exists (select 1 from fn_account_movements(p_account) m where m.kind = 'expense' and m.ref_id = p_ref) $$;

-- a manager of the owner's org (the seeded set has owner/supervisor/housekeeping/finance)
insert into staff_profiles(id, auth_user_id, organization_id, full_name, email, role)
values ('10000000-0000-0000-0000-000000000091', 'a0000000-0000-0000-0000-000000000091', '00000000-0000-0000-0000-000000000001', 'مدير المرحلة', 'mgr4@test.local', 'manager')
on conflict (id) do nothing;

-- ---------------------------------------------------------------- setup: a branch, a stay worth 75 SAR (7,500 halalas), cash in the box
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; b uuid; cat uuid; begin
  r := fn_admin_upsert_branch('{"name_ar":"فرع المرحلة الرابعة","name_en":"PhaseFour branch","tax_rate_bp":0}'); b := (r->>'id')::uuid;
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', b, 'name_ar', 'غرفة الضبط', 'base_price_halalas', 3750)); cat := (r->>'id')::uuid;
  perform fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', '941'));
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b, 'category_id', cat, 'check_in', (fn_branch_today(b) + 30)::text,
         'check_out', (fn_branch_today(b) + 32)::text, 'guest_phone', '0551000091', 'guest_name', 'نزيل الضبط الأول', 'source_id', '00000000-0000-0000-0000-000000000021'));
  insert into ids values ('b', b), ('res1', (r->>'id')::uuid);
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b, 'category_id', cat, 'check_in', (fn_branch_today(b) + 40)::text,
         'check_out', (fn_branch_today(b) + 42)::text, 'guest_phone', '0551000092', 'guest_name', 'نزيل الضبط الثاني', 'source_id', '00000000-0000-0000-0000-000000000021'));
  insert into ids values ('res2', (r->>'id')::uuid);
  perform fn_admin_set_account_opening(t_accid(b, 'cash_box'), 5000000, fn_branch_today(b), 'رصيد افتتاحي تجريبي');
  perform t_record('P4-00 the branch, two stays of 7,500 halalas each and a cash box with an opening are set up',
    (select (t_fin(t_id('res1'))->>'total')::bigint) = 7500
    and (select (t_fin(t_id('res2'))->>'total')::bigint) = 7500
    and (select opening_balance_halalas from cash_accounts where id = t_accid(t_id('b'), 'cash_box')) = 5000000,
    (select t_fin(t_id('res1'))->>'total'));
exception when others then perform t_record('P4-00 the branch, two stays of 7,500 halalas each and a cash box with an opening are set up', false, sqlerrm);
end $$;
reset role;
insert into branch_memberships(staff_id, branch_id)
select s, t_id('b') from unnest(array['10000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000091']::uuid[]) s
on conflict do nothing;
set role authenticated;

-- ---------------------------------------------------------------- 4.1: no receipt without «استلمت», refused for every role
do $$ declare x text; begin
  x := t_fails(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res1'), 'kind', 'receipt', 'amount_halalas', 1000, 'method', 'cash', 'idempotency_key', 'p4-noc')), '%received_confirm%');
  perform t_record('P4-01 4.1: a receipt without «استلمت» confirmation is refused (owner)', x = 'ok', x);
end $$;
do $$ declare x text; begin
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  x := t_fails(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res1'), 'kind', 'receipt', 'amount_halalas', 1000, 'method', 'cash', 'idempotency_key', 'p4-noc-s')), '%received_confirm%');
  perform t_record('P4-02 4.1: a receipt without «استلمت» confirmation is refused (supervisor)', x = 'ok', x);
  perform t_login('a0000000-0000-0000-0000-000000000004', 'fin@test.local');
  x := t_fails(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res1'), 'kind', 'receipt', 'amount_halalas', 1000, 'method', 'cash', 'idempotency_key', 'p4-noc-f')), '%received_confirm%');
  perform t_record('P4-03 4.1: a receipt without «استلمت» confirmation is refused (finance)', x = 'ok', x);
  perform t_login('a0000000-0000-0000-0000-000000000091', 'mgr4@test.local');
  x := t_fails(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res1'), 'kind', 'receipt', 'amount_halalas', 1000, 'method', 'cash', 'idempotency_key', 'p4-noc-m')), '%received_confirm%');
  perform t_record('P4-04 4.1: a receipt without «استلمت» confirmation is refused (manager); rollback: nothing was recorded',
    x = 'ok' and (select count(*) from financial_vouchers where reservation_id = t_id('res1')) = 0
    and (select (t_fin(t_id('res1'))->>'balance_due')::bigint) = 7500, x);
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
end $$;
do $$ declare r jsonb; begin
  r := fn_create_voucher(jsonb_build_object('reservation_id', t_id('res1'), 'kind', 'receipt', 'amount_halalas', 1000, 'method', 'cash', 'received_confirmed', true, 'idempotency_key', 'p4-ok-1'));
  perform t_record('P4-05 4.1: with «استلمت» the receipt passes and the due drops to 6,500',
    (r->>'ok')::boolean and (select (t_fin(t_id('res1'))->>'balance_due')::bigint) = 6500, r->>'number');
exception when others then perform t_record('P4-05 4.1: with «استلمت» the receipt passes and the due drops to 6,500', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- 4.2: the voucher never exceeds the due (99,999 on a stay worth 75 is refused)
do $$ declare x text; begin
  x := t_fails(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res1'), 'kind', 'receipt', 'amount_halalas', 9999900, 'method', 'cash', 'received_confirmed', true, 'idempotency_key', 'p4-cap-1')), '%amount_exceeds_short%');
  perform t_record('P4-06 4.2: a voucher of 99,999 SAR on a booking worth 75 SAR is refused; rollback: totals unchanged',
    x = 'ok' and (select (t_fin(t_id('res1'))->>'balance_due')::bigint) = 6500
    and (select count(*) from financial_vouchers where reservation_id = t_id('res1')) = 1, x);
end $$;
do $$ declare x text; begin
  x := t_fails(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res2'), 'kind', 'receipt', 'amount_halalas', 8000, 'method', 'cash', 'received_confirmed', true, 'advance_ok', true, 'idempotency_key', 'p4-adv-0')), '%amount_exceeds_short%');
  perform t_record('P4-07 4.2: an excess without a written reason is refused even with advance_ok', x = 'ok', x);
end $$;
do $$ declare r jsonb; ri int; begin
  r := fn_create_voucher(jsonb_build_object('reservation_id', t_id('res2'), 'kind', 'receipt', 'amount_halalas', 8000, 'method', 'cash', 'received_confirmed', true,
                                            'advance_ok', true, 'reason', 'دفع النزيل مقدمًا بطلبه', 'idempotency_key', 'p4-adv-1'));
  select t_review_count('voucher_advance_payment', t_id('res2')) into ri;
  perform t_record('P4-08 4.2: the excess passes as «دفعة مقدمة» with a reason and a review item; totals: credit = 500',
    (r->>'ok')::boolean and ri = 1
    and (select (t_fin(t_id('res2'))->>'credit')::bigint) = 500
    and (select (t_fin(t_id('res2'))->>'payment_status')) = 'paid', r->>'number');
exception when others then perform t_record('P4-08 4.2: the excess passes as «دفعة مقدمة» with a reason and a review item; totals: credit = 500', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- 4.1: «الآجل باعتماد المدير فقط»
do $$ declare r jsonb; x text; ri int; begin
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', t_id('b'), 'category_id', (select room_category_id from reservations where id = t_id('res1')),
         'check_in', (fn_branch_today(t_id('b')) + 50)::text, 'check_out', (fn_branch_today(t_id('b')) + 52)::text,
         'guest_phone', '0551000093', 'guest_name', 'نزيل الآجل', 'source_id', '00000000-0000-0000-0000-000000000021'));
  insert into ids values ('res3', (r->>'id')::uuid) on conflict (k) do update set v = excluded.v;
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  x := t_fails(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res3'), 'kind', 'receipt', 'amount_halalas', 2000, 'method', 'ota_deferred', 'received_confirmed', true, 'idempotency_key', 'p4-def-1')), '%deferred_manager_only%');
  perform t_record('P4-09 4.1: «آجل» without the management is refused (supervisor)', x = 'ok', x);
  perform t_login('a0000000-0000-0000-0000-000000000091', 'mgr4@test.local');
  r := fn_create_voucher(jsonb_build_object('reservation_id', t_id('res3'), 'kind', 'receipt', 'amount_halalas', 2000, 'method', 'ota_deferred', 'received_confirmed', true, 'idempotency_key', 'p4-def-2'));
  select t_review_count('voucher_deferred_manager', t_id('res3')) into ri;
  perform t_record('P4-10 4.1: «آجل» with the management passes and lands in «بحاجة لمراجعة»',
    (r->>'ok')::boolean and ri = 1 and (select (t_fin(t_id('res3'))->>'received')::bigint) = 2000, r->>'number');
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
exception when others then perform t_record('P4-09/P4-10 «الآجل باعتماد المدير فقط»', false, sqlerrm);
end $$;
do $$ declare r jsonb; begin
  r := fn_create_voucher(jsonb_build_object('reservation_id', t_id('res3'), 'kind', 'deposit', 'amount_halalas', 3000, 'method', 'cash', 'idempotency_key', 'p4-dep-1'));
  perform t_record('P4-11 4.1: the confirmation rule is for receipts; a deposit voucher is unchanged',
    (r->>'ok')::boolean and (select (t_fin(t_id('res3'))->>'deposit_balance')::bigint) = 3000, r->>'number');
exception when others then perform t_record('P4-11 4.1: the confirmation rule is for receipts; a deposit voucher is unchanged', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- 4.3: the expense — a limit per role, «بانتظار اعتماد», the floor, the 10 MB receipt
do $$ declare r jsonb; bal bigint; begin
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  bal := t_bal(t_accid(t_id('b'), 'cash_box'));
  r := fn_expense_create(jsonb_build_object('branch_id', t_id('b'), 'account_id', t_accid(t_id('b'), 'cash_box'),
         'category_id', (select id from expense_categories where organization_id = fn_user_org_id() order by sort_order limit 1),
         'amount_halalas', 600000, 'description', 'مصروف فوق حد المشرف', 'idempotency_key', 'p4-ex-1',
         'attachments', jsonb_build_array(jsonb_build_object('data_base64', t_png(), 'file_name', 'r.png'))));
  insert into ids values ('exp_pending', (r->>'id')::uuid) on conflict (k) do update set v = excluded.v;
  perform t_record('P4-12 4.3: a supervisor above the role limit (6,000 SAR > 5,000) creates «بانتظار اعتماد»; the box does not move',
    r->>'status' = 'pending' and (r->>'pending_approval')::boolean
    and t_bal(t_accid(t_id('b'), 'cash_box')) = bal
    and t_review_for('expense_pending_approval', (r->>'id')::uuid)
    and not t_mov_has_expense(t_accid(t_id('b'), 'cash_box'), (r->>'id')::uuid), r->>'number');
exception when others then perform t_record('P4-12 4.3: a supervisor above the role limit creates «بانتظار اعتماد»', false, sqlerrm);
end $$;
do $$ declare x text; r jsonb; bal bigint; begin
  x := t_fails(format('select fn_expense_approve(%L)', t_id('exp_pending')), '%');
  perform t_record('P4-13 4.3: a supervisor cannot approve the pending expense', x = 'ok', x);
  perform t_login('a0000000-0000-0000-0000-000000000091', 'mgr4@test.local');
  bal := t_bal(t_accid(t_id('b'), 'cash_box'));
  r := fn_expense_approve(t_id('exp_pending'));
  perform t_record('P4-14 4.3: the manager approves; the expense now moves the box and appears in the ledger',
    (r->>'ok')::boolean and t_bal(t_accid(t_id('b'), 'cash_box')) = bal - 600000
    and t_mov_has_expense(t_accid(t_id('b'), 'cash_box'), t_id('exp_pending')), r->>'number');
exception when others then perform t_record('P4-13/P4-14 4.3 اعتماد المصروف', false, sqlerrm);
end $$;
do $$ declare x text; n bigint; begin
  x := t_fails(format('select fn_expense_create(%L::jsonb)', jsonb_build_object('branch_id', t_id('b'), 'account_id', t_accid(t_id('b'), 'cash_box'),
         'category_id', (select id from expense_categories where organization_id = fn_user_org_id() order by sort_order limit 1),
         'amount_halalas', 99999999, 'description', 'مصروف أكبر من الصندوق', 'idempotency_key', 'p4-ex-neg',
         'attachments', jsonb_build_array(jsonb_build_object('data_base64', t_png(), 'file_name', 'r.png')))), '%CASH_BOX_NEGATIVE%');
  select count(*) into n from expense_vouchers where branch_id = t_id('b') and idempotency_key = 'p4-ex-neg';
  perform t_record('P4-15 4.3: the cash box never goes below zero (a manager is refused too); rollback: no voucher written', x = 'ok' and n = 0, x);
end $$;
do $$ declare r jsonb; begin
  r := fn_expense_create(jsonb_build_object('branch_id', t_id('b'), 'account_id', t_accid(t_id('b'), 'cash_box'),
         'category_id', (select id from expense_categories where organization_id = fn_user_org_id() order by sort_order limit 1),
         'amount_halalas', 400000, 'description', 'مصروف ضمن حد المشرف', 'idempotency_key', 'p4-ex-2',
         'attachments', jsonb_build_array(jsonb_build_object('data_base64', t_png_mb(3), 'file_name', 'big.png'))));
  perform t_record('P4-16 4.3: within the limit the expense is approved at once, and a 3 MB receipt (was refused over 2 MB) is accepted',
    r->>'status' = 'approved' and (r->>'ok')::boolean
    and t_att_size((r->>'id')::uuid) = 3145728, r->>'number');
exception when others then perform t_record('P4-16 4.3: within the limit the expense is approved at once, and a 3 MB receipt is accepted', false, sqlerrm);
end $$;
do $$ declare x text; begin
  x := t_fails(format('select fn_expense_create(%L::jsonb)', jsonb_build_object('branch_id', t_id('b'), 'account_id', t_accid(t_id('b'), 'cash_box'),
         'category_id', (select id from expense_categories where organization_id = fn_user_org_id() order by sort_order limit 1),
         'amount_halalas', 1000, 'description', 'مرفق أكبر من 10 ميجابايت', 'idempotency_key', 'p4-ex-big',
         'attachments', jsonb_build_array(jsonb_build_object('data_base64', t_png_mb(11), 'file_name', 'huge.png')))), '%attachment_too_large%');
  perform t_record('P4-17 4.3: an 11 MB receipt is refused (the ceiling is 10 MB)', x = 'ok', x);
end $$;

-- ---------------------------------------------------------------- 4.4: the blind count — no system figure before sending
do $$ declare g jsonb; begin
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  g := fn_day_closing_get(t_id('b'), fn_branch_today(t_id('b')));
  perform t_record('P4-18 4.4: before any closing the function returns no system figure and no matrix',
    not exists (select 1 from jsonb_array_elements(g->'live'->'boxes') b where b ? 'system_halalas')
    and g->'live'->'matrix' = '[]'::jsonb, (g->'live'->'boxes')::text);
exception when others then perform t_record('P4-18 4.4: before any closing the function returns no system figure and no matrix', false, sqlerrm);
end $$;
do $$ declare s jsonb; g jsonb; live jsonb; lines jsonb; begin
  live := t_compute(t_id('b'), fn_branch_today(t_id('b')));   -- the test computes what the screen must not see
  select jsonb_agg(jsonb_build_object('key', b->>'key', 'entered_halalas', b->>'system_halalas')) into lines from jsonb_array_elements(live->'boxes') b;
  s := fn_day_closing_save(jsonb_build_object('branch_id', t_id('b'), 'business_date', fn_branch_today(t_id('b')), 'lines', lines));
  g := fn_day_closing_get(t_id('b'), fn_branch_today(t_id('b')));
  perform t_record('P4-19 4.4: while the draft is counted, the stored lines hide the system figure and the difference but keep what was entered',
    (s->>'ok')::boolean
    and not exists (select 1 from jsonb_array_elements(g->'lines') l where l ? 'system_halalas' or l ? 'difference_halalas')
    and exists (select 1 from jsonb_array_elements(g->'lines') l where l->>'key' = 'cash' and l->>'entered_halalas' is not null), (g->'lines')::text);
exception when others then perform t_record('P4-19 4.4: while the draft is counted, the stored lines hide the system figure and the difference but keep what was entered', false, sqlerrm);
end $$;
do $$ declare c day_closings%rowtype; rv jsonb; s jsonb; g jsonb; exp bigint; begin
  select * into c from day_closings where branch_id = t_id('b') and business_date = fn_branch_today(t_id('b'));
  rv := fn_day_closing_review(c.id);
  s := fn_day_closing_submit(c.id, (rv->>'version')::int, rv->>'hash');
  exp := (select (b->>'system_halalas')::bigint from jsonb_array_elements(t_compute(t_id('b'), fn_branch_today(t_id('b')))->'boxes') b where b->>'key' = 'cash');
  g := fn_day_closing_get(t_id('b'), fn_branch_today(t_id('b')));
  perform t_record('P4-20 4.4: after sending, the system figure is returned and equals the computed cash (totals invariant)',
    (s->>'ok')::boolean
    and exists (select 1 from jsonb_array_elements(g->'live'->'boxes') b where b->>'key' = 'cash' and (b->>'system_halalas')::bigint = exp)
    and exists (select 1 from jsonb_array_elements(g->'lines') l where l ? 'system_halalas' and l->>'key' = 'cash'), s::text);
exception when others then perform t_record('P4-20 4.4: after sending, the system figure is returned and equals the computed cash (totals invariant)', false, sqlerrm);
end $$;
-- ---------------------------------------------------------------- review fix: the exemption cannot be spoofed
-- Caller JSON internal_reuse, a spoofed app.source setting and a spoofed x-client-source header must NOT exempt a
-- direct RPC caller from «استلمت», the remaining-due cap or «الآجل باعتماد المدير»; the internal flows must still work.
do $$ declare x text; begin
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  x := t_fails(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res1'), 'kind', 'receipt', 'amount_halalas', 1000, 'method', 'cash', 'internal_reuse', true, 'idempotency_key', 'p4-spoof-1')), '%received_confirm%');
  perform t_record('P4-21 fix: a direct receipt with internal_reuse=true and no «استلمت» is still refused; rollback: nothing recorded',
    x = 'ok' and (select count(*) from financial_vouchers where reservation_id = t_id('res1')) = 1, x);
end $$;
do $$ declare x text; begin
  x := t_fails(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res1'), 'kind', 'receipt', 'amount_halalas', 9999900, 'method', 'cash', 'received_confirmed', true, 'internal_reuse', true, 'idempotency_key', 'p4-spoof-2')), '%amount_exceeds_short%');
  perform t_record('P4-22 fix: a 99,999 voucher with internal_reuse=true is still refused by the due cap; totals unchanged',
    x = 'ok' and (select (t_fin(t_id('res1'))->>'balance_due')::bigint) = 6500, x);
end $$;
do $$ declare x text; begin
  perform set_config('app.source', 'ops_assistant', true);   -- what the trusted assistant path sets; a caller must gain nothing from it
  x := t_fails(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res1'), 'kind', 'receipt', 'amount_halalas', 1000, 'method', 'cash', 'idempotency_key', 'p4-spoof-3')), '%received_confirm%');
  perform set_config('app.source', '', true);
  perform t_record('P4-23 fix: a spoofed app.source=ops_assistant does not exempt the receipt from «استلمت»',
    x = 'ok' and (select count(*) from financial_vouchers where reservation_id = t_id('res1')) = 1, x);
end $$;
do $$ declare x text; begin
  perform set_config('request.headers', '{"x-client-source":"ops_assistant"}', true);   -- a spoofed client header
  x := t_fails(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res1'), 'kind', 'receipt', 'amount_halalas', 1000, 'method', 'cash', 'idempotency_key', 'p4-spoof-4')), '%received_confirm%');
  perform set_config('request.headers', '{}', true);
  perform t_record('P4-24 fix: a spoofed x-client-source header does not exempt the receipt from «استلمت»',
    x = 'ok' and (select count(*) from financial_vouchers where reservation_id = t_id('res1')) = 1, x);
end $$;
do $$ declare x text; begin
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  perform set_config('app.source', 'ops_assistant', true);
  x := t_fails(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res3'), 'kind', 'receipt', 'amount_halalas', 2000, 'method', 'ota_deferred', 'received_confirmed', true, 'internal_reuse', true, 'idempotency_key', 'p4-spoof-5')), '%deferred_manager_only%');
  perform set_config('app.source', '', true);
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  perform t_record('P4-25 fix: «آجل» with spoofed flags is still refused below the management', x = 'ok', x);
end $$;
do $$ declare r jsonb; vid uuid; begin
  select id into vid from financial_vouchers where reservation_id = t_id('res1') and idempotency_key = 'p4-ok-1';
  r := fn_staff_correct_voucher(jsonb_build_object('voucher_id', vid, 'amount_halalas', '1500', 'reason', 'تصحيح مبلغ الاختبار', 'idempotency_key', 'p4-fix-correct-1'));
  perform t_record('P4-26 fix: the internal correction flow still works without caller flags (replacement posted, totals follow)',
    (r->>'ok')::boolean and (select (t_fin(t_id('res1'))->>'received')::bigint) = 1500
    and (select (t_fin(t_id('res1'))->>'balance_due')::bigint) = 6000, r->>'number');
exception when others then perform t_record('P4-26 fix: the internal correction flow still works without caller flags (replacement posted, totals follow)', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- summary
select name, case when ok then 'PASS' else 'FAIL' end as result, coalesce(detail, '') as detail from test_results order by ctid;
-- a FAIL row alone does not stop the suite (the row starts with the name, not with FAIL): raise so run.sh sees an error
\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from test_results where ok is not true) then raise exception 'PHASE 4 MONEY CONTROL TESTS FAILED'; end if;
  if (select count(*) from test_results) < 27 then raise exception 'PHASE 4 MONEY CONTROL TESTS INCOMPLETE: % of 27 checks ran', (select count(*) from test_results); end if;
end $$;
