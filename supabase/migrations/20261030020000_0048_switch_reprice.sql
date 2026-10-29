-- =====================================================================
-- 0048 — Changes before arrival (correction batch 3: B4, B5; the owner's notes 5 and 6, decision 3).
--   * Switching a booking that has not checked in to a unit of another type re-prices the nights from the effective
--     day by the new type's prices (the calendar, the platform price for a platform booking, the weekly or monthly
--     price when the whole stay moves). The old nights keep their rows marked removed and are refunded by one
--     adjustment line; the new nights are booked as rent lines, so the change is visible line by line.
--   * Kept as before: a stay the platform collected (its amount does not change with the unit), a resident's switch
--     (a difference is an explicit adjustment), and a switch within the same type.
--   * The answer says whether the price changed and by how much; the audit keeps the old and new totals.
--   * A platform booking's number, booking day and who collects can be corrected before arrival (fn_staff_update_platform).
--   * fn_quote_stay takes 'periods': false (calendar prices only), so the switch dialog shows what will be booked.
--   Changes no stored data.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.fn_staff_switch_room(p_reservation uuid, p_room uuid, p_effective date, p_reason text, p_expected_version integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare r reservations%rowtype; old reservation_allocations%rowtype; eff date; old_room uuid; new_rm rooms%rowtype; new_kb boolean;
        v_reprice boolean; v_old_sum bigint := 0; v_new_sum bigint := 0; v_runs jsonb; v_platform boolean;
begin
  perform fn_require_cap('room.assign');
  if coalesce(trim(p_reason),'') = '' then raise exception 'VALIDATION: reason'; end if;
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  perform fn_check_version_strict(r.version, p_expected_version);
  if r.status not in ('confirmed','checked_in','pending_verification') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  eff := coalesce(p_effective, greatest(fn_branch_today(r.branch_id), r.check_in));
  if eff < r.check_in or eff >= r.check_out then raise exception 'VALIDATION: effective_date'; end if;
  if r.status = 'checked_in' and eff > fn_branch_today(r.branch_id) then raise exception 'VALIDATION: effective_date'; end if;   -- a resident moves now, not in the future
  select * into new_rm from rooms where id = p_room;
  if not found or new_rm.branch_id <> r.branch_id then raise exception 'ROOM_NOT_FOUND'; end if;            -- R06
  if r.room_id = p_room then raise exception 'SAME_ROOM'; end if;
  if r.status = 'checked_in' and new_rm.cleanliness <> 'clean' then raise exception 'ROOM_NOT_CLEAN'; end if;
  if r.adults + r.companions > (select max_capacity from room_categories where id = new_rm.category_id) then raise exception 'CAPACITY_EXCEEDED'; end if;

  -- lock rooms in a fixed order to avoid deadlocks when two switches cross
  perform 1 from rooms where id in (p_room, r.room_id) order by id for update;

  select * into old from reservation_allocations where reservation_id = r.id and status = 'active' and daterange(from_date, to_date, '[)') @> eff for update;
  if found then
    if old.room_id = p_room then raise exception 'SAME_ROOM'; end if;
    old_room := old.room_id;
    if old.from_date = eff then
      update reservation_allocations set status = 'cancelled', closed_at = now(), reason = coalesce(reason,'') || ' | switched' where id = old.id;
    else
      update reservation_allocations set to_date = eff, status = case when eff <= fn_branch_today(r.branch_id) and r.status = 'checked_in' then 'closed' else 'active' end,
             closed_at = case when eff <= fn_branch_today(r.branch_id) and r.status = 'checked_in' then now() end where id = old.id;
    end if;
    if r.status = 'checked_in' then
      update rooms set status = 'cleaning', cleanliness = 'dirty' where id = old_room;
      insert into housekeeping_tasks(organization_id, branch_id, room_id, task_type_id, task_type_name_snapshot, reservation_id, priority, description, created_by)
      select r.organization_id, r.branch_id, old_room, t.id, t.name, r.id, 'high', 'تبديل وحدة', fn_staff_id() from task_types t where t.id = fn_room_cleaning_type(r.branch_id);
      update keyboxes set code_status = 'needs_change', field_tested = false where room_id = old_room;
    else
      update rooms set status = 'available' where id = old_room and status = 'reserved';
    end if;
  end if;

  -- B5 (the owner's decision): before check-in, a unit of another type re-prices the nights from the effective day by the
  -- new type (calendar, platform price for a platform booking). The old nights keep their rows, marked removed, and are
  -- refunded by one adjustment; the new nights are booked as rent. A stay the platform collected keeps its price (the
  -- platform's amount does not change with the unit), and a resident's switch keeps it too (an explicit adjustment).
  v_reprice := r.status in ('confirmed','pending_verification') and r.room_category_id <> new_rm.category_id
               and not coalesce(r.platform_collects, false);
  update reservations set room_category_id = new_rm.category_id where id = r.id and r.room_category_id <> new_rm.category_id;
  perform fn_allocate(r.id, p_room, eff, r.check_out, 'switch: ' || p_reason);
  if v_reprice then
    perform fn_ensure_nights(r.id);
    select coalesce(sum(price_halalas), 0) into v_old_sum from reservation_nights
    where reservation_id = r.id and status = 'active' and night >= eff and night < r.check_out;
    update reservation_nights set status = 'removed', removed_at = now(), removed_by = fn_staff_id(), removed_reason = 'تبديل وحدة: ' || p_reason
    where reservation_id = r.id and status = 'active' and night >= eff and night < r.check_out;
    if v_old_sum <> 0 then
      perform fn_add_charge(r.id, 'adjustment', 'تبديل وحدة: إلغاء سعر النوع السابق', 1, -v_old_sum, true, p_reason, null, eff, r.check_out);
    end if;
    v_platform := exists (select 1 from booking_sources s where s.id = r.source_id and s.kind <> 'direct');
    v_runs := fn_stay_runs(new_rm.category_id, eff, r.check_out, v_platform, null, eff = r.check_in);
    v_new_sum := fn_book_nights(r.id, v_runs, 'تبديل وحدة', p_reason);
    -- the stay's discounts never exceed its rent after a cheaper type (a discount is reviewed again, not carried below zero)
    if coalesce((select sum(-total_halalas) from reservation_charges where reservation_id = r.id and kind = 'discount'), 0)
       > (select coalesce(sum(price_halalas), 0) from reservation_nights where reservation_id = r.id and status = 'active') then
      raise exception 'VALIDATION: discount_exceeds_rent';
    end if;
    -- a whole stay moved takes the basis its new nights carry (decision 15 reads it when the stay is shortened)
    update reservations set nightly_rate_halalas = coalesce((select round(avg(price_halalas))::bigint from reservation_nights where reservation_id = r.id and status = 'active'), nightly_rate_halalas),
           price_basis = case when eff = r.check_in and price_basis <> 'manual' then
                           case when exists (select 1 from jsonb_array_elements(v_runs) x where x->>'basis' = 'monthly') then 'monthly'
                                when exists (select 1 from jsonb_array_elements(v_runs) x where x->>'basis' = 'weekly') then 'weekly' else 'daily' end
                         else price_basis end
    where id = r.id;
    perform fn_recompute_reservation_finance(r.id);
  end if;
  new_kb := exists (select 1 from keyboxes where room_id = p_room);
  if r.status = 'checked_in' then
    update rooms set status = 'occupied' where id = p_room;
    update reservations set access_status = case when new_kb then 'approved' else 'key_handed' end::access_status, keybox_delivered = false where id = r.id;
  end if;
  update reservations set version = version + 1, updated_at = now() where id = r.id;
  perform fn_audit_change(r.branch_id, 'reservation.room_switched', 'reservation', r.id, jsonb_build_object('room_id', old_room, 'category_id', r.room_category_id, 'total_halalas', r.total_halalas),
    jsonb_build_object('room_id', p_room, 'effective', eff, 'category_id', new_rm.category_id, 'repriced', v_reprice,
                       'old_nights_halalas', v_old_sum, 'new_nights_halalas', v_new_sum, 'total_halalas', (select total_halalas from reservations where id = r.id)), p_reason);
  return jsonb_build_object('ok', true, 'from_room', old_room, 'to_room', p_room, 'effective', eff,
                            'entry_code_review_required', r.status = 'checked_in', 'code_delivery_required', r.status = 'checked_in' and new_kb,
                            'repriced', v_reprice, 'price_delta_halalas', v_new_sum - v_old_sum,
                            'price_kept_reason', case when v_reprice then null when r.room_category_id = new_rm.category_id then 'same_type'
                                                      when r.status = 'checked_in' then 'in_house' else 'platform_collects' end);
end $function$;


-- B4 (the owner's note 5): the platform's fields of a booking can be corrected before arrival and before «طابقتُ مع
-- المنصة» — the platform's number (one per booking or group, decision 69), the day it was booked there, and who
-- collects. A reason is required; the group's units change together; the audit keeps the before and after.
--   * who collects: the platform → the property cancels the deferred receipt «آجل عبر المنصات» (the voucher's own
--     cancellation, so it needs «إلغاء سند» and is refused once the receipt is in a platform payout); the property →
--     the platform issues that receipt for what is still owed.
--   * the source (the platform itself) is not changed here: that waits for the owner's decision on its price.
create or replace function fn_staff_update_platform(p_reservation uuid, p jsonb, p_reason text, p_expected_version int default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; u reservations%rowtype; src booking_sources%rowtype; f jsonb; vch jsonb;
        v_ext text; v_booked date; v_collects boolean; n int := 0; v_vouchers jsonb := '[]'::jsonb; owed bigint; vv record; v_con text;
begin
  perform fn_require_cap('res.create');
  if coalesce(trim(p_reason), '') = '' then raise exception 'VALIDATION: reason'; end if;
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  perform fn_check_version_strict(r.version, p_expected_version);
  select * into src from booking_sources where id = r.source_id;
  if not found or src.kind <> 'external' then raise exception 'VALIDATION: not_platform'; end if;
  if r.status not in ('confirmed', 'pending_verification') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  if r.platform_verified_at is not null then raise exception 'PLATFORM_VERIFIED'; end if;

  v_ext := case when p ? 'external_ref' then nullif(btrim(fn_latin_digits(p->>'external_ref')), '') else r.external_ref end;
  if src.external_reference_required and v_ext is null then raise exception 'VALIDATION: external_ref_required'; end if;
  begin v_booked := case when p ? 'platform_booked_on' then nullif(p->>'platform_booked_on', '')::date else r.platform_booked_on end;
  exception when others then raise exception 'VALIDATION: platform_booked_on'; end;
  if v_booked is null or v_booked > fn_branch_today(r.branch_id) or v_booked < r.check_in - 730 then raise exception 'VALIDATION: platform_booked_on'; end if;
  v_collects := case when p ? 'platform_collects' then (p->>'platform_collects')::boolean else r.platform_collects end;
  if v_collects is null then raise exception 'VALIDATION: platform_collects'; end if;
  -- decision 69: one platform number per booking or group
  if v_ext is not null and exists (select 1 from reservations x where x.organization_id = r.organization_id and x.source_id = r.source_id and x.external_ref = v_ext
                                     and coalesce(x.group_ref, x.id::text) <> coalesce(r.group_ref, r.id::text)) then
    raise exception 'DUPLICATE_EXTERNAL_REF';
  end if;

  for u in select * from reservations where id = r.id or (r.group_ref is not null and group_ref = r.group_ref and organization_id = r.organization_id)
           order by id for update loop
    perform fn_require_branch(u.branch_id);
    if u.id <> r.id and u.status not in ('confirmed', 'pending_verification', 'cancelled', 'no_show') then raise exception 'GROUP_UNIT_IN_HOUSE'; end if;
    if u.id <> r.id and u.status in ('cancelled', 'no_show') then
      if u.external_ref is distinct from v_ext then                                        -- the group keeps one number
        update reservations set external_ref = v_ext, version = version + 1, updated_at = now() where id = u.id;
        perform fn_audit_change(u.branch_id, 'reservation.platform_updated', 'reservation', u.id, jsonb_build_object('external_ref', u.external_ref),
          jsonb_build_object('external_ref', v_ext), p_reason);
      end if;
      continue;
    end if;
    -- who collects changed: the deferred receipt follows (money moves, so the caller must see money)
    if coalesce(u.platform_collects, false) <> v_collects then perform fn_require_money(); end if;
    if coalesce(u.platform_collects, false) and not v_collects then
      -- the deferred refunds go first, so the receipt's cancellation never leaves the stay below zero
      for vv in select id from financial_vouchers where reservation_id = u.id and kind in ('refund', 'receipt') and method = 'ota_deferred' and status = 'approved'
                order by (kind = 'receipt'), created_at loop
        perform fn_cancel_voucher(vv.id, 'تغيير من يقبض: المنشأة عند الوصول — ' || p_reason);
      end loop;
    elsif not coalesce(u.platform_collects, false) and v_collects then
      f := fn_reservation_finance_internal(u.id);
      owed := (f->>'total')::bigint - ((f->>'received')::bigint - (f->>'refunded')::bigint);
      if owed > 0 then
        vch := fn_create_voucher(jsonb_build_object('kind', 'receipt', 'reservation_id', u.id, 'amount_halalas', owed, 'method', 'ota_deferred',
                                                    'reference', v_ext, 'note', 'قبضته المنصة عند الحجز', 'reason', p_reason,
                                                    'idempotency_key', 'platform-collect:' || u.id || ':' || u.version));
        v_vouchers := v_vouchers || jsonb_build_array(vch->>'number');
      end if;
    end if;
    update reservations set external_ref = v_ext, platform_booked_on = v_booked, platform_collects = v_collects,
           version = version + 1, updated_at = now() where id = u.id;
    perform fn_recompute_reservation_finance(u.id);
    perform fn_audit_change(u.branch_id, 'reservation.platform_updated', 'reservation', u.id,
      jsonb_build_object('external_ref', u.external_ref, 'platform_booked_on', u.platform_booked_on, 'platform_collects', u.platform_collects),
      jsonb_build_object('external_ref', v_ext, 'platform_booked_on', v_booked, 'platform_collects', v_collects, 'vouchers', v_vouchers), p_reason);
    n := n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'units', n, 'vouchers', v_vouchers, 'finance', fn_reservation_finance_internal(r.id));
exception when unique_violation or exclusion_violation then
  get stacked diagnostics v_con = constraint_name;
  if v_con in ('uniq_reservation_source_ref', 'excl_reservation_source_ref') then raise exception 'DUPLICATE_EXTERNAL_REF'; end if;
  raise;
end $$;
revoke execute on function fn_staff_update_platform(uuid, jsonb, text, int) from public, anon;
grant execute on function fn_staff_update_platform(uuid, jsonb, text, int) to authenticated;

-- the quote can leave out the weekly and monthly prices: the switch dialog previews a part of a stay as 0048 books it
CREATE OR REPLACE FUNCTION public.fn_quote_stay(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_branch uuid := (p->>'branch_id')::uuid; v_cat uuid := (p->>'category_id')::uuid; ci date := (p->>'check_in')::date; co date := (p->>'check_out')::date;
        c room_categories%rowtype; b branches%rowtype; src booking_sources%rowtype; platform boolean := false;
        ovr bigint := nullif(p->>'nightly_rate_halalas', '')::bigint; disc bigint := coalesce(nullif(p->>'discount_halalas', '')::bigint, 0);
        runs jsonb; x jsonb; n int; rent_gross bigint := 0; rent_net bigint := 0; tax bigint := 0; net bigint; t bigint; disc_net bigint := 0; disc_tax bigint := 0;
        computed bigint; min_total bigint; sup_max bigint; my_max bigint;
begin
  perform fn_require_branch(v_branch);
  if ci is null or co is null or co <= ci then raise exception 'VALIDATION: dates'; end if;
  if co - ci > 366 then raise exception 'VALIDATION: dates'; end if;
  select * into c from room_categories where id = v_cat and branch_id = v_branch;
  if not found then raise exception 'BRANCH_MISMATCH: category'; end if;
  select * into b from branches where id = v_branch;
  if nullif(p->>'source_id', '') is not null then
    select * into src from booking_sources where id = (p->>'source_id')::uuid and organization_id = fn_user_org_id();
    platform := found and src.kind <> 'direct';
  end if;
  if disc < 0 then raise exception 'VALIDATION: amount'; end if;
  n := co - ci;
  runs := fn_stay_runs(v_cat, ci, co, platform, ovr, coalesce((p->>'periods')::boolean, true));
  for x in select * from jsonb_array_elements(runs) loop
    rent_gross := rent_gross + (x->>'nights')::bigint * (x->>'price')::bigint;
    select * into net, t from fn_apply_tax(v_branch, (x->>'nights')::bigint * (x->>'price')::bigint, true);
    rent_net := rent_net + net; tax := tax + t;
  end loop;
  if disc > rent_gross then raise exception 'VALIDATION: discount_exceeds_rent'; end if;
  if disc > 0 then select * into disc_net, disc_tax from fn_apply_tax(v_branch, -disc, true); end if;
  computed := (select coalesce(sum(s.price_halalas), 0) from fn_stay_prices(v_cat, ci, co, platform, null, true) s);
  min_total := c.min_nightly_halalas * n;
  sup_max := greatest(0, least(floor(rent_gross::numeric * b.supervisor_max_discount_bp / 10000)::bigint, rent_gross - coalesce(min_total, 0)));
  my_max := case when fn_can('disc.after') then rent_gross when fn_can('disc.before') then sup_max else 0 end;
  return jsonb_build_object('nights', n, 'runs', runs, 'channel', case when platform then 'platform' else 'system' end,
    'basis', case when ovr is not null then 'manual' when not coalesce((p->>'periods')::boolean, true) then 'daily' when n >= 30 and c.monthly_price_halalas is not null then 'monthly'
                  when n >= 7 and c.weekly_price_halalas is not null then 'weekly' else 'daily' end,
    'nightly_rate', round(rent_gross::numeric / n)::bigint, 'rent_gross', rent_gross, 'computed_rent', computed,
    'rent', rent_net, 'discount', disc_net, 'tax', tax + disc_tax, 'total', rent_net + disc_net + tax + disc_tax,
    'tax_rate_bp', b.tax_rate_bp, 'prices_include_tax', b.prices_include_tax,
    'min_nightly', c.min_nightly_halalas, 'discount_max', my_max, 'supervisor_discount_max', sup_max,
    'supervisor_max_discount_bp', b.supervisor_max_discount_bp);
end $function$;


-- the audit dictionary gains the platform correction (kept identical to src/lib/auditLabels.ts by tests/unit/audit_labels.test.ts)
create or replace function fn_audit_action_label(p_action text) returns text
language sql immutable set search_path = public as $$
  select coalesce(
    case p_action
      when 'reservation.created' then 'إنشاء حجز'
      when 'reservation.cancelled' then 'إلغاء حجز'
      when 'reservation.cancel_undone' then 'التراجع عن إلغاء حجز'
      when 'reservation.checked_in' then 'تسجيل وصول'
      when 'reservation.check_in_undone' then 'التراجع عن تسجيل الوصول'
      when 'reservation.checked_out' then 'تسجيل مغادرة'
      when 'reservation.closed' then 'إغلاق إقامة'
      when 'reservation.unclosed' then 'إعادة فتح إقامة مغلقة'
      when 'reservation.stay_reopened' then 'إعادة فتح إقامة بعد المغادرة'
      when 'reservation.no_show' then 'تسجيل عدم حضور'
      when 'reservation.departure_changed' then 'تغيير موعد المغادرة'
      when 'reservation.room_switched' then 'تبديل الوحدة'
      when 'reservation.service_added' then 'إضافة خدمة إلى الحجز'
      when 'reservation.total_changed' then 'تعديل إجمالي الحجز'
      when 'reservation.payment_exception' then 'مهلة سداد استثنائية'
      when 'reservation.inspected' then 'فحص المغادرة'
      when 'reservation.damage_charged' then 'رسم ضرر'
      when 'reservation.hold_set' then 'وضع حظر على الحجز'
      when 'reservation.hold_lifted' then 'رفع الحظر عن الحجز'
      when 'reservation.shomoos_registered' then 'تسجيل شموس'
      when 'reservation.shomoos_accepted' then 'تأكيد قبول شموس'
      when 'reservation.platform_updated' then 'تصحيح بيانات المنصة'
      when 'reservation.platform_checked' then 'مطابقة الحجز مع المنصة'
      when 'reservation.platform_unchecked' then 'إلغاء مطابقة الحجز مع المنصة'
      when 'reservation.summary_signed' then 'إقرار ملخص الإقامة ورقيًا'
      when 'assign_room' then 'تخصيص وحدة للحجز'
      when 'approve_checkin' then 'اعتماد الدخول'
      when 'checkout' then 'تسجيل مغادرة'
      when 'manual_release_slot' then 'فتح توفر يدويًا'
      when 'guest.entered_from_document' then 'إدخال بيانات ضيف من الوثيقة'
      when 'guest.corrected' then 'تصحيح بيانات ضيف'
      when 'guest.banned' then 'حظر ضيف'
      when 'guest.unbanned' then 'رفع حظر ضيف'
      when 'guest.rated' then 'تقييم ضيف'
      when 'guest_data_submitted' then 'إدخال الضيف بياناته بنفسه'
      when 'guest_verified_lookup' then 'تحقق الضيف من حجزه'
      when 'guest_checkin_request' then 'طلب وصول من الضيف'
      when 'guest_viewed_code' then 'عرض الضيف رمز الدخول'
      when 'guest_summary_accepted' then 'قبول الضيف ملخص الإقامة'
      when 'confirm_gov_registration' then 'تأكيد التسجيل الحكومي'
      when 'approve_identity' then 'اعتماد هوية ضيف'
      when 'reject_identity' then 'رفض هوية ضيف'
      when 'confirm_payment' then 'تأكيد دفعة'
      when 'voucher.receipt_created' then 'إنشاء سند قبض'
      when 'voucher.deposit_created' then 'إنشاء سند تأمين'
      when 'voucher.refund_created' then 'إنشاء سند رد'
      when 'voucher.deposit_refund_created' then 'إنشاء سند رد تأمين'
      when 'voucher.deposit_apply_created' then 'استخدام التأمين لتغطية رسوم'
      when 'voucher.cancelled' then 'إلغاء سند'
      when 'voucher.corrected' then 'تصحيح سند'
      when 'invoice.issued' then 'إصدار فاتورة'
      when 'invoice.edited' then 'تعديل فاتورة'
      when 'invoice.cancelled' then 'إلغاء فاتورة'
      when 'pos.settled' then 'تسوية الشبكة'
      when 'platform.payout_confirmed' then 'تأكيد إيداع منصة'
      when 'platform.payout_cancelled' then 'إلغاء إيداع منصة'
      when 'cash_account.created' then 'إنشاء صندوق أو حساب'
      when 'cash_account.updated' then 'تعديل صندوق أو حساب'
      when 'cash_account.archived' then 'أرشفة صندوق أو حساب'
      when 'cash_account.restored' then 'استعادة صندوق أو حساب'
      when 'rates.updated' then 'تعديل الأسعار'
      when 'review.marked' then 'مراجعة بند من قائمة المراجعة'
      when 'deliver_access_code' then 'تسليم رمز الدخول'
      when 'delivery_failed' then 'تعذّر تسليم رمز الدخول'
      when 'rotate_keybox_code' then 'تغيير رمز صندوق المفتاح'
      when 'keybox_field_tested' then 'تجربة رمز صندوق المفتاح'
      when 'keybox.code_viewed' then 'عرض رمز صندوق المفتاح'
      when 'task.created' then 'إنشاء مهمة'
      when 'task.started' then 'بدء مهمة'
      when 'task.completed' then 'إتمام مهمة'
      when 'task.cancelled' then 'إلغاء مهمة'
      when 'task.assigned' then 'إسناد مهمة'
      when 'cleaning_completed' then 'إتمام تنظيف'
      when 'room.cleanliness_changed' then 'تغيير حالة النظافة يدويًا'
      when 'maintenance_opened' then 'فتح بلاغ صيانة'
      when 'maintenance_resolved' then 'إغلاق بلاغ صيانة'
      when 'branch.created' then 'إنشاء فرع'
      when 'branch.updated' then 'تعديل فرع'
      when 'branch.money_defaults' then 'تعديل إعدادات المال للفرع'
      when 'branch.tax_changed' then 'تغيير ضريبة الفرع'
      when 'branch.logo_changed' then 'تغيير شعار الفرع'
      when 'branch.image_changed' then 'تغيير صورة الفرع'
      when 'branch.archived' then 'أرشفة فرع'
      when 'branch.restored' then 'استعادة فرع'
      when 'block.created' then 'إنشاء بلوك'
      when 'block.updated' then 'تعديل بلوك'
      when 'block.archived' then 'أرشفة بلوك'
      when 'block.restored' then 'استعادة بلوك'
      when 'floor.created' then 'إنشاء طابق'
      when 'floor.updated' then 'تعديل طابق'
      when 'floor.archived' then 'أرشفة طابق'
      when 'floor.restored' then 'استعادة طابق'
      when 'room.created' then 'إنشاء وحدة'
      when 'room.updated' then 'تعديل وحدة'
      when 'room.archived' then 'أرشفة وحدة'
      when 'room.restored' then 'استعادة وحدة'
      when 'room_category.created' then 'إنشاء نوع وحدة'
      when 'room_category.updated' then 'تعديل نوع وحدة'
      when 'room_category.archived' then 'أرشفة نوع وحدة'
      when 'room_category.restored' then 'استعادة نوع وحدة'
      when 'facility.created' then 'إنشاء مرفق'
      when 'facility.updated' then 'تعديل مرفق'
      when 'facility.archived' then 'أرشفة مرفق'
      when 'facility.restored' then 'استعادة مرفق'
      when 'task_type.created' then 'إنشاء نوع مهمة'
      when 'task_type.updated' then 'تعديل نوع مهمة'
      when 'task_type.archived' then 'أرشفة نوع مهمة'
      when 'task_type.restored' then 'استعادة نوع مهمة'
      when 'service.created' then 'إنشاء خدمة'
      when 'service.updated' then 'تعديل خدمة'
      when 'service.archived' then 'أرشفة خدمة'
      when 'service.restored' then 'استعادة خدمة'
      when 'source.enabled' then 'تفعيل مصدر حجز'
      when 'source.disabled' then 'تعطيل مصدر حجز'
      when 'staff_invited' then 'دعوة موظف'
      when 'staff.activated' then 'تفعيل موظف'
      when 'staff.deactivated' then 'إيقاف موظف'
      when 'staff.role_changed' then 'تغيير دور موظف'
      when 'staff.updated' then 'تعديل بيانات موظف'
      when 'staff.signed_out' then 'تسجيل خروج إجباري'
      when 'demo_owner_bootstrap' then 'إنشاء مالك نسخة العرض'
      when 'data_purge_executed' then 'تنفيذ تفريغ بيانات'
      when 'ai_proposal.executed' then 'تنفيذ اقتراح مساعد العمليات'
      when 'ai_settings_updated' then 'تعديل إعدادات الذكاء الاصطناعي'
      when 'knowledge.created' then 'إضافة إجابة إلى قاعدة المعرفة'
      when 'knowledge.updated' then 'تعديل إجابة في قاعدة المعرفة'
      when 'knowledge.archived' then 'أرشفة إجابة من قاعدة المعرفة'
      when 'knowledge.restored' then 'استعادة إجابة في قاعدة المعرفة'
      when 'unanswered.ignored' then 'تجاهل سؤال بلا إجابة'
      when 'unanswered.open' then 'إعادة فتح سؤال بلا إجابة'
      when 'conversation_taken' then 'استلام المحادثة من المساعد'
      when 'conversation_returned_to_assistant' then 'إعادة المحادثة إلى المساعد'
      when 'whatsapp_channel_updated' then 'تعديل إعداد واتساب الفرع'
      when 'permissions.updated' then 'تعديل مصفوفة الصلاحيات'
      when 'permissions.reset' then 'إعادة مصفوفة الصلاحيات إلى المعتمدة'
      when 'organization.updated' then 'تعديل بيانات المنشأة'
      else null
    end,
    fn_audit_removal_label(p_action),
    case when position('.' in p_action) > 1 then
      coalesce(case split_part(p_action, '.', 2)
        when 'created' then 'إنشاء' when 'updated' then 'تعديل' when 'archived' then 'أرشفة' when 'restored' then 'استعادة'
        when 'enabled' then 'تفعيل' when 'disabled' then 'تعطيل' when 'cancelled' then 'إلغاء' when 'completed' then 'إتمام'
        when 'started' then 'بدء' when 'assigned' then 'إسناد' when 'issued' then 'إصدار' when 'edited' then 'تعديل'
        when 'corrected' then 'تصحيح' when 'confirmed' then 'تأكيد' when 'approved' then 'اعتماد' when 'rejected' then 'رفض'
        when 'viewed' then 'عرض' when 'changed' then 'تغيير' when 'executed' then 'تنفيذ' when 'marked' then 'تعليم' when 'settled' then 'تسوية'
        else null end, replace(split_part(p_action, '.', 2), '_', ' '))
      || ' — ' || fn_audit_entity_label(split_part(p_action, '.', 1))
    end,
    replace(p_action, '_', ' '));
$$;