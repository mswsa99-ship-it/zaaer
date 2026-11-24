-- =====================================================================
-- Phase 4 money controls, server side (proposed migration 0084): 4.5 one standing deposit, 4.6 the six anomaly
-- rules, 4.7 the nightly price floor and the owner-approved free stay, 4.8 the discount threshold with the owner's
-- prior approval. Every refusal is followed by its rollback invariant (nothing written), every acceptance by its
-- totals invariant. Descriptive names, no coded prefixes (worker package; the integrator registers codes if wanted).
-- Runs after rates_tests.sql on the same database (uses the synthetic organisation 00..01, branch 010, the direct
-- source 00..21 and the staff of core_tests.sql). Invented data only.
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
create or replace function t_fin(p uuid) returns jsonb language sql security definer as $$ select fn_reservation_finance_internal(p) $$;

-- ---------------------------------------------------------------- fixtures (as the owner): a type at 300.00 a night, four units, an expense category, a second branch with an empty box
-- the discount gate ships off (null) until the hotel sets its threshold; these tests set the proposed 20%
update system_settings set discount_review_threshold_bp = 2000 where organization_id = '00000000-0000-0000-0000-000000000001';
create or replace function t_stay(p_room uuid, p_phone text, p_name text) returns uuid language plpgsql as $$
declare r jsonb;
begin
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_id', p_room,
         'check_in', fn_branch_today('00000000-0000-0000-0000-000000000010') + 400, 'check_out', fn_branch_today('00000000-0000-0000-0000-000000000010') + 402,
         'guest_phone', p_phone, 'guest_name', p_name, 'source_id', '00000000-0000-0000-0000-000000000021'));
  return (r->>'id')::uuid;
end $$;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; begin
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'name_ar', 'نوع ضبط المال', 'base_capacity', 2, 'max_capacity', 3,
         'base_price_halalas', 30000, 'min_nightly_halalas', 10000));
  insert into ids values ('cat', (r->>'id')::uuid);
  for i in 1..4 loop
    r := fn_admin_upsert_room(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_number', 'MC-' || i));
    execute format('insert into ids values (%L, %L)', 'room' || i, r->>'id');
  end loop;
  r := fn_admin_upsert_expense_category(jsonb_build_object('name', 'مصاريف ضبط المال'));
  insert into ids values ('expcat', (r->>'id')::uuid);
  r := fn_admin_upsert_branch(jsonb_build_object('name_ar', 'فرع الضبط', 'name_en', 'Controls branch'));
  insert into ids values ('branch2', (r->>'id')::uuid);
  insert into ids values ('box2', (select id from cash_accounts where branch_id = (r->>'id')::uuid and kind = 'cash_box' and is_default));
end $$;
-- the owner works the new branch too (a membership, as the fixtures give for the other branches)
reset role;
insert into branch_memberships(staff_id, branch_id)
  select '10000000-0000-0000-0000-000000000001', v from ids where k = 'branch2'
  on conflict do nothing;
set role authenticated;
do $$ begin
  insert into ids values ('res1', t_stay(t_id('room1'), '0560000001', 'ضيف التأمين'));
  insert into ids values ('res2', t_stay(t_id('room2'), '0560000002', 'ضيف العتبة'));
  insert into ids values ('res3', t_stay(t_id('room4'), '0560000004', 'ضيف الخصم'));
end $$;

-- ---------------------------------------------------------------- 4.5 the deposit: one standing, an increase only «تكملة تأمين» with its reason
do $$ declare r jsonb; e1 text; e2 text; e3 text; f jsonb; begin
  r := fn_create_voucher(jsonb_build_object('reservation_id', t_id('res1'), 'kind', 'deposit', 'amount_halalas', 10000, 'method', 'cash', 'idempotency_key', 'p4k-dep1'));
  e1 := t_fails(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res1'), 'kind', 'deposit', 'amount_halalas', 5000,
        'method', 'cash', 'idempotency_key', 'p4k-dep2')), 'DEPOSIT_EXISTS%');
  f := t_fin(t_id('res1'));
  perform t_record('4.5 a second deposit without its reason is refused, and the refusal writes nothing (the first deposit stands alone)',
    (r->>'ok')::boolean and e1 = 'ok'
    and t_count(format('select count(*) from financial_vouchers where reservation_id = %L and kind = ''deposit'' and status = ''approved''', t_id('res1'))) = 1
    and (f->>'deposit_received')::bigint = 10000, e1 || ' / ' || f::text);
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  e2 := t_fails(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res1'), 'kind', 'deposit', 'amount_halalas', 5000,
        'method', 'cash', 'idempotency_key', 'p4k-dep2s')), 'DEPOSIT_EXISTS%');
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  perform t_record('4.5 the refusal holds for the supervisor too, not only the owner', e2 = 'ok', e2);
  r := fn_create_voucher(jsonb_build_object('reservation_id', t_id('res1'), 'kind', 'deposit', 'amount_halalas', 5000, 'method', 'cash',
         'reason', 'تكملة تأمين — تلف في الوحدة', 'idempotency_key', 'p4k-dep3'));
  f := t_fin(t_id('res1'));
  perform t_record('4.5 the reasoned top-up passes and the totals add up (both deposits stand)',
    (r->>'ok')::boolean and (f->>'deposit_received')::bigint = 15000, f::text);
  e3 := t_fails(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res1'), 'kind', 'deposit', 'amount_halalas', 1000,
        'method', 'cash', 'idempotency_key', 'p4k-dep4')), 'DEPOSIT_EXISTS%');
  perform t_record('4.5 a third deposit without its reason is still refused (the top-up does not open the door)',
    e3 = 'ok' and (t_fin(t_id('res1'))->>'deposit_received')::bigint = 15000, e3);
exception when others then perform t_record('4.5 the deposit gate and the top-up', false, sqlerrm); end $$;

-- (its own block: the duplicate-deposit flag trigger is deferred to the commit, so the item is read after the write commits)
do $$ begin
  perform t_record('4.6 the reasoned top-up opens the repeated-deposit review item and its alert',
    t_count(format('select count(*) from review_items where kind = ''deposit_duplicate'' and reservation_id = %L and reviewed_at is null', t_id('res1'))) = 1
    and t_count(format('select count(*) from notifications n join review_items ri on ri.branch_id = n.branch_id where ri.kind = ''deposit_duplicate'' and ri.reservation_id = %L and n.title like ''%%شذوذ مالي%%''', t_id('res1'))) >= 1, null);
exception when others then perform t_record('4.6 the reasoned top-up opens the repeated-deposit review item and its alert', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- 4.6 receipts and expenses over the threshold, over the due, and the negative box
do $$ declare r jsonb; begin
  r := fn_create_voucher(jsonb_build_object('reservation_id', t_id('res1'), 'kind', 'receipt', 'amount_halalas', 600000, 'method', 'cash', 'idempotency_key', 'p4k-rcp1'));
  perform t_record('4.6 a receipt over the threshold and over what is due is flagged twice, once per rule, with an alert each',
    (r->>'ok')::boolean
    and t_count(format('select count(*) from review_items where kind = ''receipt_over_threshold'' and reservation_id = %L', t_id('res1'))) = 1
    and t_count(format('select count(*) from review_items where kind = ''receipt_over_due'' and reservation_id = %L', t_id('res1'))) = 1
    and t_count(format('select count(*) from notifications where branch_id = ''00000000-0000-0000-0000-000000000010'' and title like ''%%شذوذ مالي%%''')) >= 3,
    r::text);
  r := fn_create_voucher(jsonb_build_object('reservation_id', t_id('res2'), 'kind', 'receipt', 'amount_halalas', 1000, 'method', 'cash', 'idempotency_key', 'p4k-rcp2'));
  perform t_record('4.6 an ordinary receipt under the threshold and within the due fires neither rule',
    (r->>'ok')::boolean
    and t_count(format('select count(*) from review_items where kind in (''receipt_over_threshold'', ''receipt_over_due'') and reservation_id = %L', t_id('res2'))) = 0,
    r::text);
exception when others then perform t_record('4.6 the receipt rules', false, sqlerrm); end $$;

do $$ declare r jsonb; begin
  r := fn_expense_create(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'account_id',
         (select id from cash_accounts where branch_id = '00000000-0000-0000-0000-000000000010' and kind = 'cash_box' and is_default),
         'category_id', t_id('expcat'), 'attachments', jsonb_build_array(jsonb_build_object('data_base64', 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'file_name', 'receipt.png')), 'amount_halalas', 600001, 'description', 'مصروف فوق العتبة', 'idempotency_key', 'p4k-exp1'));
  perform t_record('4.6 an expense over the threshold is flagged with its amount',
    (r->>'ok')::boolean
    and t_count('select count(*) from review_items where kind = ''expense_over_threshold''') = 1, r::text);
exception when others then perform t_record('4.6 the expense threshold', false, sqlerrm); end $$;

do $$ declare r jsonb; begin
  r := fn_expense_create(jsonb_build_object('branch_id', t_id('branch2'), 'account_id', t_id('box2'), 'category_id', t_id('expcat'),
         'attachments', jsonb_build_array(jsonb_build_object('data_base64', 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'file_name', 'receipt.png')), 'amount_halalas', 1000, 'description', 'سحب من صندوق فارغ', 'idempotency_key', 'p4k-exp2'));
  perform t_record('4.6 a box under zero is flagged once, with the balance',
    (r->>'ok')::boolean
    and t_count(format('select count(*) from review_items where kind = ''negative_cash_box'' and entity_id = %L', t_id('box2'))) = 1, r::text);
  r := fn_expense_create(jsonb_build_object('branch_id', t_id('branch2'), 'account_id', t_id('box2'), 'category_id', t_id('expcat'),
         'attachments', jsonb_build_array(jsonb_build_object('data_base64', 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'file_name', 'receipt.png')), 'amount_halalas', 1000, 'description', 'سحب ثان من الصندوق نفسه', 'idempotency_key', 'p4k-exp3'));
  perform t_record('4.6 a box that stays negative is not flagged again while the first item waits',
    (r->>'ok')::boolean
    and t_count(format('select count(*) from review_items where kind = ''negative_cash_box'' and entity_id = %L and reviewed_at is null', t_id('box2'))) = 1, r::text);
exception when others then perform t_record('4.6 the negative box', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- 4.7 the price floor and the owner-approved free stay
do $$ declare e_owner text; e_mgr text; e_sup text; e_sup2 text; e_norsn text; r jsonb; rid uuid; begin
  e_owner := t_fails(format('select fn_staff_create_reservation(%L::jsonb)', jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'),
    'room_id', t_id('room3'), 'check_in', fn_branch_today('00000000-0000-0000-0000-000000000010') + 400, 'check_out', fn_branch_today('00000000-0000-0000-0000-000000000010') + 401,
    'guest_phone', '0560000010', 'guest_name', 'صفر مالك', 'source_id', '00000000-0000-0000-0000-000000000021', 'nightly_rate_halalas', 0)), 'PRICE_FLOOR%');
  perform t_record('4.7 a zero night price is refused for the owner, and the refusal writes neither reservation nor nights',
    e_owner = 'ok'
    and t_count('select count(*) from reservations where id in (select reservation_id from reservation_guests where phone = ''0560000010'')') = 0, e_owner);
  perform t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
  e_mgr := t_fails(format('select fn_staff_create_reservation(%L::jsonb)', jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'),
    'check_in', fn_branch_today('00000000-0000-0000-0000-000000000010') + 400, 'check_out', fn_branch_today('00000000-0000-0000-0000-000000000010') + 401,
    'guest_phone', '0560000011', 'guest_name', 'صفر مدير', 'source_id', '00000000-0000-0000-0000-000000000021', 'nightly_rate_halalas', 0)), 'PRICE_FLOOR%');
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  e_sup := t_fails(format('select fn_staff_create_reservation(%L::jsonb)', jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'),
    'check_in', fn_branch_today('00000000-0000-0000-0000-000000000010') + 400, 'check_out', fn_branch_today('00000000-0000-0000-0000-000000000010') + 401,
    'guest_phone', '0560000012', 'guest_name', 'صفر مشرف', 'source_id', '00000000-0000-0000-0000-000000000021', 'nightly_rate_halalas', 0)), 'accepted');
  e_sup2 := t_fails(format('select fn_staff_create_free_stay(%L::jsonb)', jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'),
    'check_in', fn_branch_today('00000000-0000-0000-0000-000000000010') + 400, 'check_out', fn_branch_today('00000000-0000-0000-0000-000000000010') + 401,
    'guest_phone', '0560000013', 'guest_name', 'مجاني مشرف', 'source_id', '00000000-0000-0000-0000-000000000021', 'reason', 'مجاملة')), 'FORBIDDEN%');
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  perform t_record('4.7 a zero night price is refused for the manager and the supervisor, and the free-stay path is the owner''s alone',
    e_mgr = 'ok' and e_sup <> 'accepted' and e_sup2 = 'ok', e_mgr || ' / ' || e_sup || ' / ' || e_sup2);
  e_norsn := t_fails(format('select fn_staff_create_free_stay(%L::jsonb)', jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'),
    'check_in', fn_branch_today('00000000-0000-0000-0000-000000000010') + 400, 'check_out', fn_branch_today('00000000-0000-0000-0000-000000000010') + 401,
    'guest_phone', '0560000014', 'guest_name', 'مجاني بلا سبب', 'source_id', '00000000-0000-0000-0000-000000000021')), 'VALIDATION: reason%');
  r := fn_staff_create_free_stay(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_id', t_id('room3'),
         'check_in', fn_branch_today('00000000-0000-0000-0000-000000000010') + 400, 'check_out', fn_branch_today('00000000-0000-0000-0000-000000000010') + 402,
         'guest_phone', '0560000015', 'guest_name', 'ضيف مجاني', 'source_id', '00000000-0000-0000-0000-000000000021', 'reason', 'تعويض عن إزعاج سابق'));
  rid := (r->>'id')::uuid; insert into ids values ('resfree', rid) on conflict (k) do nothing;
  perform t_record('4.7 the free stay needs the owner''s reason, marks the stay, books zero nights, and the zero price is flagged and alerted',
    e_norsn = 'ok' and (r->>'ok')::boolean and (r->>'free_stay')::boolean
    and (select free_stay from reservations where id = rid) and (select free_stay_approved_by from reservations where id = rid) = '10000000-0000-0000-0000-000000000001'
    and t_count(format('select count(*) from reservation_nights where reservation_id = %L and status = ''active'' and price_halalas > 0', rid)) = 0
    and (t_fin(rid)->>'total')::bigint = 0
    and t_count(format('select count(*) from review_items where kind = ''zero_price'' and reservation_id = %L', rid)) = 1,
    e_norsn || ' / ' || r::text);
  perform t_record('4.7 an ordinary priced stay on the same unit type opens no zero-price item (the rule does not misfire)',
    t_count(format('select count(*) from review_items where kind = ''zero_price'' and reservation_id in (select id from reservations where id in (%L, %L))', t_id('res1'), t_id('res2'))) = 0, null);
exception when others then perform t_record('4.7 the price floor and the free stay', false, sqlerrm); end $$;

-- the floor holds even against a direct table write, not only the RPCs
reset role;
do $$ declare e text; begin
  e := t_fails(format('insert into reservation_nights(organization_id, branch_id, reservation_id, night, price_halalas, basis)
           select organization_id, branch_id, id, check_in, 0, ''manual'' from reservations where id = %L', t_id('res2')), 'PRICE_FLOOR%');
  perform t_record('4.7 a zero night written straight into the table is refused all the same',
    e = 'ok' and t_count(format('select count(*) from reservation_nights where reservation_id = %L and price_halalas <= 0', t_id('res2'))) = 0, e);
end $$;
set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');

-- ---------------------------------------------------------------- 4.8 the discount threshold: under it as before, over it the owner's prior approval and a review item with the amount
do $$ declare r jsonb; e text; begin
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'),
         'check_in', fn_branch_today('00000000-0000-0000-0000-000000000010') + 400, 'check_out', fn_branch_today('00000000-0000-0000-0000-000000000010') + 402,
         'guest_phone', '0560000020', 'guest_name', 'خصم مشرف', 'source_id', '00000000-0000-0000-0000-000000000021', 'discount_halalas', 3000, 'discount_reason', 'خصم خمسة بالمئة'));
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  perform t_record('4.8 a small discount under the hotel''s threshold passes for the supervisor exactly as before (no approval, no flag)',
    (r->>'ok')::boolean
    and t_count(format('select count(*) from review_items where kind = ''discount_over_threshold'' and reservation_id = %L', (r->>'id')::uuid)) = 0, r::text);
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'),
         'check_in', fn_branch_today('00000000-0000-0000-0000-000000000010') + 400, 'check_out', fn_branch_today('00000000-0000-0000-0000-000000000010') + 402,
         'guest_phone', '0560000021', 'guest_name', 'خصم عادي', 'source_id', '00000000-0000-0000-0000-000000000021', 'discount_halalas', 6000, 'discount_reason', 'حسم عشرة بالمئة'));
  insert into ids values ('res5', (r->>'id')::uuid) on conflict (k) do nothing;
  perform t_record('4.8 a discount under the hotel''s threshold passes at booking with no approval and no flag',
    (r->>'ok')::boolean
    and t_count(format('select count(*) from review_items where kind = ''discount_over_threshold'' and reservation_id = %L', (r->>'id')::uuid)) = 0, r::text);
exception when others then perform t_record('4.8 the threshold''s lower side', false, sqlerrm); end $$;

do $$ declare e1 text; e2 text; e3 text; a jsonb; r jsonb; v int; begin
  select version into v from reservations where id = t_id('res3');
  e1 := t_fails(format('select fn_staff_adjust_price(%L, %L, %s, %L, %L, %s)', t_id('res3'), 'discount', 15000, 'خصم كبير', 'طلب الضيف', v), 'DISCOUNT_APPROVAL_REQUIRED%');
  perform t_record('4.8 a discount that pushes the stay over the threshold is refused without the owner''s prior approval, and writes nothing',
    e1 = 'ok'
    and t_count(format('select count(*) from reservation_charges where reservation_id = %L and kind = ''discount''', t_id('res3'))) = 0, e1);
  perform t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
  e2 := t_fails(format('select fn_approve_discount(%L::jsonb)', jsonb_build_object('reservation_id', t_id('res3'), 'amount_halalas', 18000, 'reason', 'اعتماد')), 'FORBIDDEN%');
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  select version into v from reservations where id = t_id('res3');
  a := fn_approve_discount(jsonb_build_object('reservation_id', t_id('res3'), 'amount_halalas', 15000, 'reason', 'ضيف دائم — معه حجوزات قادمة'));
  r := fn_staff_adjust_price(t_id('res3'), 'discount', 15000, 'خصم معتمد', 'طلب الضيف', v);
  perform t_record('4.8 the approval is the owner''s alone; with it the same discount passes, consumes the approval, and opens a review item carrying the amount',
    e2 = 'ok' and (a->>'ok')::boolean and (r->>'ok')::boolean
    and t_count(format('select count(*) from discount_approvals where reservation_id = %L and used_at is not null and used_charge_id is not null', t_id('res3'))) = 1
    and t_count(format('select count(*) from review_items where kind = ''discount_over_threshold'' and reservation_id = %L and (details->>''amount_halalas'')::bigint = 15000', t_id('res3'))) = 1
    and t_count(format('select coalesce(sum(-total_halalas), 0) from reservation_charges where reservation_id = %L and kind = ''discount''', t_id('res3'))) = 15000,
    e2 || ' / ' || r::text);
  select version into v from reservations where id = t_id('res3');
  e3 := t_fails(format('select fn_staff_adjust_price(%L, %L, %s, %L, %L, %s)', t_id('res3'), 'discount', 6000, 'خصم ثان', 'بلا اعتماد جديد', v), 'DISCOUNT_APPROVAL_REQUIRED%');
  perform t_record('4.8 the consumed approval covers nothing further: the next over-threshold discount is refused again',
    e3 = 'ok'
    and t_count(format('select coalesce(sum(-total_halalas), 0) from reservation_charges where reservation_id = %L and kind = ''discount''', t_id('res3'))) = 15000, e3);
  perform t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
  select version into v from reservations where id = t_id('res3');
  e3 := t_fails(format('select fn_staff_adjust_price(%L, %L, %s, %L, %L, %s)', t_id('res3'), 'discount', 6000, 'خصم مدير', 'بلا اعتماد', v), 'DISCOUNT_APPROVAL_REQUIRED%');
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  perform t_record('4.8 the gate binds the manager too, not only the owner (SQL per role)',
    e3 = 'ok'
    and t_count(format('select coalesce(sum(-total_halalas), 0) from reservation_charges where reservation_id = %L and kind = ''discount''', t_id('res3'))) = 15000, e3);
exception when others then perform t_record('4.8 the approval path', false, sqlerrm); end $$;

-- =====================================================================
-- RESULTS
-- =====================================================================
reset role;
select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),150) as detail from test_results order by ok, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if (select count(*) from test_results) < 19 then raise exception 'PHASE4 MONEY CONTROLS TESTS INCOMPLETE: % of 19 checks ran', (select count(*) from test_results); end if;
  if exists (select 1 from test_results where ok is not true) then raise exception 'PHASE4 MONEY CONTROLS TESTS FAILED'; end if;
end $$;
