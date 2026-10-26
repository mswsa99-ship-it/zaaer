/**
 * Readable names for the audit log (decision 14, 10.3): one Arabic label per action code.
 *
 * The same dictionary lives in SQL (fn_audit_action_label, migration 0040) so the log, its export and the
 * «استعمال القدرات» report (decision 55) read the same; tests/unit/contract.test.ts keeps the two identical.
 * A code missing here is shown humanised from its parts (fn_audit_action_label does the same), never hidden.
 */
export const AUDIT_ACTION_LABELS: Record<string, string> = {
  // reservations and stays
  "reservation.created": "إنشاء حجز",
  "reservation.cancelled": "إلغاء حجز",
  "reservation.cancel_undone": "التراجع عن إلغاء حجز",
  "reservation.checked_in": "تسجيل وصول",
  "reservation.check_in_undone": "التراجع عن تسجيل الوصول",
  "reservation.checked_out": "تسجيل مغادرة",
  "reservation.closed": "إغلاق إقامة",
  "reservation.unclosed": "إعادة فتح إقامة مغلقة",
  "reservation.stay_reopened": "إعادة فتح إقامة بعد المغادرة",
  "reservation.no_show": "تسجيل عدم حضور",
  "reservation.departure_changed": "تغيير موعد المغادرة",
  "reservation.room_switched": "تبديل الوحدة",
  "reservation.service_added": "إضافة خدمة إلى الحجز",
  "reservation.total_changed": "تعديل إجمالي الحجز",
  "reservation.payment_exception": "مهلة سداد استثنائية",
  "reservation.inspected": "فحص المغادرة",
  "reservation.damage_charged": "رسم ضرر",
  "reservation.hold_set": "وضع حظر على الحجز",
  "reservation.hold_lifted": "رفع الحظر عن الحجز",
  "reservation.shomoos_registered": "تسجيل شموس",
  "reservation.shomoos_accepted": "تأكيد قبول شموس",
  "reservation.platform_checked": "مطابقة الحجز مع المنصة",
  "reservation.platform_unchecked": "إلغاء مطابقة الحجز مع المنصة",
  "reservation.summary_signed": "إقرار ملخص الإقامة ورقيًا",
  assign_room: "تخصيص وحدة للحجز",
  approve_checkin: "اعتماد الدخول",
  checkout: "تسجيل مغادرة",
  manual_release_slot: "فتح توفر يدويًا",
  // guests
  "guest.entered_from_document": "إدخال بيانات ضيف من الوثيقة",
  "guest.corrected": "تصحيح بيانات ضيف",
  "guest.banned": "حظر ضيف",
  "guest.unbanned": "رفع حظر ضيف",
  "guest.rated": "تقييم ضيف",
  guest_data_submitted: "إدخال الضيف بياناته بنفسه",
  guest_verified_lookup: "تحقق الضيف من حجزه",
  guest_checkin_request: "طلب وصول من الضيف",
  guest_viewed_code: "عرض الضيف رمز الدخول",
  guest_summary_accepted: "قبول الضيف ملخص الإقامة",
  confirm_gov_registration: "تأكيد التسجيل الحكومي",
  approve_identity: "اعتماد هوية ضيف",
  reject_identity: "رفض هوية ضيف",
  // money
  confirm_payment: "تأكيد دفعة",
  "voucher.receipt_created": "إنشاء سند قبض",
  "voucher.deposit_created": "إنشاء سند تأمين",
  "voucher.refund_created": "إنشاء سند رد",
  "voucher.deposit_refund_created": "إنشاء سند رد تأمين",
  "voucher.deposit_apply_created": "استخدام التأمين لتغطية رسوم",
  "voucher.cancelled": "إلغاء سند",
  "voucher.corrected": "تصحيح سند",
  "invoice.issued": "إصدار فاتورة",
  "invoice.edited": "تعديل فاتورة",
  "invoice.cancelled": "إلغاء فاتورة",
  "pos.settled": "تسوية الشبكة",
  "platform.payout_confirmed": "تأكيد إيداع منصة",
  "platform.payout_cancelled": "إلغاء إيداع منصة",
  "cash_account.created": "إنشاء صندوق أو حساب",
  "cash_account.updated": "تعديل صندوق أو حساب",
  "cash_account.archived": "أرشفة صندوق أو حساب",
  "cash_account.restored": "استعادة صندوق أو حساب",
  "rates.updated": "تعديل الأسعار",
  "review.marked": "مراجعة بند من قائمة المراجعة",
  // access and codes
  deliver_access_code: "تسليم رمز الدخول",
  delivery_failed: "تعذّر تسليم رمز الدخول",
  rotate_keybox_code: "تغيير رمز صندوق المفتاح",
  keybox_field_tested: "تجربة رمز صندوق المفتاح",
  "keybox.code_viewed": "عرض رمز صندوق المفتاح",
  // housekeeping and maintenance
  "task.created": "إنشاء مهمة",
  "task.started": "بدء مهمة",
  "task.completed": "إتمام مهمة",
  "task.cancelled": "إلغاء مهمة",
  "task.assigned": "إسناد مهمة",
  cleaning_completed: "إتمام تنظيف",
  "room.cleanliness_changed": "تغيير حالة النظافة يدويًا",
  maintenance_opened: "فتح بلاغ صيانة",
  maintenance_resolved: "إغلاق بلاغ صيانة",
  // property definitions
  "branch.created": "إنشاء فرع",
  "branch.updated": "تعديل فرع",
  "branch.money_defaults": "تعديل إعدادات المال للفرع",
  "branch.tax_changed": "تغيير ضريبة الفرع",
  "branch.logo_changed": "تغيير شعار الفرع",
  "branch.image_changed": "تغيير صورة الفرع",
  "branch.archived": "أرشفة فرع",
  "branch.restored": "استعادة فرع",
  "block.created": "إنشاء بلوك",
  "block.updated": "تعديل بلوك",
  "block.archived": "أرشفة بلوك",
  "block.restored": "استعادة بلوك",
  "block.deleted": "حذف بلوك",
  "floor.created": "إنشاء طابق",
  "floor.updated": "تعديل طابق",
  "floor.archived": "أرشفة طابق",
  "floor.restored": "استعادة طابق",
  "floor.deleted": "حذف طابق",
  "room.created": "إنشاء وحدة",
  "room.updated": "تعديل وحدة",
  "room.archived": "أرشفة وحدة",
  "room.restored": "استعادة وحدة",
  "room.deleted": "حذف وحدة",
  "room_category.created": "إنشاء نوع وحدة",
  "room_category.updated": "تعديل نوع وحدة",
  "room_category.archived": "أرشفة نوع وحدة",
  "room_category.restored": "استعادة نوع وحدة",
  "room_category.deleted": "حذف نوع وحدة",
  "facility.created": "إنشاء مرفق",
  "facility.updated": "تعديل مرفق",
  "facility.archived": "أرشفة مرفق",
  "facility.restored": "استعادة مرفق",
  "facility.deleted": "حذف مرفق",
  "task_type.created": "إنشاء نوع مهمة",
  "task_type.updated": "تعديل نوع مهمة",
  "task_type.archived": "أرشفة نوع مهمة",
  "task_type.restored": "استعادة نوع مهمة",
  "task_type.deleted": "حذف نوع مهمة",
  "service.created": "إنشاء خدمة",
  "service.updated": "تعديل خدمة",
  "service.archived": "أرشفة خدمة",
  "service.restored": "استعادة خدمة",
  "service.deleted": "حذف خدمة",
  "source.enabled": "تفعيل مصدر حجز",
  "source.disabled": "تعطيل مصدر حجز",
  // staff and security
  staff_invited: "دعوة موظف",
  "staff.activated": "تفعيل موظف",
  "staff.deactivated": "إيقاف موظف",
  "staff.role_changed": "تغيير دور موظف",
  "staff.updated": "تعديل بيانات موظف",
  "staff.signed_out": "تسجيل خروج إجباري",
  demo_owner_bootstrap: "إنشاء مالك نسخة العرض",
  data_purge_executed: "تنفيذ تفريغ بيانات",
  // assistant, knowledge and channels
  "ai_proposal.executed": "تنفيذ اقتراح مساعد العمليات",
  ai_settings_updated: "تعديل إعدادات الذكاء الاصطناعي",
  "knowledge.created": "إضافة إجابة إلى قاعدة المعرفة",
  "knowledge.updated": "تعديل إجابة في قاعدة المعرفة",
  "knowledge.archived": "أرشفة إجابة من قاعدة المعرفة",
  "knowledge.restored": "استعادة إجابة في قاعدة المعرفة",
  "unanswered.ignored": "تجاهل سؤال بلا إجابة",
  "unanswered.open": "إعادة فتح سؤال بلا إجابة",
  conversation_taken: "استلام المحادثة من المساعد",
  conversation_returned_to_assistant: "إعادة المحادثة إلى المساعد",
  whatsapp_channel_updated: "تعديل إعداد واتساب الفرع",
  // the permissions matrix and the organisation (0043, 0044)
  "permissions.updated": "تعديل مصفوفة الصلاحيات",
  "permissions.reset": "إعادة مصفوفة الصلاحيات إلى المعتمدة",
  "organization.updated": "تعديل بيانات المنشأة",
};

/** Entity names as the log shows them. */
export const AUDIT_ENTITY_LABELS: Record<string, string> = {
  reservation: "حجز", reservation_guest: "ضيف", guest_profile: "ملف ضيف", financial_voucher: "سند", voucher: "سند", invoice: "فاتورة",
  room: "وحدة", room_category: "نوع وحدة", facility: "مرفق", housekeeping_task: "مهمة", task_type: "نوع مهمة", service_definition: "خدمة",
  branch: "فرع", block: "بلوك", floor: "طابق", staff_profile: "موظف", cash_account: "صندوق أو حساب", booking_source: "مصدر حجز",
  service: "خدمة", keybox: "صندوق مفتاح", knowledge_entry: "إجابة", unanswered_question: "سؤال بلا إجابة", ai_settings: "إعدادات الذكاء الاصطناعي",
  ai_proposal: "اقتراح المساعد", ai_action_proposal: "اقتراح المساعد", conversation: "محادثة", review_items: "بند مراجعة",
  pos_settlement: "تسوية شبكة", platform_payout: "إيداع منصة", review_item: "بند مراجعة", maintenance_ticket: "بلاغ صيانة",
  whatsapp_channel: "واتساب الفرع", organization: "المنشأة", data_purge: "تفريغ بيانات", rate_calendar: "تقويم الأسعار",
  inventory_period: "فترة توفر", release_rule: "قاعدة توفر", released_slot: "توفر",
  role_permissions: "مصفوفة الصلاحيات",
};

const VERB_LABELS: Record<string, string> = {
  created: "إنشاء", updated: "تعديل", archived: "أرشفة", restored: "استعادة", enabled: "تفعيل", disabled: "تعطيل", cancelled: "إلغاء",
  completed: "إتمام", started: "بدء", assigned: "إسناد", issued: "إصدار", edited: "تعديل", corrected: "تصحيح", confirmed: "تأكيد",
  approved: "اعتماد", rejected: "رفض", viewed: "عرض", changed: "تغيير", executed: "تنفيذ", marked: "تعليم", settled: "تسوية", deleted: "حذف",
};

/** The label of a code; a code outside the dictionary is humanised from its parts (fn_audit_action_label does the same). */
export function auditActionLabel(code: string): string {
  const known = AUDIT_ACTION_LABELS[code];
  if (known) return known;
  const dot = code.indexOf(".");
  if (dot > 0) {
    const entity = AUDIT_ENTITY_LABELS[code.slice(0, dot)] ?? code.slice(0, dot).replace(/_/g, " ");
    const verb = code.slice(dot + 1);
    return `${VERB_LABELS[verb] ?? verb.replace(/_/g, " ")} — ${entity}`;
  }
  return code.replace(/_/g, " ");
}

export function auditEntityLabel(entityType: string | null | undefined): string {
  if (!entityType) return "—";
  return AUDIT_ENTITY_LABELS[entityType] ?? entityType.replace(/_/g, " ");
}
