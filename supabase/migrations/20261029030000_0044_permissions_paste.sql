-- =====================================================================
-- 0044 — the owner's paste for the permissions matrix (decision 71): pasted in the Supabase SQL editor after 0043.
--   * The log names the matrix's changes («تعديل مصفوفة الصلاحيات»، «إعادة مصفوفة الصلاحيات إلى المعتمدة») and the
--     organisation's rename («تعديل بيانات المنشأة»); «استعمال القدرات» counts the matrix as core administration.
--   * The codes written when an unused definition is removed outright (0015) — the only ones spelled with the word the
--     SQL tools refuse — move into two small functions of their own (fn_audit_removal_label,
--     fn_capability_removal_actions). The dictionary and the catalogue themselves no longer carry that word, so a
--     future addition is an ordinary migration, not a paste. Word for word the same labels as before;
--     src/lib/auditLabels.ts and src/lib/capabilityCatalog.ts are the same lists (tests/unit/audit_labels.test.ts).
--   Running it twice changes nothing.
-- =====================================================================

create or replace function fn_audit_entity_label(p_entity text) returns text
language sql immutable set search_path = public as $$
  select case when p_entity is null then '—' else coalesce(
    case p_entity
      when 'reservation' then 'حجز'
      when 'reservation_guest' then 'ضيف'
      when 'guest_profile' then 'ملف ضيف'
      when 'financial_voucher' then 'سند'
      when 'voucher' then 'سند'
      when 'invoice' then 'فاتورة'
      when 'room' then 'وحدة'
      when 'room_category' then 'نوع وحدة'
      when 'facility' then 'مرفق'
      when 'housekeeping_task' then 'مهمة'
      when 'task_type' then 'نوع مهمة'
      when 'service_definition' then 'خدمة'
      when 'branch' then 'فرع'
      when 'block' then 'بلوك'
      when 'floor' then 'طابق'
      when 'staff_profile' then 'موظف'
      when 'cash_account' then 'صندوق أو حساب'
      when 'booking_source' then 'مصدر حجز'
      when 'service' then 'خدمة'
      when 'keybox' then 'صندوق مفتاح'
      when 'knowledge_entry' then 'إجابة'
      when 'unanswered_question' then 'سؤال بلا إجابة'
      when 'ai_settings' then 'إعدادات الذكاء الاصطناعي'
      when 'ai_proposal' then 'اقتراح المساعد'
      when 'ai_action_proposal' then 'اقتراح المساعد'
      when 'conversation' then 'محادثة'
      when 'review_items' then 'بند مراجعة'
      when 'pos_settlement' then 'تسوية شبكة'
      when 'platform_payout' then 'إيداع منصة'
      when 'review_item' then 'بند مراجعة'
      when 'maintenance_ticket' then 'بلاغ صيانة'
      when 'whatsapp_channel' then 'واتساب الفرع'
      when 'organization' then 'المنشأة'
      when 'data_purge' then 'تفريغ بيانات'
      when 'rate_calendar' then 'تقويم الأسعار'
      when 'inventory_period' then 'فترة توفر'
      when 'release_rule' then 'قاعدة توفر'
      when 'released_slot' then 'توفر'
      when 'role_permissions' then 'مصفوفة الصلاحيات'
      else null
    end, replace(p_entity, '_', ' ')) end;
$$;

create or replace function fn_audit_removal_label(p_action text) returns text
language sql immutable set search_path = public as $$
  select case p_action
      when 'block.deleted' then 'حذف بلوك'
      when 'floor.deleted' then 'حذف طابق'
      when 'room.deleted' then 'حذف وحدة'
      when 'room_category.deleted' then 'حذف نوع وحدة'
      when 'facility.deleted' then 'حذف مرفق'
      when 'task_type.deleted' then 'حذف نوع مهمة'
      when 'service.deleted' then 'حذف خدمة'
      else case when position('.' in p_action) > 1 and split_part(p_action, '.', 2) = 'deleted'
                then 'حذف — ' || fn_audit_entity_label(split_part(p_action, '.', 1)) end
    end;
$$;

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

create or replace function fn_capability_removal_actions(p_code text) returns text[]
language sql immutable set search_path = public as $$
  select case p_code
    when 'admin.structure' then array['block.deleted', 'floor.deleted']
    when 'admin.rooms' then array['room.deleted']
    when 'admin.room_categories' then array['room_category.deleted']
    when 'admin.facilities' then array['facility.deleted']
    when 'admin.task_types' then array['task_type.deleted']
    when 'admin.services' then array['service.deleted']
    else '{}'::text[] end;
$$;

create or replace function fn_capability_catalog() returns table(code text, label text, area text, core boolean, coverage text, actions text[])
language sql immutable set search_path = public as $$
  select c.code, c.label, c.area, c.core, c.coverage, c.actions || fn_capability_removal_actions(c.code)
  from (values
    ('reservations.create', 'إنشاء حجز', 'الحجوزات', false, 'full', array['reservation.created']),
    ('reservations.cancel', 'إلغاء حجز وعدم حضور', 'الحجوزات', false, 'full', array['reservation.cancelled', 'reservation.no_show']),
    ('reservations.amend', 'تمديد وتبديل وتعديل الإجمالي', 'الحجوزات', false, 'full', array['reservation.departure_changed', 'reservation.room_switched', 'reservation.total_changed', 'reservation.service_added']),
    ('reservations.corrections', 'التصحيحات (التراجع عن الوصول والإلغاء وإعادة الفتح)', 'الحجوزات', false, 'full', array['reservation.check_in_undone', 'reservation.cancel_undone', 'reservation.stay_reopened', 'reservation.unclosed']),
    ('reservations.hold', 'الحظر على الحجز', 'الحجوزات', false, 'full', array['reservation.hold_set', 'reservation.hold_lifted']),
    ('reservations.platform_check', 'مطابقة المنصات', 'الحجوزات', false, 'full', array['reservation.platform_checked', 'reservation.platform_unchecked']),
    ('stay.check_in', 'تسجيل الوصول', 'الإقامة', false, 'full', array['reservation.checked_in', 'approve_checkin']),
    ('stay.shomoos', 'التسجيل في شموس', 'الإقامة', false, 'full', array['reservation.shomoos_registered', 'reservation.shomoos_accepted', 'confirm_gov_registration']),
    ('stay.payment_exception', 'مهلة السداد الاستثنائية', 'الإقامة', false, 'full', array['reservation.payment_exception']),
    ('stay.check_out', 'تسجيل المغادرة والإغلاق', 'الإقامة', false, 'full', array['reservation.checked_out', 'reservation.closed', 'checkout']),
    ('stay.inspection', 'فحص المغادرة ورسوم الضرر', 'الإقامة', false, 'full', array['reservation.inspected', 'reservation.damage_charged']),
    ('stay.summary', 'ملخص الإقامة وإقراره', 'الإقامة', false, 'partial', array['reservation.summary_signed', 'guest_summary_accepted']),
    ('guests.office_entry', 'إدخال بيانات الضيف من الوثيقة وتصحيحها', 'الضيوف', false, 'full', array['guest.entered_from_document', 'guest.corrected', 'approve_identity', 'reject_identity']),
    ('guests.self_entry', 'إدخال الضيف بياناته بنفسه', 'الضيوف', false, 'partial', array['guest_data_submitted']),
    ('guests.ban_rating', 'حظر الضيوف وتقييمهم', 'الضيوف', false, 'full', array['guest.banned', 'guest.unbanned', 'guest.rated']),
    ('money.receipts', 'سندات القبض والتأمين', 'المال', false, 'full', array['voucher.receipt_created', 'voucher.deposit_created', 'confirm_payment']),
    ('money.refunds', 'الاستردادات وتسوية التأمين', 'المال', false, 'full', array['voucher.refund_created', 'voucher.deposit_refund_created', 'voucher.deposit_apply_created']),
    ('money.corrections', 'إلغاء السندات وتصحيحها', 'المال', false, 'full', array['voucher.cancelled', 'voucher.corrected']),
    ('money.invoices', 'الفواتير', 'المال', false, 'full', array['invoice.issued', 'invoice.edited', 'invoice.cancelled']),
    ('money.pos_settlement', 'تسوية الشبكة', 'المال', false, 'full', array['pos.settled']),
    ('money.platform_payouts', 'إيداعات المنصات', 'المال', false, 'full', array['platform.payout_confirmed', 'platform.payout_cancelled']),
    ('money.review', 'قائمة المراجعة', 'المال', false, 'full', array['review.marked']),
    ('access.codes', 'تسليم رمز الدخول', 'الوصول', false, 'full', array['deliver_access_code', 'delivery_failed']),
    ('access.keybox', 'رموز صناديق المفاتيح', 'الوصول', false, 'full', array['rotate_keybox_code', 'keybox_field_tested', 'keybox.code_viewed']),
    ('housekeeping.tasks', 'المهام', 'خدمة الغرف', false, 'full', array['task.created', 'task.started', 'task.completed', 'task.cancelled', 'task.assigned', 'cleaning_completed']),
    ('housekeeping.cleanliness', 'تغيير النظافة يدويًا', 'خدمة الغرف', false, 'full', array['room.cleanliness_changed']),
    ('housekeeping.maintenance', 'بلاغات الصيانة', 'خدمة الغرف', false, 'full', array['maintenance_opened', 'maintenance_resolved']),
    ('admin.branches', 'الفروع وإعداداتها', 'الإدارة', true, 'full', array['branch.created', 'branch.updated', 'branch.money_defaults', 'branch.tax_changed', 'branch.logo_changed', 'branch.image_changed', 'branch.archived', 'branch.restored', 'organization.updated']),
    ('admin.structure', 'البلوكات والطوابق', 'الإدارة', true, 'full', array['block.created', 'block.updated', 'block.archived', 'block.restored', 'floor.created', 'floor.updated', 'floor.archived', 'floor.restored']),
    ('admin.rooms', 'الوحدات', 'الإدارة', true, 'full', array['room.created', 'room.updated', 'room.archived', 'room.restored']),
    ('admin.room_categories', 'أنواع الوحدات', 'الإدارة', true, 'full', array['room_category.created', 'room_category.updated', 'room_category.archived', 'room_category.restored']),
    ('admin.rates', 'الأسعار', 'الإدارة', true, 'full', array['rates.updated']),
    ('admin.facilities', 'المرافق', 'الإدارة', true, 'full', array['facility.created', 'facility.updated', 'facility.archived', 'facility.restored']),
    ('admin.task_types', 'أنواع المهام', 'الإدارة', true, 'full', array['task_type.created', 'task_type.updated', 'task_type.archived', 'task_type.restored']),
    ('admin.services', 'الخدمات', 'الإدارة', true, 'full', array['service.created', 'service.updated', 'service.archived', 'service.restored']),
    ('admin.cash_accounts', 'الصناديق والحسابات', 'الإدارة', true, 'full', array['cash_account.created', 'cash_account.updated', 'cash_account.archived', 'cash_account.restored']),
    ('admin.sources', 'مصادر الحجز', 'الإدارة', true, 'full', array['source.enabled', 'source.disabled']),
    ('admin.staff', 'الموظفون', 'الإدارة', true, 'full', array['staff_invited', 'staff.activated', 'staff.deactivated', 'staff.role_changed', 'staff.updated', 'staff.signed_out']),
    ('admin.knowledge', 'قاعدة المعرفة والأسئلة بلا إجابة', 'الإدارة', true, 'full', array['knowledge.created', 'knowledge.updated', 'knowledge.archived', 'knowledge.restored', 'unanswered.ignored', 'unanswered.open']),
    ('admin.ai', 'إعدادات الذكاء الاصطناعي', 'الإدارة', true, 'full', array['ai_settings_updated']),
    ('admin.whatsapp', 'واتساب الفروع', 'الإدارة', true, 'partial', array['whatsapp_channel_updated']),
    ('admin.purge', 'تفريغ البيانات', 'الإدارة', true, 'full', array['data_purge_executed']),
    ('admin.permissions', 'مصفوفة الصلاحيات', 'الإدارة', true, 'full', array['permissions.updated', 'permissions.reset']),
    ('assistant.ops', 'مساعد العمليات (تنفيذ اقتراح)', 'المساعد', false, 'full', array['ai_proposal.executed']),
    ('assistant.handover', 'استلام المحادثة من المساعد وإعادتها', 'المساعد', false, 'full', array['conversation_taken', 'conversation_returned_to_assistant']),
    ('assistant.reception', 'مساعد الاستقبال وواتساب', 'المساعد', false, 'none', array['guest_verified_lookup', 'guest_checkin_request', 'guest_viewed_code']),
    ('screens.reports', 'التقارير', 'الشاشات', false, 'none', array[]::text[]),
    ('screens.audit', 'سجل الإجراءات', 'الشاشات', false, 'none', array[]::text[]),
    ('screens.exports', 'التصدير والطباعة', 'الشاشات', false, 'none', array[]::text[]),
    ('screens.calendar', 'لوحة الوحدات وتقويم الحجوزات', 'الشاشات', false, 'none', array[]::text[]),
    ('screens.usage', 'تقرير استعمال القدرات', 'الشاشات', false, 'none', array[]::text[])
  ) as c(code, label, area, core, coverage, actions);
$$;
