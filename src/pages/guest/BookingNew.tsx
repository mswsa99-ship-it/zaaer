import { useEffect, useState, useCallback } from "react";
import { useNavigate, Link } from "react-router-dom";
import { ArrowLeft, Search, CalendarDays, Users, BedDouble, ExternalLink, CheckCircle2, Building2 } from "lucide-react";
import { supabase } from "../../lib/supabase";
import { guestApi, toArabicError } from "../../lib/api";
import { useBranch } from "../../lib/branch";
import { Card, ErrorBanner, Spinner, EmptyState } from "../../components/ui";
import { formatCurrency, todayISO, nightsBetween, formatHijri } from "../../lib/utils";

interface AvailabilityRow { category_id: string; category_name: string; base_price_halalas: number; base_capacity: number; max_capacity: number; available_to_show: number }
interface Source { id: string; name: string; booking_url: string | null }

function addDays(iso: string, n: number): string {
  const d = new Date(iso + "T00:00:00Z"); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10);
}

export default function BookingNew() {
  const navigate = useNavigate();
  const { branchId, branch, branches, setBranchId } = useBranch();
  const [checkIn, setCheckIn] = useState(todayISO());
  const [checkOut, setCheckOut] = useState(addDays(todayISO(), 1));
  const [guests, setGuests] = useState(2);
  const [loading, setLoading] = useState(false);
  const [results, setResults] = useState<AvailabilityRow[]>([]);
  const [sources, setSources] = useState<Source[]>([]);
  const [searched, setSearched] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    supabase.from("booking_sources").select("id, name, booking_url").eq("is_active", true).not("booking_url", "is", null).then(({ data }) => setSources((data as Source[]) ?? []));
  }, []);

  const search = useCallback(async () => {
    if (!branchId) return;
    setLoading(true); setError(null); setSearched(true);
    try {
      // Availability for every night of the stay; a category is offered only if it has stock on all nights.
      const nights = Math.max(1, nightsBetween(checkIn, checkOut));
      const perNight = await Promise.all(Array.from({ length: nights }, (_, i) => guestApi.availability(branchId, addDays(checkIn, i))));
      const first = perNight[0] ?? [];
      const merged = first.map((row) => ({
        ...row,
        available_to_show: Math.min(...perNight.map((day) => day.find((d) => d.category_id === row.category_id)?.available_to_show ?? 0)),
      }));
      setResults(merged.filter((r) => r.max_capacity >= guests));
    } catch (e) {
      setError(toArabicError(e)); setResults([]);
    }
    setLoading(false);
  }, [branchId, checkIn, checkOut, guests]);

  useEffect(() => { if (branchId) search(); }, [branchId]); // eslint-disable-line react-hooks/exhaustive-deps

  const nights = nightsBetween(checkIn, checkOut);

  return (
    <div className="mx-auto max-w-3xl px-4 py-8 lg:py-12">
      <Link to="/reception" className="mb-4 inline-flex items-center gap-1.5 text-sm text-ink-400 hover:text-ink-600"><ArrowLeft className="h-4 w-4" /> رجوع للمحادثة</Link>

      <div className="mb-6">
        <h1 className="text-2xl font-bold text-ink-800">استكشاف الغرف المتاحة</h1>
        <p className="mt-2 text-sm text-ink-500">اختر الفرع وتواريخ إقامتك وعدد الأشخاص. الحجز النهائي يتم عبر منصة الحجز المعتمدة، ثم تعود برقم الحجز لإكمال إجراءات الوصول.</p>
      </div>

      <Card className="mb-6">
        <div className="grid gap-4 sm:grid-cols-4">
          <div>
            <label className="label"><Building2 className="ml-1 inline h-3.5 w-3.5" /> الفرع</label>
            <select value={branchId ?? ""} onChange={(e) => setBranchId(e.target.value)} className="input">
              {branches.map((b) => <option key={b.id} value={b.id}>{b.name_ar}</option>)}
            </select>
          </div>
          <div>
            <label className="label"><CalendarDays className="ml-1 inline h-3.5 w-3.5" /> الوصول</label>
            <input type="date" value={checkIn} min={todayISO()} onChange={(e) => { setCheckIn(e.target.value); if (e.target.value >= checkOut) setCheckOut(addDays(e.target.value, 1)); }} className="input" />
            <p className="mt-1 text-[11px] text-ink-400">{formatHijri(checkIn)}</p>
          </div>
          <div>
            <label className="label"><CalendarDays className="ml-1 inline h-3.5 w-3.5" /> المغادرة</label>
            <input type="date" value={checkOut} min={addDays(checkIn, 1)} onChange={(e) => setCheckOut(e.target.value)} className="input" />
            <p className="mt-1 text-[11px] text-ink-400">{formatHijri(checkOut)}</p>
          </div>
          <div>
            <label className="label"><Users className="ml-1 inline h-3.5 w-3.5" /> الأشخاص</label>
            <input type="number" min={1} max={12} value={guests} onChange={(e) => setGuests(Math.max(1, Math.min(12, Number(e.target.value) || 1)))} className="input" />
          </div>
        </div>
        <div className="mt-4 flex items-center justify-between">
          <p className="text-xs text-ink-400">{nights} ليلة · الوصول {branch?.check_in_time?.slice(0, 5) ?? "16:00"} · المغادرة {branch?.check_out_time?.slice(0, 5) ?? "12:00"}</p>
          <button onClick={search} className="btn-primary" disabled={loading || nights < 1}>{loading ? <Spinner /> : <><Search className="h-4 w-4" /> بحث</>}</button>
        </div>
      </Card>

      {error && <div className="mb-4"><ErrorBanner message={error} /></div>}

      {searched && !loading && results.filter((r) => r.available_to_show > 0).length === 0 && !error && (
        <EmptyState icon={<BedDouble className="h-10 w-10" />} title="لا توجد وحدات متاحة لهذه التواريخ" description="جرّب تواريخ أخرى أو تواصل مع الاستقبال." />
      )}

      <div className="space-y-3">
        {results.filter((r) => r.available_to_show > 0).map((r) => (
          <Card key={r.category_id} className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <div className="flex items-center gap-2">
                <h3 className="text-base font-semibold text-ink-800">{r.category_name}</h3>
                <span className="badge bg-success-500/10 text-success-600"><CheckCircle2 className="h-3 w-3" /> {r.available_to_show} متاحة</span>
              </div>
              <p className="mt-1 text-xs text-ink-400">يبدأ من {formatCurrency(r.base_price_halalas / 100)} / ليلة · حتى {r.max_capacity} أشخاص · إجمالي تقديري {formatCurrency((r.base_price_halalas * Math.max(nights, 1)) / 100)}</p>
            </div>
            <div className="flex flex-wrap items-center gap-2">
              {sources.length === 0 && <span className="text-xs text-ink-400">لم تُضبط روابط الحجز بعد — تواصل مع الاستقبال</span>}
              {sources.map((s) => (
                <a key={s.id} href={s.booking_url!} target="_blank" rel="noopener noreferrer" className="btn-accent text-sm">
                  احجز عبر {s.name} <ExternalLink className="h-3.5 w-3.5" />
                </a>
              ))}
            </div>
          </Card>
        ))}
      </div>

      <div className="mt-8 rounded-xl bg-brand-50 p-4 text-center text-sm text-brand-700">
        بعد إتمام الحجز على المنصة، عُد إلى صفحة <button onClick={() => navigate("/booking/lookup")} className="font-medium underline">التحقق من الحجز</button> لإكمال إجراءات الوصول. النقر على رابط المنصة لا يُعد حجزًا.
      </div>
    </div>
  );
}
