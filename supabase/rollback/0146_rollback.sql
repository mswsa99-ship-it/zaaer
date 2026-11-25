-- restores exactly what 0146 removed (authenticated only) and the 0145 definition of fn_branch_iban
grant select (payment_status) on public.reservations to authenticated;
grant select (identity_issue_number) on public.reservation_guests to authenticated;
create or replace function public.fn_branch_iban(p_branch uuid)
returns text language sql stable security definer set search_path = public as $$
  select b.bank_iban from branches b
  where b.id = p_branch and b.organization_id = fn_user_org_id()
    and b.id in (select fn_user_branch_ids())
    and fn_has_role('owner','manager')
    and fn_page_read_gate(array['/admin/cash-accounts']);
$$;
