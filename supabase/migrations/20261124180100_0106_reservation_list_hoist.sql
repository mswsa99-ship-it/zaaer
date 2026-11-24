-- 0106 — fn_reservation_list at the 2.10 volume (item «الأداء بحجم كبير»: the main functions under 500 ms p95).
-- Ownership: this migration owns only the fn_reservation_list body; migration 0040 is not edited.
--
-- The body is byte-for-byte the 0040 logic with one mechanical change: the uncorrelated, per-row-re-evaluated
-- STABLE calls are evaluated once per statement instead — the branch set goes into a materialized CTE, and
-- fn_sees_money()/fn_has_role() into uncorrelated scalar subqueries. Same columns, same filters, same ordering,
-- same role/branch permission semantics (fn_user_branch_ids / fn_sees_money / fn_has_role still decide; they are
-- STABLE, so one evaluation per statement returns what per-row evaluation returned per row). Evidence in
-- acceptance/load-report.md: ~1,007 ms → ~36 ms on a 2,074-booking branch; byte-identical results to the 0040
-- body across roles, filters and pagination (tests/load/40-list-capture.sql before/after diff), cross-hotel
-- calls stay FORBIDDEN.

create or replace function public.fn_reservation_list(p_branch uuid, p_filters jsonb DEFAULT '{}'::jsonb, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  with ub as materialized (select fn_user_branch_ids() b), f as (select coalesce(p_filters, '{}'::jsonb) j, coalesce((select timezone from branches where id = p_branch), 'Asia/Riyadh') tz),
  base as (
    select r.*, (select full_name from reservation_guests g where g.reservation_id = r.id and g.is_primary limit 1) as guest_name,
           (select room_number from rooms where id = r.room_id) as room_number, (select name from booking_sources where id = r.source_id) as source_name,
           (select name_ar from room_categories where id = r.room_category_id) as category_name,
           (select full_name from staff_profiles where id = r.created_by) as created_by_name,
           (select fn_sees_money()) as money
    from reservations r, f
    where r.branch_id = p_branch and r.branch_id in (select b from ub)
      and (coalesce(f.j->>'status','') = '' or r.status::text = any(string_to_array(f.j->>'status', ',')))
      and (coalesce(f.j->>'open_only','false') <> 'true' or r.status in ('pending_verification','confirmed','checked_in'))
      and (f.j->>'check_in_from' is null or r.check_in >= (f.j->>'check_in_from')::date)
      and (f.j->>'check_in_to' is null or r.check_in <= (f.j->>'check_in_to')::date)
      and (f.j->>'check_out_from' is null or r.check_out >= (f.j->>'check_out_from')::date)
      and (f.j->>'check_out_to' is null or r.check_out <= (f.j->>'check_out_to')::date)
      and (f.j->>'created_from' is null or (r.created_at at time zone f.tz)::date >= (f.j->>'created_from')::date)
      and (f.j->>'created_to' is null or (r.created_at at time zone f.tz)::date <= (f.j->>'created_to')::date)
      -- FRONT-09: «مقيم في يوم» is a stay that was or is in the unit that day — never a cancelled, rejected or no-show
      -- booking; a guest past their departure who has not left is still in house today
      and (f.j->>'stay_on' is null or (r.status not in ('cancelled', 'rejected', 'no_show', 'draft') and r.check_in <= (f.j->>'stay_on')::date
           and (r.check_out > (f.j->>'stay_on')::date or (r.status = 'checked_in' and (f.j->>'stay_on')::date <= fn_branch_today(p_branch)))))
      and (f.j->>'source_id' is null or r.source_id = (f.j->>'source_id')::uuid)
      and (f.j->>'category_id' is null or r.room_category_id = (f.j->>'category_id')::uuid)
      and (f.j->>'room_id' is null or r.room_id = (f.j->>'room_id')::uuid)
      and (coalesce(f.j->>'room_number','') = '' or exists (select 1 from rooms rm where rm.id = r.room_id and rm.room_number = f.j->>'room_number'))
      and (coalesce(f.j->>'booking_type','') = '' or r.booking_type = f.j->>'booking_type')
      and (coalesce(f.j->>'company','') = '' or coalesce(r.company_name,'') ilike '%' || (f.j->>'company') || '%')
      and (coalesce(f.j->>'price_basis','') = '' or r.price_basis = f.j->>'price_basis')
      and (coalesce(f.j->>'payment_status','') = '' or r.payment_status::text = f.j->>'payment_status')
      and (coalesce(f.j->>'identity_status','') = '' or r.identity_status::text = f.j->>'identity_status')
      and (coalesce(f.j->>'access_status','') = '' or r.access_status::text = f.j->>'access_status')
      and (coalesce(f.j->>'group_ref','') = '' or r.group_ref = f.j->>'group_ref')
      and (coalesce(f.j->>'has_discount','false') <> 'true' or r.discount_halalas > 0)
      and (coalesce(f.j->>'platform_collects','') = '' or r.platform_collects = (f.j->>'platform_collects')::boolean)
      and (coalesce(f.j->>'has_balance','false') <> 'true' or ((select fn_sees_money()) and r.balance_due_halalas > 0 and r.status not in ('cancelled', 'rejected', 'no_show')))
      and (coalesce(f.j->>'q','') = '' or r.internal_ref ilike '%' || (f.j->>'q') || '%' or coalesce(r.external_ref,'') ilike '%' || (f.j->>'q') || '%'
           or coalesce(r.cancel_reference,'') ilike '%' || (f.j->>'q') || '%' or coalesce(r.company_name,'') ilike '%' || (f.j->>'q') || '%'
           or exists (select 1 from reservation_guests g where g.reservation_id = r.id and (g.full_name ilike '%' || (f.j->>'q') || '%' or g.phone like '%' || (f.j->>'q') || '%')))
  ),
  ordered as (
    select b.*, row_number() over (order by
      case when (select j->>'sort' from f) = 'check_in_asc' then b.check_in end asc,
      case when (select j->>'sort' from f) = 'check_out' then b.check_out end desc,
      case when (select j->>'sort' from f) = 'created' then b.created_at end desc,
      case when (select j->>'sort' from f) = 'ref' then b.internal_ref end asc,
      b.check_in desc, b.created_at desc) as rn
    from base b)
  select jsonb_build_object(
    'total', (select count(*) from base),
    'rows', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'internal_ref', internal_ref, 'external_ref', external_ref, 'status', status, 'check_in', check_in, 'check_out', check_out,
               'nights', check_out - check_in, 'guest_name', guest_name, 'room_number', room_number, 'source_name', source_name, 'category_name', category_name,
               'booking_type', booking_type, 'company_name', company_name, 'price_basis', price_basis, 'adults', adults, 'companions', companions,
               'platform_booked_on', platform_booked_on, 'platform_collects', platform_collects, 'created_by_name', created_by_name,
               'actual_check_in', actual_check_in, 'actual_check_out', actual_check_out, 'cancelled_at', cancelled_at, 'cancel_reference', cancel_reference,
               'total_halalas', case when money then total_halalas end, 'paid_halalas', case when money then paid_halalas end,
               'discount_halalas', case when money then discount_halalas end, 'nightly_rate_halalas', case when money then nightly_rate_halalas end,
               'balance_due_halalas', case when money then (case when status in ('cancelled', 'rejected', 'no_show') then 0 else balance_due_halalas end) end, 'deposit_balance_halalas', case when money then deposit_balance_halalas end,
               'payment_status', payment_status, 'identity_status', identity_status, 'access_status', access_status, 'created_at', created_at,
               'group_ref', group_ref, 'hold', coalesce(security_hold, false),
               'ban', case when (select fn_sees_money()) then jsonb_array_length(fn_reservation_ban_matches(id)) > 0 end,
               'rating', case when (select fn_has_role('owner','manager','supervisor')) then (select gp.rating from reservation_guests g join guest_profiles gp on gp.id = g.guest_profile_id
                                                                                     where g.reservation_id = b.id and g.is_primary limit 1) end) order by rn), '[]'::jsonb)
             from (select * from ordered where rn > coalesce(p_offset, 0) and rn <= coalesce(p_offset, 0) + least(greatest(coalesce(p_limit, 50), 1), 1000)) b));
$function$;
