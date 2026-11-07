-- =====================================================================
-- Accounting stage, task A4 (EX*; migration 0064): the expense voucher with its category and its receipt, cancelled only
-- with a reason by the management; the ledger of each box and bank account with its opening balance and, on every line,
-- the running balance = opening + in − out; and the day's closing counting the expenses. Tried from outside the screens.
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
create or replace function t_closing(p uuid) returns day_closings language sql security definer as $$ select * from day_closings where id = p $$;
create or replace function t_count(p_sql text) returns bigint language plpgsql security definer as $$ declare n bigint; begin execute p_sql into n; return n; end $$;
create or replace function t_today(p uuid) returns date language sql security definer as $$ select fn_branch_today(p) $$;
-- what a script could compute itself from what it reads: the md5 of the day's money (no review token)
create or replace function t_forge(p uuid) returns text language sql security definer as $$
  select fn_day_closing_summary_hash(fn_day_closing_compute(c.branch_id, c.business_date), fn_day_closing_lines_json(c.id)) from day_closings c where c.id = p $$;
-- the window passing, as time would
create or replace function t_expire(p uuid) returns void language sql security definer as $$ update day_closings set edit_until = now() - interval '1 minute' where id = p $$;


create or replace function t_png() returns text language sql immutable as $$ select 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==' $$;
create or replace function t_accid(p_branch uuid, p_kind text) returns uuid language sql security definer as $$
  select id from cash_accounts where branch_id = p_branch and kind = p_kind and archived_at is null $$;

-- ---------------------------------------------------------------- EX01 the matrix
select t_record('EX01 the permissions matrix has «expense.create» (owner, manager, supervisor, finance), «expense.cancel» (owner, manager), «ledger.view» (owner, manager, supervisor, finance)',
  (select count(*) from fn_permission_catalog()) = 60
  and exists (select 1 from fn_permission_catalog() c where c.code = 'expense.create' and c.default_roles = '{owner,manager,supervisor,finance}')
  and exists (select 1 from fn_permission_catalog() c where c.code = 'expense.cancel' and c.default_roles = '{owner,manager}')
  and exists (select 1 from fn_permission_catalog() c where c.code = 'ledger.view' and c.default_roles = '{owner,manager,supervisor,finance}'));

-- ---------------------------------------------------------------- a branch of its own with money in its boxes
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; b uuid; cat uuid; res uuid; begin
  r := fn_admin_upsert_branch('{"name_ar":"فرع المصروفات","name_en":"Expenses branch","tax_rate_bp":0}'); b := (r->>'id')::uuid;
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', b, 'name_ar', 'غرفة المصروفات', 'base_price_halalas', 20000)); cat := (r->>'id')::uuid;
  perform fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', '801'));
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b, 'category_id', cat, 'check_in', (t_today(b) + 30)::text,
         'check_out', (t_today(b) + 32)::text, 'guest_phone', '0551000081', 'guest_name', 'نزيل المصروفات', 'source_id', '00000000-0000-0000-0000-000000000021'));
  res := (r->>'id')::uuid;
  insert into ids values ('b', b), ('res', res);
  perform fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind','receipt', 'amount_halalas', 30000, 'method','cash', 'idempotency_key','ex-1'));
  perform fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind','receipt', 'amount_halalas', 10000, 'method','bank_transfer', 'reference','EX-TR-1', 'idempotency_key','ex-2'));
exception when others then perform t_record('EX00 the branch and its money are set up', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- EX02 the categories are the owner's list
do $$ declare r jsonb; dup text; begin
  r := fn_admin_upsert_expense_category(jsonb_build_object('name', 'غاز'));
  dup := t_fails(format('select fn_admin_upsert_expense_category(%L::jsonb)', jsonb_build_object('name', 'صيانة وإصلاح')), 'DUPLICATE_NAME%');
  insert into ids values ('cat', (select id from expense_categories where name = 'صيانة وإصلاح' and organization_id = fn_user_org_id()));
  perform t_record('EX02 the expense categories are seeded and are the owner''s list: one added, a duplicate name refused',
    dup = 'ok' and (select count(*) from expense_categories where organization_id = fn_user_org_id()) >= 9, dup);
exception when others then perform t_record('EX02 the expense categories are seeded and are the owner''s list: one added, a duplicate name refused', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- EX03–EX04 the supervisor writes an expense
insert into branch_memberships(staff_id, branch_id) select '10000000-0000-0000-0000-000000000002', t_id('b')
  where not exists (select 1 from branch_memberships where staff_id = '10000000-0000-0000-0000-000000000002' and branch_id = t_id('b'));
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
set role authenticated;
do $$ declare base jsonb; r jsonb; again jsonb; nofile text; badtype text; other text; future text; cats text; begin
  base := jsonb_build_object('branch_id', t_id('b'), 'account_id', t_accid(t_id('b'), 'cash_box'), 'category_id', t_id('cat'),
                             'amount_halalas', 4500, 'description', 'قطع غيار للمكيف', 'payee', 'محل التبريد');
  nofile := t_fails(format('select fn_expense_create(%L::jsonb)', base), 'VALIDATION: attachment_required%');
  badtype := t_fails(format('select fn_expense_create(%L::jsonb)', base || jsonb_build_object('attachments', jsonb_build_array(jsonb_build_object('data_base64', encode('hello'::bytea, 'base64'))))), 'VALIDATION: attachment_type%');
  other := t_fails(format('select fn_expense_create(%L::jsonb)', base || jsonb_build_object('account_id', t_accid('00000000-0000-0000-0000-000000000010', 'cash_box'),
                   'attachments', jsonb_build_array(jsonb_build_object('data_base64', t_png())))), 'BRANCH_MISMATCH%');
  future := t_fails(format('select fn_expense_create(%L::jsonb)', base || jsonb_build_object('occurred_on', t_today(t_id('b')) + 1,
                   'attachments', jsonb_build_array(jsonb_build_object('data_base64', t_png())))), 'VALIDATION: occurred_on%');
  cats := t_fails(format('select fn_admin_upsert_expense_category(%L::jsonb)', jsonb_build_object('name', 'تصنيف المشرف')), 'FORBIDDEN%');
  r := fn_expense_create(base || jsonb_build_object('idempotency_key', 'ex-exp-1', 'attachments', jsonb_build_array(jsonb_build_object('data_base64', t_png(), 'file_name', 'فاتورة.png'))));
  again := fn_expense_create(base || jsonb_build_object('idempotency_key', 'ex-exp-1', 'attachments', jsonb_build_array(jsonb_build_object('data_base64', t_png()))));
  insert into ids values ('e1', (r->>'id')::uuid);
  perform t_record('EX03 an expense needs its receipt (image or PDF), its branch''s account and a past day; it is numbered EXP and written once per key; the supervisor cannot edit the categories',
    nofile = 'ok' and badtype = 'ok' and other = 'ok' and future = 'ok' and cats = 'ok' and r->>'number' like 'EXP-%'
    and (again->>'replayed')::boolean and again->>'id' = r->>'id'
    and t_count(format('select count(*) from expense_attachments where expense_id = %L and mime = ''image/png''', r->>'id')) = 1,
    concat_ws(' / ', nofile, badtype, other, future, cats));
exception when others then perform t_record('EX03 an expense needs its receipt (image or PDF), its branch''s account and a past day; it is numbered EXP and written once per key; the supervisor cannot edit the categories', false, sqlerrm);
end $$;
do $$ declare r jsonb; nocancel text; l jsonb; f jsonb; begin
  r := fn_expense_create(jsonb_build_object('branch_id', t_id('b'), 'account_id', t_accid(t_id('b'), 'bank_account'), 'category_id', t_id('cat'),
         'amount_halalas', 2000, 'description', 'رسوم تحويل', 'reference', 'BNK-77', 'attachments', jsonb_build_array(jsonb_build_object('data_base64', t_png()))));
  insert into ids values ('e2', (r->>'id')::uuid);
  nocancel := t_fails(format('select fn_expense_cancel(%L, %L)', t_id('e1'), 'خطأ'), 'FORBIDDEN%');
  l := fn_expense_list(t_id('b'), t_today(t_id('b')) - 1, t_today(t_id('b')));
  f := fn_expense_attachment((l->0->'attachments'->0->>'id')::uuid);
  perform t_record('EX04 the supervisor lists the expenses with their files and reads a file; cancelling is the management''s',
    nocancel = 'ok' and jsonb_array_length(l) = 2 and f->>'mime' = 'image/png' and length(f->>'data_base64') > 20, nocancel);
exception when others then perform t_record('EX04 the supervisor lists the expenses with their files and reads a file; cancelling is the management''s', false, sqlerrm);
end $$;
-- the closing of the day counts the cash expenses: cash 300.00 − 45.00; the bank expense is shown, the transfers stay 100.00
do $$ declare g jsonb; begin
  g := fn_day_closing_get(t_id('b'), t_today(t_id('b')));
  perform t_record('EX05 the day''s closing subtracts the expenses from the cash box (300.00 − 45.00) and shows the bank expense (20.00) without changing the transfers (100.00)',
    (select (b->>'system_halalas')::bigint from jsonb_array_elements(g->'live'->'boxes') b where b->>'key' = 'cash') = 25500
    and (select (b->>'system_halalas')::bigint from jsonb_array_elements(g->'live'->'boxes') b where b->>'key' = 'bank_transfer') = 10000
    and (g->'live'->'expenses'->>'bank_transfer')::bigint = 2000
    and (g->'live'->'expenses'->>'count')::int = 2, g->'live'->>'boxes');
exception when others then perform t_record('EX05 the day''s closing subtracts the expenses from the cash box (300.00 − 45.00) and shows the bank expense (20.00) without changing the transfers (100.00)', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- EX12 a cash expense on a day whose closing was sent is the management's
insert into day_closings(organization_id, branch_id, business_date, status, figures, submitted_at, edit_until)
select organization_id, id, fn_branch_today(id) - 2, 'submitted', '{"boxes": []}'::jsonb, now(), now() from branches where id = t_id('b');
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
set role authenticated;
do $$ declare r text; begin
  r := t_fails(format('select fn_expense_create(%L::jsonb)', jsonb_build_object('branch_id', t_id('b'), 'account_id', t_accid(t_id('b'), 'cash_box'), 'category_id', t_id('cat'),
         'amount_halalas', 1000, 'description', 'مصروف متأخر', 'occurred_on', t_today(t_id('b')) - 2, 'attachments', jsonb_build_array(jsonb_build_object('data_base64', t_png())))), 'CLOSING_SENT_DAY%');
  perform t_record('EX12 the supervisor cannot date a cash expense on a day whose closing was sent', r = 'ok', r);
end $$;
reset role;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; begin
  r := fn_expense_create(jsonb_build_object('branch_id', t_id('b'), 'account_id', t_accid(t_id('b'), 'cash_box'), 'category_id', t_id('cat'),
         'amount_halalas', 1000, 'description', 'مصروف متأخر', 'occurred_on', t_today(t_id('b')) - 2, 'attachments', jsonb_build_array(jsonb_build_object('data_base64', t_png()))));
  perform t_record('EX12b the owner can, and it goes to «بحاجة لمراجعة»',
    t_count(format('select count(*) from review_items where entity_id = %L and kind = ''expense_after_closing''', r->>'id')) = 1, r::text);
exception when others then perform t_record('EX12b the owner can, and it goes to «بحاجة لمراجعة»', false, sqlerrm); end $$;
reset role;

-- ---------------------------------------------------------------- EX06–EX07 the owner cancels, sets the opening, reads the ledger
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare noreason text; r jsonb; begin
  noreason := t_fails(format('select fn_expense_cancel(%L, %L)', t_id('e2'), ' '), 'VALIDATION: reason%');
  r := fn_expense_cancel(t_id('e2'), 'سُجّل مرتين');
  perform t_record('EX06 the owner cancels an expense only with a reason; it is recorded and sent to «بحاجة لمراجعة»',
    noreason = 'ok' and (select status from expense_vouchers where id = t_id('e2')) = 'cancelled'
    and t_count(format('select count(*) from review_items where entity_id = %L and kind = ''expense_cancelled''', t_id('e2'))) = 1
    and t_count(format('select count(*) from audit_events where entity_id = %L and action = ''expense.cancelled''', t_id('e2'))) = 1, noreason);
exception when others then perform t_record('EX06 the owner cancels an expense only with a reason; it is recorded and sent to «بحاجة لمراجعة»', false, sqlerrm);
end $$;
do $$ declare l jsonb; bad int; cash jsonb; bank jsonb; noreason text; begin
  noreason := t_fails(format('select fn_admin_set_account_opening(%L, 50000, %L, null)', t_accid(t_id('b'), 'cash_box'), t_today(t_id('b')) - 1), 'VALIDATION: reason%');
  perform fn_admin_set_account_opening(t_accid(t_id('b'), 'cash_box'), 50000, t_today(t_id('b')) - 1, 'رصيد الصندوق عند بدء النظام');
  cash := fn_account_ledger(t_accid(t_id('b'), 'cash_box'), t_today(t_id('b')) - 7, t_today(t_id('b')));
  bank := fn_account_ledger(t_accid(t_id('b'), 'bank_account'), t_today(t_id('b')) - 7, t_today(t_id('b')));
  -- every line: balance = opening + all in − all out up to that line
  select count(*) into bad from (
    select (x->>'balance_halalas')::bigint as bal,
           (cash->>'opening_halalas')::bigint + sum((x->>'in_halalas')::bigint - (x->>'out_halalas')::bigint) over (order by o) as expect
    from jsonb_array_elements(cash->'lines') with ordinality t(x, o)) q where bal <> expect;
  perform t_record('EX07 the ledger: opening 500.00 (set with its date and reason), every line''s running balance = opening + in − out, closing 755.00; the cancelled expense is no movement',
    noreason = 'ok' and bad = 0 and (cash->>'opening_halalas')::bigint = 50000 and jsonb_array_length(cash->'lines') = 2
    and (cash->>'closing_halalas')::bigint = 75500 and (cash->>'closing_halalas')::bigint = (cash->>'opening_halalas')::bigint + (cash->>'in_halalas')::bigint - (cash->>'out_halalas')::bigint
    and jsonb_array_length(bank->'lines') = 1 and (bank->>'closing_halalas')::bigint = 10000,
    concat_ws(' / ', noreason, bad, cash->>'closing_halalas', bank->>'closing_halalas'));
exception when others then perform t_record('EX07 the ledger: opening 500.00 (set with its date and reason), every line''s running balance = opening + in − out, closing 755.00; the cancelled expense is no movement', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- EX08 housekeeping sees none of it; the files are not readable directly
select t_login('a0000000-0000-0000-0000-000000000003', 'hk@test.local');
set role authenticated;
do $$ declare r1 text; r2 text; begin
  r1 := t_fails(format('select fn_account_ledger(%L, current_date - 1, current_date)', t_accid('00000000-0000-0000-0000-000000000010', 'cash_box')), 'FORBIDDEN%');
  r2 := t_fails('select count(*) from expense_attachments', '%permission denied%');
  perform t_record('EX08 housekeeping cannot read the ledger or the expenses; nobody reads the files except through the expense''s branch',
    r1 = 'ok' and r2 = 'ok' and (select count(*) from expense_vouchers) = 0, concat_ws(' / ', r1, r2));
end $$;
reset role;
select t_record('EX09 the expenses'' log lines read in Arabic', fn_audit_action_label('expense.cancelled') = 'إلغاء سند صرف'
  and fn_audit_entity_label('expense_voucher') = 'سند صرف' and fn_audit_entity_label('day_closing') = 'إقفال يوم');

select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),160) as detail from test_results order by ok nulls first, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from test_results where ok is not true) then raise exception 'ACCOUNTING A4 TESTS FAILED'; end if;
  if (select count(*) from test_results) < 11 then raise exception 'ACCOUNTING A4 TESTS INCOMPLETE: % of 11 checks ran', (select count(*) from test_results); end if;
end $$;
