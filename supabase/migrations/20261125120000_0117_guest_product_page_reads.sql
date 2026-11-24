-- Source-backed direct-read individual page gates; definer guest RPC paths unchanged.
begin;
drop policy staff_guests_select on public.guest_profiles;
create policy staff_guests_select on public.guest_profiles for select to authenticated
  using (organization_id = (select fn_user_org_id()) and fn_has_role(variadic array['owner'::role_code,'manager'::role_code,'supervisor'::role_code])
         and (select fn_page_read_gate(array['/admin/guests','/admin/guests/:id'])));
drop policy products_read on public.products;
create policy products_read on public.products for select to authenticated
  using (organization_id = (select fn_user_org_id()) and (select fn_page_read_gate(array['/admin/products'])));
drop policy product_categories_read on public.product_categories;
create policy product_categories_read on public.product_categories for select to authenticated
  using (organization_id = (select fn_user_org_id()) and (select fn_page_read_gate(array['/admin/products'])));
commit;
