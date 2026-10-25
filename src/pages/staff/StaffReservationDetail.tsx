import { useEffect, useState, useCallback } from "react";
import { auditActionLabel } from "../../lib/auditLabels";
import { useParams, useNavigate, Link } from "react-router-dom";
import { ArrowLeft, UserCheck, UserX, CreditCard, CheckCircle2, XCircle, Sparkles, DoorClosed, IdCard, Printer, UserPlus } from "lucide-react";
import { supabase } from "../../lib/supabase";
import { useAuth } from "../../lib/auth";
import { staffApi, toArabicError } from "../../lib/api";
import { Card, Spinner, EmptyState, ErrorBanner, Badge } from "../../components/ui";
import {
  RESERVATION_STATUS_LABELS, PAYMENT_STATUS_LABELS, GUEST_VERIFICATION_LABELS, IDENTITY_TYPE_LABELS, ROOM_STATUS_LABELS,
  type ReservationStatus, type PaymentStatus, type GuestVerificationStatus, type AccessStatus, type IdentityType, type RoomStatus,
} from "../../lib/types";
import { formatCurrency, maskId, formatDateTime } from "../../lib/utils";
import { ReservationOperations } from "../../components/ReservationOperations";
import { StayCycle } from "../../components/StayCycle";
import { GuestAlerts, OfficeGuestDialog, PlatformPanel, GroupPanel, StaySummaryDialog, GuestEntryBadge } from "../../components/Guests";
import { opsApi, type ReservationDetail, type GroupSummary } from "../../lib/api";

interface Detail {
  id: string; internal_ref: string; external_ref: string | null; status: ReservationStatus;
  branch_id: string; room_id: string | null; room_category_id: string | null;
  check_in: string; check_out: string; adults: number; companions: number;
  expected_arrival_time: string | null; expected_departure_time: string | null; group_ref: string | null;
  rent_amount_halalas: number; total_halalas: number; paid_halalas: number;
  payment_status: PaymentStatus; identity_status: GuestVerificationStatus;
  government_registration: boolean; gov_registration_ref: string | null; access_status: AccessStatus; keybox_delivered: boolean;
  security_hold: boolean; security_hold_reason: string | null;
  checkin_approved_by: string | null; checkin_approved_at: string | null; actual_check_in: string | null; actual_check_out: string | null;
  notes: string | null;
  source?: { name: string } | null;
  room?: { room_number: string; status: RoomStatus } | null;
  room_category?: { name_ar: string } | null;
  branch?: { name_ar: string } | null;
}

interface GuestDetail {
  id: string; is_primary: boolean; full_name: string; identity_type: IdentityType | null;
  identity_number_last4: string | null; nationality: string | null; birth_date: string | null;
  phone: string | null; relationship: string | null; verification_status: GuestVerificationStatus; data_submitted: boolean;
}

interface RoomOption { id: string; room_number: string; status: RoomStatus }

const RESERVATION_SELECT = `
  id, internal_ref, external_ref, status, branch_id, room_id, room_category_id,
  check_in, check_out, adults, companions,
  payment_status, identity_status, expected_arrival_time, expected_departure_time, group_ref,
  government_registration, gov_registration_ref, access_status, keybox_delivered,
  security_hold, security_hold_reason,
  checkin_approved_by, checkin_approved_at, actual_check_in, actual_check_out, notes,
  source:booking_sources(name), room:rooms(room_number, status), room_category:room_categories(name_ar), branch:branches(name_ar)
`;

export default function StaffReservationDetail() {
  const { id } = useParams();
  const navigate = useNavigate();
  const { profile } = useAuth();
  const role = profile?.role;
  // money is shown only to money roles (the server strips it in fn_reservation_detail; the legacy row read is gated here too)
  const canMoney = role === "owner" || role === "manager" || role === "supervisor" || role === "finance";

  const [detail, setDetail] = useState<Detail | null>(null);
  const [guests, setGuests] = useState<GuestDetail[]>([]);
  /** bumps on every load, so the stay cycle and the ledger refresh with the page */
  const [tick, setTick] = useState(0);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [action, setAction] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);

  // Inline forms
  const [rejectingGuest, setRejectingGuest] = useState<string | null>(null);
  const [rejectReason, setRejectReason] = useState("");
  const [rooms, setRooms] = useState<RoomOption[]>([]);
  const [group, setGroup] = useState<GroupSummary | null>(null);
  const [selectedRoom, setSelectedRoom] = useState("");
  // phase 5 (0038): bans, the hold, the rating, the platform's fields and the acknowledgements come from fn_reservation_detail
  const [extra, setExtra] = useState<ReservationDetail | null>(null);
  const [officeGuest, setOfficeGuest] = useState<{ open: boolean; guest: GuestDetail | null }>({ open: false, guest: null });
  const [summaryOpen, setSummaryOpen] = useState(false);
  const canOffice = role === "owner" || role === "manager" || role === "supervisor";

  const load = useCallback(async () => {
    if (!id) return;
    try {
      const [res, g] = await Promise.all([
        supabase.from("reservations").select(RESERVATION_SELECT).eq("id", id).maybeSingle(),
        supabase.from("reservation_guests").select("id, is_primary, full_name, identity_type, identity_number_last4, nationality, birth_date, phone, relationship, verification_status, data_submitted").eq("reservation_id", id).order("is_primary", { ascending: false }),
      ]);
      if (res.error) throw res.error;
      if (g.error) throw g.error;
      // money columns are not selectable through the table (0009 column gate): they come from the role-gated ledger RPC
      let d = res.data as unknown as Detail | null;
      if (d) {
        const fin = canMoney ? await supabase.rpc("fn_reservation_finance", { p_reservation: id }) : { data: null };
        const f = (fin.data ?? null) as { total?: number; net_collected?: number; rent?: number } | null;
        d = { ...d, total_halalas: f?.total ?? 0, paid_halalas: f?.net_collected ?? 0, rent_amount_halalas: f?.rent ?? 0 };
      }
      setDetail(d);
      setGuests((g.data as GuestDetail[]) ?? []);
      if (canMoney) { try { setExtra(await opsApi.detail(id)); } catch { setExtra(null); } }
      setTick((t) => t + 1);
      setLoadError(null);
    } catch (e) {
      setLoadError(toArabicError(e));
    } finally {
      setLoading(false);
    }
  }, [id, canMoney]);

  useEffect(() => { load(); }, [load]);
  useEffect(() => {
    if (!id || !detail?.group_ref) { setGroup(null); return; }
    opsApi.groupSummary(id).then(setGroup).catch(() => setGroup(null));
  }, [id, detail?.group_ref, tick]); // eslint-disable-line react-hooks/exhaustive-deps

  // Realtime
  useEffect(() => {
    if (!id) return;
    const ch = supabase.channel(`res-${id}`).on("postgres_changes", { event: "*", schema: "public", table: "reservations", filter: `id=eq.${id}` }, () => load()).subscribe();
    return () => { supabase.removeChannel(ch); };
  }, [id, load]);

  // Rooms available for assignment (same branch + category)
  useEffect(() => {
    if (!detail || detail.room_id || !detail.room_category_id) { setRooms([]); return; }
    let alive = true;
    (async () => {
      try {
        const data = await opsApi.availableRooms(detail.branch_id, detail.check_in, detail.check_out, detail.room_category_id, detail.id);
        if (alive) setRooms(data.map((r) => ({ id: r.room_id, room_number: r.room_number, status: r.status as RoomStatus })));
      } catch { if (alive) setRooms([]); }
    })();
    return () => { alive = false; };
  }, [detail?.id, detail?.room_id, detail?.room_category_id, detail?.branch_id, detail?.check_in, detail?.check_out]); // eslint-disable-line react-hooks/exhaustive-deps

  async function run(name: string, fn: () => Promise<void>) {
    setAction(name); setActionError(null);
    try {
      await fn();
      await load();
    } catch (e) {
      setActionError(toArabicError(e));
    } finally {
      setAction(null);
    }
  }

  // ---- Identity ----
  const approveIdentity = (guestId: string) => run("identity_" + guestId, async () => { await staffApi.approveIdentity(guestId, true); });
  const rejectIdentity = (guestId: string) => run("reject_" + guestId, async () => {
    if (!rejectReason.trim()) throw new Error("REASON_REQUIRED");
    await staffApi.approveIdentity(guestId, false, rejectReason.trim());
    setRejectingGuest(null); setRejectReason("");
  });

  // ---- Room assignment ----
  const assignRoom = () => run("assign", async () => {
    if (!id) return;
    if (!selectedRoom) throw new Error("ROOM_NOT_FOUND");
    await staffApi.assignRoom(id, selectedRoom);
    setSelectedRoom("");
  });

  if (loading) return <div className="flex justify-center py-12"><Spinner className="h-8 w-8" /></div>;
  if (loadError && !detail) return <ErrorBanner message={loadError} />;
  if (!detail) return <EmptyState title="الحجز غير موجود" />;

  const remaining = Math.max(0, detail.total_halalas - detail.paid_halalas);

  return (
    <div>
      <button onClick={() => navigate("/staff/reservations")} className="mb-4 inline-flex items-center gap-1.5 text-sm text-ink-400 hover:text-ink-600">
        <ArrowLeft className="h-4 w-4" /> رجوع
      </button>

      <div className="mb-6 flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-xl font-bold text-ink-800">{detail.internal_ref}</h1>
          <p className="mt-1 text-sm text-ink-500">
            {detail.branch?.name_ar} · {detail.room?.room_number ?? "—"} · {detail.room_category?.name_ar}
          </p>
          <p className="mt-1 text-xs text-ink-400">
            {detail.check_in}{detail.expected_arrival_time ? ` ${detail.expected_arrival_time.slice(0, 5)}` : ""} → {detail.check_out}{detail.expected_departure_time ? ` ${detail.expected_departure_time.slice(0, 5)}` : ""} · {detail.source?.name}
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          <Badge className="bg-brand-50 text-brand-700">{RESERVATION_STATUS_LABELS[detail.status]}</Badge>
          {canMoney && <Badge className="bg-warning-500/10 text-warning-600">{PAYMENT_STATUS_LABELS[detail.payment_status]}</Badge>}
          <Badge className={detail.identity_status === "verified" ? "bg-success-500/10 text-success-600" : "bg-ink-100 text-ink-500"}>{GUEST_VERIFICATION_LABELS[detail.identity_status]}</Badge>
        </div>
      </div>
      {group && group.units.length > 1 && (
        <div className="mb-4 flex flex-wrap items-center gap-2 rounded-xl border border-brand-100 bg-brand-50/50 px-3 py-2 text-xs text-ink-600">
          <span className="font-medium text-brand-700">حجز جماعي {detail.group_ref} — {group.units.length} وحدات:</span>
          {group.units.map((g) => g.id === detail.id
            ? <span key={g.id} className="rounded-md bg-white px-2 py-0.5 font-mono font-semibold text-ink-800 shadow-sm">{g.internal_ref}{g.room_number ? ` · ${g.room_number}` : ""}</span>
            : <Link key={g.id} to={`/staff/reservations/${g.id}`} className="rounded-md px-2 py-0.5 font-mono hover:bg-white">{g.internal_ref}{g.room_number ? ` · ${g.room_number}` : ` · ${g.category_name ?? ""}`}</Link>)}
        </div>
      )}

      {/* decision 21: the ban's red alert, the hold and the rating; the hold is also shown to roles without the detail RPC */}
      {extra ? <div className="mb-4"><GuestAlerts d={extra} onChanged={load} /></div> : detail.security_hold && (
        <div className="mb-4 rounded-xl border border-danger-500/30 bg-danger-500/10 px-4 py-3 text-sm text-danger-600">
          <p className="font-semibold">يوجد حظر على هذا الحجز</p>
          {detail.security_hold_reason && <p className="mt-0.5 text-xs">{detail.security_hold_reason}</p>}
        </div>
      )}

      {loadError && <div className="mb-4"><ErrorBanner message={loadError} /></div>}
      {actionError && <div className="mb-4"><ErrorBanner message={actionError} /></div>}
      <div className="grid gap-4 lg:grid-cols-2">
        {/* Guests / Identity */}
        <Card>
          <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
            <div className="flex items-center gap-2"><UserCheck className="h-5 w-5 text-brand-600" /><h2 className="text-base font-semibold text-ink-800">النزلاء ومطابقة الهوية</h2></div>
            <div className="flex flex-wrap gap-2">
              {canMoney && <button onClick={() => setSummaryOpen(true)} className="btn-outline text-xs" data-testid="stay-summary-btn"><Printer className="h-3.5 w-3.5" /> ملخص الإقامة</button>}
              {canOffice && guests.length < detail.adults + detail.companions && !["cancelled", "rejected", "closed", "checked_out", "no_show"].includes(detail.status) && <button onClick={() => setOfficeGuest({ open: true, guest: null })} className="btn-outline text-xs" data-testid="office-add-guest"><UserPlus className="h-3.5 w-3.5" /> مرافق من الوثيقة</button>}
            </div>
          </div>
          <div className="space-y-3">
            {guests.map((g) => (
              <div key={g.id} className="rounded-xl border border-ink-100 p-3">
                <div className="flex items-center justify-between gap-2">
                  <div>
                    <div className="flex items-center gap-2">
                      <p className="text-sm font-medium text-ink-800">{g.full_name}</p>
                      {g.is_primary && <Badge className="bg-brand-50 text-brand-600">رئيسي</Badge>}
                    </div>
                    <p className="mt-0.5 text-xs text-ink-400">
                      {g.identity_type ? IDENTITY_TYPE_LABELS[g.identity_type] : "—"} · {maskId(g.identity_number_last4 ?? undefined)} · {g.nationality ?? "—"}
                      {g.relationship && ` · ${g.relationship}`}
                    </p>
                    <p className="mt-0.5 flex flex-wrap items-center gap-1.5 text-xs text-ink-400">الحالة: {GUEST_VERIFICATION_LABELS[g.verification_status]}{!g.data_submitted && " · لم تُدخل البيانات"}{extraGuest(extra, g.id) && <GuestEntryBadge g={extraGuest(extra, g.id)!} />}</p>
                  </div>
                  {g.verification_status !== "verified" && g.verification_status !== "rejected" && (
                    <div className="flex flex-wrap justify-end gap-2">
                      {g.data_submitted && <button onClick={() => approveIdentity(g.id)} disabled={action === "identity_" + g.id} className="btn-accent text-xs">
                        {action === "identity_" + g.id ? <Spinner className="h-3.5 w-3.5" /> : <UserCheck className="h-3.5 w-3.5" />} اعتمد
                      </button>}
                      {canOffice && !["cancelled", "rejected", "closed", "checked_out", "no_show"].includes(detail.status) && <button onClick={() => setOfficeGuest({ open: true, guest: g })} className="btn-outline text-xs" data-testid={`office-enter-${g.id}`}>
                        <IdCard className="h-3.5 w-3.5" /> {g.data_submitted ? "تصحيح من الوثيقة" : "إدخال من الوثيقة"}
                      </button>}
                      {g.data_submitted && <button onClick={() => { setRejectingGuest(rejectingGuest === g.id ? null : g.id); setRejectReason(""); }} className="btn-danger text-xs">
                        <UserX className="h-3.5 w-3.5" /> رفض
                      </button>}
                    </div>
                  )}
                  {g.verification_status === "verified" && canOffice && !["cancelled", "rejected", "closed", "checked_out", "no_show"].includes(detail.status) && (
                    <button onClick={() => setOfficeGuest({ open: true, guest: g })} className="btn-ghost text-xs" data-testid={`office-correct-${g.id}`}><IdCard className="h-3.5 w-3.5" /> تصحيح بسبب</button>
                  )}
                  {g.verification_status === "verified" && <CheckCircle2 className="h-5 w-5 text-success-600" />}
                  {g.verification_status === "rejected" && <XCircle className="h-5 w-5 text-danger-500" />}
                </div>
                {rejectingGuest === g.id && (
                  <div className="mt-3 space-y-2 border-t border-ink-50 pt-3">
                    <label className="label">سبب الرفض (إلزامي)</label>
                    <textarea value={rejectReason} onChange={(e) => setRejectReason(e.target.value)} className="input" rows={2} placeholder="مثال: الوثيقة لا تطابق الاسم المدخل" />
                    <div className="flex gap-2">
                      <button onClick={() => rejectIdentity(g.id)} disabled={action === "reject_" + g.id || !rejectReason.trim()} className="btn-danger text-xs">
                        {action === "reject_" + g.id ? <Spinner className="h-3.5 w-3.5" /> : <UserX className="h-3.5 w-3.5" />} تأكيد الرفض
                      </button>
                      <button onClick={() => setRejectingGuest(null)} className="btn-outline text-xs">إلغاء</button>
                    </div>
                  </div>
                )}
              </div>
            ))}
            {guests.length === 0 && <p className="text-sm text-ink-400">لم تُسجّل بيانات النزلاء بعد.</p>}
          </div>
          <p className="mt-3 rounded-lg bg-ink-50 px-3 py-2 text-xs text-ink-500">
            مساران (القرار 2): يدخل الضيف بياناته بنفسه ثم يطابقها المشرف مع الوثيقة الأصلية، أو يدخلها المكتب من الوثيقة الأصلية فتُعتمد فورًا باسمه. التصحيح بسبب ويُراجَع.
          </p>
        </Card>

        {extra?.platform && <PlatformPanel d={extra} canCheck={canOffice} onChanged={load} />}
        {group && group.units.length > 1 && <div className="lg:col-span-2"><GroupPanel current={detail.id} group={group} /></div>}

        {/* Payment & Status */}
        <div className="space-y-4">
          {canMoney && <Card>
            <div className="mb-3 flex items-center gap-2">
              <CreditCard className="h-5 w-5 text-brand-600" />
              <h2 className="text-base font-semibold text-ink-800">السداد</h2>
            </div>
            <div className="grid grid-cols-2 gap-3 text-sm">
              <div><p className="text-xs text-ink-400">الإجمالي</p><p className="font-medium text-ink-700">{formatCurrency(detail.total_halalas / 100)}</p></div>
              <div><p className="text-xs text-ink-400">المدفوع</p><p className="font-medium text-success-600">{formatCurrency(detail.paid_halalas / 100)}</p></div>
              <div><p className="text-xs text-ink-400">المتبقي</p><p className="font-medium text-warning-600">{formatCurrency(remaining / 100)}</p></div>
              <div><p className="text-xs text-ink-400">الحالة</p><p className="font-medium text-ink-700">{PAYMENT_STATUS_LABELS[detail.payment_status]}</p></div>
            </div>
            <p className="mt-3 rounded-lg bg-ink-50 px-3 py-2 text-xs text-ink-500">تُسجَّل الدفعات والتأمين والاسترداد من «الملخص المالي» أدناه — مسار واحد لكل حركة مالية، بسند مرقّم وقابل للتدقيق.</p>
          </Card>}

          <Card>
            <div className="mb-3 flex items-center gap-2">
              <DoorClosed className="h-5 w-5 text-brand-600" />
              <h2 className="text-base font-semibold text-ink-800">الغرفة</h2>
            </div>
            {detail.room ? (
              <p className="text-sm text-ink-700">
                غرفة {detail.room.room_number} · <span className="text-ink-400">{ROOM_STATUS_LABELS[detail.room.status] ?? detail.room.status}</span>
              </p>
            ) : (
              <div className="space-y-3">
                <div>
                  <label className="label">تخصيص غرفة ({detail.room_category?.name_ar ?? "التصنيف"})</label>
                  <select value={selectedRoom} onChange={(e) => setSelectedRoom(e.target.value)} className="input">
                    <option value="">اختر غرفة متاحة</option>
                    {rooms.map((r) => <option key={r.id} value={r.id}>{r.room_number} · {ROOM_STATUS_LABELS[r.status] ?? r.status}</option>)}
                  </select>
                  {rooms.length === 0 && <p className="mt-1 text-xs text-ink-400">لا توجد وحدة من هذا النوع متاحة لكامل فترة الإقامة.</p>}
                </div>
                <button onClick={assignRoom} disabled={action === "assign" || !selectedRoom} className="btn-primary w-full text-sm">
                  {action === "assign" ? <Spinner className="h-4 w-4" /> : <DoorClosed className="h-4 w-4" />} تخصيص الغرفة
                </button>
              </div>
            )}
          </Card>
        </div>

        <OfficeGuestDialog open={officeGuest.open} reservationId={detail.id} guest={officeGuest.guest} onClose={() => setOfficeGuest({ open: false, guest: null })} onDone={async () => { setOfficeGuest({ open: false, guest: null }); await load(); }} />
        <StaySummaryDialog open={summaryOpen} reservationId={detail.id} canRecord={canOffice} onClose={() => setSummaryOpen(false)} onChanged={load} />

        {/* The stay cycle (0033): Shomoos, the arrival, the code, the nights, the departure, the inspection, «مغلق» */}
        <div className="lg:col-span-2">
          <StayCycle reservationId={detail.id} branchId={detail.branch_id} refreshKey={tick} onChanged={load} />
        </div>

        {/* Stay management & financial ledger (Zaaer core) */}
        <div className="lg:col-span-2">
          <ReservationOperations reservationId={detail.id} refreshKey={tick} onChanged={load} />
        </div>

        {/* Audit */}
        {(role === "owner" || role === "manager" || role === "supervisor") && (
          <Card className="lg:col-span-2">
            <div className="mb-3 flex items-center gap-2">
              <Sparkles className="h-5 w-5 text-ink-400" />
              <h2 className="text-base font-semibold text-ink-800">سجل العمليات</h2>
            </div>
            <AuditLog reservationId={detail.id} refreshKey={tick} />
          </Card>
        )}
      </div>
    </div>
  );
}

const extraGuest = (extra: ReservationDetail | null, id: string) => extra?.guests?.find((x) => x.id === id) ?? null;

const AUDIT_LABELS: Record<string, string> = {
  // the stay cycle (0033)
  "reservation.checked_in": "تسجيل الوصول", "reservation.checked_out": "تسجيل المغادرة", "reservation.shomoos_registered": "تسجيل شموس",
  "reservation.shomoos_accepted": "قبول شموس", "reservation.inspected": "فحص المغادرة", "reservation.damage_charged": "رسم ضرر",
  "reservation.payment_exception": "سبب استمرار مع ليلة غير مدفوعة", "reservation.check_in_undone": "تراجع عن تسجيل الوصول",
  "reservation.stay_reopened": "إعادة فتح الإقامة", "reservation.cancel_undone": "تراجع عن الإلغاء", "reservation.closed": "إغلاق الإقامة",
  "reservation.unclosed": "العودة إلى «غادر»", "reservation.created": "إنشاء الحجز", "reservation.cancelled": "إلغاء الحجز",
  "reservation.departure_changed": "تغيير المغادرة", "reservation.room_switched": "تبديل الوحدة", "reservation.service_added": "إضافة خدمة", "reservation.total_changed": "تعديل الإجمالي",
  "voucher.receipt_created": "سند قبض", "voucher.deposit_created": "قبض تأمين", "voucher.refund_created": "استرداد", "voucher.deposit_refund_created": "رد تأمين",
  "voucher.deposit_apply_created": "تغطية من التأمين", "voucher.cancelled": "إلغاء سند", "invoice.issued": "إصدار فاتورة",
  approve_identity: "اعتماد مطابقة الهوية",
  reject_identity: "رفض مطابقة الهوية",
  // phase 5 (0038)
  "guest.entered_from_document": "إدخال بيانات نزيل من الوثيقة", "guest.corrected": "تصحيح بيانات نزيل", "reservation.hold_set": "وضع حظر على الحجز", "reservation.hold_lifted": "رفع الحظر عن الحجز",
  "reservation.platform_checked": "مطابقة مع المنصة", "reservation.platform_unchecked": "إلغاء المطابقة مع المنصة", "reservation.summary_signed": "توقيع ملخص الإقامة", guest_summary_accepted: "إقرار الضيف بملخص الإقامة",
  guest_data_submitted: "إدخال الضيف لبياناته",
  confirm_payment: "تأكيد السداد",
  confirm_gov_registration: "تأكيد التسجيل النظامي",
  assign_room: "تخصيص غرفة",
  approve_checkin: "اعتماد الدخول",
  deliver_access_code: "تسليم رمز الصندوق",
  deliver_keybox: "تسليم رمز الصندوق",
  mark_delivery_failed: "الإبلاغ عن فشل التسليم",
  checkout: "المغادرة",
  checkout_override: "مغادرة بتجاوز إداري",
};

function AuditLog({ reservationId, refreshKey }: { reservationId: string; refreshKey: number }) {
  const [events, setEvents] = useState<{ action: string; created_at: string; actor_id: string | null }[]>([]);
  useEffect(() => {
    let alive = true;
    (async () => {
      const { data } = await supabase.from("audit_events").select("action, created_at, actor_id").eq("entity_id", reservationId).order("created_at", { ascending: false }).limit(50);
      if (alive) setEvents((data as { action: string; created_at: string; actor_id: string | null }[]) ?? []);
    })();
    return () => { alive = false; };
  }, [reservationId, refreshKey]);

  return (
    <div className="space-y-2">
      {events.map((e, i) => (
        <div key={i} className="flex items-center justify-between text-xs text-ink-500">
          <span>{AUDIT_LABELS[e.action] ?? auditActionLabel(e.action)}</span>
          <span className="text-ink-400">{formatDateTime(e.created_at)}</span>
        </div>
      ))}
      {events.length === 0 && <p className="text-xs text-ink-400">لا توجد عمليات مسجّلة بعد.</p>}
    </div>
  );
}
