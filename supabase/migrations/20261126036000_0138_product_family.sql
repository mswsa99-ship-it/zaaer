-- UNADOPTED, UNRUN local candidate (product family). Basis: page /admin/products is its own route; per-page add/edit per user item 3 and 4 (reply 2026-11-25 06:19:08 to the 06:14:40 list); comment is provenance only.
-- Individual non-owner accounts: create = /admin/products add, update = edit, branch availability = edit. Legacy accounts and the owner keep cap 'definitions'.
-- Role/branch rules inside the bodies (fn_require_branch, product_other_branch) are unchanged.
create or replace function public.fn_require_product_page(p_action text) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if p_action not in ('add','edit') then raise exception 'FORBIDDEN: definitions' using errcode='42501'; end if;
  if fn_staff_id() is not null and fn_current_role() <> 'owner' and fn_user_access_mode() = 'individual' then
    perform fn_require_user_page('/admin/products', p_action);
  else
    perform fn_require_cap('definitions');
  end if;
end $$;
revoke all on function public.fn_require_product_page(text) from public, anon;
grant execute on function public.fn_require_product_page(text) to authenticated;
-- UNADOPTED local candidate. Internal, no execute for API roles. Core of fn_admin_set_product_branch after its gate.
create or replace function public.fn_product_branch_apply(p_product uuid, p_branch uuid, p_available boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare x products%rowtype; b branches%rowtype; was boolean;
begin
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
revoke all on function public.fn_product_branch_apply(uuid, uuid, boolean) from public, anon, authenticated;
create or replace function fn_admin_set_product_branch(p_product uuid, p_branch uuid, p_available boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public.fn_require_product_page('edit');
  return public.fn_product_branch_apply(p_product, p_branch, p_available);
end $$;
create or replace function fn_admin_upsert_product_category(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c product_categories%rowtype; v_name text := btrim(coalesce(p->>'name', '')); before jsonb;
begin
  perform public.fn_require_product_page(case when nullif(p->>'id','') is null then 'add' else 'edit' end);
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
create or replace function fn_admin_upsert_product(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare x products%rowtype; v_name text := btrim(coalesce(p->>'name', '')); v_desc text := nullif(btrim(coalesce(p->>'description', '')), '');
        v_price bigint; v_cat uuid; before jsonb;
begin
  perform public.fn_require_product_page(case when nullif(p->>'id','') is null then 'add' else 'edit' end);
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
    -- option A (UNADOPTED): the branches the new product is sold in travel with its creation, in the same transaction (create = add)
    if p ? 'branches' then
      if jsonb_typeof(p->'branches') <> 'array' then raise exception 'VALIDATION: product_branch'; end if;
      perform public.fn_product_branch_apply(x.id, (b.value #>> '{}')::uuid, true) from jsonb_array_elements(p->'branches') b(value);
    end if;
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
