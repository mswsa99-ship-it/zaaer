-- 0069 — W2 of the guest journey (plan «خطة تصحيح ملاحظات التجربة», stage م٤, «مفاتيح الضريبة»; the tax decision of
-- 27 October): the value-added tax is off by default, and each of rent, services and products has its own switch
-- and its own rate in the branch's settings (the owner's alone, decision 68). Each product, as each service, keeps
-- its own «خاضع للضريبة» switch. What was recorded before a change stays as it was:
--   · a reservation keeps the tax policy it was made under (decision 68) — now three rates: for its rent, for the
--     services added to it and for the products ordered in it. A change of the branch's switches reaches new
--     reservations only; a reservation made before this migration keeps its one rate for all three;
--   · branches.tax_rate_bp stays what every reader of it knows: the rent rate in force (0 while the rent switch is
--     off), held to the switch by a constraint of the table;
--   · a product order says how much of its total is tax, and what is paid is exactly what the order showed.

-- ---------------------------------------------------------------------------------------------------------------
-- 1. The switches and the rates of a branch
-- ---------------------------------------------------------------------------------------------------------------
alter table branches add column if not exists tax_rent_enabled boolean not null default false;
alter table branches add column if not exists tax_rent_rate_bp int not null default 1500;
alter table branches add column if not exists tax_services_enabled boolean not null default false;
alter table branches add column if not exists tax_services_rate_bp int not null default 1500;
alter table branches add column if not exists tax_products_enabled boolean not null default false;
alter table branches add column if not exists tax_products_rate_bp int not null default 1500;
-- a branch that charges tax today charges its one rate on everything taxable: its three switches start on, at that rate
update branches set tax_rent_enabled = true, tax_rent_rate_bp = tax_rate_bp, tax_services_enabled = true, tax_services_rate_bp = tax_rate_bp,
                    tax_products_enabled = true, tax_products_rate_bp = tax_rate_bp
 where tax_rate_bp > 0 and not tax_rent_enabled;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'branches_tax_rates_valid') then
    alter table branches add constraint branches_tax_rates_valid
      check (tax_rent_rate_bp between 1 and 10000 and tax_services_rate_bp between 1 and 10000 and tax_products_rate_bp between 1 and 10000);
  end if;
  -- the rent rate in force is the rent switch and its rate, never anything else
  if not exists (select 1 from pg_constraint where conname = 'branches_tax_rent_in_force') then
    alter table branches add constraint branches_tax_rent_in_force
      check (tax_rate_bp = case when tax_rent_enabled then tax_rent_rate_bp else 0 end);
  end if;
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 2. The policy a reservation is made under: three rates
-- ---------------------------------------------------------------------------------------------------------------
-- (null on a reservation made before this migration: its one rate, tax_rate_bp, stands for all three)
alter table reservations add column if not exists tax_services_rate_bp int;
alter table reservations add column if not exists tax_products_rate_bp int;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'reservations_tax_rates_valid') then
    alter table reservations add constraint reservations_tax_rates_valid
      check ((tax_services_rate_bp is null or tax_services_rate_bp between 0 and 10000) and (tax_products_rate_bp is null or tax_products_rate_bp between 0 and 10000));
  end if;
end $$;

create or replace function fn_reservation_tax_snapshot() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.tax_rate_bp is null or new.prices_include_tax is null or new.tax_services_rate_bp is null or new.tax_products_rate_bp is null then
    select coalesce(new.tax_rate_bp, b.tax_rate_bp), coalesce(new.prices_include_tax, b.prices_include_tax),
           coalesce(new.tax_services_rate_bp, case when b.tax_services_enabled then b.tax_services_rate_bp else 0 end),
           coalesce(new.tax_products_rate_bp, case when b.tax_products_enabled then b.tax_products_rate_bp else 0 end)
      into new.tax_rate_bp, new.prices_include_tax, new.tax_services_rate_bp, new.tax_products_rate_bp
      from branches b where b.id = new.branch_id;
  end if;
  return new;
end $$;
revoke all on function fn_reservation_tax_snapshot() from public, anon, authenticated;

-- the tax of an amount on a reservation, by the policy the reservation was made under and by what the amount is
-- for: rent, a service or a product (half up at the line)
create or replace function fn_charge_tax(p_reservation uuid, p_category text, p_amount bigint, p_taxable boolean) returns table(net_halalas bigint, tax_halalas bigint)
language plpgsql stable security definer set search_path = public as $$
declare rate int; incl boolean;
begin
  if p_category is null or p_category not in ('rent', 'services', 'products') then raise exception 'VALIDATION: tax_category'; end if;
  select case p_category when 'rent' then coalesce(r.tax_rate_bp, b.tax_rate_bp)
                         when 'services' then coalesce(r.tax_services_rate_bp, r.tax_rate_bp, b.tax_rate_bp)
                         else coalesce(r.tax_products_rate_bp, r.tax_rate_bp, b.tax_rate_bp) end,
         coalesce(r.prices_include_tax, b.prices_include_tax) into rate, incl
  from reservations r join branches b on b.id = r.branch_id where r.id = p_reservation;
  if not p_taxable or coalesce(rate, 0) = 0 then return query select p_amount, 0::bigint; return; end if;
  if incl then
    tax_halalas := p_amount - round(p_amount::numeric * 10000 / (10000 + rate));
    return query select p_amount - tax_halalas, tax_halalas;
  else
    tax_halalas := round(p_amount::numeric * rate / 10000);
    return query select p_amount, tax_halalas;
  end if;
end $$;
revoke all on function fn_charge_tax(uuid, text, bigint, boolean) from public, anon, authenticated;

-- the rent's tax, as every reader of it asks for it
create or replace function fn_reservation_tax(p_reservation uuid, p_amount bigint, p_taxable boolean) returns table(net_halalas bigint, tax_halalas bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  return query select t.net_halalas, t.tax_halalas from fn_charge_tax(p_reservation, 'rent', p_amount, p_taxable) t;
end $$;
revoke all on function fn_reservation_tax(uuid, bigint, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 3. A line of the stay, taxed by what it is for
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_add_charge_in(p_category text, p_reservation uuid, p_kind text, p_description text, p_quantity numeric, p_unit_price bigint, p_taxable boolean, p_reason text,
                                            p_service uuid default null, p_service_from date default null, p_service_to date default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; gross bigint; net bigint; tax bigint; cid uuid; sf date; st date; today date;
begin
  select * into r from reservations where id = p_reservation;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  gross := round(p_quantity * p_unit_price);                      -- whole halalas, half up (decision 47)
  if p_kind = 'discount' then gross := -abs(gross); end if;
  select * into net, tax from fn_charge_tax(r.id, p_category, gross, p_taxable);
  today := fn_branch_today(r.branch_id);
  sf := coalesce(p_service_from, case when p_kind in ('rent', 'discount', 'adjustment') then r.check_in else today end);
  st := coalesce(p_service_to,   case when p_kind in ('rent', 'discount', 'adjustment') then r.check_out else today end);
  if st < sf then raise exception 'VALIDATION: service_period'; end if;
  insert into reservation_charges(organization_id, branch_id, reservation_id, kind, description, quantity, unit_price_halalas, total_halalas, taxable, service_definition_id, reason, created_by, service_from, service_to)
  values (r.organization_id, r.branch_id, r.id, p_kind, p_description, p_quantity, p_unit_price, net, p_taxable, p_service, p_reason, fn_staff_id(), sf, st) returning id into cid;
  if tax <> 0 then
    insert into reservation_charges(organization_id, branch_id, reservation_id, kind, description, quantity, unit_price_halalas, total_halalas, taxable, reason, created_by, service_from, service_to, base_charge_id)
    values (r.organization_id, r.branch_id, r.id, 'tax', 'ضريبة القيمة المضافة — ' || p_description, 1, tax, tax, false, p_reason, fn_staff_id(), sf, st, cid);
  end if;
  return cid;
end $$;
revoke all on function fn_add_charge_in(text, uuid, text, text, numeric, bigint, boolean, text, uuid, date, date) from public, anon, authenticated;

-- rent, its discounts and its adjustments carry the rent's tax; everything else added to a stay (a service, an
-- addition, a penalty) carries the services' tax. A product order's lines are added as products (§4).
create or replace function fn_add_charge(p_reservation uuid, p_kind text, p_description text, p_quantity numeric, p_unit_price bigint, p_taxable boolean, p_reason text,
                                         p_service uuid default null, p_service_from date default null, p_service_to date default null) returns uuid
language plpgsql security definer set search_path = public as $$
begin
  return fn_add_charge_in(case when p_kind in ('rent', 'discount', 'adjustment') then 'rent' else 'services' end,
                          p_reservation, p_kind, p_description, p_quantity, p_unit_price, p_taxable, p_reason, p_service, p_service_from, p_service_to);
end $$;
revoke all on function fn_add_charge(uuid, text, text, numeric, bigint, boolean, text, uuid, date, date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 4. Product orders: the products' tax, shown on the order and paid as shown
-- ---------------------------------------------------------------------------------------------------------------
alter table product_order_lines add column if not exists tax_halalas bigint not null default 0;   -- the part of total_halalas that is tax

create or replace function fn_product_order_json(p_order uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', o.id, 'number', o.number, 'status', o.status, 'source', o.source, 'total_halalas', o.total_halalas,
           'tax_halalas', coalesce((select sum(l.tax_halalas) from product_order_lines l where l.order_id = o.id), 0),
           'tax_included', coalesce(r.prices_include_tax, false),
           'reservation_id', o.reservation_id, 'internal_ref', r.internal_ref, 'room_number', rm.room_number, 'branch_id', o.branch_id,
           'created_at', o.created_at, 'paid_at', o.paid_at, 'delivered_at', o.delivered_at, 'cancelled_at', o.cancelled_at, 'cancel_reason', o.cancel_reason,
           'voucher_number', (select number from financial_vouchers where id = o.voucher_id),
           'task_status', (select status from housekeeping_tasks where id = o.task_id), 'version', o.version,
           'lines', coalesce((select jsonb_agg(jsonb_build_object('product_id', l.product_id, 'name', l.name, 'quantity', l.quantity,
                                                                 'unit_price_halalas', l.unit_price_halalas, 'total_halalas', l.total_halalas) order by l.created_at, l.name)
                              from product_order_lines l where l.order_id = o.id), '[]'::jsonb))
  from product_orders o left join reservations r on r.id = o.reservation_id left join rooms rm on rm.id = r.room_id
  where o.id = p_order
$$;
revoke all on function fn_product_order_json(uuid) from public, anon, authenticated;

-- adds items to the stay's open order (or opens one). The stay must be checked in, in a room. Items: [{product_id, quantity}].
-- Locks the stay first, then the order: the order every money operation on a stay takes.
create or replace function fn_product_order_add(p_reservation uuid, p_items jsonb, p_source text, p_conversation uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; o product_orders%rowtype; it record; x products%rowtype; q int; net bigint; tax bigint; fresh boolean := false;
begin
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  if r.status <> 'checked_in' or r.room_id is null then raise exception 'VALIDATION: not_in_stay'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 20 then raise exception 'VALIDATION: items'; end if;
  if exists (select 1 from jsonb_array_elements(p_items) e
              where jsonb_typeof(e) <> 'object'
                 or coalesce(e->>'product_id', '') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
                 or coalesce(e->>'quantity', '') !~ '^[0-9]{1,2}$' or (e->>'quantity')::int not between 1 and 50) then
    raise exception 'VALIDATION: items';
  end if;
  -- the stay's open order of the same channel (the guest adds to it until it is paid), else a new one
  select * into o from product_orders where reservation_id = r.id and status = 'pending_payment' and source = p_source
   order by created_at desc limit 1 for update;
  if not found then
    insert into product_orders(organization_id, branch_id, reservation_id, number, source, conversation_id, created_by)
    values (r.organization_id, r.branch_id, r.id, fn_next_document_number(r.organization_id, 'product_order', 'ORD'), p_source, p_conversation, fn_staff_id())
    returning * into o;
    fresh := true;
  end if;
  for it in select (e->>'product_id')::uuid as pid, sum((e->>'quantity')::int)::int as qty from jsonb_array_elements(p_items) e group by 1 order by 1 loop
    select * into x from products where id = it.pid and organization_id = r.organization_id;
    if not found or not x.is_active
       or not exists (select 1 from product_categories c where c.id = x.category_id and c.is_active)
       or not exists (select 1 from product_branches pb where pb.product_id = x.id and pb.branch_id = r.branch_id and pb.available) then
      raise exception 'VALIDATION: product_unavailable';
    end if;
    select quantity into q from product_order_lines where order_id = o.id and product_id = x.id;
    q := coalesce(q, 0) + it.qty;
    if q > 50 then raise exception 'VALIDATION: order_quantity'; end if;
    -- the products' tax of the policy the stay was made under
    select * into net, tax from fn_charge_tax(r.id, 'products', x.price_halalas * q, x.taxable);
    insert into product_order_lines(organization_id, order_id, product_id, name, unit_price_halalas, quantity, taxable, total_halalas, tax_halalas)
    values (o.organization_id, o.id, x.id, x.name, x.price_halalas, q, x.taxable, net + tax, tax)
    on conflict (order_id, product_id) do update set quantity = excluded.quantity, total_halalas = excluded.total_halalas, tax_halalas = excluded.tax_halalas,
                                                     unit_price_halalas = excluded.unit_price_halalas, name = excluded.name, taxable = excluded.taxable;
  end loop;
  update product_orders set total_halalas = (select coalesce(sum(total_halalas), 0) from product_order_lines where order_id = o.id),
                            conversation_id = coalesce(conversation_id, p_conversation), version = version + 1, updated_at = now()
   where id = o.id;
  perform fn_audit_change(r.branch_id, case when fresh then 'product_order.created' else 'product_order.added' end, 'product_order', o.id, null,
                          jsonb_build_object('number', o.number, 'items', p_items, 'source', p_source));
  if fresh then
    insert into notifications(branch_id, audience, title, body, link)
    values (r.branch_id, 'supervisor', 'طلب منتجات بانتظار الدفع',
            o.number || ' — غرفة ' || coalesce((select room_number from rooms where id = r.room_id), '') , '/staff/orders');
  end if;
  return fn_product_order_json(o.id);
end $$;
revoke all on function fn_product_order_add(uuid, jsonb, text, uuid) from public, anon, authenticated;

-- what the guest's branch offers, whether the guest can order now, the open order, and the products' tax of the stay
-- (so the prices are read as they will be charged: before the tax, or with it)
create or replace function fn_guest_products(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r reservations%rowtype;
begin
  select * into r from reservations where id = fn_token_reservation(p_token);
  return jsonb_build_object('can_order', r.status = 'checked_in' and r.room_id is not null,
                            'categories', fn_branch_products(r.branch_id),
                            'tax', jsonb_build_object('rate_bp', coalesce(r.tax_products_rate_bp, r.tax_rate_bp, 0), 'included', coalesce(r.prices_include_tax, false)),
                            'open_order', (select fn_product_order_json(o.id) from product_orders o
                                            where o.reservation_id = r.id and o.status = 'pending_payment' and o.source = 'whatsapp' order by o.created_at desc limit 1));
end $$;
revoke all on function fn_guest_products(text) from public, anon, authenticated;
grant execute on function fn_guest_products(text) to service_role;

-- the stays of a branch the reception can order for (checked in, in a room) with the products' tax of each, and what
-- the branch offers
create or replace function fn_staff_product_menu(p_branch uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform fn_require_cap('voucher.receipt');
  perform fn_require_branch(p_branch);
  return jsonb_build_object('categories', fn_branch_products(p_branch),
    'stays', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'internal_ref', r.internal_ref, 'room_number', rm.room_number,
                                                           'tax_rate_bp', coalesce(r.tax_products_rate_bp, r.tax_rate_bp, 0), 'tax_included', coalesce(r.prices_include_tax, false))
                                         order by rm.room_number)
                         from reservations r join rooms rm on rm.id = r.room_id where r.branch_id = p_branch and r.status = 'checked_in'), '[]'::jsonb));
end $$;
revoke all on function fn_staff_product_menu(uuid) from public, anon;
grant execute on function fn_staff_product_menu(uuid) to authenticated;

-- payment, then the voucher, then the delivery task, in one step: the order's lines join the stay's account, a receipt
-- of the same amount pays them, and the delivery task is created. p: {order_id, method, reference?, account_id?,
-- idempotency_key, expected_version, duplicate_reference_ok?}
create or replace function fn_staff_pay_product_order(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o product_orders%rowtype; r reservations%rowtype; l record; cid uuid; amt bigint; v jsonb; tid uuid; key text := btrim(coalesce(p->>'idempotency_key', ''));
        items text;
begin
  perform fn_require_cap('voucher.receipt');
  if coalesce(p->>'order_id', '') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then raise exception 'NOT_FOUND'; end if;
  if key = '' then raise exception 'VALIDATION: idempotency_key'; end if;
  -- paid at the hotel: cash, a card terminal or a transfer (a platform never collects for an order)
  if coalesce(p->>'method', '') not in ('cash', 'pos', 'bank_transfer') then raise exception 'VALIDATION: order_method'; end if;
  select * into o from product_orders where id = (p->>'order_id')::uuid and organization_id = fn_user_org_id();
  if not found then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(o.branch_id);
  -- the stay, then the order (the order every money operation on the stay takes)
  select * into r from reservations where id = o.reservation_id for update;
  select * into o from product_orders where id = o.id for update;
  if o.status <> 'pending_payment' then
    -- the same request again: its result
    if o.voucher_id is not null and exists (select 1 from financial_vouchers where id = o.voucher_id and idempotency_key = key) then
      return jsonb_build_object('ok', true, 'duplicate', true, 'order', fn_product_order_json(o.id));
    end if;
    raise exception 'VALIDATION: order_status';
  end if;
  -- what is paid is what the cashier was shown: an item added meanwhile (the guest, a colleague) refuses the payment
  perform fn_check_version_strict(o.version, nullif(p->>'expected_version', '')::int);
  if not exists (select 1 from product_order_lines where order_id = o.id) then raise exception 'VALIDATION: items'; end if;
  if r.status <> 'checked_in' or r.room_id is null then raise exception 'VALIDATION: not_in_stay'; end if;
  -- the lines join the stay's account as products, with the products' tax
  for l in select * from product_order_lines where order_id = o.id order by created_at, name loop
    cid := fn_add_charge_in('products', r.id, 'addon', l.name || ' × ' || l.quantity, l.quantity, l.unit_price_halalas, l.taxable, 'طلب ' || o.number);
    update reservation_charges set product_order_id = o.id where id = cid or base_charge_id = cid;
  end loop;
  select coalesce(sum(total_halalas), 0) into amt from reservation_charges where product_order_id = o.id;
  -- and they are exactly what the order showed
  if amt <> o.total_halalas then raise exception 'VALIDATION: order_total'; end if;
  -- the receipt of exactly that amount, marked as this order's (its entry goes to product revenue)
  perform set_config('fivehours.product_order', o.id::text, true);
  v := fn_create_voucher(jsonb_build_object('reservation_id', r.id, 'kind', 'receipt', 'amount_halalas', amt, 'method', p->>'method',
                                            'reference', p->>'reference', 'account_id', p->>'account_id', 'idempotency_key', key,
                                            'duplicate_reference_ok', coalesce((p->>'duplicate_reference_ok')::boolean, false),
                                            'note', 'طلب منتجات ' || o.number));
  perform set_config('fivehours.product_order', '', true);
  if not exists (select 1 from financial_vouchers where id = (v->>'voucher_id')::uuid and product_order_id = o.id and status = 'approved') then
    raise exception 'VALIDATION: order_voucher';
  end if;
  -- the delivery task for the guest's room. It is the order's (product_orders.task_id), not the stay's: the check-out
  -- looks for an open task of the stay before it creates the departure cleaning, and a delivery must not stand for it
  select string_agg(quantity || ' × ' || name, '، ' order by created_at, name) into items from product_order_lines where order_id = o.id;
  insert into housekeeping_tasks(organization_id, branch_id, room_id, task_type_id, task_type_name_snapshot, priority, description, created_by)
  values (r.organization_id, r.branch_id, r.room_id, fn_product_delivery_type(r.branch_id), 'تسليم طلب منتجات', 'high',
          'تسليم ' || o.number || ': ' || items, fn_staff_id())
  returning id into tid;
  update product_orders set status = 'paid', voucher_id = (v->>'voucher_id')::uuid, task_id = tid,
                            paid_at = now(), paid_by = fn_staff_id(), version = version + 1, updated_at = now()
   where id = o.id;
  insert into notifications(branch_id, audience, title, body, link)
  values (r.branch_id, 'supervisor', 'تسليم طلب منتجات', o.number || ' — غرفة ' || (select room_number from rooms where id = r.room_id), '/staff/housekeeping');
  perform fn_audit_change(r.branch_id, 'product_order.paid', 'product_order', o.id, jsonb_build_object('status', 'pending_payment'),
                          jsonb_build_object('status', 'paid', 'number', o.number, 'amount_halalas', amt, 'voucher', v->>'number', 'method', p->>'method'));
  return jsonb_build_object('ok', true, 'duplicate', false, 'voucher_number', v->>'number', 'order', fn_product_order_json(o.id));
end $$;
revoke all on function fn_staff_pay_product_order(jsonb) from public, anon;
grant execute on function fn_staff_pay_product_order(jsonb) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 5. The settings: the owner's switches (decision 68: the tax policy is the owner's alone)
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_admin_upsert_branch(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b branches%rowtype; v_id uuid := (p->>'id')::uuid; before jsonb; tax_changed boolean;
        v_map text := nullif(trim(coalesce(p->>'map_url', '')), ''); v_link text := nullif(trim(coalesce(p->>'booking_platform_url', '')), '');
        v_phone text := nullif(trim(fn_latin_digits(coalesce(p->>'phone', ''))), ''); v_email text := nullif(lower(trim(coalesce(p->>'email', ''))), '');
        k text; has_switches boolean := false; v_one int;
        v_rent_on boolean; v_rent_bp int; v_svc_on boolean; v_svc_bp int; v_prod_on boolean; v_prod_bp int;
begin
  perform fn_require_cap('branch.settings');
  if coalesce(trim(p->>'name_ar'), '') = '' then raise exception 'VALIDATION: name_ar'; end if;
  -- decision 31: the English name is required (a change that leaves it out keeps the one on file)
  if (v_id is null or p ? 'name_en') and coalesce(trim(p->>'name_en'), '') = '' then raise exception 'VALIDATION: name_en'; end if;
  -- SETUP-09: one branch per name in the organisation (archived branches aside); a phone and an email that work
  if exists (select 1 from branches x where x.organization_id = fn_user_org_id() and x.archived_at is null and x.id is distinct from v_id
               and fn_normalize_ar(trim(x.name_ar)) = fn_normalize_ar(trim(p->>'name_ar'))) then
    raise exception 'DUPLICATE_BRANCH_NAME';
  end if;
  if p ? 'phone' and v_phone is not null and fn_normalize_phone(v_phone) is null then raise exception 'VALIDATION: phone'; end if;
  if p ? 'email' and v_email is not null and not fn_valid_email(v_email) then raise exception 'VALIDATION: email'; end if;
  if p ? 'timezone' then
    begin perform now() at time zone (p->>'timezone'); exception when others then raise exception 'VALIDATION: timezone'; end;
  end if;
  if (p->>'tax_rate_bp') is not null and ((p->>'tax_rate_bp') !~ '^[0-9]{1,4}$' or (p->>'tax_rate_bp')::int > 10000) then raise exception 'VALIDATION: tax_rate'; end if;
  -- W2: each of rent, services and products has its switch (true or false) and its rate (0.01% to 100%)
  foreach k in array array['tax_rent_enabled', 'tax_services_enabled', 'tax_products_enabled'] loop
    if p ? k then
      if jsonb_typeof(p->k) <> 'boolean' then raise exception 'VALIDATION: tax_switch'; end if;
      has_switches := true;
    end if;
  end loop;
  foreach k in array array['tax_rent_rate_bp', 'tax_services_rate_bp', 'tax_products_rate_bp'] loop
    if p ? k then
      if coalesce(p->>k, '') !~ '^[0-9]{1,5}$' or (p->>k)::int not between 1 and 10000 then raise exception 'VALIDATION: tax_rate'; end if;
      has_switches := true;
    end if;
  end loop;
  if (p ? 'prices_include_tax') and jsonb_typeof(p->'prices_include_tax') not in ('boolean', 'null') then raise exception 'VALIDATION: tax_switch'; end if;
  if (p->>'default_deposit_halalas') is not null and (p->>'default_deposit_halalas') !~ '^[0-9]{1,12}$' then raise exception 'VALIDATION: amount'; end if;
  if (p->>'supervisor_max_discount_bp') is not null and ((p->>'supervisor_max_discount_bp') !~ '^[0-9]{1,5}$' or (p->>'supervisor_max_discount_bp')::int > 10000) then
    raise exception 'VALIDATION: discount_limit';
  end if;
  if (p->>'country_code') is not null and (p->>'country_code') !~ '^[A-Z]{2}$' then raise exception 'VALIDATION: country'; end if;
  if (p->>'default_language') is not null and (p->>'default_language') not in ('ar', 'en') then raise exception 'VALIDATION: language'; end if;
  if v_map is not null and not fn_valid_map_url(v_map) then raise exception 'VALIDATION: map_url'; end if;
  if v_link is not null and not fn_valid_https_url(v_link) then raise exception 'VALIDATION: booking_url'; end if;
  -- the one rate of the screen before the switches (tax_rate_bp alone): on everything taxable, as it was then
  v_one := case when has_switches then null else (p->>'tax_rate_bp')::int end;
  if v_id is null then
    perform fn_require_role('owner');
    v_rent_on := coalesce((p->>'tax_rent_enabled')::boolean, coalesce(v_one, 0) > 0);
    v_svc_on := coalesce((p->>'tax_services_enabled')::boolean, coalesce(v_one, 0) > 0);
    v_prod_on := coalesce((p->>'tax_products_enabled')::boolean, coalesce(v_one, 0) > 0);
    v_rent_bp := coalesce((p->>'tax_rent_rate_bp')::int, nullif(v_one, 0), 1500);
    v_svc_bp := coalesce((p->>'tax_services_rate_bp')::int, nullif(v_one, 0), 1500);
    v_prod_bp := coalesce((p->>'tax_products_rate_bp')::int, nullif(v_one, 0), 1500);
    insert into branches(organization_id, name_ar, name_en, city, address, map_url, phone, email, check_in_time, check_out_time, timezone, tax_rate_bp, prices_include_tax,
                         tax_rent_enabled, tax_rent_rate_bp, tax_services_enabled, tax_services_rate_bp, tax_products_enabled, tax_products_rate_bp,
                         default_deposit_halalas, tax_number, commercial_register, is_active, supervisor_max_discount_bp, country_code, default_language, booking_platform_url)
    values (fn_user_org_id(), trim(p->>'name_ar'), trim(p->>'name_en'), p->>'city', p->>'address', v_map, v_phone, v_email,
            coalesce((p->>'check_in_time')::time, '16:00'), coalesce((p->>'check_out_time')::time, '12:00'),
            coalesce(p->>'timezone', 'Asia/Riyadh'), case when v_rent_on then v_rent_bp else 0 end, coalesce((p->>'prices_include_tax')::boolean, false),
            v_rent_on, v_rent_bp, v_svc_on, v_svc_bp, v_prod_on, v_prod_bp,
            coalesce((p->>'default_deposit_halalas')::bigint, 5000), nullif(trim(coalesce(p->>'tax_number', '')), ''), p->>'commercial_register', coalesce((p->>'is_active')::boolean, true),
            coalesce((p->>'supervisor_max_discount_bp')::int, 0), coalesce(p->>'country_code', 'SA'), coalesce(p->>'default_language', 'ar'), v_link)
    returning * into b;
    perform fn_room_cleaning_type(b.id);   -- (its cash box and bank account come from trg_branch_bootstrap_accounts)
    perform fn_audit_change(b.id, 'branch.created', 'branch', b.id, null, to_jsonb(b));
  else
    select * into b from branches where id = v_id and organization_id = fn_user_org_id() for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    perform fn_require_branch(b.id);
    perform fn_check_version(b.version, (p->>'version')::int);
    if has_switches then
      v_rent_on := coalesce((p->>'tax_rent_enabled')::boolean, b.tax_rent_enabled); v_rent_bp := coalesce((p->>'tax_rent_rate_bp')::int, b.tax_rent_rate_bp);
      v_svc_on := coalesce((p->>'tax_services_enabled')::boolean, b.tax_services_enabled); v_svc_bp := coalesce((p->>'tax_services_rate_bp')::int, b.tax_services_rate_bp);
      v_prod_on := coalesce((p->>'tax_products_enabled')::boolean, b.tax_products_enabled); v_prod_bp := coalesce((p->>'tax_products_rate_bp')::int, b.tax_products_rate_bp);
    elsif v_one is not null and v_one is distinct from b.tax_rate_bp then
      v_rent_on := v_one > 0; v_svc_on := v_one > 0; v_prod_on := v_one > 0;
      v_rent_bp := coalesce(nullif(v_one, 0), b.tax_rent_rate_bp); v_svc_bp := coalesce(nullif(v_one, 0), b.tax_services_rate_bp); v_prod_bp := coalesce(nullif(v_one, 0), b.tax_products_rate_bp);
    else
      v_rent_on := b.tax_rent_enabled; v_rent_bp := b.tax_rent_rate_bp; v_svc_on := b.tax_services_enabled; v_svc_bp := b.tax_services_rate_bp;
      v_prod_on := b.tax_products_enabled; v_prod_bp := b.tax_products_rate_bp;
    end if;
    tax_changed := row(v_rent_on, v_rent_bp, v_svc_on, v_svc_bp, v_prod_on, v_prod_bp)
                     is distinct from row(b.tax_rent_enabled, b.tax_rent_rate_bp, b.tax_services_enabled, b.tax_services_rate_bp, b.tax_products_enabled, b.tax_products_rate_bp)
                or ((p->>'prices_include_tax') is not null and (p->>'prices_include_tax')::boolean is distinct from b.prices_include_tax)
                or ((p ? 'tax_number') and nullif(trim(coalesce(p->>'tax_number', '')), '') is distinct from b.tax_number);
    if tax_changed and not fn_can('branch.tax') then raise exception 'FORBIDDEN: tax settings are the owner''s'; end if;
    if not (p ? 'name_en') and coalesce(trim(b.name_en), '') = '' then raise exception 'VALIDATION: name_en'; end if;
    before := to_jsonb(b);
    update branches set
      name_ar = trim(p->>'name_ar'), name_en = case when p ? 'name_en' then trim(p->>'name_en') else name_en end, city = coalesce(p->>'city', city), address = coalesce(p->>'address', address),
      map_url = case when p ? 'map_url' then v_map else map_url end,
      phone = case when p ? 'phone' then v_phone else phone end, email = case when p ? 'email' then v_email else email end,
      check_in_time = coalesce((p->>'check_in_time')::time, check_in_time), check_out_time = coalesce((p->>'check_out_time')::time, check_out_time),
      timezone = coalesce(p->>'timezone', timezone), tax_rate_bp = case when v_rent_on then v_rent_bp else 0 end,
      tax_rent_enabled = v_rent_on, tax_rent_rate_bp = v_rent_bp, tax_services_enabled = v_svc_on, tax_services_rate_bp = v_svc_bp,
      tax_products_enabled = v_prod_on, tax_products_rate_bp = v_prod_bp,
      prices_include_tax = coalesce((p->>'prices_include_tax')::boolean, prices_include_tax),
      default_deposit_halalas = coalesce((p->>'default_deposit_halalas')::bigint, default_deposit_halalas),
      supervisor_max_discount_bp = coalesce((p->>'supervisor_max_discount_bp')::int, supervisor_max_discount_bp),
      tax_number = case when p ? 'tax_number' then nullif(trim(coalesce(p->>'tax_number', '')), '') else tax_number end,
      commercial_register = coalesce(p->>'commercial_register', commercial_register),
      country_code = coalesce(p->>'country_code', country_code), default_language = coalesce(p->>'default_language', default_language),
      booking_platform_url = case when p ? 'booking_platform_url' then v_link else booking_platform_url end,
      is_active = coalesce((p->>'is_active')::boolean, is_active), version = version + 1, updated_at = now()
    where id = b.id returning * into b;
    perform fn_audit_change(b.id, 'branch.updated', 'branch', b.id, before, to_jsonb(b));
    if tax_changed then
      perform fn_audit_change(b.id, 'branch.tax_changed', 'branch', b.id,
        jsonb_build_object('tax_rate_bp', before->'tax_rate_bp', 'prices_include_tax', before->'prices_include_tax', 'tax_number', before->'tax_number',
                           'tax_rent_enabled', before->'tax_rent_enabled', 'tax_rent_rate_bp', before->'tax_rent_rate_bp',
                           'tax_services_enabled', before->'tax_services_enabled', 'tax_services_rate_bp', before->'tax_services_rate_bp',
                           'tax_products_enabled', before->'tax_products_enabled', 'tax_products_rate_bp', before->'tax_products_rate_bp'),
        jsonb_build_object('tax_rate_bp', b.tax_rate_bp, 'prices_include_tax', b.prices_include_tax, 'tax_number', b.tax_number,
                           'tax_rent_enabled', b.tax_rent_enabled, 'tax_rent_rate_bp', b.tax_rent_rate_bp,
                           'tax_services_enabled', b.tax_services_enabled, 'tax_services_rate_bp', b.tax_services_rate_bp,
                           'tax_products_enabled', b.tax_products_enabled, 'tax_products_rate_bp', b.tax_products_rate_bp),
        'يسري على الحجوزات الجديدة فقط');
    end if;
  end if;
  return jsonb_build_object('ok', true, 'id', b.id, 'version', b.version);
end $$;
revoke all on function fn_admin_upsert_branch(jsonb) from public, anon;
grant execute on function fn_admin_upsert_branch(jsonb) to authenticated;
