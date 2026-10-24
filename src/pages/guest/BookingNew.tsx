import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { ArrowLeft, CalendarDays, Users, BedDouble, ExternalLink, Minus, Plus, Moon } from "lucide-react";
import { supabase } from "../../lib/supabase";
import { guestApi, toArabicError } from "../../lib/api";
import { useBranch, priceTaxNote } from "../../lib/branch";
import { Card, ErrorBanner, Spinner, EmptyState } from "../../components/ui";
import { formatCurrency, todayISO, addDaysISO, formatHijri } from "../../lib/utils";

/**
 * «احجز الآن» — three choices and the answer appears by itself: arrival day, nights, people.
 * Only what can actually be booked is listed (a category needs stock on every night of the stay), with the
 * estimated total for the whole stay and one booking button. The booking itself is made on the approved platform.
 */
interface AvailabilityRow { category_id: string; category_name: string; base_price_halalas: number; base_capacity: number; max_capacity: number; available_to_show: number }
interface Source { id: string; name: string; booking_url: string | null }

function Stepper({ icon: Icon, label, value, min, max, onChange, unit }: { icon: typeof Users; label: string; value: number; min: number; max: number; onChange: (v: number) => void; unit: string }) {
  return (
    <div>
      <p className="label"><Icon className="ml-1 inline h-3.5 w-3.5" /> {label}</p>
      <div className="flex items-center justify-between rounded-xl border border-ink-200 bg-white px-2 py-1.5">
        <button type="button" onClick={() => onChange(Math.max(min, value - 1))} disabled={value <= min} className="rounded-lg p-2 text-ink-500 hover:bg-ink-50 disabled:opacity-30" aria-label={`إنقاص ${label}`}><Minus className="h-4 w-4" /></button>
        <span className="text-base font-semibold text-ink-800">{value} <span className="text-xs font-normal text-ink-400">{unit}</span></span>
        <button type="button" onClick={() => onChange(Math.min(max, value + 1))} disabled={value >= max} className="rounded-lg p-2 text-ink-500 hover:bg-ink-50 disabled:opacity-30" aria-label={`زيادة ${label}`}><Plus className="h-4 w-4" /></button>
      </div>
    </div>
  );
}

export default function BookingNew() {
  const { branchId, branch, branches, setBranchId } = useBranch();
  const taxNote = priceTaxNote(branch);
  const [checkIn, setCheckIn] = useState(todayISO());
  const [nights, setNights] = useState(1);
  const [guests, setGuests] = useState(2);
  const [loading, setLoading] = useState(false);
  const [results, setResults] = useState<AvailabilityRow[] | null>(null);
  const [sources, setSources] = useState<Source[]>([]);
  const [error, setError] = useState<string | null>(null);
  const checkOut = addDaysISO(checkIn, nights);

  useEffect(() => {
    supabase.from("booking_sources").select("id, name, booking_url").eq("is_active", true).not("booking_url", "is", null).then(({ data }) => setSources((data as Source[]) ?? []));
  }, []);

  // the answer follows every change (no search button)
  useEffect(() => {
    if (!branchId) return;
    let alive = true;
    setLoading(true); setError(null);
    const t = setTimeout(async () => {
      try {
        const perNight = await Promise.all(Array.from({ length: nights }, (_, i) => guestApi.availability(branchId, addDaysISO(checkIn, i))));
        const merged = (perNight[0] ?? []).map((row) => ({
          ...row,
          available_to_show: Math.min(...perNight.map((day) => day.find((d) => d.category_id === row.category_id)?.available_to_show ?? 0)),
        }));
        if (alive) setResults(merged.filter((r) => r.max_capacity >= guests && r.available_to_show > 0));
      } catch (e) {
        if (alive) { setError(toArabicError(e)); setResults([]); }
      }
      if (alive) setLoading(false);
    }, 250);
    return () => { alive = false; clearTimeout(t); };
  }, [branchId, checkIn, nights, guests]);

  const [main, ...others] = sources;

  return (
    <div className="mx-auto max-w-xl px-4 py-8 lg:py-12">
      <Link to="/reception" className="mb-4 inline-flex items-center gap-1.5 text-sm text-ink-400 hover:text-ink-600"><ArrowLeft className="h-4 w-4" /> رجوع</Link>
      <h1 className="mb-5 text-2xl font-bold text-ink-800">احجز إقامتك</h1>

      <Card className="mb-5 space-y-4">
        {branches.length > 1 && (
          <select value={branchId ?? ""} onChange={(e) => setBranchId(e.target.value)} className="input" aria-label="الفرع">
            {branches.map((b) => <option key={b.id} value={b.id}>{b.name_ar}</option>)}
          </select>
        )}
        <div>
          <label className="label" htmlFor="check-in"><CalendarDays className="ml-1 inline h-3.5 w-3.5" /> يوم الوصول</label>
          <input id="check-in" type="date" value={checkIn} min={todayISO()} onChange={(e) => e.target.value && setCheckIn(e.target.value)} className="input" />
          <p className="mt-1 text-[11px] text-ink-400">{formatHijri(checkIn)} · المغادرة <span dir="ltr">{checkOut}</span></p>
        </div>
        <div className="grid grid-cols-2 gap-3">
          <Stepper icon={Moon} label="الليالي" unit={nights === 1 ? "ليلة" : "ليالٍ"} value={nights} min={1} max={30} onChange={setNights} />
          <Stepper icon={Users} label="الأشخاص" unit={guests === 1 ? "شخص" : "أشخاص"} value={guests} min={1} max={12} onChange={setGuests} />
        </div>
      </Card>

      {error && <div className="mb-4"><ErrorBanner message={error} /></div>}
      {loading && !results && <Spinner className="mx-auto h-6 w-6" />}

      {results && results.length === 0 && !error && (
        <EmptyState icon={<BedDouble className="h-10 w-10" />} title="لا يوجد متاح لهذه التواريخ" description="غيّر يوم الوصول أو عدد الليالي." />
      )}

      <div className={loading ? "space-y-3 opacity-60 transition-opacity" : "space-y-3"}>
        {(results ?? []).map((r) => (
          <Card key={r.category_id} className="space-y-3">
            <div className="flex items-start justify-between gap-3">
              <div>
                <h3 className="text-base font-semibold text-ink-800">{r.category_name}</h3>
                <p className="mt-0.5 text-xs text-ink-400">حتى {r.max_capacity} أشخاص{r.available_to_show <= 2 ? ` · بقي ${r.available_to_show}` : ""}</p>
              </div>
              <div className="text-left">
                <p className="text-lg font-bold text-ink-800" dir="ltr">{formatCurrency((r.base_price_halalas * nights) / 100)}</p>
                <p className="text-[11px] text-ink-400">{nights} {nights === 1 ? "ليلة" : "ليالٍ"}{taxNote ? ` · ${taxNote}` : ""}</p>
              </div>
            </div>
            {main ? (
              <a href={main.booking_url!} target="_blank" rel="noopener noreferrer" className="btn-primary w-full">احجز الآن <ExternalLink className="h-4 w-4" /></a>
            ) : (
              <Link to="/reception" className="btn-primary w-full">اطلب الحجز من الاستقبال</Link>
            )}
            {others.length > 0 && (
              <p className="text-center text-xs text-ink-400">أو عبر {others.map((s, i) => <span key={s.id}>{i > 0 && "، "}<a href={s.booking_url!} target="_blank" rel="noopener noreferrer" className="text-brand-600 hover:underline">{s.name}</a></span>)}</p>
            )}
          </Card>
        ))}
      </div>

      <p className="mt-6 text-center text-xs text-ink-400">بعد الحجز تجده في <Link to="/booking/lookup" className="text-brand-600">«حجوزاتي»</Link> برقم جوالك.</p>
    </div>
  );
}
