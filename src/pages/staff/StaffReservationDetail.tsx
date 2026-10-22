import { useEffect, useState, useCallback } from "react";
import { useParams, useNavigate, Link } from "react-router-dom";
import { ArrowLeft, UserCheck, UserX, CreditCard, KeyRound, CheckCircle2, XCircle, FileCheck, Sparkles, ShieldCheck, AlertCircle, Home, DoorClosed, ShieldAlert, AlertTriangle } from "lucide-react";
import { supabase } from "../../lib/supabase";
import { useAuth } from "../../lib/auth";
import { staffApi, toArabicError, type GateResult } from "../../lib/api";
import { Card, Spinner, EmptyState, ErrorBanner, Badge } from "../../components/ui";
import {
  RESERVATION_STATUS_LABELS, PAYMENT_STATUS_LABELS, GUEST_VERIFICATION_LABELS, IDENTITY_TYPE_LABELS, ROOM_STATUS_LABELS,
  type ReservationStatus, type PaymentStatus, type GuestVerificationStatus, type AccessStatus, type IdentityType, type RoomStatus,
} from "../../lib/types";
import { formatCurrency, maskId, formatDateTime } from "../../lib/utils";
import { ReservationOperations } from "../../components/ReservationOperations";
import { opsApi } from "../../lib/api";

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

interface EvalResult { allowed: boolean; reasons: string[] }
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
  const canOverride = role === "owner" || role === "manager";
  // money is shown only to money roles (the server strips it in fn_reservation_detail; the legacy row read is gated here too)
  const canMoney = role === "owner" || role === "manager" || role === "supervisor" || role === "finance";

  const [detail, setDetail] = useState<Detail | null>(null);
  const [guests, setGuests] = useState<GuestDetail[]>([]);
  const [evaluation, setEvaluation] = useState<EvalResult | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [action, setAction] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [gateReasons, setGateReasons] = useState<string[] | null>(null);

  // Inline forms
  const [rejectingGuest, setRejectingGuest] = useState<string | null>(null);
  const [rejectReason, setRejectReason] = useState("");
  const [govRef, setGovRef] = useState("");
  const [rooms, setRooms] = useState<RoomOption[]>([]);
  const [group, setGroup] = useState<Array<{ id: string; internal_ref: string; room_number: string | null; category_name: string | null }>>([]);
  const [selectedRoom, setSelectedRoom] = useState("");
  const [deliverChannel, setDeliverChannel] = useState<"screen" | "supervisor">("screen");
  const [revealedCode, setRevealedCode] = useState<string | null>(null);
  const [failReason, setFailReason] = useState("");
  const [showFail, setShowFail] = useState(false);
  const [overrideReason, setOverrideReason] = useState("");

  const load = useCallback(async () => {
    if (!id) return;
    try {
      const [res, g, evalRes] = await Promise.all([
        supabase.from("reservations").select(RESERVATION_SELECT).eq("id", id).maybeSingle(),
        supabase.from("reservation_guests").select("id, is_primary, full_name, identity_type, identity_number_last4, nationality, birth_date, phone, relationship, verification_status, data_submitted").eq("reservation_id", id).order("is_primary", { ascending: false }),
        supabase.rpc("fn_evaluate_access", { p_reservation: id, p_skip_supervisor: false }),
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
      setEvaluation(((evalRes.data as EvalResult[]) ?? [])[0] ?? null);
      setLoadError(null);
    } catch (e) {
      setLoadError(toArabicError(e));
    } finally {
      setLoading(false);
    }
  }, [id, canMoney]);

  useEffect(() => { load(); }, [load]);
  useEffect(() => {
    if (!id || !detail?.group_ref) { setGroup([]); return; }
    supabase.rpc("fn_reservation_group", { p_reservation: id }).then(({ data }) => setGroup((data as typeof group) ?? []));
  }, [id, detail?.group_ref]); // eslint-disable-line react-hooks/exhaustive-deps

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
    setAction(name); setActionError(null); setNotice(null); setGateReasons(null);
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

  // ---- Gov registration ----
  const confirmGovRegistration = () => run("gov", async () => {
    if (!id) return;
    if (!govRef.trim()) throw new Error("VALIDATION: reference_required");
    await staffApi.confirmGovRegistration(id, govRef.trim());
    setGovRef("");
  });

  // ---- Room assignment ----
  const assignRoom = () => run("assign", async () => {
    if (!id) return;
    if (!selectedRoom) throw new Error("ROOM_NOT_FOUND");
    await staffApi.assignRoom(id, selectedRoom);
    setSelectedRoom("");
  });

  // ---- Check-in approval ----
  const approveCheckIn = () => run("approve_checkin", async () => {
    if (!id) return;
    const r: GateResult = await staffApi.approveCheckin(id);
    if (!r.ok) setGateReasons(r.reasons ?? ["شروط ناقصة"]);
  });

  // ---- Deliver code ----
  const deliverCode = () => run("deliver", async () => {
    if (!id) return;
    const r: GateResult = await staffApi.deliverAccessCode(id, deliverChannel);
    if (!r.ok) { setGateReasons(r.reasons ?? ["شروط ناقصة"]); return; }
    if (deliverChannel === "supervisor" && r.code) setRevealedCode(r.code);
    const parts: string[] = ["تم تسليم الرمز بنجاح."];
    if (r.released_count !== null && r.released_count !== undefined) parts.push(`عدد الغرف المتاحة للعرض الآن: ${r.released_count}`);
    setNotice(parts.join(" "));
  });

  // ---- Delivery failed ----
  const markDeliveryFailed = () => run("fail", async () => {
    if (!id) return;
    if (!failReason.trim()) throw new Error("REASON_REQUIRED");
    await staffApi.markDeliveryFailed(id, failReason.trim());
    setShowFail(false); setFailReason("");
  });

  // ---- Checkout ----
  const checkout = (withOverride: boolean) => run("checkout", async () => {
    if (!id) return;
    const r: GateResult = await staffApi.checkout(id, withOverride && overrideReason.trim() ? overrideReason.trim() : undefined);
    if (!r.ok) { setGateReasons(r.reasons ?? ["تعذّر تنفيذ المغادرة"]); return; }
    setOverrideReason("");
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
      {group.length > 1 && (
        <div className="mb-4 flex flex-wrap items-center gap-2 rounded-xl border border-brand-100 bg-brand-50/50 px-3 py-2 text-xs text-ink-600">
          <span className="font-medium text-brand-700">حجز جماعي {detail.group_ref} — {group.length} وحدات:</span>
          {group.map((g) => g.id === detail.id
            ? <span key={g.id} className="rounded-md bg-white px-2 py-0.5 font-mono font-semibold text-ink-800 shadow-sm">{g.internal_ref}{g.room_number ? ` · ${g.room_number}` : ""}</span>
            : <Link key={g.id} to={`/staff/reservations/${g.id}`} className="rounded-md px-2 py-0.5 font-mono hover:bg-white">{g.internal_ref}{g.room_number ? ` · ${g.room_number}` : ` · ${g.category_name ?? ""}`}</Link>)}
        </div>
      )}

      {detail.security_hold && (
        <div className="mb-4 flex items-start gap-3 rounded-xl border border-danger-500/30 bg-danger-500/10 px-4 py-3 text-sm text-danger-600">
          <ShieldAlert className="mt-0.5 h-5 w-5 shrink-0" />
          <div>
            <p className="font-semibold">يوجد حظر أمني على هذا الحجز</p>
            {detail.security_hold_reason && <p className="mt-0.5 text-xs">{detail.security_hold_reason}</p>}
            <p className="mt-0.5 text-xs">لا يمكن اعتماد الدخول أو تسليم الرمز حتى يُرفع الحظر من الإدارة.</p>
          </div>
        </div>
      )}

      {loadError && <div className="mb-4"><ErrorBanner message={loadError} /></div>}
      {actionError && <div className="mb-4"><ErrorBanner message={actionError} /></div>}
      {notice && <div className="mb-4 rounded-xl border border-success-500/30 bg-success-500/10 px-4 py-3 text-sm text-success-600">{notice}</div>}
      {gateReasons && (
        <div className="mb-4 rounded-xl border border-warning-500/30 bg-warning-500/10 p-4">
          <p className="flex items-center gap-2 text-sm font-medium text-warning-600"><AlertCircle className="h-4 w-4" /> تعذّر تنفيذ الإجراء للأسباب التالية:</p>
          <ul className="mt-2 space-y-1">{gateReasons.map((r, i) => <li key={i} className="text-xs text-warning-600">• {r}</li>)}</ul>
        </div>
      )}

      {/* One-time code reveal (supervisor channel) */}
      {revealedCode && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-ink-900/60 p-4">
          <div className="card w-full max-w-sm p-6 text-center">
            <KeyRound className="mx-auto mb-3 h-8 w-8 text-brand-600" />
            <h3 className="text-base font-semibold text-ink-800">رمز صندوق المفتاح</h3>
            <p className="mt-1 text-xs text-ink-400">يُعرض مرة واحدة فقط. بلّغه للنزيل شفهيًا ثم أغلق النافذة.</p>
            <p className="my-5 font-mono text-4xl font-bold tracking-[0.3em] text-ink-900" dir="ltr">{revealedCode}</p>
            <button onClick={() => setRevealedCode(null)} className="btn-primary w-full">
              <CheckCircle2 className="h-4 w-4" /> تم التسليم شفهيًا
            </button>
          </div>
        </div>
      )}

      <div className="grid gap-4 lg:grid-cols-2">
        {/* Guests / Identity */}
        <Card>
          <div className="mb-3 flex items-center gap-2">
            <UserCheck className="h-5 w-5 text-brand-600" />
            <h2 className="text-base font-semibold text-ink-800">النزلاء ومطابقة الهوية</h2>
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
                    <p className="mt-0.5 text-xs text-ink-400">الحالة: {GUEST_VERIFICATION_LABELS[g.verification_status]}{!g.data_submitted && " · لم تُدخل البيانات"}</p>
                  </div>
                  {g.verification_status !== "verified" && g.verification_status !== "rejected" && (
                    <div className="flex gap-2">
                      <button onClick={() => approveIdentity(g.id)} disabled={action === "identity_" + g.id || !g.data_submitted} className="btn-accent text-xs">
                        {action === "identity_" + g.id ? <Spinner className="h-3.5 w-3.5" /> : <UserCheck className="h-3.5 w-3.5" />} اعتمد
                      </button>
                      <button onClick={() => { setRejectingGuest(rejectingGuest === g.id ? null : g.id); setRejectReason(""); }} className="btn-danger text-xs">
                        <UserX className="h-3.5 w-3.5" /> رفض
                      </button>
                    </div>
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
            ملاحظة: إدخال البيانات لا يعني التحقق. يجب على المشرف مطابقة الوثيقة الأصلية.
          </p>
        </Card>

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
              <FileCheck className="h-5 w-5 text-brand-600" />
              <h2 className="text-base font-semibold text-ink-800">التسجيل النظامي</h2>
            </div>
            {detail.government_registration ? (
              <div>
                <p className="flex items-center gap-2 text-sm text-success-600"><CheckCircle2 className="h-4 w-4" /> تم تأكيد التسجيل</p>
                {detail.gov_registration_ref && <p className="mt-1 text-xs text-ink-400" dir="ltr">المرجع: {detail.gov_registration_ref}</p>}
              </div>
            ) : (
              <form onSubmit={(e) => { e.preventDefault(); confirmGovRegistration(); }} className="space-y-3">
                <div>
                  <label className="label">رقم مرجع التسجيل (إلزامي)</label>
                  <input value={govRef} onChange={(e) => setGovRef(e.target.value)} className="input" dir="ltr" placeholder="رقم المرجع في منصة التسجيل" />
                </div>
                <button type="submit" disabled={action === "gov" || !govRef.trim()} className="btn-outline w-full text-sm">
                  {action === "gov" ? <Spinner className="h-4 w-4" /> : <FileCheck className="h-4 w-4" />} تأكيد إتمام التسجيل النظامي
                </button>
              </form>
            )}
          </Card>

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

        {/* Access gate */}
        <Card className="lg:col-span-2">
          <div className="mb-4 flex items-center gap-2">
            <KeyRound className="h-5 w-5 text-brand-600" />
            <h2 className="text-base font-semibold text-ink-800">بوابة اعتماد الدخول وتسليم الرمز</h2>
          </div>

          <div className="mb-4 grid grid-cols-2 gap-2 sm:grid-cols-4">
            <Condition label="الحجز مؤكد" ok={["confirmed", "checked_in"].includes(detail.status)} />
            <Condition label="الهوية معتمدة" ok={detail.identity_status === "verified"} />
            <Condition label="السداد مستوفى" ok={detail.payment_status === "paid"} />
            <Condition label="التسجيل النظامي" ok={detail.government_registration} />
            <Condition label="غرفة مخصصة" ok={!!detail.room_id} />
            <Condition label="الغرفة جاهزة" ok={!evaluation?.reasons?.some((r) => r.includes("الغرفة غير جاهزة"))} />
            <Condition label="اعتماد المشرف" ok={["approved", "delivery_pending", "delivered", "acknowledged"].includes(detail.access_status)} />
            <Condition label="الرمز صالح" ok={!evaluation?.reasons?.some((r) => r.includes("رمز") || r.includes("صندوق"))} />
          </div>

          {evaluation && !evaluation.allowed && (
            <div className="mb-4 rounded-xl border border-warning-500/30 bg-warning-500/10 p-4">
              <p className="flex items-center gap-2 text-sm font-medium text-warning-600"><AlertCircle className="h-4 w-4" /> شروط ناقصة:</p>
              <ul className="mt-2 space-y-1">
                {evaluation.reasons.map((r, i) => <li key={i} className="text-xs text-warning-600">• {r}</li>)}
              </ul>
            </div>
          )}

          {detail.status !== "checked_out" && detail.status !== "closed" && ["locked", "eligibility_review"].includes(detail.access_status) && (
            <button onClick={approveCheckIn} disabled={action === "approve_checkin" || detail.security_hold} className="btn-primary w-full">
              {action === "approve_checkin" ? <Spinner className="h-4 w-4" /> : <ShieldCheck className="h-4 w-4" />} {action === "approve_checkin" ? "جارٍ…" : "اعتماد الدخول"}
            </button>
          )}

          {["approved", "delivery_pending"].includes(detail.access_status) && (
            <div className="space-y-3">
              <div>
                <label className="label">قناة التسليم</label>
                <div className="grid grid-cols-2 gap-2">
                  <label className={`flex cursor-pointer items-center gap-2 rounded-xl border px-3 py-2 text-sm ${deliverChannel === "screen" ? "border-brand-400 bg-brand-50 text-brand-700" : "border-ink-100 text-ink-600"}`}>
                    <input type="radio" name="channel" value="screen" checked={deliverChannel === "screen"} onChange={() => setDeliverChannel("screen")} />
                    شاشة النزيل (الرمز يظهر للنزيل)
                  </label>
                  <label className={`flex cursor-pointer items-center gap-2 rounded-xl border px-3 py-2 text-sm ${deliverChannel === "supervisor" ? "border-brand-400 bg-brand-50 text-brand-700" : "border-ink-100 text-ink-600"}`}>
                    <input type="radio" name="channel" value="supervisor" checked={deliverChannel === "supervisor"} onChange={() => setDeliverChannel("supervisor")} />
                    تسليم شفهي عبر المشرف
                  </label>
                </div>
              </div>
              <button onClick={deliverCode} disabled={action === "deliver" || detail.security_hold} className="btn-accent w-full">
                {action === "deliver" ? <Spinner className="h-4 w-4" /> : <KeyRound className="h-4 w-4" />} {action === "deliver" ? "جارٍ التسليم…" : "تسليم رمز الصندوق"}
              </button>
            </div>
          )}

          {(detail.access_status === "delivered" || detail.access_status === "acknowledged") && (
            <div className="space-y-3">
              <div className="rounded-xl bg-success-500/10 p-4 text-center">
                <CheckCircle2 className="mx-auto mb-2 h-8 w-8 text-success-600" />
                <p className="text-sm font-medium text-success-600">تم تسليم رمز الصندوق بنجاح</p>
                {detail.actual_check_in && <p className="mt-1 text-xs text-ink-400">وقت الدخول: {formatDateTime(detail.actual_check_in)}</p>}
              </div>
              {detail.access_status === "delivered" && !showFail && (
                <button onClick={() => setShowFail(true)} className="btn-outline w-full text-sm">
                  <AlertTriangle className="h-4 w-4" /> الإبلاغ عن فشل التسليم
                </button>
              )}
              {detail.access_status === "delivered" && showFail && (
                <div className="space-y-2 rounded-xl border border-ink-100 p-3">
                  <label className="label">سبب فشل التسليم (إلزامي)</label>
                  <textarea value={failReason} onChange={(e) => setFailReason(e.target.value)} className="input" rows={2} placeholder="مثال: لم تصل الرسالة للنزيل" />
                  <div className="flex gap-2">
                    <button onClick={markDeliveryFailed} disabled={action === "fail" || !failReason.trim()} className="btn-danger text-xs">
                      {action === "fail" ? <Spinner className="h-3.5 w-3.5" /> : <AlertTriangle className="h-3.5 w-3.5" />} تأكيد فشل التسليم
                    </button>
                    <button onClick={() => { setShowFail(false); setFailReason(""); }} className="btn-outline text-xs">إلغاء</button>
                  </div>
                </div>
              )}
            </div>
          )}

          {detail.status === "checked_in" && (
            <div className="mt-4 space-y-3 border-t border-ink-50 pt-4">
              <button onClick={() => checkout(false)} disabled={action === "checkout"} className="btn-danger w-full">
                {action === "checkout" ? <Spinner className="h-4 w-4" /> : <Home className="h-4 w-4" />} {action === "checkout" ? "جارٍ المغادرة…" : "تأكيد المغادرة"}
              </button>
              {canOverride && gateReasons && (
                <div className="space-y-2 rounded-xl border border-warning-500/30 p-3">
                  <label className="label">تجاوز إداري — سبب التجاوز</label>
                  <textarea value={overrideReason} onChange={(e) => setOverrideReason(e.target.value)} className="input" rows={2} placeholder="يُسجل السبب في سجل العمليات" />
                  <button onClick={() => checkout(true)} disabled={action === "checkout" || !overrideReason.trim()} className="btn-outline w-full text-sm">
                    <ShieldCheck className="h-4 w-4" /> تأكيد المغادرة مع التجاوز
                  </button>
                </div>
              )}
            </div>
          )}

          {(detail.status === "checked_out" || detail.status === "closed") && (
            <div className="rounded-xl bg-ink-50 p-4 text-center text-sm text-ink-600">
              تمت المغادرة{detail.actual_check_out && ` في ${formatDateTime(detail.actual_check_out)}`}. الغرفة الآن تحت التنظيف، ورمز الصندوق يحتاج إلى تغيير.
            </div>
          )}
        </Card>

        {/* Stay management & financial ledger (Zaaer core) */}
        <div className="lg:col-span-2">
          <ReservationOperations reservationId={detail.id} onChanged={load} />
        </div>

        {/* Audit */}
        {(role === "owner" || role === "manager" || role === "supervisor") && (
          <Card className="lg:col-span-2">
            <div className="mb-3 flex items-center gap-2">
              <Sparkles className="h-5 w-5 text-ink-400" />
              <h2 className="text-base font-semibold text-ink-800">سجل العمليات</h2>
            </div>
            <AuditLog reservationId={detail.id} approvedAt={detail.checkin_approved_at} refreshKey={`${detail.status}-${detail.access_status}-${detail.payment_status}-${detail.identity_status}-${detail.government_registration}-${detail.room_id}`} />
          </Card>
        )}
      </div>
    </div>
  );
}

function Condition({ label, ok }: { label: string; ok: boolean }) {
  return (
    <div className={`flex items-center gap-2 rounded-lg px-3 py-2 text-xs ${ok ? "bg-success-500/10 text-success-600" : "bg-ink-50 text-ink-400"}`}>
      {ok ? <CheckCircle2 className="h-4 w-4" /> : <XCircle className="h-4 w-4" />}
      {label}
    </div>
  );
}

const AUDIT_LABELS: Record<string, string> = {
  approve_identity: "اعتماد مطابقة الهوية",
  reject_identity: "رفض مطابقة الهوية",
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

function AuditLog({ reservationId, approvedAt, refreshKey }: { reservationId: string; approvedAt: string | null; refreshKey: string }) {
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
      {approvedAt && (
        <div className="flex items-center gap-2 text-xs text-ink-500">
          <ShieldCheck className="h-3.5 w-3.5 text-accent-600" /> اعتماد الدخول · {formatDateTime(approvedAt)}
        </div>
      )}
      {events.map((e, i) => (
        <div key={i} className="flex items-center justify-between text-xs text-ink-500">
          <span>{AUDIT_LABELS[e.action] ?? e.action}</span>
          <span className="text-ink-400">{formatDateTime(e.created_at)}</span>
        </div>
      ))}
      {events.length === 0 && !approvedAt && <p className="text-xs text-ink-400">لا توجد عمليات مسجّلة بعد.</p>}
    </div>
  );
}
