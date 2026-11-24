-- =====================================================================
-- 0084 (plan item 7.2, O5 «الفرع المؤرشف»): the products branch list is a selection list, so an archived branch
-- never appears in it («لا يظهر فرع مؤرشف في أي قائمة اختيار، ومنها المنتجات»). The list is the only change: the
-- management screen reads the table directly and still finds the archived row, and restoring a branch returns it
-- to the list. Proposed by worker N3; NOT applied anywhere — the integrator rehearses it.
-- =====================================================================

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
                          from branches b where b.organization_id = fn_user_org_id() and b.archived_at is null), '[]'::jsonb));
end $$;
revoke all on function fn_admin_products() from public, anon;
grant execute on function fn_admin_products() to authenticated;
