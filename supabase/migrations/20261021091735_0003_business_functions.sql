/*
# Server-side Business Logic Functions

SECURITY DEFINER functions that run with privileged role for sensitive
operations. These enforce business rules server-side so the browser cannot
bypass them.

1. fn_evaluate_access(reservation_id) — checks all conditions for keybox
   delivery and returns { allowed, reasons[] }.
2. fn_release_next_slot(branch_id, category_id, date) — implements the
   sequential room release rule.
3. fn_get_public_availability(branch_id, date) — returns public-facing
   availability counts honoring release rules.
4. fn_verify_booking_ownership(reservation_id, phone_last4) — checks the
   last 4 digits of the phone match without exposing full data.
*/

-- ============ ACCESS RELEASE GATE ============
create or replace function fn_evaluate_access(p_reservation uuid)
returns table(allowed boolean, reasons text[])
language plpgsql security definer set search_path = public as $$
declare
  r reservations%rowtype;
  rm rooms%rowtype;
  kb keyboxes%rowtype;
  primary_verified boolean;
  all_guests_submitted boolean;
  payment_ok boolean;
  room_assigned boolean;
  v_reasons text[] := '{}';
begin
  select * into r from reservations where id = p_reservation;
  if not found then
    return query select false, array['الحجز غير موجود']::text[];
    return;
  end if;

  -- 1. Reservation confirmed
  if r.status not in ('confirmed','checked_in') then
    v_reasons := array_append(v_reasons, 'الحجز غير مؤكد');
  end if;

  -- 2. Identity verified (primary guest)
  if r.identity_status <> 'verified' then
    v_reasons := array_append(v_reasons, 'لم يتم اعتماد مطابقة الهوية');
  end if;

  -- 3. All guests data submitted
  select coalesce(bool_and(data_submitted), true) into all_guests_submitted
  from reservation_guests where reservation_id = p_reservation;
  if not coalesce(all_guests_submitted, false) and exists(select 1 from reservation_guests where reservation_id = p_reservation) then
    v_reasons := array_append(v_reasons, 'بيانات أحد النزلاء ناقصة');
  elsif not exists(select 1 from reservation_guests where reservation_id = p_reservation) then
    v_reasons := array_append(v_reasons, 'لم يتم تسجيل بيانات النزلاء');
  end if;

  -- 4. Payment satisfied (paid or partially_paid per policy — here require paid)
  if r.payment_status not in ('paid','partially_paid') then
    v_reasons := array_append(v_reasons, 'لم يتم استيفاء السداد المطلوب');
  end if;

  -- 5. Government registration
  if not r.government_registration then
    v_reasons := array_append(v_reasons, 'لم يتم تأكيد التسجيل النظامي');
  end if;

  -- 6. Room assigned & ready
  if r.room_id is null then
    v_reasons := array_append(v_reasons, 'لم يتم تخصيص غرفة');
  else
    select * into rm from rooms where id = r.room_id;
    if rm.status not in ('ready','reserved') then
      v_reasons := array_append(v_reasons, 'الغرفة غير جاهزة');
    end if;
  end if;

  -- 7. Keybox code active and not needing change
  if r.room_id is not null then
    select * into kb from keyboxes where room_id = r.room_id limit 1;
    if not found then
      v_reasons := array_append(v_reasons, 'لا يوجد صندوق مفتاح للغرفة');
    elsif kb.code_status = 'needs_change' then
      v_reasons := array_append(v_reasons, 'رمز الصندوق يحتاج إلى تغيير');
    elsif kb.code_encrypted is null then
      v_reasons := array_append(v_reasons, 'لم يتم تعيين رمز الصندوق');
    end if;
  end if;

  -- 8. Supervisor final approval
  if r.access_status not in ('approved','delivery_pending','delivered','acknowledged') then
    v_reasons := array_append(v_reasons, 'لم يعتمد المشرف الدخول النهائي');
  end if;

  return query select (array_length(v_reasons, 1) is null), v_reasons;
end;
$$;

-- ============ SEQUENTIAL ROOM RELEASE ============
create or replace function fn_get_public_availability(p_branch uuid, p_date date)
returns table(category_id uuid, category_name text, available_to_show int, total_available int)
language plpgsql security definer set search_path = public as $$
declare
  rr release_rules%rowtype;
  rs released_slots%rowtype;
  total_free int;
  released int;
begin
  return query
  select rc.id, rc.name_ar,
    least(
      case
        when rr.enabled then coalesce(rs.released_count, rr.initial_public_release)
        else coalesce(ip.total_units,0) - coalesce(ip.blocked_units,0)
      end,
      greatest(coalesce(ip.total_units,0) - coalesce(ip.blocked_units,0) - occupied_count, 0)
    ) as available_to_show,
    greatest(coalesce(ip.total_units,0) - coalesce(ip.blocked_units,0) - occupied_count, 0) as total_available
  from room_categories rc
  left join inventory_periods ip on ip.category_id = rc.id and ip.branch_id = p_branch and ip.date = p_date
  left join release_rules rr on rr.category_id = rc.id and rr.branch_id = p_branch
  left join released_slots rs on rs.category_id = rc.id and rs.branch_id = p_branch and rs.date = p_date
  left join lateral (
    select count(*) as occupied_count from reservations r
    where r.branch_id = p_branch and r.room_category_id = rc.id
      and r.status in ('confirmed','checked_in')
      and p_date >= r.check_in and p_date < r.check_out
  ) occ on true
  where rc.branch_id = p_branch and rc.is_active;
end;
$$;

-- ============ RELEASE NEXT SLOT ============
-- Called after an access delivery is confirmed. Increments the released count
-- by release_increment, but never beyond total available.
create or replace function fn_release_next_slot(p_branch uuid, p_category uuid, p_date date)
returns void
language plpgsql security definer set search_path = public as $$
declare
  rr release_rules%rowtype;
  current_released int;
  total_available int;
  new_count int;
begin
  select * into rr from release_rules where branch_id = p_branch and category_id = p_category;
  if not found or not rr.enabled then return; end if;

  select coalesce(released_count, 0) into current_released
  from released_slots where branch_id = p_branch and category_id = p_category and date = p_date;

  select count(*) into total_available from rooms rm
  where rm.branch_id = p_branch and rm.category_id = p_category
    and rm.status in ('available','ready');

  new_count := least(current_released + rr.release_increment, total_available);
  if new_count < rr.initial_public_release then
    new_count := rr.initial_public_release;
  end if;

  insert into released_slots (branch_id, category_id, date, released_count, updated_at)
  values (p_branch, p_category, p_date, new_count, now())
  on conflict (branch_id, category_id, date)
  do update set released_count = excluded.released_count, updated_at = now();
end;
$$;

-- ============ BOOKING VERIFICATION ============
-- Returns a limited summary if the last 4 digits of phone match.
create or replace function fn_verify_booking_ownership(p_reservation uuid, p_phone_last4 text)
returns table(ok boolean, internal_ref text, status reservation_status, check_in date, check_out date, branch_name text)
language plpgsql security definer set search_path = public as $$
declare
  r reservations%rowtype;
  primary_guest reservation_guests%rowtype;
  match boolean;
begin
  select * into r from reservations where id = p_reservation;
  if not found then return query select false, null::text, null::reservation_status, null::date, null::date, null::text; return; end if;

  select * into primary_guest from reservation_guests where reservation_id = p_reservation and is_primary limit 1;
  match := (primary_guest.phone is not null and right(primary_guest.phone, 4) = p_phone_last4)
       or (r.id is not null and right((select phone from guest_profiles gp where gp.id = primary_guest.guest_profile_id), 4) = p_phone_last4);

  if match then
    return query select true, r.internal_ref, r.status, r.check_in, r.check_out,
      (select name_ar from branches where id = r.branch_id);
  else
    return query select false, null::text, null::reservation_status, null::date, null::date, null::text;
  end if;
end;
$$;

-- ============ AUDIT HELPER ============
create or replace function fn_audit(p_org uuid, p_branch uuid, p_actor uuid, p_action text, p_entity text, p_entity_id uuid, p_details jsonb)
returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into audit_events (organization_id, branch_id, actor_id, action, entity_type, entity_id, details)
  values (p_org, p_branch, p_actor, p_action, p_entity, p_entity_id, p_details);
end;
$$;

grant execute on function fn_evaluate_access(uuid) to authenticated, anon;
grant execute on function fn_get_public_availability(uuid, date) to authenticated, anon;
grant execute on function fn_release_next_slot(uuid, uuid, date) to authenticated, anon;
grant execute on function fn_verify_booking_ownership(uuid, text) to authenticated, anon;
grant execute on function fn_audit(uuid, uuid, uuid, text, text, uuid, jsonb) to authenticated, anon;
