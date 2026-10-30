/**
 * «تقويم الأسعار» (decision 33): unit types in rows, nights in columns, read right to left like Zaaer's calendar.
 * Each type shows how many of its units are free that night out of how many it has (red at zero), its price row, and —
 * when the type is priced by channel — the platforms' row. A night with no price in the calendar takes the type's base
 * price and shows it in grey. Past nights are for reading only. Prices are set on a cell, on selected cells, or on a
 * group (from–to × types × weekdays); nothing goes under the type's minimum; the owner or a manager edits, and every
 * edit is recorded with what it replaced. A price change never touches a stay already booked (its nights are fixed).
 */
import { useMemo, useState } from "react";
import { CalendarRange, ChevronRight, ChevronLeft, Layers, X } from "lucide-react";
import { useBranchQuery } from "../../lib/useBranchQuery";
import { ratesApi, toArabicError, type RateCalendar, type RateCategory } from "../../lib/api";
import { SectionTitle, LoadingScreen, Card, ErrorBanner, LoadErrorCard, EmptyState } from "../../components/ui";
import { Modal, Field, ActionForm, Submit, MoneyInput } from "../../components/forms";
import { BranchPicker } from "../../components/BranchPicker";
import { formatCurrency, todayISO, addDaysISO } from "../../lib/utils";

const WINDOW = 28;
const DAY_NAMES = ["الأحد", "الإثنين", "الثلاثاء", "الأربعاء", "الخميس", "الجمعة", "السبت"];
const dow = (night: string) => new Date(`${night}T00:00:00Z`).getUTCDay();
const sar = (h: number | null | undefined) => (h == null ? "—" : formatCurrency(h / 100));
/** A cell's price without the currency: 250 or 250.50 */
const short = (h: number) => (h % 100 === 0 ? String(h / 100) : (h / 100).toFixed(2));
type Row = "price" | "platform";
type Cell = { category_id: string; night: string; row: Row };
const keyOf = (c: Cell) => `${c.category_id}|${c.night}|${c.row}`;
const NO_DATA: RateCalendar = { today: todayISO(), from: todayISO(), to: todayISO(), categories: [] };

export default function AdminRates() {
  const [start, setStart] = useState(todayISO());
  const [tick, setTick] = useState(0);
  const [picked, setPicked] = useState<Map<string, Cell>>(new Map());
  const [anchor, setAnchor] = useState<Cell | null>(null);
  const [editing, setEditing] = useState(false);
  const [grouping, setGrouping] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);

  // G24 (decision 40): the active branch's calendar for a 4-week window
  const q = useBranchQuery<RateCalendar>((branchId) => ratesApi.calendar(branchId, start, addDaysISO(start, WINDOW - 1)), [start, tick], NO_DATA);
  const cal = q.data; const branchId = q.branchId;
  const nights = useMemo(() => cal.categories[0]?.days.map((d) => d.night) ?? Array.from({ length: WINDOW }, (_, i) => addDaysISO(start, i)), [cal, start]);

  if (q.loading && !cal.categories.length) return <LoadingScreen />;
  const isPast = (night: string) => night < cal.today;
  const reload = () => { setPicked(new Map()); setAnchor(null); setTick((t) => t + 1); };
  const toggle = (cell: Cell, range: boolean) => {
    if (isPast(cell.night)) return;
    setPicked((m) => {
      const n = new Map(m);
      if (range && anchor && anchor.category_id === cell.category_id && anchor.row === cell.row) {
        const [a, b] = anchor.night <= cell.night ? [anchor.night, cell.night] : [cell.night, anchor.night];
        for (const night of nights) if (night >= a && night <= b && !isPast(night)) { const c = { ...cell, night }; n.set(keyOf(c), c); }
      } else if (n.has(keyOf(cell))) n.delete(keyOf(cell));
      else n.set(keyOf(cell), cell);
      return n;
    });
    setAnchor(cell);
  };
  const selection = [...picked.values()];

  return (
    <div>
      <SectionTitle title="تقويم الأسعار" subtitle="الأنواع في صفوف والليالي في أعمدة. الرمادي سعر النوع الأساسي (لا سعر في التقويم). تعديل الأسعار لا يمس حجزًا قائمًا." action={<BranchPicker />} />
      {q.error && <div className="mb-4">{cal.categories.length ? <ErrorBanner message={q.error} /> : <LoadErrorCard message={q.error} onRetry={q.reload} />}</div>}
      {notice && <p className="mb-4 rounded-xl bg-success-500/10 px-3 py-2 text-sm text-success-600" role="status">{notice}</p>}

      <div className="mb-3 flex flex-wrap items-center gap-2">
        <button type="button" className="btn-outline px-2 text-sm" onClick={() => setStart(addDaysISO(start, -14))} aria-label="الأسبوعان السابقان"><ChevronRight className="h-4 w-4" /></button>
        <button type="button" className="btn-outline text-sm" onClick={() => setStart(todayISO())}>اليوم</button>
        <button type="button" className="btn-outline px-2 text-sm" onClick={() => setStart(addDaysISO(start, 14))} aria-label="الأسبوعان التاليان"><ChevronLeft className="h-4 w-4" /></button>
        <input type="date" className="input w-auto py-1.5 text-sm" dir="ltr" value={start} onChange={(e) => e.target.value && setStart(e.target.value)} aria-label="بداية العرض" />
        <div className="flex-1" />
        {selection.length > 0 && <>
          <span className="text-sm text-ink-600">{selection.length} خانة محددة</span>
          <button type="button" className="btn-ghost text-sm" onClick={() => setPicked(new Map())}><X className="h-4 w-4" /> إلغاء التحديد</button>
          <button type="button" className="btn-primary text-sm" onClick={() => setEditing(true)}>تعديل المحدد</button>
        </>}
        <button type="button" className="btn-outline text-sm" onClick={() => setGrouping(true)} disabled={!cal.categories.length}><Layers className="h-4 w-4" /> تعديل مجموعة</button>
      </div>

      {cal.categories.length === 0 ? (!q.error && <EmptyState icon={<CalendarRange className="h-10 w-10" />} title="لا توجد أنواع وحدات في هذا الفرع" description="أضف نوع وحدة أولًا من «أنواع الوحدات»." />) : (
        <Card className="overflow-x-auto p-0">
          <table className="border-separate border-spacing-0 text-xs" data-testid="rates-grid">
            <thead>
              <tr>
                <th className="sticky right-0 z-20 min-w-[8.5rem] border-b border-l border-ink-100 bg-white px-3 py-2 text-right font-semibold text-ink-700 sm:min-w-[13rem]">النوع</th>
                {nights.map((n) => (
                  <th key={n} className={`min-w-[4.5rem] border-b border-ink-100 px-1 py-1.5 text-center font-medium ${isPast(n) ? "bg-ink-50 text-ink-400" : dow(n) === 5 || dow(n) === 6 ? "bg-brand-50/60 text-brand-800" : "text-ink-600"}`}>
                    <div>{DAY_NAMES[dow(n)]}</div><div dir="ltr" className="text-[10px] opacity-80">{n.slice(8, 10)}/{n.slice(5, 7)}</div>
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {cal.categories.map((c) => <TypeRows key={c.id} c={c} past={isPast} picked={picked} onPick={toggle} />)}
            </tbody>
          </table>
        </Card>
      )}
      <p className="mt-3 text-[11px] text-ink-400">اضغط خانة لتحديدها، وShift مع الضغط لتحديد مدى في الصف نفسه. «المتوفر» للعرض: الوحدات الفعّالة ناقص الحجوزات المؤكدة والمقيمة تلك الليلة. الأسبوعي والشهري والحد الأدنى في «أنواع الوحدات»؛ التأمين في إعدادات الفرع.</p>

      <Modal open={editing} title={`تعديل ${selection.length} خانة`} onClose={() => setEditing(false)}>
        {editing && branchId && <EditSelection branchId={branchId} cells={selection} categories={cal.categories} onDone={(n) => { setEditing(false); setNotice(`حُدِّثت ${n} خانة.`); reload(); }} />}
      </Modal>
      <Modal open={grouping} title="تعديل مجموعة" onClose={() => setGrouping(false)} wide>
        {grouping && branchId && <GroupEdit branchId={branchId} today={cal.today} categories={cal.categories} onDone={(n) => { setGrouping(false); setNotice(`حُدِّثت ${n} خانة.`); reload(); }} />}
      </Modal>
    </div>
  );
}

function TypeRows({ c, past, picked, onPick }: { c: RateCategory; past: (night: string) => boolean; picked: Map<string, Cell>; onPick: (cell: Cell, range: boolean) => void }) {
  const rows: Row[] = c.price_mode === "by_channel" ? ["price", "platform"] : ["price"];
  const label = (r: Row) => (r === "platform" ? "سعر المنصات" : c.price_mode === "by_channel" ? "سعر النظام" : "السعر");
  return (
    <>
      <tr data-testid="rates-type" data-type={c.name}>
        <th scope="row" className="sticky right-0 z-10 border-l border-t border-ink-100 bg-white px-3 pb-1 pt-2 text-right align-top font-normal">
          <div className="font-semibold text-ink-800">{c.name}</div>
          <div className="mt-0.5 text-[10px] leading-4 text-ink-400">
            الأساسي {sar(c.base_price)}{c.min_nightly != null && <> · الأدنى {sar(c.min_nightly)}</>}
            {(c.weekly_price != null || c.monthly_price != null) && <div>{c.weekly_price != null && <>أسبوعي {sar(c.weekly_price)}</>}{c.weekly_price != null && c.monthly_price != null && " · "}{c.monthly_price != null && <>شهري {sar(c.monthly_price)}</>}</div>}
            <div>المتوفر من {c.units}</div>
          </div>
        </th>
        {c.days.map((d) => (
          <td key={d.night} className={`border-t border-ink-100 px-1 pt-2 text-center font-medium ${past(d.night) ? "bg-ink-50 text-ink-400" : d.available === 0 ? "text-danger-600" : "text-ink-500"}`} data-testid="rates-available">
            {d.available}/{c.units}
          </td>
        ))}
      </tr>
      {rows.map((r) => (
        <tr key={r}>
          <th scope="row" className="sticky right-0 z-10 border-l border-ink-100 bg-white px-3 py-1 text-right text-[11px] font-medium text-ink-500">{label(r)}</th>
          {c.days.map((d) => {
            const v = r === "price" ? d.price : d.platform_price;
            const shown = v ?? (r === "platform" ? d.price ?? c.base_price : c.base_price);
            const cell: Cell = { category_id: c.id, night: d.night, row: r };
            const on = picked.has(keyOf(cell)); const isPast = past(d.night);
            return (
              <td key={d.night} className="px-0.5 py-0.5">
                <button type="button" disabled={isPast} onClick={(e) => onPick(cell, e.shiftKey)}
                  aria-pressed={on} aria-label={`${c.name} ${label(r)} ${d.night}`} data-testid="rates-cell"
                  className={`w-full rounded-lg px-1 py-1.5 text-center tabular-nums transition ${isPast ? "cursor-default bg-ink-50 text-ink-400" : on ? "bg-brand-600 font-semibold text-white" : v != null ? "bg-white font-semibold text-ink-800 ring-1 ring-inset ring-ink-100 hover:ring-brand-300" : "bg-ink-50/60 text-ink-400 hover:bg-ink-100"}`}>
                  {short(shown)}
                </button>
              </td>
            );
          })}
        </tr>
      ))}
    </>
  );
}

function EditSelection({ branchId, cells, categories, onDone }: { branchId: string; cells: Cell[]; categories: RateCategory[]; onDone: (changed: number) => void }) {
  const hasPrice = cells.some((c) => c.row === "price"); const hasPlatform = cells.some((c) => c.row === "platform");
  const [price, setPrice] = useState<number | null>(null); const [platform, setPlatform] = useState<number | null>(null); const [reason, setReason] = useState("");
  const mins = [...new Set(cells.map((c) => c.category_id))].map((id) => categories.find((x) => x.id === id)).filter((x): x is RateCategory => !!x && x.min_nightly != null);
  const strip = (row: Row) => cells.filter((c) => c.row === row).map(({ category_id, night }) => ({ category_id, night }));
  async function save(clear: boolean) {
    let changed = 0;
    if (hasPrice) {
      if (!clear && (price == null || price <= 0)) throw new Error("VALIDATION: price");
      changed += (await ratesApi.set({ branch_id: branchId, cells: strip("price"), ...(clear ? { clear: "price" as const } : { price_halalas: price }), reason: reason.trim() || undefined })).changed;
    }
    if (hasPlatform) {
      if (!clear && (platform == null || platform <= 0)) throw new Error("VALIDATION: price");
      changed += (await ratesApi.set({ branch_id: branchId, cells: strip("platform"), ...(clear ? { clear: "platform" as const } : { platform_price_halalas: platform }), reason: reason.trim() || undefined })).changed;
    }
    onDone(changed);
  }
  return (
    <ActionForm onSubmit={() => save(false)}>
      <div className="space-y-3">
        {hasPrice && <Field label="السعر لليلة"><MoneyInput valueHalalas={price} onChange={setPrice} /></Field>}
        {hasPlatform && <Field label="سعر المنصات لليلة" hint="يُقترح عند إدخال حجز منصة، ولا يُرسل إلى المنصات."><MoneyInput valueHalalas={platform} onChange={setPlatform} /></Field>}
        {mins.length > 0 && <p className="text-xs text-ink-500">الحد الأدنى: {mins.map((m) => `${m.name} ${sar(m.min_nightly)}`).join(" · ")}</p>}
        <Field label="ملاحظة (اختياري)"><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="مثال: موسم الإجازة" /></Field>
      </div>
      <div className="mt-5 flex flex-wrap gap-2">
        <Submit label="حفظ" />
        <ClearButton onClear={() => save(true)} />
      </div>
    </ActionForm>
  );
}

/** «إرجاع للسعر الأساسي»: runs inside the same form so its errors show there too. */
function ClearButton({ onClear }: { onClear: () => Promise<void> }) {
  const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  return (
    <>
      <button type="button" className="btn-outline" disabled={busy} onClick={async () => { setBusy(true); setErr(null); try { await onClear(); } catch (e) { setErr(toArabicError(e)); } finally { setBusy(false); } }}>إرجاع للسعر الأساسي</button>
      {err && <span className="w-full text-sm text-danger-600" role="alert">{err}</span>}
    </>
  );
}

function GroupEdit({ branchId, today, categories, onDone }: { branchId: string; today: string; categories: RateCategory[]; onDone: (changed: number) => void }) {
  const [from, setFrom] = useState(today); const [to, setTo] = useState(addDaysISO(today, 30));
  const [types, setTypes] = useState<Set<string>>(new Set(categories.map((c) => c.id)));
  const [days, setDays] = useState<Set<number>>(new Set([0, 1, 2, 3, 4, 5, 6]));
  const [mode, setMode] = useState<"set" | "clear">("set");
  const [price, setPrice] = useState<number | null>(null); const [platform, setPlatform] = useState<number | null>(null); const [reason, setReason] = useState("");
  const chosen = categories.filter((c) => types.has(c.id)); const anyChannel = chosen.some((c) => c.price_mode === "by_channel");
  const flip = <T,>(s: Set<T>, v: T) => { const n = new Set(s); if (n.has(v)) n.delete(v); else n.add(v); return n; };
  return (
    <ActionForm onSubmit={async () => {
      if (!chosen.length) throw new Error("VALIDATION: categories");
      if (days.size === 0) throw new Error("VALIDATION: cells");   // no weekday chosen: nothing to change (an empty list would mean every day)
      if (mode === "set" && price == null && platform == null) throw new Error("VALIDATION: price");
      const r = await ratesApi.set({ branch_id: branchId, from, to, category_ids: chosen.map((c) => c.id), weekdays: days.size === 7 ? [] : [...days],
        ...(mode === "clear" ? { clear: true } : { price_halalas: price ?? undefined, platform_price_halalas: anyChannel ? platform ?? undefined : undefined }), reason: reason.trim() || undefined });
      onDone(r.changed);
    }}>
      <div className="grid gap-3 sm:grid-cols-2">
        <Field label="من"><input type="date" className="input" dir="ltr" min={today} value={from} onChange={(e) => setFrom(e.target.value)} /></Field>
        <Field label="إلى"><input type="date" className="input" dir="ltr" min={from} value={to} onChange={(e) => setTo(e.target.value)} /></Field>
      </div>
      <fieldset className="mt-3">
        <legend className="label">الأنواع</legend>
        <div className="flex flex-wrap gap-2">
          {categories.map((c) => (
            <label key={c.id} className={`flex cursor-pointer items-center gap-1.5 rounded-xl border px-3 py-1.5 text-sm ${types.has(c.id) ? "border-brand-500 bg-brand-50 text-brand-800" : "border-ink-100 text-ink-600"}`}>
              <input type="checkbox" className="h-4 w-4 accent-brand-600" checked={types.has(c.id)} onChange={() => setTypes(flip(types, c.id))} />{c.name}
            </label>
          ))}
        </div>
      </fieldset>
      <fieldset className="mt-3">
        <legend className="label">أيام الأسبوع</legend>
        <div className="flex flex-wrap gap-1.5">
          {DAY_NAMES.map((n, i) => (
            <button key={n} type="button" aria-pressed={days.has(i)} onClick={() => setDays(flip(days, i))}
              className={`rounded-lg border px-2.5 py-1 text-xs ${days.has(i) ? "border-brand-500 bg-brand-50 font-medium text-brand-800" : "border-ink-100 text-ink-500"}`}>{n}</button>
          ))}
        </div>
      </fieldset>
      <div className="mt-4 flex gap-4 text-sm">
        <label className="flex items-center gap-1.5"><input type="radio" name="mode" checked={mode === "set"} onChange={() => setMode("set")} /> تحديد سعر</label>
        <label className="flex items-center gap-1.5"><input type="radio" name="mode" checked={mode === "clear"} onChange={() => setMode("clear")} /> إرجاع للسعر الأساسي</label>
      </div>
      {mode === "set" && (
        <div className="mt-3 grid gap-3 sm:grid-cols-2">
          <Field label="السعر لليلة"><MoneyInput valueHalalas={price} onChange={setPrice} /></Field>
          {anyChannel && <Field label="سعر المنصات لليلة" hint="للأنواع المسعّرة «مختلف للمنصات» فقط."><MoneyInput valueHalalas={platform} onChange={setPlatform} /></Field>}
        </div>
      )}
      {chosen.some((c) => c.min_nightly != null) && <p className="mt-2 text-xs text-ink-500">الحد الأدنى: {chosen.filter((c) => c.min_nightly != null).map((c) => `${c.name} ${sar(c.min_nightly)}`).join(" · ")}</p>}
      <div className="mt-3"><Field label="ملاحظة (اختياري)"><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="مثال: أسعار رمضان" /></Field></div>
      <Submit label={mode === "clear" ? "إرجاع للأساسي" : "تطبيق"} />
    </ActionForm>
  );
}
