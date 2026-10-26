import { useEffect, useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import { ArrowLeft, CalendarPlus, Calculator, Plus, X, Users, Search, ShieldBan, UserCheck } from "lucide-react";
import { supabase } from "../../lib/supabase";
import { useAuth } from "../../lib/auth";
import { useBranchQuery, must } from "../../lib/useBranchQuery";
import { opsApi, guestProfileApi, toArabicError, type Quote, type PriceRun, type GuestProfileRow } from "../../lib/api";
import { Stars } from "../../components/Guests";
import { Card, SectionTitle, ErrorBanner, Spinner, LoadErrorCard } from "../../components/ui";
import { Field, MoneyInput, Toggle } from "../../components/forms";
import { BranchPicker } from "../../components/BranchPicker";
import { formatCurrency, todayISO } from "../../lib/utils";
import { CLEANLINESS_LABELS } from "../../lib/types";

interface Cat { id: string; name_ar: string; base_capacity: number; max_capacity: number; base_price_halalas: number }
interface Src { id: string; name: string; kind: string; external_reference_required: boolean }

interface Options { cats: Cat[]; sources: Src[] }
const NO_OPTIONS: Options = { cats: [], sources: [] };

const addDays = (d: string, n: number) => { const x = new Date(d + "T00:00:00Z"); x.setUTCDate(x.getUTCDate() + n); return x.toISOString().slice(0, 10); };

export default function StaffReservationNew() {
  const navigate = useNavigate();
  const { profile, can } = useAuth();
  // a rate below the quote stays the owner's and the manager's (0030); the discount follows the matrix (decision 71)
  const isMgr = profile?.role === "owner" || profile?.role === "manager";
  // decision 9: the supervisor discounts too, within the branch's percentage and the type's minimum (the quote says how much)
  const canDiscount = can("disc.before") || can("disc.after");
  // G24 (decision 40): the unit types of the ACTIVE branch; booking sources are organisation-wide
  const opts = useBranchQuery<Options>(async (branchId) => {
    const [c, s] = await Promise.all([
      supabase.from("room_categories").select("id, name_ar, base_capacity, max_capacity, base_price_halalas").eq("branch_id", branchId).is("archived_at", null).eq("is_active", true).order("sort_order"),
      supabase.from("booking_sources").select("id, name, kind, external_reference_required").eq("is_active", true).is("archived_at", null).order("name"),
    ]);
    return { cats: must(c) as Cat[], sources: must(s) as Src[] };
  }, [], NO_OPTIONS);
  const { cats, sources } = opts.data; const branchId = opts.branchId;
  const [f, setF] = useState({ check_in: todayISO(), check_out: addDays(todayISO(), 1), category_id: "", room_id: "", source_id: "", external_ref: "", guest_name: "", guest_phone: "", nationality: "", adults: 1, companions: 0, booking_type: "individual", company_name: "", visit_purpose: "", notes: "", confirm: true, override: false, nightly_rate: null as number | null, discount: 0, discount_reason: "",
    // decision 4: a platform's booking says who collects and the day it was booked there
    platform_collects: null as boolean | null, platform_booked_on: todayISO() });
  // decision 2: the guest profile — chosen from the search, matched by phone on the server, or a new one
  const [guest, setGuest] = useState<GuestProfileRow | null>(null);
  const [newProfile, setNewProfile] = useState(false);
  const [profileQ, setProfileQ] = useState("");
  const [profileHits, setProfileHits] = useState<GuestProfileRow[]>([]);
  useEffect(() => {
    const q = profileQ.trim(); if (q.length < 2) { setProfileHits([]); return; }
    let alive = true; const t = setTimeout(() => guestProfileApi.list({ q, limit: 8 }).then((r) => { if (alive) setProfileHits(r.rows); }).catch(() => { if (alive) setProfileHits([]); }), 250);
    return () => { alive = false; clearTimeout(t); };
  }, [profileQ]);
  // Zaaer parity (0011): companions by name, extra units in the same booking (one reservation per unit, created atomically)
  const [companionRows, setCompanionRows] = useState<Array<{ full_name: string; relationship: string }>>([]);
  const [extraUnits, setExtraUnits] = useState<Array<{ category_id: string; adults: number; companions: number }>>([]);
  const [times, setTimes] = useState({ arrival: "", departure: "" });
  const [quote, setQuote] = useState<Quote | null>(null);
  const [rooms, setRooms] = useState<Array<{ room_id: string; room_number: string; status: string; cleanliness: string; block_name: string | null }>>([]);
  const [error, setError] = useState<string | null>(null); const [busy, setBusy] = useState(false);

  // Branch-scoped choices never carry over to another branch: the unit type, the unit and the extra units are reset
  // whenever the branch's options change (a branch switch clears them first); the source stays if it still exists.
  useEffect(() => {
    setF((p) => ({ ...p, category_id: cats[0]?.id ?? "", room_id: "",
      source_id: sources.some((x) => x.id === p.source_id) ? p.source_id : (sources.find((x) => x.kind === "direct")?.id ?? sources[0]?.id ?? "") }));
    setExtraUnits([]);
  }, [cats, sources]);

  const nights = useMemo(() => Math.max(0, Math.round((new Date(f.check_out).getTime() - new Date(f.check_in).getTime()) / 86400000)), [f.check_in, f.check_out]);
  const source = sources.find((s) => s.id === f.source_id);
  const cat = cats.find((c) => c.id === f.category_id);

  // live quote + availability from the server (the browser never computes prices)
  useEffect(() => {
    // a unit type that is not one of the active branch's (a branch switch in progress) is never quoted
    if (!branchId || !cats.some((c) => c.id === f.category_id) || nights <= 0) { setQuote(null); setRooms([]); return; }
    let alive = true;
    (async () => {
      try {
        const [q, r] = await Promise.all([
          opsApi.quote(branchId, f.category_id, f.check_in, f.check_out, f.override ? f.nightly_rate : null, canDiscount ? f.discount : 0, f.source_id || null),
          opsApi.availableRooms(branchId, f.check_in, f.check_out, f.category_id),
        ]);
        if (!alive) return; setQuote(q); setRooms(r); setError(null);
        if (f.room_id && !r.some((x) => x.room_id === f.room_id)) setF((p) => ({ ...p, room_id: "" }));
      } catch (e) { if (alive) { setQuote(null); setError(toArabicError(e)); } }
    })();
    return () => { alive = false; };
  }, [branchId, cats, f.category_id, f.check_in, f.check_out, f.override, f.nightly_rate, f.discount, f.source_id, nights, canDiscount]); // eslint-disable-line react-hooks/exhaustive-deps

  async function submit() {
    setBusy(true); setError(null);
    try {
      const named = companionRows.filter((c) => c.full_name.trim()).map((c) => ({ full_name: c.full_name.trim(), relationship: c.relationship.trim() || null }));
      const main = { category_id: f.category_id, room_id: f.room_id || null, adults: f.adults, companions: Math.max(f.companions, named.length), companions_details: named, nightly_rate_halalas: f.override ? f.nightly_rate : null };
      const r = await opsApi.createReservation({ branch_id: branchId, ...main, check_in: f.check_in, check_out: f.check_out, source_id: f.source_id, external_ref: f.external_ref || null,
        arrival_time: times.arrival || null, departure_time: times.departure || null,
        ...(source?.kind === "external" ? { platform_collects: f.platform_collects, platform_booked_on: f.platform_booked_on } : {}),
        guest_profile_id: guest?.id ?? null, new_profile: newProfile,
        guest_name: f.guest_name, guest_phone: f.guest_phone || null, nationality: f.nationality || null, booking_type: f.booking_type, company_name: f.company_name || null, visit_purpose: f.visit_purpose || null,
        notes: f.notes || null, confirm: f.confirm, discount_halalas: canDiscount ? f.discount : 0, discount_reason: f.discount_reason || null,
        ...(extraUnits.length > 0 ? { units: [main, ...extraUnits.map((u) => ({ category_id: u.category_id, room_id: null, adults: u.adults, companions: u.companions, companions_details: [], nightly_rate_halalas: null, discount_halalas: 0 }))] } : {}) });
      navigate(`/staff/reservations/${r.id}`);
    } catch (e) { setError(toArabicError(e)); } finally { setBusy(false); }
  }

  const namedCompanions = companionRows.filter((c) => c.full_name.trim()).length;
  const capacityOk = (cat ? f.adults + Math.max(f.companions, namedCompanions) <= cat.max_capacity : true)
    && extraUnits.every((u) => { const c = cats.find((x) => x.id === u.category_id); return !c || u.adults + u.companions <= c.max_capacity; });
  return (
    <div>
      <button onClick={() => navigate("/staff/reservations")} className="mb-4 inline-flex items-center gap-1.5 text-sm text-ink-400 hover:text-ink-600"><ArrowLeft className="h-4 w-4" /> الحجوزات</button>
      <SectionTitle title="حجز جديد" subtitle="يتحقق الخادم من التوفر والسعة والسعر لحظة التأكيد" action={<BranchPicker />} />
      {opts.error && <div className="mb-4"><LoadErrorCard message={opts.error} onRetry={opts.reload} /></div>}
      {error && <div className="mb-4"><ErrorBanner message={error} /></div>}
      <form onSubmit={(e) => { e.preventDefault(); submit(); }} className="grid gap-4 lg:grid-cols-3">
        <div className="space-y-4 lg:col-span-2">
          <Card>
            <h3 className="mb-3 font-semibold text-ink-800">المدة والوحدة</h3>
            <div className="grid gap-3 sm:grid-cols-3">
              <Field label="الوصول"><input type="date" className="input" dir="ltr" value={f.check_in} onChange={(e) => setF({ ...f, check_in: e.target.value, check_out: f.check_out <= e.target.value ? addDays(e.target.value, 1) : f.check_out })} /></Field>
              <Field label="المغادرة"><input type="date" className="input" dir="ltr" min={addDays(f.check_in, 1)} value={f.check_out} onChange={(e) => setF({ ...f, check_out: e.target.value })} /></Field>
              <Field label="الليالي"><input className="input bg-ink-50" dir="ltr" readOnly value={nights} /></Field>
              <Field label="وقت الوصول المتوقع" hint="فارغ = موعد الفرع"><input type="time" className="input" dir="ltr" value={times.arrival} onChange={(e) => setTimes({ ...times, arrival: e.target.value })} /></Field>
              <Field label="وقت المغادرة المتوقع" hint="فارغ = موعد الفرع"><input type="time" className="input" dir="ltr" value={times.departure} onChange={(e) => setTimes({ ...times, departure: e.target.value })} /></Field>
              <div />
              <Field label="نوع الوحدة" className="sm:col-span-2"><select className="input" value={f.category_id} onChange={(e) => setF({ ...f, category_id: e.target.value, room_id: "" })}>{cats.map((c) => <option key={c.id} value={c.id}>{c.name_ar} — {formatCurrency(c.base_price_halalas / 100)} / ليلة — حتى {c.max_capacity} أشخاص</option>)}</select></Field>
              <Field label="الوحدة (اختياري الآن)" hint={rooms.length === 0 && nights > 0 ? "لا توجد وحدة متاحة لكامل الفترة من هذا النوع" : undefined}>
                <select className="input" value={f.room_id} onChange={(e) => setF({ ...f, room_id: e.target.value })}>
                  <option value="">تخصيص لاحقًا</option>
                  {rooms.map((r) => <option key={r.room_id} value={r.room_id}>{r.room_number}{r.block_name ? ` (${r.block_name})` : ""} · {CLEANLINESS_LABELS[r.cleanliness]}</option>)}
                </select>
              </Field>
            </div>
            {extraUnits.map((u, i) => (
              <div key={i} className="mt-3 grid items-end gap-3 rounded-xl border border-ink-100 p-3 sm:grid-cols-[1fr_6rem_6rem_auto]">
                <Field label={`الوحدة ${i + 2} — النوع`}><select className="input" value={u.category_id} onChange={(e) => setExtraUnits(extraUnits.map((x, j) => (j === i ? { ...x, category_id: e.target.value } : x)))}>{cats.map((c) => <option key={c.id} value={c.id}>{c.name_ar} — حتى {c.max_capacity}</option>)}</select></Field>
                <Field label="بالغون"><input type="number" min={1} className="input" dir="ltr" value={u.adults} onChange={(e) => setExtraUnits(extraUnits.map((x, j) => (j === i ? { ...x, adults: Number(e.target.value) } : x)))} /></Field>
                <Field label="مرافقون"><input type="number" min={0} className="input" dir="ltr" value={u.companions} onChange={(e) => setExtraUnits(extraUnits.map((x, j) => (j === i ? { ...x, companions: Number(e.target.value) } : x)))} /></Field>
                <button type="button" onClick={() => setExtraUnits(extraUnits.filter((_, j) => j !== i))} className="btn-ghost mb-0.5 p-2 text-ink-400" aria-label="إزالة الوحدة"><X className="h-4 w-4" /></button>
              </div>
            ))}
            <div className="mt-3 flex flex-wrap items-center gap-3">
              <button type="button" onClick={() => setExtraUnits([...extraUnits, { category_id: f.category_id, adults: 1, companions: 0 }])} className="btn-outline text-xs"><Plus className="h-3.5 w-3.5" /> وحدة أخرى في نفس الحجز</button>
              {extraUnits.length > 0 && <p className="text-[11px] text-ink-400">يُنشأ حجز لكل وحدة بنفس الضيف والتواريخ، دفعة واحدة: إن تعذّر أحدها لا يُنشأ أي منها. تُخصَّص وحدات الحجوزات الإضافية من صفحة كل حجز.</p>}
            </div>
          </Card>
          <Card>
            <h3 className="mb-3 font-semibold text-ink-800">الضيف الرئيسي</h3>
            {/* decision 2: a returning guest is picked from the profiles (by name, phone or document); a new one gets a new profile */}
            <div className="mb-3 rounded-xl border border-ink-100 p-3" data-testid="profile-picker">
              {guest ? (
                <div className="flex flex-wrap items-center justify-between gap-2 text-sm">
                  <div className="flex items-center gap-2"><UserCheck className="h-4 w-4 text-success-600" /><span className="font-medium text-ink-800">{guest.full_name}</span><span className="text-xs text-ink-400" dir="ltr">{guest.phone_masked ?? ""}</span>{guest.stays > 0 && <span className="text-xs text-ink-400">· {guest.stays} إقامة سابقة</span>}{guest.rating != null && <Stars n={guest.rating} />}{guest.banned && <span className="inline-flex items-center gap-1 text-xs font-medium text-danger-600"><ShieldBan className="h-3.5 w-3.5" /> محظور: {guest.ban_reason}</span>}</div>
                  <button type="button" onClick={() => { setGuest(null); setF({ ...f, guest_name: "", guest_phone: "", nationality: "" }); }} className="btn-ghost text-xs">تغيير</button>
                </div>
              ) : (
                <div>
                  <div className="relative"><Search className="pointer-events-none absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2 text-ink-300" /><input className="input pr-9" value={profileQ} onChange={(e) => setProfileQ(e.target.value)} placeholder="ضيف سابق؟ ابحث بالاسم أو الجوال أو رقم الوثيقة" aria-label="بحث عن ضيف سابق" /></div>
                  {profileHits.length > 0 && (
                    <ul className="mt-2 divide-y divide-ink-50 rounded-lg border border-ink-100 bg-white text-sm">
                      {profileHits.map((g) => <li key={g.id}><button type="button" onClick={() => { setGuest(g); setNewProfile(false); setProfileQ(""); setProfileHits([]); setF({ ...f, guest_name: g.full_name, nationality: g.nationality ?? f.nationality }); }} className="flex w-full items-center justify-between gap-2 px-3 py-2 text-right hover:bg-ink-50" data-testid="profile-hit"><span>{g.full_name}{g.banned && <span className="mr-2 text-xs text-danger-600">محظور</span>}</span><span className="text-xs text-ink-400" dir="ltr">{g.phone_masked ?? ""} · {g.stays}</span></button></li>)}
                    </ul>
                  )}
                  <label className="mt-2 flex items-center gap-2 text-xs text-ink-500"><input type="checkbox" checked={newProfile} onChange={(e) => setNewProfile(e.target.checked)} /> ضيف جديد (لا تربطه بملف على الجوال نفسه)</label>
                </div>
              )}
            </div>
            <div className="grid gap-3 sm:grid-cols-2">
              <Field label="الاسم (مطلوب)"><input className="input" value={f.guest_name} onChange={(e) => setF({ ...f, guest_name: e.target.value })} /></Field>
              <Field label="الجوال" hint={guest ? "يبقى جوال الملف المختار إن تُرك فارغًا" : "يُعاد استخدام ملف الضيف بالجوال نفسه ما لم تُعلّم «ضيف جديد»"}><input className="input" dir="ltr" value={f.guest_phone} onChange={(e) => setF({ ...f, guest_phone: e.target.value })} placeholder="05xxxxxxxx" /></Field>
              <Field label="الجنسية"><input className="input" value={f.nationality} onChange={(e) => setF({ ...f, nationality: e.target.value })} /></Field>
              <div className="grid grid-cols-2 gap-3">
                <Field label="بالغون"><input type="number" min={1} className="input" dir="ltr" value={f.adults} onChange={(e) => setF({ ...f, adults: Number(e.target.value) })} /></Field>
                <Field label="مرافقون"><input type="number" min={0} className="input" dir="ltr" value={f.companions} onChange={(e) => setF({ ...f, companions: Number(e.target.value) })} /></Field>
              </div>
              {!capacityOk && <p className="text-xs text-danger-600 sm:col-span-2">عدد النزلاء يتجاوز سعة نوع الوحدة.</p>}
              <div className="space-y-2 sm:col-span-2">
                {companionRows.map((c, i) => (
                  <div key={i} className="grid grid-cols-[1fr_9rem_auto] items-center gap-2">
                    <input className="input" placeholder={`اسم المرافق ${i + 1}`} value={c.full_name} onChange={(e) => setCompanionRows(companionRows.map((x, j) => (j === i ? { ...x, full_name: e.target.value } : x)))} />
                    <input className="input" placeholder="صلة القرابة" value={c.relationship} onChange={(e) => setCompanionRows(companionRows.map((x, j) => (j === i ? { ...x, relationship: e.target.value } : x)))} />
                    <button type="button" onClick={() => setCompanionRows(companionRows.filter((_, j) => j !== i))} className="btn-ghost p-2 text-ink-400" aria-label="إزالة المرافق"><X className="h-4 w-4" /></button>
                  </div>
                ))}
                <button type="button" onClick={() => setCompanionRows([...companionRows, { full_name: "", relationship: "" }])} className="btn-ghost text-xs text-brand-700"><Users className="h-3.5 w-3.5" /> تسجيل اسم مرافق (اختياري)</button>
                {companionRows.length > 0 && <p className="text-[11px] text-ink-400">يُسجَّل كل مرافق كنزيل في الحجز وتبقى مطابقة هويته عند الوصول.</p>}
              </div>
            </div>
          </Card>
          <Card>
            <h3 className="mb-3 font-semibold text-ink-800">المصدر والتفاصيل</h3>
            <div className="grid gap-3 sm:grid-cols-2">
              <Field label="مصدر الحجز"><select className="input" value={f.source_id} onChange={(e) => setF({ ...f, source_id: e.target.value })}>{sources.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></Field>
              <Field label={`رقم الحجز في المنصة${source?.external_reference_required ? " (مطلوب)" : ""}`} hint={extraUnits.length > 0 && f.external_ref ? "رقم واحد للمجموعة كلها؛ لا يُقبل في حجز أو مجموعة أخرى" : undefined}><input className="input" dir="ltr" value={f.external_ref} onChange={(e) => setF({ ...f, external_ref: e.target.value })} aria-label="رقم الحجز في المنصة" /></Field>
              {source?.kind === "external" && <>
                <Field label="من يقبض المبلغ (مطلوب)" hint="إن قبضت المنصة يُسجَّل سند «آجل عبر المنصات» تلقائيًا ويُطابَق لاحقًا مع إيداعها">
                  <select className="input" value={f.platform_collects == null ? "" : f.platform_collects ? "platform" : "property"} onChange={(e) => setF({ ...f, platform_collects: e.target.value === "" ? null : e.target.value === "platform" })} aria-label="من يقبض المبلغ" data-testid="platform-collects">
                    <option value="">— اختر —</option><option value="platform">المنصة قبضت المبلغ</option><option value="property">المنشأة تقبض عند الوصول</option>
                  </select>
                </Field>
                <Field label="تاريخ الحجز في المنصة" hint="يُحسب منه تقرير الحجوزات المتأخرة الإدخال"><input type="date" className="input" dir="ltr" max={todayISO()} value={f.platform_booked_on} onChange={(e) => setF({ ...f, platform_booked_on: e.target.value })} aria-label="تاريخ الحجز في المنصة" /></Field>
              </>}
              <Field label="نوع الحجز"><select className="input" value={f.booking_type} onChange={(e) => setF({ ...f, booking_type: e.target.value })}><option value="individual">فرد</option><option value="company">شركة</option></select></Field>
              {f.booking_type === "company" && <Field label="اسم الشركة"><input className="input" value={f.company_name} onChange={(e) => setF({ ...f, company_name: e.target.value })} /></Field>}
              <Field label="الغرض"><select className="input" value={f.visit_purpose} onChange={(e) => setF({ ...f, visit_purpose: e.target.value })}><option value="">—</option>{["سياحة", "زيارة أقارب", "عمل", "ديني", "رياضة وترفيه", "أخرى"].map((x) => <option key={x} value={x}>{x}</option>)}</select></Field>
              <Field label="ملاحظات" className="sm:col-span-2"><textarea className="input" rows={2} value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} /></Field>
            </div>
          </Card>
        </div>
        <div className="space-y-4">
          <Card>
            <h3 className="mb-3 flex items-center gap-2 font-semibold text-ink-800"><Calculator className="h-4 w-4 text-brand-600" /> التسعير</h3>
            <div className="space-y-3">
              <Toggle checked={f.override} onChange={(v) => setF({ ...f, override: v, nightly_rate: v ? (quote?.nightly_rate ?? cat?.base_price_halalas ?? 0) : null })} label="سعر ليلة يدوي لكل الليالي" />
              {f.override && <><MoneyInput valueHalalas={f.nightly_rate} onChange={(h) => setF({ ...f, nightly_rate: h })} />{!isMgr && <p className="text-[11px] text-ink-400">لا يقل عن السعر المحسوب؛ الأقل خصمٌ ضمن حدك.</p>}</>}
              {canDiscount && <>
                <Field label="خصم (إجمالي)" hint={quote?.discount_max != null ? (isMgr ? undefined : `المسموح لك حتى ${formatCurrency(quote.discount_max / 100)}${quote.supervisor_max_discount_bp ? ` (حتى ${quote.supervisor_max_discount_bp / 100}% وبما لا ينزل تحت أدنى سعر)` : " — لا خصم للمشرف في هذا الفرع"}`) : undefined}>
                  <MoneyInput valueHalalas={f.discount} onChange={(h) => setF({ ...f, discount: h ?? 0 })} />
                </Field>
                {f.discount > 0 && <Field label="سبب الخصم (إلزامي)"><input className="input" value={f.discount_reason} onChange={(e) => setF({ ...f, discount_reason: e.target.value })} aria-label="سبب الخصم" /></Field>}
              </>}
            </div>
            {quote && (
              <div className="mt-4 space-y-1.5 rounded-xl bg-ink-50 p-3 text-sm">
                {quote.runs && quote.runs.length > 0 ? <RunList runs={quote.runs} basis={quote.basis} channel={quote.channel} /> : <Row l={`الإيجار (${quote.nights} × ${formatCurrency(quote.nightly_rate / 100)})`} v={formatCurrency(quote.rent / 100)} />}
                {quote.runs && quote.runs.length > 0 && <Row l={`الإيجار (${quote.nights} ${quote.nights === 1 ? "ليلة" : "ليالٍ"})`} v={formatCurrency(quote.rent / 100)} />}
                {quote.discount !== 0 && <Row l="الخصم" v={formatCurrency(quote.discount / 100)} />}
                {quote.tax_rate_bp > 0 && <Row l={`الضريبة ${quote.tax_rate_bp / 100}% ${quote.prices_include_tax ? "(مضمنة)" : ""}`} v={formatCurrency(quote.tax / 100)} />}
                <div className="border-t border-ink-200 pt-1.5"><Row l="الإجمالي" v={formatCurrency(quote.total / 100)} strong /></div>
              </div>
            )}
          </Card>
          <Card>
            <Toggle checked={f.confirm} onChange={(v) => setF({ ...f, confirm: v })} label="تأكيد الحجز مباشرة" />
            <p className="mt-1 text-xs text-ink-400">بدون تأكيد يبقى الحجز «بانتظار التحقق» ولا يحجز الوحدة إلا بعد تخصيصها.</p>
            <button type="submit" disabled={busy || !quote || !f.guest_name.trim() || !capacityOk || nights <= 0 || (source?.kind === "external" && f.platform_collects == null)} className="btn-primary mt-4 w-full">{busy ? <Spinner className="h-4 w-4" /> : <CalendarPlus className="h-4 w-4" />} {extraUnits.length > 0 ? `إنشاء ${extraUnits.length + 1} حجوزات` : "إنشاء الحجز"}</button>
          </Card>
        </div>
      </form>
    </div>
  );
}
const BASIS_AR: Record<PriceRun["basis"], string> = { base: "أساسي", calendar: "التقويم", platform: "سعر المنصات", weekly: "أسبوعي", monthly: "شهري", manual: "يدوي", kept: "بنفس السعر", legacy: "سابق" };
/** The stay night by night, grouped by price (0030): 3 ليالٍ × 250 · التقويم */
function RunList({ runs, basis, channel }: { runs: PriceRun[]; basis?: string; channel?: string }) {
  const shown = runs.slice(0, 6);
  return (
    <div className="space-y-0.5 border-b border-ink-200 pb-1.5 text-xs text-ink-500" data-testid="quote-runs">
      {basis === "weekly" && <p className="font-medium text-brand-700">بالسعر الأسبوعي للنوع</p>}
      {basis === "monthly" && <p className="font-medium text-brand-700">بالسعر الشهري للنوع</p>}
      {channel === "platform" && basis === "daily" && <p className="font-medium text-brand-700">حجز منصة: سعر المنصات حيث وُجد</p>}
      {shown.map((r) => (
        <div key={r.from} className="flex justify-between gap-2">
          <span><span dir="ltr">{r.from.slice(8, 10)}/{r.from.slice(5, 7)}</span> · {r.nights} {r.nights === 1 ? "ليلة" : "ليالٍ"} × {formatCurrency(r.price / 100)}</span>
          <span className="text-ink-400">{BASIS_AR[r.basis]}</span>
        </div>
      ))}
      {runs.length > shown.length && <p className="text-ink-400">و{runs.length - shown.length} فترات أخرى</p>}
    </div>
  );
}
function Row({ l, v, strong }: { l: string; v: string; strong?: boolean }) { return <div className={`flex justify-between ${strong ? "font-semibold text-ink-800" : "text-ink-600"}`}><span>{l}</span><span dir="ltr">{v}</span></div>; }
