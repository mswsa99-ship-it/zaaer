-- =====================================================================
-- Accounting stage, task A5 (GL*; migration 0065): the double entry. Every voucher, expense, platform payout, closing
-- difference and opening balance makes its balanced entry; the trial balance has no difference; the deposit is a
-- liability, never revenue; a locked month refuses every entry. Tried from outside the screens.
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
create or replace function t_count(p_sql text) returns bigint language plpgsql security definer as $$ declare n bigint; begin execute p_sql into n; return n; end $$;
create or replace function t_today(p uuid) returns date language sql security definer as $$ select fn_branch_today(p) $$;
create or replace function t_png() returns text language sql immutable as $$ select 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==' $$;
create or replace function t_accid(p_branch uuid, p_kind text) returns uuid language sql security definer as $$
  select id from cash_accounts where branch_id = p_branch and kind = p_kind and archived_at is null $$;
-- the balance of a chart account (by its fixed key or its code) in the given branch, debit-positive
create or replace function t_bal(p_branch uuid, p_account uuid) returns bigint language sql security definer as $$
  select coalesce(sum(l.debit_halalas - l.credit_halalas), 0)::bigint from journal_lines l join journal_entries e on e.id = l.entry_id
  where e.branch_id = p_branch and l.account_id = p_account $$;
create or replace function t_sys(p_key text) returns uuid language sql security definer as $$
  select id from gl_accounts where system_key = p_key and organization_id = (select organization_id from branches where id = '00000000-0000-0000-0000-000000000010') $$;
create or replace function t_glcash(p_cash uuid) returns uuid language sql security definer as $$ select id from gl_accounts where cash_account_id = p_cash $$;
-- an entry whose two sides differ, written straight through the posting function (as a buggy path would)
create or replace function t_unbalanced() returns void language plpgsql security definer as $$
begin
  perform fn_gl_post((select organization_id from branches where id = t_id('b')), t_id('b'), t_today(t_id('b')), 'voucher', gen_random_uuid(), 'post', 'غير متوازن',
                     jsonb_build_array(jsonb_build_object('account_id', t_sys('suspense'), 'debit', 100), jsonb_build_object('account_id', t_sys('rent_revenue'), 'credit', 90)));
  set constraints all immediate;
end $$;

-- ---------------------------------------------------------------- GL01 the matrix, GL02 the chart
select t_record('GL01 the permissions matrix has «accounts.view» (owner, manager, finance) and «accounts.close_month» (owner)',
  (select count(*) from fn_permission_catalog()) = 62
  and exists (select 1 from fn_permission_catalog() c where c.code = 'accounts.view' and c.default_roles = '{owner,manager,finance}')
  and exists (select 1 from fn_permission_catalog() c where c.code = 'accounts.close_month' and c.default_roles = '{owner}'));
select t_record('GL02 the chart is numbered by kind: the deposits (21) are a liability, the rent (41) revenue, the boxes under 111 and the banks under 112, opened on first use',
  (select type from gl_accounts where id = t_sys('deposits')) = 'liability' and (select code from gl_accounts where id = t_sys('deposits')) = '21'
  and (select type from gl_accounts where id = t_sys('rent_revenue')) = 'revenue' and (select code from gl_accounts where id = t_sys('rent_revenue')) = '41'
  and t_count('select count(*) from gl_accounts g join cash_accounts c on c.id = g.cash_account_id where c.kind = ''cash_box'' and g.code !~ ''^111[0-9]{2}$''') = 0
  and t_count('select count(*) from gl_accounts g join cash_accounts c on c.id = g.cash_account_id where c.kind = ''bank_account'' and g.code !~ ''^112[0-9]{2}$''') = 0
  and t_count('select count(*) from gl_accounts where cash_account_id is not null') > 0);

-- ---------------------------------------------------------------- GL03 what the other suites wrote is all in the journal
select t_record('GL03 every approved or cancelled voucher, every expense and every platform payout written by the other suites has its entry; every cancelled one its reversal',
  t_count('select count(*) from financial_vouchers v where v.status in (''approved'', ''cancelled'') and not exists (select 1 from journal_entries e where e.source_type = ''voucher'' and e.source_id = v.id and e.posting = ''post'')') = 0
  and t_count('select count(*) from financial_vouchers v where v.status = ''cancelled'' and not exists (select 1 from journal_entries e where e.source_type = ''voucher'' and e.source_id = v.id and e.reversal_of is not null)') = 0
  and t_count('select count(*) from financial_vouchers v where v.status = ''pending'' and exists (select 1 from journal_entries e where e.source_type = ''voucher'' and e.source_id = v.id)') = 0
  and t_count('select count(*) from expense_vouchers x where not exists (select 1 from journal_entries e where e.source_type = ''expense'' and e.source_id = x.id)') = 0
  and t_count('select count(*) from platform_payouts p where not exists (select 1 from journal_entries e where e.source_type = ''payout'' and e.source_id = p.id)') = 0
  and t_count('select count(*) from financial_vouchers') > 5 and t_count('select count(*) from platform_payouts') > 0,
  t_count('select count(*) from journal_entries') || ' entries');
select t_record('GL04 every entry in the journal balances (debit = credit, two lines at least), and no voucher of a deposit ever touches the rent revenue except applying it',
  t_count('select count(*) from (select entry_id from journal_lines group by entry_id having sum(debit_halalas) <> sum(credit_halalas) or count(*) < 2) x') = 0
  and t_count('select count(*) from journal_entries e where not exists (select 1 from journal_lines l where l.entry_id = e.id)') = 0
  and t_count('select count(*) from journal_entries e join financial_vouchers v on v.id = e.source_id and e.source_type = ''voucher'' join journal_lines l on l.entry_id = e.id
               where v.kind in (''deposit'', ''deposit_refund'') and l.account_id in (select id from gl_accounts where type = ''revenue'')') = 0
  and t_count('select count(*) from journal_entries e join financial_vouchers v on v.id = e.source_id and e.source_type = ''voucher'' and e.posting = ''post''
               where v.kind in (''deposit'', ''deposit_refund'', ''deposit_apply'') and not exists (select 1 from journal_lines l where l.entry_id = e.id and l.account_id in (select id from gl_accounts where system_key = ''deposits''))') = 0);
select t_record('GL05 a platform payout clears the platform''s receivable: the bank gets what arrived, the commission (0051) alone in 58, a gap from the net as shortage or other income',
  t_count('select count(*) from platform_payouts p where p.status = ''confirmed'' and p.commission_halalas > 0 and not exists (
             select 1 from journal_entries e join journal_lines l on l.entry_id = e.id where e.source_type = ''payout'' and e.source_id = p.id
             and l.account_id in (select id from gl_accounts where system_key = ''platform_commission'') and l.debit_halalas = p.commission_halalas)') = 0
  and t_count('select count(*) from platform_payouts p where p.status = ''confirmed'' and p.commission_halalas = 0 and exists (
             select 1 from journal_entries e join journal_lines l on l.entry_id = e.id where e.source_type = ''payout'' and e.source_id = p.id
             and l.account_id in (select id from gl_accounts where system_key = ''platform_commission''))') = 0
  and t_count('select count(*) from platform_payouts p where not exists (select 1 from journal_entries e join journal_lines l on l.entry_id = e.id join gl_accounts g on g.id = l.account_id
             where e.source_type = ''payout'' and e.source_id = p.id and g.source_id = p.source_id and l.credit_halalas = p.expected_halalas)') = 0);

select t_record('GL15 every sent closing whose counted cash differs from the system books exactly that difference to the box (shortage or overage), once, net of its amendments (an amended closing''s earlier difference is reversed)',
  t_count('select count(*) from day_closings c join day_closing_lines l on l.closing_id = c.id and l.line_key = ''cash''
           where c.status = ''submitted'' and l.account_id is not null
             and coalesce((select sum(jl.debit_halalas - jl.credit_halalas) from journal_entries e join journal_lines jl on jl.entry_id = e.id
                           where e.source_type = ''day_closing'' and e.source_id = c.id and jl.account_id = (select id from gl_accounts where cash_account_id = l.account_id)), 0) <> coalesce(l.difference_halalas, 0)') = 0
  and t_count('select count(*) from journal_entries where source_type = ''day_closing'' and reversal_of is not null') > 0,
  t_count('select count(*) from journal_entries where source_type = ''day_closing''') || ' closing entries');

-- ---------------------------------------------------------------- a branch of its own: rent, a deposit, a refund, an expense
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; b uuid; cat uuid; res uuid; v jsonb; begin
  r := fn_admin_upsert_branch('{"name_ar":"فرع القيود","name_en":"Journal branch","tax_rate_bp":0}'); b := (r->>'id')::uuid;
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', b, 'name_ar', 'غرفة القيود', 'base_price_halalas', 20000)); cat := (r->>'id')::uuid;
  perform fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', '901'));
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b, 'category_id', cat, 'check_in', (t_today(b) + 30)::text,
         'check_out', (t_today(b) + 32)::text, 'guest_phone', '0551000091', 'guest_name', 'نزيل القيود', 'source_id', '00000000-0000-0000-0000-000000000021'));
  res := (r->>'id')::uuid;
  insert into ids values ('b', b), ('res', res);
  v := fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind','receipt', 'amount_halalas', 30000, 'method','cash', 'idempotency_key','gl-1'));
  insert into ids values ('v1', (v->>'voucher_id')::uuid);
  perform fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind','receipt', 'amount_halalas', 8500, 'method','bank_transfer', 'reference','GL-TR-1', 'idempotency_key','gl-2'));
  v := fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind','deposit', 'amount_halalas', 5000, 'method','cash', 'idempotency_key','gl-3'));
  insert into ids values ('vdep', (v->>'voucher_id')::uuid);
  perform fn_refund(jsonb_build_object('reservation_id', res, 'kind','deposit_apply', 'amount_halalas', 1500, 'reason','تغطية من التأمين', 'idempotency_key','gl-4'));
  r := fn_expense_create(jsonb_build_object('branch_id', b, 'account_id', t_accid(b, 'cash_box'), 'category_id',
         (select id from expense_categories where name = 'صيانة وإصلاح' and organization_id = fn_user_org_id()),
         'amount_halalas', 4500, 'description', 'قطع غيار', 'attachments', jsonb_build_array(jsonb_build_object('data_base64', t_png()))));
  insert into ids values ('e1', (r->>'id')::uuid);
exception when others then perform t_record('GL00 the branch and its money are set up', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- GL06 the balances of the branch
do $$ declare tb jsonb; inc jsonb; bs jsonb; b uuid := t_id('b'); cash bigint; dep bigint; rev bigint; begin
  cash := t_bal(b, t_glcash(t_accid(b, 'cash_box')));
  dep := -t_bal(b, t_sys('deposits'));
  rev := -t_bal(b, t_sys('rent_revenue'));
  tb := fn_trial_balance(t_today(b) - 1, t_today(b), b);
  inc := fn_income_statement(t_today(b) - 1, t_today(b), b);
  bs := fn_balance_sheet(t_today(b), b);
  perform t_record('GL06 the branch''s books: the box holds 30000 + 5000 − 4500, the deposit is a liability of 5000 − 1500 (applied to the rent), the rent revenue 38500 + 1500; the trial balance, the income statement and the balance sheet agree with no difference',
    cash = 30500 and dep = 3500 and rev = 40000
    and (tb->>'difference_halalas')::bigint = 0 and (tb->>'total_debit_halalas')::bigint > 0
    and (inc->>'revenue_halalas')::bigint = 40000 and (inc->>'expenses_halalas')::bigint = 4500 and (inc->>'net_income_halalas')::bigint = 35500
    and (bs->>'difference_halalas')::bigint = 0 and (bs->>'assets_halalas')::bigint = 39000 and (bs->>'liabilities_halalas')::bigint = 3500 and (bs->>'retained_income_halalas')::bigint = 35500,
    concat_ws(' / ', cash, dep, rev, tb->>'difference_halalas', inc->>'net_income_halalas', bs->>'difference_halalas'));
exception when others then perform t_record('GL06 the branch''s books: the box holds 30000 + 5000 − 4500, the deposit is a liability of 5000 − 1500 (applied to the rent), the rent revenue 38500 + 1500; the trial balance, the income statement and the balance sheet agree with no difference', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- GL07 cancellations reverse, the opening balance reposts
do $$ declare b uuid := t_id('b'); box uuid; n int; st jsonb; begin
  box := t_accid(b, 'cash_box');
  perform fn_cancel_voucher(t_id('v1'), 'سند خاطئ');
  perform fn_expense_cancel(t_id('e1'), 'مكرر');
  perform fn_admin_set_account_opening(box, 20000, t_today(b) - 3, 'الرصيد عند البدء');
  perform fn_admin_set_account_opening(box, 25000, t_today(b) - 3, 'تصحيح العدّ');
  select count(*) into n from journal_entries where source_type = 'opening' and source_id = box;
  st := fn_account_statement(t_glcash(box), t_today(b) - 5, t_today(b), b);
  perform t_record('GL07 a cancelled voucher and a cancelled expense are reversed (never erased), and a changed opening balance is reversed and booked again: the box ends at 25000 + 5000 (the rent and the expense gone); its statement runs to that',
    t_bal(b, t_glcash(box)) = 30000 and n = 3 and -t_bal(b, t_sys('opening')) = 25000
    and t_count(format('select count(*) from journal_entries where source_id = %L and reversal_of is not null', t_id('v1'))) = 1
    and t_count(format('select count(*) from journal_entries where source_id = %L and reversal_of is not null', t_id('e1'))) = 1
    and (st->'lines'->-1->>'balance_halalas')::bigint = 30000 and (st->>'opening_halalas')::bigint = 0,
    concat_ws(' / ', t_bal(b, t_glcash(box)), n, st->'lines'->-1->>'balance_halalas'));
exception when others then perform t_record('GL07 a cancelled voucher and a cancelled expense are reversed (never erased), and a changed opening balance is reversed and booked again: the box ends at 25000 + 5000 (the rent and the expense gone); its statement runs to that', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- GL08 the database refuses an unbalanced entry and any direct write
do $$ declare r1 text; begin
  r1 := t_fails('select t_unbalanced()', 'JOURNAL_UNBALANCED%');
  perform t_record('GL08 an unbalanced entry is refused by the database itself, whatever path writes it', r1 = 'ok', r1);
end $$;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r1 text; r2 text; r3 text; begin
  r1 := t_fails(format('insert into journal_entries(organization_id, number, entry_date, source_type, source_id, posting, description) values (fn_user_org_id(), %L, current_date, %L, gen_random_uuid(), %L, %L)', 'JE-X', 'voucher', 'post', 'x'), '%permission denied%');
  r2 := t_fails('update journal_lines set debit_halalas = debit_halalas + 1', '%permission denied%');
  r3 := t_fails('select fn_gl_post(null, null, null, null, null, null, null, null)', '%permission denied%');
  perform t_record('GL09 even the owner cannot write, change or post an entry directly: only the vouchers, expenses, payouts, closings and openings make them',
    r1 = 'ok' and r2 = 'ok' and r3 = 'ok', concat_ws(' / ', r1, r2, r3));
end $$;

-- ---------------------------------------------------------------- GL10 the month lock
do $$ declare b uuid := t_id('b'); res uuid := t_id('res'); r1 text; r2 text; r3 text; r4 text; r5 text; n0 bigint; ok jsonb; begin
  r5 := t_fails(format('select fn_accounting_lock_month(%L, true, %L)', t_today(b), ''), 'VALIDATION: reason%');
  perform fn_accounting_lock_month(t_today(b), true, 'إقفال الشهر بعد المراجعة');
  select count(*) into n0 from financial_vouchers where reservation_id = res;
  r1 := t_fails(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id', res, 'kind','receipt', 'amount_halalas', 700, 'method','cash', 'idempotency_key','gl-lock-1')), 'PERIOD_LOCKED%');
  r2 := t_fails(format('select fn_expense_create(%L::jsonb)', jsonb_build_object('branch_id', b, 'account_id', t_accid(b, 'cash_box'),
          'category_id', (select id from expense_categories where name = 'صيانة وإصلاح' and organization_id = fn_user_org_id()),
          'amount_halalas', 300, 'description', 'بعد القفل', 'attachments', jsonb_build_array(jsonb_build_object('data_base64', t_png())))), 'PERIOD_LOCKED%');
  r3 := t_fails(format('select fn_cancel_voucher(%L, %L)', t_id('vdep'), 'بعد القفل'), 'PERIOD_LOCKED%');
  r4 := t_fails(format('select fn_accounting_lock_month(%L, true, %L)', t_today(b) + 40, 'شهر قادم'), 'VALIDATION: month%');
  perform t_record('GL10 the owner locks the month: a voucher, an expense and a cancellation dated in it are refused and nothing is written; a future month cannot be locked, nor without a reason',
    r1 = 'ok' and r2 = 'ok' and r3 = 'ok' and r4 = 'ok' and r5 = 'ok'
    and (select count(*) from financial_vouchers where reservation_id = res) = n0
    and (select status from financial_vouchers where id = t_id('vdep')) = 'approved'
    and fn_trial_balance(t_today(b), t_today(b), b)->'locked_months' ? to_char(t_today(b), 'YYYY-MM'),
    concat_ws(' / ', r1, r2, r3, r4, r5));
  perform fn_accounting_lock_month(t_today(b), false, 'تصحيح سند متأخر');
  ok := fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind','receipt', 'amount_halalas', 700, 'method','cash', 'idempotency_key','gl-lock-2'));
  perform t_record('GL11 the owner opens it again with a reason (both recorded in the log), and the voucher is accepted',
    ok->>'voucher_id' is not null and exists (select 1 from accounting_periods where month = date_trunc('month', t_today(b))::date and not locked)
    and t_count('select count(*) from audit_events where action in (''accounting.month_locked'', ''accounting.month_opened'')') >= 2);
exception when others then perform t_record('GL10 the owner locks the month: a voucher, an expense and a cancellation dated in it are refused and nothing is written; a future month cannot be locked, nor without a reason', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- GL16 the journal agrees with the ledger; GL17 a correction keeps the day and its lock
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare b uuid := t_id('b'); box uuid; led jsonb; begin
  box := t_accid(b, 'cash_box');
  led := fn_account_ledger(box, t_today(b) - 3, t_today(b));
  perform t_record('GL16 the box in the journal stands where its ledger (0064) ends: the opening balance is what was counted on its day',
    (led->>'closing_halalas')::bigint = t_bal(b, t_glcash(box)), (led->>'closing_halalas') || ' / ' || t_bal(b, t_glcash(box)));
exception when others then perform t_record('GL16 the box in the journal stands where its ledger (0064) ends: the opening balance is what was counted on its day', false, sqlerrm);
end $$;
do $$ declare v jsonb; begin
  v := fn_create_voucher(jsonb_build_object('reservation_id', t_id('res'), 'kind','receipt', 'amount_halalas', 600, 'method','cash', 'idempotency_key','gl-old-1'));
  insert into ids values ('vold', (v->>'voucher_id')::uuid);
end $$;
reset role;
-- the voucher belongs to a day of an earlier month (as an older voucher would)
update financial_vouchers set occurred_at = occurred_at - interval '40 days' where id = t_id('vold');
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare b uuid := t_id('b'); d date; r1 text; nb int; begin
  d := t_today(b) - 40;
  perform fn_accounting_lock_month(d, true, 'شهر سابق مراجَع');
  select count(*) into nb from journal_entries where source_id = t_id('vold');
  r1 := t_fails(format('select fn_staff_correct_voucher(%L::jsonb)', jsonb_build_object('voucher_id', t_id('vold'), 'amount_halalas', 500, 'reason', 'المبلغ الصحيح', 'idempotency_key', 'gl-old-2')), 'PERIOD_LOCKED%');
  perform t_record('GL17 a voucher whose day moved is booked again on its day (reversed today), and correcting a voucher of a locked month is refused: the replacement keeps the locked day',
    r1 = 'ok' and nb = 3
    and t_count(format('select count(*) from journal_entries where source_id = %L and reversal_of is null and entry_date = %L', t_id('vold'), d)) = 1
    and (select status from financial_vouchers where id = t_id('vold')) = 'approved', concat_ws(' / ', r1, nb));
  perform fn_accounting_lock_month(d, false, 'انتهت المراجعة');
exception when others then perform t_record('GL17 a voucher whose day moved is booked again on its day (reversed today), and correcting a voucher of a locked month is refused: the replacement keeps the locked day', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- GL12 who reads the books
insert into branch_memberships(staff_id, branch_id) select s, t_id('b') from unnest(array['10000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000004']::uuid[]) s
  where not exists (select 1 from branch_memberships where staff_id = s and branch_id = t_id('b'));
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
set role authenticated;
do $$ declare r1 text; r2 text; r3 text; begin
  r1 := t_fails(format('select fn_trial_balance(%L, %L, %L)', t_today(t_id('b')) - 1, t_today(t_id('b')), t_id('b')), 'FORBIDDEN%');
  r2 := t_fails(format('select fn_accounting_lock_month(%L, true, %L)', t_today(t_id('b')), 'محاولة'), 'FORBIDDEN%');
  perform t_record('GL12 the supervisor reads no journal, no trial balance, and locks no month',
    r1 = 'ok' and r2 = 'ok' and (select count(*) from journal_entries) = 0 and (select count(*) from journal_lines) = 0 and (select count(*) from gl_accounts) = 0,
    concat_ws(' / ', r1, r2));
end $$;
reset role;
select t_login('a0000000-0000-0000-0000-000000000004', 'fin@test.local');
set role authenticated;
do $$ declare tb jsonb; r1 text; begin
  tb := fn_trial_balance(t_today(t_id('b')) - 1, t_today(t_id('b')), null);
  r1 := t_fails(format('select fn_accounting_lock_month(%L, true, %L)', t_today(t_id('b')), 'محاولة'), 'FORBIDDEN%');
  perform t_record('GL13 finance reads the trial balance of its branches (no difference) and the journal, but cannot lock a month',
    (tb->>'difference_halalas')::bigint = 0 and jsonb_array_length(tb->'rows') > 0 and r1 = 'ok' and (select count(*) from journal_entries) > 0, r1);
exception when others then perform t_record('GL13 finance reads the trial balance of its branches (no difference) and the journal, but cannot lock a month', false, sqlerrm);
end $$;
reset role;
select t_record('GL14 the accounts'' log lines read in Arabic', fn_audit_action_label('accounting.month_locked') = 'قفل شهر محاسبي'
  and fn_audit_entity_label('accounting_period') = 'شهر محاسبي' and fn_audit_entity_label('expense_voucher') = 'سند صرف');

select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),160) as detail from test_results order by ok nulls first, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from test_results where ok is not true) then raise exception 'ACCOUNTING A5 TESTS FAILED'; end if;
  if (select count(*) from test_results) < 17 then raise exception 'ACCOUNTING A5 TESTS INCOMPLETE: % of 17 checks ran', (select count(*) from test_results); end if;
end $$;
