/**
 * Typed client for the server-side business functions (SECURITY DEFINER RPCs)
 * and the AI Edge Function. Pages must use these instead of writing to tables:
 * the database rejects direct writes for operational roles.
 */
import { supabase } from "./supabase";

export class ApiError extends Error {
  constructor(message: string, public readonly code?: string) { super(message); }
}

const ERROR_AR: Record<string, string> = {
  FORBIDDEN: "ليس لديك صلاحية لهذا الإجراء.",
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
  CODE_MUST_DIFFER_FROM_PREVIOUS: "يجب أن يختلف الرمز الجديد عن الرمز السابق.",
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
  DUPLICATE_EXTERNAL_REF: "يوجد حجز بنفس المصدر والمرجع الخارجي.",
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
  NOTHING_TO_INVOICE: "لا توجد بنود غير مفوترة.",
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
};

const VALIDATION_AR: Record<string, string> = {
  full_name_three_parts: "الاسم الثلاثي مطلوب كما في الوثيقة.",
  identity_type: "نوع الوثيقة غير صحيح.",
  identity_number_format: "شكل رقم الوثيقة غير صحيح لهذا النوع.",
  nationality: "الجنسية مطلوبة.",
  birth_date: "تاريخ الميلاد غير صالح.",
  birth_date_range: "تاريخ الميلاد خارج النطاق المنطقي.",
  consent_required: "يجب الإقرار بصحة البيانات.",
  phone_required_primary: "رقم الجوال مطلوب للنزيل الرئيسي.",
  amount: "المبلغ غير صحيح.",
  reference_required: "رقم المرجع مطلوب.",
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
};

export function toArabicError(e: unknown): string {
  const msg = (e as { message?: string })?.message ?? String(e);
  const v = msg.match(/VALIDATION:\s*([a-z_0-9]+)/i);
  if (v) return VALIDATION_AR[v[1]] ?? "بيانات غير صالحة: " + v[1];
  for (const k of Object.keys(ERROR_AR)) if (msg.includes(k)) return ERROR_AR[k];
  if (/permission denied|row-level security/i.test(msg)) return ERROR_AR.FORBIDDEN;
  return "تعذّر تنفيذ العملية: " + msg.slice(0, 120);
}

async function rpc<T = unknown>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new ApiError(error.message, error.code);
  return data as T;
}

// ---------------------------------------------------------------------------
// Guest (token-scoped)
// ---------------------------------------------------------------------------
export interface GuestSession {
  reservation: {
    id: string; internal_ref: string; external_ref: string | null; status: string; check_in: string; check_out: string;
    adults: number; companions: number; payment_status: string; identity_status: string; government_registration: boolean;
    access_status: string; total_halalas: number; paid_halalas: number; branch_name: string | null; room_number: string | null; category_name: string | null;
  };
  guests: Array<{ id: string; is_primary: boolean; full_name: string; identity_type: string | null; identity_number_last4: string | null; nationality: string | null; birth_date: string | null; relationship: string | null; verification_status: string; data_submitted: boolean }>;
  access: { allowed: boolean; reasons: string[] };
  expires_at: string;
}

export const guestApi = {
  lookup: (externalRef: string, phoneLast4: string, sourceId?: string | null) =>
    rpc<{ status: "ok" | "unmatched" | "mismatch" | "throttled" | "invalid"; token?: string }>("fn_guest_lookup", { p_external_ref: externalRef, p_phone_last4: phoneLast4, p_source_id: sourceId ?? null, p_fingerprint: fingerprint() }),
  session: (token: string) => rpc<GuestSession>("fn_guest_session", { p_token: token }),
  submit: (token: string, guestId: string | null, payload: Record<string, unknown>) => rpc<{ ok: boolean; guest_id: string }>("fn_guest_submit", { p_token: token, p_guest_id: guestId, p_payload: payload }),
  submitCheckin: (token: string) => rpc<{ ok: boolean; access_status: string }>("fn_guest_submit_checkin", { p_token: token }),
  accessCode: (token: string) => rpc<{ allowed: boolean; code?: string; room_number?: string; reasons?: string[] }>("fn_guest_access_code", { p_token: token }),
  availability: (branchId: string, date: string) => rpc<Array<{ category_id: string; category_name: string; base_price_halalas: number; base_capacity: number; max_capacity: number; available_to_show: number; total_available: number }>>("fn_get_public_availability", { p_branch: branchId, p_date: date }),
};

// ---------------------------------------------------------------------------
// Staff
// ---------------------------------------------------------------------------
export type GateResult = { ok: boolean; reasons?: string[]; code?: string; released_count?: number | null };

export const staffApi = {
  approveIdentity: (guestId: string, approve: boolean, reason?: string) => rpc<{ ok: boolean; identity_status: string }>("fn_staff_approve_identity", { p_guest_id: guestId, p_approve: approve, p_reason: reason ?? null }),
  confirmPayment: (reservationId: string, method: string, amountHalalas: number, reference: string, provider?: string) =>
    rpc<{ ok: boolean; duplicate: boolean; payment_status?: string; paid_halalas?: number }>("fn_staff_confirm_payment", { p_reservation: reservationId, p_method: method, p_amount_halalas: amountHalalas, p_reference: reference, p_idempotency_key: `${reservationId}:${method}:${reference}`, p_provider: provider ?? null }),
  confirmGovRegistration: (reservationId: string, reference: string) => rpc<{ ok: boolean }>("fn_staff_confirm_gov_registration", { p_reservation: reservationId, p_reference: reference }),
  assignRoom: (reservationId: string, roomId: string) => rpc<{ ok: boolean }>("fn_staff_assign_room", { p_reservation: reservationId, p_room: roomId }),
  approveCheckin: (reservationId: string) => rpc<GateResult>("fn_staff_approve_checkin", { p_reservation: reservationId }),
  deliverAccessCode: (reservationId: string, channel: "screen" | "whatsapp" | "supervisor") => rpc<GateResult>("fn_staff_deliver_access_code", { p_reservation: reservationId, p_channel: channel }),
  markDeliveryFailed: (reservationId: string, reason: string) => rpc<{ ok: boolean }>("fn_staff_mark_delivery_failed", { p_reservation: reservationId, p_reason: reason }),
  checkout: (reservationId: string, overrideReason?: string) => rpc<GateResult>("fn_staff_checkout", { p_reservation: reservationId, p_override_reason: overrideReason ?? null }),
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

export async function aiHealth(): Promise<{ configured: boolean; ok: boolean; model?: string | null; latency_ms?: number; error?: string }> {
  const { data, error } = await supabase.functions.invoke("ai-health", { body: {} });
  if (error) return { configured: false, ok: false, error: error.message };
  return data as { configured: boolean; ok: boolean; model?: string | null; latency_ms?: number; error?: string };
}

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
export interface Quote { nights: number; nightly_rate: number; rent: number; discount: number; tax: number; total: number; tax_rate_bp: number; prices_include_tax: boolean }

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
  quote: (branchId: string, categoryId: string, checkIn: string, checkOut: string, nightlyOverride?: number | null, discount?: number) =>
    rpc<Quote>("fn_staff_quote", { p_branch: branchId, p_category: categoryId, p_check_in: checkIn, p_check_out: checkOut, p_nightly_override: nightlyOverride ?? null, p_discount_halalas: discount ?? 0 }),
  availableRooms: (branchId: string, from: string, to: string, categoryId?: string | null, excludeReservation?: string | null) =>
    rpc<Array<{ room_id: string; room_number: string; category_id: string; category_name: string; status: string; cleanliness: string; block_name: string | null; floor_name: string | null }>>("fn_available_rooms", { p_branch: branchId, p_from: from, p_to: to, p_category: categoryId ?? null, p_exclude_reservation: excludeReservation ?? null }),
  createReservation: (p: Record<string, unknown>) => rpc<{ ok: boolean; id: string; internal_ref: string; quote: Quote }>("fn_staff_create_reservation", { p }),
  amendStay: (id: string, newCheckOut: string, pricingMode: "keep_rate" | "reprice", reason: string, version?: number) =>
    rpc<{ ok: boolean; delta_nights?: number; finance?: Finance }>("fn_staff_amend_stay", { p_reservation: id, p_new_check_out: newCheckOut, p_pricing_mode: pricingMode, p_reason: reason, p_expected_version: version ?? null }),
  switchRoom: (id: string, roomId: string, effective: string | null, reason: string, version?: number) =>
    rpc<{ ok: boolean; entry_code_review_required: boolean }>("fn_staff_switch_room", { p_reservation: id, p_room: roomId, p_effective: effective, p_reason: reason, p_expected_version: version ?? null }),
  adjustPrice: (id: string, kind: "discount" | "adjustment" | "penalty" | "addon", amountHalalas: number, description: string, reason: string, version?: number) =>
    rpc<{ ok: boolean; finance: Finance }>("fn_staff_adjust_price", { p_reservation: id, p_kind: kind, p_amount_halalas: amountHalalas, p_description: description, p_reason: reason, p_expected_version: version ?? null }),
  addService: (id: string, serviceId: string, quantity = 1, note?: string) => rpc<{ ok: boolean; finance: Finance }>("fn_staff_add_service", { p_reservation: id, p_service: serviceId, p_quantity: quantity, p_note: note ?? null }),
  cancelReservation: (id: string, reason: string, source: "staff" | "ota" | "guest" = "staff", externalEventId?: string) =>
    rpc<{ ok: boolean; duplicate: boolean; refund_required_separately?: boolean }>("fn_staff_cancel_reservation", { p_reservation: id, p_reason: reason, p_source: source, p_external_event_id: externalEventId ?? null }),
  noShow: (id: string, reason: string) => rpc<{ ok: boolean }>("fn_staff_no_show", { p_reservation: id, p_reason: reason }),
  detail: (id: string) => rpc<ReservationDetail | null>("fn_reservation_detail", { p_reservation: id }),
  list: (branchId: string, filters: Record<string, unknown>, limit = 50, offset = 0) => rpc<{ total: number; rows: ReservationRow[] }>("fn_reservation_list", { p_branch: branchId, p_filters: filters, p_limit: limit, p_offset: offset }),

  // money
  createVoucher: (p: { reservation_id: string; kind: "receipt" | "deposit"; amount_halalas: number; method: string; reference?: string; note?: string; reason?: string; idempotency_key: string }) =>
    rpc<{ ok: boolean; duplicate: boolean; voucher_id: string; number: string; finance: Finance }>("fn_create_voucher", { p }),
  refund: (p: { reservation_id: string; kind: "refund" | "deposit_refund" | "deposit_apply"; amount_halalas: number; method?: string; reference?: string; reason: string; idempotency_key: string; original_voucher_id?: string }) =>
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

  // reports (A05): money KPIs come from the voucher ledger, never from reservation totals. Role-gated on the server.
  reportsFinance: (branchId: string, from: string, to: string) => rpc<ReportsFinance>("fn_reports_finance", { p_branch: branchId, p_from: from, p_to: to }),

  // AI ops proposals (human-in-the-loop)
  executeProposal: (id: string) => rpc<{ ok: boolean; result?: unknown; error?: string }>("fn_ai_ops_execute_proposal", { p_id: id }),
  rejectProposal: (id: string, reason?: string) => rpc<{ ok: boolean }>("fn_ai_ops_reject_proposal", { p_id: id, p_reason: reason ?? null }),
};

export interface ReservationRow {
  id: string; internal_ref: string; external_ref: string | null; status: string; check_in: string; check_out: string; nights: number;
  guest_name: string | null; room_number: string | null; source_name: string | null; category_name: string | null;
  total_halalas: number; paid_halalas: number; balance_due_halalas: number; deposit_balance_halalas: number;
  payment_status: string; identity_status: string; access_status: string; created_at: string;
}
export interface ReservationDetail {
  reservation: Record<string, unknown> & { id: string; internal_ref: string; status: string; check_in: string; check_out: string; version: number; branch_id: string; room_id: string | null; room_category_id: string | null; adults: number; companions: number; nightly_rate_halalas: number; external_ref: string | null; actual_check_in: string | null; actual_check_out: string | null; cancel_reason: string | null };
  notes: string | null;
  source: { name: string; code: string; kind: string } | null;
  category: string | null;
  room: { id: string; room_number: string; status: string; cleanliness: string } | null;
  guests: Array<{ id: string; is_primary: boolean; full_name: string; identity_type: string | null; identity_number_last4: string | null; nationality: string | null; phone: string | null; verification_status: string; data_submitted: boolean }>;
  allocations: Array<{ id: string; room_number: string; from_date: string; to_date: string; status: string; reason: string | null; created_at: string }>;
  charges: Array<{ id: string; kind: string; description: string; quantity: number; unit_price_halalas: number; total_halalas: number; invoice_id: string | null; reason: string | null; created_at: string }> | null;
  vouchers: Array<{ id: string; number: string; kind: string; amount_halalas: number; method: string; status: string; reference: string | null; note: string | null; reason: string | null; occurred_at: string; cancel_reason: string | null }> | null;
  invoices: Array<{ id: string; number: string; status: string; total_halalas: number; issued_at: string; period_from: string; period_to: string }> | null;
  finance: Finance | null;
  history: Array<{ action: string; at: string; actor: string | null; details: Record<string, unknown> | null }>;
}
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
