-- 0154: a WARNING (never a block) before saving a booking that looks like a repeat of an existing one: same branch, same dates,
-- same unit type, and the same guest by phone or by name (the same person), whatever the platform number. Two different
-- guests booking the same type on the same dates are normal and are not reported. Read only; it returns the internal
-- reference and which of phone/name matched, never the other guest's name or phone.
CREATE OR REPLACE FUNCTION public.fn_staff_similar_bookings(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_branch uuid := nullif(p->>'branch_id', '')::uuid; v_cat uuid := nullif(p->>'category_id', '')::uuid;
        ci date := nullif(p->>'check_in', '')::date; co date := nullif(p->>'check_out', '')::date;
        v_np text := fn_normalize_phone(nullif(trim(coalesce(p->>'guest_phone', '')), '')); v_nk text := fn_person_name_key(p->>'guest_name'); items jsonb;
begin
  perform fn_require_cap('res.create');
  perform fn_require_branch(v_branch);
  if ci is null or co is null or v_cat is null then return jsonb_build_object('count', 0, 'items', '[]'::jsonb); end if;
  select coalesce(jsonb_agg(x order by x->>'check_in'), '[]'::jsonb) into items from (
    select jsonb_build_object('internal_ref', r.internal_ref, 'status', r.status, 'check_in', r.check_in, 'check_out', r.check_out,
             'same_phone', v_np is not null and fn_normalize_phone(g.phone) = v_np, 'same_name', v_nk is not null and fn_person_name_key(g.full_name) = v_nk) as x
      from reservations r join reservation_guests g on g.reservation_id = r.id and g.is_primary
     where r.organization_id = fn_user_org_id() and r.branch_id = v_branch and r.room_category_id = v_cat
       and r.check_in = ci and r.check_out = co and r.status not in ('draft', 'cancelled', 'rejected')
       and ((v_np is not null and fn_normalize_phone(g.phone) = v_np) or (v_nk is not null and fn_person_name_key(g.full_name) = v_nk))
     limit 5) s;
  return jsonb_build_object('count', jsonb_array_length(items), 'items', items);
end $function$;
REVOKE ALL ON FUNCTION public.fn_staff_similar_bookings(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_staff_similar_bookings(jsonb) TO authenticated;
