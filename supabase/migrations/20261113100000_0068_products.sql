-- 0068 — W1 of the guest journey (plan «خطة تصحيح ملاحظات التجربة», stage م٤, part 1: «المنتجات والشراء»):
--   · a catalogue of products in categories, without stock, each one made available or not in each branch by hand;
--   · a guest staying in a room orders from WhatsApp (or the reception orders for them): the order waits for payment;
--     while it waits the guest may add to it or cancel it;
--   · the order goes through payment, then the voucher, then the delivery task, in one step done by the reception: its
--     lines join the stay's account as charges and a receipt of the same amount is issued for it (so the stay's balance
--     does not move), and a delivery task for the guest's room is created; the order is delivered when that task is done;
--   · a paid order is cancelled only by the owner or the manager (its voucher is cancelled with it, its charges are
--     balanced back, its task is cancelled); its voucher and its task cannot be cancelled or corrected on their own;
--   · what a product order brings in is product revenue (43), not rent.

-- ---------------------------------------------------------------------------------------------------------------
-- 1. The log lines
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_audit_accounting_label(p_action text) returns text
language sql immutable set search_path = public as $$
  select case p_action
      when 'day_closing.created' then 'بدء إقفال يوم'
      when 'day_closing.submitted' then 'إرسال إقفال يوم'
      when 'day_closing.amended' then 'تعديل إقفال يوم خلال المهلة'
      when 'day_closing.edit_requested' then 'طلب تعديل إقفال بعد المهلة'
      when 'day_closing.edit_approved' then 'الموافقة على تعديل إقفال'
      when 'day_closing.edit_rejected' then 'رفض تعديل إقفال'
      when 'branch.day_close_rules_changed' then 'تغيير مهلة تعديل الإقفال'
      when 'expense.created' then 'إصدار سند صرف'
      when 'expense.cancelled' then 'إلغاء سند صرف'
      when 'expense_category.created' then 'إضافة تصنيف مصروف'
      when 'expense_category.updated' then 'تعديل تصنيف مصروف'
      when 'cash_account.opening_set' then 'تحديد الرصيد الافتتاحي'
      when 'accounting.month_locked' then 'قفل شهر محاسبي'
      when 'accounting.month_opened' then 'فتح شهر محاسبي'
      when 'bank_mail.settings_changed' then 'تعديل بريد البنك'
      when 'bank_rule.created' then 'إضافة قاعدة قراءة رسائل البنك'
      when 'bank_rule.updated' then 'تعديل قاعدة قراءة رسائل البنك'
      when 'bank_message.reparsed' then 'إعادة قراءة رسالة بنكية'
      when 'bank_movement.assigned' then 'نسبة حركة بنكية لحساب فرع'
      when 'bank_movement.matched' then 'مطابقة حركة بنكية'
      when 'bank_movement.unmatched' then 'فك مطابقة حركة بنكية'
      when 'bank_movement.converted' then 'تحويل حركة بنكية إلى سند'
      when 'product_category.created' then 'إضافة فئة منتجات'
      when 'product_category.updated' then 'تعديل فئة منتجات'
      when 'product.created' then 'إضافة منتج'
      when 'product.updated' then 'تعديل منتج'
      when 'product.availability_changed' then 'تغيير إتاحة منتج في فرع'
      when 'product_order.created' then 'طلب منتجات جديد'
      when 'product_order.added' then 'إضافة إلى طلب منتجات'
      when 'product_order.paid' then 'دفع طلب منتجات'
      when 'product_order.delivered' then 'تسليم طلب منتجات'
      when 'product_order.cancelled' then 'إلغاء طلب منتجات'
      else null
    end;
$$;
revoke all on function fn_audit_accounting_label(text) from public, anon;
grant execute on function fn_audit_accounting_label(text) to authenticated, service_role;
do $$
declare fn oid; def text; n int;
        old_e constant text := $a$when 'bank_match' then 'مطابقة بنكية' end$a$;
        new_e constant text := $b$when 'bank_match' then 'مطابقة بنكية' when 'product' then 'منتج' when 'product_category' then 'فئة منتجات' when 'product_order' then 'طلب منتجات' end$b$;
begin
  select p.oid into fn from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'fn_audit_entity_label';
  def := pg_get_functiondef(fn);
  n := (length(def) - length(replace(def, old_e, ''))) / length(old_e);
  if n <> 1 then raise exception '0068: the closing line of fn_audit_entity_label was found % times, not once', n; end if;
  execute replace(def, old_e, new_e);
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 2. The chart: product revenue (43)
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_gl_seed(p_org uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r record; v_parent uuid;
begin
  perform pg_advisory_xact_lock(hashtext('gl_seed:' || p_org::text));
  for r in select * from (values
      ('1',    'الأصول',                     'asset',     null,  false, 'assets'),
      ('11',   'النقد وما في حكمه',           'asset',     '1',   false, 'cash_group'),
      ('111',  'صناديق الفروع',              'asset',     '11',  false, 'cash_parent'),
      ('112',  'الحسابات البنكية',            'asset',     '11',  false, 'bank_parent'),
      ('12',   'الذمم المدينة',              'asset',     '1',   false, 'receivables'),
      ('121',  'مستحقات المنصات',            'asset',     '12',  false, 'platform_parent'),
      ('129',  'حساب معلّق',                 'asset',     '12',  true,  'suspense'),
      ('2',    'الالتزامات',                 'liability', null,  false, 'liabilities'),
      ('21',   'تأمينات الضيوف',             'liability', '2',   true,  'deposits'),
      ('3',    'حقوق الملكية',               'equity',    null,  false, 'equity'),
      ('31',   'الأرصدة الافتتاحية',          'equity',    '3',   true,  'opening'),
      ('4',    'الإيرادات',                  'revenue',   null,  false, 'revenue'),
      ('41',   'إيراد الإيجار',               'revenue',   '4',   true,  'rent_revenue'),
      ('42',   'مردودات الإيجار',             'revenue',   '4',   true,  'rent_returns'),
      ('43',   'إيراد المنتجات',              'revenue',   '4',   true,  'product_revenue'),
      ('49',   'إيرادات أخرى وزيادات',        'revenue',   '4',   true,  'other_income'),
      ('5',    'المصروفات',                  'expense',   null,  false, 'expenses'),
      ('51',   'المصروفات التشغيلية',         'expense',   '5',   false, 'expense_parent'),
      ('57',   'رسوم وفروق المطابقة البنكية',  'expense',   '5',   true,  'bank_fees'),
      ('58',   'عمولات المنصات',             'expense',   '5',   true,  'platform_commission'),
      ('59',   'عجز الصندوق',                'expense',   '5',   true,  'cash_shortage')
    ) t(code, name, type, parent, postable, key)
  loop
    if not exists (select 1 from gl_accounts where organization_id = p_org and system_key = r.key) then
      select id into v_parent from gl_accounts where organization_id = p_org and code = r.parent;
      insert into gl_accounts(organization_id, code, name, type, parent_id, is_postable, system_key)
      values (p_org, r.code, r.name, r.type, v_parent, r.postable, r.key);
    end if;
  end loop;
end $$;
revoke all on function fn_gl_seed(uuid) from public, anon, authenticated;
select fn_gl_seed(id) from organizations;

-- ---------------------------------------------------------------------------------------------------------------
-- 3. The tables
-- ---------------------------------------------------------------------------------------------------------------
create table if not exists product_categories (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  name text not null,
  sort_order int not null default 0,
  is_active boolean not null default true,
  version int not null default 1,
  created_by uuid references staff_profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint product_category_name_valid check (char_length(btrim(name)) between 1 and 40)
);
create unique index if not exists uniq_product_category_name on product_categories(organization_id, lower(name));

-- no stock is kept (decision of the appendix): a product is offered or not, by branch
create table if not exists products (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  category_id uuid not null references product_categories(id),
  name text not null,
  description text,
  price_halalas bigint not null,
  taxable boolean not null default true,       -- for the tax switches (W2); no tax is charged while a branch has none
  is_active boolean not null default true,
  sort_order int not null default 0,
  version int not null default 1,
  created_by uuid references staff_profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint product_name_valid check (char_length(btrim(name)) between 1 and 40),
  constraint product_description_valid check (description is null or char_length(description) <= 200),
  constraint product_price_valid check (price_halalas between 1 and 10000000)
);
create unique index if not exists uniq_product_name on products(organization_id, lower(name));
create index if not exists idx_products_category on products(category_id);

-- a product is offered in a branch only when the owner made it available there
create table if not exists product_branches (
  product_id uuid not null references products(id),
  branch_id uuid not null references branches(id),
  organization_id uuid not null references organizations(id),
  available boolean not null default false,
  updated_by uuid references staff_profiles(id),
  updated_at timestamptz not null default now(),
  primary key (product_id, branch_id)
);
create index if not exists idx_product_branches_branch on product_branches(branch_id) where available;

create table if not exists product_orders (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  branch_id uuid not null references branches(id),
  -- the stay, the voucher, the task and the conversation are kept by the functions, without a reference of the
  -- database: the trial-data purge (0022) removes those rows without knowing this table (its rows then stay behind,
  -- as the journal's do, until the purge update before going live covers them)
  reservation_id uuid not null,
  number text not null,
  status text not null default 'pending_payment',
  source text not null,                          -- whatsapp | staff
  conversation_id uuid,
  total_halalas bigint not null default 0,       -- the lines with their tax, as the stay's account will carry them
  voucher_id uuid,
  task_id uuid,
  created_by uuid references staff_profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  paid_at timestamptz,
  paid_by uuid references staff_profiles(id),
  delivered_at timestamptz,
  cancelled_at timestamptz,
  cancelled_by uuid references staff_profiles(id),
  cancel_reason text,
  version int not null default 1,
  constraint product_order_status_valid check (status in ('pending_payment', 'paid', 'delivered', 'cancelled')),
  constraint product_order_source_valid check (source in ('whatsapp', 'staff')),
  -- payment, then the voucher, then the delivery task: a paid or delivered order has both
  constraint product_order_paid_has_voucher check (status not in ('paid', 'delivered') or (voucher_id is not null and task_id is not null and paid_at is not null))
);
create unique index if not exists uniq_product_order_number on product_orders(organization_id, number);
create index if not exists idx_product_orders_branch on product_orders(branch_id, status, created_at desc);
create index if not exists idx_product_orders_reservation on product_orders(reservation_id);
create unique index if not exists uniq_product_order_task on product_orders(task_id) where task_id is not null;
create unique index if not exists uniq_product_order_voucher on product_orders(voucher_id) where voucher_id is not null;

create table if not exists product_order_lines (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  order_id uuid not null references product_orders(id),
  product_id uuid not null references products(id),
  name text not null,                            -- as it was when ordered
  unit_price_halalas bigint not null,
  quantity int not null,
  taxable boolean not null,
  total_halalas bigint not null,                 -- with its tax
  created_at timestamptz not null default now(),
  constraint product_order_line_quantity_valid check (quantity between 1 and 50)
);
create unique index if not exists uniq_product_order_line on product_order_lines(order_id, product_id);

-- what an order put in the stay's account, and the receipt that paid it (kept by the functions and the guard of §6;
-- no reference of the database, so the purge removes the order and these rows in whichever order it goes)
alter table reservation_charges add column if not exists product_order_id uuid;
alter table financial_vouchers add column if not exists product_order_id uuid;
create index if not exists idx_charges_product_order on reservation_charges(product_order_id) where product_order_id is not null;

-- read: the catalogue by the organisation's staff; the orders (amounts: money, as the vouchers) by the staff of their
-- branches who see money; written only by functions
alter table product_categories enable row level security;
alter table products enable row level security;
alter table product_branches enable row level security;
alter table product_orders enable row level security;
alter table product_order_lines enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'product_categories' and policyname = 'product_categories_read') then
    create policy "product_categories_read" on product_categories for select to authenticated using (organization_id = fn_user_org_id());
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'products' and policyname = 'products_read') then
    create policy "products_read" on products for select to authenticated using (organization_id = fn_user_org_id());
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'product_branches' and policyname = 'product_branches_read') then
    create policy "product_branches_read" on product_branches for select to authenticated using (organization_id = fn_user_org_id());
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'product_orders' and policyname = 'product_orders_read') then
    create policy "product_orders_read" on product_orders for select to authenticated
      using (organization_id = fn_user_org_id() and branch_id in (select fn_user_branch_ids()) and fn_sees_money());
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'product_order_lines' and policyname = 'product_order_lines_read') then
    create policy "product_order_lines_read" on product_order_lines for select to authenticated
      using (organization_id = fn_user_org_id() and order_id in (select id from product_orders));
  end if;
end $$;
revoke all on product_categories, products, product_branches, product_orders, product_order_lines from anon, authenticated;
grant select on product_categories, products, product_branches, product_orders, product_order_lines to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 4. The catalogue (settings: «المنتجات»)
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_admin_upsert_product_category(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c product_categories%rowtype; v_name text := btrim(coalesce(p->>'name', '')); before jsonb;
begin
  perform fn_require_cap('definitions');
  if v_name = '' or char_length(v_name) > 40 then raise exception 'VALIDATION: category_name'; end if;
  if (p ? 'sort_order') and coalesce(p->>'sort_order', '') !~ '^[0-9]{1,4}$' then raise exception 'VALIDATION: sort_order'; end if;
  if (p->>'id') is null then
    if exists (select 1 from product_categories where organization_id = fn_user_org_id() and lower(name) = lower(v_name)) then raise exception 'DUPLICATE_NAME'; end if;
    insert into product_categories(organization_id, name, sort_order, created_by)
    values (fn_user_org_id(), v_name, coalesce((p->>'sort_order')::int, (select coalesce(max(sort_order), 0) + 10 from product_categories where organization_id = fn_user_org_id())), fn_staff_id())
    returning * into c;
    perform fn_audit_change(null, 'product_category.created', 'product_category', c.id, null, to_jsonb(c));
  else
    select * into c from product_categories where id = (p->>'id')::uuid and organization_id = fn_user_org_id() for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    perform fn_check_version_strict(c.version, (p->>'version')::int);
    if exists (select 1 from products x join product_branches pb on pb.product_id = x.id
                where x.category_id = c.id and pb.available and pb.branch_id not in (select fn_user_branch_ids())) then
      raise exception 'FORBIDDEN: product_other_branch' using errcode = '42501';
    end if;
    if exists (select 1 from product_categories where organization_id = c.organization_id and lower(name) = lower(v_name) and id <> c.id) then raise exception 'DUPLICATE_NAME'; end if;
    before := to_jsonb(c);
    update product_categories set name = v_name, sort_order = coalesce((p->>'sort_order')::int, sort_order),
                                  is_active = coalesce((p->>'is_active')::boolean, is_active), version = version + 1, updated_at = now()
     where id = c.id returning * into c;
    perform fn_audit_change(null, 'product_category.updated', 'product_category', c.id, before, to_jsonb(c));
  end if;
  return jsonb_build_object('ok', true, 'id', c.id, 'version', c.version);
end $$;
revoke all on function fn_admin_upsert_product_category(jsonb) from public, anon;
grant execute on function fn_admin_upsert_product_category(jsonb) to authenticated;

create or replace function fn_admin_upsert_product(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare x products%rowtype; v_name text := btrim(coalesce(p->>'name', '')); v_desc text := nullif(btrim(coalesce(p->>'description', '')), '');
        v_price bigint; v_cat uuid; before jsonb;
begin
  perform fn_require_cap('definitions');
  if v_name = '' or char_length(v_name) > 40 then raise exception 'VALIDATION: product_name'; end if;
  if v_desc is not null and char_length(v_desc) > 200 then raise exception 'VALIDATION: product_description'; end if;
  if coalesce(p->>'price_halalas', '') !~ '^[0-9]{1,9}$' then raise exception 'VALIDATION: product_price'; end if;
  v_price := (p->>'price_halalas')::bigint;
  if v_price < 1 or v_price > 10000000 then raise exception 'VALIDATION: product_price'; end if;
  if (p ? 'sort_order') and coalesce(p->>'sort_order', '') !~ '^[0-9]{1,4}$' then raise exception 'VALIDATION: sort_order'; end if;
  if coalesce(p->>'category_id', '') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then raise exception 'VALIDATION: product_category'; end if;
  select id into v_cat from product_categories where id = (p->>'category_id')::uuid and organization_id = fn_user_org_id();
  if v_cat is null then raise exception 'VALIDATION: product_category'; end if;
  if (p->>'id') is null then
    if exists (select 1 from products where organization_id = fn_user_org_id() and lower(name) = lower(v_name)) then raise exception 'DUPLICATE_NAME'; end if;
    insert into products(organization_id, category_id, name, description, price_halalas, taxable, sort_order, created_by)
    values (fn_user_org_id(), v_cat, v_name, v_desc, v_price, coalesce((p->>'taxable')::boolean, true),
            coalesce((p->>'sort_order')::int, (select coalesce(max(sort_order), 0) + 10 from products where organization_id = fn_user_org_id())), fn_staff_id())
    returning * into x;
    perform fn_audit_change(null, 'product.created', 'product', x.id, null, to_jsonb(x));
  else
    select * into x from products where id = (p->>'id')::uuid and organization_id = fn_user_org_id() for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    perform fn_check_version_strict(x.version, (p->>'version')::int);
    -- a product sold in a branch the caller does not work in is changed by the owner (or a manager of that branch too)
    if exists (select 1 from product_branches pb where pb.product_id = x.id and pb.available and pb.branch_id not in (select fn_user_branch_ids())) then
      raise exception 'FORBIDDEN: product_other_branch' using errcode = '42501';
    end if;
    if exists (select 1 from products where organization_id = x.organization_id and lower(name) = lower(v_name) and id <> x.id) then raise exception 'DUPLICATE_NAME'; end if;
    before := to_jsonb(x);
    -- an order already placed keeps the name and the price it was placed with
    update products set category_id = v_cat, name = v_name, description = v_desc, price_halalas = v_price,
                        taxable = coalesce((p->>'taxable')::boolean, taxable), is_active = coalesce((p->>'is_active')::boolean, is_active),
                        sort_order = coalesce((p->>'sort_order')::int, sort_order), version = version + 1, updated_at = now()
     where id = x.id returning * into x;
    perform fn_audit_change(null, 'product.updated', 'product', x.id, before, to_jsonb(x));
  end if;
  return jsonb_build_object('ok', true, 'id', x.id, 'version', x.version);
end $$;
revoke all on function fn_admin_upsert_product(jsonb) from public, anon;
grant execute on function fn_admin_upsert_product(jsonb) to authenticated;

-- the owner (or a manager in their branches) makes a product available in a branch, or not
create or replace function fn_admin_set_product_branch(p_product uuid, p_branch uuid, p_available boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare x products%rowtype; b branches%rowtype; was boolean;
begin
  perform fn_require_cap('definitions');
  select * into x from products where id = p_product and organization_id = fn_user_org_id();
  if not found then raise exception 'NOT_FOUND'; end if;
  select * into b from branches where id = p_branch and organization_id = x.organization_id;
  if not found then raise exception 'VALIDATION: product_branch'; end if;
  perform fn_require_branch(b.id);
  if p_available is null then raise exception 'VALIDATION: available'; end if;
  select available into was from product_branches where product_id = x.id and branch_id = b.id for update;
  insert into product_branches(product_id, branch_id, organization_id, available, updated_by, updated_at)
  values (x.id, b.id, x.organization_id, p_available, fn_staff_id(), now())
  on conflict (product_id, branch_id) do update set available = excluded.available, updated_by = excluded.updated_by, updated_at = now();
  if was is distinct from p_available then
    perform fn_audit_change(b.id, 'product.availability_changed', 'product', x.id, jsonb_build_object('available', coalesce(was, false)),
                            jsonb_build_object('available', p_available, 'branch', b.name_ar, 'product', x.name));
  end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function fn_admin_set_product_branch(uuid, uuid, boolean) from public, anon;
grant execute on function fn_admin_set_product_branch(uuid, uuid, boolean) to authenticated;

create or replace function fn_admin_products() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform fn_require_cap('definitions');
  return jsonb_build_object(
    'categories', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'sort_order', c.sort_order, 'is_active', c.is_active, 'version', c.version,
                                                                'products', (select count(*) from products x where x.category_id = c.id)) order by c.sort_order, c.name)
                            from product_categories c where c.organization_id = fn_user_org_id()), '[]'::jsonb),
    'products', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'category_id', x.category_id, 'name', x.name, 'description', x.description,
                                                              'price_halalas', x.price_halalas, 'taxable', x.taxable, 'is_active', x.is_active, 'sort_order', x.sort_order, 'version', x.version,
                                                              'branches', coalesce((select jsonb_agg(pb.branch_id order by pb.branch_id) from product_branches pb where pb.product_id = x.id and pb.available), '[]'::jsonb))
                                           order by x.sort_order, x.name)
                          from products x where x.organization_id = fn_user_org_id()), '[]'::jsonb),
    'branches', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name_ar, 'mine', b.id in (select fn_user_branch_ids())) order by b.name_ar)
                          from branches b where b.organization_id = fn_user_org_id()), '[]'::jsonb));
end $$;
revoke all on function fn_admin_products() from public, anon;
grant execute on function fn_admin_products() to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 5. Orders
-- ---------------------------------------------------------------------------------------------------------------
-- the products offered in a branch now: active, in an active category, made available there
create or replace function fn_branch_products(p_branch uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name,
           'products', (select jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'description', x.description, 'price_halalas', x.price_halalas) order by x.sort_order, x.name)
                          from products x join product_branches pb on pb.product_id = x.id and pb.branch_id = p_branch and pb.available
                         where x.category_id = c.id and x.is_active))
         order by c.sort_order, c.name), '[]'::jsonb)
  from product_categories c
  where c.organization_id = (select organization_id from branches where id = p_branch) and c.is_active
    and exists (select 1 from products x join product_branches pb on pb.product_id = x.id and pb.branch_id = p_branch and pb.available where x.category_id = c.id and x.is_active)
$$;
revoke all on function fn_branch_products(uuid) from public, anon, authenticated;

create or replace function fn_product_order_json(p_order uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', o.id, 'number', o.number, 'status', o.status, 'source', o.source, 'total_halalas', o.total_halalas,
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
    select * into net, tax from fn_reservation_tax(r.id, x.price_halalas * q, x.taxable);
    insert into product_order_lines(organization_id, order_id, product_id, name, unit_price_halalas, quantity, taxable, total_halalas)
    values (o.organization_id, o.id, x.id, x.name, x.price_halalas, q, x.taxable, net + tax)
    on conflict (order_id, product_id) do update set quantity = excluded.quantity, total_halalas = excluded.total_halalas,
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

-- ---- the guest (WhatsApp, through the webhook with its verified token) ----
-- what the guest's branch offers, whether the guest can order now, and the open order
create or replace function fn_guest_products(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r reservations%rowtype;
begin
  select * into r from reservations where id = fn_token_reservation(p_token);
  return jsonb_build_object('can_order', r.status = 'checked_in' and r.room_id is not null,
                            'categories', fn_branch_products(r.branch_id),
                            'open_order', (select fn_product_order_json(o.id) from product_orders o
                                            where o.reservation_id = r.id and o.status = 'pending_payment' and o.source = 'whatsapp' order by o.created_at desc limit 1));
end $$;
revoke all on function fn_guest_products(text) from public, anon, authenticated;
grant execute on function fn_guest_products(text) to service_role;

create or replace function fn_guest_order_products(p_token text, p_items jsonb, p_conversation uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare rid uuid := fn_token_reservation(p_token); conv uuid;
begin
  select id into conv from conversations where id = p_conversation and guest_token = p_token;
  return fn_product_order_add(rid, p_items, 'whatsapp', conv);
end $$;
revoke all on function fn_guest_order_products(text, jsonb, uuid) from public, anon, authenticated;
grant execute on function fn_guest_order_products(text, jsonb, uuid) to service_role;

-- the guest cancels their order while it waits for payment
create or replace function fn_guest_cancel_product_order(p_token text, p_number text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare rid uuid := fn_token_reservation(p_token); o product_orders%rowtype;
begin
  perform 1 from reservations where id = rid for update;
  select * into o from product_orders where reservation_id = rid and number = p_number for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if o.status <> 'pending_payment' or o.source <> 'whatsapp' then raise exception 'VALIDATION: order_status'; end if;
  update product_orders set status = 'cancelled', cancelled_at = now(), cancel_reason = 'ألغاه النزيل', version = version + 1, updated_at = now() where id = o.id;
  perform fn_audit_change(o.branch_id, 'product_order.cancelled', 'product_order', o.id, jsonb_build_object('status', o.status), jsonb_build_object('status', 'cancelled', 'by', 'guest'), 'ألغاه النزيل');
  return fn_product_order_json(o.id);
end $$;
revoke all on function fn_guest_cancel_product_order(text, text) from public, anon, authenticated;
grant execute on function fn_guest_cancel_product_order(text, text) to service_role;

-- the guest's orders of this stay (the latest first)
create or replace function fn_guest_product_orders(p_token text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(fn_product_order_json(o.id) order by o.created_at desc), '[]'::jsonb)
  from product_orders o where o.reservation_id = fn_token_reservation(p_token)
$$;
revoke all on function fn_guest_product_orders(text) from public, anon, authenticated;
grant execute on function fn_guest_product_orders(text) to service_role;

-- the assistant may say what a branch offers (no personal data)
create or replace function fn_public_products(p_branch uuid) returns jsonb
language sql stable security definer set search_path = public as $$ select fn_branch_products(p_branch) $$;
revoke all on function fn_public_products(uuid) from public, anon, authenticated;
grant execute on function fn_public_products(uuid) to service_role;

-- ---- the reception ----
create or replace function fn_staff_product_orders(p_branch uuid, p_status text default null, p_days int default 7) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform fn_require_cap('voucher.receipt');
  perform fn_require_branch(p_branch);
  if p_status is not null and p_status not in ('pending_payment', 'paid', 'delivered', 'cancelled') then raise exception 'VALIDATION: status'; end if;
  if p_days is null or p_days not between 1 and 90 then raise exception 'VALIDATION: days'; end if;
  return coalesce((select jsonb_agg(fn_product_order_json(o.id) order by o.created_at desc)
                     from product_orders o
                    where o.branch_id = p_branch and (p_status is null or o.status = p_status)
                      -- an order waiting for payment or for delivery stays listed whatever its age
                      and (o.status in ('pending_payment', 'paid') or o.created_at > now() - make_interval(days => p_days))
                      -- not one whose stay the trial-data purge removed (its rows stay until the purge covers them)
                      and exists (select 1 from reservations x where x.id = o.reservation_id)), '[]'::jsonb);
end $$;
revoke all on function fn_staff_product_orders(uuid, text, int) from public, anon;
grant execute on function fn_staff_product_orders(uuid, text, int) to authenticated;

-- the stays of a branch the reception can order for (checked in, in a room), with what the branch offers
create or replace function fn_staff_product_menu(p_branch uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform fn_require_cap('voucher.receipt');
  perform fn_require_branch(p_branch);
  return jsonb_build_object('categories', fn_branch_products(p_branch),
    'stays', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'internal_ref', r.internal_ref, 'room_number', rm.room_number) order by rm.room_number)
                         from reservations r join rooms rm on rm.id = r.room_id where r.branch_id = p_branch and r.status = 'checked_in'), '[]'::jsonb));
end $$;
revoke all on function fn_staff_product_menu(uuid) from public, anon;
grant execute on function fn_staff_product_menu(uuid) to authenticated;

create or replace function fn_staff_create_product_order(p_reservation uuid, p_items jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b uuid;
begin
  perform fn_require_cap('voucher.receipt');
  select branch_id into b from reservations where id = p_reservation and organization_id = fn_user_org_id();
  if b is null then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(b);
  return fn_product_order_add(p_reservation, p_items, 'staff', null);
end $$;
revoke all on function fn_staff_create_product_order(uuid, jsonb) from public, anon;
grant execute on function fn_staff_create_product_order(uuid, jsonb) to authenticated;

-- the delivery task type, made on first use in each branch
create or replace function fn_product_delivery_type(p_branch uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  select id into v from task_types where branch_id = p_branch and code = 'product_delivery';
  if v is null then
    insert into task_types(organization_id, branch_id, code, name, description)
    select organization_id, id, 'product_delivery', 'تسليم طلب منتجات', 'يُنشأ تلقائيًا بعد دفع الطلب' from branches where id = p_branch
    on conflict (branch_id, name) do update set code = 'product_delivery'
    returning id into v;
  end if;
  if v is null then raise exception 'TASK_TYPE_MISSING: product_delivery'; end if;
  return v;
end $$;
revoke all on function fn_product_delivery_type(uuid) from public, anon, authenticated;

-- payment, then the voucher, then the delivery task, in one step: the order's lines join the stay's account, a receipt
-- of the same amount pays them, and the delivery task is created. p: {order_id, method, reference?, account_id?,
-- idempotency_key, duplicate_reference_ok?}
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
  -- the lines join the stay's account (with their tax, as any charge)
  for l in select * from product_order_lines where order_id = o.id order by created_at, name loop
    cid := fn_add_charge(r.id, 'addon', l.name || ' × ' || l.quantity, l.quantity, l.unit_price_halalas, l.taxable, 'طلب ' || o.number);
    update reservation_charges set product_order_id = o.id where id = cid or base_charge_id = cid;
  end loop;
  select coalesce(sum(total_halalas), 0) into amt from reservation_charges where product_order_id = o.id;
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
  update product_orders set status = 'paid', total_halalas = amt, voucher_id = (v->>'voucher_id')::uuid, task_id = tid,
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

-- the reception cancels an order waiting for payment; the owner or the manager cancels a paid one that was not
-- delivered: its voucher is cancelled (the money is returned or was never taken), its charges are balanced back in
-- the stay's account, its delivery task is cancelled. A delivered order is not cancelled here.
create or replace function fn_staff_cancel_product_order(p_order uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o product_orders%rowtype; r reservations%rowtype; v financial_vouchers%rowtype; c record; cid uuid; v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  perform fn_require_cap('voucher.receipt');
  if v_reason is null or char_length(v_reason) > 300 then raise exception 'VALIDATION: reason'; end if;
  select * into o from product_orders where id = p_order and organization_id = fn_user_org_id();
  if not found then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(o.branch_id);
  select * into r from reservations where id = o.reservation_id for update;
  perform 1 from housekeeping_tasks where id = o.task_id for update;      -- the task before the order, as its completion takes them
  select * into o from product_orders where id = o.id for update;
  if o.status = 'delivered' then raise exception 'VALIDATION: order_delivered'; end if;
  if o.status = 'cancelled' then raise exception 'VALIDATION: order_status'; end if;
  if o.status = 'paid' then
    perform fn_require_cap('voucher.cancel');
    select * into v from financial_vouchers where id = o.voucher_id;
    -- a receipt of a day that is over (or of a settled card day) is not erased: that day's figures stay as they were
    if fn_branch_date(v.branch_id, v.occurred_at) < fn_branch_today(v.branch_id) or fn_voucher_settled(v.id) then
      raise exception 'VALIDATION: order_cancel_day';
    end if;
    -- lines already on an invoice are not reversed here
    if exists (select 1 from reservation_charges where product_order_id = o.id and invoice_id is not null) then
      raise exception 'VALIDATION: order_invoiced';
    end if;
    perform set_config('fivehours.order_cancel', o.id::text, true);
    perform fn_cancel_voucher(o.voucher_id, 'إلغاء الطلب ' || o.number || ': ' || v_reason);
    -- each of the order's rows gets its exact opposite, of the same kind (the line and its tax): the stay's account,
    -- its tax and its night-by-night dues are as if the order had not been
    for c in select * from reservation_charges where product_order_id = o.id and kind = 'addon' and total_halalas > 0 order by created_at, id loop
      insert into reservation_charges(organization_id, branch_id, reservation_id, kind, description, quantity, unit_price_halalas, total_halalas, taxable,
                                      reason, created_by, service_from, service_to, product_order_id)
      values (c.organization_id, c.branch_id, c.reservation_id, 'addon', 'إلغاء: ' || c.description, c.quantity, -c.unit_price_halalas, -c.total_halalas, c.taxable,
              'إلغاء الطلب ' || o.number, fn_staff_id(), c.service_from, c.service_to, o.id)
      returning id into cid;
      insert into reservation_charges(organization_id, branch_id, reservation_id, kind, description, quantity, unit_price_halalas, total_halalas, taxable,
                                      reason, created_by, service_from, service_to, base_charge_id, product_order_id)
      select t.organization_id, t.branch_id, t.reservation_id, 'tax', 'إلغاء: ' || t.description, t.quantity, -t.unit_price_halalas, -t.total_halalas, t.taxable,
             'إلغاء الطلب ' || o.number, fn_staff_id(), t.service_from, t.service_to, cid, o.id
        from reservation_charges t where t.base_charge_id = c.id and t.kind = 'tax';
    end loop;
    if (select coalesce(sum(total_halalas), 0) from reservation_charges where product_order_id = o.id) <> 0 then
      raise exception 'VALIDATION: order_status';
    end if;
    update housekeeping_tasks set status = 'cancelled', cancelled_at = now(), cancel_reason = 'أُلغي الطلب ' || o.number, version = version + 1, updated_at = now()
     where id = o.task_id and status in ('pending', 'in_progress');
    perform set_config('fivehours.order_cancel', '', true);
    perform fn_recompute_reservation_finance(r.id);
  end if;
  update product_orders set status = 'cancelled', cancelled_at = now(), cancelled_by = fn_staff_id(), cancel_reason = v_reason, version = version + 1, updated_at = now()
   where id = o.id;
  perform fn_audit_change(o.branch_id, 'product_order.cancelled', 'product_order', o.id, jsonb_build_object('status', o.status),
                          jsonb_build_object('status', 'cancelled', 'number', o.number, 'amount_halalas', o.total_halalas), v_reason);
  return fn_product_order_json(o.id);
end $$;
revoke all on function fn_staff_cancel_product_order(uuid, text) from public, anon;
grant execute on function fn_staff_cancel_product_order(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 6. The links held by the database: a receipt made for an order is marked as the order's; the order's voucher and
--    task are not cancelled or corrected on their own; the order is delivered when its task is done
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_trg_product_voucher() returns trigger
language plpgsql security definer set search_path = public as $$
declare oid text := nullif(current_setting('fivehours.product_order', true), '');
begin
  if tg_op = 'INSERT' then
    if new.reversal_of is not null and exists (select 1 from financial_vouchers where id = new.reversal_of and product_order_id is not null) then
      raise exception 'VALIDATION: order_voucher';
    end if;
    if oid is not null and new.kind = 'receipt' and new.product_order_id is null then new.product_order_id := oid::uuid; end if;
    return new;
  end if;
  if old.product_order_id is not null and new.status is distinct from old.status
     and coalesce(nullif(current_setting('fivehours.order_cancel', true), ''), '-') <> old.product_order_id::text then
    raise exception 'VALIDATION: order_voucher';
  end if;
  if new.product_order_id is distinct from old.product_order_id then raise exception 'VALIDATION: order_voucher'; end if;
  return new;
end $$;
revoke all on function fn_trg_product_voucher() from public, anon, authenticated;
create or replace trigger trg_product_voucher before insert or update on financial_vouchers for each row execute function fn_trg_product_voucher();

create or replace function fn_trg_product_task() returns trigger
language plpgsql security definer set search_path = public as $$
declare o product_orders%rowtype;
begin
  select * into o from product_orders where task_id = new.id;
  if not found or new.status is not distinct from old.status then return new; end if;
  if tg_when = 'BEFORE' then
    if new.status = 'cancelled' and o.status = 'paid'
       and coalesce(nullif(current_setting('fivehours.order_cancel', true), ''), '-') <> o.id::text then
      raise exception 'VALIDATION: order_task';
    end if;
    return new;
  end if;
  if new.status = 'completed' and o.status = 'paid' then
    update product_orders set status = 'delivered', delivered_at = now(), version = version + 1, updated_at = now() where id = o.id and status = 'paid';
    perform fn_audit_change(o.branch_id, 'product_order.delivered', 'product_order', o.id, jsonb_build_object('status', 'paid'),
                            jsonb_build_object('status', 'delivered', 'number', o.number, 'task', new.id));
  end if;
  return new;
end $$;
revoke all on function fn_trg_product_task() from public, anon, authenticated;
create or replace trigger trg_product_task_guard before update of status on housekeeping_tasks for each row execute function fn_trg_product_task();
create or replace trigger trg_product_task_done after update of status on housekeeping_tasks for each row execute function fn_trg_product_task();

-- the stay moves or ends: a paid order's delivery follows the guest to the new room; at the departure an order still
-- waiting for its payment is cancelled, and a paid one not delivered says on its task that the guest has left
create or replace function fn_trg_product_stay() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.room_id is distinct from old.room_id and new.room_id is not null then
    update housekeeping_tasks set room_id = new.room_id, updated_at = now()
     where status in ('pending', 'in_progress') and id in (select task_id from product_orders where reservation_id = new.id and status = 'paid');
  end if;
  if new.status is distinct from old.status and new.status::text in ('checked_out', 'closed') and old.status::text = 'checked_in' then
    update product_orders set status = 'cancelled', cancelled_at = now(), cancel_reason = 'غادر النزيل قبل الدفع', version = version + 1, updated_at = now()
     where reservation_id = new.id and status = 'pending_payment';
    update housekeeping_tasks set description = 'غادر النزيل — راجع الاستقبال قبل التسليم. ' || description, updated_at = now()
     where status in ('pending', 'in_progress') and description not like 'غادر النزيل%'
       and id in (select task_id from product_orders where reservation_id = new.id and status = 'paid');
  end if;
  return new;
end $$;
revoke all on function fn_trg_product_stay() from public, anon, authenticated;
create or replace trigger trg_product_stay after update of room_id, status on reservations for each row execute function fn_trg_product_stay();

-- ---------------------------------------------------------------------------------------------------------------
-- 7. The books: a receipt for a product order is product revenue (43); everything else as in 0065
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_gl_post_voucher(p_id uuid, p_posting text default 'post') returns void
language plpgsql security definer set search_path = public as $$
declare v financial_vouchers%rowtype; v_org uuid; money uuid; src uuid; d date; label text; income uuid;
begin
  select * into v from financial_vouchers where id = p_id;
  v_org := v.organization_id;
  select source_id into src from reservations where id = v.reservation_id;
  money := case when v.account_id is not null then fn_gl_for_cash(v.account_id)
                when v.method::text in ('ota_deferred', 'booking_platform') then fn_gl_for_source(v_org, src)
                else fn_gl_system(v_org, 'suspense') end;
  income := case when v.product_order_id is not null then fn_gl_system(v_org, 'product_revenue') else fn_gl_system(v_org, 'rent_revenue') end;
  d := fn_branch_date(v.branch_id, v.occurred_at);
  label := v.number || ' — ' || case v.kind when 'receipt' then case when v.product_order_id is not null then 'قبض طلب منتجات' else 'قبض إيجار' end
                                            when 'refund' then 'رد مبلغ' when 'deposit' then 'قبض تأمين'
                                            when 'deposit_refund' then 'رد تأمين' else 'خصم من التأمين' end;
  perform fn_gl_post(v_org, v.branch_id, d, 'voucher', v.id, p_posting, label, case v.kind
    when 'receipt' then jsonb_build_array(jsonb_build_object('account_id', money, 'debit', v.amount_halalas),
                                          jsonb_build_object('account_id', income, 'credit', v.amount_halalas))
    when 'refund' then jsonb_build_array(jsonb_build_object('account_id', fn_gl_system(v_org, 'rent_returns'), 'debit', v.amount_halalas),
                                         jsonb_build_object('account_id', money, 'credit', v.amount_halalas))
    when 'deposit' then jsonb_build_array(jsonb_build_object('account_id', money, 'debit', v.amount_halalas),
                                          jsonb_build_object('account_id', fn_gl_system(v_org, 'deposits'), 'credit', v.amount_halalas))
    when 'deposit_refund' then jsonb_build_array(jsonb_build_object('account_id', fn_gl_system(v_org, 'deposits'), 'debit', v.amount_halalas),
                                                 jsonb_build_object('account_id', money, 'credit', v.amount_halalas))
    else jsonb_build_array(jsonb_build_object('account_id', fn_gl_system(v_org, 'deposits'), 'debit', v.amount_halalas),
                           jsonb_build_object('account_id', fn_gl_system(v_org, 'rent_revenue'), 'credit', v.amount_halalas)) end);
end $$;
revoke all on function fn_gl_post_voucher(uuid, text) from public, anon, authenticated;
