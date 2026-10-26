/**
 * The reservations list (decision 14, 10.1): every filter of the reference (arrival, departure and creation dates,
 * individual or company, the company, unit type and number, rent type, source, a discount, status, payment and
 * identity states), a column picker, saved views kept on the server, and exports that state branch, period, filters
 * and scope (decision 43, X09) — all read through fn_reservation_list, which the server scopes and gates.
 */
import { useCallback, useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { BookCheck, Plus, Search, SlidersHorizontal, Columns3, Bookmark, CalendarRange, Star, Trash2, X } from "lucide-react";
import { opsApi, listsApi, fetchAllPages, toArabicError, type ReservationRow, type ReservationListFilters, type SavedView, type ReportFilterOptions } from "../../lib/api";
import { SectionTitle, ErrorBanner, Badge, DataState, Spinner } from "../../components/ui";
import { Modal, Field, ActionForm, Submit } from "../../components/forms";
import { ExportMenu } from "../../components/ExportMenu";
import { useBranchQuery } from "../../lib/useBranchQuery";
import { useBranch } from "../../lib/branch";
import { useAuth } from "../../lib/auth";
import { BranchPicker } from "../../components/BranchPicker";
import { RESERVATION_STATUS_LABELS, RESERVATION_STATUS_COLORS, PAYMENT_STATUS_LABELS, ACCESS_STATUS_LABELS, GUEST_VERIFICATION_LABELS, type ReservationStatus } from "../../lib/types";
import { formatCurrency, formatDateTime, todayISO } from "../../lib/utils";
import { money, type ExportScope, type ExportStatement } from "../../lib/exports";
import type { XlsxCell } from "../../lib/xlsx";
import { supabase } from "../../lib/supabase";

const PAGE = 25;
const NO_ROWS: { total: number; rows: ReservationRow[] } = { total: 0, rows: [] };
const sar = (h: number | null | undefined) => (h == null ? "—" : formatCurrency(h / 100));
const BOOKING_TYPE_LABELS: Record<string, string> = { individual: "فرد", company: "شركة" };
const PRICE_BASIS_LABELS: Record<string, string> = { daily: "يومي", weekly: "أسبوعي", monthly: "شهري", manual: "سعر يدوي" };
const IDENTITY_LABELS: Record<string, string> = { ...GUEST_VERIFICATION_LABELS, pending_supervisor: "بانتظار المشرف", verified: "مطابقة" };
const SORT_LABELS: Record<NonNullable<ReservationListFilters["sort"]> | "default", string> = { default: "الوصول (الأحدث أولًا)", check_in_asc: "الوصول (الأقدم أولًا)", check_out: "المغادرة", created: "تاريخ الإنشاء", ref: "رقم الحجز" };
const COLUMNS_KEY = "zaaer.reservations.columns.v1";

type Col = { key: string; label: string; money?: boolean; cell: (r: ReservationRow) => React.ReactNode; out: (r: ReservationRow) => XlsxCell; width?: number };
const status = (s: string) => RESERVATION_STATUS_LABELS[s as ReservationStatus] ?? s;
const day = (iso: string | null | undefined) => (iso ? iso.slice(0, 10) : "");
const COLUMNS: Col[] = [
  { key: "internal_ref", label: "رقم الحجز", cell: (r) => <><Link to={`/staff/reservations/${r.id}`} className="font-mono text-xs hover:underline">{r.internal_ref}</Link>{r.external_ref && <div className="text-[10px] text-ink-400">{r.source_name} · <span dir="ltr">{r.external_ref}</span></div>}</>, out: (r) => r.internal_ref, width: 14 },
  { key: "external_ref", label: "رقم المنصة", cell: (r) => <span className="font-mono text-xs" dir="ltr">{r.external_ref ?? "—"}</span>, out: (r) => r.external_ref ?? "" },
  { key: "guest_name", label: "الضيف", cell: (r) => <>{r.guest_name ?? "—"}{r.ban && <span className="mr-1 inline-flex items-center rounded-md bg-danger-500/10 px-1.5 py-0.5 text-[10px] font-medium text-danger-600" data-testid="row-ban">محظور</span>}{r.hold && <span className="mr-1 inline-flex items-center rounded-md bg-danger-500/10 px-1.5 py-0.5 text-[10px] font-medium text-danger-600">حظر على الحجز</span>}{r.rating != null && r.rating <= 2 && <span className="mr-1 inline-flex items-center rounded-md bg-warning-500/10 px-1.5 py-0.5 text-[10px] font-medium text-warning-600">تقييم {r.rating}/5</span>}</>, out: (r) => r.guest_name ?? "", width: 24 },
  { key: "booking_type", label: "فرد / شركة", cell: (r) => <>{BOOKING_TYPE_LABELS[r.booking_type ?? ""] ?? r.booking_type ?? "—"}{r.company_name && <div className="text-[10px] text-ink-400">{r.company_name}</div>}</>, out: (r) => `${BOOKING_TYPE_LABELS[r.booking_type ?? ""] ?? r.booking_type ?? ""}${r.company_name ? ` · ${r.company_name}` : ""}` },
  { key: "room_number", label: "الوحدة", cell: (r) => <>{r.room_number ?? <span className="text-ink-300">—</span>}<div className="text-[10px] text-ink-400">{r.category_name}</div></>, out: (r) => r.room_number ?? "" },
  { key: "category_name", label: "نوع الوحدة", cell: (r) => r.category_name ?? "—", out: (r) => r.category_name ?? "" },
  { key: "status", label: "الحالة", cell: (r) => <Badge className={RESERVATION_STATUS_COLORS[r.status as ReservationStatus] ?? "bg-ink-100 text-ink-600"}>{status(r.status)}</Badge>, out: (r) => status(r.status) },
  { key: "check_in", label: "الوصول", cell: (r) => <span dir="ltr">{r.check_in}</span>, out: (r) => r.check_in },
  { key: "check_out", label: "المغادرة", cell: (r) => <span dir="ltr">{r.check_out}</span>, out: (r) => r.check_out },
  { key: "nights", label: "الليالي", cell: (r) => r.nights, out: (r) => r.nights },
  { key: "actual_check_in", label: "الوصول الفعلي", cell: (r) => r.actual_check_in ? formatDateTime(r.actual_check_in) : "—", out: (r) => r.actual_check_in ? formatDateTime(r.actual_check_in) : "" },
  { key: "actual_check_out", label: "المغادرة الفعلية", cell: (r) => r.actual_check_out ? formatDateTime(r.actual_check_out) : "—", out: (r) => r.actual_check_out ? formatDateTime(r.actual_check_out) : "" },
  { key: "guests", label: "الأشخاص", cell: (r) => `${r.adults ?? "—"} + ${r.companions ?? 0}`, out: (r) => `${r.adults ?? ""} + ${r.companions ?? 0}` },
  { key: "source_name", label: "المصدر", cell: (r) => r.source_name ?? "—", out: (r) => r.source_name ?? "" },
  { key: "platform", label: "المنصة", cell: (r) => r.platform_booked_on ? <span className="text-xs">{r.platform_booked_on}{r.platform_collects != null && <span className="text-ink-400"> · {r.platform_collects ? "تقبض المنصة" : "تقبض المنشأة"}</span>}</span> : "—", out: (r) => r.platform_booked_on ? `${r.platform_booked_on}${r.platform_collects != null ? (r.platform_collects ? " · تقبض المنصة" : " · تقبض المنشأة") : ""}` : "" },
  { key: "price_basis", label: "نوع الإيجار", cell: (r) => PRICE_BASIS_LABELS[r.price_basis ?? ""] ?? r.price_basis ?? "—", out: (r) => PRICE_BASIS_LABELS[r.price_basis ?? ""] ?? r.price_basis ?? "" },
  { key: "nightly_rate_halalas", label: "سعر الليلة", money: true, cell: (r) => <span dir="ltr">{sar(r.nightly_rate_halalas)}</span>, out: (r) => money(r.nightly_rate_halalas) },
  { key: "discount_halalas", label: "الخصم", money: true, cell: (r) => <span dir="ltr">{sar(r.discount_halalas)}</span>, out: (r) => money(r.discount_halalas) },
  { key: "total_halalas", label: "الإجمالي", money: true, cell: (r) => <span dir="ltr">{sar(r.total_halalas)}</span>, out: (r) => money(r.total_halalas) },
  { key: "paid_halalas", label: "المحصّل", money: true, cell: (r) => <span dir="ltr">{sar(r.paid_halalas)}</span>, out: (r) => money(r.paid_halalas) },
  { key: "balance_due_halalas", label: "المتبقي", money: true, cell: (r) => <span dir="ltr" className={r.balance_due_halalas > 0 ? "font-medium text-warning-600" : "text-success-600"}>{sar(r.balance_due_halalas)}</span>, out: (r) => money(r.balance_due_halalas) },
  { key: "deposit_balance_halalas", label: "رصيد التأمين", money: true, cell: (r) => <span dir="ltr">{sar(r.deposit_balance_halalas)}</span>, out: (r) => money(r.deposit_balance_halalas) },
  { key: "payment_status", label: "حالة الدفع", cell: (r) => PAYMENT_STATUS_LABELS[r.payment_status as keyof typeof PAYMENT_STATUS_LABELS] ?? r.payment_status, out: (r) => PAYMENT_STATUS_LABELS[r.payment_status as keyof typeof PAYMENT_STATUS_LABELS] ?? r.payment_status },
  { key: "identity_status", label: "الهوية", cell: (r) => IDENTITY_LABELS[r.identity_status] ?? r.identity_status, out: (r) => IDENTITY_LABELS[r.identity_status] ?? r.identity_status },
  { key: "access_status", label: "الوصول للوحدة", cell: (r) => ACCESS_STATUS_LABELS[r.access_status as keyof typeof ACCESS_STATUS_LABELS] ?? r.access_status, out: (r) => ACCESS_STATUS_LABELS[r.access_status as keyof typeof ACCESS_STATUS_LABELS] ?? r.access_status },
  { key: "group_ref", label: "المجموعة", cell: (r) => r.group_ref ? <span className="font-mono text-xs">{r.group_ref}</span> : "—", out: (r) => r.group_ref ?? "" },
  { key: "cancel", label: "الإلغاء", cell: (r) => r.cancelled_at ? <span className="text-xs">{day(r.cancelled_at)}{r.cancel_reference && <span className="font-mono text-ink-400"> · {r.cancel_reference}</span>}</span> : "—", out: (r) => r.cancelled_at ? `${day(r.cancelled_at)}${r.cancel_reference ? ` · ${r.cancel_reference}` : ""}` : "" },
  { key: "created_at", label: "أُنشئ", cell: (r) => <span className="text-xs">{formatDateTime(r.created_at)}{r.created_by_name && <span className="text-ink-400"> · {r.created_by_name}</span>}</span>, out: (r) => `${formatDateTime(r.created_at)}${r.created_by_name ? ` · ${r.created_by_name}` : ""}` },
];
const DEFAULT_COLUMNS = ["internal_ref", "guest_name", "room_number", "status", "check_in", "check_out", "total_halalas", "balance_due_halalas", "deposit_balance_halalas"];

type Filters = ReservationListFilters;
const DEFAULT_FILTERS: Filters = { open_only: true };
const isOn = (v: unknown) => v === true || v === "true";

/** The active filters in the reader's words, for the file's statement (decision 43) */
export function filterWords(f: Filters, opts?: ReportFilterOptions | null): string[] {
  const out: string[] = [];
  const range = (label: string, a?: string, b?: string) => { if (a || b) out.push(`${label}: ${a && b ? `${a} → ${b}` : a ? `من ${a}` : `حتى ${b}`}`); };
  if (f.status) out.push(`الحالة: ${String(f.status).split(",").map(status).join("، ")}`);
  if (isOn(f.open_only)) out.push("المفتوحة فقط");
  if (isOn(f.has_balance)) out.push("عليها متبقٍ");
  if (isOn(f.has_discount)) out.push("فيها خصم");
  range("الوصول", f.check_in_from, f.check_in_to); range("المغادرة", f.check_out_from, f.check_out_to); range("تاريخ الإنشاء", f.created_from, f.created_to);
  if (f.stay_on) out.push(`مقيم في: ${f.stay_on}`);
  if (f.source_id) out.push(`المصدر: ${opts?.sources?.find((s) => s.id === f.source_id)?.name ?? f.source_id}`);
  if (f.category_id) out.push(`نوع الوحدة: ${opts?.categories?.find((c) => c.id === f.category_id)?.name ?? f.category_id}`);
  if (f.room_number) out.push(`الوحدة: ${f.room_number}`);
  if (f.booking_type) out.push(`النوع: ${BOOKING_TYPE_LABELS[f.booking_type] ?? f.booking_type}`);
  if (f.company) out.push(`الشركة: ${f.company}`);
  if (f.price_basis) out.push(`نوع الإيجار: ${PRICE_BASIS_LABELS[f.price_basis] ?? f.price_basis}`);
  if (f.payment_status) out.push(`الدفع: ${PAYMENT_STATUS_LABELS[f.payment_status as keyof typeof PAYMENT_STATUS_LABELS] ?? f.payment_status}`);
  if (f.identity_status) out.push(`الهوية: ${IDENTITY_LABELS[f.identity_status] ?? f.identity_status}`);
  if (f.access_status) out.push(`الوصول للوحدة: ${ACCESS_STATUS_LABELS[f.access_status as keyof typeof ACCESS_STATUS_LABELS] ?? f.access_status}`);
  if (f.group_ref) out.push(`المجموعة: ${f.group_ref}`);
  if (f.platform_collects !== undefined && f.platform_collects !== "") out.push(isOn(f.platform_collects) ? "تقبض المنصة" : "تقبض المنشأة");
  if (f.q) out.push(`بحث: ${f.q}`);
  if (f.sort && f.sort in SORT_LABELS) out.push(`الترتيب: ${SORT_LABELS[f.sort]}`);
  return out;
}

export default function StaffReservations() {
  const { profile, permissions } = useAuth();
  const { branch } = useBranch();
  const moneyRole = permissions.seesMoney;
  const [filters, setFilters] = useState<Filters>(DEFAULT_FILTERS);
  const [page, setPage] = useState(0);
  const [advanced, setAdvanced] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [columns, setColumns] = useState<string[]>(() => { try { const s = localStorage.getItem(COLUMNS_KEY); const a = s ? (JSON.parse(s) as string[]) : null; return Array.isArray(a) && a.length ? a : DEFAULT_COLUMNS; } catch { return DEFAULT_COLUMNS; } });
  const [pickerOpen, setPickerOpen] = useState(false);
  const [views, setViews] = useState<SavedView[]>([]);
  const [viewId, setViewId] = useState<string>("");
  const [viewsError, setViewsError] = useState<string | null>(null);
  const [saveOpen, setSaveOpen] = useState<null | { name: string; asDefault: boolean; update: boolean }>(null);
  const [viewsLoaded, setViewsLoaded] = useState(false);

  useEffect(() => { try { localStorage.setItem(COLUMNS_KEY, JSON.stringify(columns)); } catch { /* per-browser convenience only */ } }, [columns]);

  const visibleColumns = useMemo(() => COLUMNS.filter((c) => columns.includes(c.key) && (moneyRole || !c.money)), [columns, moneyRole]);

  const list = useBranchQuery((b) => opsApi.list(b, filters, PAGE, page * PAGE), [filters, page], NO_ROWS);
  const options = useBranchQuery<ReportFilterOptions | null>(async (b) => { const o = await listsApi.filterOptions(b); return o && "sources" in o ? (o as ReportFilterOptions) : null; }, [], null);
  const { data, branchId, reload } = list;
  useEffect(() => {
    const ch = supabase.channel("res-list").on("postgres_changes", { event: "*", schema: "public", table: "reservations" }, () => reload()).subscribe();
    return () => { supabase.removeChannel(ch); };
  }, [reload]);

  const loadViews = useCallback(async () => {
    try { const v = await listsApi.savedViews("reservations"); setViews(v); setViewsError(null); return v; } catch (e) { setViewsError(toArabicError(e)); return [] as SavedView[]; }
  }, []);
  useEffect(() => {
    let alive = true;
    loadViews().then((v) => { if (!alive || viewsLoaded) return; setViewsLoaded(true); const d = v.find((x) => x.is_default); if (d) applyView(d); });
    return () => { alive = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [loadViews]);

  function applyView(v: SavedView) { setViewId(v.id); setFilters((v.filters ?? {}) as Filters); if (v.columns?.length) setColumns(v.columns); setPage(0); }
  const set = (k: keyof Filters, v: string | boolean) => { setPage(0); setViewId(""); setFilters((f) => { const n: Record<string, unknown> = { ...f, [k]: v }; if (v === "" || v === false) delete n[k]; return n as Filters; }); };
  const clearFilters = () => { setFilters({}); setPage(0); setViewId(""); };
  const pages = Math.max(1, Math.ceil(data.total / PAGE));
  const words = filterWords(filters, options.data);
  const activeCount = Object.keys(filters).filter((k) => k !== "sort").length;

  const statement = (scope: ExportScope): ExportStatement => ({
    title: "الحجوزات", branch: branch?.name_ar ?? null,
    period: filters.check_in_from || filters.check_in_to ? { from: filters.check_in_from, to: filters.check_in_to } : null,
    filters: words, scope, generatedAt: formatDateTime(new Date().toISOString()), by: profile?.full_name ?? null,
  });
  const table = async (scope: ExportScope) => {
    const cols = visibleColumns;
    const rows = scope.kind === "page" ? data.rows : (await fetchAllPages((limit, offset) => opsApi.list(branchId!, filters, limit, offset), 500)).rows;
    return { columns: cols.map((c) => c.label), rows: rows.map((r) => cols.map((c) => c.out(r))), widths: cols.map((c) => c.width ?? 14) };
  };

  async function saveView() {
    if (!saveOpen) return;
    const name = saveOpen.name.trim(); if (!name) throw new Error("VALIDATION: name");
    const current = views.find((v) => v.id === viewId);
    const r = await listsApi.saveView({ id: saveOpen.update && current ? current.id : undefined, screen: "reservations", name, filters: filters as Record<string, unknown>, columns, is_default: saveOpen.asDefault });
    setSaveOpen(null); const v = await loadViews(); setViewId(r.id); void v;
  }
  async function removeView(id: string) {
    try { await listsApi.removeView(id); if (viewId === id) setViewId(""); await loadViews(); } catch (e) { setError(toArabicError(e)); }
  }

  const sel = (k: keyof Filters, label: string, entries: Array<[string, string]>, all = "الكل") => (
    <label className="flex items-center gap-1.5 text-xs text-ink-600">{label}
      <select className="input w-auto py-1 text-xs" value={String(filters[k] ?? "")} onChange={(e) => set(k, e.target.value)} aria-label={label}><option value="">{all}</option>{entries.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select>
    </label>
  );
  const dateRange = (label: string, from: keyof Filters, to: keyof Filters) => (
    <div className="flex items-center gap-1.5 text-xs text-ink-600"><span className="w-20">{label}</span>
      <input type="date" className="input w-auto py-1 text-xs" dir="ltr" aria-label={`${label} من`} value={String(filters[from] ?? "")} onChange={(e) => set(from, e.target.value)} />
      <span>→</span>
      <input type="date" className="input w-auto py-1 text-xs" dir="ltr" aria-label={`${label} إلى`} value={String(filters[to] ?? "")} onChange={(e) => set(to, e.target.value)} />
    </div>
  );

  return (
    <div>
      <SectionTitle title="الحجوزات" subtitle={`${data.total} حجز مطابق${words.length ? ` · ${words.join(" · ")}` : ""}`} action={
        <div className="flex flex-wrap items-center gap-2">
          <BranchPicker />
          <Link to="/staff/rooms?view=calendar" className="btn-outline text-sm" data-testid="open-calendar"><CalendarRange className="h-4 w-4" /> تقويم الحجوزات</Link>
          <ExportMenu source={{ statement, table, pageCount: data.rows.length, total: data.total }} disabled={!branchId} />
          <Link to="/staff/reservations/new" className="btn-primary text-sm"><Plus className="h-4 w-4" /> حجز جديد</Link>
        </div>} />
      {error && <div className="mb-4"><ErrorBanner message={error} /></div>}

      <div className="card mb-4 p-3">
        <div className="flex flex-wrap items-center gap-2">
          <div className="relative"><Search className="pointer-events-none absolute right-3 top-2.5 h-4 w-4 text-ink-400" /><input className="input w-56 pr-9" placeholder="مرجع / ضيف / جوال / شركة" value={String(filters.q ?? "")} onChange={(e) => set("q", e.target.value)} aria-label="بحث" /></div>
          <select className="input w-auto" value={String(filters.status ?? "")} onChange={(e) => { set("status", e.target.value); if (e.target.value) set("open_only", false); }} aria-label="الحالة"><option value="">كل الحالات</option>{Object.entries(RESERVATION_STATUS_LABELS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select>
          <label className="flex items-center gap-1.5 text-sm text-ink-600"><input type="checkbox" checked={isOn(filters.open_only)} onChange={(e) => set("open_only", e.target.checked)} /> المفتوحة فقط</label>
          {moneyRole && <label className="flex items-center gap-1.5 text-sm text-ink-600"><input type="checkbox" checked={isOn(filters.has_balance)} onChange={(e) => set("has_balance", e.target.checked)} /> عليها متبقٍ</label>}
          <button type="button" onClick={() => setAdvanced(!advanced)} className={`btn-ghost text-sm ${advanced ? "text-brand-700" : ""}`} data-testid="toggle-advanced" aria-expanded={advanced}><SlidersHorizontal className="h-4 w-4" /> مرشحات زائر{activeCount ? ` (${activeCount})` : ""}</button>
          <div className="relative">
            <button type="button" onClick={() => setPickerOpen(!pickerOpen)} className="btn-ghost text-sm" data-testid="column-picker" aria-expanded={pickerOpen}><Columns3 className="h-4 w-4" /> الأعمدة ({visibleColumns.length})</button>
            {pickerOpen && (
              <div className="absolute right-0 z-20 mt-1 grid w-72 grid-cols-2 gap-1 rounded-xl border border-ink-100 bg-white p-2 text-xs shadow-lg" data-testid="column-picker-menu">
                {COLUMNS.filter((c) => moneyRole || !c.money).map((c) => (
                  <label key={c.key} className="flex items-center gap-1.5 rounded-lg px-2 py-1 hover:bg-ink-50"><input type="checkbox" checked={columns.includes(c.key)} onChange={(e) => setColumns((cs) => e.target.checked ? [...cs, c.key] : cs.length > 1 ? cs.filter((x) => x !== c.key) : cs)} /> {c.label}</label>
                ))}
                <div className="col-span-2 mt-1 flex justify-between border-t border-ink-50 pt-1"><button type="button" className="text-ink-500 hover:underline" onClick={() => setColumns(DEFAULT_COLUMNS)}>الأعمدة الافتراضية</button><button type="button" className="text-brand-600 hover:underline" onClick={() => setPickerOpen(false)}>إغلاق</button></div>
              </div>
            )}
          </div>
          <div className="flex items-center gap-1" data-testid="saved-views">
            <Bookmark className="h-4 w-4 text-ink-400" />
            <select className="input w-auto py-1 text-xs" value={viewId} onChange={(e) => { const v = views.find((x) => x.id === e.target.value); if (v) applyView(v); else setViewId(""); }} aria-label="العروض المحفوظة">
              <option value="">— عرض محفوظ —</option>
              {views.map((v) => <option key={v.id} value={v.id}>{v.is_default ? "★ " : ""}{v.name}</option>)}
            </select>
            <button type="button" className="btn-ghost px-2 py-1 text-xs" onClick={() => setSaveOpen({ name: views.find((v) => v.id === viewId)?.name ?? "", asDefault: views.find((v) => v.id === viewId)?.is_default ?? false, update: !!viewId })} data-testid="save-view">حفظ العرض</button>
            {viewId && <button type="button" className="btn-ghost px-2 py-1 text-xs text-danger-600" onClick={() => removeView(viewId)} aria-label="حذف العرض المحفوظ" title="إزالة العرض (يُؤرشف)"><Trash2 className="h-3.5 w-3.5" /></button>}
          </div>
          {activeCount > 0 && <button type="button" onClick={clearFilters} className="btn-ghost text-xs text-ink-500" data-testid="clear-filters"><X className="h-3.5 w-3.5" /> مسح المرشحات</button>}
        </div>
        {viewsError && <p className="mt-2 text-xs text-danger-600">{viewsError}</p>}
        {advanced && (
          <div className="mt-3 grid gap-2 border-t border-ink-50 pt-3 md:grid-cols-2 xl:grid-cols-3" data-testid="advanced-filters">
            {dateRange("الوصول", "check_in_from", "check_in_to")}
            {dateRange("المغادرة", "check_out_from", "check_out_to")}
            {dateRange("تاريخ الإنشاء", "created_from", "created_to")}
            <label className="flex items-center gap-1.5 text-xs text-ink-600"><span className="w-20">مقيم في يوم</span><input type="date" className="input w-auto py-1 text-xs" dir="ltr" value={String(filters.stay_on ?? "")} onChange={(e) => set("stay_on", e.target.value)} aria-label="مقيم في يوم" /><button type="button" className="text-brand-600 hover:underline" onClick={() => set("stay_on", todayISO())}>اليوم</button></label>
            {sel("source_id", "المصدر", (options.data?.sources ?? []).map((s) => [s.id, s.name]))}
            {sel("category_id", "نوع الوحدة", (options.data?.categories ?? []).map((c) => [c.id, c.name]))}
            <label className="flex items-center gap-1.5 text-xs text-ink-600">رقم الوحدة <input className="input w-24 py-1 text-xs" value={String(filters.room_number ?? "")} onChange={(e) => set("room_number", e.target.value)} aria-label="رقم الوحدة" /></label>
            {sel("booking_type", "فرد / شركة", Object.entries(BOOKING_TYPE_LABELS))}
            <label className="flex items-center gap-1.5 text-xs text-ink-600">الشركة <input className="input w-36 py-1 text-xs" value={String(filters.company ?? "")} onChange={(e) => set("company", e.target.value)} aria-label="الشركة" /></label>
            {sel("price_basis", "نوع الإيجار", Object.entries(PRICE_BASIS_LABELS))}
            {sel("payment_status", "حالة الدفع", Object.entries(PAYMENT_STATUS_LABELS))}
            {sel("identity_status", "الهوية", Object.entries(IDENTITY_LABELS))}
            {sel("access_status", "الوصول للوحدة", Object.entries(ACCESS_STATUS_LABELS))}
            <label className="flex items-center gap-1.5 text-xs text-ink-600">المجموعة <input className="input w-28 py-1 text-xs font-mono" value={String(filters.group_ref ?? "")} onChange={(e) => set("group_ref", e.target.value)} aria-label="المجموعة" /></label>
            {sel("platform_collects", "من يقبض", [["true", "المنصة"], ["false", "المنشأة"]])}
            <label className="flex items-center gap-1.5 text-xs text-ink-600"><input type="checkbox" checked={isOn(filters.has_discount)} onChange={(e) => set("has_discount", e.target.checked)} /> فيها خصم</label>
            {sel("sort", "الترتيب", Object.entries(SORT_LABELS).filter(([k]) => k !== "default") as Array<[string, string]>, SORT_LABELS.default)}
          </div>
        )}
      </div>

      <DataState loading={list.loading} error={list.error} empty={data.rows.length === 0} onRetry={reload} emptyIcon={<BookCheck className="h-10 w-10" />} emptyTitle="لا توجد حجوزات مطابقة" emptyDescription={activeCount ? "جرّب تخفيف المرشحات." : undefined}>
        <div className="card overflow-x-auto">
          <table className="w-full text-sm" data-testid="reservations-table">
            <thead className="bg-ink-50 text-xs text-ink-500"><tr>{visibleColumns.map((c) => <th key={c.key} className="whitespace-nowrap px-3 py-2 text-right font-medium">{c.label}</th>)}<th /></tr></thead>
            <tbody>
              {data.rows.map((r) => (
                <tr key={r.id} className="border-t border-ink-50 hover:bg-ink-50/60" data-testid="reservation-row">
                  {visibleColumns.map((c) => <td key={c.key} className="whitespace-nowrap px-3 py-2 text-ink-700" dir={c.money ? "ltr" : undefined}>{c.cell(r)}</td>)}
                  <td className="px-3 py-2"><Link to={`/staff/reservations/${r.id}`} className="btn-outline px-2 py-1 text-xs">فتح</Link></td>
                </tr>
              ))}
            </tbody>
          </table>
          <div className="flex items-center justify-between border-t border-ink-50 px-3 py-2 text-xs text-ink-500">
            <span>صفحة {page + 1} من {pages} · {data.total} حجز{list.refreshing && <Spinner className="mr-2 inline h-3 w-3" />}</span>
            <div className="flex gap-2"><button disabled={page === 0} onClick={() => setPage(page - 1)} className="btn-ghost px-2 py-1 text-xs">السابق</button><button disabled={page + 1 >= pages} onClick={() => setPage(page + 1)} className="btn-ghost px-2 py-1 text-xs">التالي</button></div>
          </div>
        </div>
      </DataState>

      <Modal open={!!saveOpen} title="حفظ العرض" onClose={() => setSaveOpen(null)}>
        {saveOpen && (
          <ActionForm onSubmit={saveView}>
            <div className="space-y-3">
              <Field label="اسم العرض" hint="المرشحات والأعمدة الحالية تُحفظ باسمك على الخادم؛ لا يراها غيرك."><input className="input" value={saveOpen.name} onChange={(e) => setSaveOpen({ ...saveOpen, name: e.target.value })} maxLength={60} autoFocus /></Field>
              {viewId && <label className="flex items-center gap-2 text-sm text-ink-600"><input type="checkbox" checked={saveOpen.update} onChange={(e) => setSaveOpen({ ...saveOpen, update: e.target.checked })} /> تحديث العرض الحالي بدل إنشاء عرض جديد</label>}
              <label className="flex items-center gap-2 text-sm text-ink-600"><input type="checkbox" checked={saveOpen.asDefault} onChange={(e) => setSaveOpen({ ...saveOpen, asDefault: e.target.checked })} /> <Star className="h-3.5 w-3.5 text-warning-500" /> اجعله العرض الافتراضي عند فتح الصفحة</label>
              <p className="text-xs text-ink-400">{words.length ? `المرشحات: ${words.join(" · ")}` : "بلا مرشحات"} · الأعمدة: {visibleColumns.length}</p>
            </div>
            <Submit label="حفظ" onCancel={() => setSaveOpen(null)} />
          </ActionForm>
        )}
      </Modal>
    </div>
  );
}
