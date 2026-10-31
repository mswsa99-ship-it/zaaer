-- 0053 — the front desk findings of the 31 October review, as the owner decided them (1 November 2026).
--
-- FRONT-01 (critical): a unit whose guest stayed past the departure date was offered as free tonight and sold. Owner's
--   decision: the resident holds the unit until their departure is recorded — no new stay is allocated over tonight
--   (fn_room_available, fn_allocate: ROOM_OCCUPIED_OVERSTAY); the overstay stays in «ينتظرك الآن» and the owner's alerts.
-- FRONT-02 (critical): nothing moved a booking from «بانتظار التحقق» to «مؤكد», and the arrival requires «مؤكد».
--   Owner's decision: the booking is confirmed by itself when its identity is verified (any path), audited; bookings
--   already in that state are confirmed by this migration, each with its audit row.
-- FRONT-03: «تسجيل المغادرة» before the departure date took one click and kept the unused paid nights silently.
--   Owner's decision: a confirmation, and a decision on the unused nights — fn_staff_check_out refuses an early departure
--   until it says early_departure = 'shorten' (the stay ends today: the nights left are removed and their price becomes
--   the guest's credit, refunded or kept by the existing steps) or 'keep' (the nights stay paid), with a reason.
-- FRONT-04: the same once-only service could be added twice. Owner's decision: a second one takes a written reason.

-- ---------------------------------------------------------------------------------------------- FRONT-01
-- a resident past their departure date (still «مقيم») holds the unit from that date until tonight
create or replace function fn_room_overstay_blocks(p_room uuid, p_from date, p_to date, p_exclude_reservation uuid default null)
returns boolean language sql stable security definer set search_path = public, extensions as $$
  select exists (
    select 1 from reservation_allocations a join reservations rs on rs.id = a.reservation_id join rooms rm on rm.id = a.room_id
    where a.room_id = p_room and a.status = 'active' and rs.status = 'checked_in'
      and a.to_date <= fn_branch_today(rm.branch_id)
      and daterange(a.to_date, fn_branch_today(rm.branch_id) + 1, '[)') && daterange(p_from, p_to, '[)')
      and (p_exclude_reservation is null or a.reservation_id <> p_exclude_reservation));
$$;
revoke all on function fn_room_overstay_blocks(uuid, date, date, uuid) from public, anon;
grant execute on function fn_room_overstay_blocks(uuid, date, date, uuid) to authenticated;

create or replace function fn_room_available(p_room uuid, p_from date, p_to date, p_exclude_reservation uuid default null)
returns boolean language sql stable security definer set search_path = public, extensions as $$
  select exists (select 1 from rooms rm where rm.id = p_room and rm.branch_id in (select fn_user_branch_ids()))
     and not exists (
    select 1 from reservation_allocations a
    where a.room_id = p_room and a.status = 'active'
      and daterange(a.from_date, a.to_date, '[)') && daterange(p_from, p_to, '[)')
      and (p_exclude_reservation is null or a.reservation_id <> p_exclude_reservation))
     and not fn_room_overstay_blocks(p_room, p_from, p_to, p_exclude_reservation);
$$;


create or replace function fn_allocate(p_reservation uuid, p_room uuid, p_from date, p_to date, p_reason text) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare r reservations%rowtype; rm rooms%rowtype; aid uuid;
begin
  select * into r from reservations where id = p_reservation;
  select * into rm from rooms where id = p_room for update;
  if not found or rm.branch_id <> r.branch_id then raise exception 'ROOM_NOT_FOUND'; end if;
  if not rm.is_active or rm.archived_at is not null or rm.status in ('blocked','out_of_service','maintenance') then raise exception 'ROOM_NOT_AVAILABLE'; end if;
  if r.room_category_id is not null and rm.category_id <> r.room_category_id then raise exception 'ROOM_CATEGORY_MISMATCH'; end if;
  if fn_room_overstay_blocks(p_room, p_from, p_to, r.id) then raise exception 'ROOM_OCCUPIED_OVERSTAY'; end if;
  begin
    insert into reservation_allocations(reservation_id, room_id, branch_id, from_date, to_date, status, reason, created_by)
    values (r.id, p_room, r.branch_id, p_from, p_to, 'active', p_reason, fn_staff_id()) returning id into aid;
  exception when exclusion_violation then
    raise exception 'ALLOCATION_CONFLICT: room % is allocated during part of %–%', rm.room_number, p_from, p_to using errcode = '23P01';
  end;
  update reservations set room_id = p_room, updated_at = now() where id = r.id;
  -- 'reserved' is an operational flag for a stay that starts today or already started; future allocations keep the room sellable/cleanable today
  if rm.status in ('available','ready','cleaning') and r.status in ('confirmed','pending_verification') and p_from <= fn_branch_today(r.branch_id) then
    update rooms set status = 'reserved' where id = p_room;
  else
    perform fn_recompute_room_ready(p_room);   -- never leave a stale 'available': readiness is computed (ready / cleaning / maintenance)
  end if;
  return aid;
end $$;

-- ---------------------------------------------------------------------------------------------- FRONT-02
create or replace function fn_trg_confirm_on_identity() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'pending_verification' and new.identity_status = 'verified' and old.identity_status is distinct from 'verified' then
    new.status := 'confirmed';
    perform fn_audit_change(new.branch_id, 'reservation.confirmed', 'reservation', new.id,
      jsonb_build_object('status', 'pending_verification'), jsonb_build_object('status', 'confirmed', 'by', 'identity_verified'), null);
  end if;
  return new;
end $$;
revoke all on function fn_trg_confirm_on_identity() from public, anon, authenticated;
create or replace trigger trg_confirm_on_identity before update of identity_status on reservations
  for each row execute function fn_trg_confirm_on_identity();

do $c$ declare r record; begin
  for r in select id, branch_id from reservations where status = 'pending_verification' and identity_status = 'verified' loop
    update reservations set status = 'confirmed', version = version + 1, updated_at = now() where id = r.id;
    perform fn_audit_change(r.branch_id, 'reservation.confirmed', 'reservation', r.id,
      jsonb_build_object('status', 'pending_verification'), jsonb_build_object('status', 'confirmed', 'by', 'migration_0053'), 'تأكيد تلقائي: الهوية مطابقة');
  end loop;
end $c$;

-- ---------------------------------------------------------------------------------------------- FRONT-03
-- the nights from p_new_check_out to the stay's departure are removed and their price becomes the guest's credit
-- (the same entries as «تقصير الإقامة»; a departure is recorded the same day, so «today» is allowed here)
create or replace function fn_shorten_for_departure(p_reservation uuid, p_new_check_out date, p_reason text) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare r reservations%rowtype; refund bigint; delta int; before jsonb;
begin
  select * into r from reservations where id = p_reservation for update;
  delta := p_new_check_out - r.check_out;
  if delta >= 0 then return 0; end if;
  if r.price_basis in ('weekly', 'monthly') and not fn_has_role('owner','manager') then
    raise exception 'FORBIDDEN: shortening a weekly or monthly stay requires manager';
  end if;
  before := jsonb_build_object('check_out', r.check_out, 'total_halalas', r.total_halalas);
  perform fn_ensure_nights(r.id);
  update reservation_allocations set to_date = p_new_check_out
  where reservation_id = r.id and status = 'active' and to_date = r.check_out and from_date < p_new_check_out;
  select coalesce(sum(price_halalas), 0) into refund from reservation_nights
  where reservation_id = r.id and status = 'active' and night >= p_new_check_out and night < r.check_out;
  update reservation_nights set status = 'removed', removed_at = now(), removed_by = fn_staff_id(), removed_reason = p_reason
  where reservation_id = r.id and status = 'active' and night >= p_new_check_out and night < r.check_out;
  perform fn_add_charge(r.id, 'adjustment', 'مغادرة مبكرة: ' || abs(delta) || ' ليلة لم تُستخدم', 1, -refund, true, p_reason, null, p_new_check_out, r.check_out);
  update reservations set check_out = p_new_check_out,
         nightly_rate_halalas = coalesce((select round(avg(price_halalas))::bigint from reservation_nights where reservation_id = r.id and status = 'active'), nightly_rate_halalas),
         updated_at = now()
  where id = r.id;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_audit_change(r.branch_id, 'reservation.departure_changed', 'reservation', r.id, before,
    jsonb_build_object('check_out', p_new_check_out, 'total_halalas', (select total_halalas from reservations where id = r.id), 'delta_nights', delta,
                       'early_departure', 'shorten', 'nights', jsonb_build_object('refunded_halalas', refund)), p_reason);
  return refund;
end $$;
revoke all on function fn_shorten_for_departure(uuid, date, text) from public, anon, authenticated;

create or replace function fn_staff_check_out(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; f jsonb; tt uuid; existing_task uuid; has_kb boolean; st text; inv_no text;
        v_today date; v_end date; v_mode text; v_reason text; v_unused int; v_amount bigint;
begin
  perform fn_require_cap('checkout');
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.status in ('checked_out', 'closed') then return jsonb_build_object('ok', true, 'duplicate', true, 'status', r.status); end if;   -- R14
  if r.status <> 'checked_in' then raise exception 'NOT_CHECKED_IN'; end if;
  if p ? 'expected_version' then perform fn_check_version(r.version, (p->>'expected_version')::int); end if;

  -- FRONT-03: leaving before the departure date is a decision on the nights not used, with a reason
  v_today := fn_branch_today(r.branch_id);
  if r.check_out > v_today then
    v_end := greatest(v_today, r.check_in + 1);
    v_mode := nullif(p->>'early_departure', '');
    v_reason := nullif(trim(coalesce(p->>'reason', '')), '');
    if v_end < r.check_out then
      perform fn_ensure_nights(r.id);
      select count(*), coalesce(sum(price_halalas), 0) into v_unused, v_amount from reservation_nights
      where reservation_id = r.id and status = 'active' and night >= v_end and night < r.check_out;
      if v_mode is null then
        return jsonb_build_object('ok', false, 'early_departure', true, 'unused_nights', v_unused, 'unused_halalas', v_amount, 'new_check_out', v_end,
          'reasons', jsonb_build_array('مغادرة قبل موعدها: ' || v_unused || ' ليلة مدفوعة أو محجوزة لم تُستخدم. اختر تقصير الإقامة أو إبقاء الليالي مدفوعة، مع السبب.'));
      end if;
      if v_mode not in ('shorten', 'keep') then raise exception 'VALIDATION: early_departure'; end if;
      if v_reason is null then raise exception 'VALIDATION: reason'; end if;
      if v_mode = 'shorten' then
        perform fn_shorten_for_departure(r.id, v_end, v_reason);
        select * into r from reservations where id = r.id;
      else
        perform fn_audit_change(r.branch_id, 'reservation.departure_changed', 'reservation', r.id, jsonb_build_object('check_out', r.check_out),
          jsonb_build_object('check_out', r.check_out, 'early_departure', 'keep', 'unused_nights', v_unused, 'unused_halalas', v_amount), v_reason);
      end if;
    end if;
  end if;

  f := fn_recompute_reservation_finance(r.id);
  -- nothing owed, for anyone: no override (decision 8)
  if (f->>'balance_due')::bigint > 0 then
    return jsonb_build_object('ok', false, 'balance_due', (f->>'balance_due')::bigint, 'reasons', jsonb_build_array(
      'على الحجز مبلغ مستحق ' || fn_sar_text((f->>'balance_due')::bigint)
      || '. يُصفَّر بسند قبض، أو بالخصم من التأمين بسبب، أو بتسوية سعر من المالك أو المدير بسبب.'));
  end if;
  update reservations set status = 'checked_out', actual_check_out = now(), checked_out_by = fn_staff_id(), version = version + 1, updated_at = now() where id = r.id;
  perform fn_release_allocations(r.id, 'close');
  if r.room_id is not null then
    update rooms set status = 'cleaning', cleanliness = 'dirty', updated_at = now() where id = r.room_id;
    tt := fn_room_cleaning_type(r.branch_id);
    select id into existing_task from housekeeping_tasks where room_id = r.room_id and reservation_id = r.id and status in ('pending', 'in_progress') limit 1;
    if existing_task is null then
      insert into housekeeping_tasks(organization_id, branch_id, room_id, task_type_id, task_type_name_snapshot, reservation_id, priority, description, created_by)
      values (r.organization_id, r.branch_id, r.room_id, tt, 'تنظيف الوحدة وتعقيمها', r.id, 'high', 'تنظيف بعد المغادرة', fn_staff_id());
    end if;
    has_kb := exists (select 1 from keyboxes where room_id = r.room_id);
    update keyboxes set code_status = 'needs_change', field_tested = false where room_id = r.room_id;
    insert into notifications(branch_id, audience, title, body, link)
    values (r.branch_id, 'supervisor', case when has_kb then 'مغادرة — تنظيف وتغيير رمز مطلوب' else 'مغادرة — تنظيف مطلوب' end,
            'غرفة ' || (select room_number from rooms where id = r.room_id), '/staff/housekeeping');
  end if;
  perform fn_audit_change(r.branch_id, 'reservation.checked_out', 'reservation', r.id, jsonb_build_object('status', 'checked_in'),
    jsonb_build_object('status', 'checked_out', 'deposit_balance_halalas', (f->>'deposit_balance')::bigint, 'credit_halalas', (f->>'credit')::bigint));
  inv_no := fn_auto_invoice(r.id, 'checkout');
  st := fn_sync_closed(r.id);
  return jsonb_build_object('ok', true, 'duplicate', false, 'status', st, 'deposit_to_settle_halalas', (f->>'deposit_balance')::bigint,
                            'credit_halalas', (f->>'credit')::bigint, 'invoice', inv_no, 'missing', to_jsonb(fn_closure_missing(r.id)));
end $$;

-- ---------------------------------------------------------------------------------------------- FRONT-04
create or replace function fn_staff_add_service(p_reservation uuid, p_service uuid, p_quantity numeric default 1, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; s service_definitions%rowtype; qty numeric; price bigint; cid uuid; v_note text := nullif(trim(coalesce(p_note, '')), '');
begin
  perform fn_require_cap('charges.add');
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.status in ('cancelled','rejected','closed','no_show') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  select * into s from service_definitions where id = p_service and branch_id = r.branch_id and archived_at is null and is_active;
  if not found then raise exception 'SERVICE_NOT_AVAILABLE'; end if;
  if r.status = 'checked_in' and fn_overdue_blocked(r.id) then
    raise exception 'PAYMENT_OVERDUE: a night is unpaid past its deadline';
  end if;
  if s.late_checkout_until is not null and r.status not in ('pending_verification', 'confirmed', 'checked_in') then
    raise exception 'RESERVATION_STATUS_INVALID';
  end if;
  -- FRONT-04: a once-only service already on the stay is added again only with a written reason
  if s.billing_unit = 'once' and v_note is null
     and exists (select 1 from reservation_charges c where c.reservation_id = r.id and c.kind = 'addon' and c.service_definition_id = s.id) then
    raise exception 'SERVICE_ALREADY_ADDED';
  end if;
  qty := case s.billing_unit when 'night' then (r.check_out - r.check_in) when 'person' then (r.adults + r.companions) when 'quantity' then coalesce(p_quantity,1) else 1 end;
  if qty <= 0 then raise exception 'VALIDATION: quantity'; end if;
  price := case when s.is_free then 0 else s.price_halalas end;
  -- snapshot name/price/tax at the time of adding (G27)
  cid := fn_add_charge(r.id, 'addon', s.name_ar || case when v_note is not null then ' — ' || v_note else '' end, qty, price, s.taxable, null, s.id,
                       case when s.billing_unit = 'night' then r.check_in end, case when s.billing_unit = 'night' then r.check_out end);
  if s.late_checkout_until is not null then
    update reservation_charges set purpose = 'late_checkout' where id = cid;
    update reservations set late_checkout_until = greatest(coalesce(late_checkout_until, s.late_checkout_until), s.late_checkout_until) where id = r.id;
  end if;
  update reservations set version = version + 1 where id = r.id;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_audit_change(r.branch_id, 'reservation.service_added', 'reservation', r.id, null,
    jsonb_build_object('service_id', s.id, 'name', s.name_ar, 'quantity', qty, 'unit_price', price, 'late_checkout_until', to_char(s.late_checkout_until, 'HH24:MI'), 'note', v_note));
  return jsonb_build_object('ok', true, 'finance', fn_reservation_finance_internal(r.id), 'late_checkout_until', to_char(s.late_checkout_until, 'HH24:MI'));
end $$;

-- the older entry point (no screen calls it): its reason, when given, is a decision to keep the nights paid
create or replace function fn_staff_checkout(p_reservation uuid, p_override_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  return fn_staff_check_out(jsonb_build_object('reservation_id', p_reservation)
    || case when nullif(trim(coalesce(p_override_reason, '')), '') is null then '{}'::jsonb
            else jsonb_build_object('early_departure', 'keep', 'reason', p_override_reason) end);
end $$;
