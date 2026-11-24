-- 0105 opening-balance anomaly regression. Synthetic fixtures only, rolled back.
-- Run after security_tests.sql and core_tests.sql (the normal SQL runner order).
\set ON_ERROR_STOP on
begin;
create temp table opening_results(name text primary key, ok boolean not null);
create temp table opening_ids(k text primary key, id uuid);
grant all on opening_results, opening_ids to public;
create or replace function pg_temp.opening_login(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid)::text, false);
end $$;
select pg_temp.opening_login('a0000000-0000-0000-0000-000000000001');
set local role authenticated;
do $$ declare r jsonb; b uuid; begin
  r := fn_admin_upsert_branch('{"name_ar":"فرع اختبار افتتاحي","name_en":"Opening regression"}');
  b := (r->>'id')::uuid;
  insert into opening_ids values ('branch', b);
  insert into opening_ids select kind, id from cash_accounts where branch_id = b;
  r := fn_admin_upsert_expense_category('{"name":"مصروف اختبار افتتاحي"}');
  insert into opening_ids values ('expense_category', (r->>'id')::uuid);
end $$;
-- Initial negative import: exact review kind/entity, balance details, tenant and manager audience.
do $$ declare box uuid := (select id from opening_ids where k = 'cash_box'); b uuid := (select id from opening_ids where k = 'branch'); r jsonb; begin
  r := fn_admin_set_account_opening(box, -50000, fn_branch_today(b), 'اختبار استيراد افتتاحي');
  insert into opening_results values ('OPEN-01 negative import succeeds and creates one scoped review',
    (r->>'ok')::boolean and (select count(*) = 1 from review_items
      where kind = 'negative_cash_box' and entity_type = 'cash_account' and entity_id = box
      and branch_id = b and organization_id = fn_user_org_id() and reviewed_at is null
      and details->>'balance_halalas' = '-50000' and details->>'by_opening_set' = 'true'));
  insert into opening_results values ('OPEN-02 immediate manager alert is in the same branch and hotel',
    (select count(*) = 1 from notifications where branch_id = b and organization_id = fn_user_org_id()
      and audience = 'manager' and title like 'شذوذ مالي:%'));
  insert into opening_results values ('OPEN-03 ordinary opening review and audit still exist',
    exists(select 1 from review_items where entity_id = box and kind = 'account_opening_set')
    and exists(select 1 from audit_events where entity_id = box and action = 'cash_account.opening_set'));
  perform fn_admin_set_account_opening(box, -60000, fn_branch_today(b), 'إعادة استيراد سالب');
  perform fn_admin_set_account_opening(box, -60000, fn_branch_today(b), 'تكرار الاستيراد');
  insert into opening_results values ('OPEN-04 repeat imports do not duplicate the open anomaly or alert',
    (select count(*) = 1 from review_items where entity_id = box and kind = 'negative_cash_box' and reviewed_at is null)
    and (select count(*) = 1 from notifications where branch_id = b and audience = 'manager' and title like 'شذوذ مالي:%'));
end $$;
-- Review closure permits a later anomaly, while zero/positive balance does not alert.
reset role;
update review_items set reviewed_at = now(), reviewed_by = '10000000-0000-0000-0000-000000000001'
  where entity_id = (select id from opening_ids where k = 'cash_box') and kind = 'negative_cash_box';
set local role authenticated;
do $$ declare box uuid := (select id from opening_ids where k = 'cash_box'); b uuid := (select id from opening_ids where k = 'branch'); bank uuid := (select id from opening_ids where k = 'bank_account'); begin
  perform fn_admin_set_account_opening(box, 0, fn_branch_today(b), 'رصيد صفر');
  perform fn_admin_set_account_opening(box, 10000, fn_branch_today(b), 'رصيد موجب');
  perform fn_admin_set_account_opening(bank, -50000, fn_branch_today(b), 'حساب بنكي سالب ليس صندوقا');
  insert into opening_results values ('OPEN-05 zero, positive, and bank opening do not create cash-box alerts',
    not exists(select 1 from review_items where entity_id in (box, bank) and kind = 'negative_cash_box' and reviewed_at is null)
    and (select count(*) = 1 from notifications where branch_id = b and title like 'شذوذ مالي:%'));
  perform fn_admin_set_account_opening(box, -1, fn_branch_today(b), 'حالة جديدة بعد المراجعة');
  insert into opening_results values ('OPEN-06 later negative import after review creates one new anomaly and alert',
    (select count(*) = 2 from review_items where entity_id = box and kind = 'negative_cash_box')
    and (select count(*) = 1 from review_items where entity_id = box and kind = 'negative_cash_box' and reviewed_at is null)
    and (select count(*) = 2 from notifications where branch_id = b and title like 'شذوذ مالي:%'));
  perform fn_admin_set_account_opening(box, 10000, fn_branch_today(b), 'تمويل مصروف اختباري');
  perform fn_expense_create(jsonb_build_object('branch_id', b, 'account_id', box,
    'category_id', (select id from opening_ids where k = 'expense_category'), 'amount_halalas', 7000,
    'description', 'مصروف اختبار الرصيد الفعلي', 'idempotency_key', 'opening-regression-expense',
    'attachments', jsonb_build_array(jsonb_build_object('file_name', 'receipt.png',
      'data_base64', 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='))));
end $$;
reset role;
update review_items set reviewed_at = now(), reviewed_by = '10000000-0000-0000-0000-000000000001'
  where entity_id = (select id from opening_ids where k = 'cash_box') and kind = 'negative_cash_box' and reviewed_at is null;
set local role authenticated;
do $$ declare box uuid := (select id from opening_ids where k = 'cash_box'); b uuid := (select id from opening_ids where k = 'branch'); begin
  perform fn_admin_set_account_opening(box, 5000, fn_branch_today(b), 'افتتاحي موجب برصيد فعلي سالب');
  insert into opening_results values ('OPEN-07 positive opening with posted expense detects actual negative balance',
    exists(select 1 from review_items where entity_id = box and kind = 'negative_cash_box' and reviewed_at is null
      and details->>'balance_halalas' = '-2000')
    and (select count(*) = 3 from notifications where branch_id = b and title like 'شذوذ مالي:%'));
end $$;
-- Owner B creates a separate box. Owner A cannot update it or create reviews/alerts there.
reset role;
select pg_temp.opening_login('a0000000-0000-0000-0000-000000000005');
set local role authenticated;
do $$ declare r jsonb; b uuid; begin
  r := fn_admin_upsert_branch('{"name_ar":"فرع عزل افتتاحي","name_en":"Opening isolation"}');
  b := (r->>'id')::uuid;
  insert into opening_ids values ('branch_b', b);
  insert into opening_ids select 'box_b', id from cash_accounts where branch_id = b and kind = 'cash_box';
end $$;
select pg_temp.opening_login('a0000000-0000-0000-0000-000000000001');
do $$ declare box uuid := (select id from opening_ids where k = 'box_b'); b uuid := (select id from opening_ids where k = 'branch_b'); refused boolean := false; begin
  begin
    perform fn_admin_set_account_opening(box, -50000, current_date, 'محاولة عابرة للفنادق');
  exception when others then
    refused := sqlerrm = 'NOT_FOUND' or sqlerrm like 'FORBIDDEN:%';
  end;
  insert into opening_results values ('OPEN-08 another hotel opening update is refused', refused);
  insert into opening_results values ('OPEN-09 foreign hotel cash/reviews/alerts are invisible',
    not exists(select 1 from cash_accounts where id = box)
    and not exists(select 1 from review_items where branch_id = b)
    and not exists(select 1 from notifications where branch_id = b));
end $$;
reset role;
do $$ declare b uuid := (select id from opening_ids where k = 'branch_b'); box uuid := (select id from opening_ids where k = 'box_b'); begin
  insert into opening_results values ('OPEN-10 rejected cross-hotel import writes nothing (privileged invariant)',
    (select opening_balance_halalas = 0 and opening_on is null from cash_accounts where id = box)
    and not exists(select 1 from review_items where branch_id = b)
    and not exists(select 1 from notifications where branch_id = b)
    and not exists(select 1 from audit_events where entity_id = box and action = 'cash_account.opening_set'));
end $$;
-- The second owner can use their own account and receives only their own anomaly.
select pg_temp.opening_login('a0000000-0000-0000-0000-000000000005');
set local role authenticated;
do $$ declare box uuid := (select id from opening_ids where k = 'box_b'); b uuid := (select id from opening_ids where k = 'branch_b'); begin
  perform fn_admin_set_account_opening(box, -100, fn_branch_today(b), 'رصيد الفندق الآخر');
  insert into opening_results values ('OPEN-11 second hotel receives its own review and manager alert',
    (select count(*) = 1 from review_items where kind = 'negative_cash_box' and entity_id = box and organization_id = fn_user_org_id())
    and (select count(*) = 1 from notifications where branch_id = b and organization_id = fn_user_org_id() and audience = 'manager' and title like 'شذوذ مالي:%')
    and not exists(select 1 from review_items where entity_id = (select id from opening_ids where k = 'cash_box')));
end $$;
reset role;
select case when ok then 'PASS' else 'FAIL' end as result, name from opening_results order by name;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from opening_results;
do $$ begin
  if (select count(*) from opening_results) <> 11 or exists(select 1 from opening_results where not ok) then
    raise exception 'OPENING ANOMALY TESTS FAILED OR INCOMPLETE';
  end if;
end $$;
rollback;
