create or replace function t_today(p uuid) returns date language sql security definer as $$ select fn_branch_today(p) $$;  -- 0127: authenticated cannot call fn_branch_today directly
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
  r := fn_admin_upsert_branch('{"name_ar":"فرع قفل المصروف 0126","name_en":"Expense lock 0126 branch","tax_rate_bp":0}'); b := (r->>'id')::uuid;
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', b, 'name_ar', 'غرفة الضبط', 'base_price_halalas', 3750)); cat := (r->>'id')::uuid;
  perform fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', '946'));
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b, 'category_id', cat, 'check_in', (t_today(b) + 30)::text,
         'check_out', (t_today(b) + 32)::text, 'guest_phone', '0551000191', 'guest_name', 'نزيل الضبط الأول', 'source_id', '00000000-0000-0000-0000-000000000021'));
  insert into ids values ('b', b), ('res1', (r->>'id')::uuid);
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b, 'category_id', cat, 'check_in', (t_today(b) + 40)::text,
         'check_out', (t_today(b) + 42)::text, 'guest_phone', '0551000192', 'guest_name', 'نزيل الضبط الثاني', 'source_id', '00000000-0000-0000-0000-000000000021'));
  insert into ids values ('res2', (r->>'id')::uuid);
  perform fn_admin_set_account_opening(t_accid(b, 'cash_box'), 5000000, t_today(b), 'رصيد افتتاحي تجريبي');
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

-- ---------------------------------------------------------------- 4.3: the expense — a limit per role, «بانتظار اعتماد», the floor, the 10 MB receipt
do $$ declare r jsonb; bal bigint; begin
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  bal := t_bal(t_accid(t_id('b'), 'cash_box'));
  r := fn_expense_create(jsonb_build_object('branch_id', t_id('b'), 'account_id', t_accid(t_id('b'), 'cash_box'),
         'category_id', (select id from expense_categories where organization_id = fn_user_org_id() order by sort_order limit 1),
         'amount_halalas', 600000, 'description', 'مصروف فوق حد المشرف', 'idempotency_key', 'l0126-ex-1',
         'attachments', jsonb_build_array(jsonb_build_object('data_base64', t_png(), 'file_name', 'r.png'))));
  insert into ids values ('exp_pending', (r->>'id')::uuid) on conflict (k) do update set v = excluded.v;
  perform t_record('P4-12 4.3: a supervisor above the role limit (6,000 SAR > 5,000) creates «بانتظار اعتماد»; the box does not move',
    r->>'status' = 'pending' and (r->>'pending_approval')::boolean
    and t_bal(t_accid(t_id('b'), 'cash_box')) = bal
    and t_review_for('expense_pending_approval', (r->>'id')::uuid)
    and not t_mov_has_expense(t_accid(t_id('b'), 'cash_box'), (r->>'id')::uuid), r->>'number');
exception when others then perform t_record('P4-12 4.3: a supervisor above the role limit creates «بانتظار اعتماد»', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- 0126 candidate regression (NOT part of frozen v9g)
-- Approving a pending expense whose business day is in a locked month. Preserved semantics: the journal date stays the expense's own
-- business day (fn_branch_date of occurred_at); a locked month refuses with PERIOD_LOCKED; the whole approval rolls back;
-- no fallback to an open period. Limit: occurred_at is today here, so the date assertion does not separate expense day from approval day.
-- Standalone: repeats the phase4 branch/stay/cash-box setup and its P4-12 pending expense (the 4.1/4.2 voucher blocks are left out) with its own names (runs before or after phase4_voucher_closing_tests.sql); needs migrations 0001-0128 and the earlier run.sh files for the seeded staff and settings.
reset role;
create or replace function t_snap0126(p_exp uuid, p_acc uuid) returns text language sql security definer as $$
  select concat_ws('|',
    'status=' || (select status from expense_vouchers where id = p_exp),
    'box=' || fn_cash_account_balance(p_acc),
    'je_exp=' || (select count(*) from journal_entries where source_type = 'expense' and source_id = p_exp),
    'je_all=' || (select count(*) from journal_entries),
    'jl_all=' || (select count(*) from journal_lines),
    'mov_exp=' || (select count(*) from fn_account_movements(p_acc) m where m.kind = 'expense' and m.ref_id = p_exp),
    'audit_approved=' || (select count(*) from audit_events where action = 'expense.approved' and entity_id = p_exp),
    'review=' || (select count(*) from review_items where kind = 'expense_pending_approval' and entity_id = p_exp),
    'vouchers=' || (select count(*) from expense_vouchers)) $$;
create or replace function t_day0126(p_exp uuid) returns date language sql security definer as $$ select fn_branch_date(branch_id, occurred_at) from expense_vouchers where id = p_exp $$;
grant execute on function t_snap0126(uuid,uuid), t_day0126(uuid) to public;
set role authenticated;
do $$ declare b uuid := t_id('b'); e uuid := t_id('exp_pending'); acc uuid; x text; s0 text; s1 text; s2 text; r jsonb; d date; begin
  acc := t_accid(b, 'cash_box');
  d := t_day0126(e);
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  perform fn_accounting_lock_month(date_trunc('month', d)::date, true, 'إقفال لاختبار 0126');
  perform t_login('a0000000-0000-0000-0000-000000000091', 'mgr4@test.local');
  s0 := t_snap0126(e, acc);
  x := t_fails(format('select fn_expense_approve(%L)', e), 'PERIOD_LOCKED%');
  s1 := t_snap0126(e, acc);
  perform t_record('L0126-1: approving a pending expense whose business day is in a locked month is refused with PERIOD_LOCKED', x = 'ok', x);
  perform t_record('L0126-2: the refused approval leaves no effect (status pending, box, journal entries and lines, movements, audit, reviews, voucher count all equal before/after)',
    s0 = s1 and s0 like 'status=pending|%' and s0 like '%|je_exp=0|%' and s0 like '%|mov_exp=0|%' and s0 like '%|audit_approved=0|%', s0 || ' => ' || s1);
  -- unlock: the same approval now succeeds and posts on the expense's own day, not on the approval day
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  perform fn_accounting_lock_month(date_trunc('month', d)::date, false, 'فتح بعد اختبار 0126');
  perform t_login('a0000000-0000-0000-0000-000000000091', 'mgr4@test.local');
  r := fn_expense_approve(e);
  s2 := t_snap0126(e, acc);
  perform t_record('L0126-3: after unlocking, the same approval succeeds and posts exactly one balanced entry dated fn_branch_date(occurred_at). Same-day fixture: this does NOT distinguish expense day from approval day',
    (r->>'ok')::boolean and s2 like 'status=approved|%' and s2 like '%|je_exp=1|%'
    and (select entry_date from journal_entries where source_type = 'expense' and source_id = e) = d
    and (select coalesce(sum(l.debit_halalas),0) = coalesce(sum(l.credit_halalas),0) and sum(l.debit_halalas) = 600000
         from journal_lines l join journal_entries j on j.id = l.entry_id where j.source_type = 'expense' and j.source_id = e), s2);
exception when others then perform t_record('L0126 locked-month approval', false, sqlerrm);
end $$;
select name, case when ok then 'PASS' else 'FAIL' end as result, coalesce(detail, '') as detail from test_results order by ctid;
\set ON_ERROR_STOP on
do $$ begin
  if (select count(*) from test_results where name like 'L0126%' and ok) <> 3 or exists (select 1 from test_results where ok is not true) then raise exception 'EXPENSE LOCK 0126 TESTS FAILED OR INCOMPLETE'; end if;
end $$;
