-- 0150: the by-staff lines of three reports carry the staff id and group by it, so two people with the same display name stay two lines.
-- Additive: every existing key keeps its name and meaning; `staff_id` is a new key (null when the row has no staff). Same signatures, grants and guards (CREATE OR REPLACE).
-- Reproduced on PG16 (rolled back): two same-name staff were merged into one line in the discounts report; late entries and identities group by name by definition.

CREATE OR REPLACE FUNCTION public.fn_reports_discounts(p_branch uuid, p_from date, p_to date, p_filters jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare tz text; full_view boolean; res jsonb; f jsonb := coalesce(p_filters, '{}'::jsonb); v_staff uuid; v_source uuid; v_cat uuid; v_after boolean;
begin
  perform fn_require_cap('reports.finance');
  perform fn_require_branch(p_branch);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then raise exception 'VALIDATION: range'; end if;
  select timezone into tz from branches where id = p_branch;
  full_view := fn_cap_full('reports.finance');
  v_staff := (f->>'staff_id')::uuid; v_source := (f->>'source_id')::uuid; v_cat := (f->>'category_id')::uuid; v_after := (f->>'after_arrival')::boolean;
  with d as (
    select ch.id, r.id as reservation_id, r.internal_ref, ch.description, ch.reason, round(abs(ch.quantity * ch.unit_price_halalas))::bigint as amount,
           ch.created_at, ch.created_by, sp.full_name as staff_name, sp.role::text as staff_role,
           (r.actual_check_in is not null and ch.created_at >= r.actual_check_in) as after_arrival
    from reservation_charges ch
    join reservations r on r.id = ch.reservation_id
    left join staff_profiles sp on sp.id = ch.created_by
    where ch.branch_id = p_branch and ch.kind = 'discount' and (ch.created_at at time zone tz)::date between p_from and p_to
      and (v_staff is null or ch.created_by = v_staff) and (v_source is null or r.source_id = v_source) and (v_cat is null or r.room_category_id = v_cat)
      and (v_after is null or (r.actual_check_in is not null and ch.created_at >= r.actual_check_in) = v_after)
  )
  select jsonb_build_object('period', jsonb_build_object('from', p_from, 'to', p_to),
    'filters', jsonb_strip_nulls(jsonb_build_object('staff_id', v_staff, 'source_id', v_source, 'category_id', v_cat, 'after_arrival', v_after)),
    'total_halalas', coalesce(sum(amount), 0), 'count', count(*),
    'by_staff', coalesce((select jsonb_agg(jsonb_build_object('staff_id', s.created_by, 'staff', s.staff_name, 'role', s.staff_role, 'count', s.n, 'total_halalas', s.total) order by s.total desc)
                          from (select created_by, staff_name, staff_role, count(*) as n, sum(amount) as total from d group by created_by, staff_name, staff_role) s), '[]'::jsonb),
    'rows', case when full_view then coalesce((select jsonb_agg(jsonb_build_object('staff_id', d2.created_by, 'id', d2.id, 'reservation_id', d2.reservation_id, 'internal_ref', d2.internal_ref,
              'amount_halalas', d2.amount, 'reason', coalesce(d2.reason, d2.description), 'staff', d2.staff_name, 'role', d2.staff_role,
              'created_at', d2.created_at, 'after_arrival', d2.after_arrival) order by d2.created_at desc) from d d2), '[]'::jsonb) end)
  into res from d;
  return res;
end $function$;

CREATE OR REPLACE FUNCTION public.fn_reports_late_entries__impl(p_branch uuid, p_from date, p_to date, p_min_days integer, p_filters jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare tz text; f jsonb := coalesce(p_filters, '{}'::jsonb); v_staff uuid; v_source uuid;
begin
  perform fn_require_role_ind('owner', 'manager');
  perform fn_require_branch(p_branch);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then raise exception 'VALIDATION: period'; end if;
  select coalesce(timezone, 'Asia/Riyadh') into tz from branches where id = p_branch;
  v_staff := (f->>'staff_id')::uuid; v_source := (f->>'source_id')::uuid;
  return (with x as (
    select r.id, r.internal_ref, r.external_ref, s.name as source_name, r.platform_booked_on, (r.created_at at time zone tz)::date as entered_on,
           r.created_at, r.check_in, r.status, (select full_name from staff_profiles where id = r.created_by) as created_by, r.created_by as created_by_id
    from reservations r join booking_sources s on s.id = r.source_id and s.kind = 'external'
    where r.branch_id = p_branch and r.platform_booked_on is not null and (r.created_at at time zone tz)::date between p_from and p_to
      and (v_staff is null or r.created_by = v_staff) and (v_source is null or r.source_id = v_source)
  ), late as (select *, entered_on - platform_booked_on as lag_days from x where entered_on - platform_booked_on >= greatest(coalesce(p_min_days, 1), 0))
  select jsonb_build_object(
    'filters', jsonb_strip_nulls(jsonb_build_object('staff_id', v_staff, 'source_id', v_source)),
    'platform_bookings', (select count(*) from x), 'late', (select count(*) from late),
    'after_arrival', (select count(*) from late where entered_on > check_in),
    'by_staff', coalesce((select jsonb_agg(jsonb_build_object('staff_id', created_by_id, 'staff', coalesce(created_by, '—'), 'count', c, 'max_lag', m) order by c desc)
                          from (select created_by_id, created_by, count(*) c, max(lag_days) m from late group by created_by_id, created_by) z), '[]'::jsonb),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'internal_ref', internal_ref, 'external_ref', external_ref, 'source_name', source_name,
                                                         'booked_on', platform_booked_on, 'entered_on', entered_on, 'entered_at', created_at, 'lag_days', lag_days,
                                                         'check_in', check_in, 'after_arrival', entered_on > check_in, 'status', status, 'created_by', created_by, 'created_by_id', created_by_id)
                                      order by lag_days desc, created_at) from late), '[]'::jsonb)));
end $function$;

CREATE OR REPLACE FUNCTION public.fn_reports_identities(p_branch uuid, p_from date, p_to date, p_path text, p_filters jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare tz text; f jsonb := coalesce(p_filters, '{}'::jsonb); v_staff uuid;
begin
  perform fn_require_cap('reports.identities_usage');
  perform fn_require_branch(p_branch);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then raise exception 'VALIDATION: period'; end if;
  if coalesce(p_path, 'office') not in ('office', 'guest', 'all') then raise exception 'VALIDATION: path'; end if;
  select coalesce(timezone, 'Asia/Riyadh') into tz from branches where id = p_branch;
  v_staff := (f->>'staff_id')::uuid;
  return (with x as (
    select g.id, r.id as reservation_id, r.internal_ref, g.full_name, g.is_primary, g.identity_type, g.identity_number_last4, g.entry_path,
           g.entered_at, g.verified_at, (select full_name from staff_profiles where id = g.entered_by) as entered_by,
           (select full_name from staff_profiles where id = g.verified_by) as verified_by, g.verified_by as verified_by_id
    from reservation_guests g join reservations r on r.id = g.reservation_id
    where r.branch_id = p_branch and g.verification_status = 'verified' and g.verified_at is not null
      and (g.verified_at at time zone tz)::date between p_from and p_to
      and (coalesce(p_path, 'office') = 'all' or g.entry_path = coalesce(p_path, 'office'))
      and (v_staff is null or g.verified_by = v_staff)
  )
  select jsonb_build_object(
    'filters', jsonb_strip_nulls(jsonb_build_object('staff_id', v_staff, 'path', coalesce(p_path, 'office'))),
    'count', (select count(*) from x),
    'by_staff', coalesce((select jsonb_agg(jsonb_build_object('staff_id', verified_by_id, 'staff', coalesce(verified_by, '—'), 'office', o, 'guest', gu) order by o + gu desc)
                          from (select verified_by_id, verified_by, count(*) filter (where entry_path = 'office') o, count(*) filter (where entry_path is distinct from 'office') gu
                                  from x group by verified_by_id, verified_by) z), '[]'::jsonb),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('guest_id', id, 'reservation_id', reservation_id, 'internal_ref', internal_ref, 'full_name', full_name,
                                                         'is_primary', is_primary, 'identity_type', identity_type, 'identity_last4', identity_number_last4,
                                                         'entry_path', entry_path, 'entered_by', entered_by, 'entered_at', entered_at,
                                                         'verified_by', verified_by, 'verified_at', verified_at) order by verified_at desc) from x), '[]'::jsonb)));
end $function$;
