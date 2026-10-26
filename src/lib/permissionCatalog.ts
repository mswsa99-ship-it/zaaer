/**
 * The permissions matrix the owner approved (decision 71) — a copy of fn_permission_catalog() in migration 0043, kept
 * identical by tests/unit/permissions.test.ts. The server decides every operation (fn_can); the screens and the demo
 * read this list to show the matrix and to hide what a person may not do.
 *   defaultRoles — who the approved matrix allows (the owner always);
 *   fullRoles    — who gets the operation without its condition (null: everyone allowed);
 *   limitNote    — the condition a ticked role outside fullRoles works under;
 *   locked       — only the owner, never editable («تعديل مصفوفة الصلاحيات»).
 */
import type { StaffRole } from "./nav";

export interface PermissionRow { code: string; label: string; area: string; sort: number; defaultRoles: readonly StaffRole[]; fullRoles: readonly StaffRole[] | null; limitNote: string | null; locked: boolean }

export const PERMISSION_CATALOG: readonly PermissionRow[] = [
  { code: "res.create", label: "إنشاء حجز مفرد أو جماعي", area: "الحجوزات", sort: 10, defaultRoles: ["owner", "manager", "supervisor"], fullRoles: ["owner", "manager"], limitNote: "سعر أقل من المعروض يحتاج المدير", locked: false },
  { code: "disc.before", label: "خصم قبل الوصول (ضمن أدنى سعر وأقصى نسبة)", area: "الحجوزات", sort: 20, defaultRoles: ["owner", "manager", "supervisor"], fullRoles: null, limitNote: null, locked: false },
  { code: "disc.after", label: "خصم بعد الوصول أو فوق الحدين", area: "الحجوزات", sort: 30, defaultRoles: ["owner", "manager"], fullRoles: null, limitNote: null, locked: false },
  { code: "price.adjust", label: "تسوية سعر بسبب (تصفير رصيد، مغادرة مبكرة)", area: "الحجوزات", sort: 40, defaultRoles: ["owner", "manager"], fullRoles: null, limitNote: null, locked: false },
  { code: "charges.add", label: "رسوم وخدمات إضافية وخروج متأخر برسوم", area: "الحجوزات", sort: 50, defaultRoles: ["owner", "manager", "supervisor"], fullRoles: null, limitNote: null, locked: false },
  { code: "stay.extend", label: "تمديد يدوي (يُمنع مع ليلة غير مدفوعة إلا بسبب)", area: "الحجوزات", sort: 60, defaultRoles: ["owner", "manager", "supervisor"], fullRoles: ["owner", "manager"], limitNote: "لا يقصّر إقامة أسبوعية أو شهرية", locked: false },
  { code: "room.assign", label: "تخصيص وحدة ونقلها", area: "الحجوزات", sort: 70, defaultRoles: ["owner", "manager", "supervisor"], fullRoles: null, limitNote: null, locked: false },
  { code: "res.cancel", label: "إلغاء حجز (وبرقم المنصة دون رد) وعدم حضور", area: "الحجوزات", sort: 80, defaultRoles: ["owner", "manager", "supervisor"], fullRoles: null, limitNote: null, locked: false },
  { code: "res.undo_cancel", label: "التراجع عن الإلغاء خلال ساعة", area: "الحجوزات", sort: 90, defaultRoles: ["owner", "manager"], fullRoles: null, limitNote: null, locked: false },
  { code: "hold.set", label: "وضع حظر على حجز", area: "الحجوزات", sort: 100, defaultRoles: ["owner", "manager", "supervisor"], fullRoles: null, limitNote: null, locked: false },
  { code: "hold.lift", label: "رفع الحظر عن حجز", area: "الحجوزات", sort: 110, defaultRoles: ["owner", "manager"], fullRoles: null, limitNote: null, locked: false },
  { code: "guest.enter", label: "إدخال بيانات الضيف من الوثيقة الأصلية وتصحيحها بسبب", area: "الضيوف", sort: 120, defaultRoles: ["owner", "manager", "supervisor"], fullRoles: null, limitNote: null, locked: false },
  { code: "identity.approve", label: "اعتماد الهوية", area: "الضيوف", sort: 130, defaultRoles: ["owner", "manager", "supervisor"], fullRoles: null, limitNote: null, locked: false },
  { code: "guest.ban", label: "حظر ضيف ورفعه", area: "الضيوف", sort: 140, defaultRoles: ["owner", "manager"], fullRoles: null, limitNote: null, locked: false },
  { code: "guest.rate", label: "تقييم الضيف وملاحظته الداخلية", area: "الضيوف", sort: 150, defaultRoles: ["owner", "manager", "supervisor"], fullRoles: null, limitNote: null, locked: false },
  { code: "shomoos", label: "تأكيد شموس (المرجع والتسجيل والقبول)", area: "الإقامة", sort: 160, defaultRoles: ["owner", "manager", "supervisor"], fullRoles: null, limitNote: null, locked: false },
  { code: "checkin", label: "تسجيل الوصول (ومهلة السداد والإقرار الورقي)", area: "الإقامة", sort: 170, defaultRoles: ["owner", "manager", "supervisor"], fullRoles: null, limitNote: null, locked: false },
  { code: "code.deliver", label: "تسليم الرمز (الوحدات ذات الصندوق)", area: "الإقامة", sort: 180, defaultRoles: ["owner", "manager", "supervisor"], fullRoles: null, limitNote: null, locked: false },
  { code: "checkin.undo", label: "التراجع عن الوصول خلال 30 دقيقة", area: "الإقامة", sort: 190, defaultRoles: ["owner", "manager"], fullRoles: null, limitNote: null, locked: false },
  { code: "checkout", label: "تسجيل المغادرة (المتبقي صفر، بلا تجاوز لأحد)", area: "الإقامة", sort: 200, defaultRoles: ["owner", "manager", "supervisor"], fullRoles: null, limitNote: null, locked: false },
  { code: "stay.reopen", label: "إعادة فتح حجز غادر خلال ساعتين", area: "الإقامة", sort: 210, defaultRoles: ["owner", "manager"], fullRoles: null, limitNote: null, locked: false },
  { code: "inspection", label: "فحص المغادرة", area: "الإقامة", sort: 220, defaultRoles: ["owner", "manager", "supervisor", "housekeeping"], fullRoles: null, limitNote: null, locked: false },
  { code: "voucher.receipt", label: "سند قبض إيجار أو تأمين", area: "المال", sort: 230, defaultRoles: ["owner", "manager", "supervisor", "finance"], fullRoles: null, limitNote: null, locked: false },
  { code: "voucher.refund", label: "رد مبلغ إقامة", area: "المال", sort: 240, defaultRoles: ["owner", "manager", "finance"], fullRoles: null, limitNote: null, locked: false },
  { code: "deposit.refund", label: "رد التأمين (بعد فحص المغادرة فقط)", area: "المال", sort: 250, defaultRoles: ["owner", "manager", "supervisor", "finance"], fullRoles: null, limitNote: null, locked: false },
  { code: "damage.charge", label: "رسم ضرر وخصمه من التأمين", area: "المال", sort: 260, defaultRoles: ["owner", "manager", "supervisor"], fullRoles: null, limitNote: null, locked: false },
  { code: "deposit.apply", label: "خصم من التأمين بسبب لتصفير الرصيد", area: "المال", sort: 270, defaultRoles: ["owner", "manager", "supervisor", "finance"], fullRoles: null, limitNote: null, locked: false },
  { code: "voucher.correct", label: "تصحيح سند (إلغاء وإصدار بسبب)", area: "المال", sort: 280, defaultRoles: ["owner", "manager", "supervisor"], fullRoles: ["owner", "manager"], limitNote: "سنداته خلال 24 ساعة", locked: false },
  { code: "voucher.cancel", label: "إلغاء سند", area: "المال", sort: 290, defaultRoles: ["owner", "manager"], fullRoles: null, limitNote: null, locked: false },
  { code: "pos.settle", label: "تسوية الشبكة اليومية", area: "المال", sort: 300, defaultRoles: ["owner", "manager", "supervisor", "finance"], fullRoles: null, limitNote: null, locked: false },
  { code: "platform.payouts", label: "مطابقة الآجل عبر المنصات الشهرية", area: "المال", sort: 310, defaultRoles: ["owner", "manager", "finance"], fullRoles: ["owner", "manager"], limitNote: "دون إلغاء إيداع مؤكد", locked: false },
  { code: "invoice.issue", label: "إصدار فاتورة جزئية", area: "المال", sort: 320, defaultRoles: ["owner", "manager", "supervisor", "finance"], fullRoles: null, limitNote: null, locked: false },
  { code: "invoice.edit", label: "تعديل فاتورة بسبب (ينبّه الإدارة)", area: "المال", sort: 330, defaultRoles: ["owner", "manager", "supervisor", "finance"], fullRoles: null, limitNote: null, locked: false },
  { code: "rates", label: "تقويم الأسعار وأسعار النوع (أساسي، أسبوعي، شهري، أدنى)", area: "الإعدادات", sort: 340, defaultRoles: ["owner", "manager"], fullRoles: null, limitNote: null, locked: false },
  { code: "branch.tax", label: "نسبة الضريبة", area: "الإعدادات", sort: 350, defaultRoles: ["owner"], fullRoles: null, limitNote: null, locked: false },
  { code: "branch.settings", label: "إعدادات الفرع الأخرى (التأمين، أقصى خصم، الموقع، الشعار، رابط المنصة…)", area: "الإعدادات", sort: 360, defaultRoles: ["owner", "manager"], fullRoles: null, limitNote: null, locked: false },
  { code: "cash_accounts", label: "الصناديق والحسابات البنكية", area: "الإعدادات", sort: 370, defaultRoles: ["owner", "manager"], fullRoles: null, limitNote: null, locked: false },
  { code: "definitions", label: "الوحدات والأنواع والمرافق والخدمات وأنواع المهام ومصادر الحجز", area: "الإعدادات", sort: 380, defaultRoles: ["owner", "manager"], fullRoles: null, limitNote: null, locked: false },
  { code: "policies", label: "السياسات", area: "الإعدادات", sort: 390, defaultRoles: ["owner", "manager"], fullRoles: null, limitNote: null, locked: false },
  { code: "knowledge", label: "قاعدة معرفة المساعد", area: "الإعدادات", sort: 400, defaultRoles: ["owner", "manager", "supervisor"], fullRoles: null, limitNote: null, locked: false },
  { code: "task.work", label: "إنشاء مهمة وبدؤها وإتمامها", area: "خدمة الغرف", sort: 410, defaultRoles: ["owner", "manager", "supervisor", "housekeeping"], fullRoles: ["owner", "manager", "supervisor", "finance"], limitNote: "مهامه المسندة إليه", locked: false },
  { code: "task.manage", label: "إسناد مهمة وإلغاؤها", area: "خدمة الغرف", sort: 420, defaultRoles: ["owner", "manager", "supervisor"], fullRoles: null, limitNote: null, locked: false },
  { code: "cleanliness", label: "تغيير النظافة يدويًا (حر)", area: "خدمة الغرف", sort: 430, defaultRoles: ["owner", "manager", "supervisor", "housekeeping"], fullRoles: null, limitNote: null, locked: false },
  { code: "keybox.code", label: "تغيير رمز الصندوق وتجربته", area: "خدمة الغرف", sort: 440, defaultRoles: ["owner", "manager", "supervisor", "housekeeping"], fullRoles: null, limitNote: null, locked: false },
  { code: "maintenance.create", label: "البلاغات: إنشاء", area: "خدمة الغرف", sort: 450, defaultRoles: ["owner", "manager", "supervisor", "housekeeping"], fullRoles: null, limitNote: null, locked: false },
  { code: "maintenance.resolve", label: "البلاغات: حلّ", area: "خدمة الغرف", sort: 460, defaultRoles: ["owner", "manager", "supervisor"], fullRoles: null, limitNote: null, locked: false },
  { code: "conversation.take", label: "تولّي محادثة واتساب", area: "المحادثات", sort: 470, defaultRoles: ["owner", "manager", "supervisor"], fullRoles: null, limitNote: null, locked: false },
  { code: "staff.manage", label: "دعوة موظف وتعديله وتفعيله وتعطيله", area: "الموظفون والأمان", sort: 480, defaultRoles: ["owner"], fullRoles: ["owner"], limitNote: "لا يمسّ حساب المالك", locked: false },
  { code: "staff.force_logout", label: "خروج إجباري", area: "الموظفون والأمان", sort: 490, defaultRoles: ["owner", "manager"], fullRoles: ["owner"], limitNote: "غير المالك والمدير", locked: false },
  { code: "security", label: "السجل الأمني ومسح البيانات وإعدادات المساعد وواتساب", area: "الموظفون والأمان", sort: 500, defaultRoles: ["owner"], fullRoles: null, limitNote: null, locked: false },
  { code: "admin.permissions", label: "تعديل مصفوفة الصلاحيات", area: "الموظفون والأمان", sort: 505, defaultRoles: ["owner"], fullRoles: null, limitNote: null, locked: true },
  { code: "review.list", label: "قائمة «بحاجة لمراجعة وتدقيق» والتأشير عليها", area: "التقارير والسجل", sort: 510, defaultRoles: ["owner"], fullRoles: null, limitNote: null, locked: false },
  { code: "reports.finance", label: "التقارير المالية وتقرير الخصومات", area: "التقارير والسجل", sort: 520, defaultRoles: ["owner", "manager", "supervisor", "finance"], fullRoles: ["owner", "manager", "finance"], limitNote: "ملخص الخصومات فقط", locked: false },
  { code: "reports.identities_usage", label: "تقرير الهويات المعتمدة من المكتب وتقرير الاستعمال", area: "التقارير والسجل", sort: 530, defaultRoles: ["owner"], fullRoles: null, limitNote: null, locked: false },
  { code: "audit.log", label: "سجل الإجراءات", area: "التقارير والسجل", sort: 540, defaultRoles: ["owner", "manager", "supervisor"], fullRoles: ["owner", "manager"], limitNote: "بلا تفاصيل التغييرات", locked: false },
];

/** the roles the owner edits (the owner's column is always allowed) */
export const EDITABLE_ROLES: readonly StaffRole[] = ["manager", "supervisor", "finance", "housekeeping"];
/** the money operations: a person sees money when any of them is allowed (fn_sees_money) */
export const MONEY_PERMISSIONS: readonly string[] = ["voucher.receipt", "voucher.refund", "deposit.refund", "deposit.apply", "voucher.correct", "voucher.cancel", "pos.settle", "platform.payouts", "invoice.issue", "invoice.edit", "reports.finance"];
export const permissionRow = (code: string) => PERMISSION_CATALOG.find((r) => r.code === code);
