-- 0146: narrow grants only. Nothing is widened and no data is touched.
-- Applies only after the code that reads these values through role-aware sources is live (0145 + the matching web build).
--  1. reservations.payment_status and reservation_guests.identity_issue_number are no longer selectable straight from the
--     tables. The app reads the payment status through fn_reservation_cards / fn_reservation_detail (masked unless the role
--     sees money); the issue number is only written (enterGuest) and never read back by the app.
--  Not here: branches.bank_iban and staff_profiles.email/phone. Both tables carry a table-level select grant, so closing a
--  column needs the table grant withdrawn and re-granted by column; that breaks direct reads in older tests and is held for a
--  call-site and test review (next cycle).
-- fn_branch_iban follows the SAME rule as the cash_accounts table policy (0113): own organisation and branches, a role that
-- sees money, and the cash-accounts page. 0145 had narrowed it to owner/manager, which left the finance role without the
-- IBAN it can read today; that extra role limit is removed (no new role policy).
-- NOT in this migration (policy questions held for the user): who may read other branches' staff names, reservation
-- reasons visible to housekeeping, route access of every staff role to the reservation pages.
-- Rollback: supabase/rollback/0146_rollback.sql.

create or replace function public.fn_branch_iban(p_branch uuid)
returns text language sql stable security definer set search_path = public as $$
  select b.bank_iban from branches b
  where b.id = p_branch and b.organization_id = fn_user_org_id()
    and b.id in (select fn_user_branch_ids())
    and fn_sees_money()
    and fn_page_read_gate(array['/admin/cash-accounts']);
$$;

-- reservations and reservation_guests already carry column-level grants (0009 column gate): a column revoke works.
revoke select (payment_status) on public.reservations from authenticated;
revoke select (identity_issue_number) on public.reservation_guests from authenticated;
