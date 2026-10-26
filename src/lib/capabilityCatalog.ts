/**
 * The catalogue of capabilities for «استعمال القدرات» (decision 55; control G26, test D04): one row per capability with
 * the audited action codes behind it, its area, whether it is core administration (decision 53), and how completely the
 * audit log sees it — 'full' (every path writes a row), 'partial' (some paths do not, e.g. the guest's own actions on
 * another channel), 'none' (a read-only screen; never written). A capability the log cannot see is reported as
 * «غير محسوم», never as unused.
 *
 * The same rows live in SQL (fn_capability_catalog, migration 0040 and the owner's paste 0041, which carries the complete
 * list with the «حذف تعريف» codes). The demo backend reads this copy; a unit test diffs it against the SQL.
 */
export interface CapabilityCatalogRow { code: string; label: string; area: string; core: boolean; coverage: "full" | "partial" | "none"; actions: readonly string[] }

export const CAPABILITY_CATALOG: ReadonlyArray<CapabilityCatalogRow> = [
  { code: "reservations.create", label: "إنشاء حجز", area: "الحجوزات", core: false, coverage: "full", actions: ["reservation.created"] },
  { code: "reservations.cancel", label: "إلغاء حجز وعدم حضور", area: "الحجوزات", core: false, coverage: "full", actions: ["reservation.cancelled", "reservation.no_show"] },
  { code: "reservations.amend", label: "تمديد وتبديل وتعديل الإجمالي", area: "الحجوزات", core: false, coverage: "full", actions: ["reservation.departure_changed", "reservation.room_switched", "reservation.total_changed", "reservation.service_added"] },
  { code: "reservations.corrections", label: "التصحيحات (التراجع عن الوصول والإلغاء وإعادة الفتح)", area: "الحجوزات", core: false, coverage: "full", actions: ["reservation.check_in_undone", "reservation.cancel_undone", "reservation.stay_reopened", "reservation.unclosed"] },
  { code: "reservations.hold", label: "الحظر على الحجز", area: "الحجوزات", core: false, coverage: "full", actions: ["reservation.hold_set", "reservation.hold_lifted"] },
  { code: "reservations.platform_check", label: "مطابقة المنصات", area: "الحجوزات", core: false, coverage: "full", actions: ["reservation.platform_checked", "reservation.platform_unchecked"] },
  { code: "stay.check_in", label: "تسجيل الوصول", area: "الإقامة", core: false, coverage: "full", actions: ["reservation.checked_in", "approve_checkin"] },
  { code: "stay.shomoos", label: "التسجيل في شموس", area: "الإقامة", core: false, coverage: "full", actions: ["reservation.shomoos_registered", "reservation.shomoos_accepted", "confirm_gov_registration"] },
  { code: "stay.payment_exception", label: "مهلة السداد الاستثنائية", area: "الإقامة", core: false, coverage: "full", actions: ["reservation.payment_exception"] },
  { code: "stay.check_out", label: "تسجيل المغادرة والإغلاق", area: "الإقامة", core: false, coverage: "full", actions: ["reservation.checked_out", "reservation.closed", "checkout"] },
  { code: "stay.inspection", label: "فحص المغادرة ورسوم الضرر", area: "الإقامة", core: false, coverage: "full", actions: ["reservation.inspected", "reservation.damage_charged"] },
  { code: "stay.summary", label: "ملخص الإقامة وإقراره", area: "الإقامة", core: false, coverage: "partial", actions: ["reservation.summary_signed", "guest_summary_accepted"] },
  { code: "guests.office_entry", label: "إدخال بيانات الضيف من الوثيقة وتصحيحها", area: "الضيوف", core: false, coverage: "full", actions: ["guest.entered_from_document", "guest.corrected", "approve_identity", "reject_identity"] },
  { code: "guests.self_entry", label: "إدخال الضيف بياناته بنفسه", area: "الضيوف", core: false, coverage: "partial", actions: ["guest_data_submitted"] },
  { code: "guests.ban_rating", label: "حظر الضيوف وتقييمهم", area: "الضيوف", core: false, coverage: "full", actions: ["guest.banned", "guest.unbanned", "guest.rated"] },
  { code: "money.receipts", label: "سندات القبض والتأمين", area: "المال", core: false, coverage: "full", actions: ["voucher.receipt_created", "voucher.deposit_created", "confirm_payment"] },
  { code: "money.refunds", label: "الاستردادات وتسوية التأمين", area: "المال", core: false, coverage: "full", actions: ["voucher.refund_created", "voucher.deposit_refund_created", "voucher.deposit_apply_created"] },
  { code: "money.corrections", label: "إلغاء السندات وتصحيحها", area: "المال", core: false, coverage: "full", actions: ["voucher.cancelled", "voucher.corrected"] },
  { code: "money.invoices", label: "الفواتير", area: "المال", core: false, coverage: "full", actions: ["invoice.issued", "invoice.edited", "invoice.cancelled"] },
  { code: "money.pos_settlement", label: "تسوية الشبكة", area: "المال", core: false, coverage: "full", actions: ["pos.settled"] },
  { code: "money.platform_payouts", label: "إيداعات المنصات", area: "المال", core: false, coverage: "full", actions: ["platform.payout_confirmed", "platform.payout_cancelled"] },
  { code: "money.review", label: "قائمة المراجعة", area: "المال", core: false, coverage: "full", actions: ["review.marked"] },
  { code: "access.codes", label: "تسليم رمز الدخول", area: "الوصول", core: false, coverage: "full", actions: ["deliver_access_code", "delivery_failed"] },
  { code: "access.keybox", label: "رموز صناديق المفاتيح", area: "الوصول", core: false, coverage: "full", actions: ["rotate_keybox_code", "keybox_field_tested", "keybox.code_viewed"] },
  { code: "housekeeping.tasks", label: "المهام", area: "خدمة الغرف", core: false, coverage: "full", actions: ["task.created", "task.started", "task.completed", "task.cancelled", "task.assigned", "cleaning_completed"] },
  { code: "housekeeping.cleanliness", label: "تغيير النظافة يدويًا", area: "خدمة الغرف", core: false, coverage: "full", actions: ["room.cleanliness_changed"] },
  { code: "housekeeping.maintenance", label: "بلاغات الصيانة", area: "خدمة الغرف", core: false, coverage: "full", actions: ["maintenance_opened", "maintenance_resolved"] },
  { code: "admin.branches", label: "الفروع وإعداداتها", area: "الإدارة", core: true, coverage: "full", actions: ["branch.created", "branch.updated", "branch.money_defaults", "branch.tax_changed", "branch.logo_changed", "branch.image_changed", "branch.archived", "branch.restored", "organization.updated"] },
  { code: "admin.structure", label: "البلوكات والطوابق", area: "الإدارة", core: true, coverage: "full", actions: ["block.created", "block.updated", "block.archived", "block.restored", "block.deleted", "floor.created", "floor.updated", "floor.archived", "floor.restored", "floor.deleted"] },
  { code: "admin.rooms", label: "الوحدات", area: "الإدارة", core: true, coverage: "full", actions: ["room.created", "room.updated", "room.archived", "room.restored", "room.deleted"] },
  { code: "admin.room_categories", label: "أنواع الوحدات", area: "الإدارة", core: true, coverage: "full", actions: ["room_category.created", "room_category.updated", "room_category.archived", "room_category.restored", "room_category.deleted"] },
  { code: "admin.rates", label: "الأسعار", area: "الإدارة", core: true, coverage: "full", actions: ["rates.updated"] },
  { code: "admin.facilities", label: "المرافق", area: "الإدارة", core: true, coverage: "full", actions: ["facility.created", "facility.updated", "facility.archived", "facility.restored", "facility.deleted"] },
  { code: "admin.task_types", label: "أنواع المهام", area: "الإدارة", core: true, coverage: "full", actions: ["task_type.created", "task_type.updated", "task_type.archived", "task_type.restored", "task_type.deleted"] },
  { code: "admin.services", label: "الخدمات", area: "الإدارة", core: true, coverage: "full", actions: ["service.created", "service.updated", "service.archived", "service.restored", "service.deleted"] },
  { code: "admin.cash_accounts", label: "الصناديق والحسابات", area: "الإدارة", core: true, coverage: "full", actions: ["cash_account.created", "cash_account.updated", "cash_account.archived", "cash_account.restored"] },
  { code: "admin.sources", label: "مصادر الحجز", area: "الإدارة", core: true, coverage: "full", actions: ["source.enabled", "source.disabled"] },
  { code: "admin.staff", label: "الموظفون", area: "الإدارة", core: true, coverage: "full", actions: ["staff_invited", "staff.activated", "staff.deactivated", "staff.role_changed", "staff.updated", "staff.signed_out"] },
  { code: "admin.knowledge", label: "قاعدة المعرفة والأسئلة بلا إجابة", area: "الإدارة", core: true, coverage: "full", actions: ["knowledge.created", "knowledge.updated", "knowledge.archived", "knowledge.restored", "unanswered.ignored", "unanswered.open"] },
  { code: "admin.ai", label: "إعدادات الذكاء الاصطناعي", area: "الإدارة", core: true, coverage: "full", actions: ["ai_settings_updated"] },
  { code: "admin.whatsapp", label: "واتساب الفروع", area: "الإدارة", core: true, coverage: "partial", actions: ["whatsapp_channel_updated"] },
  { code: "admin.purge", label: "تفريغ البيانات", area: "الإدارة", core: true, coverage: "full", actions: ["data_purge_executed"] },
  { code: "admin.permissions", label: "مصفوفة الصلاحيات", area: "الإدارة", core: true, coverage: "full", actions: ["permissions.updated", "permissions.reset"] },
  { code: "assistant.ops", label: "مساعد العمليات (تنفيذ اقتراح)", area: "المساعد", core: false, coverage: "full", actions: ["ai_proposal.executed"] },
  { code: "assistant.handover", label: "استلام المحادثة من المساعد وإعادتها", area: "المساعد", core: false, coverage: "full", actions: ["conversation_taken", "conversation_returned_to_assistant"] },
  { code: "assistant.reception", label: "مساعد الاستقبال وواتساب", area: "المساعد", core: false, coverage: "none", actions: ["guest_verified_lookup", "guest_checkin_request", "guest_viewed_code"] },
  { code: "screens.reports", label: "التقارير", area: "الشاشات", core: false, coverage: "none", actions: [] },
  { code: "screens.audit", label: "سجل الإجراءات", area: "الشاشات", core: false, coverage: "none", actions: [] },
  { code: "screens.exports", label: "التصدير والطباعة", area: "الشاشات", core: false, coverage: "none", actions: [] },
  { code: "screens.calendar", label: "لوحة الوحدات وتقويم الحجوزات", area: "الشاشات", core: false, coverage: "none", actions: [] },
  { code: "screens.usage", label: "تقرير استعمال القدرات", area: "الشاشات", core: false, coverage: "none", actions: [] },
];
