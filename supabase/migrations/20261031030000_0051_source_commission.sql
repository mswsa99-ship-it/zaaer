-- 0051 — the commission of each booking source, set by the owner (owner's decision, 31 October 2026).
--
-- Zaaer kept a commission per source (Agoda.com and جذر إن at 15%, the rest 0). The system had none: a platform's
-- deposit that came in short by its commission always needed a typed reason. Now:
--   * booking_sources.commission_bp: the source's commission in basis points (1500 = 15%, 0–100%), changed only through
--     fn_admin_set_source_commission (capability «definitions»: the owner and the managers), audited with before/after;
--   * Agoda.com and جذر إن start at 15%, as in Zaaer; the others at 0;
--   * matching a platform's deposit expects the gross less the commission: the payout keeps the rate and the commission
--     it used, and its difference is now what arrived against that net. A reason is asked only for a difference from
--     the net. Earlier payouts keep their rows: commission 0, difference as it was.

alter table booking_sources add column if not exists commission_bp int not null default 0;
do $c$ begin
  if not exists (select 1 from pg_constraint where conname = 'booking_source_commission_valid') then
    alter table booking_sources add constraint booking_source_commission_valid check (commission_bp between 0 and 10000);
  end if;
end $c$;
alter table platform_payouts add column if not exists commission_bp int not null default 0;
alter table platform_payouts add column if not exists commission_halalas bigint not null default 0;

update booking_sources set commission_bp = 1500 where code in ('agoda', 'jathr_inn') and commission_bp = 0;

create or replace function fn_admin_set_source_commission(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s booking_sources%rowtype; v_bp int;
begin
  perform fn_require_cap('definitions');
  if coalesce(p->>'commission_bp', '') !~ '^[0-9]{1,5}$' then raise exception 'VALIDATION: commission'; end if;
  v_bp := (p->>'commission_bp')::int;
  if v_bp > 10000 then raise exception 'VALIDATION: commission'; end if;
  select * into s from booking_sources where id = (p->>'id')::uuid and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if s.commission_bp = v_bp then return jsonb_build_object('ok', true, 'changed', false); end if;
  update booking_sources set commission_bp = v_bp where id = s.id;
  perform fn_audit_change(null, 'source.commission_updated', 'booking_source', s.id,
    jsonb_build_object('code', s.code, 'commission_bp', s.commission_bp), jsonb_build_object('code', s.code, 'commission_bp', v_bp),
    nullif(trim(coalesce(p->>'reason', '')), ''));
  return jsonb_build_object('ok', true, 'changed', true);
end $$;
revoke all on function fn_admin_set_source_commission(jsonb) from public, anon;
grant execute on function fn_admin_set_source_commission(jsonb) to authenticated;

CREATE OR REPLACE FUNCTION public.fn_platform_unsettled(p_branch uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform fn_require_cap('platform.payouts');
  perform fn_require_branch(p_branch);
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', v.id, 'number', v.number, 'kind', v.kind, 'amount_halalas', v.amount_halalas,
                                        'signed_halalas', case when v.kind = 'receipt' then v.amount_halalas else -v.amount_halalas end,
                                        'occurred_at', v.occurred_at, 'reservation_id', r.id, 'internal_ref', r.internal_ref, 'external_ref', r.external_ref,
                                        'check_in', r.check_in, 'source_id', r.source_id, 'source_name', s.name, 'commission_bp', coalesce(s.commission_bp, 0)) order by s.name, v.occurred_at)
    from financial_vouchers v join reservations r on r.id = v.reservation_id left join booking_sources s on s.id = r.source_id
    where v.branch_id = p_branch and v.method = 'ota_deferred' and v.status = 'approved' and v.payout_id is null and v.kind in ('receipt', 'refund')), '[]'::jsonb);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_platform_payout_confirm(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_branch uuid := (p->>'branch_id')::uuid; v_source uuid := (p->>'source_id')::uuid; ids uuid[]; n int; good int; expected bigint; received bigint;
        v_bp int; v_commission bigint; v_net bigint;
        acc uuid; pay platform_payouts%rowtype; v_note text := nullif(trim(coalesce(p->>'note', '')), ''); v_ref text := nullif(trim(coalesce(p->>'reference', '')), '');
begin
  perform fn_require_cap('platform.payouts');
  perform fn_require_branch(v_branch);
  ids := array(select (x)::uuid from jsonb_array_elements_text(coalesce(p->'voucher_ids', '[]'::jsonb)) x);
  n := coalesce(array_length(ids, 1), 0);
  if n = 0 then raise exception 'VALIDATION: vouchers'; end if;
  received := fn_parse_halalas(p->>'received_halalas');
  if v_ref is null then raise exception 'VALIDATION: reference_required'; end if;
  if (p->>'received_on') is null or (p->>'received_on')::date > fn_branch_today(v_branch) then raise exception 'VALIDATION: received_on'; end if;
  acc := fn_voucher_account(v_branch, 'bank_transfer', (p->>'account_id')::uuid);
  -- lock the vouchers; every one must be an unmatched deferred payment of this branch and platform
  perform 1 from financial_vouchers where id = any(ids) for update;
  select count(*), coalesce(sum(case when v.kind = 'receipt' then v.amount_halalas else -v.amount_halalas end), 0) into good, expected
  from financial_vouchers v join reservations r on r.id = v.reservation_id
  where v.id = any(ids) and v.branch_id = v_branch and v.method = 'ota_deferred' and v.status = 'approved' and v.payout_id is null
    and v.kind in ('receipt', 'refund') and r.source_id = v_source;
  if good <> n then raise exception 'VALIDATION: payout_vouchers'; end if;
  -- 0051: the source's commission is expected; only what differs from the net (gross − commission) needs a reason
  select coalesce(commission_bp, 0) into v_bp from booking_sources where id = v_source;
  v_commission := round(expected::numeric * coalesce(v_bp, 0) / 10000)::bigint;
  v_net := expected - v_commission;
  if received <> v_net and v_note is null then raise exception 'VALIDATION: note_required'; end if;
  insert into platform_payouts(organization_id, branch_id, source_id, account_id, expected_halalas, commission_bp, commission_halalas, received_halalas, difference_halalas, voucher_count, received_on, reference, note, created_by)
  values ((select organization_id from branches where id = v_branch), v_branch, v_source, acc, expected, coalesce(v_bp, 0), v_commission, received, received - v_net, n, (p->>'received_on')::date, v_ref, v_note, fn_staff_id())
  returning * into pay;
  update financial_vouchers set payout_id = pay.id where id = any(ids);
  perform fn_audit_change(v_branch, 'platform.payout_confirmed', 'platform_payout', pay.id, null, to_jsonb(pay), v_note);
  return jsonb_build_object('ok', true, 'payout', to_jsonb(pay));
end $function$;

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
      when 'source.commission_updated' then 'تعديل عمولة مصدر حجز'
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
