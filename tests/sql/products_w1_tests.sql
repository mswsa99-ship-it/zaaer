-- =====================================================================
-- Guest journey, task W1 (PR*; migration 0068): products and ordering. A catalogue of products in categories, without
-- stock, each one offered or not in each branch; a guest in their room orders (WhatsApp, with the verified token) or
-- the reception orders for them; the order waits for payment, then the payment, the voucher and the delivery task are
-- one step; the order is delivered when its task is done; a paid order is cancelled only by the owner or the manager,
-- and its voucher and task never on their own; what an order brings in is product revenue (43).
-- Tried from outside the screens.
-- =====================================================================
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create temp table ids(k text primary key, v uuid);
grant all on ids to public;
create temp table toks(k text primary key, v text);
grant all on toks to public;
create or replace function tp_login(p_uid uuid, p_email text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email)::text, false);
end $$;
create or replace function tp_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;
create or replace function tp_id(p_k text) returns uuid language sql security definer as $$ select v from ids where k = p_k $$;
create or replace function tp_tok(p_k text) returns text language sql security definer as $$ select v from toks where k = p_k $$;
create or replace function tp_fails(p_sql text, p_like text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'accepted';
exception when others then
  return case when sqlerrm like p_like then 'ok' else sqlerrm end;
end $$;
create or replace function tp_count(p_sql text) returns bigint language plpgsql security definer as $$ declare n bigint; begin execute p_sql into n; return n; end $$;
create or replace function tp_today(p uuid) returns date language sql security definer as $$ select fn_branch_today(p) $$;
create or replace function tp_bal(p_branch uuid, p_key text) returns bigint language sql security definer as $$
  select coalesce(sum(l.credit_halalas - l.debit_halalas), 0)::bigint from journal_lines l join journal_entries e on e.id = l.entry_id join gl_accounts g on g.id = l.account_id
  where e.branch_id = p_branch and g.system_key = p_key $$;
create or replace function tp_due(p uuid) returns bigint language sql security definer as $$ select (fn_reservation_finance_internal(p)->>'balance_due')::bigint $$;
create or replace function tp_order(p uuid) returns product_orders language sql security definer as $$ select * from product_orders where id = p $$;
create or replace function tp_items(variadic p text[]) returns jsonb language sql immutable as $$
  select jsonb_agg(jsonb_build_object('product_id', p[i], 'quantity', p[i + 1]::int) order by i) from generate_series(1, array_length(p, 1), 2) i $$;
-- a stay checked in to a room (the arrival itself is tried elsewhere)
create or replace function tp_check_in(p_res uuid, p_room uuid) returns void language sql security definer as $$
  update reservations set status = 'checked_in', room_id = p_room, actual_check_in = now() where id = p_res $$;
create or replace function tp_stay_due(p uuid) returns jsonb language sql security definer as $$ select fn_stay_due_internal(p) $$;
create or replace function tp_guest_cancel(p_token text, p_number text) returns jsonb language sql security definer as $$ select fn_guest_cancel_product_order(p_token, p_number) $$;
create or replace function tp_token(p uuid) returns text language sql security definer as $$ insert into registration_sessions(reservation_id) values (p) returning token $$;

-- ---------------------------------------------------------------- two branches, stays, a manager of the first only
select tp_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; b uuid; b2 uuid; b3 uuid; cat uuid; cat2 uuid; cat3 uuid; res uuid; begin
  r := fn_admin_upsert_branch('{"name_ar":"فرع المنتجات","name_en":"Products branch","tax_rate_bp":0}'); b := (r->>'id')::uuid;
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', b, 'name_ar', 'غرفة المنتجات', 'base_price_halalas', 30000)); cat := (r->>'id')::uuid;
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', '961')); insert into ids values ('room1', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', '962')); insert into ids values ('room2', (r->>'id')::uuid);
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b, 'category_id', cat, 'check_in', tp_today(b)::text, 'check_out', (tp_today(b) + 2)::text,
         'guest_phone', '0551000096', 'guest_name', 'نزيل المنتجات', 'source_id', '00000000-0000-0000-0000-000000000021'));
  insert into ids values ('b', b), ('res1', (r->>'id')::uuid);
  -- an ordinary receipt of the stay (not an order's)
  perform fn_create_voucher(jsonb_build_object('reservation_id', (r->>'id')::uuid, 'kind', 'receipt', 'amount_halalas', 10000, 'method', 'cash', 'idempotency_key', 'pr-base'));
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b, 'category_id', cat, 'check_in', (tp_today(b) + 5)::text, 'check_out', (tp_today(b) + 6)::text,
         'guest_phone', '0551000097', 'guest_name', 'نزيل لم يصل', 'source_id', '00000000-0000-0000-0000-000000000021'));
  insert into ids values ('res2', (r->>'id')::uuid);
  -- a second branch, which the manager does not work in
  r := fn_admin_upsert_branch('{"name_ar":"فرع المنتجات الثاني","name_en":"Products branch two","tax_rate_bp":0}'); b2 := (r->>'id')::uuid;
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', b2, 'name_ar', 'غرفة الفرع الثاني', 'base_price_halalas', 30000)); cat2 := (r->>'id')::uuid;
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', b2, 'category_id', cat2, 'room_number', '971')); insert into ids values ('room3', (r->>'id')::uuid);
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b2, 'category_id', cat2, 'check_in', tp_today(b2)::text, 'check_out', (tp_today(b2) + 1)::text,
         'guest_phone', '0551000098', 'guest_name', 'نزيل الفرع الثاني', 'source_id', '00000000-0000-0000-0000-000000000021'));
  insert into ids values ('b2', b2), ('res3', (r->>'id')::uuid);
  -- a third branch with tax added on top of the price (15%)
  r := fn_admin_upsert_branch('{"name_ar":"فرع الضريبة","name_en":"Tax branch","tax_rate_bp":1500}'); b3 := (r->>'id')::uuid;
  update branches set prices_include_tax = false where id = b3;
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', b3, 'name_ar', 'غرفة الضريبة', 'base_price_halalas', 30000)); cat3 := (r->>'id')::uuid;
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', b3, 'category_id', cat3, 'room_number', '981')); insert into ids values ('room4', (r->>'id')::uuid);
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b3, 'category_id', cat3, 'check_in', tp_today(b3)::text, 'check_out', (tp_today(b3) + 1)::text,
         'guest_phone', '0551000099', 'guest_name', 'نزيل الضريبة', 'source_id', '00000000-0000-0000-0000-000000000021'));
  insert into ids values ('b3', b3), ('res4', (r->>'id')::uuid);
exception when others then perform tp_record('PD00 the branches and the stays are set up', false, sqlerrm);
end $$;
reset role;
select tp_check_in(tp_id('res1'), tp_id('room1'));
select tp_check_in(tp_id('res3'), tp_id('room3'));
select tp_check_in(tp_id('res4'), tp_id('room4'));
update branches set prices_include_tax = false where id = tp_id('b3');
insert into toks values ('t1', tp_token(tp_id('res1'))), ('t2', tp_token(tp_id('res2'))), ('t3', tp_token(tp_id('res3'))), ('t4', tp_token(tp_id('res4')));
insert into branch_memberships(staff_id, branch_id) select s, tp_id('b') from unnest(array['10000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000008']::uuid[]) s
  where not exists (select 1 from branch_memberships where staff_id = s and branch_id = tp_id('b'));

-- ---------------------------------------------------------------- PD01 the catalogue
select tp_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; c1 uuid; c2 uuid; c3 uuid; e_name text; e_price text; e_price2 text; e_cat text; e_dup text; e_ver text; e_dupc text; v int; begin
  r := fn_admin_upsert_product_category('{"name":"مشروبات"}'); c1 := (r->>'id')::uuid;
  r := fn_admin_upsert_product_category('{"name":"وجبات خفيفة"}'); c2 := (r->>'id')::uuid;
  r := fn_admin_upsert_product_category('{"name":"مستلزمات"}'); c3 := (r->>'id')::uuid;
  insert into ids values ('c1', c1), ('c2', c2), ('c3', c3);
  r := fn_admin_upsert_product(jsonb_build_object('category_id', c1, 'name', 'ماء', 'price_halalas', 200)); insert into ids values ('water', (r->>'id')::uuid);
  r := fn_admin_upsert_product(jsonb_build_object('category_id', c1, 'name', 'قهوة', 'price_halalas', 800, 'description', 'قهوة سوداء')); insert into ids values ('coffee', (r->>'id')::uuid);
  r := fn_admin_upsert_product(jsonb_build_object('category_id', c2, 'name', 'بسكويت', 'price_halalas', 350)); insert into ids values ('biscuit', (r->>'id')::uuid);
  r := fn_admin_upsert_product(jsonb_build_object('category_id', c3, 'name', 'فرشاة أسنان', 'price_halalas', 500, 'taxable', false)); insert into ids values ('brush', (r->>'id')::uuid);
  e_name := tp_fails(format('select fn_admin_upsert_product(%L)', jsonb_build_object('category_id', c1, 'name', ' ', 'price_halalas', 100)), 'VALIDATION: product_name%');
  e_price := tp_fails(format('select fn_admin_upsert_product(%L)', jsonb_build_object('category_id', c1, 'name', 'عصير', 'price_halalas', 0)), 'VALIDATION: product_price%');
  e_price2 := tp_fails(format('select fn_admin_upsert_product(%L)', jsonb_build_object('category_id', c1, 'name', 'عصير', 'price_halalas', '1.5')), 'VALIDATION: product_price%');
  e_cat := tp_fails(format('select fn_admin_upsert_product(%L)', jsonb_build_object('category_id', gen_random_uuid(), 'name', 'عصير', 'price_halalas', 100)), 'VALIDATION: product_category%');
  e_dup := tp_fails(format('select fn_admin_upsert_product(%L)', jsonb_build_object('category_id', c2, 'name', 'ماء', 'price_halalas', 100)), 'DUPLICATE_NAME%');
  e_dupc := tp_fails('select fn_admin_upsert_product_category(''{"name":"مشروبات"}'')', 'DUPLICATE_NAME%');
  select version into v from products where id = tp_id('water');
  perform fn_admin_upsert_product(jsonb_build_object('id', tp_id('water'), 'version', v, 'category_id', c1, 'name', 'ماء', 'price_halalas', 250));
  e_ver := tp_fails(format('select fn_admin_upsert_product(%L)', jsonb_build_object('id', tp_id('water'), 'version', v, 'category_id', c1, 'name', 'ماء', 'price_halalas', 300)), '%VERSION%');
  perform tp_record('PD01 the owner keeps the catalogue: categories and products with a price and no stock; a blank name, a zero or broken price, an unknown category, a repeated name and a stale edit are refused',
    e_name = 'ok' and e_price = 'ok' and e_price2 = 'ok' and e_cat = 'ok' and e_dup = 'ok' and e_dupc = 'ok' and e_ver = 'ok'
    and (select price_halalas from products where id = tp_id('water')) = 250
    and jsonb_array_length(fn_admin_products()->'categories') >= 3 and jsonb_array_length(fn_admin_products()->'products') >= 4,
    concat_ws(' / ', e_name, e_price, e_price2, e_cat, e_dup, e_dupc, e_ver));
exception when others then perform tp_record('PD01 the owner keeps the catalogue: categories and products with a price and no stock; a blank name, a zero or broken price, an unknown category, a repeated name and a stale edit are refused', false, sqlerrm);
end $$;
reset role;
select tp_login('a0000000-0000-0000-0000-000000000002', 'supervisor@test.local');
set role authenticated;
select tp_record('PD01b a supervisor does not change the catalogue (the «definitions» operation)',
  tp_fails(format('select fn_admin_upsert_product(%L)', jsonb_build_object('category_id', tp_id('c1'), 'name', 'شاي', 'price_halalas', 300)), 'FORBIDDEN%') = 'ok'
  and tp_fails(format('select fn_admin_set_product_branch(%L, %L, true)', tp_id('water'), tp_id('b')), 'FORBIDDEN%') = 'ok');
reset role;

-- ---------------------------------------------------------------- PD02 offered by branch
select tp_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare m jsonb; m2 jsonb; names text; begin
  perform fn_admin_set_product_branch(tp_id('water'), tp_id('b'), true);
  perform fn_admin_set_product_branch(tp_id('coffee'), tp_id('b'), true);
  perform fn_admin_set_product_branch(tp_id('biscuit'), tp_id('b'), true);
  perform fn_admin_set_product_branch(tp_id('brush'), tp_id('b'), true);
  perform fn_admin_set_product_branch(tp_id('water'), tp_id('b2'), true);
  perform fn_admin_set_product_branch(tp_id('water'), tp_id('b3'), true);
  perform fn_admin_set_product_branch(tp_id('brush'), tp_id('b3'), true);
  -- the biscuit taken off in the first branch; the third category made inactive, then active again
  perform fn_admin_set_product_branch(tp_id('biscuit'), tp_id('b'), false);
  m := fn_staff_product_menu(tp_id('b'))->'categories'; m2 := fn_staff_product_menu(tp_id('b2'))->'categories';
  select string_agg(p->>'name', ',' order by p->>'name') into names from jsonb_array_elements(m) c, jsonb_array_elements(c->'products') p;
  perform tp_record('PD02 a branch offers only what the owner made available there, in categories; another branch offers its own',
    names = 'فرشاة أسنان,قهوة,ماء' and jsonb_array_length(m2) = 1 and m2->0->'products'->0->>'name' = 'ماء'
    and not exists (select 1 from jsonb_array_elements(m) c where c->>'name' = 'وجبات خفيفة'), coalesce(names, '') || ' | ' || m2::text);
exception when others then perform tp_record('PD02 a branch offers only what the owner made available there, in categories; another branch offers its own', false, sqlerrm);
end $$;
reset role;
select tp_login('a0000000-0000-0000-0000-000000000008', 'manager@test.local');
set role authenticated;
select tp_record('PD02b a manager sets what their own branch offers, never another branch''s',
  tp_fails(format('select fn_admin_set_product_branch(%L, %L, true)', tp_id('coffee'), tp_id('b2')), 'FORBIDDEN%') = 'ok'
  and tp_fails(format('select fn_admin_set_product_branch(%L, %L, true)', tp_id('coffee'), tp_id('b')), '%') = 'accepted');
reset role;

-- ---------------------------------------------------------------- PD03 the guest orders from WhatsApp (service role, verified token)
set role service_role;
do $$ declare g jsonb; o jsonb; o2 jsonb; notin text; gone text; bad1 text; bad2 text; bad3 text; bad4 text; badtok text; begin
  g := fn_guest_products(tp_tok('t1'));
  o := fn_guest_order_products(tp_tok('t1'), tp_items(tp_id('water')::text, '2', tp_id('coffee')::text, '1'));
  o2 := fn_guest_order_products(tp_tok('t1'), tp_items(tp_id('water')::text, '1'));
  insert into ids values ('o1', (o->>'id')::uuid);
  notin := tp_fails(format('select fn_guest_order_products(%L, %L)', tp_tok('t2'), tp_items(tp_id('water')::text, '1')), 'VALIDATION: not_in_stay%');
  gone := tp_fails(format('select fn_guest_order_products(%L, %L)', tp_tok('t1'), tp_items(tp_id('biscuit')::text, '1')), 'VALIDATION: product_unavailable%');
  bad1 := tp_fails(format('select fn_guest_order_products(%L, %L)', tp_tok('t1'), tp_items(tp_id('water')::text, '0')), 'VALIDATION: items%');
  bad2 := tp_fails(format('select fn_guest_order_products(%L, %L)', tp_tok('t1'), tp_items(tp_id('water')::text, '51')), 'VALIDATION: items%');
  bad3 := tp_fails(format('select fn_guest_order_products(%L, %L)', tp_tok('t1'), '[]'), 'VALIDATION: items%');
  bad4 := tp_fails(format('select fn_guest_order_products(%L, %L)', tp_tok('t1'), tp_items(tp_id('water')::text, '50')), 'VALIDATION: order_quantity%');
  badtok := tp_fails(format('select fn_guest_order_products(%L, %L)', 'NOTATOKEN', tp_items(tp_id('water')::text, '1')), 'TOKEN_INVALID%');
  perform tp_record('PD03 a guest in their room orders from WhatsApp: the order waits for payment and the next item joins it; a stay not checked in, a product not offered there, a broken list and an unknown token are refused',
    (g->>'can_order')::boolean and jsonb_array_length(g->'categories') = 2
    and o->>'status' = 'pending_payment' and (o->>'total_halalas')::bigint = 2 * 250 + 800
    and o2->>'id' = o->>'id' and (o2->>'total_halalas')::bigint = 3 * 250 + 800
    and exists (select 1 from jsonb_array_elements(o2->'lines') l where l->>'name' = 'ماء' and (l->>'quantity')::int = 3)
    and notin = 'ok' and gone = 'ok' and bad1 = 'ok' and bad2 = 'ok' and bad3 = 'ok' and bad4 = 'ok' and badtok = 'ok'
    and not (fn_guest_products(tp_tok('t2'))->>'can_order')::boolean,
    concat_ws(' / ', o2::text, notin, gone, bad1, bad2, bad3, bad4, badtok));
exception when others then perform tp_record('PD03 a guest in their room orders from WhatsApp: the order waits for payment and the next item joins it; a stay not checked in, a product not offered there, a broken list and an unknown token are refused', false, sqlerrm);
end $$;
reset role;
select tp_record('PD03b the orders tell the reception: one notice per new order, and the order is in the log',
  tp_count(format('select count(*) from notifications where branch_id = %L and title = ''طلب منتجات بانتظار الدفع''', tp_id('b'))) = 1
  and tp_count(format('select count(*) from audit_events where entity_id = %L and action in (''product_order.created'', ''product_order.added'')', tp_id('o1'))) = 2);

-- ---------------------------------------------------------------- PD04 the guest cancels while it waits
set role service_role;
do $$ declare o jsonb; c jsonb; other text; again text; begin
  o := fn_guest_order_products(tp_tok('t3'), tp_items(tp_id('water')::text, '1'));
  insert into ids values ('o3', (o->>'id')::uuid);
  other := tp_fails(format('select fn_guest_cancel_product_order(%L, %L)', tp_tok('t1'), o->>'number'), 'NOT_FOUND%');
  c := fn_guest_cancel_product_order(tp_tok('t3'), o->>'number');
  again := tp_fails(format('select fn_guest_cancel_product_order(%L, %L)', tp_tok('t3'), o->>'number'), 'VALIDATION: order_status%');
  perform tp_record('PD04 the guest cancels their own order while it waits for payment, not another stay''s, and only once',
    c->>'status' = 'cancelled' and other = 'ok' and again = 'ok', concat_ws(' / ', other, again));
exception when others then perform tp_record('PD04 the guest cancels their own order while it waits for payment, not another stay''s, and only once', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- PD05 payment, then the voucher, then the delivery task
select tp_login('a0000000-0000-0000-0000-000000000002', 'supervisor@test.local');
set role authenticated;
do $$ declare due0 bigint; rent0 bigint; prod0 bigint; p jsonb; dup jsonb; other text; badm text; o product_orders; v financial_vouchers; t housekeeping_tasks; ch bigint; begin
  due0 := tp_due(tp_id('res1')); rent0 := tp_bal(tp_id('b'), 'rent_revenue'); prod0 := tp_bal(tp_id('b'), 'product_revenue');
  -- a platform never collects for an order: paid at the hotel only
  badm := tp_fails(format('select fn_staff_pay_product_order(%L)', jsonb_build_object('order_id', tp_id('o1'), 'expected_version', (select version from product_orders where id = tp_id('o1')), 'method', 'ota_deferred', 'idempotency_key', 'pr-pay-0')), 'VALIDATION: order_method%');
  p := fn_staff_pay_product_order(jsonb_build_object('order_id', tp_id('o1'), 'expected_version', (select version from product_orders where id = tp_id('o1')), 'method', 'cash', 'idempotency_key', 'pr-pay-1'));
  dup := fn_staff_pay_product_order(jsonb_build_object('order_id', tp_id('o1'), 'expected_version', (select version from product_orders where id = tp_id('o1')), 'method', 'cash', 'idempotency_key', 'pr-pay-1'));
  other := tp_fails(format('select fn_staff_pay_product_order(%L)', jsonb_build_object('order_id', tp_id('o1'), 'expected_version', (select version from product_orders where id = tp_id('o1')), 'method', 'cash', 'idempotency_key', 'pr-pay-2')), 'VALIDATION: order_status%');
  o := tp_order(tp_id('o1'));
  select * into v from financial_vouchers where id = o.voucher_id;
  select * into t from housekeeping_tasks where id = o.task_id;
  select coalesce(sum(total_halalas), 0) into ch from reservation_charges where product_order_id = o.id;
  insert into ids values ('v1', o.voucher_id), ('task1', o.task_id);
  perform tp_record('PD05 the reception takes the payment: the lines join the stay''s account and a receipt of the same amount pays them (the balance does not move), a delivery task for the room is created, all in one step; the same request again returns it, another is refused',
    p->>'duplicate' = 'false' and dup->>'duplicate' = 'true' and other = 'ok' and badm = 'ok'
    and o.status = 'paid' and o.total_halalas = 1550 and v.amount_halalas = 1550 and v.kind = 'receipt' and v.status = 'approved' and v.product_order_id = o.id
    and ch = 1550 and tp_due(tp_id('res1')) = due0
    and t.status = 'pending' and t.room_id = tp_id('room1') and t.reservation_id is null
    and (select code from task_types where id = t.task_type_id) = 'product_delivery' and t.description like '%3 × ماء%',
    concat_ws(' / ', p::text, badm, o.status, o.total_halalas::text, ch::text, tp_due(tp_id('res1'))::text, due0::text));
  perform tp_record('PD05b what the order brought in is product revenue (43), not rent',
    tp_bal(tp_id('b'), 'product_revenue') = prod0 + 1550 and tp_bal(tp_id('b'), 'rent_revenue') = rent0,
    tp_bal(tp_id('b'), 'product_revenue')::text || ' / ' || tp_bal(tp_id('b'), 'rent_revenue')::text);
exception when others then perform tp_record('PD05 the reception takes the payment: the lines join the stay''s account and a receipt of the same amount pays them (the balance does not move), a delivery task for the room is created, all in one step; the same request again returns it, another is refused', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- PD06 the order's voucher and task are not undone on their own
select tp_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare cv text; ct text; cc text; begin
  cv := tp_fails(format('select fn_cancel_voucher(%L, %L)', tp_id('v1'), 'خطأ'), 'VALIDATION: order_voucher%');
  ct := tp_fails(format('select fn_hk_cancel_task(%L, %L)', tp_id('task1'), 'لا داعي'), 'VALIDATION: order_task%');
  cc := tp_fails(format('select fn_staff_correct_voucher(%L)', jsonb_build_object('voucher_id', tp_id('v1'), 'reason', 'تصحيح', 'idempotency_key', 'pr-corr', 'amount_halalas', 1000)), 'VALIDATION: order_voucher%');
  perform tp_record('PD06 the voucher of an order is not cancelled or corrected on its own, and its delivery task is not cancelled on its own: the order is cancelled instead',
    cv = 'ok' and ct = 'ok' and cc = 'ok' and (tp_order(tp_id('o1'))).status = 'paid', concat_ws(' / ', cv, ct, cc));
exception when others then perform tp_record('PD06 the voucher of an order is not cancelled or corrected on its own, and its delivery task is not cancelled on its own: the order is cancelled instead', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- PD07 delivered when its task is done
select tp_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare cd text; begin
  perform fn_hk_complete_task(tp_id('task1'), 'سُلِّم للنزيل', (select version from housekeeping_tasks where id = tp_id('task1')));
  cd := tp_fails(format('select fn_staff_cancel_product_order(%L, %L)', tp_id('o1'), 'تراجع'), 'VALIDATION: order_delivered%');
  perform tp_record('PD07 the order is delivered when its delivery task is done; a delivered order is not cancelled',
    (tp_order(tp_id('o1'))).status = 'delivered' and (tp_order(tp_id('o1'))).delivered_at is not null and cd = 'ok', cd);
exception when others then perform tp_record('PD07 the order is delivered when its delivery task is done; a delivered order is not cancelled', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- PD08 a paid order cancelled by the owner
set role service_role;
select (fn_guest_order_products(tp_tok('t1'), tp_items(tp_id('coffee')::text, '2'))->>'id') is not null;
reset role;
insert into ids select 'o2', id from product_orders where reservation_id = tp_id('res1') and status = 'pending_payment';
select tp_login('a0000000-0000-0000-0000-000000000002', 'supervisor@test.local');
set role authenticated;
select (fn_staff_pay_product_order(jsonb_build_object('order_id', tp_id('o2'), 'expected_version', (select version from product_orders where id = tp_id('o2')), 'method', 'cash', 'idempotency_key', 'pr-pay-o2'))->>'ok')::boolean;
select tp_record('PD08a a supervisor does not cancel a paid order (cancelling its voucher is the owner''s or the manager''s)',
  tp_fails(format('select fn_staff_cancel_product_order(%L, %L)', tp_id('o2'), 'النزيل لم يعد يريده'), 'FORBIDDEN%') = 'ok');
reset role;
select tp_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare due0 bigint; prod0 bigint; c jsonb; o product_orders; noreason text; ch bigint; begin
  due0 := tp_due(tp_id('res1')); prod0 := tp_bal(tp_id('b'), 'product_revenue');
  noreason := tp_fails(format('select fn_staff_cancel_product_order(%L, %L)', tp_id('o2'), ' '), 'VALIDATION: reason%');
  c := fn_staff_cancel_product_order(tp_id('o2'), 'النزيل لم يعد يريده');
  o := tp_order(tp_id('o2'));
  select coalesce(sum(total_halalas), 0) into ch from reservation_charges where product_order_id = o.id;
  perform tp_record('PD08 the owner cancels a paid order not yet delivered, with a reason: its voucher is cancelled (the revenue is reversed), its charges are balanced back, its delivery task is cancelled, the stay''s balance does not move',
    noreason = 'ok' and o.status = 'cancelled' and (select status from financial_vouchers where id = o.voucher_id) = 'cancelled'
    and (select status from housekeeping_tasks where id = o.task_id) = 'cancelled'
    and ch = 0 and tp_due(tp_id('res1')) = due0 and tp_bal(tp_id('b'), 'product_revenue') = prod0 - 1600,
    concat_ws(' / ', o.status, ch::text, tp_due(tp_id('res1'))::text, due0::text, tp_bal(tp_id('b'), 'product_revenue')::text, prod0::text));
exception when others then perform tp_record('PD08 the owner cancels a paid order not yet delivered, with a reason: its voucher is cancelled (the revenue is reversed), its charges are balanced back, its delivery task is cancelled, the stay''s balance does not move', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- PD09 branches apart
set role service_role;
select (fn_guest_order_products(tp_tok('t3'), tp_items(tp_id('water')::text, '1'))->>'id') is not null;
reset role;
insert into ids select 'o4', id from product_orders where reservation_id = tp_id('res3') and status = 'pending_payment';
select tp_login('a0000000-0000-0000-0000-000000000008', 'manager@test.local');
set role authenticated;
select tp_record('PD09 a manager reads and pays the orders of their branch only: another branch''s are neither listed, read nor paid',
  tp_fails(format('select fn_staff_product_orders(%L)', tp_id('b2')), 'FORBIDDEN%') = 'ok'
  and tp_fails(format('select fn_staff_pay_product_order(%L)', jsonb_build_object('order_id', tp_id('o4'), 'expected_version', (select version from product_orders where id = tp_id('o4')), 'method', 'cash', 'idempotency_key', 'pr-x')), 'FORBIDDEN%') = 'ok'
  and tp_fails(format('select fn_staff_create_product_order(%L, %L)', tp_id('res3'), tp_items(tp_id('water')::text, '1')), 'FORBIDDEN%') = 'ok'
  and (select count(*) from product_orders where branch_id = tp_id('b2')) = 0
  and (select count(*) from product_orders where branch_id = tp_id('b')) >= 2
  and jsonb_array_length(fn_staff_product_orders(tp_id('b'))) >= 2);
reset role;

-- ---------------------------------------------------------------- PD10 nothing written past the functions
select tp_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
select tp_record('PD10 the tables are read-only to the screens: an order, a line, a product or an availability is not written directly; a voucher is not tied to an order by hand',
  tp_fails(format('update product_orders set status = %L where id = %L', 'delivered', tp_id('o4')), '%permission denied%') = 'ok'
  and tp_fails(format('insert into product_order_lines(organization_id, order_id, product_id, name, unit_price_halalas, quantity, taxable, total_halalas) select organization_id, %L, %L, %L, 1, 1, false, 1 from branches where id = %L', tp_id('o4'), tp_id('water'), 'x', tp_id('b')), '%permission denied%') = 'ok'
  and tp_fails(format('update products set price_halalas = 1 where id = %L', tp_id('water')), '%permission denied%') = 'ok'
  and tp_fails(format('insert into product_branches(product_id, branch_id, organization_id, available) select %L, %L, organization_id, true from branches where id = %L', tp_id('biscuit'), tp_id('b'), tp_id('b')), '%permission denied%') = 'ok');
reset role;
select tp_record('PD10b a guest''s function is not open to the browser: only the WhatsApp webhook (service role) calls it',
  (select not has_function_privilege('anon', 'fn_guest_order_products(text, jsonb, uuid)', 'execute'))
  and (select not has_function_privilege('authenticated', 'fn_guest_order_products(text, jsonb, uuid)', 'execute'))
  and (select not has_function_privilege('anon', 'fn_guest_products(text)', 'execute'))
  and (select not has_function_privilege('authenticated', 'fn_product_order_add(uuid, jsonb, text, uuid)', 'execute')));
do $$ declare r text; begin
  r := tp_fails(format('update financial_vouchers set product_order_id = %L where id = (select id from financial_vouchers where reservation_id = %L and product_order_id is null limit 1)', tp_id('o4'), tp_id('res1')), 'VALIDATION: order_voucher%');
  perform tp_record('PD10c even the database owner cannot tie a voucher to an order afterwards', r = 'ok', r);
end $$;

-- ---------------------------------------------------------------- PD11 tax on top, as on any charge
set role service_role;
do $$ declare o jsonb; begin
  o := fn_guest_order_products(tp_tok('t4'), tp_items(tp_id('water')::text, '2', tp_id('brush')::text, '1'));
  insert into ids values ('o5', (o->>'id')::uuid);
exception when others then perform tp_record('PD11 the order of a branch that adds tax carries the tax of its taxable lines, and the voucher pays exactly what the stay''s account carries', false, sqlerrm);
end $$;
reset role;
select tp_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare due0 bigint; p jsonb; ch bigint; begin
  due0 := tp_due(tp_id('res4'));
  p := fn_staff_pay_product_order(jsonb_build_object('order_id', tp_id('o5'), 'expected_version', (select version from product_orders where id = tp_id('o5')), 'method', 'cash', 'idempotency_key', 'pr-tax'));
  select coalesce(sum(total_halalas), 0) into ch from reservation_charges where product_order_id = tp_id('o5');
  -- water 2 × 2.50 = 5.00 + 15% = 5.75; the brush is not taxable: 5.00
  perform tp_record('PD11 the order of a branch that adds tax carries the tax of its taxable lines, and the voucher pays exactly what the stay''s account carries',
    (tp_order(tp_id('o5'))).total_halalas = 575 + 500 and ch = 1075
    and (select amount_halalas from financial_vouchers where id = (tp_order(tp_id('o5'))).voucher_id) = 1075 and tp_due(tp_id('res4')) = due0
    and tp_count(format('select count(*) from reservation_charges where product_order_id = %L and kind = ''tax''', tp_id('o5'))) = 1,
    concat_ws(' / ', (tp_order(tp_id('o5'))).total_halalas::text, ch::text));
exception when others then perform tp_record('PD11 the order of a branch that adds tax carries the tax of its taxable lines, and the voucher pays exactly what the stay''s account carries', false, sqlerrm);
end $$;
reset role;

select tp_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare c jsonb; tx bigint; tot bigint; due0 bigint; begin
  due0 := tp_due(tp_id('res4'));
  c := fn_staff_cancel_product_order(tp_id('o5'), 'خطأ في الطلب');
  select coalesce(sum(total_halalas) filter (where kind = 'tax'), 0), coalesce(sum(total_halalas), 0) into tx, tot from reservation_charges where product_order_id = tp_id('o5');
  perform tp_record('PD11b cancelling a paid order reverses its tax with it: the order''s tax lines and all its lines net to zero, the stay''s balance does not move',
    c->>'status' = 'cancelled' and tx = 0 and tot = 0 and tp_due(tp_id('res4')) = due0
    and tp_count(format('select count(*) from reservation_charges where product_order_id = %L and kind = ''tax'' and total_halalas < 0', tp_id('o5'))) = 1,
    concat_ws(' / ', tx::text, tot::text, tp_due(tp_id('res4'))::text, due0::text));
exception when others then perform tp_record('PD11b cancelling a paid order reverses its tax with it: the order''s tax lines and all its lines net to zero, the stay''s balance does not move', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- PD12 the reception orders for a guest
select tp_login('a0000000-0000-0000-0000-000000000002', 'supervisor@test.local');
set role authenticated;
do $$ declare o jsonb; m jsonb; notin text; begin
  m := fn_staff_product_menu(tp_id('b'));
  o := fn_staff_create_product_order(tp_id('res1'), tp_items(tp_id('water')::text, '1'));
  notin := tp_fails(format('select fn_staff_create_product_order(%L, %L)', tp_id('res2'), tp_items(tp_id('water')::text, '1')), 'VALIDATION: not_in_stay%');
  perform tp_record('PD12 the reception orders for a guest in their room (an order of its own, apart from the WhatsApp one) and sees the stays it can order for; not for a stay not checked in',
    o->>'source' = 'staff' and o->>'status' = 'pending_payment' and notin = 'ok'
    and exists (select 1 from jsonb_array_elements(m->'stays') s where s->>'id' = tp_id('res1')::text)
    and not exists (select 1 from jsonb_array_elements(m->'stays') s where s->>'id' = tp_id('res2')::text),
    concat_ws(' / ', o::text, notin));
exception when others then perform tp_record('PD12 the reception orders for a guest in their room (an order of its own, apart from the WhatsApp one) and sees the stays it can order for; not for a stay not checked in', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- PD13 the amounts are money
select tp_login('a0000000-0000-0000-0000-000000000003', 'hk@test.local');
set role authenticated;
select tp_record('PD13 an order carries amounts: a role that does not see money (housekeeping) reads no order and no line, even in its branch, and has no orders screen',
  (select count(*) from product_orders) = 0 and (select count(*) from product_order_lines) = 0
  and tp_fails(format('select fn_staff_product_orders(%L)', tp_id('b')), 'FORBIDDEN%') = 'ok');
reset role;
select tp_record('PD13b the orders are there to be read by who sees money', tp_count(format('select count(*) from product_orders where branch_id = %L', tp_id('b'))) >= 2);

-- ---------------------------------------------------------------- PD15–PD19 the independent review's cases
select tp_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare o jsonb; oid uuid; v0 int; stale text; due0 jsonb; due1 jsonb; paid jsonb; g text; begin
  -- PD15: what is paid is what the cashier was shown
  o := fn_staff_create_product_order(tp_id('res1'), tp_items(tp_id('water')::text, '1')); oid := (o->>'id')::uuid; v0 := (o->>'version')::int;
  g := tp_fails(format('select tp_guest_cancel(%L, %L)', (select v from toks where k = 't1'), o->>'number'), 'VALIDATION: order_status%');
  perform fn_staff_create_product_order(tp_id('res1'), tp_items(tp_id('coffee')::text, '1'));
  stale := tp_fails(format('select fn_staff_pay_product_order(%L)', jsonb_build_object('order_id', oid, 'method', 'cash', 'idempotency_key', 'pd15', 'expected_version', v0)), 'VERSION_CONFLICT%');
  perform tp_record('PD15 an item added after the cashier opened the payment refuses it (the order is not the one shown), and nothing is paid; without the version seen it is refused too',
    stale = 'ok' and (select status from product_orders where id = oid) = 'pending_payment'
    and tp_fails(format('select fn_staff_pay_product_order(%L)', jsonb_build_object('order_id', oid, 'method', 'cash', 'idempotency_key', 'pd15b')), 'VERSION_REQUIRED%') = 'ok', stale);
  perform tp_record('PD15b the guest cancels from WhatsApp only what they ordered there, not the reception''s order', g = 'ok', g);
  -- PD16: a paid order cancelled leaves the stay's night-by-night dues as they were
  due0 := tp_stay_due(tp_id('res1'));
  paid := fn_staff_pay_product_order(jsonb_build_object('order_id', oid, 'method', 'cash', 'idempotency_key', 'pd16', 'expected_version', (select version from product_orders where id = oid)));
  perform fn_staff_cancel_product_order(oid, 'تجربة المستحقات');
  due1 := tp_stay_due(tp_id('res1'));
  perform tp_record('PD16 a paid order cancelled the same day: each of its rows gets its exact opposite of the same kind, so the stay''s night-by-night dues (and what is overdue) are as before the order',
    due1 = due0 and not exists (select 1 from reservation_charges where product_order_id = oid and kind = 'adjustment')
    and (select coalesce(sum(total_halalas), 0) from reservation_charges where product_order_id = oid) = 0, left(due0::text, 150) || ' / ' || left(due1::text, 150));
exception when others then perform tp_record('PD15 the review''s payment and cancellation cases ran', false, sqlerrm);
end $$;
reset role;

-- PD17: a receipt of a day that is over is not erased; lines on an invoice are not reversed
select tp_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare o jsonb; begin
  o := fn_staff_create_product_order(tp_id('res1'), tp_items(tp_id('water')::text, '1'));
  o := fn_staff_pay_product_order(jsonb_build_object('order_id', o->>'id', 'method', 'cash', 'idempotency_key', 'pd17', 'expected_version', o->'version'))->'order';
  insert into ids values ('o17', (o->>'id')::uuid);
end $$;
reset role;
update financial_vouchers set occurred_at = occurred_at - interval '2 days' where id = (select voucher_id from product_orders where id = tp_id('o17'));
set role authenticated;
select tp_record('PD17 a paid order whose receipt is of a day that is over is not cancelled (that day''s figures stay): it is delivered instead',
  tp_fails(format('select fn_staff_cancel_product_order(%L, %L)', tp_id('o17'), 'متأخر'), 'VALIDATION: order_cancel_day%') = 'ok'
  and (select status from product_orders where id = tp_id('o17')) = 'paid');
reset role;

-- PD18: the stay moves, then ends
insert into ids select 'o18', (fn_product_order_add(tp_id('res1'), tp_items(tp_id('water')::text, '1'), 'whatsapp', null)->>'id')::uuid;
update reservations set room_id = tp_id('room2') where id = tp_id('res1');
select tp_record('PD18 the guest moves to another room: the delivery of a paid order follows them',
  (select room_id from housekeeping_tasks where id = (select task_id from product_orders where id = tp_id('o17'))) = tp_id('room2'));
update reservations set status = 'checked_out' where id = tp_id('res1');
select tp_record('PD18b the guest leaves: an order still waiting for its payment is cancelled with its reason, and a paid one not delivered says on its task that the guest has left',
  (select status || ' ' || cancel_reason from product_orders where id = tp_id('o18')) = 'cancelled غادر النزيل قبل الدفع'
  and (select description from housekeeping_tasks where id = (select task_id from product_orders where id = tp_id('o17'))) like 'غادر النزيل — راجع الاستقبال قبل التسليم. تسليم %'
  and (select status from product_orders where id = tp_id('o17')) = 'paid');

-- PD19: what another branch sells is not the manager's to change
select tp_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
select (fn_admin_set_product_branch(tp_id('coffee'), tp_id('b2'), true)->>'ok')::boolean;
reset role;
select tp_login('a0000000-0000-0000-0000-000000000008', 'manager@test.local');
set role authenticated;
do $$ declare e text; r jsonb; ok boolean; begin
  e := tp_fails(format('select fn_admin_upsert_product(%L)', jsonb_build_object('id', tp_id('coffee'), 'version', (select version from products where id = tp_id('coffee')),
         'category_id', tp_id('c1'), 'name', 'قهوة', 'price_halalas', 1)), 'FORBIDDEN: product_other_branch%');
  r := fn_admin_upsert_product(jsonb_build_object('category_id', tp_id('c2'), 'name', 'تمر المدير', 'price_halalas', 400));
  r := fn_admin_upsert_product(jsonb_build_object('id', r->>'id', 'version', r->'version', 'category_id', tp_id('c2'), 'name', 'تمر المدير', 'price_halalas', 450));
  perform tp_record('PD19 a manager does not change the price of a product another branch sells (the owner does); their own product they do',
    e = 'ok' and (select price_halalas from products where id = tp_id('coffee')) = 800 and (r->>'ok')::boolean, e);
exception when others then perform tp_record('PD19 a manager does not change the price of a product another branch sells (the owner does); their own product they do', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- PD14 an order left by the trial-data purge
-- the purge (0022) removes stays without knowing the orders (no reference of the database): such an order is not listed
insert into product_orders(organization_id, branch_id, reservation_id, number, source, created_at)
select organization_id, id, gen_random_uuid(), 'ORD-PURGED-1', 'staff', now() from branches where id = tp_id('b');
select tp_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
select tp_record('PD14 an order whose stay the trial-data purge removed is not listed, and reading it never breaks',
  not exists (select 1 from jsonb_array_elements(fn_staff_product_orders(tp_id('b'))) x where x->>'number' = 'ORD-PURGED-1')
  and not exists (select 1 from jsonb_array_elements(fn_staff_product_orders(tp_id('b'))) x where x = 'null'::jsonb));
reset role;
select tp_record('PD14b its own reading gives the order without a stay, not nothing',
  (select fn_product_order_json(id)->>'number' from product_orders where number = 'ORD-PURGED-1') = 'ORD-PURGED-1');

-- ---------------------------------------------------------------- results
select case when ok then 'PASS' else 'FAIL' end as result, name, coalesce(detail, '') as detail from test_results order by name;
do $$
declare n int; f int;
begin
  select count(*), count(*) filter (where not ok) into n, f from test_results;
  if f > 0 then raise exception 'PRODUCTS W1 TESTS FAILED: % of %', f, n; end if;
  if n < 30 then raise exception 'PRODUCTS W1 TESTS INCOMPLETE: % of 30 checks ran', n; end if;
end $$;
