\i tests/sql/audit_oracle.sql
-- =====================================================================
-- Plan phase 4, worker K items: 4.9 (M9 invoice cancellation / e-invoiced credit note, migration 0084),
-- 4.12 (per-hotel finance control thresholds, migration 0085) and the plan's 10 MB expense receipt limit (0086).
-- Uncodified descriptive names (no prefix registration yet; reported to the integrator).
-- Runs after hotel_settings_tests.sql on the same database (its synthetic organisation, branch 010 and staff).
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
create or replace function t_today() returns date language sql security definer as $$ select fn_branch_today('00000000-0000-0000-0000-000000000010') $$;

-- ---------------------------------------------------------------- fixtures: a stay of branch 010 with an issued invoice
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; res uuid; inv jsonb; begin
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'name_ar', 'نوع ضبط المال', 'base_capacity', 2, 'max_capacity', 3,
         'base_price_halalas', 10000));
  insert into ids values ('cat', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_number', 'FC-1'));
  insert into ids values ('u1', (r->>'id')::uuid);
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'),
         'room_id', t_id('u1'), 'check_in', t_today() + 400, 'check_out', t_today() + 403, 'guest_name', 'ضيف ضبط المال',
         'guest_phone', '0500099' || lpad((floor(random() * 1000))::int::text, 3, '0'), 'source_id', '00000000-0000-0000-0000-000000000021'));
  res := (r->>'id')::uuid;
  insert into ids values ('res', res);
  inv := fn_staff_issue_invoice(jsonb_build_object('reservation_id', res));
  insert into ids values ('inv', (inv->>'id')::uuid);
end $$;
reset role;
-- an invoice marked as reported to the e-invoicing authority
update invoices set e_invoice_ref = 'EINV-TEST-0001' where id = t_id('inv');

-- ---------------------------------------------------------------- 4.9: the cancellation rules
set role authenticated;
-- the reason is mandatory
select t_record('4.9 سبب الإلغاء إلزامي: إلغاء بلا سبب يُرفض',
  t_fails(format('select fn_cancel_invoice(%L, %L)', t_id('inv'), ''), 'VALIDATION: reason%') = 'ok');
-- the supervisor may not cancel (the owner or a manager)
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
select t_record('4.9 المشرف لا يلغي الفاتورة',
  t_fails(format('select fn_cancel_invoice(%L, %L)', t_id('inv'), 'سبب المشرف'), 'FORBIDDEN%') = 'ok');
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
-- an e-invoiced invoice is never cancelled
select t_record('4.9 الفاتورة المُبلَّغ عنها إلكترونيًا لا تُلغى',
  t_fails(format('select fn_cancel_invoice(%L, %L)', t_id('inv'), 'خطأ في الإصدار'), 'E_INVOICED_USE_CREDIT_NOTE%') = 'ok'
  and (select status from invoices where id = t_id('inv')) = 'issued'
  and (select count(*) from review_items where entity_id = t_id('inv') and kind = 'invoice_cancelled') = 0);
-- the credit note needs a reason, and a failed attempt writes nothing (rollback)
do $$ declare n_before int; r_before int; m text; begin
  select count(*) into n_before from invoices where reservation_id = t_id('res');
  select count(*) into r_before from review_items where kind = 'invoice_credit_note';
  m := t_fails(format('select fn_issue_credit_note(%L, %L)', t_id('inv'), ''), 'VALIDATION: reason%');
  perform t_record('4.9 الإشعار الدائن بلا سبب يُرفض ولا يترك أثرًا', m = 'ok'
    and (select count(*) from invoices where reservation_id = t_id('res')) = n_before
    and (select count(*) from review_items where kind = 'invoice_credit_note') = r_before, m);
end $$;
-- the supervisor may not issue a credit note
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
select t_record('4.9 المشرف لا يصدر إشعارًا دائنًا',
  t_fails(format('select fn_issue_credit_note(%L, %L)', t_id('inv'), 'سبب المشرف'), 'FORBIDDEN%') = 'ok');
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
-- the credit note: issued, offsets the original in full, one only, waits in the review list, audited
do $$ declare cn jsonb; orig invoices%rowtype; row_cn invoices%rowtype; begin
  select * into orig from invoices where id = t_id('inv');
  cn := fn_issue_credit_note(t_id('inv'), 'إلغاء الحجز بعد التبليغ الإلكتروني');
  insert into ids values ('cn', (cn->>'id')::uuid);
  select * into row_cn from invoices where id = (cn->>'id')::uuid;
  perform t_record('4.9 الإشعار الدائن يُصدر بمبلغ الفاتورة نفسها ويعود لها',
    row_cn.doc_kind = 'credit_note' and row_cn.credit_note_of = orig.id
    and row_cn.total_halalas = orig.total_halalas and row_cn.subtotal_halalas = orig.subtotal_halalas and row_cn.tax_halalas = orig.tax_halalas
    and row_cn.status = 'issued' and (select status from invoices where id = orig.id) = 'issued'
    and exists (select 1 from review_items where kind = 'invoice_credit_note' and entity_id = row_cn.id)
    and exists (select 1 from t_audit_all() where action = 'invoice.credit_note' and entity_id = row_cn.id));
end $$;
-- no second credit note on the same invoice
select t_record('4.9 إشعار دائن ثانٍ على الفاتورة نفسها يُرفض',
  t_fails(format('select fn_issue_credit_note(%L, %L)', t_id('inv'), 'محاولة ثانية'), 'CREDIT_NOTE_EXISTS%') = 'ok');
-- a credit note for an invoice the authority does not have is refused
do $$ declare r jsonb; res uuid; inv jsonb; m text; begin
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'),
         'room_id', t_id('u1'), 'check_in', t_today() + 410, 'check_out', t_today() + 412, 'guest_name', 'ضيف الفاتورة العادية',
         'guest_phone', '0500088' || lpad((floor(random() * 1000))::int::text, 3, '0'), 'source_id', '00000000-0000-0000-0000-000000000021'));
  res := (r->>'id')::uuid;
  inv := fn_staff_issue_invoice(jsonb_build_object('reservation_id', res));
  insert into ids values ('inv_plain', (inv->>'id')::uuid);
  m := t_fails(format('select fn_issue_credit_note(%L, %L)', (inv->>'id')::uuid, 'بلا تبليغ'), 'NOT_E_INVOICED%');
  perform t_record('4.9 لا إشعار دائن لفاتورة غير مُبلَّغ عنها', m = 'ok', m);
end $$;
-- a plain invoice still cancels: reason + review item (the pre-existing rule holds after the change)
do $$ declare ok jsonb; begin
  ok := fn_cancel_invoice(t_id('inv_plain'), 'طلب الضيف الإلغاء');
  perform t_record('4.9 الفاتورة العادية تُلغى بسبب وبند مراجعة',
    (ok->>'ok')::boolean
    and (select status from invoices where id = t_id('inv_plain')) = 'cancelled'
    and exists (select 1 from review_items where kind = 'invoice_cancelled' and entity_id = t_id('inv_plain')));
end $$;
-- hotel isolation: the other hotel's owner cannot cancel or credit-note this invoice
select t_login('a0000000-0000-0000-0000-000000000005', 'owner2@test.local');
select t_record('4.9 مالك فندق آخر لا يلغي فاتورتنا ولا يصدر إشعارًا عليها',
  t_fails(format('select fn_cancel_invoice(%L, %L)', t_id('inv'), 'تدخل خارجي'), 'FORBIDDEN%') = 'ok'
  and t_fails(format('select fn_issue_credit_note(%L, %L)', t_id('inv'), 'تدخل خارجي'), 'FORBIDDEN%') = 'ok');
reset role;
-- a credit note never points to itself, and an invoice row never carries credit_note_of without the kind
select t_record('4.9 قيود الشكل: الإشعار لا يعود لنفسه والفاتورة بلا مرجع إشعار',
  t_fails(format('update invoices set credit_note_of = id where id = %L', t_id('inv')), '%invoices_credit_note_shape%') = 'ok'
  and t_fails(format('update invoices set credit_note_of = %L where id = %L', t_id('inv'), t_id('inv_plain')), '%invoices_credit_note_shape%') = 'ok');

-- ---------------------------------------------------------------- 4.12: per-hotel control thresholds
set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
-- defaults exist for the hotel, per its own row
select t_record('4.12 عتبات افتراضية موجودة للفندق',
  (select (fn_finance_controls_get()->>'expense_limit_supervisor_halalas')::bigint) > 0
  and (select count(*) from finance_control_settings where organization_id = '00000000-0000-0000-0000-000000000001') = 1);
-- the owner changes a threshold; the change is in the security log with before and after
do $$ declare g jsonb; ev audit_events%rowtype; begin
  g := fn_finance_controls_set(jsonb_build_object('expense_limit_supervisor_halalas', 7500000, 'discount_threshold_halalas', 2500000));
  select * into ev from t_audit_all() where action = 'security.control_thresholds_updated' order by created_at desc, id desc limit 1;
  perform t_record('4.12 تغيير العتبة يُحفظ ويُسجَّل في «أمني» بالقيمتين',
    (g->>'expense_limit_supervisor_halalas')::bigint = 7500000 and (g->>'discount_threshold_halalas')::bigint = 2500000
    and ev.category = 'security' and ev.organization_id = '00000000-0000-0000-0000-000000000001'
    and (ev.details->'before'->>'expense_limit_supervisor_halalas')::bigint = 5000000
    and (ev.details->'after'->>'expense_limit_supervisor_halalas')::bigint = 7500000,
    ev.action || ' / ' || coalesce(ev.category, 'null'));
end $$;
-- the other hotel's row did not move (checked across hotels, beyond the owner's own read rule)
reset role;
select t_record('4.12 عتبة فندق لا تمس غيره',
  (select expense_limit_supervisor_halalas from finance_control_settings where organization_id = '00000000-0000-0000-0000-000000000002') = 5000000
  and (select count(*) from t_audit_all() where action = 'security.control_thresholds_updated' and organization_id = '00000000-0000-0000-0000-000000000002') = 0);
set role authenticated;
-- the supervisor reads but never writes; a rejected write changes nothing (rollback)
do $$ declare m1 text; m2 text; m3 text; begin
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  m1 := t_fails('select fn_finance_controls_set(jsonb_build_object(''refund_threshold_halalas'', 9))', 'FORBIDDEN%');
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  m2 := t_fails('select fn_finance_controls_set(jsonb_build_object(''refund_threshold_halalas'', 0))', 'VALIDATION%');
  m3 := t_fails('select fn_finance_controls_set(jsonb_build_object(''no_such_key'', 5))', 'VALIDATION: unknown_key%');
  perform t_record('4.12 غير المالك والقيم المرفوضة لا تغيّر شيئًا', m1 = 'ok' and m2 = 'ok' and m3 = 'ok'
    and (select refund_threshold_halalas from finance_control_settings where organization_id = '00000000-0000-0000-0000-000000000001') = 10000000,
    m1 || ' / ' || m2 || ' / ' || m3);
end $$;
-- RLS: a signed-in member of one hotel sees only their hotel's row in a direct read
do $$ declare n int; begin
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  select count(*) into n from finance_control_settings;
  perform t_record('4.12 القراءة المباشرة ترى صف الفندق وحده', n = 1, n::text);
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
end $$;
reset role;

-- ---------------------------------------------------------------- plan 4.3 fragment: the receipt limit is 10 MB now
create temp table t_keep(k text primary key, v text);
grant all on t_keep to public;
set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
do $$ declare cat uuid; acc uuid; big_ok jsonb; too_big text; small text; begin
  cat := (fn_admin_upsert_expense_category(jsonb_build_object('name', 'تصنيف حد المرفق'))->>'id')::uuid;
  select id into acc from cash_accounts where branch_id = '00000000-0000-0000-0000-000000000010' and kind = 'cash_box' and archived_at is null order by is_default desc limit 1;
  -- 3 MB PNG: refused before (2 MB), accepted now
  big_ok := fn_expense_create(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'account_id', acc, 'category_id', cat,
    'amount_halalas', 1000, 'description', 'مصروف بمرفق ثلاثة ميجابايت', 'idempotency_key', 'att-3mb-' || floor(random()*1000000)::text,
    'attachments', jsonb_build_array(jsonb_build_object('data_base64', encode('\x89504e470d0a1a0a'::bytea || decode(repeat('00', 3000000), 'hex'), 'base64'), 'file_name', 'receipt.png'))));
  -- 11 MB: still refused
  too_big := t_fails(format('select fn_expense_create(%L::jsonb)', jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'account_id', acc, 'category_id', cat,
    'amount_halalas', 1000, 'description', 'مصروف بمرفق أحد عشر ميجابايت', 'idempotency_key', 'att-11mb-' || floor(random()*1000000)::text,
    'attachments', jsonb_build_array(jsonb_build_object('data_base64', encode('\x89504e470d0a1a0a'::bytea || decode(repeat('00', 11000000), 'hex'), 'base64'), 'file_name', 'big.png')))), 'VALIDATION: attachment_too_large%');
  insert into t_keep values ('big_ok', big_ok->>'ok'), ('too_big', too_big), ('number', coalesce(big_ok->>'number', 'no-number'));
end $$;
reset role;
-- a refused expense writes nothing (rollback: no voucher, no attachment); these reads are beyond the staff rules, so as the platform
select t_record('4.3 مرفق 3 ميجابايت يُقبل و11 ميجابايت يُرفض ولا يترك شيئًا',
  (select v from t_keep where k = 'big_ok') = 'true'
  and exists (select 1 from expense_attachments x join expense_vouchers e on e.id = x.expense_id where x.size_bytes > 2097152 and x.size_bytes <= 10485760 and e.description = 'مصروف بمرفق ثلاثة ميجابايت')
  and (select v from t_keep where k = 'too_big') = 'ok'
  and not exists (select 1 from expense_vouchers where description = 'مصروف بمرفق أحد عشر ميجابايت'),
  (select v from t_keep where k = 'number') || ' / ' || (select v from t_keep where k = 'too_big'));

-- ---------------------------------------------------------------- summary
select (case when ok then 'PASS' else 'FAIL' end) as result, name, detail from test_results order by ctid;
select 'TOTAL', count(*) filter (where ok) as passed, count(*) as total from test_results;
do $$ begin if exists (select 1 from test_results where not ok) then raise exception 'PHASE4 CONTROLS TESTS FAILED'; end if; end $$;
