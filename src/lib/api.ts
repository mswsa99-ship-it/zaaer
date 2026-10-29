/**
 * Typed client for the server-side business functions (SECURITY DEFINER RPCs)
 * and the AI Edge Function. Pages must use these instead of writing to tables:
 * the database rejects direct writes for operational roles.
 */
import { permissionRow } from "./permissionCatalog";
import { supabase } from "./supabase";
import { clientSource, errorCode, newTraceId, normalizeTrace } from "./trace";

export class ApiError extends Error {
  /** traceId: the code sent with the request (x-correlation-id) and shown to the employee with the message. */
  constructor(message: string, public readonly code?: string, public readonly traceId?: string) { super(message); }
}

const ERROR_AR: Record<string, string> = {
  FORBIDDEN: "ليس لديك صلاحية لهذا الإجراء.",
  // the staff editor and the forced sign-out (decisions 34, 35)
  SELF_NOT_ALLOWED: "لا يُطبَّق هذا الإجراء على حسابك أنت.",
  SELF_ROLE_OR_BRANCHES: "لا يغيّر أحد دوره أو فروعه بنفسه؛ يفعل ذلك مالك آخر.",
  EMAIL_NOT_EDITABLE: "البريد هو هوية الدخول ولا يُعدَّل؛ ادعُ الموظف ببريد جديد.",
  "LIMIT: saved_views": "الحد عشرون عرضًا محفوظًا لكل شاشة؛ احذف عرضًا قديمًا.",
  "NOT_FOUND: view": "العرض المحفوظ غير موجود.",
  "NOT_FOUND: staff": "الموظف غير موجود.",
  TOKEN_INVALID: "الرابط غير صالح أو منتهي الصلاحية.",
  RESERVATION_NOT_FOUND: "الحجز غير موجود.",
  GUEST_NOT_FOUND: "سجل النزيل غير موجود.",
  GUEST_DATA_NOT_SUBMITTED: "لم يُكمل النزيل بياناته بعد.",
  REASON_REQUIRED: "يجب كتابة سبب.",
  IDENTITY_NOT_VERIFIED: "يجب اعتماد مطابقة الهوية أولًا.",
  ROOM_NOT_FOUND: "الغرفة غير موجودة.",
  ROOM_CATEGORY_MISMATCH: "تصنيف الغرفة لا يطابق تصنيف الحجز.",
  ROOM_NOT_AVAILABLE: "الغرفة غير متاحة للتخصيص.",
  RESERVATION_STATUS_INVALID: "حالة الحجز لا تسمح بهذا الإجراء.",
  NOT_CHECKED_IN: "الحجز ليس في حالة دخول.",
  NOT_IN_DELIVERED_STATE: "لم يتم تسليم الرمز لهذا الحجز.",
  CODE_MUST_DIFFER_FROM_PREVIOUS: "هذا هو الرمز الحالي نفسه — لا يُقبل. اضبط رمزًا جديدًا على الصندوق ثم احفظه.",
  PLATFORM_VERIFIED: "طُوبق الحجز مع المنصة؛ تُلغى المطابقة أولًا ثم تُصحَّح بيانات المنصة.",
  GROUP_UNIT_IN_HOUSE: "إحدى وحدات المجموعة سُجِّل وصولها؛ لا تُصحَّح بيانات المنصة بعد الوصول.",
  CODE_IN_USE: "هذا الرمز مستخدم في صندوق وحدة أخرى بهذا الفرع. اضبط على الصندوق رمزًا مختلفًا ثم احفظه.",
  GUEST_IN_HOUSE: "في الوحدة نزيل مقيم؛ رمزها لا يُعرض ولا يُغيَّر من حساب خدمة الغرف.",
  NO_KEYBOX_CODE: "لا يوجد رمز مسجّل لهذه الوحدة بعد.",
  CODE_NEEDS_CHANGE: "الرمز الحالي يجب تغييره أولًا؛ التجربة تكون للرمز الجديد.",
  GUEST_LIMIT_REACHED: "اكتمل عدد النزلاء المسجلين لهذا الحجز.",
  DUPLICATE_GUEST: "هذه الوثيقة مسجلة مسبقًا في نفس الحجز.",
  GUEST_ALREADY_VERIFIED: "تم اعتماد هذا النزيل ولا يمكن تعديل بياناته.",
  RESERVATION_NOT_EDITABLE: "لا يمكن تعديل هذا الحجز.",
  SECRET_NOT_CONFIGURED: "إعداد التشفير غير مكتمل على الخادم (app.keybox_key / app.identity_key).",
  NO_INVITATION: "لا توجد دعوة لهذا البريد. اطلب من المالك إضافتك.",
  reservations_no_overlap: "تعارض: الغرفة محجوزة لفترة متداخلة.",
  ALLOCATION_CONFLICT: "الوحدة مرتبطة بحجز آخر خلال جزء من الفترة المختارة.",
  ALREADY_ALLOCATED: "الحجز مرتبط بوحدة بالفعل؛ استخدم «تبديل الوحدة».",
  VERSION_CONFLICT: "تغيّر هذا السجل بواسطة مستخدم آخر؛ حدّث البيانات قبل الحفظ.",
  VERSION_REQUIRED: "لا يمكن الحفظ دون نسخة السجل المعروضة؛ حدّث الصفحة وأعد المحاولة.",
  BRANCH_MISMATCH: "العنصر المختار لا ينتمي إلى نفس الفرع.",
  DUPLICATE_NAME: "الاسم مستخدم مسبقًا ضمن هذا النطاق.",
  DUPLICATE_ROOM_NUMBER: "رقم الوحدة مستخدم مسبقًا في هذا الفرع.",
  DUPLICATE_EXTERNAL_REF: "رقم الحجز في المنصة مستخدم في حجز آخر أو مجموعة أخرى.",
  GROUP_NUMBER_PENDING_MIGRATION: "مشاركة رقم المنصة بين وحدات المجموعة تنتظر لصقة المالك (الترحيل 0039)؛ حتى ذلك الحين أدخل كل وحدة حجزًا مستقلًا برقمها.",
  SUMMARY_CHANGED: "تغيّر ملخص الإقامة منذ طباعته؛ اطبعه من جديد ووقّعه الضيف.",
  HAS_DEPENDENCIES: "لا يمكن الحذف لوجود سجلات مرتبطة؛ يمكن أرشفته.",
  HAS_OPEN_COMMITMENTS: "لا يمكن الأرشفة لوجود التزامات مفتوحة (حجوزات أو مهام).",
  HAS_FUTURE_COMMITMENTS: "لا يمكن تعطيل الوحدة لوجود حجوزات مستقبلية عليها؛ انقلها أولًا.",
  LAST_ACTIVE_BRANCH: "لا يمكن أرشفة آخر فرع فعال.",
  SYSTEM_DEFINITION: "هذا تعريف نظامي لا يمكن حذفه.",
  CAPACITY_EXCEEDED: "عدد النزلاء يتجاوز سعة نوع الوحدة.",
  ROOM_NOT_CLEAN: "الوحدة الجديدة غير نظيفة؛ أكمل تنظيفها أولًا.",
  REFUND_EXCEEDS_AVAILABLE: "المبلغ يتجاوز الرصيد القابل للاسترداد.",
  IDEMPOTENCY_CONFLICT: "مفتاح العملية مستخدم بمحتوى مختلف؛ أنشئ عملية جديدة.",
  CANCEL_WOULD_GO_NEGATIVE: "لا يمكن إلغاء السند لأن الرصيد سيصبح سالبًا.",
  VOUCHER_STATUS_INVALID: "حالة السند لا تسمح بهذا الإجراء.",
  NOTHING_TO_INVOICE: "لا يوجد ما لم يُفوتر في هذه الفترة.",
  // invoices and voucher correction (0036)
  INVOICE_PERIOD_OVERLAP: "فاتورة أخرى لهذا الحجز تغطي جزءًا من هذه الفترة؛ اختر ليالي لم تُفوتر.",
  INVOICE_NOT_POSITIVE: "ما بقي يخفّض قيمة الإقامة فقط؛ لا تُصدر به فاتورة — عدّل الفاتورة الصادرة لتشمله.",
  VOUCHER_IN_PAYOUT: "السند داخل مطابقة منصة مؤكدة؛ تُلغى المطابقة أولًا ثم يُصحَّح السند أو يُلغى.",
  INVOICE_UNCHANGED: "لم يتغير شيء في الفاتورة؛ عدّل الاسم أو الملاحظة أو الفترة، أو أغلق النافذة.",
  INVOICE_STATUS_INVALID: "حالة الفاتورة لا تسمح بهذا الإجراء.",
  SERVICE_NOT_AVAILABLE: "الخدمة غير متاحة أو مؤرشفة.",
  TASK_NOT_FOUND: "المهمة غير موجودة.",
  TASK_STATUS_INVALID: "حالة المهمة لا تسمح بهذا الإجراء.",
  ASSIGNEE_NOT_IN_BRANCH: "الموظف المختار ليس عضوًا فعالًا في هذا الفرع.",
  OPEN_CLEANING_TASK: "توجد مهمة تنظيف مفتوحة؛ أكملها بدل التغيير اليدوي.",
  PROPOSAL_STATUS_INVALID: "تم البت في هذا الاقتراح مسبقًا.",
  PROPOSAL_EXPIRED: "انتهت صلاحية الاقتراح؛ اطلب اقتراحًا جديدًا.",
  NOT_FOUND: "السجل غير موجود.",
  LAST_OWNER: "لا يمكن تعطيل أو تخفيض صلاحية آخر مالك فعال.",
  SAME_ROOM: "الوحدة المختارة هي الوحدة الحالية نفسها.",
  ALLOCATION_MISMATCH: "تخصيص الوحدة لا يطابق فترة الحجز؛ راجع سجل التخصيص قبل التمديد.",
  IDEMPOTENCY_CANCELLED: "هذا السند أُلغي سابقًا؛ أنشئ عملية جديدة بدل إعادة الإرسال.",
  TASK_TYPE_MISSING: "نوع مهمة التنظيف النظامي غير موجود لهذا الفرع.",
  REAUTH_REQUIRED: "أعد إدخال كلمة المرور للتأكيد.",
  // the stay cycle (0033)
  PAYMENT_OVERDUE: "على الإقامة ليلة لم تُدفع بعد موعدها: التمديد وإضافة الخدمات بعد سدادها، أو بعد تسجيل سبب يسمح بالاستمرار.",
  CORRECTION_WINDOW_PASSED: "انتهت مهلة هذا التصحيح (التراجع عن الوصول خلال 30 دقيقة، وإعادة فتح المغادرة خلال ساعتين، والتراجع عن الإلغاء خلال ساعة).",
  INSPECTION_REQUIRED: "سجّل فحص المغادرة قبل رد التأمين.",
  ROOM_HAS_GUEST: "في الوحدة نزيل مقيم؛ لا تُعطَّل ولا تُؤرشف قبل مغادرته.",
  CATEGORY_ARCHIVED: "نوع الوحدة مؤرشف ولا يقبل حجوزات جديدة.",
};

export const VALIDATION_AR: Record<string, string> = {
  // guests, platforms and the branch (0038)
  document_matched: "أكّد «طابقتُ الوثيقة الأصلية» قبل الحفظ.",
  acknowledgement_required: "يجب الإقرار بملخص الإقامة أولًا.",
  platform_collects: "حدّد من يقبض المبلغ: المنصة أم المنشأة.", platform_booked_on: "تاريخ الحجز في المنصة مطلوب ولا يكون بعد اليوم.",
  cancel_number: "رقم الإلغاء من المنصة مطلوب (حتى 60 حرفًا).", not_platform: "هذا الحجز ليس من منصة.", rating: "التقييم من 1 إلى 5.", note: "الملاحظة حتى 500 حرف.",
  ban: "حدّد الحظر أو رفعه.", hold: "حدّد وضع الحظر أو رفعه.", guest_profile: "ملف الضيف غير موجود.",
  name_en: "الاسم الإنجليزي للفرع مطلوب.", country: "رمز الدولة حرفان كبيران (مثل SA).", language: "اللغة الافتراضية: عربي أو إنجليزي.",
  map_url: "رابط الموقع يجب أن يكون رابط خرائط Google يبدأ بـ https.", booking_url: "رابط منصة الحجز يجب أن يبدأ بـ https.",
  image: "الملف ليس صورة صالحة.", image_type: "الشعار والصورة بصيغة PNG أو JPG أو WebP فقط (لا SVG).", image_too_large: "حجم الملف أكبر من المسموح (الشعار 200 كيلوبايت، الصورة 1 ميجابايت).",
  path: "مسار غير صحيح.", is_active: "حدّد التفعيل أو التعطيل.",
  // invoices, voucher correction and the review list (0036)
  nothing_changed: "لم يتغير شيء في السند: عدّل المبلغ أو الطريقة أو رقم العملية أو الحساب أو الملاحظة.",
  bill_to_name: "اسم العميل على الفاتورة مطلوب.",
  original_voucher: "السند الأصلي ليس من هذا الحجز.",
  service_period: "فترة البند غير صحيحة.",
  ids: "اختر بندًا واحدًا على الأقل.",
  // the stay cycle (0033)
  shomoos_all_guests: "أكّد أن جميع النزلاء والمرافقين سُجّلوا في شموس.",
  shomoos_reference: "رقم تسجيل شموس بين 3 و60 حرفًا.",
  shomoos_not_registered: "سجّل النزلاء في شموس أولًا.",
  shomoos_guest_count: "تغيّر عدد النزلاء بعد تسجيل شموس؛ حدِّث التسجيل أولًا.",
  first_night_unpaid: "الليلة الأولى غير مدفوعة كاملة.",
  deposit_reason: "التأمين لم يُستلم كاملًا: اكتب سبب ذلك.",
  deposit_refund_before_checkout: "يُرد تأمين الإقامة بعد تسجيل المغادرة وفحصها.",
  inspection_result: "اختر نتيجة الفحص: سليمة أو بملاحظات.",
  inspection_notes: "اكتب ملاحظات الفحص.",
  inspection_not_due: "فحص المغادرة يكون بعد تسجيل المغادرة أو في يومها.",
  not_overdue: "لا توجد على هذه الإقامة ليلة متأخرة السداد.",
  stay_ended: "انتهت فترة هذه الإقامة؛ لا يُتراجع عن إلغائها.",
  late_checkout_until: "ساعة المغادرة المتأخرة تكون بعد موعد المغادرة في الفرع.",
  late_checkout_unit: "المغادرة المتأخرة تُحتسب مرة واحدة للإقامة.",
  // core money (0028)
  method_retired: "هذه الطريقة لم تعد مستخدمة. طرق القبض والرد: نقد، شبكة، تحويل بنكي، آجل عبر المنصة.",
  deposit_method: "التأمين يُقبض ويُرد في المنشأة نفسها (نقد أو شبكة أو تحويل)، ولا تحصّله المنصة.",
  // rates (0030)
  discount_exceeds_rent: "الخصم أكبر من إيجار الإقامة.",
  discount_percent: "الخصم يتجاوز النسبة المسموحة للمشرف في هذا الفرع؛ يعتمده المالك أو المدير.",
  discount_minimum: "الخصم ينزل بسعر الليلة تحت الحد الأدنى لهذا النوع؛ يعتمده المالك أو المدير.",
  discount_reason: "اكتب سبب الخصم.",
  discount_limit: "نسبة خصم المشرف بين 0 و100%.",
  below_minimum: "السعر أقل من الحد الأدنى لليلة في هذا النوع.",
  calendar_below_minimum: "في التقويم أسعار قادمة أقل من هذا الحد الأدنى؛ عدّلها أولًا.",
  past_night: "لا يُعدَّل سعر ليلة مضت.",
  too_many_cells: "التعديل يشمل خانات كثيرة؛ قسّمه على فترات أقصر.",
  cells: "لا توجد خانات مطابقة لهذا التعديل.",
  price: "حدد سعرًا، أو اختر الإرجاع للسعر الأساسي.",
  range: "نطاق التواريخ غير صالح.",
  categories: "اختر نوع وحدة واحدًا على الأقل.",
  price_mode: "تصنيف السعر غير صالح.",
  account_required: "لا يوجد صندوق أو حساب بنكي افتراضي لهذا الفرع. اختر واحدًا، أو عرّفه من «الصناديق والحسابات».",
  account_kind: "النقد يُقيَّد في صندوق، والشبكة والتحويل في حساب بنكي.",
  account_archived: "هذا الصندوق أو الحساب مؤرشف ولا يُستخدم لسندات جديدة.",
  account_not_allowed: "الآجل عبر المنصة لا يُقيَّد في صندوق ولا حساب.",
  account_last4: "آخر أربعة أرقام من الحساب: أربعة أرقام فقط.",
  reference: "رقم العملية بين 3 و60 حرفًا.",
  note_required: "يوجد فرق: اكتب سببه.",
  business_date: "لا تُسوّى إلا الأيام التي مضت أو اليوم.",
  received_on: "تاريخ الاستلام لا يكون بعد اليوم.",
  vouchers: "اختر دفعة واحدة على الأقل.",
  payout_vouchers: "بعض الدفعات المختارة ليست دفعات آجلة غير مطابقة لهذه المنصة في هذا الفرع.",
  payout_status: "هذه المطابقة ملغاة مسبقًا.",
  tax_rate: "نسبة الضريبة بين 0 و100%.",
  full_name_three_parts: "الاسم الثلاثي مطلوب كما في الوثيقة.",
  identity_type: "نوع الوثيقة غير صحيح.",
  identity_number_format: "رقم الوثيقة غير صحيح: الهوية الوطنية 10 أرقام تبدأ بـ 1، والإقامة 10 أرقام تبدأ بـ 2.",
  nationality: "الجنسية مطلوبة.",
  birth_date: "تاريخ الميلاد غير صالح.",
  birth_date_range: "تاريخ الميلاد خارج النطاق المنطقي.",
  consent_required: "يجب الإقرار بصحة البيانات.",
  phone_required_primary: "رقم الجوال مطلوب للنزيل الرئيسي.",
  // data validity (0047)
  name_letters_only: "الاسم حروف فقط (عربية أو إنجليزية)، بلا أرقام أو رموز.",
  phone_required: "رقم جوال الضيف الرئيسي مطلوب.",
  phone_format: "رقم الجوال: سعودي يبدأ بـ 05 ويتكون من 10 أرقام، أو دولي يبدأ بـ + ثم رمز الدولة.",
  minimum_age_15: "لا يُسجَّل من عمره أقل من 15 سنة.",
  amount: "المبلغ غير صحيح.",
  reference_required: "رقم المرجع أو رقم العملية مطلوب.",
  idempotency_key: "مفتاح العملية مفقود.",
  code_must_be_4_to_8_digits: "الرمز يجب أن يكون من 4 إلى 8 أرقام.",
  title: "العنوان مطلوب.",
  channel: "قناة التسليم غير صحيحة.",
  name: "الاسم مطلوب.", name_ar: "الاسم العربي مطلوب.", room_number: "رقم الوحدة مطلوب.", reason: "يجب كتابة سبب.",
  dates: "يجب أن يكون وقت المغادرة بعد وقت الوصول.", guest_name: "اسم الضيف مطلوب.", guests: "عدد النزلاء غير صحيح.",
  source: "مصدر الحجز غير صالح.", external_ref_required: "المرجع الخارجي مطلوب لهذا المصدر.", one_target: "اختر وحدة أو مرفقًا (واحدًا فقط).",
  pricing_mode: "اختر طريقة التسعير.", effective_date: "تاريخ التبديل خارج فترة الإقامة.", checkout_in_past: "تاريخ المغادرة الجديد في الماضي.",
  arrival_not_due: "لا يمكن إعلان عدم الحضور قبل موعد الوصول.", kind: "نوع العملية غير صحيح.", method: "طريقة الدفع مطلوبة.",
  entity: "نوع العنصر غير صحيح.", capacity: "السعة القصوى يجب ألا تقل عن الأساسية.", cleanliness: "حالة النظافة غير صحيحة.", quantity: "الكمية غير صحيحة.",
  action: "إجراء غير مسموح.", summary: "وصف الاقتراح مطلوب.", timezone: "المنطقة الزمنية غير صالحة (مثال: Asia/Riyadh).",
  display_phone: "رقم واتساب غير صحيح (مثال: 05xxxxxxxx أو 9665xxxxxxxx).", phone_number_id: "Phone Number ID أرقام فقط (من Meta)، ولا يُستخدم لفرعين.",
  waba_id: "WhatsApp Business Account ID أرقام فقط.", access_token: "رمز الوصول غير صالح (انسخه كاملًا من Meta).", app_secret: "App Secret غير صالح.",
  channel_incomplete: "أكمل الإعداد قبل التفعيل: رقم واتساب الفرع ومفتاح ربط كمبيوتر الاستقبال (أو بيانات Meta في وضع Cloud API).", period: "الفترة غير صحيحة (من قبل إلى).",
  mode: "طريقة الربط غير صحيحة.", auto_reply: "قيمة الرد الآلي غير صحيحة.", human_pause_minutes: "مدة توقف الرد الآلي بين 5 و720 دقيقة.",
  period_after_today: "لا يمكن أن تنتهي الفترة بعد اليوم.", choose_category: "اختر نوعًا واحدًا من البيانات على الأقل.", unknown_category: "نوع بيانات غير معروف.",
  confirmation_phrase: "عبارة التأكيد غير مطابقة.", preview_expired: "انتهت صلاحية المعاينة (15 دقيقة). اعرض المعاينة من جديد.",
  // the lists, the staff editor and the task's schedule (0040)
  schedule: "نهاية المهمة لا تسبق بدايتها.", schedule_start: "بداية المهمة مطلوبة.",
  allowed: "اختر مسموحًا أو غير مسموح.", changes: "لا تغييرات للحفظ.",
  branch_id: "اختر الفرع.", status: "الحالة غير صحيحة.", screen: "الشاشة غير معروفة.", full_name: "الاسم مطلوب.", email_and_name: "البريد والاسم مطلوبان.",
};

/** Refusals that say which rule refused, more useful than the generic «no permission». */
const FORBIDDEN_AR: Array<[RegExp, string]> = [
  [/post-arrival discount/, "الخصم بعد وصول الضيف للمالك أو المدير."],
  [/rate below the quoted price/, "سعر ليلة أقل من السعر المحسوب خصمٌ يعتمده المالك أو المدير؛ استخدم خانة الخصم ضمن حدك."],
  [/shortening a weekly or monthly stay/, "تقصير إقامة بالسعر الأسبوعي أو الشهري يقرر تسويته المالك أو المدير."],
  [/tax settings are the owner/, "إعدادات الضريبة للمالك وحده."],
  [/supervisor corrects only the vouchers they issued/, "يصحح المشرف السندات التي أصدرها هو فقط؛ غيرها يصححه المالك أو المدير."],
  [/after 24 hours a voucher is corrected by a manager/, "مضت 24 ساعة على السند؛ يصححه الآن المالك أو المدير."],
  [/a manager signs out neither an owner nor a manager/, "لا يُخرج المالكَ أو مديرًا إلا المالك."],
  [/only the owner changes an owner/, "حساب المالك ودور المالك لا يغيّرهما إلا المالك."],
  [/PERMISSION_LOCKED/, "تعديل مصفوفة الصلاحيات للمالك وحده، ولا يُمنح لدور آخر."],
  [/UNKNOWN_PERMISSION/, "عملية غير معروفة في مصفوفة الصلاحيات."],
];
/** a refusal by the permissions matrix (0043): «FORBIDDEN: <code>», «FORBIDDEN: <code> (limited)», money, discounts */
function matrixRefusal(msg: string): string | null {
  if (/FORBIDDEN: money\b/.test(msg)) return "لا تسمح مصفوفة الصلاحيات لدورك برؤية المبالغ.";
  if (/FORBIDDEN: disc\.before \/ disc\.after/.test(msg)) return "لا تسمح مصفوفة الصلاحيات لدورك بالخصم.";
  const m = msg.match(/FORBIDDEN: ([a-z_]+(?:\.[a-z_]+)?)( \(limited\))?/);
  const row = m ? permissionRow(m[1]) : undefined;
  if (!m || !row) return null;
  return m[2] ? `دورك يملك «${row.label}» بقيدها فقط: ${row.limitNote ?? ""}.` : `لا تسمح مصفوفة الصلاحيات لدورك بـ«${row.label}». يغيّر ذلك المالك من «مصفوفة الصلاحيات».`;
}
function arabicMessage(msg: string): string {
  const v = msg.match(/VALIDATION:\s*([a-z_0-9]+)/i);
  if (v) return VALIDATION_AR[v[1]] ?? "بيانات غير صالحة: " + v[1];
  for (const [re, ar] of FORBIDDEN_AR) if (re.test(msg)) return ar;
  const matrix = matrixRefusal(msg);
  if (matrix) return matrix;
  for (const k of Object.keys(ERROR_AR)) if (msg.includes(k)) return ERROR_AR[k];
  if (/permission denied|row-level security/i.test(msg)) return ERROR_AR.FORBIDDEN;
  return "تعذّر تنفيذ العملية: " + msg.slice(0, 120);
}

/** The Arabic message for an error; a failed server operation also shows its trace code (decision 60). */
export function toArabicError(e: unknown): string {
  const msg = (e as { message?: string })?.message ?? String(e);
  const trace = (e as { traceId?: string })?.traceId;
  return trace ? `${arabicMessage(msg)} (رمز التتبع: ${trace})` : arabicMessage(msg);
}

/** Records a failed operation by its trace code only (no message text, no personal data). Best effort. */
function logClientError(traceId: string, message: string, fn: string) {
  void Promise.resolve(supabase.rpc("fn_log_client_error", { p_trace: traceId, p_code: errorCode(message), p_context: fn })).catch(() => undefined);
}

async function rpc<T = unknown>(fn: string, args: Record<string, unknown>): Promise<T> {
  const traceId = newTraceId();
  const call = supabase.rpc(fn, args) as unknown as { setHeader?: (n: string, v: string) => unknown };
  const request = (typeof call.setHeader === "function"
    ? (call.setHeader("x-correlation-id", traceId) as { setHeader: (n: string, v: string) => unknown }).setHeader("x-client-source", clientSource())
    : call) as PromiseLike<{ data: unknown; error: { message: string; code?: string } | null }>;
  const { data, error } = await request;
  if (error) {
    logClientError(traceId, error.message, fn);
    // a refusal may mean the session was ended by the owner (decision 34): the auth provider re-checks it
    if (error.code === "42501" || /FORBIDDEN|permission denied/i.test(error.message)) { try { window.dispatchEvent(new Event("zaaer:forbidden")); } catch { /* not in a browser */ } }
    throw new ApiError(error.message, error.code, traceId);
  }
  return data as T;
}

// ---------------------------------------------------------------------------
// Guest (token-scoped)
// ---------------------------------------------------------------------------
export interface PhoneReservation {
  ref: string; internal_ref: string; status: string; check_in: string; check_out: string; nights: number;
  branch_name: string | null; category_name: string | null; payment_status: string; access_status: string; identity_status: string;
}
export interface PhoneReservations { phone_last4: string; reservations: PhoneReservation[] }

export interface GuestSession {
  reservation: {
    id: string; internal_ref: string; external_ref: string | null; status: string; check_in: string; check_out: string;
    adults: number; companions: number; payment_status: string; identity_status: string; government_registration: boolean;
    access_status: string; total_halalas: number; paid_halalas: number; branch_name: string | null; room_number: string | null; category_name: string | null;
    /** 0033: a unit with a key box gets its code after the arrival; one without takes its key at reception */
    has_keybox?: boolean;
    /** 0033: the first night, paid in full before the arrival */
    first_night_paid?: boolean;
    /** 0038: the branch (for its map and platform links) and whether «ملخص الإقامة» was accepted */
    branch_id?: string;
    summary_accepted?: boolean;
  };
  guests: Array<{ id: string; is_primary: boolean; full_name: string; identity_type: string | null; identity_number_last4: string | null; nationality: string | null; birth_date: string | null; relationship: string | null; verification_status: string; data_submitted: boolean }>;
  access: { allowed: boolean; reasons: string[] };
  expires_at: string;
}

export const guestApi = {
  lookup: (externalRef: string, phoneLast4: string, sourceId?: string | null) =>
    rpc<{ status: "ok" | "unmatched" | "mismatch" | "throttled" | "invalid"; token?: string }>("fn_guest_lookup", { p_external_ref: externalRef, p_phone_last4: phoneLast4, p_source_id: sourceId ?? null, p_fingerprint: fingerprint() }),
  /** Phone-first lookup (0020): code by WhatsApp, or a booking number until WhatsApp is connected. */
  sendPhoneCode: async (phone: string): Promise<{ status: "sent" | "channel_unavailable" | "throttled" | "invalid" | "send_failed" }> => {
    const { data, error } = await supabase.functions.invoke("guest-otp", { body: { phone, client_fingerprint: fingerprint() } });
    if (error || !data) return { status: "send_failed" };
    return data;
  },
  verifyPhoneCode: (phone: string, code: string) =>
    rpc<{ status: "ok" | "mismatch" | "expired" | "throttled" | "invalid"; token?: string; attempts_left?: number }>("fn_guest_phone_verify", { p_phone: phone, p_code: code, p_fingerprint: fingerprint() }),
  verifyPhoneRef: (phone: string, ref: string) =>
    rpc<{ status: "ok" | "mismatch" | "throttled" | "invalid"; token?: string }>("fn_guest_phone_verify_ref", { p_phone: phone, p_ref: ref, p_fingerprint: fingerprint() }),
  phoneReservations: (token: string) => rpc<PhoneReservations>("fn_guest_phone_reservations", { p_token: token }),
  openPhoneReservation: (token: string, internalRef: string) => rpc<{ status: "ok"; token: string }>("fn_guest_phone_open", { p_token: token, p_internal_ref: internalRef }),
  session: (token: string) => rpc<GuestSession>("fn_guest_session", { p_token: token }),
  submit: (token: string, guestId: string | null, payload: Record<string, unknown>) => rpc<{ ok: boolean; guest_id: string }>("fn_guest_submit", { p_token: token, p_guest_id: guestId, p_payload: payload }),
  submitCheckin: (token: string) => rpc<{ ok: boolean; access_status: string }>("fn_guest_submit_checkin", { p_token: token }),
  accessCode: (token: string) => rpc<{ allowed: boolean; code?: string; room_number?: string; reasons?: string[] }>("fn_guest_access_code", { p_token: token }),
  /** «ملخص الإقامة» (decision 19): the text the guest accepts, with its hash */
  staySummary: (token: string) => rpc<GuestStaySummary>("fn_guest_stay_summary", { p_token: token }),
  acknowledge: (token: string, hash: string) => rpc<{ ok: boolean; duplicate: boolean; accepted_at: string }>("fn_guest_acknowledge", { p_token: token, p_hash: hash }),
  /** the branch as a guest page may show it (decisions 23, 31): the platform link, the map, the language, its logo and image */
  branch: (branchId: string) => rpc<PublicBranch | null>("fn_public_branch", { p_branch: branchId }),
  branchMedia: (branchId: string, kind: "logo" | "image") => rpc<string | null>("fn_branch_media", { p_branch: branchId, p_kind: kind }),
};
export interface PublicBranch { id: string; name_ar: string; name_en: string | null; city: string | null; address: string | null; phone: string | null; map_url: string | null; booking_platform_url: string | null; default_language: "ar" | "en"; country_code: string; check_in_time: string; check_out_time: string; logo_version: string | null; image_version: string | null }
export interface StaySummary {
  language: "ar" | "en"; text: string; hash: string;
  branch: { id: string; name: string; name_ar: string; name_en: string | null; city: string | null; address: string | null; phone: string | null; country_code: string; commercial_register: string | null; logo_version: string | null };
  reservation: { id: string; internal_ref: string; external_ref: string | null; source: string | null; guest_name: string | null; category: string | null; room_number: string | null; check_in: string; check_out: string; check_in_time: string; check_out_time: string; nights: number };
  money: { rent: number; discounts: number; extras: number; tax: number; total: number; paid: number; balance: number; deposit_required: number; deposit_held: number };
  policies: Array<{ title: string; content: string }>;
}
export interface Acknowledgement { id: string; method: "electronic" | "paper"; language: string; accepted_at: string; text_hash: string; recorded_by: string | null }
export type GuestStaySummary = StaySummary & { accepted_at: string | null; method: "electronic" | "paper" | null; current: boolean };

// ---------------------------------------------------------------------------
// Staff
// ---------------------------------------------------------------------------
export type GateResult = { ok: boolean; reasons?: string[]; code?: string; released_count?: number | null };

export const staffApi = {
  approveIdentity: (guestId: string, approve: boolean, reason?: string) => rpc<{ ok: boolean; identity_status: string }>("fn_staff_approve_identity", { p_guest_id: guestId, p_approve: approve, p_reason: reason ?? null }),
  confirmPayment: (reservationId: string, method: string, amountHalalas: number, reference: string, provider?: string) =>
    rpc<{ ok: boolean; duplicate: boolean; payment_status?: string; paid_halalas?: number }>("fn_staff_confirm_payment", { p_reservation: reservationId, p_method: method, p_amount_halalas: amountHalalas, p_reference: reference, p_idempotency_key: `${reservationId}:${method}:${reference}`, p_provider: provider ?? null }),
  assignRoom: (reservationId: string, roomId: string) => rpc<{ ok: boolean }>("fn_staff_assign_room", { p_reservation: reservationId, p_room: roomId }),
  /** «تسليم الرمز» (0033): only after the arrival, only for a unit with a key box */
  deliverAccessCode: (reservationId: string, channel: "screen" | "whatsapp" | "supervisor") => rpc<GateResult>("fn_staff_deliver_access_code", { p_reservation: reservationId, p_channel: channel }),
  markDeliveryFailed: (reservationId: string, reason: string) => rpc<{ ok: boolean }>("fn_staff_mark_delivery_failed", { p_reservation: reservationId, p_reason: reason }),
  completeCleaning: (taskId: string) => rpc<{ ok: boolean; room_status: string }>("fn_staff_complete_cleaning", { p_task: taskId }),
  rotateKeybox: (roomId: string, newCode: string, fieldTested: boolean) => rpc<{ ok: boolean; room_status: string; code_version: number }>("fn_staff_rotate_keybox_code", { p_room: roomId, p_new_code: newCode, p_field_tested: fieldTested }),
  markKeyboxTested: (roomId: string) => rpc<{ ok: boolean; room_status: string }>("fn_staff_mark_keybox_tested", { p_room: roomId }),
  createMaintenance: (roomId: string, title: string, description: string | null) => rpc<{ ok: boolean; ticket_id: string }>("fn_staff_create_maintenance", { p_room: roomId, p_title: title, p_description: description }),
  resolveMaintenance: (ticketId: string) => rpc<{ ok: boolean; room_status: string }>("fn_staff_resolve_maintenance", { p_ticket: ticketId }),
  resolveTicket: (ticketId: string) => rpc<{ ok: boolean }>("fn_staff_resolve_ticket", { p_ticket: ticketId }),
  releaseNextSlot: (branchId: string, categoryId: string, date: string, reason: string) => rpc<number>("fn_staff_release_next_slot", { p_branch: branchId, p_category: categoryId, p_date: date, p_reason: reason }),
  claimProfile: (fullName?: string) => rpc<{ ok: boolean; role?: string; claimed?: boolean; bootstrap?: boolean; error?: string }>("fn_claim_staff_profile", { p_full_name: fullName ?? null }),
  invite: (email: string, fullName: string, role: string, branchIds: string[]) => rpc<{ ok: boolean; staff_id: string }>("fn_staff_invite", { p_email: email, p_full_name: fullName, p_role: role, p_branch_ids: branchIds }),
  updateAiSettings: (patch: Record<string, unknown>) => rpc<{ ok: boolean }>("fn_admin_update_ai_settings", { p: patch }),
};

// ---------------------------------------------------------------------------
// The stay cycle (0033): Shomoos, the arrival and its two entries, night-by-night payment, the departure with
// nothing owed, the inspection, damages, «مغلق», and the corrections within their windows
// ---------------------------------------------------------------------------
/** What is due night by night (decision 3): the first night before the arrival, every later night by the branch's check-out time on its day. */
export interface StayDue {
  nights: number; nights_due: number; nights_covered: number; total: number; collected: number; first_night: number;
  due_now: number; shortfall_now: number; overdue: boolean; overdue_amount: number; overdue_since: string | null; overdue_through: string | null;
  next_unpaid_night: string | null; next_deadline: string | null; deadline_time: string; balance_due: number; deposit_required: number; deposit_balance: number;
}
/** Everything the stay page needs, for the signed-in role (fn_stay_status): money only for the money roles. */
export interface StayStatus {
  status: string; version: number; access_status: string; room_number: string | null; has_keybox: boolean;
  keybox_state: "none" | "unset" | "needs_change" | "untested" | "ready";
  departure_time: string; late_checkout_until: string | null; late_departure: boolean;
  checked_in_at: string | null; checked_in_by: string | null; checked_out_at: string | null; checked_out_by: string | null;
  checkin: null | { blockers: string[]; money_blockers?: string[]; first_night?: number; collected?: number; first_night_short?: number; deposit_required?: number; deposit_balance?: number; deposit_short?: number };
  code: null | { blockers: string[]; delivered: boolean };
  due: StayDue | null; overdue_blocked: boolean | null;
  payment_exception: null | { reason: string; through_night: string; by: string | null; at: string };
  deposit_waiver: null | { reason: string; at: string; by: string | null };
  shomoos: { registered: boolean; reference: string | null; registered_at: string | null; registered_by: string | null; guest_count: number | null; guests_now: number; accepted_at: string | null; accepted_by: string | null };
  inspection: null | { result: "ok" | "notes"; notes: string | null; suggested: number | null; by: string | null; at: string };
  inspection_due: boolean; deposit_refund_blocker: string | null;
  corrections: { allowed: boolean; undo_check_in_until: string | null; reopen_until: string | null; undo_cancel_until: string | null };
  closure: null | { closed: boolean; closed_at: string | null; missing: string[] };
}
/** One entry of the arrival screen: the rent receipt or the deposit receipt (each its own voucher). */
export interface PaymentEntry { amount_halalas: number; method: string; account_id?: string; reference?: string; idempotency_key: string }
export interface CheckInResult { ok: boolean; duplicate?: boolean; reasons?: string[]; has_keybox?: boolean; rent_voucher?: string | null; deposit_voucher?: string | null; released_count?: number | null; status?: string }
export interface CheckOutResult { ok: boolean; duplicate?: boolean; status?: string; balance_due?: number; reasons?: string[]; deposit_to_settle_halalas?: number; credit_halalas?: number; missing?: string[]; invoice?: string | null }
export interface StayFollowups {
  generated_at: string;
  overdue: Array<{ id: string; internal_ref: string; room_number: string | null; guest: string | null; overdue_amount: number; overdue_since: string | null; check_out: string; excused: boolean }>;
  departed_open: Array<{ id: string; internal_ref: string; room_number: string | null; guest: string | null; checked_out_at: string | null; missing: string[]; inspected: boolean; deposit_balance: number }>;
  late_departures: Array<{ id: string; internal_ref: string; room_number: string | null; guest: string | null; check_out: string; departure_time: string }>;
}
export interface DaySummary { date: string; everyone: boolean; rows: Array<{ staff_id: string | null; staff_name: string; kind: string; method: string | null; count: number; total: number }> }

export const stayApi = {
  status: (reservationId: string) => rpc<StayStatus | null>("fn_stay_status", { p_reservation: reservationId }),
  /** «تسجيل الوصول»: the conditions, then the rent and the deposit entries, then the arrival — all or nothing */
  checkIn: (p: { reservation_id: string; expected_version?: number; rent?: PaymentEntry; deposit?: PaymentEntry; deposit_reason?: string }) => rpc<CheckInResult>("fn_staff_check_in", { p }),
  /** Shomoos: «register» with the reference and «every guest registered», then «accept» once Shomoos accepted it */
  shomoos: (p: { reservation_id: string; action: "register" | "accept"; reference?: string; all_guests?: boolean }) => rpc<{ ok: boolean; unchanged: boolean }>("fn_staff_shomoos", { p }),
  /** the departure, with nothing owed for anyone (decision 8) */
  checkOut: (reservationId: string, version?: number) => rpc<CheckOutResult>("fn_staff_check_out", { p: version == null ? { reservation_id: reservationId } : { reservation_id: reservationId, expected_version: version } }),
  inspect: (p: { reservation_id: string; result: "ok" | "notes"; notes?: string; suggested_deduction_halalas?: number }) => rpc<{ ok: boolean; id: string }>("fn_staff_record_inspection", { p }),
  damage: (p: { reservation_id: string; amount_halalas: number; description?: string; reason: string; apply_deposit?: boolean; idempotency_key: string }) =>
    rpc<{ ok: boolean; duplicate: boolean; charge_id: string; from_deposit_halalas?: number; finance: Finance }>("fn_staff_add_damage", { p }),
  paymentException: (reservationId: string, reason: string) => rpc<{ ok: boolean; through_night: string }>("fn_staff_payment_exception", { p: { reservation_id: reservationId, reason } }),
  undoCheckIn: (reservationId: string, reason: string) => rpc<{ ok: boolean; code_needs_change: boolean }>("fn_staff_undo_check_in", { p: { reservation_id: reservationId, reason } }),
  reopenStay: (reservationId: string, reason: string) => rpc<{ ok: boolean; access_status: string }>("fn_staff_reopen_stay", { p: { reservation_id: reservationId, reason } }),
  undoCancel: (reservationId: string, reason: string) => rpc<{ ok: boolean; status: string }>("fn_staff_undo_cancel", { p: { reservation_id: reservationId, reason } }),
  followups: (branchId: string) => rpc<StayFollowups>("fn_stay_followups", { p_branch: branchId }),
  daySummary: (branchId: string, date: string) => rpc<DaySummary>("fn_staff_day_summary", { p_branch: branchId, p_date: date }),
};

// ---------------------------------------------------------------------------
// «الرموز» — the key-box codes of the units (supervisor and housekeeping; 0025)
// ---------------------------------------------------------------------------
/** change: must be changed (red) · untested: new code not yet tried on the box · ok · none: no key box for the unit */
export type KeyboxState = "change" | "untested" | "ok" | "none";
export interface KeyboxUnit {
  room_id: string; room_number: string; block: string | null; floor: string | null;
  room_status: string; cleanliness: string; guest_in_house: boolean;
  state: KeyboxState; has_code: boolean; code_version: number | null; field_tested: boolean;
  needs_change_since: string | null; last_changed_at: string | null; last_changed_by: string | null;
  /** for the signed-in user: housekeeping never acts on a unit with a guest in house */
  can_change: boolean; can_view: boolean;
}
export interface KeyboxAlerts { count: number; oldest_since: string | null; rooms: string[] }

export const codesApi = {
  board: (branchId: string) => rpc<KeyboxUnit[]>("fn_keybox_board", { p_branch: branchId }),
  alerts: (branchId: string) => rpc<KeyboxAlerts>("fn_keybox_alerts", { p_branch: branchId }),
  /** the current code (audited on the server, never stored in the browser) */
  reveal: (roomId: string) => rpc<{ ok: boolean; code: string; code_version: number }>("fn_keybox_reveal", { p_room: roomId }),
  change: (roomId: string, newCode: string, fieldTested: boolean) => staffApi.rotateKeybox(roomId, newCode, fieldTested),
  markTested: (roomId: string) => staffApi.markKeyboxTested(roomId),
};

// ---------------------------------------------------------------------------
// AI receptionist (Edge Function). The browser never talks to Gemini directly.
// ---------------------------------------------------------------------------
export interface AiReply {
  conversation_id: string;
  reply: string;
  actions: { label: string; route?: string }[];
  mode: "ai" | "scripted";
  verified: boolean;
  handed_off: boolean;
  ai_status?: string;
  intent?: string;
}

export async function aiChat(message: string, opts: { conversationId?: string | null; guestToken?: string | null; branchId?: string | null; channel?: "screen" | "whatsapp" }): Promise<AiReply> {
  const { data, error } = await supabase.functions.invoke<AiReply>("ai-reception", {
    body: { message, conversation_id: opts.conversationId ?? null, guest_token: opts.guestToken ?? null, branch_id: opts.branchId ?? null, channel: opts.channel ?? "screen", client_fingerprint: fingerprint() },
  });
  if (error || !data) throw new ApiError(error?.message ?? "AI_UNAVAILABLE");
  return data;
}

/**
 * ok: some model answered (the assistants use the first that does); model: the one they would use now — differs
 * from `primary` while the configured model is down; error: the configured model's failure; checked: every model probed.
 */
export interface AiHealth {
  configured: boolean;
  ok: boolean;
  primary?: string | null;
  model?: string | null;
  latency_ms?: number;
  error?: string;
  checked?: Array<{ model: string; ok: boolean; latency_ms?: number; error?: string }>;
}

export async function aiHealth(): Promise<AiHealth> {
  const { data, error } = await supabase.functions.invoke("ai-health", { body: {} });
  if (error) return { configured: false, ok: false, error: error.message };
  return data as AiHealth;
}

// ---------------------------------------------------------------------------
// WhatsApp per branch (0021) and data purge (0022) — owner only
// ---------------------------------------------------------------------------
export type WaMode = "web_bridge" | "cloud_api";
export type BridgeStatus = "starting" | "qr" | "connected" | "disconnected" | "stopped";
export interface WaChannelRow {
  branch_id: string; branch_name: string; branch_phone: string | null; mode: WaMode; enabled: boolean; display_phone: string | null;
  phone_number_id: string | null; waba_id: string | null; has_token: boolean; token_last4: string | null; has_app_secret: boolean;
  verify_token: string | null; otp_template: string | null; template_lang: string; status: "not_configured" | "configured" | "active" | "error";
  last_error: string | null; last_checked_at: string | null; verified_name: string | null; updated_at: string | null;
  // the reception computer (0023)
  auto_reply: boolean; human_pause_minutes: number; has_bridge_key: boolean; bridge_key_last4: string | null; bridge_key_created_at: string | null;
  bridge_status: BridgeStatus | null; bridge_phone: string | null; bridge_name: string | null; bridge_version: string | null;
  bridge_last_seen: string | null; bridge_online: boolean;
}
export interface WaReplyResult { ok: boolean; delivered: boolean; queued?: boolean; bridge_online?: boolean; error?: string }
export interface WaCheck { ok: boolean; verified_name?: string; display_phone_number?: string; quality_rating?: string; matches_number?: boolean; error?: string }
export interface PublicWhatsapp { active: boolean; wa_phone: string | null; branch_name: string; branch_phone: string | null }
export type PurgeCategory = "conversations" | "reservations" | "finance" | "guests" | "operations" | "logs" | "audit";
export interface PurgePreview { request_id: string; token: string; counts: Record<string, number>; categories: PurgeCategory[]; phrase: string; expires_in_minutes: number }
export interface PurgeHistoryRow { id: string; branch_name: string | null; from: string; to: string; categories: PurgeCategory[]; counts: Record<string, number>; executed_at: string; by: string | null }

export const whatsappApi = {
  channels: () => rpc<WaChannelRow[]>("fn_admin_whatsapp_channels", {}),
  /** bridge_key comes back once, only when it was just created (regenerate_bridge_key) */
  save: (branchId: string, patch: Record<string, unknown>) => rpc<{ ok: boolean; status: string; enabled: boolean; mode: WaMode; bridge_key?: string }>("fn_admin_whatsapp_save", { p_branch: branchId, p: patch }),
  publicInfo: (branchId: string) => rpc<PublicWhatsapp | null>("fn_public_whatsapp", { p_branch: branchId }),
  async check(branchId: string): Promise<WaCheck> {
    const { data, error } = await supabase.functions.invoke<WaCheck>("whatsapp-send", { body: { mode: "check", branch_id: branchId } });
    if (error || !data) return { ok: false, error: error?.message ?? "unavailable" };
    return data;
  },
  async reply(conversationId: string, text: string): Promise<WaReplyResult> {
    const { data, error } = await supabase.functions.invoke<WaReplyResult>("whatsapp-send", { body: { mode: "reply", conversation_id: conversationId, text } });
    if (error || !data) throw new ApiError(error?.message ?? "WHATSAPP_UNAVAILABLE");
    return data;
  },
  /** inbox: take a conversation (the assistant steps back; on WhatsApp for the branch's pause) or return it */
  take: (conversationId: string, take: boolean) => rpc<{ ok: boolean; status: string; human_active_until: string | null }>("fn_conversation_take", { p_conversation: conversationId, p_take: take }),
};

/** where the reception-computer program is published (next to the website, built by CI) */
export const BRIDGE_DOWNLOAD_PATH = "bridge/zaaer-whatsapp-bridge.zip";
/** bridge-config.json for the program on the reception computer (the key is shown this once) */
export function bridgeConfig(branchName: string, displayPhone: string | null, key: string, supabaseUrl: string) {
  return { server: `${supabaseUrl.replace(/\/$/, "")}/functions/v1/wa-bridge`, key, branch: branchName, branch_phone: displayPhone, created_at: new Date().toISOString() };
}

export const purgeApi = {
  preview: (branchId: string | null, from: string, to: string, categories: PurgeCategory[]) =>
    rpc<PurgePreview>("fn_admin_purge_preview", { p_branch: branchId, p_from: from, p_to: to, p_categories: categories }),
  execute: (token: string, phrase: string) => rpc<{ ok: boolean; counts: Record<string, number> }>("fn_admin_purge_execute", { p_token: token, p_phrase: phrase }),
  history: () => rpc<PurgeHistoryRow[]>("fn_admin_purge_history", {}),
};

/** What happened to a trace code (decision 60; owner and manager). */
export interface TraceLookup {
  failure: { trace_id: string; error_code: string; context: string | null; staff_name: string | null; created_at: string } | null;
  events: Array<{ action: string; entity_type: string | null; entity_id: string | null; actor_name: string | null; source: string | null; result: string | null; created_at: string }>;
}
export const supportApi = {
  /** The code as the employee read it: spaces, the "رمز التتبع:" label and lower case are tolerated. */
  lookupTrace: (code: string) => rpc<TraceLookup>("fn_lookup_trace", { p_trace: normalizeTrace(code) }),
};

// ---------------------------------------------------------------------------
// Core money (0028): cash boxes and bank accounts, the terminal settlement, platform payouts
// ---------------------------------------------------------------------------
export interface CashAccount { id: string; branch_id: string; kind: "cash_box" | "bank_account"; name: string; bank_name: string | null; account_last4: string | null; is_default: boolean; is_active: boolean; archived_at: string | null; archive_reason: string | null; version: number }
export interface PosDay {
  in_halalas: number; out_halalas: number; system_total_halalas: number; voucher_count: number;
  vouchers: Array<{ id: string; number: string; kind: string; amount_halalas: number; reference: string | null; occurred_at: string }>;
  settlement: PosSettlement | null;
}
export interface PosSettlement { id: string; account_id: string; business_date: string; terminal_total_halalas: number; system_total_halalas: number; difference_halalas: number; voucher_count: number; status: "matched" | "difference"; note: string | null; version: number; updated_at: string }
export interface PlatformPayment { id: string; number: string; kind: "receipt" | "refund"; amount_halalas: number; signed_halalas: number; occurred_at: string; reservation_id: string; internal_ref: string; external_ref: string | null; check_in: string; source_id: string; source_name: string | null }
export const moneyApi = {
  upsertAccount: (p: Partial<CashAccount> & { name: string }) => rpc<{ ok: boolean; id: string; version: number }>("fn_admin_upsert_cash_account", { p }),
  archiveAccount: (id: string, archive: boolean, reason: string) => rpc<{ ok: boolean; used_by_vouchers?: number; default_missing?: boolean; unchanged?: boolean }>("fn_admin_archive_cash_account", { p_id: id, p_archive: archive, p_reason: reason }),
  posDay: (branchId: string, accountId: string, date: string) => rpc<PosDay>("fn_pos_settlement_preview", { p_branch: branchId, p_account: accountId, p_date: date }),
  posSettle: (p: { branch_id: string; account_id: string; business_date: string; terminal_total_halalas: number; note?: string; version?: number }) => rpc<{ ok: boolean; settlement: PosSettlement }>("fn_pos_settle", { p }),
  platformUnsettled: (branchId: string) => rpc<PlatformPayment[]>("fn_platform_unsettled", { p_branch: branchId }),
  platformConfirm: (p: { branch_id: string; source_id: string; voucher_ids: string[]; received_halalas: number; received_on: string; account_id?: string; reference: string; note?: string }) => rpc<{ ok: boolean }>("fn_platform_payout_confirm", { p }),
  platformCancel: (id: string, reason: string) => rpc<{ ok: boolean }>("fn_platform_payout_cancel", { p_payout: id, p_reason: reason }),
};

function fingerprint(): string {
  try {
    let f = sessionStorage.getItem("fp");
    if (!f) { f = crypto.randomUUID(); sessionStorage.setItem("fp", f); }
    return f;
  } catch { return "anon"; }
}


// ---------------------------------------------------------------------------
// Property / operations / finance (0007) — all writes are SECURITY DEFINER RPCs
// ---------------------------------------------------------------------------
export type DefinitionEntity = "branch" | "block" | "floor" | "room_category" | "room" | "facility" | "task_type" | "service";
export interface UpsertResult { ok: boolean; id: string; version: number }
export interface Finance {
  rent: number; addons: number; discounts: number; penalties: number; adjustments: number; tax: number; total: number;
  received: number; refunded: number; deposit_applied: number; net_collected: number; balance_due: number; credit: number;
  deposit_received: number; deposit_refunded: number; deposit_balance: number; payment_status: string;
}
/** A run of nights at one price: [from, to) — to is exclusive (0030). */
export interface PriceRun { from: string; to: string; nights: number; price: number; basis: "base" | "calendar" | "platform" | "weekly" | "monthly" | "manual" | "kept" | "legacy" }
export interface Quote {
  nights: number; nightly_rate: number; rent: number; discount: number; tax: number; total: number; tax_rate_bp: number; prices_include_tax: boolean;
  /** 0030: the nights grouped by price, how the stay is priced, and on which row of the calendar */
  runs?: PriceRun[]; basis?: "daily" | "weekly" | "monthly" | "manual"; channel?: "system" | "platform";
  rent_gross?: number; computed_rent?: number; min_nightly?: number | null;
  /** how much discount the caller may give on this stay (decision 9) */
  discount_max?: number; supervisor_discount_max?: number; supervisor_max_discount_bp?: number;
}
export interface RateDay { night: string; price: number | null; platform_price: number | null; available: number }
export interface RateCategory { id: string; name: string; base_price: number; weekly_price: number | null; monthly_price: number | null; min_nightly: number | null; price_mode: "unified" | "by_channel"; units: number; days: RateDay[] }
export interface RateCalendar { today: string; from: string; to: string; categories: RateCategory[] }
export interface DiscountAllowance { rent: number; discounts: number; nights: number; after_arrival: boolean; max: number; percent_bp: number; min_nightly: number | null; unlimited: boolean }
export interface StayNight { night: string; price: number; basis: PriceRun["basis"]; status: "active" | "removed"; removed_at: string | null; removed_reason: string | null }
export interface DiscountReport {
  period: { from: string; to: string }; total_halalas: number; count: number;
  /** decision 36: the filters the figures were computed with */
  filters?: ReportFilters;
  by_staff: Array<{ staff: string | null; role: string | null; count: number; total_halalas: number }>;
  rows: Array<{ id: string; reservation_id: string; internal_ref: string; amount_halalas: number; reason: string | null; staff: string | null; role: string | null; created_at: string; after_arrival: boolean }> | null;
}

/** Rates (0030): the price calendar, the nights of a stay, discount allowance and report, the capacity impact of a type. */
export const ratesApi = {
  calendar: (branchId: string, from: string, to: string) => rpc<RateCalendar>("fn_rate_calendar", { p_branch: branchId, p_from: from, p_to: to }),
  set: (p: { branch_id: string; price_halalas?: number | null; platform_price_halalas?: number | null; clear?: boolean | "price" | "platform"; cells?: Array<{ category_id: string; night: string }>; from?: string; to?: string; category_ids?: string[]; weekdays?: number[]; reason?: string }) =>
    rpc<{ ok: boolean; changed: number; matched: number }>("fn_rate_calendar_set", { p }),
  allowance: (reservationId: string) => rpc<DiscountAllowance>("fn_discount_allowance", { p_reservation: reservationId }),
  nights: (reservationId: string) => rpc<StayNight[] | null>("fn_reservation_nights", { p_reservation: reservationId }),
  /** decision 36: filters by staff, source, unit type and «بعد الوصول»; every argument is named so the server resolves the one function */
  discounts: (branchId: string, from: string, to: string, filters: ReportFilters = {}) => rpc<DiscountReport>("fn_reports_discounts", { p_branch: branchId, p_from: from, p_to: to, p_filters: filters }),
  capacityImpact: (categoryId: string, maxCapacity: number) => rpc<Array<{ id: string; internal_ref: string; check_in: string; check_out: string; guests: number; status: string }>>("fn_category_capacity_impact", { p_category: categoryId, p_max_capacity: maxCapacity }),
};

export const opsApi = {
  // definitions
  upsertBranch: (p: Record<string, unknown>) => rpc<UpsertResult>("fn_admin_upsert_branch", { p }),
  upsertBlock: (p: Record<string, unknown>) => rpc<UpsertResult>("fn_admin_upsert_block", { p }),
  upsertFloor: (p: Record<string, unknown>) => rpc<UpsertResult>("fn_admin_upsert_floor", { p }),
  upsertRoomCategory: (p: Record<string, unknown>) => rpc<UpsertResult>("fn_admin_upsert_room_category", { p }),
  upsertRoom: (p: Record<string, unknown>) => rpc<UpsertResult>("fn_admin_upsert_room", { p }),
  upsertFacility: (p: Record<string, unknown>) => rpc<UpsertResult>("fn_admin_upsert_facility", { p }),
  upsertTaskType: (p: Record<string, unknown>) => rpc<UpsertResult>("fn_admin_upsert_task_type", { p }),
  upsertService: (p: Record<string, unknown>) => rpc<UpsertResult>("fn_admin_upsert_service", { p }),
  archiveDefinition: (entity: DefinitionEntity, id: string, reason: string, archive = true) => rpc<{ ok: boolean }>("fn_admin_archive_definition", { p_entity: entity, p_id: id, p_reason: reason, p_archive: archive }),
  deleteDefinition: (entity: DefinitionEntity, id: string) => rpc<{ ok: boolean; error?: string; dependencies?: Record<string, number> }>("fn_admin_delete_definition", { p_entity: entity, p_id: id }),
  dependencies: (entity: DefinitionEntity, id: string) => rpc<Record<string, number>>("fn_definition_dependencies", { p_entity: entity, p_id: id }),

  // reservations
  /** the stay's quote night by night (0030): the source decides the calendar row (system or platform) */
  quote: (branchId: string, categoryId: string, checkIn: string, checkOut: string, nightlyOverride?: number | null, discount?: number, sourceId?: string | null) =>
    rpc<Quote>("fn_quote_stay", { p: { branch_id: branchId, category_id: categoryId, check_in: checkIn, check_out: checkOut, source_id: sourceId ?? null, nightly_rate_halalas: nightlyOverride ?? null, discount_halalas: discount ?? 0 } }),
  availableRooms: (branchId: string, from: string, to: string, categoryId?: string | null, excludeReservation?: string | null) =>
    rpc<Array<{ room_id: string; room_number: string; category_id: string; category_name: string; status: string; cleanliness: string; block_name: string | null; floor_name: string | null }>>("fn_available_rooms", { p_branch: branchId, p_from: from, p_to: to, p_category: categoryId ?? null, p_exclude_reservation: excludeReservation ?? null }),
  createReservation: (p: Record<string, unknown>) => rpc<{ ok: boolean; id: string; internal_ref: string; quote: Quote }>("fn_staff_create_reservation", { p }),
  amendStay: (id: string, newCheckOut: string, pricingMode: "keep_rate" | "reprice", reason: string, version?: number) =>
    rpc<{ ok: boolean; delta_nights?: number; finance?: Finance }>("fn_staff_amend_stay", { p_reservation: id, p_new_check_out: newCheckOut, p_pricing_mode: pricingMode, p_reason: reason, p_expected_version: version ?? null }),
  switchRoom: (id: string, roomId: string, effective: string | null, reason: string, version?: number) =>
    rpc<{ ok: boolean; entry_code_review_required: boolean; code_delivery_required?: boolean }>("fn_staff_switch_room", { p_reservation: id, p_room: roomId, p_effective: effective, p_reason: reason, p_expected_version: version ?? null }),
  adjustPrice: (id: string, kind: "discount" | "adjustment" | "penalty" | "addon", amountHalalas: number, description: string, reason: string, version?: number) =>
    rpc<{ ok: boolean; finance: Finance }>("fn_staff_adjust_price", { p_reservation: id, p_kind: kind, p_amount_halalas: amountHalalas, p_description: description, p_reason: reason, p_expected_version: version ?? null }),
  addService: (id: string, serviceId: string, quantity = 1, note?: string) => rpc<{ ok: boolean; finance: Finance; late_checkout_until?: string | null }>("fn_staff_add_service", { p_reservation: id, p_service: serviceId, p_quantity: quantity, p_note: note ?? null }),
  /** cancelling (decision 4): a platform's booking with the platform's cancellation number (once), the whole group at once; never a refund by itself */
  cancel: (p: { reservation_id: string; reason: string; cancel_number?: string | null; by_platform?: boolean; whole_group?: boolean }) =>
    rpc<{ ok: boolean; duplicate: boolean; cancelled: number; status: string; refund_required_separately?: boolean; platform_collected?: boolean }>("fn_staff_cancel", { p }),
  /** the office path of guest data (decision 2): from the original document, verified at once; a correction with a reason */
  enterGuest: (p: { reservation_id: string; guest_id?: string | null; full_name: string; identity_type: string; identity_number: string; identity_issue_number?: string | null; nationality: string; birth_date: string; phone?: string | null; relationship?: string | null; document_matched: boolean; reason?: string | null }) =>
    rpc<{ ok: boolean; guest_id: string; identity_status: string }>("fn_staff_enter_guest", { p }),
  /** a hold on one booking (decision 21): placed by the supervisor and up, lifted by the owner or a manager */
  setHold: (reservationId: string, hold: boolean, reason: string) => rpc<{ ok: boolean; duplicate: boolean }>("fn_staff_set_hold", { p: { reservation_id: reservationId, hold, reason } }),
  /** «ملخص الإقامة» to print, with the acknowledgements on file; the paper signature recorded against the printed text */
  staySummary: (reservationId: string) => rpc<StaySummary & { acknowledgements: Acknowledgement[] }>("fn_stay_summary", { p_reservation: reservationId }),
  recordPaperAck: (reservationId: string, textHash: string) => rpc<{ ok: boolean; duplicate: boolean; accepted_at: string }>("fn_staff_record_paper_ack", { p: { reservation_id: reservationId, text_hash: textHash } }),
  /** the platforms' daily list (decision 4): today's and tomorrow's arrivals, matched against the platform */
  platformCheckList: (branchId: string, date?: string | null) => rpc<{ date: string; rows: PlatformCheckRow[] }>("fn_platform_check_list", { p_branch: branchId, p_date: date ?? null }),
  /** B4 (0048): the platform's number, booking day and who collects, corrected before arrival (the group's units together) */
  platformUpdate: (reservationId: string, p: { external_ref?: string | null; platform_booked_on?: string | null; platform_collects?: boolean }, reason: string, version?: number) =>
    rpc<{ ok: boolean; units: number; vouchers: string[] }>("fn_staff_update_platform", { p_reservation: reservationId, p, p_reason: reason, p_expected_version: version ?? null }),
  platformMarkChecked: (reservationId: string, checked = true) => rpc<{ ok: boolean; units: number }>("fn_platform_mark_checked", { p: { reservation_id: reservationId, checked } }),
  /** the group's page (decision 69): every unit with its money, and the totals */
  groupSummary: (reservationId: string) => rpc<GroupSummary | null>("fn_reservation_group_summary", { p_reservation: reservationId }),
  /** the red alerts, holds and ratings of a branch's current bookings */
  flags: (branchId: string) => rpc<Record<string, { ban: boolean; hold: boolean; rating: number | null }>>("fn_reservation_flags", { p_branch: branchId }),
  noShow: (id: string, reason: string) => rpc<{ ok: boolean }>("fn_staff_no_show", { p_reservation: id, p_reason: reason }),
  detail: (id: string) => rpc<ReservationDetail | null>("fn_reservation_detail", { p_reservation: id }),
  list: (branchId: string, filters: ReservationListFilters, limit = 50, offset = 0) => rpc<{ total: number; rows: ReservationRow[] }>("fn_reservation_list", { p_branch: branchId, p_filters: filters, p_limit: limit, p_offset: offset }),

  // money
  createVoucher: (p: { reservation_id: string; kind: "receipt" | "deposit"; amount_halalas: number; method: string; account_id?: string; reference?: string; note?: string; reason?: string; idempotency_key: string }) =>
    rpc<{ ok: boolean; duplicate: boolean; voucher_id: string; number: string; finance: Finance }>("fn_create_voucher", { p }),
  refund: (p: { reservation_id: string; kind: "refund" | "deposit_refund" | "deposit_apply"; amount_halalas: number; method?: string; account_id?: string; reference?: string; reason: string; idempotency_key: string; original_voucher_id?: string }) =>
    rpc<{ ok: boolean; duplicate: boolean; voucher_id: string; number: string; finance: Finance }>("fn_refund", { p }),
  cancelVoucher: (id: string, reason: string) => rpc<{ ok: boolean; finance: Finance; provider_refund_note?: string }>("fn_cancel_voucher", { p_voucher: id, p_reason: reason }),
  createInvoice: (reservationId: string, from?: string, to?: string) => rpc<{ ok: boolean; id: string; number: string; total_halalas: number }>("fn_create_invoice", { p_reservation: reservationId, p_from: from ?? null, p_to: to ?? null }),
  cancelInvoice: (id: string, reason: string) => rpc<{ ok: boolean }>("fn_cancel_invoice", { p_invoice: id, p_reason: reason }),
  finance: (reservationId: string) => rpc<Finance>("fn_reservation_finance", { p_reservation: reservationId }),

  // housekeeping
  createTask: (p: Record<string, unknown>) => rpc<{ ok: boolean; id: string }>("fn_hk_create_task", { p }),
  startTask: (id: string) => rpc<{ ok: boolean }>("fn_hk_start_task", { p_task: id }),
  completeTask: (id: string, note?: string, version?: number) => rpc<{ ok: boolean; room_status?: string }>("fn_hk_complete_task", { p_task: id, p_note: note ?? null, p_expected_version: version ?? null }),
  cancelTask: (id: string, reason: string) => rpc<{ ok: boolean }>("fn_hk_cancel_task", { p_task: id, p_reason: reason }),
  assignTask: (id: string, assigneeId: string | null) => rpc<{ ok: boolean }>("fn_hk_assign_task", { p_task: id, p_assignee: assigneeId }),
  setCleanliness: (roomId: string, state: "clean" | "dirty", reason?: string) => rpc<{ ok: boolean; room_status: string }>("fn_hk_set_cleanliness", { p_room: roomId, p_state: state, p_reason: reason ?? null }),

  // operations
  unitsBoard: (branchId: string) => rpc<UnitCard[]>("fn_ops_units_board", { p_branch: branchId }),
  dailySummary: (branchId: string, date?: string) => rpc<DailySummary | null>("fn_ops_daily_summary", { p_branch: branchId, p_date: date ?? null }),

  // reports (GAP05): money KPIs come from the voucher ledger, never from reservation totals. Role-gated on the server.
  reportsFinance: (branchId: string, from: string, to: string, filters: ReportFilters = {}) => rpc<ReportsFinance>("fn_reports_finance", { p_branch: branchId, p_from: from, p_to: to, p_filters: filters }),

  // AI ops proposals (human-in-the-loop)
  executeProposal: (id: string) => rpc<{ ok: boolean; result?: unknown; error?: string }>("fn_ai_ops_execute_proposal", { p_id: id }),
  rejectProposal: (id: string, reason?: string) => rpc<{ ok: boolean }>("fn_ai_ops_reject_proposal", { p_id: id, p_reason: reason ?? null }),
};

export interface ReservationRow {
  id: string; internal_ref: string; external_ref: string | null; status: string; check_in: string; check_out: string; nights: number;
  guest_name: string | null; room_number: string | null; source_name: string | null; category_name: string | null;
  /** money: null for housekeeping (the server leaves the money columns empty for roles without money) */
  total_halalas: number; paid_halalas: number; balance_due_halalas: number; deposit_balance_halalas: number;
  payment_status: string; identity_status: string; access_status: string; created_at: string;
  /** 0038: the group, the hold, the ban (money roles) and the main guest's rating (owner, manager, supervisor) */
  group_ref?: string | null; hold?: boolean; ban?: boolean | null; rating?: number | null;
  /** 0040 (decision 14): the columns the column picker offers */
  booking_type?: string | null; company_name?: string | null; price_basis?: string | null; adults?: number; companions?: number;
  platform_booked_on?: string | null; platform_collects?: boolean | null; created_by_name?: string | null;
  actual_check_in?: string | null; actual_check_out?: string | null; cancelled_at?: string | null; cancel_reference?: string | null;
  discount_halalas?: number | null; nightly_rate_halalas?: number | null;
}
/** The filters of the reservations list (0040, decision 14): every one of the reference, and a sort. Dates are ISO days; csv for several statuses. */
export interface ReservationListFilters {
  status?: string; open_only?: boolean | string; check_in_from?: string; check_in_to?: string; check_out_from?: string; check_out_to?: string;
  created_from?: string; created_to?: string; stay_on?: string; source_id?: string; category_id?: string; room_id?: string; room_number?: string;
  booking_type?: string; company?: string; price_basis?: string; payment_status?: string; identity_status?: string; access_status?: string;
  group_ref?: string; has_discount?: boolean | string; platform_collects?: boolean | string; has_balance?: boolean | string; q?: string;
  sort?: "check_in_asc" | "check_out" | "created" | "ref";
}
/** The filters a report takes beside its period (decision 36); each report reads the ones its data has. */
export interface ReportFilters { staff_id?: string; method?: string; account_id?: string; source_id?: string; category_id?: string; after_arrival?: boolean }
export interface ReservationDetail {
  reservation: Record<string, unknown> & { id: string; internal_ref: string; status: string; check_in: string; check_out: string; version: number; branch_id: string; room_id: string | null; room_category_id: string | null; adults: number; companions: number; nightly_rate_halalas: number; external_ref: string | null; actual_check_in: string | null; actual_check_out: string | null; cancel_reason: string | null };
  notes: string | null;
  source: { name: string; code: string; kind: string } | null;
  category: string | null;
  room: { id: string; room_number: string; status: string; cleanliness: string } | null;
  guests: Array<{ id: string; is_primary: boolean; full_name: string; identity_type: string | null; identity_number_last4: string | null; nationality: string | null; phone: string | null; relationship?: string | null; birth_date?: string | null; verification_status: string; data_submitted: boolean;
    entry_path?: "guest" | "office" | null; verified_at?: string | null; verified_by?: string | null; profile_id?: string | null; profile_mismatch?: boolean }>;
  /** phase 5 (0038): the active bans matching the guests, the main guest's rating, the hold, the platform's fields, the stay summary's acknowledgements */
  bans?: Array<{ ban_id: string; name: string; reason: string; since: string; matched_by: string[] }> | null;
  guest_profile?: { id: string; rating: number | null; rating_note: string | null; rated_at: string | null; rated_by: string | null; stays: number } | null;
  hold?: { reason: string | null; at: string | null; by: string | null } | null;
  platform?: { booked_on: string | null; collects: boolean | null; verified_at: string | null; verified_by: string | null; cancel_reference: string | null } | null;
  acknowledgements?: Acknowledgement[] | null;
  allocations: Array<{ id: string; room_number: string; from_date: string; to_date: string; status: string; reason: string | null; created_at: string }>;
  charges: Array<{ id: string; kind: string; description: string; quantity: number; unit_price_halalas: number; total_halalas: number; invoice_id: string | null; reason: string | null; created_at: string; invoiced_halalas?: number; service_from?: string; service_to?: string }> | null;
  vouchers: Array<{ id: string; number: string; kind: string; amount_halalas: number; method: string; account_id: string | null; payout_id: string | null; status: string; reference: string | null; note: string | null; reason: string | null; occurred_at: string; cancel_reason: string | null;
    created_at?: string; created_by?: string | null; created_by_name?: string | null; original_voucher_id?: string | null; original_number?: string | null; replaced_by_number?: string | null }> | null;
  invoices: Invoice[] | null;
  /** the stay's value not yet carried by an issued invoice (negative: the invoices carry more than its lines) */
  invoicing?: { uninvoiced_halalas: number } | null;
  finance: Finance | null;
  history: Array<{ action: string; at: string; actor: string | null; details: Record<string, unknown> | null }>;
}
/** One line of an invoice: its share of a line of the stay (a line can be split over period invoices — 0036). */
export interface InvoiceLine { charge_id: string; kind: string; description: string; quantity: number; unit_price_halalas: number; total_halalas: number; amount_halalas: number; service_from: string; service_to: string; invoiced_halalas?: number }
export interface InvoiceVersion { version: number; period_from: string; period_to: string; bill_to: { name?: string; note?: string }; subtotal_halalas: number; tax_halalas: number; total_halalas: number; lines: InvoiceLine[]; since: string; by: string | null; replaced_at: string; replaced_by: string | null; reason: string }
export interface Invoice {
  id: string; number: string; status: "issued" | "cancelled"; scope: "period" | "remaining"; origin: "manual" | "checkout" | "deposit_settled"; version: number;
  subtotal_halalas: number; tax_halalas: number; total_halalas: number; issued_at: string; issued_by: string | null; updated_at: string | null; updated_by: string | null;
  cancelled_at: string | null; cancel_reason: string | null; period_from: string; period_to: string; bill_to: { name?: string; note?: string }; lines: InvoiceLine[]; versions: InvoiceVersion[];
}
export interface InvoicePreview {
  ok: boolean; problems: string[]; scope: "period" | "remaining"; from: string | null; to: string | null; lines: InvoiceLine[]; subtotal_halalas: number; tax_halalas: number; total_halalas: number;
  reservation: { id: string; internal_ref: string; external_ref: string | null; guest: string | null; check_in: string; check_out: string; status: string }; uninvoiced_halalas: number;
}
export interface ReviewItem {
  id: string; kind: string; entity_type: string; entity_id: string | null; reservation_id: string | null; internal_ref: string | null; branch_id: string | null; branch_name: string | null;
  summary: string; reason: string | null; details: Record<string, unknown> | null; created_at: string; created_by: string | null; reviewed_at: string | null; reviewed_by: string | null; review_note: string | null;
}
export interface ReviewSummary { open: number; oldest_at: string | null; monitors: number; by_kind: Record<string, number> }

/** Invoices (decisions 26, 27): partial by period with a preview, edited with a reason (versions kept), cancelled by management. */
export const invoiceApi = {
  preview: (p: { reservation_id?: string; invoice_id?: string; from?: string | null; to?: string | null }) => rpc<InvoicePreview>("fn_invoice_preview", { p }),
  issue: (p: { reservation_id: string; from?: string | null; to?: string | null; bill_to?: { name?: string; note?: string } }) =>
    rpc<{ ok: boolean; id: string; number: string; total_halalas: number; period_from: string; period_to: string; scope: string; line_count: number }>("fn_staff_issue_invoice", { p }),
  edit: (p: { invoice_id: string; reason: string; bill_to?: { name?: string; note?: string }; from?: string; to?: string }) =>
    rpc<{ ok: boolean; unchanged: boolean; id: string; number: string; version: number; total_halalas?: number }>("fn_staff_edit_invoice", { p }),
  cancel: (id: string, reason: string) => rpc<{ ok: boolean }>("fn_cancel_invoice", { p_invoice: id, p_reason: reason }),
  /** «تصحيح سند» (decision 11): the original cancelled and its replacement issued in one step, with a reason */
  correctVoucher: (p: { voucher_id: string; reason: string; idempotency_key: string; amount_halalas?: number; method?: string; reference?: string | null; account_id?: string | null; note?: string | null }) =>
    rpc<{ ok: boolean; duplicate: boolean; voucher_id: string; number: string; original_number: string; finance: Finance }>("fn_staff_correct_voucher", { p }),
};

/** «بحاجة لمراجعة وتدقيق» — the owner's review list (§16), and the monitors of decision 54. */
export const reviewApi = {
  list: (p: { status?: "open" | "reviewed" | "all"; kind?: string; branch_id?: string; before?: string; limit?: number }) => rpc<{ items: ReviewItem[]; open_count: number }>("fn_review_list", { p }),
  mark: (ids: string[], note?: string) => rpc<{ ok: boolean; marked: number }>("fn_review_mark", { p: { ids, note: note ?? null } }),
  summary: () => rpc<ReviewSummary | null>("fn_review_summary", {}),
  monitorsIfDue: (branchId: string) => rpc<{ ran: boolean; last_run_at: string | null; found?: Record<string, number>; summary: ReviewSummary | null }>("fn_monitors_if_due", { p_branch: branchId }),
};

export interface PlatformCheckRow { id: string; internal_ref: string; external_ref: string | null; source_name: string; source_code: string; status: string; check_in: string; check_out: string; nights: number; guests: number; guest_name: string | null; group_ref: string | null; platform_collects: boolean | null; platform_booked_on: string | null; total_halalas: number; paid_halalas: number; cancel_reference: string | null; verified_at: string | null; verified_by: string | null }
export interface GroupSummary {
  group_ref: string; external_ref: string | null; source_name: string | null;
  units: Array<{ id: string; internal_ref: string; status: string; check_in: string; check_out: string; adults: number; companions: number; room_number: string | null; category_name: string | null; total_halalas: number | null; paid_halalas: number | null; balance_due_halalas: number | null; deposit_balance_halalas: number | null }>;
  totals: { units: number; active_units?: number; total_halalas?: number; paid_halalas?: number; balance_due_halalas?: number; deposit_balance_halalas?: number };
}
export interface GuestProfileRow { id: string; full_name: string; phone_masked: string | null; nationality: string | null; identity_type: string | null; identity_last4: string | null; rating: number | null; rating_note: string | null; stays: number; last_check_in: string | null; banned: boolean; ban_reason: string | null; duplicates: number; created_at: string }
export interface GuestProfileDetail {
  profile: { id: string; full_name: string; phone: string | null; nationality: string | null; email: string | null; identity_type: string | null; identity_last4: string | null; rating: number | null; rating_note: string | null; rated_at: string | null; rated_by: string | null; created_at: string };
  ban: { id: string; reason: string; since: string; own: boolean; by: string | null } | null;
  ban_history: Array<{ id: string; reason: string; since: string; by: string | null; lifted_at: string | null; lifted_by: string | null; lift_reason: string | null }>;
  stays: Array<{ reservation_id: string; internal_ref: string; external_ref: string | null; status: string; check_in: string; check_out: string; branch_name: string | null; is_primary: boolean; room_number: string | null; category_name: string | null; source_name: string | null }>;
  duplicates: Array<{ id: string; full_name: string; match: "identity" | "phone"; stays: number }>;
  can_ban: boolean;
}
/** Guest profiles (decisions 2, 21): search, one profile with its stays, the rating, the ban. */
export const guestProfileApi = {
  list: (p: { q?: string; filter?: "all" | "banned" | "duplicates" | "rated" | "low"; limit?: number; offset?: number }) => rpc<{ total: number; rows: GuestProfileRow[] }>("fn_guest_profiles", { p }),
  get: (id: string) => rpc<GuestProfileDetail>("fn_guest_profile", { p_id: id }),
  rate: (profileId: string, rating: number | null, note: string | null) => rpc<{ ok: boolean; rating: number | null }>("fn_guest_rate", { p: { profile_id: profileId, rating, note } }),
  ban: (profileId: string, reason: string) => rpc<{ ok: boolean; duplicate: boolean; ban_id?: string }>("fn_guest_ban", { p: { profile_id: profileId, ban: true, reason } }),
  unban: (profileId: string, reason: string) => rpc<{ ok: boolean; duplicate: boolean; ban_id?: string }>("fn_guest_ban", { p: { profile_id: profileId, ban: false, reason } }),
};
/** The owner's and the manager's reports of phase 5 (decisions 2, 4). */
export const guestReportsApi = {
  lateEntries: (branchId: string, from: string, to: string, minDays = 1, filters: ReportFilters = {}) => rpc<{ platform_bookings: number; late: number; after_arrival: number; by_staff: Array<{ staff: string; count: number; max_lag: number }>; rows: Array<{ id: string; internal_ref: string; external_ref: string | null; source_name: string | null; booked_on: string; entered_on: string; entered_at: string; lag_days: number; check_in: string; after_arrival: boolean; status: string; created_by: string | null }> }>("fn_reports_late_entries", { p_branch: branchId, p_from: from, p_to: to, p_min_days: minDays, p_filters: filters }),
  identities: (branchId: string, from: string, to: string, path: "office" | "guest" | "all" = "office", filters: ReportFilters = {}) => rpc<{ count: number; by_staff: Array<{ staff: string; office: number; guest: number }>; rows: Array<{ guest_id: string; reservation_id: string; internal_ref: string; full_name: string; is_primary: boolean; identity_type: string | null; identity_last4: string | null; entry_path: string | null; entered_by: string | null; entered_at: string | null; verified_by: string | null; verified_at: string }> }>("fn_reports_identities", { p_branch: branchId, p_from: from, p_to: to, p_path: path, p_filters: filters }),
};
/** The branch's media (decision 31): the logo (≤200 KB) and the image (≤1 MB), kept with the branch's settings. */
export const branchMediaApi = {
  set: (branchId: string, kind: "logo" | "image", dataBase64: string | null) => rpc<{ ok: boolean; changed: boolean; media: { mime: string; size_bytes: number; sha256: string } | null }>("fn_admin_set_branch_media", { p: { branch_id: branchId, kind, data_base64: dataBase64 ?? "" } }),
  info: (branchId: string) => rpc<Record<"logo" | "image", { mime: string; size_bytes: number; updated_at: string; updated_by: string | null } | undefined>>("fn_admin_branch_media_info", { p_branch: branchId }),
  setSourceActive: (id: string, isActive: boolean, reason?: string | null) => rpc<{ ok: boolean; changed: boolean }>("fn_admin_set_source_active", { p: { id, is_active: isActive, reason: reason ?? null } }),
};
export interface UnitCard {
  room_id: string; room_number: string; category: string; block: string | null; floor: string | null; is_active: boolean; status: string; cleanliness: string;
  open_tasks: number; open_maintenance: number; keybox_ready: boolean;
  current: { reservation_id: string; internal_ref: string; status: string; check_in: string; check_out: string; guest: string; balance_due: number } | null;
  next: { internal_ref: string; check_in: string } | null;
}
/** fn_reports_finance(p_branch, p_from, p_to) — all amounts are halalas (integers). */
export interface ReportsFinance {
  period: { from: string; to: string };
  /** Approved vouchers dated inside the period. */
  ledger: { receipts: number; refunds: number; net_collected: number; deposits_received: number; deposits_refunded: number; deposits_applied: number; deposit_balance_open: number };
  /** Charges of the stays that intersect the period (discounts are negative). */
  charges: { total_charged: number; rent: number; addons: number; discounts: number; tax: number };
  /** net_collected ÷ total_charged in percent (one decimal); null when nothing was charged. */
  collection_rate_pct: number | null;
  by_method: Array<{ method: string; amount_halalas: number }>;
  by_day: Array<{ day: string; receipts: number; refunds: number }>;
  /** decision 36: per staff member (receipts and refunds they recorded) and per box or account */
  by_staff?: Array<{ staff_id: string | null; staff: string; receipts: number; refunds: number; count: number }>;
  by_account?: Array<{ account_id: string; account: string; in_halalas: number; out_halalas: number }>;
  filters?: ReportFilters; filtered?: boolean;
  reservations: { count: number; nights: number; cancelled: number; no_show: number; by_source: Array<{ source: string; count: number; total_halalas: number }> };
  definitions: { revenue: string; collection_rate: string };
}
export interface DailySummary {
  date: string; occupancy_pct: number;
  units: { active: number; occupied: number; reserved: number; ready: number; dirty: number; maintenance: number; out_of_service: number };
  arrivals: { expected: number; arrived: number; pending_identity: number; unpaid: number; overdue: number };
  departures: { expected: number; done: number; overstay: number; with_balance: number };
  housekeeping: { open: number; in_progress: number; completed_today: number; unassigned: number };
  finance: { received_today: number; refunded_today: number; deposits_held: number; outstanding_in_house: number; deposit_to_settle_after_checkout: number };
  tickets_open: number; generated_at: string;
}


// ---------------------------------------------------------------------------
// Phase 6 (0040–0041): the lists, the calendar, the log, the ledger, saved views, the staff editor, capability usage
// ---------------------------------------------------------------------------
export interface SavedView { id: string; name: string; filters: Record<string, unknown>; columns: string[] | null; is_default: boolean; updated_at: string }
export type SavedViewScreen = "reservations" | "vouchers" | "audit";
export interface CalendarUnit { room_id: string; room_number: string; category_id: string | null; category: string | null; floor_id: string | null; floor: string | null; block: string | null; status: string; cleanliness: string; is_active: boolean }
export interface CalendarSegment { room_id: string; reservation_id: string; internal_ref: string; status: string; from_date: string; to_date: string; starts_before: boolean; ends_after: boolean; guest: string | null; source: string | null; group_ref: string | null; payment_status: string | null; balance_due_halalas: number | null }
export interface ReservationCalendar { from: string; to: string; today: string; units: CalendarUnit[]; segments: CalendarSegment[] }
export interface AuditListFilters { branch_id?: string; from?: string; to?: string; actor_id?: string; action?: string; action_prefix?: boolean; entity_type?: string; entity_id?: string; correlation_id?: string; category?: "business" | "security"; result?: string; source?: string; q?: string; limit?: number; offset?: number }
export interface AuditRow {
  id: string; created_at: string; action: string; action_label: string; entity_type: string | null; entity_label: string; entity_id: string | null; entity_ref: string | null;
  actor_id: string | null; actor_name: string | null; actor_type: string | null; source: string | null; result: string | null; category: string; correlation_id: string | null;
  branch_id: string | null; branch_name: string | null; reason: string | null; details: Record<string, unknown> | null;
}
export interface AuditList { total: number; rows: AuditRow[]; limit: number; offset: number; tz: string }
export interface VoucherListFilters { branch_id: string; from?: string; to?: string; kind?: string; method?: string; account_id?: string; status?: "approved" | "cancelled" | "all"; staff_id?: string; reservation_id?: string; q?: string; limit?: number; offset?: number }
export interface VoucherRow {
  id: string; number: string; kind: string; amount_halalas: number; method: string; status: string; reference: string | null; reason: string | null; note: string | null; occurred_at: string;
  cancel_reason: string | null; cancelled_at: string | null; created_by: string | null; creator_name: string | null; account_id: string | null; account_name: string | null; payout_id: string | null;
  original_voucher_id: string | null; original_number: string | null; reservation: { id: string; internal_ref: string | null } | null;
}
export interface VoucherTotals { receipts: number; refunds: number; deposits: number; deposit_refunds: number; deposit_applied: number; approved: number; cancelled: number; by_method: Array<{ method: string; amount_halalas: number }>; by_account: Array<{ account_id: string; account_name: string | null; in_halalas: number; out_halalas: number }> }
export interface VoucherList { total: number; rows: VoucherRow[]; totals: VoucherTotals; limit: number; offset: number; tz: string }
export interface ReportFilterOptions { staff: Array<{ id: string; name: string; role: string; is_active: boolean }>; accounts: Array<{ id: string; name: string; kind: string; is_active: boolean }>; sources: Array<{ id: string; name: string; kind: string; is_active: boolean }>; categories: Array<{ id: string; name: string }>; floors: Array<{ id: string; name: string; block: string | null }> }

export const listsApi = {
  /** the units × days calendar of a branch (decision 14, 10.2): at most 62 days */
  calendar: (branchId: string, from: string, to: string) => rpc<ReservationCalendar>("fn_reservation_calendar", { p_branch: branchId, p_from: from, p_to: to }),
  /** the log with readable names, filters and pages (decision 14, 10.3); security rows for the owner, details for the owner and the manager */
  audit: (p: AuditListFilters) => rpc<AuditList>("fn_audit_list", { p }),
  /** the ledger with filters, pages and totals over the whole set (decision 14, 10.4) */
  vouchers: (p: VoucherListFilters) => rpc<VoucherList>("fn_voucher_list", { p }),
  savedViews: (screen: SavedViewScreen) => rpc<SavedView[]>("fn_saved_views_list", { p_screen: screen }),
  saveView: (p: { id?: string; screen: SavedViewScreen; name: string; filters?: Record<string, unknown>; columns?: string[] | null; is_default?: boolean }) => rpc<{ ok: boolean; id: string }>("fn_saved_view_save", { p }),
  removeView: (id: string) => rpc<{ ok: boolean }>("fn_saved_view_remove", { p_id: id }),
  /** the filter options of a branch's reports and lists (decision 36) */
  filterOptions: (branchId: string) => rpc<ReportFilterOptions | Record<string, never>>("fn_report_filter_options", { p_branch: branchId }),
  /** the live members of a branch (the owner included), for assignment and filters */
  branchStaff: (branchId: string) => rpc<Array<{ id: string; full_name: string; role: string }>>("fn_branch_staff", { p_branch: branchId }),
};

export interface StaffListRow { id: string; full_name: string; email: string; phone: string | null; role: string; is_active: boolean; linked: boolean; created_at: string; sessions_ended_at: string | null; updated_at: string | null; branch_ids: string[]; is_me: boolean }
/** The staff screens (decisions 34, 35): the owner edits, activates and signs out; the manager reads and signs out non-managers. */
export const staffAdminApi = {
  list: () => rpc<StaffListRow[]>("fn_admin_staff_list", {}),
  update: (p: { staff_id: string; reason: string; full_name?: string; phone?: string | null; role?: string; branch_ids?: string[] }) => rpc<{ ok: boolean; changed?: string[]; unchanged?: boolean }>("fn_admin_update_staff", { p }),
  setActive: (staffId: string, active: boolean, reason: string) => rpc<{ ok: boolean; is_active?: boolean; sessions_ended?: number; unchanged?: boolean }>("fn_admin_set_staff_active", { p_staff: staffId, p_active: active, p_reason: reason }),
  forceLogout: (staffId: string, reason: string) => rpc<{ ok: boolean; sessions_ended: number }>("fn_admin_force_logout", { p_staff: staffId, p_reason: reason }),
};

export interface CapabilityUsageRow { code: string; label: string; area: string; core: boolean; coverage: "full" | "partial" | "none"; last_success_at: string | null; week_count: number; window_count: number; by: { human: number; assistant: number; automation: number; guest: number }; rejected: number; status: "used" | "idle" | "undetermined" | "unmeasured" }
export interface CapabilityUsage { weeks: number; window_start: string; generated_at: string; log_since: string | null; log_covers_window: boolean; rows: CapabilityUsageRow[]; other_actions: Array<{ action: string; label: string; window_count: number; last_at: string }>; note: string }
/** «استعمال القدرات» (decision 55): the owner's report from the audit log itself. */
export const usageApi = {
  capabilities: (weeks = 4) => rpc<CapabilityUsage>("fn_reports_capability_usage", { p: { weeks } }),
};

/** «مصفوفة الصلاحيات» (decision 71, migration 0043): what a person may do, and the owner's editor. */
export interface MyPermissions { role: string | null; allowed: string[]; full: string[]; sees_money: boolean }
export interface PermissionCell { allowed: boolean; default: boolean; limited: boolean }
export interface PermissionMatrixRow { code: string; label: string; area: string; locked: boolean; limit_note: string | null; full_roles: string[] | null; cells: Record<string, PermissionCell> }
export interface PermissionMatrix {
  roles: string[]; editable_roles: string[]; rows: PermissionMatrixRow[]; changed: number;
  last_change: { at: string; by: string | null; reason: string | null } | null;
}
export interface PermissionChange { code: string; role: string; allowed: boolean }
export const permissionsApi = {
  mine: () => rpc<MyPermissions>("fn_my_permissions", {}),
  matrix: () => rpc<PermissionMatrix>("fn_permissions_matrix", {}),
  save: (changes: PermissionChange[], reason: string) => rpc<{ ok: boolean; changed?: number; unchanged?: boolean }>("fn_admin_set_permissions", { p: { changes, reason } }),
  reset: (reason: string) => rpc<{ ok: boolean; changed?: number; unchanged?: boolean }>("fn_admin_reset_permissions", { p_reason: reason }),
};

/**
 * Every page of a list, for an export (decision 43, X09): the server caps a page, so the export reads page after page
 * until it holds exactly `total` rows; a set that changes under it is read again once, then reported as a page.
 */
export async function fetchAllPages<R>(page: (limit: number, offset: number) => Promise<{ total: number; rows: R[] }>, pageSize = 500, maxRows = 50_000): Promise<{ rows: R[]; total: number; complete: boolean }> {
  for (let attempt = 0; attempt < 2; attempt++) {
    const first = await page(pageSize, 0);
    const rows = [...first.rows]; let total = first.total; let stable = true;
    while (rows.length < total && rows.length < maxRows) {
      const next = await page(pageSize, rows.length);
      if (next.total !== total || next.rows.length === 0) { stable = false; total = next.total; break; }
      rows.push(...next.rows);
    }
    if (stable && rows.length === total) return { rows, total, complete: true };
    if (attempt === 1 || rows.length >= maxRows) return { rows, total, complete: false };
  }
  return { rows: [], total: 0, complete: false };
}

// ---------------------------------------------------------------------------
// AI operations assistant (Edge Function `ai-ops`, runs as the signed-in staff)
// ---------------------------------------------------------------------------
export interface OpsProposal { id: string; action: string; summary: string; args: Record<string, unknown> }
export interface OpsReply { conversation_id: string; reply: string; proposals: OpsProposal[]; mode: "ai" | "deterministic"; ai_status?: string }
export interface Briefing { headline: string; items: Array<{ level: "critical" | "warning" | "info"; text: string; link?: string }>; text: string; insights: string | null; mode: "ai" | "deterministic"; ai_status?: string; date?: string; generated_at?: string }

export async function aiOpsChat(message: string, branchId: string, conversationId?: string | null): Promise<OpsReply> {
  const { data, error } = await supabase.functions.invoke<OpsReply>("ai-ops", { body: { mode: "chat", message, branch_id: branchId, conversation_id: conversationId ?? null } });
  if (error || !data) throw new ApiError(error?.message ?? "AI_UNAVAILABLE");
  return data;
}
export async function aiOpsBriefing(branchId: string, date?: string): Promise<Briefing> {
  const { data, error } = await supabase.functions.invoke<Briefing>("ai-ops", { body: { mode: "briefing", branch_id: branchId, date: date ?? null } });
  if (error || !data) throw new ApiError(error?.message ?? "AI_UNAVAILABLE");
  return data;
}

export const newIdempotencyKey = () => (typeof crypto !== "undefined" && "randomUUID" in crypto ? crypto.randomUUID() : String(Date.now()) + Math.random());
export const toHalalas = (sar: string | number) => Math.round(Number(sar) * 100);
