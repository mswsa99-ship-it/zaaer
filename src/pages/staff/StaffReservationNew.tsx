import { useEffect, useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import { ArrowLeft, CalendarPlus, Calculator, Plus, X, Users } from "lucide-react";
import { supabase } from "../../lib/supabase";
import { useAuth } from "../../lib/auth";
import { useBranch } from "../../lib/branch";
import { opsApi, toArabicError, type Quote } from "../../lib/api";
import { Card, SectionTitle, ErrorBanner, Spinner } from "../../components/ui";
import { Field, MoneyInput, Toggle } from "../../components/forms";
import { BranchPicker } from "../../components/BranchPicker";
import { formatCurrency, todayISO } from "../../lib/utils";
import { CLEANLINESS_LABELS } from "../../lib/types";

interface Cat { id: string; name_ar: string; base_capacity: number; max_capacity: number; base_price_halalas: number }
interface Src { id: string; name: string; kind: string; external_reference_required: boolean }

const addDays = (d: string, n: number) => { const x = new Date(d + "T00:00:00Z"); x.setUTCDate(x.getUTCDate() + n); return x.toISOString().slice(0, 10); };

export default function StaffReservationNew() {
  const navigate = useNavigate();
  const { profile } = useAuth();
  const { branchId } = useBranch();
  const canDiscount = profile?.role === "owner" || profile?.role === "manager";
  const [cats, setCats] = useState<Cat[]>([]); const [sources, setSources] = useState<Src[]>([]);
  const [f, setF] = useState({ check_in: todayISO(), check_out: addDays(todayISO(), 1), category_id: "", room_id: "", source_id: "", external_ref: "", guest_name: "", guest_phone: "", nationality: "", adults: 1, companions: 0, booking_type: "individual", company_name: "", visit_purpose: "", notes: "", confirm: true, override: false, nightly_rate: null as number | null, discount: 0, discount_reason: "" });
  // Zaaer parity (0011): companions by name, extra units in the same booking (one reservation per unit, created atomically)
  const [companionRows, setCompanionRows] = useState<Array<{ full_name: string; relationship: string }>>([]);
  const [extraUnits, setExtraUnits] = useState<Array<{ category_id: string; adults: number; companions: number }>>([]);
  const [times, setTimes] = useState({ arrival: "", departure: "" });
  const [quote, setQuote] = useState<Quote | null>(null);
  const [rooms, setRooms] = useState<Array<{ room_id: string; room_number: string; status: string; cleanliness: string; block_name: string | null }>>([]);
  const [error, setError] = useState<string | null>(null); const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!branchId) return;
    (async () => {
      const [c, s] = await Promise.all([
        supabase.from("room_categories").select("id, name_ar, base_capacity, max_capacity, base_price_halalas").eq("branch_id", branchId).is("archived_at", null).eq("is_active", true).order("sort_order"),
        supabase.from("booking_sources").select("id, name, kind, external_reference_required").eq("is_active", true).is("archived_at", null).order("name"),
      ]);
      setCats((c.data as Cat[]) ?? []); setSources((s.data as Src[]) ?? []);
      setF((p) => ({ ...p, category_id: p.category_id || (c.data?.[0] as Cat | undefined)?.id || "", source_id: p.source_id || ((s.data ?? []) as Src[]).find((x) => x.kind === "direct")?.id || (s.data?.[0] as Src | undefined)?.id || "" }));
    })();
  }, [branchId]);

  const nights = useMemo(() => Math.max(0, Math.round((new Date(f.check_out).getTime() - new Date(f.check_in).getTime()) / 86400000)), [f.check_in, f.check_out]);
  const source = sources.find((s) => s.id === f.source_id);
  const cat = cats.find((c) => c.id === f.category_id);

  // live quote + availability from the server (the browser never computes prices)
  useEffect(() => {
    if (!branchId || !f.category_id || nights <= 0) { setQuote(null); setRooms([]); return; }
    let alive = true;
    (async () => {
      try {
        const [q, r] = await Promise.all([
          opsApi.quote(branchId, f.category_id, f.check_in, f.check_out, f.override ? f.nightly_rate : null, canDiscount ? f.discount : 0),
          opsApi.availableRooms(branchId, f.check_in, f.check_out, f.category_id),
        ]);
        if (!alive) return; setQuote(q); setRooms(r); setError(null);
        if (f.room_id && !r.some((x) => x.room_id === f.room_id)) setF((p) => ({ ...p, room_id: "" }));
      } catch (e) { if (alive) { setQuote(null); setError(toArabicError(e)); } }
    })();
    return () => { alive = false; };
  }, [branchId, f.category_id, f.check_in, f.check_out, f.override, f.nightly_rate, f.discount, nights, canDiscount]); // eslint-disable-line react-hooks/exhaustive-deps

  async function submit() {
    setBusy(true); setError(null);
    try {
      const named = companionRows.filter((c) => c.full_name.trim()).map((c) => ({ full_name: c.full_name.trim(), relationship: c.relationship.trim() || null }));
      const main = { category_id: f.category_id, room_id: f.room_id || null, adults: f.adults, companions: Math.max(f.companions, named.length), companions_details: named, nightly_rate_halalas: f.override ? f.nightly_rate : null };
      const r = await opsApi.createReservation({ branch_id: branchId, ...main, check_in: f.check_in, check_out: f.check_out, source_id: f.source_id, external_ref: f.external_ref || null,
        arrival_time: times.arrival || null, departure_time: times.departure || null,
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
            <div className="grid gap-3 sm:grid-cols-2">
              <Field label="الاسم (مطلوب)"><input className="input" value={f.guest_name} onChange={(e) => setF({ ...f, guest_name: e.target.value })} /></Field>
              <Field label="الجوال" hint="يُستخدم لإعادة استخدام ملف الضيف دون دمج تلقائي بالاسم"><input className="input" dir="ltr" value={f.guest_phone} onChange={(e) => setF({ ...f, guest_phone: e.target.value })} placeholder="05xxxxxxxx" /></Field>
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
              <Field label={`المرجع الخارجي${source?.external_reference_required ? " (مطلوب)" : ""}`}><input className="input" dir="ltr" value={f.external_ref} onChange={(e) => setF({ ...f, external_ref: e.target.value })} /></Field>
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
              <Toggle checked={f.override} onChange={(v) => setF({ ...f, override: v, nightly_rate: v ? (cat?.base_price_halalas ?? 0) : null })} label="سعر ليلة مختلف عن الأساسي" />
              {f.override && <MoneyInput valueHalalas={f.nightly_rate} onChange={(h) => setF({ ...f, nightly_rate: h })} />}
              {canDiscount && <><Field label="خصم (إجمالي)"><MoneyInput valueHalalas={f.discount} onChange={(h) => setF({ ...f, discount: h ?? 0 })} /></Field>{f.discount > 0 && <Field label="سبب الخصم"><input className="input" value={f.discount_reason} onChange={(e) => setF({ ...f, discount_reason: e.target.value })} /></Field>}</>}
            </div>
            {quote && (
              <div className="mt-4 space-y-1.5 rounded-xl bg-ink-50 p-3 text-sm">
                <Row l={`الإيجار (${quote.nights} × ${formatCurrency(quote.nightly_rate / 100)})`} v={formatCurrency(quote.rent / 100)} />
                {quote.discount !== 0 && <Row l="الخصم" v={formatCurrency(quote.discount / 100)} />}
                <Row l={`الضريبة ${(quote.tax_rate_bp / 100).toFixed(0)}% ${quote.prices_include_tax ? "(مضمنة)" : ""}`} v={formatCurrency(quote.tax / 100)} />
                <div className="border-t border-ink-200 pt-1.5"><Row l="الإجمالي" v={formatCurrency(quote.total / 100)} strong /></div>
              </div>
            )}
          </Card>
          <Card>
            <Toggle checked={f.confirm} onChange={(v) => setF({ ...f, confirm: v })} label="تأكيد الحجز مباشرة" />
            <p className="mt-1 text-xs text-ink-400">بدون تأكيد يبقى الحجز «بانتظار التحقق» ولا يحجز الوحدة إلا بعد تخصيصها.</p>
            <button type="submit" disabled={busy || !quote || !f.guest_name.trim() || !capacityOk || nights <= 0} className="btn-primary mt-4 w-full">{busy ? <Spinner className="h-4 w-4" /> : <CalendarPlus className="h-4 w-4" />} {extraUnits.length > 0 ? `إنشاء ${extraUnits.length + 1} حجوزات` : "إنشاء الحجز"}</button>
          </Card>
        </div>
      </form>
    </div>
  );
}
function Row({ l, v, strong }: { l: string; v: string; strong?: boolean }) { return <div className={`flex justify-between ${strong ? "font-semibold text-ink-800" : "text-ink-600"}`}><span>{l}</span><span dir="ltr">{v}</span></div>; }
