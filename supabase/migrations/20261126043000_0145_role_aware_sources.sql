-- 0145: role-aware read sources, ADDITIVE ONLY (no grant is changed here; nothing is widened).
-- They let the app stop reading four things straight from tables, so a later migration (0146) can revoke the direct
-- column reads. The app ships first; the revoke comes after the new code is live.
--   fn_reservation_cards   the operational reservation cards, with payment_status only for roles that see money
--   fn_branch_iban         the branch IBAN, for the roles that hold the cash-accounts page, in their own branches
--   fn_my_profile          the signed-in person's own staff row
--   fn_staff_directory     id, full name and role of staff (no email, no phone)
-- Every function re-applies the same conditions the table policies apply today (organisation, own branches, page gate).

create or replace function public.fn_reservation_cards(p_branch uuid, p_status text[] default null, p_today_only boolean default false)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_out jsonb;
begin
  if not (p_branch in (select fn_user_branch_ids())) then return '[]'::jsonb; end if;
  if not fn_page_read_gate(array['/admin/dashboard','/admin/reports','/staff/reservations/:id','/staff/arrivals','/staff/identity-verification','/staff/payments','/staff/access-approvals','/staff/dashboard','/staff/rooms','/staff/orders']) then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', r.id, 'internal_ref', r.internal_ref, 'external_ref', r.external_ref, 'status', r.status,
      'check_in', r.check_in, 'check_out', r.check_out, 'adults', r.adults, 'companions', r.companions,
      'payment_status', case when fn_sees_money() then r.payment_status end,
      'identity_status', r.identity_status, 'government_registration', r.government_registration,
      'shomoos_accepted_at', r.shomoos_accepted_at, 'access_status', r.access_status, 'keybox_delivered', r.keybox_delivered,
      'actual_check_in', r.actual_check_in, 'updated_at', r.updated_at,
      'source', case when s.id is null then null else jsonb_build_object('name', s.name) end,
      'room', case when rm.id is null then null else jsonb_build_object('room_number', rm.room_number) end,
      'room_category', case when c.id is null then null else jsonb_build_object('name_ar', c.name_ar) end,
      'branch', jsonb_build_object('name_ar', b.name_ar)
    ) order by r.created_at desc), '[]'::jsonb) into v_out
  from reservations r
  join branches b on b.id = r.branch_id
  left join booking_sources s on s.id = r.source_id
  left join rooms rm on rm.id = r.room_id
  left join room_categories c on c.id = r.room_category_id
  where r.branch_id = p_branch and r.organization_id = fn_user_org_id()
    and (p_status is null or cardinality(p_status) = 0 or r.status::text = any(p_status))
    and (not p_today_only or r.check_in = (now() at time zone coalesce(b.timezone, 'Asia/Riyadh'))::date);
  return v_out;
end $$;

create or replace function public.fn_branch_iban(p_branch uuid)
returns text language sql stable security definer set search_path = public as $$
  select b.bank_iban from branches b
  where b.id = p_branch and b.organization_id = fn_user_org_id()
    and b.id in (select fn_user_branch_ids())
    and fn_has_role('owner','manager')
    and fn_page_read_gate(array['/admin/cash-accounts']);
$$;

create or replace function public.fn_my_profile()
returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(p) from (select id, auth_user_id, organization_id, full_name, email, phone, role, is_active
                           from staff_profiles where auth_user_id = auth.uid()) p;
$$;

create or replace function public.fn_staff_directory()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'full_name', s.full_name, 'role', s.role) order by s.full_name), '[]'::jsonb)
  from staff_profiles s
  where s.organization_id = fn_user_org_id() and s.is_active
    and fn_page_read_gate(array['/staff/housekeeping']);
$$;

revoke all on function public.fn_reservation_cards(uuid, text[], boolean), public.fn_branch_iban(uuid), public.fn_my_profile(), public.fn_staff_directory() from public, anon;
grant execute on function public.fn_reservation_cards(uuid, text[], boolean), public.fn_branch_iban(uuid), public.fn_my_profile(), public.fn_staff_directory() to authenticated;
