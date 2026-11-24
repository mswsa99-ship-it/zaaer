-- 0125 history-detail permission (user approval 2026-11-24 20:03 on the 19:59 proposal): before/after details in the audit log
-- and in the reservation history become a separate, owner-granted sensitive permission for INDIVIDUAL-mode non-owner accounts only.
-- Scope: audit log + reservation history details. NOT payouts, vouchers, force_logout or finance full rights (B8 unchanged).
-- Owner and legacy accounts: unchanged (fn_history_details_allowed returns the caller's existing legacy decision).
-- Page, branch, security-category and row guards are untouched; only the details payload is gated. Each surface keeps its own
-- page guard (audit log: audit.log / /admin/audit-logs; reservation detail: /staff/reservations view); this helper checks only the
-- explicit sensitive grant, so the grant works on whichever surface the account is allowed to open.
-- An individual account without the grant still sees action / time / actor and the reason, but not before/after values.
begin;
create or replace function public.fn_history_details_allowed(p_legacy_allowed boolean) returns boolean
language sql stable security definer set search_path = public as $$
  select case when fn_current_role() = 'owner' then true
              when fn_user_access_mode() = 'individual' then exists (
                select 1 from staff_page_access a
                 where a.staff_id = fn_staff_id() and a.organization_id = fn_user_org_id() and a.enabled
                   and jsonb_typeof(a.sensitive_grants) = 'array' and a.sensitive_grants ? 'history.details')
                and exists (select 1 from fn_permission_catalog() c where c.code = 'history.details' and not c.locked)
              else coalesce(p_legacy_allowed, false) end
$$;
revoke all on function public.fn_history_details_allowed(boolean) from public, anon;
grant execute on function public.fn_history_details_allowed(boolean) to authenticated;

create or replace function fn_permission_catalog()
 RETURNS TABLE(code text, label text, area text, sort integer, default_roles role_code[], full_roles role_code[], limit_note text, locked boolean)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
as $$
  values
    ('res.create', 'إنشاء حجز مفرد أو جماعي', 'الحجوزات', 10, '{owner,manager,supervisor}'::role_code[], '{owner,manager}'::role_code[], 'سعر أقل من المعروض يحتاج المدير', false),
    ('disc.before', 'خصم قبل الوصول (ضمن أدنى سعر وأقصى نسبة)', 'الحجوزات', 20, '{owner,manager,supervisor}', null, null, false),
    ('disc.after', 'خصم بعد الوصول أو فوق الحدين', 'الحجوزات', 30, '{owner,manager}', null, null, false),
    ('price.adjust', 'تسوية سعر بسبب (تصفير رصيد، مغادرة مبكرة)', 'الحجوزات', 40, '{owner,manager}', null, null, false),
    ('charges.add', 'رسوم وخدمات إضافية وخروج متأخر برسوم', 'الحجوزات', 50, '{owner,manager,supervisor}', null, null, false),
    ('stay.extend', 'تمديد يدوي (يُمنع مع ليلة غير مدفوعة إلا بسبب)', 'الحجوزات', 60, '{owner,manager,supervisor}', '{owner,manager}', 'لا يقصّر إقامة أسبوعية أو شهرية', false),
    ('room.assign', 'تخصيص وحدة ونقلها', 'الحجوزات', 70, '{owner,manager,supervisor}', null, null, false),
    ('res.cancel', 'إلغاء حجز (وبرقم المنصة دون رد) وعدم حضور', 'الحجوزات', 80, '{owner,manager,supervisor}', null, null, false),
    ('res.undo_cancel', 'التراجع عن الإلغاء خلال ساعة', 'الحجوزات', 90, '{owner,manager}', null, null, false),
    ('hold.set', 'وضع حظر على حجز', 'الحجوزات', 100, '{owner,manager,supervisor}', null, null, false),
    ('hold.lift', 'رفع الحظر عن حجز', 'الحجوزات', 110, '{owner,manager}', null, null, false),
    ('guest.enter', 'إدخال بيانات الضيف من الوثيقة الأصلية وتصحيحها بسبب', 'الضيوف', 120, '{owner,manager,supervisor}', null, null, false),
    ('identity.approve', 'اعتماد الهوية', 'الضيوف', 130, '{owner,manager,supervisor}', null, null, false),
    ('guest.ban', 'حظر ضيف ورفعه', 'الضيوف', 140, '{owner,manager}', null, null, false),
    ('guest.rate', 'تقييم الضيف وملاحظته الداخلية', 'الضيوف', 150, '{owner,manager,supervisor}', null, null, false),
    ('shomoos', 'تأكيد شموس (المرجع والتسجيل والقبول)', 'الإقامة', 160, '{owner,manager,supervisor}', null, null, false),
    ('checkin', 'تسجيل الوصول (ومهلة السداد والإقرار الورقي)', 'الإقامة', 170, '{owner,manager,supervisor}', null, null, false),
    ('code.deliver', 'تسليم الرمز (الوحدات ذات الصندوق)', 'الإقامة', 180, '{owner,manager,supervisor}', null, null, false),
    ('checkin.undo', 'التراجع عن الوصول خلال 30 دقيقة', 'الإقامة', 190, '{owner,manager}', null, null, false),
    ('checkout', 'تسجيل المغادرة (المتبقي صفر، بلا تجاوز لأحد)', 'الإقامة', 200, '{owner,manager,supervisor}', null, null, false),
    ('stay.reopen', 'إعادة فتح حجز غادر خلال ساعتين', 'الإقامة', 210, '{owner,manager}', null, null, false),
    ('inspection', 'فحص المغادرة', 'الإقامة', 220, '{owner,manager,supervisor,housekeeping}', null, null, false),
    ('voucher.receipt', 'سند قبض إيجار أو تأمين', 'المال', 230, '{owner,manager,supervisor,finance}', null, null, false),
    ('voucher.refund', 'رد مبلغ إقامة', 'المال', 240, '{owner,manager,finance}', null, null, false),
    ('deposit.refund', 'رد التأمين (بعد فحص المغادرة فقط)', 'المال', 250, '{owner,manager,supervisor,finance}', null, null, false),
    ('damage.charge', 'رسم ضرر وخصمه من التأمين', 'المال', 260, '{owner,manager,supervisor}', null, null, false),
    ('deposit.apply', 'خصم من التأمين بسبب لتصفير الرصيد', 'المال', 270, '{owner,manager,supervisor,finance}', null, null, false),
    ('voucher.correct', 'تصحيح سند (إلغاء وإصدار بسبب)', 'المال', 280, '{owner,manager,supervisor}', '{owner,manager}', 'سنداته خلال 24 ساعة', false),
    ('voucher.cancel', 'إلغاء سند', 'المال', 290, '{owner,manager}', null, null, false),
    ('pos.settle', 'تسوية الشبكة اليومية', 'المال', 300, '{owner,manager,supervisor,finance}', null, null, false),
    ('platform.payouts', 'مطابقة الآجل عبر المنصات الشهرية', 'المال', 310, '{owner,manager,finance}', '{owner,manager}', 'دون إلغاء إيداع مؤكد', false),
    ('invoice.issue', 'إصدار فاتورة جزئية', 'المال', 320, '{owner,manager,supervisor,finance}', null, null, false),
    ('invoice.edit', 'تعديل فاتورة بسبب (ينبّه الإدارة)', 'المال', 330, '{owner,manager,supervisor,finance}', null, null, false),
    ('day.close', 'إقفال اليوم: العدّ والفروق والإرسال والتعديل خلال المهلة وطلب التعديل بعدها', 'المال', 334, '{owner,manager,supervisor,finance}', null, null, false),
    ('day.close.approve', 'الموافقة على طلب تعديل إقفال بعد مهلته', 'المال', 336, '{owner,manager}', null, null, false),
    ('expense.create', 'سند صرف بتصنيفه ومرفقه من صندوق الفرع أو حسابه البنكي', 'المال', 337, '{owner,manager,supervisor,finance}', null, null, false),
    ('expense.cancel', 'إلغاء سند صرف بسبب', 'المال', 338, '{owner,manager}', null, null, false),
    ('ledger.view', 'دفتر حركة الصندوق والحساب البنكي برصيده الجاري', 'المال', 339, '{owner,manager,supervisor,finance}', null, null, false),
    ('rates', 'تقويم الأسعار وأسعار النوع (أساسي، أسبوعي، شهري، أدنى)', 'الإعدادات', 340, '{owner,manager}', null, null, false),
    ('branch.tax', 'نسبة الضريبة', 'الإعدادات', 350, '{owner}', null, null, false),
    ('branch.settings', 'إعدادات الفرع الأخرى (التأمين، أقصى خصم، الموقع، الشعار، رابط المنصة…)', 'الإعدادات', 360, '{owner,manager}', null, null, false),
    ('cash_accounts', 'الصناديق والحسابات البنكية', 'الإعدادات', 370, '{owner,manager}', null, null, false),
    ('definitions', 'الوحدات والأنواع والمرافق والخدمات وأنواع المهام ومصادر الحجز', 'الإعدادات', 380, '{owner,manager}', null, null, false),
    ('policies', 'السياسات', 'الإعدادات', 390, '{owner,manager}', null, null, false),
    ('knowledge', 'قاعدة معرفة المساعد', 'الإعدادات', 400, '{owner,manager,supervisor}', null, null, false),
    ('task.work', 'إنشاء مهمة وبدؤها وإتمامها', 'خدمة الغرف', 410, '{owner,manager,supervisor,housekeeping}', '{owner,manager,supervisor,finance}', 'مهامه المسندة إليه', false),
    ('task.manage', 'إسناد مهمة وإلغاؤها', 'خدمة الغرف', 420, '{owner,manager,supervisor}', null, null, false),
    ('cleanliness', 'تغيير النظافة يدويًا (حر)', 'خدمة الغرف', 430, '{owner,manager,supervisor,housekeeping}', null, null, false),
    ('keybox.code', 'تغيير رمز الصندوق وتجربته', 'خدمة الغرف', 440, '{owner,manager,supervisor,housekeeping}', null, null, false),
    ('maintenance.create', 'البلاغات: إنشاء', 'خدمة الغرف', 450, '{owner,manager,supervisor,housekeeping}', null, null, false),
    ('maintenance.resolve', 'البلاغات: حلّ', 'خدمة الغرف', 460, '{owner,manager,supervisor}', null, null, false),
    ('conversation.take', 'تولّي محادثة واتساب', 'المحادثات', 470, '{owner,manager,supervisor}', null, null, false),
    ('staff.manage', 'دعوة موظف وتعديله وتفعيله وتعطيله', 'الموظفون والأمان', 480, '{owner}', '{owner}', 'لا يمسّ حساب المالك', false),
    ('staff.force_logout', 'خروج إجباري', 'الموظفون والأمان', 490, '{owner,manager}', '{owner}', 'غير المالك والمدير', false),
    ('security', 'السجل الأمني ومسح البيانات وإعدادات المساعد وواتساب', 'الموظفون والأمان', 500, '{owner}', null, null, false),
    ('admin.permissions', 'تعديل مصفوفة الصلاحيات', 'الموظفون والأمان', 505, '{owner}', null, null, true),
    ('review.list', 'قائمة «بحاجة لمراجعة وتدقيق» والتأشير عليها', 'التقارير والسجل', 510, '{owner}', null, null, false),
    ('reports.finance', 'التقارير المالية وتقرير الخصومات', 'التقارير والسجل', 520, '{owner,manager,supervisor,finance}', '{owner,manager,finance}', 'ملخص الخصومات فقط', false),
    ('accounts.view', 'دليل الحسابات والقيود وميزان المراجعة وقائمة الدخل والميزانية', 'التقارير والسجل', 524, '{owner,manager,finance}', null, null, false),
    ('accounts.close_month', 'قفل الشهر المحاسبي وفتحه', 'التقارير والسجل', 526, '{owner}', null, null, false),
    ('bank.view', 'الرسائل البنكية والحركات المستخرجة منها', 'التقارير والسجل', 527, '{owner,manager,finance}', null, null, false),
    ('bank.manage', 'بريد البنك وقواعد قراءة الرسائل وإعادة قراءتها', 'التقارير والسجل', 528, '{owner}', null, null, false),
    ('reports.identities_usage', 'تقرير الهويات المعتمدة من المكتب وتقرير الاستعمال', 'التقارير والسجل', 530, '{owner}', null, null, false),
    ('audit.log', 'سجل الإجراءات', 'التقارير والسجل', 540, '{owner,manager,supervisor}', '{owner,manager}', 'بلا تفاصيل التغييرات', false),
    ('history.details', 'تفاصيل قبل وبعد التعديل في سجل الإجراءات وتاريخ الحجز (للحسابات الفردية فقط، بمنحة صريحة)', 'التقارير والسجل', 545, '{owner}', null, null, false);
$$;

CREATE OR REPLACE FUNCTION public.fn_audit_list(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare q jsonb := coalesce(p, '{}'::jsonb); org uuid := fn_user_org_id(); tz text; lim int; off int; is_owner boolean; is_mgmt boolean;
        v_from date; v_to date; v_branch uuid; v_actor uuid; v_action text; v_prefix boolean; v_entity text; v_entity_id uuid; v_corr text; v_cat text; v_result text; v_q text; v_source text;
        total bigint; rows jsonb;
begin
  perform fn_require_cap('audit.log');
  is_owner := fn_has_role('owner'); is_mgmt := fn_cap_full('audit.log');
  v_branch := (q->>'branch_id')::uuid;
  if v_branch is not null then perform fn_require_branch(v_branch); end if;
  tz := coalesce((select timezone from branches where id = v_branch), (select timezone from branches where organization_id = org order by created_at limit 1), 'Asia/Riyadh');
  v_from := (q->>'from')::date; v_to := (q->>'to')::date;
  if v_from is not null and v_to is not null and v_to < v_from then raise exception 'VALIDATION: period'; end if;
  v_actor := (q->>'actor_id')::uuid; v_action := nullif(q->>'action', ''); v_prefix := coalesce((q->>'action_prefix')::boolean, false);
  v_entity := nullif(q->>'entity_type', ''); v_entity_id := (q->>'entity_id')::uuid; v_corr := nullif(q->>'correlation_id', '');
  v_cat := nullif(q->>'category', ''); v_result := nullif(q->>'result', ''); v_q := nullif(trim(coalesce(q->>'q', '')), ''); v_source := nullif(q->>'source', '');
  lim := least(greatest(coalesce((q->>'limit')::int, 50), 1), 500); off := greatest(coalesce((q->>'offset')::int, 0), 0);

  with x as (
    select e.* from audit_events e
    where e.organization_id = org
      and (e.category <> 'security' or fn_can('security'))
      and (is_owner or e.branch_id is null or e.branch_id in (select fn_user_branch_ids()))
      and (v_branch is null or e.branch_id = v_branch)
      and (v_from is null or (e.created_at at time zone tz)::date >= v_from)
      and (v_to is null or (e.created_at at time zone tz)::date <= v_to)
      and (v_actor is null or e.actor_id = v_actor)
      and (v_action is null or (v_prefix and e.action like v_action || '%') or (not v_prefix and e.action = v_action))
      and (v_entity is null or e.entity_type = v_entity)
      and (v_entity_id is null or e.entity_id = v_entity_id)
      and (v_corr is null or e.correlation_id = v_corr)
      and (v_cat is null or e.category = v_cat)
      and (v_result is null or e.result = v_result)
      and (v_source is null or e.source = v_source)
      and (v_q is null or e.action ilike '%' || v_q || '%' or coalesce(e.entity_type, '') ilike '%' || v_q || '%' or coalesce(e.correlation_id, '') = v_q
           or fn_audit_action_label(e.action) ilike '%' || v_q || '%' or coalesce(e.entity_id::text, '') = v_q)
  )
  select count(*), coalesce((select jsonb_agg(jsonb_build_object(
           'id', y.id, 'created_at', y.created_at, 'action', y.action, 'action_label', fn_audit_action_label(y.action),
           'entity_type', y.entity_type, 'entity_label', fn_audit_entity_label(y.entity_type), 'entity_id', y.entity_id, 'entity_ref', fn_audit_entity_ref(y.entity_type, y.entity_id),
           'actor_id', y.actor_id, 'actor_name', case when y.actor_id is not null then (select full_name from staff_profiles where id = y.actor_id)
                                                      when y.actor_type = 'guest' then 'ضيف' when y.actor_type = 'user' then 'مستخدم' else 'النظام' end,
           'actor_type', y.actor_type, 'source', y.source, 'result', y.result, 'category', y.category, 'correlation_id', y.correlation_id,
           'branch_id', y.branch_id, 'branch_name', (select name_ar from branches where id = y.branch_id),
           'reason', y.details->>'reason', 'details', case when fn_history_details_allowed(is_mgmt) then y.details end) order by y.created_at desc, y.id desc)
         from (select * from x order by created_at desc, id desc limit lim offset off) y), '[]'::jsonb)
    into total, rows from x;
  return jsonb_build_object('total', total, 'rows', rows, 'limit', lim, 'offset', off, 'tz', tz);
end $function$

;

CREATE OR REPLACE FUNCTION public.fn_reservation_detail__impl(p_reservation uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when r.branch_id in (select fn_user_branch_ids()) then jsonb_build_object(
    'reservation', case when fn_sees_money() then to_jsonb(r) - 'notes'
                        else to_jsonb(r) - 'notes' - 'total_halalas' - 'paid_halalas' - 'rent_amount_halalas' - 'discount_halalas' - 'addons_halalas' - 'taxes_halalas'
                             - 'balance_due_halalas' - 'deposit_balance_halalas' - 'refunded_halalas' - 'nightly_rate_halalas' - 'payment_status' - 'company_name' - 'gov_registration_ref'
                             - 'platform_collects' end,
    'notes', r.notes,
    'source', (select jsonb_build_object('name', name, 'code', code, 'kind', kind) from booking_sources where id = r.source_id),
    'category', (select name_ar from room_categories where id = r.room_category_id),
    'room', (select jsonb_build_object('id', id, 'room_number', room_number, 'status', status, 'cleanliness', cleanliness) from rooms where id = r.room_id),
    'guests', case when fn_sees_money() then (select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'is_primary', g.is_primary, 'full_name', g.full_name,
                 'identity_type', g.identity_type, 'identity_number_last4', g.identity_number_last4, 'nationality', g.nationality,
                 'phone', case when fn_has_role('owner','manager','supervisor') then g.phone end, 'relationship', g.relationship, 'birth_date', case when fn_has_role('owner','manager','supervisor') then g.birth_date end,
                 'verification_status', g.verification_status, 'data_submitted', g.data_submitted, 'entry_path', g.entry_path,
                 'verified_at', g.verified_at, 'verified_by', (select full_name from staff_profiles where id = g.verified_by),
                 'profile_id', g.guest_profile_id,
                 'profile_mismatch', exists (select 1 from guest_profiles gp where gp.id = g.guest_profile_id and gp.identity_fingerprint is not null
                                              and g.identity_fingerprint is not null and gp.identity_fingerprint <> g.identity_fingerprint)) order by g.is_primary desc, g.created_at), '[]'::jsonb)
               from reservation_guests g where g.reservation_id = r.id) end,
    'bans', case when fn_has_role('owner','manager','supervisor') then fn_reservation_ban_matches(r.id) end,
    'guest_profile', case when fn_has_role('owner','manager','supervisor') then (select jsonb_build_object('id', gp.id, 'rating', gp.rating, 'rating_note', gp.rating_note,
                        'rated_at', gp.rated_at, 'rated_by', (select full_name from staff_profiles where id = gp.rated_by),
                        'stays', (select count(distinct g2.reservation_id) from reservation_guests g2 where g2.guest_profile_id = gp.id))
                      from reservation_guests g join guest_profiles gp on gp.id = g.guest_profile_id where g.reservation_id = r.id and g.is_primary order by g.created_at limit 1) end,
    'hold', case when coalesce(r.security_hold, false) then jsonb_build_object('reason', r.security_hold_reason, 'at', r.security_hold_at,
                                                                              'by', (select full_name from staff_profiles where id = r.security_hold_by)) end,
    'platform', case when exists (select 1 from booking_sources s where s.id = r.source_id and s.kind = 'external') then jsonb_build_object(
                  'booked_on', r.platform_booked_on, 'collects', case when fn_sees_money() then r.platform_collects end,
                  'verified_at', r.platform_verified_at, 'verified_by', (select full_name from staff_profiles where id = r.platform_verified_by),
                  'cancel_reference', r.cancel_reference) end,
    'acknowledgements', case when fn_sees_money() then fn_ack_list(r.id) end,
    'allocations', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'room_number', rm.room_number, 'from_date', a.from_date, 'to_date', a.to_date, 'status', a.status, 'reason', a.reason, 'created_at', a.created_at) order by a.from_date, a.created_at), '[]'::jsonb)
                    from reservation_allocations a join rooms rm on rm.id = a.room_id where a.reservation_id = r.id),
    'charges', case when fn_sees_money() then
                 (select coalesce(jsonb_agg(to_jsonb(c) || jsonb_build_object('invoiced_halalas', coalesce((
                      select sum((l->>'amount_halalas')::bigint) from invoices i cross join lateral jsonb_array_elements(i.snapshot->'lines') l
                       where i.reservation_id = r.id and i.status = 'issued' and (l->>'charge_id')::uuid = c.id), 0)) order by c.created_at), '[]'::jsonb)
                    from reservation_charges c where c.reservation_id = r.id) end,
    'vouchers', case when fn_sees_money() then
                 (select coalesce(jsonb_agg((to_jsonb(v) - 'content_hash') || jsonb_build_object(
                      'created_by_name', (select full_name from staff_profiles where id = v.created_by),
                      'original_number', (select number from financial_vouchers o where o.id = v.original_voucher_id),
                      'replaced_by_number', (select x.number from financial_vouchers x where x.original_voucher_id = v.id order by x.created_at desc limit 1))
                    order by v.occurred_at), '[]'::jsonb) from financial_vouchers v where v.reservation_id = r.id) end,
    'invoices', case when fn_sees_money() then
                 (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'number', i.number, 'status', i.status, 'scope', i.scope, 'origin', i.origin, 'version', i.version,
                      'subtotal_halalas', i.subtotal_halalas, 'tax_halalas', i.tax_halalas, 'total_halalas', i.total_halalas,
                      'issued_at', i.issued_at, 'issued_by', (select full_name from staff_profiles where id = i.issued_by),
                      'updated_at', i.updated_at, 'updated_by', (select full_name from staff_profiles where id = i.updated_by),
                      'cancelled_at', i.cancelled_at, 'cancel_reason', i.cancel_reason,
                      'period_from', i.period_from, 'period_to', i.period_to, 'bill_to', i.bill_to, 'lines', i.snapshot->'lines', 'versions', i.versions)
                    order by i.issued_at), '[]'::jsonb) from invoices i where i.reservation_id = r.id) end,
    'invoicing', case when fn_sees_money() then jsonb_build_object('uninvoiced_halalas', fn_uninvoiced_value(r.id)) end,
    'finance', case when fn_sees_money() then fn_reservation_finance_internal(r.id) end,
    'history', case when fn_has_role('owner','manager','supervisor') then (select coalesce(jsonb_agg(jsonb_build_object('action', e.action, 'at', e.created_at, 'actor', (select full_name from staff_profiles where id = e.actor_id), 'details', case when fn_history_details_allowed(true) then e.details else jsonb_build_object('reason', e.details->'reason') end) order by e.created_at desc), '[]'::jsonb)
                from (select * from audit_events where entity_id = r.id order by created_at desc limit 50) e) end
  ) end
  from reservations r where r.id = p_reservation;
$function$

;

insert into permission_page_map(code, page, action, sensitive, any_write)
  values ('history.details', '/staff/reservations', 'view', true, false)
  on conflict (code) do nothing;

commit;
