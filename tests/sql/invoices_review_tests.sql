-- =====================================================================
-- Invoices and the owner's review list (Phase 4, migration 0036): decisions 11, 26, 27, 59 and the matrix rows they fill.
-- IV01–IV13: partial invoices by period (nights at their saved price, the discount and the tax in the same proportion,
-- one-off lines by their day, shares that add up to the halala), no overlap, the preview, the automatic invoice at
-- check-out and at the deposit's settlement, the edit with a reason and its kept versions, cancelling, and «مغلق».
-- VC01–VC09: «تصحيح سند» (cancel and re-issue in one step, the supervisor's own vouchers within 24 hours, the checks of a
-- new voucher, all or nothing, replays) and cancelling.
-- RL01–RL04: the review list, the owner's alone.
-- Runs after stay_cycle_tests.sql on the same database (its synthetic organisation, branch 010 and staff).
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
create or replace function t_res(p uuid) returns reservations language sql security definer as $$ select * from reservations where id = p $$;
create or replace function t_inv(p uuid) returns invoices language sql security definer as $$ select * from invoices where id = p $$;
create or replace function t_fin(p uuid) returns jsonb language sql security definer as $$ select fn_reservation_finance_internal(p) $$;
create or replace function t_due(p uuid, p_at timestamptz) returns jsonb language sql security definer as $$ select fn_stay_due_internal(p, p_at) $$;
create or replace function t_uninv(p uuid) returns bigint language sql security definer as $$ select fn_uninvoiced_value(p) $$;
create or replace function t_missing(p uuid) returns text[] language sql security definer as $$ select fn_closure_missing(p) $$;
create or replace function t_count(p_sql text) returns bigint language plpgsql security definer as $$ declare n bigint; begin execute p_sql into n; return n; end $$;
create or replace function t_today() returns date language sql security definer as $$ select fn_branch_today('00000000-0000-0000-0000-000000000010') $$;
create or replace function t_fails(p_sql text, p_like text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'accepted';
exception when others then
  return case when sqlerrm like p_like then 'ok' else sqlerrm end;
end $$;
create or replace function t_ready(p uuid) returns void language plpgsql security definer as $$
begin
  update reservation_guests set data_submitted = true, verification_status = 'verified' where reservation_id = p;
  update reservations set identity_status = 'verified' where id = p;
end $$;
create or replace function t_stay(p_room uuid, p_from date, p_to date, p_name text) returns uuid language plpgsql as $$
declare r jsonb;
begin
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'),
         'room_id', p_room, 'check_in', p_from, 'check_out', p_to, 'guest_name', p_name, 'guest_phone', '0500008' || lpad((floor(random() * 1000))::int::text, 3, '0'),
         'source_id', '00000000-0000-0000-0000-000000000021'));
  return (r->>'id')::uuid;
end $$;
create or replace function t_shomoos(p uuid) returns void language plpgsql as $$
begin
  perform fn_staff_shomoos(jsonb_build_object('reservation_id', p, 'action', 'register', 'reference', 'SHM-' || left(p::text, 8), 'all_guests', true));
  perform fn_staff_shomoos(jsonb_build_object('reservation_id', p, 'action', 'accept'));
end $$;
-- the arrival with the whole stay paid and the branch's deposit taken
create or replace function t_arrive_paid(p uuid, p_key text) returns jsonb language plpgsql as $$
declare d jsonb; f jsonb;
begin
  perform t_ready(p); perform t_shomoos(p);
  f := t_fin(p);
  d := t_due(p, now());
  return fn_staff_check_in(jsonb_build_object('reservation_id', p,
    'rent', jsonb_build_object('amount_halalas', (f->>'balance_due')::bigint, 'method', 'cash', 'idempotency_key', p_key || '-rent'),
    'deposit', jsonb_build_object('amount_halalas', (d->>'deposit_required')::bigint, 'method', 'cash', 'idempotency_key', p_key || '-dep')));
end $$;
-- the shares an issued invoice carries, by kind
create or replace function t_share(p_invoice uuid, p_kind text) returns bigint language sql security definer as $$
  select coalesce(sum((l->>'amount_halalas')::bigint), 0) from invoices i cross join lateral jsonb_array_elements(i.snapshot->'lines') l
   where i.id = p_invoice and l->>'kind' = p_kind
$$;
-- night prices set by hand (a stay priced from the calendar), so a discount's proportion can be checked
create or replace function t_set_night_price(p uuid, p_night date, p_price bigint) returns void language sql security definer as $$
  update reservation_nights set price_halalas = p_price where reservation_id = p and night = p_night and status = 'active'
$$;
create or replace function t_part(p uuid, p_total bigint, p_weighted boolean, p_from date, p_to date, p_at date) returns bigint language sql security definer as $$
  select fn_charge_part(p, p_total, p_weighted, p_from, p_to, p_at)
$$;
create or replace function t_round_div(p_n numeric, p_d numeric) returns bigint language sql security definer as $$
  select fn_round_div(p_n, p_d)
$$;
create or replace function t_tax_rate(p uuid, p_bp int) returns void language sql security definer as $$
  update reservations set tax_rate_bp = p_bp, prices_include_tax = false where id = p
$$;
create or replace function t_age_voucher(p uuid, p_hours int) returns void language sql security definer as $$
  update financial_vouchers set created_at = created_at - make_interval(hours => p_hours) where id = p
$$;
create or replace function t_payout(p uuid) returns void language plpgsql security definer as $$
declare po uuid;
begin
  insert into platform_payouts(organization_id, branch_id, source_id, account_id, expected_halalas, received_halalas, difference_halalas, voucher_count, received_on, reference)
  select v.organization_id, v.branch_id, '00000000-0000-0000-0000-000000000021',
         (select id from cash_accounts a where a.branch_id = v.branch_id and a.kind = 'bank_account' order by a.is_default desc limit 1),
         v.amount_halalas, v.amount_halalas, 0, 1, t_today(), 'PO-T'
    from financial_vouchers v where v.id = p returning id into po;
  update financial_vouchers set payout_id = po where id = p;
end $$;

-- ---------------------------------------------------------------- fixtures
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; begin
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'name_ar', 'نوع الفواتير', 'base_capacity', 2, 'max_capacity', 3,
         'base_price_halalas', 10000));
  insert into ids values ('cat', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_number', 'IV-1')); insert into ids values ('u1', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_number', 'IV-2')); insert into ids values ('u2', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_number', 'IV-3')); insert into ids values ('u3', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_number', 'IV-4')); insert into ids values ('u4', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_number', 'IV-5')); insert into ids values ('u5', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_number', 'IV-6')); insert into ids values ('u6', (r->>'id')::uuid);
  r := fn_admin_upsert_service(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'name_ar', 'غسيل ملابس', 'price_halalas', 1500));
  insert into ids values ('svc', (r->>'id')::uuid);
end $$;

-- ---------------------------------------------------------------- IV01–IV05: partial invoices and their shares
do $$ declare res uuid; d0 date := t_today() + 20; a jsonb; b jsonb; tot bigint; begin
  -- 4 nights × 100.00, a 40.00 discount: [d0, d0+2) carries two nights and half the discount
  res := t_stay(t_id('u1'), d0, d0 + 4, 'ضيف الفاتورة الجزئية');
  insert into ids values ('resA', res);
  perform fn_staff_adjust_price(res, 'discount', 4000, 'خصم', 'عميل دائم', (t_res(res)).version);
  a := fn_staff_issue_invoice(jsonb_build_object('reservation_id', res, 'from', d0, 'to', d0 + 2));
  b := fn_staff_issue_invoice(jsonb_build_object('reservation_id', res, 'from', d0 + 2, 'to', d0 + 4));
  tot := (t_fin(res)->>'total')::bigint;
  perform t_record('IV01 a partial invoice carries the nights of its period at their saved price and the discount in the same proportion; two periods add up to the stay',
    (a->>'scope') = 'period' and t_share((a->>'id')::uuid, 'rent') = 20000 and t_share((a->>'id')::uuid, 'discount') = -2000 and (a->>'total_halalas')::bigint = 18000
    and (b->>'total_halalas')::bigint = 18000 and (a->>'total_halalas')::bigint + (b->>'total_halalas')::bigint = tot
    and t_count(format('select count(*) from reservation_charges where reservation_id = %L and total_halalas <> 0 and invoice_id is null', res)) = 0
    and t_uninv(res) = 0, format('a=%s b=%s total=%s', a->>'total_halalas', b->>'total_halalas', tot));
exception when others then perform t_record('IV01 a partial invoice carries the nights of its period at their saved price and the discount in the same proportion; two periods add up to the stay', false, sqlerrm); end $$;

do $$ declare res uuid; d0 date := t_today() + 30; i1 jsonb; i2 jsonb; i3 jsonb; s bigint; begin
  -- a 10.00 discount over three nights cannot be split evenly: the shares are -3.33, -3.34, -3.33 and add up exactly
  res := t_stay(t_id('u2'), d0, d0 + 3, 'ضيف التقريب');
  perform fn_staff_adjust_price(res, 'discount', 1000, 'خصم', 'تقريب', (t_res(res)).version);
  i1 := fn_staff_issue_invoice(jsonb_build_object('reservation_id', res, 'from', d0, 'to', d0 + 1));
  i2 := fn_staff_issue_invoice(jsonb_build_object('reservation_id', res, 'from', d0 + 1, 'to', d0 + 2));
  i3 := fn_staff_issue_invoice(jsonb_build_object('reservation_id', res, 'from', d0 + 2, 'to', d0 + 3));
  s := t_share((i1->>'id')::uuid, 'discount') + t_share((i2->>'id')::uuid, 'discount') + t_share((i3->>'id')::uuid, 'discount');
  perform t_record('IV01b shares are cumulative: a discount split over three periods loses no halala (-333, -334, -333)',
    t_share((i1->>'id')::uuid, 'discount') = -333 and t_share((i2->>'id')::uuid, 'discount') = -334 and t_share((i3->>'id')::uuid, 'discount') = -333 and s = -1000
    and t_uninv(res) = 0, format('%s %s %s = %s', t_share((i1->>'id')::uuid, 'discount'), t_share((i2->>'id')::uuid, 'discount'), t_share((i3->>'id')::uuid, 'discount'), s));
exception when others then perform t_record('IV01b shares are cumulative: a discount split over three periods loses no halala (-333, -334, -333)', false, sqlerrm); end $$;

do $$ declare res uuid := t_id('resA'); d0 date := t_today() + 20; m text; begin
  m := t_fails(format('select fn_staff_issue_invoice(jsonb_build_object(%L, %L::uuid, %L, %L::date, %L, %L::date))', 'reservation_id', res, 'from', d0 + 1, 'to', d0 + 3), 'INVOICE_PERIOD_OVERLAP%');
  perform t_record('IV02 two period invoices of a stay never overlap', m = 'ok', m);
  m := t_fails(format('select fn_staff_issue_invoice(jsonb_build_object(%L, %L::uuid))', 'reservation_id', res), 'NOTHING_TO_INVOICE%');
  perform t_record('IV02b nothing left → NOTHING_TO_INVOICE, no empty invoice', m = 'ok', m);
end $$;

do $$ declare res uuid; d0 date := t_today() + 40; p jsonb; i jsonb; n0 bigint; begin
  res := t_stay(t_id('u3'), d0, d0 + 3, 'ضيف المعاينة');
  insert into ids values ('resP', res);
  perform fn_staff_add_service(res, t_id('svc'), 1, null);
  n0 := t_count('select count(*) from invoices');
  p := fn_invoice_preview(jsonb_build_object('reservation_id', res, 'from', d0, 'to', d0 + 2));
  perform t_record('IV03 the preview shows what «إنشاء» would issue and writes nothing',
    (p->>'ok')::boolean and t_count('select count(*) from invoices') = n0 and jsonb_array_length(p->'lines') >= 1 and (p->>'total_halalas')::bigint = 20000
    and p->'reservation'->>'guest' = 'ضيف المعاينة', p::text);
  -- the service was added today: outside [d0, d0+2], it waits for the invoice of its day (or the rest of the stay)
  i := fn_staff_issue_invoice(jsonb_build_object('reservation_id', res, 'from', d0, 'to', d0 + 2));
  perform t_record('IV04 a one-off line goes with its day: a service of today is not in a period that does not hold today',
    (i->>'total_halalas')::bigint = (p->>'total_halalas')::bigint and t_share((i->>'id')::uuid, 'addon') = 0
    and t_uninv(res) = 10000 + 1500, format('%s, left %s', i->>'total_halalas', t_uninv(res)));
  i := fn_staff_issue_invoice(jsonb_build_object('reservation_id', res));
  perform t_record('IV04b without a period, the rest of the stay: the last night and the service',
    (i->>'scope') = 'remaining' and (i->>'total_halalas')::bigint = 11500 and t_uninv(res) = 0, i::text);
exception when others then perform t_record('IV03 the preview shows what «إنشاء» would issue and writes nothing', false, sqlerrm); end $$;

do $$ declare res uuid; d0 date := t_today() + 50; i jsonb; f bigint; begin
  -- nights at 100.00 and 300.00: the first night is a quarter of the rent, so it carries a quarter of the discount
  res := t_stay(t_id('u4'), d0, d0 + 2, 'ضيف الأسعار المختلفة');
  perform t_set_night_price(res, d0 + 1, 30000);
  f := t_part(res, -2000, true, d0, d0 + 2, d0 + 1);
  perform fn_staff_adjust_price(res, 'discount', 2000, 'خصم', 'نسبة', (t_res(res)).version);
  i := fn_staff_issue_invoice(jsonb_build_object('reservation_id', res, 'from', d0, 'to', d0 + 1));
  perform t_record('IV05 a discount follows the period''s share of the rent, not its share of the nights',
    f = -500 and t_share((i->>'id')::uuid, 'discount') = -500, format('part %s, discount share %s', f, t_share((i->>'id')::uuid, 'discount')));
exception when others then perform t_record('IV05 a discount follows the period''s share of the rent, not its share of the nights', false, sqlerrm); end $$;

do $$ begin
  -- a share is multiplied before it is divided: 3 halalas over six nights, five of them, is 2.5 and rounds to 3 (a
  -- fraction rounded first, 0.83333…, would give 2.49999… and 2)
  perform t_record('IV05c a half is a half: shares round half away from zero exactly (decision 47)',
    t_round_div(15, 6) = 3 and t_round_div(-15, 6) = -3 and t_round_div(14, 6) = 2 and t_round_div(-16, 6) = -3 and t_round_div(0, 7) = 0
    and t_round_div(3 * 5, 6) = 3 and t_round_div(-1000, 3) = -333 and t_round_div(-2000, 3) = -667, null);
exception when others then perform t_record('IV05c a half is a half: shares round half away from zero exactly (decision 47)', false, sqlerrm); end $$;

do $$ declare res uuid; d0 date := t_today() + 60; i jsonb; base uuid; begin
  -- with a 15% tax, the discount's tax line knows its line and follows its proportion
  res := t_stay(t_id('u5'), d0, d0 + 2, 'ضيف الضريبة');
  perform t_tax_rate(res, 1500);
  perform fn_staff_adjust_price(res, 'discount', 2000, 'خصم', 'ضريبة', (t_res(res)).version);
  select base_charge_id into base from reservation_charges where reservation_id = res and kind = 'tax';
  i := fn_staff_issue_invoice(jsonb_build_object('reservation_id', res, 'from', d0, 'to', d0 + 1));
  perform t_record('IV05b a tax line records its line and goes with it: half the discount, half its tax',
    base is not null and (select kind from reservation_charges where id = base) = 'discount'
    and t_share((i->>'id')::uuid, 'discount') = -1000 and t_share((i->>'id')::uuid, 'tax') = -150, format('base %s, tax share %s', base, t_share((i->>'id')::uuid, 'tax')));
exception when others then perform t_record('IV05b a tax line records its line and goes with it: half the discount, half its tax', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- IV06–IV07: the automatic invoice (decision 27)
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
do $$ declare res uuid; r jsonb; co jsonb; inv invoices%rowtype; begin
  res := t_stay(t_id('u6'), t_today(), t_today() + 2, 'ضيف المغادرة');
  insert into ids values ('resD', res);
  r := t_arrive_paid(res, 'iv06');
  if not (r->>'ok')::boolean then raise exception 'arrival refused: %', r; end if;
  perform fn_staff_add_service(res, t_id('svc'), 1, null);
  perform fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind', 'receipt', 'amount_halalas', 1500, 'method', 'cash', 'idempotency_key', 'iv06-svc'));
  co := fn_staff_check_out(jsonb_build_object('reservation_id', res));
  select * into inv from invoices where reservation_id = res and status = 'issued';
  perform t_record('IV06 the check-out invoices everything not yet invoiced in the same operation',
    (co->>'ok')::boolean and (co->>'invoice') = inv.number and inv.origin = 'checkout' and inv.scope = 'remaining'
    and inv.total_halalas = (t_fin(res)->>'total')::bigint and t_uninv(res) = 0 and (t_res(res)).status = 'checked_out', co::text);
exception when others then perform t_record('IV06 the check-out invoices everything not yet invoiced in the same operation', false, sqlerrm); end $$;

do $$ declare res uuid := t_id('resD'); r jsonb; n0 bigint; inv invoices%rowtype; begin
  -- after the departure: a damage 70.00 from a 50.00 deposit, 20.00 still owed; the deposit is gone, so the damage is
  -- invoiced at once on its own invoice
  n0 := t_count(format('select count(*) from invoices where reservation_id = %L', res));
  perform fn_staff_record_inspection(jsonb_build_object('reservation_id', res, 'result', 'notes', 'notes', 'كسر', 'suggested_deduction_halalas', 7000));
  r := fn_staff_add_damage(jsonb_build_object('reservation_id', res, 'amount_halalas', 7000, 'reason', 'كسر الطاولة', 'idempotency_key', 'iv07-dmg'));
  select * into inv from invoices where reservation_id = res and origin = 'deposit_settled';
  perform t_record('IV07 a damage after the departure is invoiced when the deposit is settled, on its own invoice',
    (r->>'invoice') = inv.number and inv.total_halalas = 7000 and t_count(format('select count(*) from invoices where reservation_id = %L', res)) = n0 + 1
    and t_uninv(res) = 0 and (t_fin(res)->>'balance_due')::bigint = 2000, r::text);
  perform fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind', 'receipt', 'amount_halalas', 2000, 'method', 'cash', 'idempotency_key', 'iv07-pay'));
  perform t_record('IV07b paid in full, the stay closes by itself («مغلق»)', (t_res(res)).status = 'closed', (t_res(res)).status::text);
exception when others then perform t_record('IV07 a damage after the departure is invoiced when the deposit is settled, on its own invoice', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- IV08–IV10: the edit with a reason, versions, cancelling (decision 26)
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
do $$ declare res uuid := t_id('resA'); i uuid; e jsonb; inv invoices%rowtype; begin
  select id into i from invoices where reservation_id = res and status = 'issued' order by period_from limit 1;
  e := fn_staff_edit_invoice(jsonb_build_object('invoice_id', i, 'reason', 'اسم الشركة على الفاتورة', 'bill_to', jsonb_build_object('name', 'شركة الاختبار', 'note', 'مرجع 77')));
  inv := t_inv(i);
  perform t_record('IV08 an edit with its reason changes the bill-to, keeps the version before, and waits in the owner''s review list',
    (e->>'ok')::boolean and inv.version = 2 and inv.bill_to->>'name' = 'شركة الاختبار' and jsonb_array_length(inv.versions) = 1
    and (inv.versions->0->>'version')::int = 1 and (inv.versions->0->>'total_halalas')::bigint = inv.total_halalas and inv.versions->0->>'reason' = 'اسم الشركة على الفاتورة'
    and inv.snapshot->'bill_to'->>'name' = 'شركة الاختبار'
    and t_count(format('select count(*) from review_items where entity_id = %L and kind = %L', i, 'invoice_edited')) = 1
    and t_count(format('select count(*) from audit_events where entity_id = %L and action = %L', i, 'invoice.edited')) = 1, e::text);
  e := fn_staff_edit_invoice(jsonb_build_object('invoice_id', i, 'reason', 'لا شيء', 'bill_to', jsonb_build_object('name', 'شركة الاختبار', 'note', 'مرجع 77')));
  perform t_record('IV08b an edit that changes nothing writes nothing', (e->>'unchanged')::boolean and (t_inv(i)).version = 2, e::text);
exception when others then perform t_record('IV08 an edit with its reason changes the bill-to, keeps the version before, and waits in the owner''s review list', false, sqlerrm); end $$;

do $$ declare res uuid; d0 date := t_today() + 70; i jsonb; e jsonb; miss text[]; begin
  -- the whole stay invoiced, then a 20.00 settlement lowers the stay: the invoices carry more than its lines until the
  -- invoice is edited, and its amounts follow the lines (never typed)
  res := t_stay(t_id('u1'), d0, d0 + 2, 'ضيف التسوية');
  i := fn_staff_issue_invoice(jsonb_build_object('reservation_id', res, 'from', d0, 'to', d0 + 2));
  perform fn_staff_adjust_price(res, 'adjustment', -2000, 'تسوية', 'تعويض عن عطل', (t_res(res)).version);
  miss := t_missing(res);
  perform t_record('IV09b only lines that lower the bill are left → INVOICE_NOT_POSITIVE (no credit note; the invoice is edited instead)',
    t_fails(format('select fn_staff_issue_invoice(jsonb_build_object(%L, %L::uuid))', 'reservation_id', res), 'INVOICE_NOT_POSITIVE%') = 'ok', null);
  e := fn_staff_edit_invoice(jsonb_build_object('invoice_id', (i->>'id')::uuid, 'reason', 'تضمين التسوية'));
  perform t_record('IV09 a lower stay after its invoice: the closing says so, and the edit brings the invoice to the lines',
    array_to_string(miss, ' ') like '%الفواتير تزيد%' and (e->>'total_halalas')::bigint = 18000 and t_uninv(res) = 0
    and t_share((i->>'id')::uuid, 'adjustment') = -2000, array_to_string(miss, ' ') || ' | ' || e::text);
exception when others then perform t_record('IV09 a lower stay after its invoice: the closing says so, and the edit brings the invoice to the lines', false, sqlerrm); end $$;

do $$ declare res uuid := t_id('resP'); i uuid; m text; s bigint; t0 bigint; t1 bigint; begin
  select id, total_halalas into i, t0 from invoices where reservation_id = res and status = 'issued' and scope = 'remaining';
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  m := t_fails(format('select fn_cancel_invoice(%L::uuid, %L)', i, 'خطأ'), 'FORBIDDEN%');
  perform t_record('IV10 cancelling an invoice: not the supervisor', m = 'ok', m);
  m := t_fails(format('select fn_staff_edit_invoice(jsonb_build_object(%L, %L::uuid))', 'invoice_id', i), 'VALIDATION: reason%');
  perform t_record('IV10b an edit without a reason is refused', m = 'ok', m);
  perform t_login('a0000000-0000-0000-0000-000000000003', 'hk@test.local');
  m := t_fails(format('select fn_staff_edit_invoice(jsonb_build_object(%L, %L::uuid, %L, %L))', 'invoice_id', i, 'reason', 'x'), 'FORBIDDEN%');
  perform t_record('IV10c housekeeping cannot edit an invoice', m = 'ok', m);
  perform t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
  perform fn_cancel_invoice(i, 'أُصدرت بالخطأ');
  s := t_uninv(res);
  t1 := ((fn_staff_issue_invoice(jsonb_build_object('reservation_id', res)))->>'total_halalas')::bigint;
  perform t_record('IV10d the manager cancels: its shares are free again, a new invoice carries the same, the cancellation waits in the review list',
    s = t0 and t1 = t0 and t_count(format('select count(*) from review_items where entity_id = %L and kind = %L', i, 'invoice_cancelled')) = 1
    and t_fails(format('select fn_staff_edit_invoice(jsonb_build_object(%L, %L::uuid, %L, %L))', 'invoice_id', i, 'reason', 'x'), 'INVOICE_STATUS_INVALID%') = 'ok',
    format('free %s, re-issued %s of %s', s, t1, t0));
exception when others then perform t_record('IV10 cancelling an invoice: not the supervisor', false, sqlerrm); end $$;

do $$ declare res uuid := t_id('resA'); d0 date := t_today() + 20; i uuid; e jsonb; begin
  -- the period of a partial invoice can be moved, within what no other invoice carries
  select id into i from invoices where reservation_id = res and status = 'issued' and period_from = d0 + 2;
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  perform t_record('IV11 a period moved onto another invoice''s nights is refused',
    t_fails(format('select fn_staff_edit_invoice(jsonb_build_object(%L, %L::uuid, %L, %L, %L, %L::date))', 'invoice_id', i, 'reason', 'فترة', 'from', d0 + 1), 'INVOICE_PERIOD_OVERLAP%') = 'ok', null);
  e := fn_staff_edit_invoice(jsonb_build_object('invoice_id', i, 'reason', 'ليلة واحدة', 'to', d0 + 3));
  perform t_record('IV11b a period made shorter carries less; what it lets go waits for another invoice',
    (e->>'total_halalas')::bigint = 9000 and t_uninv(res) = 9000 and (t_inv(i)).period_to = d0 + 3 and (t_inv(i)).version = 2, e::text);
exception when others then perform t_record('IV11 a period moved onto another invoice''s nights is refused', false, sqlerrm); end $$;

do $$ declare res uuid := t_id('resD'); d jsonb; begin
  d := fn_reservation_detail(res);
  perform t_record('IV12 the reservation page shows each line''s invoiced share, each invoice''s origin and version, and what is left',
    (d->'invoicing'->>'uninvoiced_halalas')::bigint = 0 and jsonb_array_length(d->'invoices') = 2
    and (select bool_and((c->>'invoiced_halalas')::bigint = (c->>'total_halalas')::bigint) from jsonb_array_elements(d->'charges') c where (c->>'total_halalas')::bigint <> 0)
    and (d->'invoices'->0->>'origin') = 'checkout' and (d->'invoices'->0->>'version')::int = 1 and jsonb_typeof(d->'invoices'->0->'lines') = 'array', left((d->'invoicing')::text, 80));
exception when others then perform t_record('IV12 the reservation page shows each line''s invoiced share, each invoice''s origin and version, and what is left', false, sqlerrm); end $$;

do $$ declare res uuid; d0 date := t_today() + 80; i jsonb; begin
  -- the former entry point: a period gives a partial invoice, none everything left
  res := t_stay(t_id('u2'), d0, d0 + 2, 'ضيف المدخل القديم');
  i := fn_create_invoice(res, d0, d0 + 1);
  perform t_record('IV13 fn_create_invoice with a period is a partial invoice, without one the rest',
    (i->>'scope') = 'period' and (i->>'total_halalas')::bigint = 10000 and ((fn_create_invoice(res))->>'total_halalas')::bigint = 10000 and t_uninv(res) = 0, i::text);
exception when others then perform t_record('IV13 fn_create_invoice with a period is a partial invoice, without one the rest', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- VC01–VC09: «تصحيح سند» (decision 11)
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
do $$ declare res uuid; d0 date := t_today() + 90; v jsonb; c jsonb; o financial_vouchers%rowtype; n financial_vouchers%rowtype; begin
  res := t_stay(t_id('u3'), d0, d0 + 2, 'ضيف التصحيح');
  insert into ids values ('resV', res);
  v := fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind', 'receipt', 'amount_halalas', 15000, 'method', 'cash', 'idempotency_key', 'vc01-v'));
  insert into ids values ('v1', (v->>'voucher_id')::uuid);
  c := fn_staff_correct_voucher(jsonb_build_object('voucher_id', (v->>'voucher_id')::uuid, 'reason', 'المبلغ المقبوض 120 لا 150', 'amount_halalas', 12000, 'idempotency_key', 'vc01-c'));
  select * into o from financial_vouchers where id = (v->>'voucher_id')::uuid;
  select * into n from financial_vouchers where id = (c->>'voucher_id')::uuid;
  perform t_record('VC01 the supervisor corrects their own voucher within 24 hours: the original cancelled with the reason, the replacement linked, the money follows',
    (c->>'ok')::boolean and o.status = 'cancelled' and o.cancel_reason like 'تصحيح:%' and n.status = 'approved' and n.amount_halalas = 12000
    and n.original_voucher_id = o.id and n.kind = 'receipt' and (t_fin(res)->>'received')::bigint = 12000
    and t_count(format('select count(*) from review_items where entity_id = %L and kind = %L', n.id, 'voucher_corrected')) = 1
    and t_count(format('select count(*) from audit_events where entity_id = %L and action = %L', n.id, 'voucher.corrected')) = 1, c::text);
  c := fn_staff_correct_voucher(jsonb_build_object('voucher_id', (v->>'voucher_id')::uuid, 'reason', 'المبلغ المقبوض 120 لا 150', 'amount_halalas', 12000, 'idempotency_key', 'vc01-c'));
  perform t_record('VC01b the same correction again answers with its replacement and issues nothing',
    (c->>'duplicate')::boolean and (c->>'voucher_id')::uuid = n.id and t_count(format('select count(*) from financial_vouchers where reservation_id = %L', res)) = 2, c::text);
exception when others then perform t_record('VC01 the supervisor corrects their own voucher within 24 hours: the original cancelled with the reason, the replacement linked, the money follows', false, sqlerrm); end $$;

do $$ declare res uuid := t_id('resV'); v jsonb; w uuid; m text; begin
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  v := fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind', 'deposit', 'amount_halalas', 5000, 'method', 'cash', 'idempotency_key', 'vc02-v'));
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  m := t_fails(format('select fn_staff_correct_voucher(jsonb_build_object(%L, %L::uuid, %L, %L, %L, 4000, %L, %L))', 'voucher_id', (v->>'voucher_id')::uuid, 'reason', 'x', 'amount_halalas', 'idempotency_key', 'vc02-c'), 'FORBIDDEN%');
  perform t_record('VC02 the supervisor cannot correct a voucher someone else issued', m = 'ok', m);
  select id into w from financial_vouchers where reservation_id = res and status = 'approved' and kind = 'receipt';
  perform t_age_voucher(w, 25);
  m := t_fails(format('select fn_staff_correct_voucher(jsonb_build_object(%L, %L::uuid, %L, %L, %L, 11000, %L, %L))', 'voucher_id', w, 'reason', 'x', 'amount_halalas', 'idempotency_key', 'vc03-c'), 'CORRECTION_WINDOW_PASSED%');
  perform t_record('VC03 after 24 hours the supervisor''s own voucher is no longer theirs to correct', m = 'ok', m);
  perform t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
  v := fn_staff_correct_voucher(jsonb_build_object('voucher_id', w, 'reason', 'تصحيح بعد يوم', 'amount_halalas', 11000, 'idempotency_key', 'vc03-m'));
  perform t_record('VC03b after 24 hours the manager corrects it', (v->>'ok')::boolean and (t_fin(res)->>'received')::bigint = 11000, v::text);
  perform t_login('a0000000-0000-0000-0000-000000000004', 'finance@test.local');
  m := t_fails(format('select fn_staff_correct_voucher(jsonb_build_object(%L, %L::uuid, %L, %L, %L, 10000, %L, %L))', 'voucher_id', (v->>'voucher_id')::uuid, 'reason', 'x', 'amount_halalas', 'idempotency_key', 'vc08-c'), 'FORBIDDEN%');
  perform t_record('VC08 finance does not correct vouchers (§16)', m = 'ok', m);
exception when others then perform t_record('VC02 the supervisor cannot correct a voucher someone else issued', false, sqlerrm); end $$;

do $$ declare res uuid := t_id('resV'); w uuid; m text; n0 bigint; begin
  perform t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
  select id into w from financial_vouchers where reservation_id = res and status = 'approved' and kind = 'receipt';
  m := t_fails(format('select fn_staff_correct_voucher(jsonb_build_object(%L, %L::uuid, %L, 11000, %L, %L))', 'voucher_id', w, 'amount_halalas', 'idempotency_key', 'vc04-a'), 'VALIDATION: reason%');
  perform t_record('VC04 a correction needs its reason', m = 'ok', m);
  m := t_fails(format('select fn_staff_correct_voucher(jsonb_build_object(%L, %L::uuid, %L, %L, %L, %L))', 'voucher_id', w, 'reason', 'لا تغيير', 'idempotency_key', 'vc04-b'), 'VALIDATION: nothing_changed%');
  perform t_record('VC04b a correction that changes nothing is refused', m = 'ok', m);
  n0 := t_count(format('select count(*) from financial_vouchers where reservation_id = %L', res));
  m := t_fails(format('select fn_staff_correct_voucher(jsonb_build_object(%L, %L::uuid, %L, %L, %L, %L, %L, %L))', 'voucher_id', w, 'reason', 'شبكة', 'method', 'pos', 'idempotency_key', 'vc05-a'), 'VALIDATION: reference%');
  perform t_record('VC05 the replacement passes the checks of a new voucher (a terminal payment needs its number), and a refusal leaves the original as it was',
    m = 'ok' and (select status from financial_vouchers where id = w) = 'approved' and t_count(format('select count(*) from financial_vouchers where reservation_id = %L', res)) = n0, m);
  m := t_fails(format('select fn_staff_correct_voucher(jsonb_build_object(%L, %L::uuid, %L, %L, %L, %L, %L, %L))', 'voucher_id', w, 'reason', 'مدى', 'method', 'mada', 'idempotency_key', 'vc05-b'), 'VALIDATION: method_retired%');
  perform t_record('VC05b a retired method is refused in a correction too', m = 'ok', m);
exception when others then perform t_record('VC04 a correction needs its reason', false, sqlerrm); end $$;

do $$ declare res uuid := t_id('resV'); w uuid; rf jsonb; c jsonb; m text; begin
  -- 110.00 received, 100.00 refunded: correcting the receipt down to 50.00 would refund more than was received
  perform t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
  select id into w from financial_vouchers where reservation_id = res and status = 'approved' and kind = 'receipt';
  rf := fn_refund(jsonb_build_object('reservation_id', res, 'kind', 'refund', 'amount_halalas', 10000, 'method', 'cash', 'reason', 'إلغاء ليلة', 'idempotency_key', 'vc06-r'));
  m := t_fails(format('select fn_staff_correct_voucher(jsonb_build_object(%L, %L::uuid, %L, %L, %L, 5000, %L, %L))', 'voucher_id', w, 'reason', 'x', 'amount_halalas', 'idempotency_key', 'vc07-a'), 'CANCEL_WOULD_GO_NEGATIVE%');
  perform t_record('VC07 a correction that would leave more refunded than received is refused, all of it',
    m = 'ok' and (select status from financial_vouchers where id = w) = 'approved', m);
  c := fn_staff_correct_voucher(jsonb_build_object('voucher_id', (rf->>'voucher_id')::uuid, 'reason', 'المبلغ المردود 90', 'amount_halalas', 9000, 'idempotency_key', 'vc06-c'));
  perform t_record('VC06 a refund voucher is corrected through the refund''s own checks',
    (c->>'ok')::boolean and (t_fin(res)->>'refunded')::bigint = 9000 and (select kind from financial_vouchers where id = (c->>'voucher_id')::uuid) = 'refund', c::text);
exception when others then perform t_record('VC07 a correction that would leave more refunded than received is refused, all of it', false, sqlerrm); end $$;

do $$ declare res uuid; d0 date := t_today() + 95; v jsonb; c jsonb; m text; begin
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  res := t_stay(t_id('u4'), d0, d0 + 1, 'ضيف الإلغاء');
  v := fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind', 'receipt', 'amount_halalas', 3000, 'method', 'cash', 'idempotency_key', 'vc09-v'));
  c := fn_cancel_voucher((v->>'voucher_id')::uuid, 'سند مكرر');
  perform t_record('VC09 cancelling a voucher waits in the review list too',
    (c->>'ok')::boolean and t_count(format('select count(*) from review_items where entity_id = %L and kind = %L', (v->>'voucher_id')::uuid, 'voucher_cancelled')) = 1, c::text);
  v := fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind', 'receipt', 'amount_halalas', 3000, 'method', 'ota_deferred', 'reference', 'OTA-9', 'idempotency_key', 'vc09-w'));
  perform t_payout((v->>'voucher_id')::uuid);
  m := t_fails(format('select fn_cancel_voucher(%L::uuid, %L)', (v->>'voucher_id')::uuid, 'x'), 'VOUCHER_IN_PAYOUT%');
  perform t_record('VC09b a voucher already in a platform payout is neither cancelled nor corrected',
    m = 'ok' and t_fails(format('select fn_staff_correct_voucher(jsonb_build_object(%L, %L::uuid, %L, %L, %L, 2000, %L, %L))', 'voucher_id', (v->>'voucher_id')::uuid, 'reason', 'x', 'amount_halalas', 'idempotency_key', 'vc09-c'), 'VOUCHER_IN_PAYOUT%') = 'ok', m);
exception when others then perform t_record('VC09 cancelling a voucher waits in the review list too', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- RL01–RL04: the review list, the owner's alone (§16)
do $$ declare l jsonb; m text; n0 int; mk jsonb; ids uuid[]; s jsonb; begin
  perform t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
  m := t_fails('select fn_review_list(''{}''::jsonb)', 'FORBIDDEN%');
  perform t_record('RL01 the review list is the owner''s alone (the manager is refused)', m = 'ok', m);
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  perform t_record('RL01b a supervisor reads no review item through the table either', (select count(*) from review_items) = 0, null);
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  l := fn_review_list('{}'::jsonb);
  n0 := (l->>'open_count')::int;
  perform t_record('RL02 the owner sees what waits: corrections, edits, cancellations, with who, when and why',
    n0 >= 5 and exists (select 1 from jsonb_array_elements(l->'items') x where x->>'kind' = 'voucher_corrected' and x->>'created_by' is not null and x->>'reason' is not null)
    and exists (select 1 from jsonb_array_elements(l->'items') x where x->>'kind' = 'invoice_edited' and x->>'internal_ref' is not null), format('open %s', n0));
  select array_agg((x->>'id')::uuid) into ids from (select x from jsonb_array_elements(l->'items') x where x->>'kind' = 'voucher_corrected') s;
  mk := fn_review_mark(jsonb_build_object('ids', to_jsonb(ids), 'note', 'راجعتها'));
  l := fn_review_list(jsonb_build_object('status', 'reviewed'));
  perform t_record('RL03 marking moves them to «تمت مراجعتها» with the note and who marked; marking again changes nothing',
    (mk->>'marked')::int = array_length(ids, 1) and (fn_review_list('{}'::jsonb)->>'open_count')::int = n0 - array_length(ids, 1)
    and exists (select 1 from jsonb_array_elements(l->'items') x where x->>'review_note' = 'راجعتها' and x->>'reviewed_by' is not null)
    and (fn_review_mark(jsonb_build_object('ids', to_jsonb(ids)))->>'marked')::int = 0, mk::text);
  s := fn_review_summary();
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  perform t_record('RL04 the owner''s banner counts what waits by kind; anyone else gets nothing',
    (s->>'open')::int = n0 - array_length(ids, 1) and (s->'by_kind'->>'invoice_edited')::int >= 1 and fn_review_summary() is null, s::text);
exception when others then perform t_record('RL01 the review list is the owner''s alone (the manager is refused)', false, sqlerrm); end $$;

-- =====================================================================
-- RESULTS
-- =====================================================================
reset role;
select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),150) as detail from test_results order by ok, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if (select count(*) from test_results) < 44 then raise exception 'INVOICE AND REVIEW TESTS INCOMPLETE: % of 44 checks ran', (select count(*) from test_results); end if;
  if exists (select 1 from test_results where ok is not true) then raise exception 'INVOICE AND REVIEW TESTS FAILED'; end if;
end $$;
