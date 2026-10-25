export type Role = "owner" | "manager" | "supervisor" | "finance" | "housekeeping" | "guest";

export const ROLE_LABELS: Record<Role, string> = {
  owner: "مالك",
  manager: "مدير فرع",
  supervisor: "مشرف استقبال",
  finance: "مالية",
  housekeeping: "النظافة",
  guest: "نزيل",
};

export type ReservationStatus =
  | "draft"
  | "pending_verification"
  | "confirmed"
  | "checked_in"
  | "checked_out"
  | "closed"
  | "cancelled"
  | "rejected"
  | "no_show";

export const RESERVATION_STATUS_LABELS: Record<ReservationStatus, string> = {
  draft: "مسودة",
  pending_verification: "بانتظار التحقق",
  confirmed: "مؤكد",
  checked_in: "تم الدخول",
  checked_out: "تمت المغادرة",
  closed: "مغلق",
  cancelled: "ملغى",
  rejected: "مرفوض",
  no_show: "عدم حضور",
};

export const RESERVATION_STATUS_COLORS: Record<ReservationStatus, string> = {
  draft: "bg-ink-100 text-ink-500",
  pending_verification: "bg-warning-500/10 text-warning-600",
  confirmed: "bg-brand-500/10 text-brand-700",
  checked_in: "bg-success-500/10 text-success-600",
  checked_out: "bg-ink-500/10 text-ink-700",
  closed: "bg-ink-100 text-ink-500",
  cancelled: "bg-danger-500/10 text-danger-600",
  rejected: "bg-danger-500/10 text-danger-600",
  no_show: "bg-danger-500/10 text-danger-600",
};

export type GuestVerificationStatus = "not_started" | "data_submitted" | "pending_supervisor" | "verified" | "rejected";
export const GUEST_VERIFICATION_LABELS: Record<GuestVerificationStatus, string> = {
  not_started: "لم يبدأ",
  data_submitted: "تم إدخال البيانات",
  pending_supervisor: "بانتظار المشرف",
  verified: "تم التحقق",
  rejected: "مرفوض",
};

export type PaymentStatus = "pending" | "processing" | "paid" | "failed" | "partially_paid" | "refunded" | "overpaid";
export const PAYMENT_STATUS_LABELS: Record<PaymentStatus, string> = {
  pending: "بانتظار الدفع",
  processing: "قيد المعالجة",
  paid: "مدفوع",
  failed: "فشل",
  partially_paid: "دفع جزئي",
  refunded: "مسترد",
  overpaid: "دفع زائد",
};

export type AccessStatus = "locked" | "eligibility_review" | "approved" | "delivery_pending" | "delivered" | "acknowledged" | "key_handed";
export const ACCESS_STATUS_LABELS: Record<AccessStatus, string> = {
  locked: "مقفل",
  eligibility_review: "وصل النزيل",
  approved: "بانتظار تسليم الرمز",
  delivery_pending: "بانتظار التسليم",
  delivered: "سُلِّم الرمز",
  acknowledged: "اطّلع النزيل على الرمز",
  // 0033: a unit without a key box takes its ordinary key at reception
  key_handed: "سُلِّم المفتاح",
};

export type RoomStatus =
  | "available"
  | "reserved"
  | "occupied"
  | "cleaning"
  | "maintenance"
  | "blocked"
  | "out_of_service"
  | "ready";

export const ROOM_STATUS_LABELS: Record<RoomStatus, string> = {
  available: "متاحة",
  reserved: "محجوزة",
  occupied: "مشغولة",
  cleaning: "تحت التنظيف",
  maintenance: "صيانة",
  blocked: "محجوبة",
  out_of_service: "خارج الخدمة",
  ready: "جاهزة",
};

export const ROOM_STATUS_COLORS: Record<RoomStatus, string> = {
  available: "bg-success-500/10 text-success-600",
  reserved: "bg-brand-500/10 text-brand-700",
  occupied: "bg-ink-500/10 text-ink-700",
  cleaning: "bg-warning-500/10 text-warning-600",
  maintenance: "bg-danger-500/10 text-danger-600",
  blocked: "bg-ink-300/30 text-ink-600",
  out_of_service: "bg-danger-500/15 text-danger-600",
  ready: "bg-accent-500/10 text-accent-600",
};

export type IdentityType = "national_id" | "iqama" | "passport" | "gcc_id";
export const IDENTITY_TYPE_LABELS: Record<IdentityType, string> = {
  national_id: "هوية وطنية",
  iqama: "إقامة",
  passport: "جواز سفر",
  gcc_id: "هوية خليجية",
};

export type PaymentMethod = "booking_platform" | "payment_link" | "pos" | "cash" | "mada" | "card" | "bank_transfer" | "ota_deferred";
export const PAYMENT_METHOD_LABELS: Record<PaymentMethod, string> = {
  cash: "نقد",
  pos: "شبكة",
  bank_transfer: "تحويل بنكي",
  ota_deferred: "آجل عبر المنصة",
  // used before decision 24; they stay on the vouchers that used them
  mada: "مدى (طريقة سابقة)",
  card: "بطاقة ائتمان (طريقة سابقة)",
  payment_link: "رابط دفع (طريقة سابقة)",
  booking_platform: "منصة الحجز (طريقة سابقة)",
};
/** The only methods a new receipt or refund may use (decision 24). */
export const ACTIVE_PAYMENT_METHODS: PaymentMethod[] = ["cash", "pos", "bank_transfer", "ota_deferred"];
/** Which account kind a method is recorded in (decision 25); the platform takes none. */
export const METHOD_ACCOUNT_KIND: Partial<Record<PaymentMethod, "cash_box" | "bank_account">> = { cash: "cash_box", pos: "bank_account", bank_transfer: "bank_account" };
/** Methods that need their transaction number (decision 13). */
export const METHOD_NEEDS_REFERENCE: PaymentMethod[] = ["pos", "bank_transfer"];

export type VoucherKind = "receipt" | "refund" | "deposit" | "deposit_refund" | "deposit_apply";
export const VOUCHER_KIND_LABELS: Record<VoucherKind, string> = {
  receipt: "سند قبض",
  refund: "استرداد",
  deposit: "قبض تأمين",
  deposit_refund: "رد تأمين",
  deposit_apply: "استخدام تأمين لتغطية رسوم",
};

export type ChargeKind = "rent" | "addon" | "discount" | "penalty" | "tax" | "adjustment";
export const CHARGE_KIND_LABELS: Record<ChargeKind, string> = {
  rent: "إيجار", addon: "إضافة", discount: "خصم", penalty: "غرامة", tax: "ضريبة", adjustment: "تسوية",
};

export const CLEANLINESS_LABELS: Record<string, string> = { clean: "نظيفة", dirty: "متسخة", in_progress: "قيد التنظيف" };
export const CLEANLINESS_COLORS: Record<string, string> = { clean: "bg-success-500/10 text-success-600", dirty: "bg-danger-500/10 text-danger-600", in_progress: "bg-warning-500/10 text-warning-600" };
export const TASK_STATUS_LABELS: Record<string, string> = { pending: "معلقة", in_progress: "قيد التنفيذ", completed: "مكتملة", cancelled: "ملغاة" };
export const TASK_PRIORITY_LABELS: Record<string, string> = { low: "منخفضة", medium: "متوسطة", high: "مرتفعة" };
export const BILLING_UNIT_LABELS: Record<string, string> = { once: "مرة واحدة", night: "لكل ليلة", person: "لكل شخص", quantity: "بالكمية" };
