-- =====================================================================
-- Guest journey, task W2 (VT*; migration 0069): the tax switches. The value-added tax is off by default; each of
-- rent, services and products has its own switch and its own rate in the branch's settings, the owner's alone;
-- each product and each service keeps its own «خاضع للضريبة» switch; a reservation keeps the policy it was made
-- under (three rates), so what was recorded before a change — and what is added later to a stay made before it —
-- stays as it was. Tried from outside the screens.
-- =====================================================================
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create temp table ids(k text primary key, v uuid);
grant all on ids to public;
create temp table notes(k text primary key, v text);
grant all on notes to public;
create or replace function tv_login(p_uid uuid, p_email text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email)::text, false);
end $$;
create or replace function tv_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;
create or replace function tv_id(p_k text) returns uuid language sql security definer as $$ select v from ids where k = p_k $$;
create or replace function tv_note(p_k text) returns text language sql security definer as $$ select v from notes where k = p_k $$;
create or replace function tv_fails(p_sql text, p_like text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'accepted';
exception when others then
  return case when sqlerrm like p_like then 'ok' else sqlerrm end;
end $$;
create or replace function tv_today(p uuid) returns date language sql security definer as $$ select fn_branch_today(p) $$;
create or replace function tv_fin(p uuid) returns jsonb language sql security definer as $$ select fn_reservation_finance_internal(p) $$;
create or replace function tv_res(p uuid) returns reservations language sql security definer as $$ select * from reservations where id = p $$;
create or replace function tv_branch(p uuid) returns branches language sql security definer as $$ select * from branches where id = p $$;
-- the switches of a branch, in one line: rent, services, products (on/off and rate), and the rent rate in force
create or replace function tv_switches(p uuid) returns text language sql security definer as $$
  select format('%s:%s %s:%s %s:%s in force %s', tax_rent_enabled, tax_rent_rate_bp, tax_services_enabled, tax_services_rate_bp, tax_products_enabled, tax_products_rate_bp, tax_rate_bp)
  from branches where id = p $$;
-- the policy a stay was made under, in one line: rent/services/products
create or replace function tv_policy(p uuid) returns text language sql security definer as $$
  select format('%s/%s/%s', tax_rate_bp, coalesce(tax_services_rate_bp::text, 'null'), coalesce(tax_products_rate_bp::text, 'null')) from reservations where id = p $$;
-- the tax lines of a stay: their sum, and the tax line of the newest line whose description starts with a text
create or replace function tv_tax(p uuid) returns bigint language sql security definer as $$
  select coalesce(sum(total_halalas), 0)::bigint from reservation_charges where reservation_id = p and kind = 'tax' $$;
create or replace function tv_tax_of(p uuid, p_like text) returns bigint language sql security definer as $$
  select coalesce((select sum(t.total_halalas) from reservation_charges t where t.base_charge_id = c.id and t.kind = 'tax'), 0)::bigint
  from reservation_charges c where c.reservation_id = p and c.kind <> 'tax' and c.description like p_like order by c.created_at desc, c.id desc limit 1 $$;
create or replace function tv_net_of(p uuid, p_like text) returns bigint language sql security definer as $$
  select c.total_halalas from reservation_charges c where c.reservation_id = p and c.kind <> 'tax' and c.description like p_like order by c.created_at desc, c.id desc limit 1 $$;
-- the rows of a stay as they stand now (to see later that they did not change), and the same for one invoice
create or replace function tv_rows(p uuid, p_before timestamptz) returns text language sql security definer as $$
  select md5(coalesce(string_agg(to_jsonb(c)::text, '|' order by c.id), '')) from reservation_charges c where c.reservation_id = p and c.created_at <= p_before $$;
create or replace function tv_invoice(p uuid) returns text language sql security definer as $$ select md5(to_jsonb(i)::text) from invoices i where i.id = p $$;
create or replace function tv_check_in(p_res uuid, p_room uuid) returns void language sql security definer as $$
  update reservations set status = 'checked_in', room_id = p_room, actual_check_in = now() where id = p_res $$;
create or replace function tv_token(p uuid) returns text language sql security definer as $$ insert into registration_sessions(reservation_id) values (p) returning token $$;
create or replace function tv_guest_products(p_token text) returns jsonb language sql security definer as $$ select fn_guest_products(p_token) $$;
create or replace function tv_items(variadic p text[]) returns jsonb language sql immutable as $$
  select jsonb_agg(jsonb_build_object('product_id', p[i], 'quantity', p[i + 1]::int) order by i) from generate_series(1, array_length(p, 1), 2) i $$;
create or replace function tv_bal(p_branch uuid, p_key text) returns bigint language sql security definer as $$
  select coalesce(sum(l.credit_halalas - l.debit_halalas), 0)::bigint from journal_lines l join journal_entries e on e.id = l.entry_id join gl_accounts g on g.id = l.account_id
  where e.branch_id = p_branch and g.system_key = p_key $$;
-- (as the owner) a stay of two nights from today in the switches' branch, its rent paid, and — with a room — checked in
create or replace function tv_stay(p_key text, p_phone text, p_room text default null, p_from int default 0) returns uuid language plpgsql as $$
declare r jsonb; b uuid := tv_id('b'); res uuid;
begin
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b, 'category_id', tv_id('cat'), 'check_in', (tv_today(b) + p_from)::text, 'check_out', (tv_today(b) + p_from + 2)::text,
         'guest_phone', p_phone, 'guest_name', 'نزيل الضريبة', 'source_id', '00000000-0000-0000-0000-000000000021'));
  res := (r->>'id')::uuid;
  insert into ids values (p_key, res);
  perform fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind', 'receipt', 'amount_halalas', (tv_fin(res)->>'total')::bigint, 'method', 'cash', 'idempotency_key', 'vt-rent-' || p_key));
  if p_room is not null then perform tv_check_in(res, tv_id(p_room)); end if;
  return res;
end $$;
-- (as the owner) the branch's switches changed through the settings function, with the version on file
create or replace function tv_set(p_branch uuid, p jsonb) returns jsonb language plpgsql as $$
begin
  return fn_admin_upsert_branch(jsonb_build_object('id', p_branch, 'name_ar', (tv_branch(p_branch)).name_ar, 'version', (tv_branch(p_branch)).version) || p);
end $$;
-- (as the owner) an order for a stay, paid in cash; returns the order as the payment returns it
create or replace function tv_order_paid(p_res uuid, p_items jsonb, p_key text) returns jsonb language plpgsql as $$
declare o jsonb; r jsonb;
begin
  o := fn_staff_create_product_order(p_res, p_items);
  r := fn_staff_pay_product_order(jsonb_build_object('order_id', o->>'id', 'method', 'cash', 'idempotency_key', p_key, 'expected_version', (o->>'version')::int));
  return (r->'order') || jsonb_build_object('shown_total', o->'total_halalas', 'shown_tax', o->'tax_halalas');
end $$;

-- ---------------------------------------------------------------- the branch, its rooms, a service, the products, two stays made before any switch
select tv_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; b uuid; cat uuid; c uuid; i int; inv jsonb; begin
  r := fn_admin_upsert_branch('{"name_ar":"فرع مفاتيح الضريبة","name_en":"Tax switches branch"}'); b := (r->>'id')::uuid;
  insert into ids values ('b', b);
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', b, 'name_ar', 'غرفة المفاتيح', 'base_price_halalas', 10000)); cat := (r->>'id')::uuid;
  insert into ids values ('cat', cat);
  for i in 1..8 loop
    r := fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', (840 + i)::text)); insert into ids values ('room' || i, (r->>'id')::uuid);
  end loop;
  r := fn_admin_upsert_service(jsonb_build_object('branch_id', b, 'name_ar', 'غسيل ملابس', 'billing_unit', 'once', 'price_halalas', 5000)); insert into ids values ('svc', (r->>'id')::uuid);
  r := fn_admin_upsert_service(jsonb_build_object('branch_id', b, 'name_ar', 'توصيل بلا ضريبة', 'billing_unit', 'once', 'price_halalas', 2000, 'taxable', false)); insert into ids values ('svc0', (r->>'id')::uuid);
  r := fn_admin_upsert_product_category('{"name":"منتجات المفاتيح"}'); c := (r->>'id')::uuid;
  r := fn_admin_upsert_product(jsonb_build_object('category_id', c, 'name', 'ماء المفاتيح', 'price_halalas', 200)); insert into ids values ('water', (r->>'id')::uuid);
  r := fn_admin_upsert_product(jsonb_build_object('category_id', c, 'name', 'فرشاة المفاتيح', 'price_halalas', 500, 'taxable', false)); insert into ids values ('brush', (r->>'id')::uuid);
  perform fn_admin_set_product_branch(tv_id('water'), b, true);
  perform fn_admin_set_product_branch(tv_id('brush'), b, true);
  -- two stays made while every switch is off: one in its room, one still to arrive
  perform tv_stay('resA', '0552000001', 'room1');
  perform tv_stay('resX', '0552000002', null, 10);
  -- an invoice of the first night of the first stay, issued before any switch is turned
  inv := fn_staff_issue_invoice(jsonb_build_object('reservation_id', tv_id('resA'), 'from', tv_today(b)::text, 'to', (tv_today(b) + 1)::text));
  insert into ids values ('invA', (inv->>'id')::uuid);
exception when others then perform tv_record('VT00 the branch, its rooms, its service, its products and two stays are set up', false, sqlerrm);
end $$;
reset role;
insert into notes values ('t0', clock_timestamp()::text), ('rowsA', tv_rows(tv_id('resA'), clock_timestamp())), ('invA', tv_invoice(tv_id('invA'))), ('rowsX', tv_rows(tv_id('resX'), clock_timestamp()));

-- ---------------------------------------------------------------- VT01 off by default
select tv_record('VT01 the tax is off by default: a new branch has its three switches off, each with a rate ready (15%), no rent rate in force, and a stay made in it carries no tax policy',
  tv_switches(tv_id('b')) = 'f:1500 f:1500 f:1500 in force 0' and tv_policy(tv_id('resA')) = '0/0/0'
  and (tv_fin(tv_id('resA'))->>'tax')::bigint = 0 and (tv_fin(tv_id('resA'))->>'total')::bigint = 20000,
  tv_switches(tv_id('b')) || ' / ' || tv_policy(tv_id('resA')) || ' / ' || tv_fin(tv_id('resA'))::text);

-- ---------------------------------------------------------------- VT02 one switch: products
select tv_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare o jsonb; b uuid := tv_id('b'); resB uuid; begin
  perform tv_set(b, '{"tax_products_enabled":true}');
  resB := tv_stay('resB', '0552000003', 'room2');
  perform fn_staff_add_service(resB, tv_id('svc'), 1, null);
  o := fn_staff_create_product_order(resB, tv_items(tv_id('water')::text, '2', tv_id('brush')::text, '1'));
  insert into ids values ('oB', (o->>'id')::uuid);
  perform tv_record('VT02 the owner turns on the products'' switch alone: a stay made after it is taxed on its taxable products only — not on its rent, not on its services — and the order says how much of its total is tax',
    tv_switches(b) = 'f:1500 f:1500 t:1500 in force 0' and tv_policy(resB) = '0/0/1500'
    and (o->>'total_halalas')::bigint = 960 and (o->>'tax_halalas')::bigint = 60 and not (o->>'tax_included')::boolean
    and tv_tax(resB) = 0 and (tv_fin(resB)->>'total')::bigint = 25000,
    tv_switches(b) || ' / ' || tv_policy(resB) || ' / ' || o::text || ' / ' || tv_fin(resB)::text);
exception when others then perform tv_record('VT02 the owner turns on the products'' switch alone: a stay made after it is taxed on its taxable products only — not on its rent, not on its services — and the order says how much of its total is tax', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- VT03 paid as shown
select tv_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare o jsonb; r jsonb; resB uuid := tv_id('resB'); due0 bigint; rev0 bigint; begin
  due0 := (tv_fin(resB)->>'balance_due')::bigint; rev0 := tv_bal(tv_id('b'), 'product_revenue');
  select x into o from jsonb_array_elements(fn_staff_product_orders(tv_id('b'))) x where x->>'id' = tv_id('oB')::text;
  r := fn_staff_pay_product_order(jsonb_build_object('order_id', o->>'id', 'method', 'cash', 'idempotency_key', 'vt-pay-b', 'expected_version', (o->>'version')::int));
  perform tv_record('VT03 the payment charges exactly what the order showed: the lines join the stay with their tax line, the receipt is for the order''s total, the stay''s balance does not move, and the whole goes to product revenue',
    (r->'order'->>'total_halalas')::bigint = 960 and (r->'order'->>'tax_halalas')::bigint = 60
    and (select coalesce(sum(total_halalas), 0) from reservation_charges where product_order_id = (o->>'id')::uuid) = 960
    and (select coalesce(sum(total_halalas), 0) from reservation_charges where product_order_id = (o->>'id')::uuid and kind = 'tax') = 60
    and (select amount_halalas from financial_vouchers where number = r->>'voucher_number') = 960
    and (tv_fin(resB)->>'balance_due')::bigint = due0 and tv_tax(resB) = 60
    and tv_bal(tv_id('b'), 'product_revenue') - rev0 = 960,
    r::text || ' / ' || tv_fin(resB)::text);
exception when others then perform tv_record('VT03 the payment charges exactly what the order showed: the lines join the stay with their tax line, the receipt is for the order''s total, the stay''s balance does not move, and the whole goes to product revenue', false, sqlerrm);
end $$;
reset role;
insert into notes values ('tB', clock_timestamp()::text), ('rowsB', tv_rows(tv_id('resB'), clock_timestamp()));

-- ---------------------------------------------------------------- VT04 three switches, three rates
select tv_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare o jsonb; q jsonb; b uuid := tv_id('b'); resC uuid; begin
  perform tv_set(b, '{"tax_rent_enabled":true,"tax_rent_rate_bp":1500,"tax_services_enabled":true,"tax_services_rate_bp":500,"tax_products_enabled":true,"tax_products_rate_bp":1000}');
  q := fn_quote_stay(jsonb_build_object('branch_id', b, 'category_id', tv_id('cat'), 'check_in', (tv_today(b) + 20)::text, 'check_out', (tv_today(b) + 22)::text));
  resC := tv_stay('resC', '0552000004', 'room3');
  perform fn_staff_add_service(resC, tv_id('svc'), 1, null);
  o := tv_order_paid(resC, tv_items(tv_id('water')::text, '1'), 'vt-pay-c');
  perform tv_record('VT04 each of rent, services and products has its own switch and its own rate: with 15%, 5% and 10% a new stay''s rent, its service and its product order each carry their own tax; the quote shows the rent''s',
    tv_switches(b) = 't:1500 t:500 t:1000 in force 1500' and tv_policy(resC) = '1500/500/1000'
    and (q->>'tax')::bigint = 3000 and (q->>'total')::bigint = 23000 and (q->>'tax_rate_bp')::int = 1500
    and tv_tax_of(resC, 'غسيل ملابس%') = 250 and (o->>'total_halalas')::bigint = 220 and (o->>'tax_halalas')::bigint = 20
    and tv_tax(resC) = 3000 + 250 + 20 and (tv_fin(resC)->>'total')::bigint = 23000 + 5250 + 220,
    tv_switches(b) || ' / ' || tv_policy(resC) || ' / ' || q::text || ' / ' || o::text || ' / ' || tv_fin(resC)::text);
exception when others then perform tv_record('VT04 each of rent, services and products has its own switch and its own rate: with 15%, 5% and 10% a new stay''s rent, its service and its product order each carry their own tax; the quote shows the rent''s', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- VT05 what was before does not change
select tv_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare oa jsonb; ob jsonb; resA uuid := tv_id('resA'); resB uuid := tv_id('resB'); resX uuid := tv_id('resX'); b uuid := tv_id('b'); begin
  -- the stay made before any switch: a service, a product order, and (for the one still to arrive) a night more
  perform fn_staff_add_service(resA, tv_id('svc'), 1, null);
  oa := tv_order_paid(resA, tv_items(tv_id('water')::text, '2', tv_id('brush')::text, '1'), 'vt-pay-a');
  perform fn_staff_amend_stay(resX, (tv_res(resX)).check_out + 1, 'keep_rate', 'ليلة إضافية', (tv_res(resX)).version);
  -- the stay made while only products were taxed (at 15%): a second service, a second order
  perform fn_staff_add_service(resB, tv_id('svc'), 1, 'مرة ثانية');
  ob := tv_order_paid(resB, tv_items(tv_id('water')::text, '1'), 'vt-pay-b2');
  perform tv_record('VT05 a stay keeps the policy it was made under: after the switches are turned, what is added to a stay made before them — a service, a product order, a night more — carries the tax of its own policy, and its earlier lines and its issued invoice are as they were',
    tv_policy(resA) = '0/0/0' and tv_tax(resA) = 0 and (oa->>'total_halalas')::bigint = 900 and (oa->>'tax_halalas')::bigint = 0
    and tv_tax(resX) = 0 and (tv_fin(resX)->>'total')::bigint = 30000
    and tv_policy(resB) = '0/0/1500' and tv_tax_of(resB, 'غسيل ملابس — مرة ثانية') = 0 and (ob->>'total_halalas')::bigint = 230 and (ob->>'tax_halalas')::bigint = 30
    and tv_rows(resA, tv_note('t0')::timestamptz) = tv_note('rowsA') and tv_invoice(tv_id('invA')) = tv_note('invA')
    and tv_rows(resB, tv_note('tB')::timestamptz) = tv_note('rowsB'),
    tv_policy(resA) || ' ' || tv_tax(resA) || ' / ' || oa::text || ' / ' || tv_fin(resX)::text || ' / ' || ob::text);
exception when others then perform tv_record('VT05 a stay keeps the policy it was made under: after the switches are turned, what is added to a stay made before them — a service, a product order, a night more — carries the tax of its own policy, and its earlier lines and its issued invoice are as they were', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- VT06 switched off again
select tv_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare o jsonb; b uuid := tv_id('b'); resC uuid := tv_id('resC'); resD uuid; begin
  perform tv_set(b, '{"tax_rent_enabled":false,"tax_services_enabled":false,"tax_products_enabled":false}');
  resD := tv_stay('resD', '0552000005', 'room4');
  perform fn_staff_add_service(resD, tv_id('svc'), 1, null);
  o := tv_order_paid(resD, tv_items(tv_id('water')::text, '3'), 'vt-pay-d');
  -- the stay made under 15/5/10 keeps them
  perform fn_staff_add_service(resC, tv_id('svc'), 1, 'مرة ثانية');
  perform tv_record('VT06 the switches are turned off: the rates stay on file for the next time, a new stay carries no tax at all, and the stay made while they were on keeps its tax on what is added to it',
    tv_switches(b) = 'f:1500 f:500 f:1000 in force 0' and tv_policy(resD) = '0/0/0' and tv_tax(resD) = 0
    and (o->>'total_halalas')::bigint = 600 and (o->>'tax_halalas')::bigint = 0 and (tv_fin(resD)->>'total')::bigint = 20000 + 5000 + 600
    and tv_tax_of(resC, 'غسيل ملابس — مرة ثانية') = 250,
    tv_switches(b) || ' / ' || tv_policy(resD) || ' / ' || o::text || ' / ' || tv_fin(resD)::text);
exception when others then perform tv_record('VT06 the switches are turned off: the rates stay on file for the next time, a new stay carries no tax at all, and the stay made while they were on keeps its tax on what is added to it', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- VT07 the product's and the service's own switch
select tv_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare o jsonb; resC uuid := tv_id('resC'); t0 bigint; begin
  t0 := tv_tax(resC);
  perform fn_staff_add_service(resC, tv_id('svc0'), 1, null);
  o := tv_order_paid(resC, tv_items(tv_id('brush')::text, '2'), 'vt-pay-c2');
  perform tv_record('VT07 each product and each service has its own «خاضع للضريبة» switch: a product and a service that are not taxable carry no tax even in a stay whose policy taxes products and services',
    tv_tax(resC) = t0 and tv_net_of(resC, 'توصيل بلا ضريبة%') = 2000 and tv_tax_of(resC, 'توصيل بلا ضريبة%') = 0
    and (o->>'total_halalas')::bigint = 1000 and (o->>'tax_halalas')::bigint = 0,
    tv_tax(resC)::text || ' / ' || o::text);
exception when others then perform tv_record('VT07 each product and each service has its own «خاضع للضريبة» switch: a product and a service that are not taxable carry no tax even in a stay whose policy taxes products and services', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- VT08 the owner's alone
insert into branch_memberships(staff_id, branch_id) select '10000000-0000-0000-0000-000000000008', tv_id('b')
  where not exists (select 1 from branch_memberships where staff_id = '10000000-0000-0000-0000-000000000008' and branch_id = tv_id('b'));
select tv_login('a0000000-0000-0000-0000-000000000008', 'manager@test.local');
set role authenticated;
do $$ declare b uuid := tv_id('b'); e_on text; e_rate text; e_incl text; ok jsonb; before text; begin
  before := tv_switches(b);
  e_on := tv_fails(format('select tv_set(%L, %L)', b, '{"tax_products_enabled":true}'), 'FORBIDDEN%');
  e_rate := tv_fails(format('select tv_set(%L, %L)', b, '{"tax_rent_rate_bp":1400}'), 'FORBIDDEN%');
  e_incl := tv_fails(format('select tv_set(%L, %L)', b, '{"prices_include_tax":true}'), 'FORBIDDEN%');
  -- the same switches sent back with another field (the screen sends them all): saved
  ok := tv_set(b, '{"city":"بريدة","tax_rent_enabled":false,"tax_rent_rate_bp":1500,"tax_services_enabled":false,"tax_services_rate_bp":500,"tax_products_enabled":false,"tax_products_rate_bp":1000}');
  perform tv_record('VT08 the switches are the owner''s alone: a manager cannot turn one on, change a rate or the «شاملة» choice — the server refuses — yet saves the branch''s other fields with the switches as they are',
    e_on = 'ok' and e_rate = 'ok' and e_incl = 'ok' and (ok->>'ok')::boolean and tv_switches(b) = before and (tv_branch(b)).city = 'بريدة',
    e_on || ' / ' || e_rate || ' / ' || e_incl || ' / ' || tv_switches(b));
exception when others then perform tv_record('VT08 the switches are the owner''s alone: a manager cannot turn one on, change a rate or the «شاملة» choice — the server refuses — yet saves the branch''s other fields with the switches as they are', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- VT09 a switch is on or off, a rate is a rate
select tv_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare b uuid := tv_id('b'); e text[]; before text; begin
  before := tv_switches(b);
  e := array[
    tv_fails(format('select tv_set(%L, %L)', b, '{"tax_rent_rate_bp":0}'), 'VALIDATION: tax_rate%'),
    tv_fails(format('select tv_set(%L, %L)', b, '{"tax_services_rate_bp":10001}'), 'VALIDATION: tax_rate%'),
    tv_fails(format('select tv_set(%L, %L)', b, '{"tax_products_rate_bp":"15.5"}'), 'VALIDATION: tax_rate%'),
    tv_fails(format('select tv_set(%L, %L)', b, '{"tax_products_rate_bp":null}'), 'VALIDATION: tax_rate%'),
    tv_fails(format('select tv_set(%L, %L)', b, '{"tax_products_rate_bp":-5}'), 'VALIDATION: tax_rate%'),
    tv_fails(format('select tv_set(%L, %L)', b, '{"tax_services_enabled":"yes"}'), 'VALIDATION: tax_switch%'),
    tv_fails(format('select tv_set(%L, %L)', b, '{"tax_products_enabled":null}'), 'VALIDATION: tax_switch%'),
    tv_fails(format('select tv_set(%L, %L)', b, '{"tax_rent_enabled":1}'), 'VALIDATION: tax_switch%'),
    tv_fails(format('select tv_set(%L, %L)', b, '{"prices_include_tax":"yes"}'), 'VALIDATION: tax_switch%')];
  perform tv_record('VT09 a switch is true or false and a rate is from 0.01% to 100%: zero, more than 100%, a fraction of a point, nothing, a negative rate, and a switch or the «شاملة» choice that is not true or false are refused, and nothing changes',
    e = array_fill('ok'::text, array[9]) and tv_switches(b) = before, array_to_string(e, ' / '));
exception when others then perform tv_record('VT09 a switch is true or false and a rate is from 0.01% to 100%: zero, more than 100%, a fraction of a point, nothing, a negative rate, and a switch or the «شاملة» choice that is not true or false are refused, and nothing changes', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- VT10 the one rate of the screen before the switches
select tv_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare b uuid := tv_id('b'); s1 text; s2 text; s3 text; begin
  perform tv_set(b, '{"tax_products_enabled":true}');
  -- the earlier screen sends the rent rate in force back with every save: the switches stay
  perform tv_set(b, '{"tax_rate_bp":0,"city":"عنيزة"}'); s1 := tv_switches(b);
  -- a rate typed there is, as it was then, one rate on everything taxable; zero turns everything off
  perform tv_set(b, '{"tax_rate_bp":1200}'); s2 := tv_switches(b);
  perform tv_set(b, '{"tax_rate_bp":0}'); s3 := tv_switches(b);
  perform tv_record('VT10 the screen before the switches still saves: the rate in force sent back changes nothing, a rate typed there is one rate on everything taxable as it was then, and zero turns the three off',
    s1 = 'f:1500 f:500 t:1000 in force 0' and (tv_branch(b)).city = 'عنيزة' and s2 = 't:1200 t:1200 t:1200 in force 1200' and s3 = 'f:1200 f:1200 f:1200 in force 0',
    s1 || ' / ' || s2 || ' / ' || s3);
exception when others then perform tv_record('VT10 the screen before the switches still saves: the rate in force sent back changes nothing, a rate typed there is one rate on everything taxable as it was then, and zero turns the three off', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- VT11 nothing written past the settings function
select tv_record('VT11a the rent rate in force is held to the rent switch by the table itself, and a rate of zero is not kept: a write that breaks either is refused even with every right',
  tv_fails(format('update branches set tax_rate_bp = 700 where id = %L', tv_id('b')), '%branches_tax_rent_in_force%') = 'ok'
  and tv_fails(format('update branches set tax_rent_enabled = true where id = %L', tv_id('b')), '%branches_tax_rent_in_force%') = 'ok'
  and tv_fails(format('update branches set tax_products_rate_bp = 0 where id = %L', tv_id('b')), '%branches_tax_rates_valid%') = 'ok'
  and tv_fails(format('update reservations set tax_products_rate_bp = 10001 where id = %L', tv_id('resD')), '%reservations_tax_rates_valid%') = 'ok');
select tv_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare b uuid := tv_id('b'); before text; pol text; e1 text; e2 text; e3 text; begin
  before := tv_switches(b); pol := tv_policy(tv_id('resC'));
  e1 := tv_fails(format('update branches set tax_products_enabled = true where id = %L', b), '%');
  e2 := tv_fails(format('update reservations set tax_products_rate_bp = 0, tax_services_rate_bp = 0 where id = %L', tv_id('resC')), '%');
  e3 := tv_fails(format('select fn_charge_tax(%L, %L, 1000, true)', tv_id('resC'), 'products'), '%permission denied%');
  perform tv_record('VT11b from the screens'' side nothing is written past the settings function: a switch is not turned in the table, a stay''s policy is not rewritten, the stay''s policy columns are not read, and the tax function is not called',
    tv_switches(b) = before and tv_policy(tv_id('resC')) = pol and e3 = 'ok'
    and not has_column_privilege('authenticated', 'public.reservations', 'tax_products_rate_bp', 'SELECT')
    and not has_column_privilege('authenticated', 'public.reservations', 'tax_services_rate_bp', 'SELECT')
    and not has_function_privilege('authenticated', 'fn_add_charge_in(text, uuid, text, text, numeric, bigint, boolean, text, uuid, date, date)', 'execute')
    and not has_function_privilege('anon', 'fn_charge_tax(uuid, text, bigint, boolean)', 'execute'),
    e1 || ' / ' || e2 || ' / ' || e3 || ' / ' || tv_switches(b));
exception when others then perform tv_record('VT11b from the screens'' side nothing is written past the settings function: a switch is not turned in the table, a stay''s policy is not rewritten, the stay''s policy columns are not read, and the tax function is not called', false, sqlerrm);
end $$;
reset role;
select tv_record('VT11c the tax of an amount is for rent, a service or a product: another word is refused',
  tv_fails(format('select * from fn_charge_tax(%L, %L, 1000, true)', tv_id('resC'), 'other'), 'VALIDATION: tax_category%') = 'ok'
  and (select tax_halalas from fn_charge_tax(tv_id('resC'), 'services', 1000, true)) = 50
  and (select tax_halalas from fn_charge_tax(tv_id('resC'), 'products', 1000, true)) = 100
  and (select tax_halalas from fn_charge_tax(tv_id('resC'), 'rent', 1000, true)) = 150
  and (select tax_halalas from fn_reservation_tax(tv_id('resC'), 1000, true)) = 150
  and (select tax_halalas from fn_charge_tax(tv_id('resC'), 'products', 1000, false)) = 0);

-- ---------------------------------------------------------------- VT12 prices that carry the tax; a branch made with its switches
select tv_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; o jsonb; bi uuid; cat uuid; room uuid; resE uuid; begin
  r := fn_admin_upsert_branch('{"name_ar":"فرع الضريبة الشاملة","name_en":"Inclusive tax branch","tax_services_enabled":true,"tax_products_enabled":true,"tax_products_rate_bp":1500,"prices_include_tax":true}');
  bi := (r->>'id')::uuid; insert into ids values ('bi', bi);
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', bi, 'name_ar', 'غرفة الشاملة', 'base_price_halalas', 10000)); cat := (r->>'id')::uuid;
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', bi, 'category_id', cat, 'room_number', '861')); room := (r->>'id')::uuid;
  r := fn_admin_upsert_service(jsonb_build_object('branch_id', bi, 'name_ar', 'غسيل الشاملة', 'billing_unit', 'once', 'price_halalas', 5000)); insert into ids values ('svci', (r->>'id')::uuid);
  perform fn_admin_set_product_branch(tv_id('water'), bi, true);
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', bi, 'category_id', cat, 'check_in', tv_today(bi)::text, 'check_out', (tv_today(bi) + 2)::text,
         'guest_phone', '0552000006', 'guest_name', 'نزيل الشاملة', 'source_id', '00000000-0000-0000-0000-000000000021'));
  resE := (r->>'id')::uuid; insert into ids values ('resE', resE);
  perform fn_create_voucher(jsonb_build_object('reservation_id', resE, 'kind', 'receipt', 'amount_halalas', (tv_fin(resE)->>'total')::bigint, 'method', 'cash', 'idempotency_key', 'vt-rent-e'));
  perform tv_check_in(resE, room);
  perform fn_staff_add_service(resE, tv_id('svci'), 1, null);
  o := tv_order_paid(resE, tv_items(tv_id('water')::text, '2'), 'vt-pay-e');
  perform tv_record('VT12 a branch made with its switches (services at the ready 15%, products at 15%, rent off) whose prices carry the tax: the guest pays the price shown, and the tax is taken out of it — on the service and on the order, not on the rent',
    tv_switches(bi) = 'f:1500 t:1500 t:1500 in force 0' and (tv_branch(bi)).prices_include_tax and tv_policy(resE) = '0/1500/1500'
    and (o->>'total_halalas')::bigint = 400 and (o->>'tax_halalas')::bigint = 52 and (o->>'tax_included')::boolean
    and tv_net_of(resE, 'ماء المفاتيح%') = 348 and tv_tax_of(resE, 'ماء المفاتيح%') = 52
    and tv_net_of(resE, 'غسيل الشاملة%') = 4348 and tv_tax_of(resE, 'غسيل الشاملة%') = 652
    and (tv_fin(resE)->>'total')::bigint = 20000 + 5000 + 400 and tv_tax(resE) = 52 + 652,
    tv_switches(bi) || ' / ' || tv_policy(resE) || ' / ' || o::text || ' / ' || tv_fin(resE)::text);
exception when others then perform tv_record('VT12 a branch made with its switches (services at the ready 15%, products at 15%, rent off) whose prices carry the tax: the guest pays the price shown, and the tax is taken out of it — on the service and on the order, not on the rent', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- VT13 a paid order with tax is undone to nothing
select tv_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare o jsonb; c jsonb; resC uuid := tv_id('resC'); t0 bigint; tot0 bigint; rev0 bigint; begin
  t0 := tv_tax(resC); tot0 := (tv_fin(resC)->>'total')::bigint; rev0 := tv_bal(tv_id('b'), 'product_revenue');
  o := tv_order_paid(resC, tv_items(tv_id('water')::text, '5'), 'vt-pay-c3');
  c := fn_staff_cancel_product_order((o->>'id')::uuid, 'طلب بالخطأ');
  perform tv_record('VT13 a paid order that carries tax is cancelled to nothing: its line and its tax line each get their exact opposite, the stay''s total and tax are as before it, and product revenue is back where it was',
    (o->>'total_halalas')::bigint = 1100 and (o->>'tax_halalas')::bigint = 100 and c->>'status' = 'cancelled'
    and (select coalesce(sum(total_halalas), 0) from reservation_charges where product_order_id = (o->>'id')::uuid) = 0
    and (select coalesce(sum(total_halalas), 0) from reservation_charges where product_order_id = (o->>'id')::uuid and kind = 'tax') = 0
    and tv_tax(resC) = t0 and (tv_fin(resC)->>'total')::bigint = tot0 and tv_bal(tv_id('b'), 'product_revenue') = rev0,
    o::text || ' / ' || tv_fin(resC)::text);
exception when others then perform tv_record('VT13 a paid order that carries tax is cancelled to nothing: its line and its tax line each get their exact opposite, the stay''s total and tax are as before it, and product revenue is back where it was', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- VT15 every change is on the record
select tv_record('VT15 every change of a switch or a rate is on the record with what it was and what it became, and says that it reaches new reservations only; a refused change leaves no line',
  (select count(*) from audit_events where action = 'branch.tax_changed' and entity_id = tv_id('b')) = 6
  and (select details->'before'->>'tax_products_enabled' || '>' || (details->'after'->>'tax_products_enabled') || ' ' || (details->>'reason')
         from audit_events where action = 'branch.tax_changed' and entity_id = tv_id('b') order by created_at, id limit 1) = 'false>true يسري على الحجوزات الجديدة فقط'
  and (select details->'after'->>'tax_services_rate_bp' || ' ' || (details->'after'->>'tax_rate_bp') from audit_events
        where action = 'branch.tax_changed' and entity_id = tv_id('b') order by created_at, id offset 1 limit 1) = '500 1500',
  (select string_agg((details->'after')::text, ' | ' order by created_at, id) from audit_events where action = 'branch.tax_changed' and entity_id = tv_id('b')));

-- ---------------------------------------------------------------- VT14 a stay made before the switches existed
-- a stay made under one rate of 15% on everything (as before 0069) …
select tv_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ begin
  perform tv_set(tv_id('b'), '{"tax_rent_enabled":true,"tax_rent_rate_bp":1500,"tax_services_enabled":true,"tax_services_rate_bp":1500,"tax_products_enabled":true,"tax_products_rate_bp":1500}');
  perform tv_stay('resO', '0552000007', 'room5');
  perform tv_set(tv_id('b'), '{"tax_rent_enabled":false,"tax_services_enabled":false,"tax_products_enabled":false}');
exception when others then perform tv_record('VT14 a stay made before the switches existed keeps its one rate for all three: a service and a product order added to it now are taxed at that rate, whatever the branch''s switches say', false, sqlerrm);
end $$;
reset role;
-- … as 0069 finds it: the two new rates empty, its one rate standing for all three
update reservations set tax_services_rate_bp = null, tax_products_rate_bp = null where id = tv_id('resO');
select tv_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare o jsonb; resO uuid := tv_id('resO'); begin
  perform fn_staff_add_service(resO, tv_id('svc'), 1, null);
  o := tv_order_paid(resO, tv_items(tv_id('water')::text, '1'), 'vt-pay-o');
  perform tv_record('VT14 a stay made before the switches existed keeps its one rate for all three: a service and a product order added to it now are taxed at that rate, whatever the branch''s switches say',
    tv_policy(resO) = '1500/null/null' and tv_tax_of(resO, 'غسيل ملابس%') = 750 and (o->>'total_halalas')::bigint = 230 and (o->>'tax_halalas')::bigint = 30
    and tv_tax(resO) = 3000 + 750 + 30 and tv_switches(tv_id('b')) = 'f:1500 f:1500 f:1500 in force 0',
    tv_policy(resO) || ' / ' || o::text || ' / ' || tv_switches(tv_id('b')) || ' / ' || tv_fin(resO)::text);
exception when others then perform tv_record('VT14 a stay made before the switches existed keeps its one rate for all three: a service and a product order added to it now are taxed at that rate, whatever the branch''s switches say', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- VT18 an order that no longer adds up is not paid
select tv_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare o jsonb; begin
  o := fn_staff_create_product_order(tv_id('resC'), tv_items(tv_id('water')::text, '4'));   -- 8.00 and the stay's 10%
  insert into ids values ('oMis', (o->>'id')::uuid);
  insert into notes values ('oMisVer', o->>'version'), ('oMisTotal', o->>'total_halalas');
exception when others then perform tv_record('VT18 what is paid is what the order showed: an order whose lines would now be charged another amount is refused whole — no line, no receipt, no task — and is paid once it adds up again', false, sqlerrm);
end $$;
reset role;
-- (the stay's policy rewritten under the order, as no screen can do)
update reservations set tax_products_rate_bp = 0 where id = tv_id('resC');
select tv_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare e text; n int; st text; v int; begin
  e := tv_fails(format('select fn_staff_pay_product_order(%L::jsonb)', jsonb_build_object('order_id', tv_id('oMis'), 'method', 'cash', 'idempotency_key', 'vt-pay-mis', 'expected_version', tv_note('oMisVer')::int)),
                'VALIDATION: order_total%');
  select count(*) into n from reservation_charges where product_order_id = tv_id('oMis');
  select status, (select count(*) from financial_vouchers where idempotency_key = 'vt-pay-mis') into st, v from product_orders where id = tv_id('oMis');
  insert into notes values ('misRefused', e || ' ' || n || ' ' || st || ' ' || v);
end $$;
reset role;
update reservations set tax_products_rate_bp = 1000 where id = tv_id('resC');
select tv_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; begin
  r := fn_staff_pay_product_order(jsonb_build_object('order_id', tv_id('oMis'), 'method', 'cash', 'idempotency_key', 'vt-pay-mis', 'expected_version', tv_note('oMisVer')::int));
  perform tv_record('VT18 what is paid is what the order showed: an order whose lines would now be charged another amount is refused whole — no line, no receipt, no task — and is paid once it adds up again',
    tv_note('oMisTotal') = '880' and tv_note('misRefused') = 'ok 0 pending_payment 0' and (r->'order'->>'status') = 'paid' and (r->'order'->>'total_halalas')::bigint = 880
    and (select amount_halalas from financial_vouchers where number = r->>'voucher_number') = 880,
    tv_note('oMisTotal') || ' / ' || tv_note('misRefused') || ' / ' || r::text);
exception when others then perform tv_record('VT18 what is paid is what the order showed: an order whose lines would now be charged another amount is refused whole — no line, no receipt, no task — and is paid once it adds up again', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- VT16 what the guest and the reception are told
insert into notes values ('tokC', tv_token(tv_id('resC'))), ('tokA', tv_token(tv_id('resA'))), ('tokE', tv_token(tv_id('resE')));
select tv_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
select tv_record('VT16 the guest''s list and the reception''s say how the prices are read for each stay: the products'' rate of the stay''s own policy, and whether the prices carry it',
  tv_guest_products(tv_note('tokC'))->'tax' = '{"rate_bp": 1000, "included": false}'::jsonb
  and tv_guest_products(tv_note('tokA'))->'tax' = '{"rate_bp": 0, "included": false}'::jsonb
  and tv_guest_products(tv_note('tokE'))->'tax' = '{"rate_bp": 1500, "included": true}'::jsonb
  and (select (x->>'tax_rate_bp')::int from jsonb_array_elements(fn_staff_product_menu(tv_id('b'))->'stays') x where x->>'id' = tv_id('resC')::text) = 1000
  and (select (x->>'tax_rate_bp')::int from jsonb_array_elements(fn_staff_product_menu(tv_id('b'))->'stays') x where x->>'id' = tv_id('resA')::text) = 0
  and (select (x->>'tax_included')::boolean from jsonb_array_elements(fn_staff_product_menu(tv_id('bi'))->'stays') x where x->>'id' = tv_id('resE')::text),
  (tv_guest_products(tv_note('tokC'))->'tax')::text || ' / ' || (fn_staff_product_menu(tv_id('b'))->'stays')::text);
reset role;

-- ---------------------------------------------------------------- VT17 the books stay balanced
select tv_record('VT17 with tax on the lines, every entry of the two branches is still balanced, and each order''s receipt is for exactly what its lines put in the stay''s account',
  not exists (select 1 from journal_entries e where e.branch_id in (tv_id('b'), tv_id('bi'))
               and (select coalesce(sum(debit_halalas), 0) - coalesce(sum(credit_halalas), 0) from journal_lines l where l.entry_id = e.id) <> 0)
  and not exists (select 1 from product_orders o where o.branch_id in (tv_id('b'), tv_id('bi')) and o.status in ('paid', 'delivered')
                   and (select amount_halalas from financial_vouchers v where v.id = o.voucher_id)
                       is distinct from (select coalesce(sum(total_halalas), 0) from reservation_charges c where c.product_order_id = o.id)));

-- ---------------------------------------------------------------- results
\set ON_ERROR_STOP on
select case when ok then 'PASS' else 'FAIL' end as result, name, coalesce(detail, '') as detail from test_results order by name;
do $$
declare n int; f int;
begin
  select count(*), count(*) filter (where not ok) into n, f from test_results;
  if f > 0 then raise exception 'TAX W2 TESTS FAILED: % of %', f, n; end if;
  if n < 20 then raise exception 'TAX W2 TESTS INCOMPLETE: % of 20 checks ran', n; end if;
end $$;
