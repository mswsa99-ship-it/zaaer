-- 0072 — the trial data stays in the system until the owner erases it (the owner's instruction of 15 November):
--   · the example catalogue of products (3 categories, 12 items, as in the demo) is added where the organisation has
--     no product yet, marked as trial data and offered in every branch, so the journey can be tried at once; the
--     owner's own list replaces it («استيراد قائمة» or one by one), and a trial item the owner edits becomes theirs;
--   · the guests imported from Zaaer are marked as such: they are the hotel's real guests, never trial data, and
--     «مسح كل بيانات التجربة» keeps them (the erasing itself is the owner's paste, 0073).

-- ---------------------------------------------------------------------------------------------------------------
-- 1. Trial items of the catalogue
-- ---------------------------------------------------------------------------------------------------------------
alter table product_categories add column if not exists is_sample boolean not null default false;
alter table products add column if not exists is_sample boolean not null default false;

-- the example catalogue for an organisation that has no product yet: returns how many items it added
create or replace function fn_seed_sample_products(p_org uuid) returns int
language plpgsql security definer set search_path = public as $$
declare c uuid; cat record; it record; pid uuid; n int := 0;
begin
  if exists (select 1 from products where organization_id = p_org) then return 0; end if;
  for cat in select * from (values (1, 'مشروبات'), (2, 'وجبات خفيفة'), (3, 'مستلزمات شخصية')) v(k, name) loop
    insert into product_categories(organization_id, name, sort_order, is_sample) values (p_org, cat.name, cat.k * 10, true)
    on conflict do nothing returning id into c;
    if c is null then continue; end if;
    for it in select * from (values
        (1, 'ماء صغير', 200, null), (1, 'مشروب غازي', 400, null), (1, 'عصير برتقال', 600, 'علبة 250 مل'), (1, 'قهوة سريعة التحضير', 500, 'ظرفان مع كوب'),
        (2, 'رقائق البطاطس', 400, null), (2, 'بسكويت', 300, null), (2, 'شوكولاتة', 500, null), (2, 'نودلز سريعة التحضير', 700, 'كوب جاهز بالماء الحار'),
        (3, 'فرشاة ومعجون أسنان', 800, null), (3, 'شفرة حلاقة', 600, null), (3, 'شاحن جوال', 2500, 'منفذ USB-C'), (3, 'مناديل مبللة', 500, null)
      ) v(k, name, price, description) where v.k = cat.k loop
      insert into products(organization_id, category_id, name, description, price_halalas, sort_order, is_sample)
      values (p_org, c, it.name, it.description, it.price, (n + 1) * 10, true)
      on conflict do nothing returning id into pid;
      if pid is not null then
        n := n + 1;
        insert into product_branches(product_id, branch_id, organization_id, available)
        select pid, b.id, p_org, true from branches b where b.organization_id = p_org and b.is_active
        on conflict do nothing;
      end if;
    end loop;
  end loop;
  return n;
end $$;
revoke all on function fn_seed_sample_products(uuid) from public, anon, authenticated;
-- an organisation in use (its owner has an account) gets it now; a new one starts with its own list
select fn_seed_sample_products(o.id) from organizations o
 where exists (select 1 from staff_profiles sp where sp.organization_id = o.id and sp.role = 'owner' and sp.is_active and sp.auth_user_id is not null);

-- an item or a category the owner edits is theirs from then on (no longer trial data)
create or replace function fn_trg_product_not_sample() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.is_sample and new.is_sample and new.version > old.version then new.is_sample := false; end if;
  return new;
end $$;
revoke all on function fn_trg_product_not_sample() from public, anon, authenticated;
create or replace trigger trg_product_not_sample before update on products for each row execute function fn_trg_product_not_sample();
create or replace trigger trg_category_not_sample before update on product_categories for each row execute function fn_trg_product_not_sample();

-- the settings show which items are trial data
create or replace function fn_admin_products() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform fn_require_cap('definitions');
  return jsonb_build_object(
    'categories', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'sort_order', c.sort_order, 'is_active', c.is_active, 'version', c.version,
                                                                'is_sample', c.is_sample, 'products', (select count(*) from products x where x.category_id = c.id)) order by c.sort_order, c.name)
                            from product_categories c where c.organization_id = fn_user_org_id()), '[]'::jsonb),
    'products', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'category_id', x.category_id, 'name', x.name, 'description', x.description,
                                                              'price_halalas', x.price_halalas, 'taxable', x.taxable, 'is_active', x.is_active, 'sort_order', x.sort_order, 'version', x.version,
                                                              'is_sample', x.is_sample,
                                                              'branches', coalesce((select jsonb_agg(pb.branch_id order by pb.branch_id) from product_branches pb where pb.product_id = x.id and pb.available), '[]'::jsonb))
                                           order by x.sort_order, x.name)
                          from products x where x.organization_id = fn_user_org_id()), '[]'::jsonb),
    'branches', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name_ar, 'mine', b.id in (select fn_user_branch_ids())) order by b.name_ar)
                          from branches b where b.organization_id = fn_user_org_id()), '[]'::jsonb));
end $$;
revoke all on function fn_admin_products() from public, anon;
grant execute on function fn_admin_products() to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 2. The guests imported from Zaaer are the hotel's own
-- ---------------------------------------------------------------------------------------------------------------
alter table guest_profiles add column if not exists imported_at timestamptz;
-- The import of 30–31 October (STAGING.md, 2026-10-31): 2,452 profiles written in four batches between 22:00 and 22:08
-- UTC on 30 October, each with a note naming Zaaer. Either sign marks a profile as imported — its note («زائر», or
-- Zaaer), or its creation inside the import's window — so a note edited since never exposes it. Kept as a function: the
-- trial-data purge (0073) marks again before it takes any guest, and the checks try it on profiles of each kind.
create or replace function fn_mark_imported_guests(p_org uuid) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  update guest_profiles set imported_at = created_at
   where imported_at is null and (p_org is null or organization_id = p_org)
     and (notes like '%زائر%' or notes ilike '%zaaer%'
          or (created_at >= timestamptz '2026-10-30 21:55:00+00' and created_at < timestamptz '2026-10-30 22:15:00+00'));
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function fn_mark_imported_guests(uuid) from public, anon, authenticated;
select fn_mark_imported_guests(null);

-- ---------------------------------------------------------------------------------------------------------------
-- 3. What «مسح كل بيانات التجربة» would take, counted without taking anything (the page shows it before the owner
--    chooses; the erasing is the paste 0073 and the page's three steps)
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_admin_trial_overview() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_org uuid := fn_user_org_id();
begin
  perform fn_require_cap('security');
  return jsonb_build_object(
    'first_day', (select least(min(r.check_in), min((r.created_at at time zone 'Asia/Riyadh')::date)) from reservations r where r.organization_id = v_org),
    'reservations', (select count(*) from reservations where organization_id = v_org),
    'in_house_or_upcoming', (select count(*) from reservations where organization_id = v_org and status in ('checked_in', 'confirmed', 'pending_verification', 'draft')
                               and check_out >= fn_branch_today(branch_id)),
    'vouchers', (select count(*) from financial_vouchers where organization_id = v_org),
    'expenses', (select count(*) from expense_vouchers where organization_id = v_org),
    'journal_entries', (select count(*) from journal_entries where organization_id = v_org and source_type <> 'opening'),
    'bank_movements', (select count(*) from bank_movements where organization_id = v_org),
    'product_orders', (select count(*) from product_orders where organization_id = v_org),
    'sample_products', (select count(*) from products where organization_id = v_org and is_sample),
    'guests_trial', (select count(*) from guest_profiles where organization_id = v_org and imported_at is null),
    'guests_imported', (select count(*) from guest_profiles where organization_id = v_org and imported_at is not null),
    'paste_applied', exists (select 1 from pg_proc where proname = 'fn_purge_categories' and prosrc like '%samples%'));
end $$;
revoke all on function fn_admin_trial_overview() from public, anon;
grant execute on function fn_admin_trial_overview() to authenticated;
