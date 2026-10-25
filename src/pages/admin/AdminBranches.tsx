import { useCallback, useEffect, useState } from "react";
import { Building2, Plus, Pencil, Image as ImageIcon, Trash2 } from "lucide-react";
import { supabase } from "../../lib/supabase";
import { useAuth } from "../../lib/auth";
import { opsApi, branchMediaApi, guestApi, toArabicError } from "../../lib/api";
import { SectionTitle, LoadingScreen, Card, EmptyState, Badge, ErrorBanner } from "../../components/ui";
import { formatCurrency } from "../../lib/utils";
import { Modal, Field, ActionForm, Submit, DefinitionLifecycle, ArchivedBadge, Toggle, MoneyInput } from "../../components/forms";

interface Branch { id: string; name_ar: string; name_en: string | null; city: string | null; address: string | null; phone: string | null; email: string | null; is_active: boolean; check_in_time: string; check_out_time: string; timezone: string; tax_rate_bp: number; prices_include_tax: boolean; default_deposit_halalas: number; supervisor_max_discount_bp: number; tax_number: string | null; commercial_register: string | null; archived_at: string | null; version: number; rooms?: number;
  // decision 31
  map_url: string | null; booking_platform_url: string | null; country_code: string; default_language: "ar" | "en" }

const EMPTY: Partial<Branch> = { name_ar: "", name_en: "", city: "", address: "", phone: "", email: "", check_in_time: "16:00", check_out_time: "12:00", timezone: "Asia/Riyadh", tax_rate_bp: 0, prices_include_tax: false, default_deposit_halalas: 5000, supervisor_max_discount_bp: 0, is_active: true, map_url: "", booking_platform_url: "", country_code: "SA", default_language: "ar" };
const taxText = (b: Pick<Branch, "tax_rate_bp" | "prices_include_tax">) => b.tax_rate_bp === 0 ? "بلا ضريبة" : `ضريبة ${(b.tax_rate_bp / 100).toFixed(2)}% ${b.prices_include_tax ? "(شاملة)" : "(غير شاملة)"}`;

export default function AdminBranches() {
  const { profile } = useAuth();
  const isOwner = profile?.role === "owner";
  const [rows, setRows] = useState<Branch[]>([]);
  const [loading, setLoading] = useState(true); const [error, setError] = useState<string | null>(null);
  const [draft, setDraft] = useState<Partial<Branch> | null>(null);
  const [showArchived, setShowArchived] = useState(false);

  const load = useCallback(async () => {
    const [b, r] = await Promise.all([
      supabase.from("branches").select("id, name_ar, name_en, city, address, phone, email, is_active, check_in_time, check_out_time, timezone, tax_rate_bp, prices_include_tax, default_deposit_halalas, supervisor_max_discount_bp, tax_number, commercial_register, archived_at, version, map_url, booking_platform_url, country_code, default_language").order("name_ar"),
      supabase.from("rooms").select("branch_id").is("archived_at", null),
    ]);
    if (b.error) setError(toArabicError(b.error));
    const count = new Map<string, number>(); for (const x of (r.data ?? []) as { branch_id: string }[]) count.set(x.branch_id, (count.get(x.branch_id) ?? 0) + 1);
    setRows(((b.data ?? []) as Branch[]).map((x) => ({ ...x, rooms: count.get(x.id) ?? 0 })));
    setLoading(false);
  }, []);
  useEffect(() => { load(); }, [load]);

  if (loading) return <LoadingScreen />;
  const visible = rows.filter((b) => showArchived || !b.archived_at);
  return (
    <div>
      <SectionTitle title="الفروع" subtitle={`${visible.length} فرع — الضريبة والمنطقة الزمنية إعدادات معتمدة لكل فرع`} action={isOwner ? <button onClick={() => setDraft({ ...EMPTY })} className="btn-primary text-sm"><Plus className="h-4 w-4" /> فرع جديد</button> : undefined} />
      {error && <div className="mb-4"><ErrorBanner message={error} /></div>}
      <div className="mb-4"><Toggle checked={showArchived} onChange={setShowArchived} label="إظهار المؤرشف" /></div>
      {visible.length === 0 ? <EmptyState icon={<Building2 className="h-10 w-10" />} title="لا توجد فروع" /> : (
        <div className="grid gap-3 md:grid-cols-2">
          {visible.map((b) => (
            <Card key={b.id} className={b.archived_at ? "opacity-60" : ""}>
              <div className="flex items-start justify-between gap-3">
                <div>
                  <div className="flex items-center gap-2"><h3 className="text-base font-semibold text-ink-800">{b.name_ar}</h3><ArchivedBadge archivedAt={b.archived_at} />{!b.is_active && !b.archived_at && <Badge className="bg-warning-500/10 text-warning-600">معطل</Badge>}</div>
                  {b.name_en && <p className="text-xs text-ink-400" dir="ltr">{b.name_en}</p>}
                  <p className="mt-1 text-sm text-ink-500">{[b.city, b.address].filter(Boolean).join(" · ") || "—"}</p>
                  <p className="mt-1 text-xs text-ink-400">{b.rooms} وحدة · وصول {b.check_in_time?.slice(0, 5)} / مغادرة {b.check_out_time?.slice(0, 5)} · {taxText(b)} · التأمين {formatCurrency(b.default_deposit_halalas / 100)} لكل وحدة · {b.timezone} · {b.default_language === "en" ? "English" : "عربي"}</p>
                  <p className="mt-1 text-xs text-ink-400">{b.booking_platform_url ? <a href={b.booking_platform_url} target="_blank" rel="noopener noreferrer" className="text-brand-600 hover:underline" dir="ltr">رابط منصة الحجز</a> : <span className="text-warning-600">لا رابط منصة حجز — يُحال الضيف إلى الاستقبال</span>}{b.map_url ? <> · <a href={b.map_url} target="_blank" rel="noopener noreferrer" className="text-brand-600 hover:underline">الخريطة</a></> : null}</p>
                </div>
                <button onClick={() => setDraft(b)} className="btn-ghost p-1.5" title="تعديل" aria-label={`تعديل ${b.name_ar}`}><Pencil className="h-4 w-4" /></button>
              </div>
            </Card>
          ))}
        </div>
      )}
      <Modal open={!!draft} title={draft?.id ? "تعديل فرع" : "فرع جديد"} onClose={() => setDraft(null)} wide>
        {draft && (
          <ActionForm onSubmit={async () => { await opsApi.upsertBranch({ ...draft, rooms: undefined }); setDraft(null); await load(); }}>
            <div className="grid gap-3 sm:grid-cols-2">
              <Field label="الاسم العربي (مطلوب)"><input className="input" value={draft.name_ar ?? ""} onChange={(e) => setDraft({ ...draft, name_ar: e.target.value })} /></Field>
              <Field label="الاسم الإنجليزي (مطلوب)" hint="يظهر في مطبوعات الضيف بالإنجليزية"><input className="input" dir="ltr" value={draft.name_en ?? ""} onChange={(e) => setDraft({ ...draft, name_en: e.target.value })} aria-label="الاسم الإنجليزي" /></Field>
              <Field label="المدينة"><input className="input" value={draft.city ?? ""} onChange={(e) => setDraft({ ...draft, city: e.target.value })} /></Field>
              <Field label="العنوان"><input className="input" value={draft.address ?? ""} onChange={(e) => setDraft({ ...draft, address: e.target.value })} /></Field>
              <Field label="الهاتف"><input className="input" dir="ltr" value={draft.phone ?? ""} onChange={(e) => setDraft({ ...draft, phone: e.target.value })} /></Field>
              <Field label="البريد"><input className="input" dir="ltr" value={draft.email ?? ""} onChange={(e) => setDraft({ ...draft, email: e.target.value })} /></Field>
              <Field label="وقت الوصول"><input type="time" className="input" dir="ltr" value={draft.check_in_time?.slice(0, 5) ?? "16:00"} onChange={(e) => setDraft({ ...draft, check_in_time: e.target.value })} /></Field>
              <Field label="وقت المغادرة"><input type="time" className="input" dir="ltr" value={draft.check_out_time?.slice(0, 5) ?? "12:00"} onChange={(e) => setDraft({ ...draft, check_out_time: e.target.value })} /></Field>
              <Field label="المنطقة الزمنية"><input className="input" dir="ltr" value={draft.timezone ?? "Asia/Riyadh"} onChange={(e) => setDraft({ ...draft, timezone: e.target.value })} /></Field>
              <Field label="التأمين لكل وحدة" hint="المبلغ المقترح عند قبض التأمين، وهو منفصل عن الإيراد ويُرد بعد فحص المغادرة."><MoneyInput valueHalalas={draft.default_deposit_halalas ?? 0} onChange={(h) => setDraft({ ...draft, default_deposit_halalas: h ?? 0 })} /></Field>
              <Field label="السجل التجاري"><input className="input" dir="ltr" value={draft.commercial_register ?? ""} onChange={(e) => setDraft({ ...draft, commercial_register: e.target.value })} /></Field>
              <Field label="البلد" hint="رمز من حرفين"><input className="input" dir="ltr" maxLength={2} value={draft.country_code ?? "SA"} onChange={(e) => setDraft({ ...draft, country_code: e.target.value.toUpperCase() })} aria-label="البلد" /></Field>
              <Field label="اللغة الافتراضية" hint="للرسائل التلقائية للضيف ومطبوعاته (ملخص الإقامة)"><select className="input" value={draft.default_language ?? "ar"} onChange={(e) => setDraft({ ...draft, default_language: e.target.value as "ar" | "en" })} aria-label="اللغة الافتراضية"><option value="ar">العربية</option><option value="en">English</option></select></Field>
              <Field label="رابط الموقع (خرائط Google)" hint="https فقط؛ يرسله المساعد للضيف ويظهر في صفحاته" className="sm:col-span-2"><input className="input" dir="ltr" value={draft.map_url ?? ""} onChange={(e) => setDraft({ ...draft, map_url: e.target.value })} placeholder="https://maps.app.goo.gl/…" aria-label="رابط الموقع" /></Field>
              <Field label="رابط منصة الحجز" hint="الطريقة الوحيدة لحجز جديد (القرار 23): يُحال إليه من لا حجز له، في الموقع وواتساب" className="sm:col-span-2"><input className="input" dir="ltr" value={draft.booking_platform_url ?? ""} onChange={(e) => setDraft({ ...draft, booking_platform_url: e.target.value })} placeholder="https://www.booking.com/hotel/sa/…" aria-label="رابط منصة الحجز" /></Field>
              <Field label="أقصى خصم للمشرف %" hint="من إيجار الإقامة، قبل الوصول، ولا ينزل تحت أدنى سعر للنوع. صفر = لا يخصم المشرف؛ ما فوقه للمالك أو المدير.">
                <input type="number" min={0} max={100} step="0.5" className="input" dir="ltr" aria-label="أقصى خصم للمشرف" value={((draft.supervisor_max_discount_bp ?? 0) / 100).toString()} onChange={(e) => setDraft({ ...draft, supervisor_max_discount_bp: Math.round(Number(e.target.value) * 100) })} />
              </Field>
            </div>
            {/* decision 68: the tax policy is the owner's alone (the server refuses anyone else's change too) */}
            <fieldset className="mt-4 rounded-xl border border-ink-100 p-3" disabled={!isOwner} data-testid="branch-tax">
              <legend className="px-1 text-xs font-semibold text-ink-600">الضريبة {isOwner ? "" : "— يعدّلها المالك فقط"}</legend>
              <div className="grid gap-3 sm:grid-cols-2">
                <Field label="نسبة الضريبة %" hint="صفر يعني لا ضريبة على الحجوزات الجديدة؛ أي تغيير يسري على الحجوزات الجديدة فقط، ويُسجَّل."><input type="number" step="0.01" min={0} max={100} className="input" dir="ltr" aria-label="نسبة الضريبة" value={((draft.tax_rate_bp ?? 0) / 100).toString()} onChange={(e) => setDraft({ ...draft, tax_rate_bp: Math.round(Number(e.target.value) * 100) })} /></Field>
                <Field label="الرقم الضريبي"><input className="input" dir="ltr" value={draft.tax_number ?? ""} onChange={(e) => setDraft({ ...draft, tax_number: e.target.value })} /></Field>
                {(draft.tax_rate_bp ?? 0) > 0 && <div className="sm:col-span-2"><Toggle checked={draft.prices_include_tax ?? false} onChange={(v) => setDraft({ ...draft, prices_include_tax: v })} label="الأسعار شاملة الضريبة" /></div>}
              </div>
            </fieldset>
            {draft.id && <div className="mt-3"><Toggle checked={draft.is_active ?? true} onChange={(v) => setDraft({ ...draft, is_active: v })} label="فرع فعال (التعطيل يمنع حجوزات جديدة ولا يخفي التاريخ)" /></div>}
            <Submit label="حفظ" onCancel={() => setDraft(null)} />
          </ActionForm>
        )}
        {draft?.id && <BranchMedia branchId={draft.id} />}
        {draft?.id && isOwner && <DefinitionLifecycle entity="branch" id={draft.id} archived={!!draft.archived_at} onDone={() => { setDraft(null); load(); }} />}
      </Modal>
    </div>
  );
}

/** The branch's logo (PNG, JPG or WebP up to 200 KB) and image (up to 1 MB), kept with the branch's settings (decision 31). */
function BranchMedia({ branchId }: { branchId: string }) {
  const [info, setInfo] = useState<Record<string, { mime: string; size_bytes: number; updated_at: string; updated_by: string | null } | undefined>>({});
  const [preview, setPreview] = useState<Record<string, string | null>>({});
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const load = useCallback(async () => {
    try {
      const i = await branchMediaApi.info(branchId); setInfo(i);
      const out: Record<string, string | null> = {};
      for (const k of ["logo", "image"] as const) out[k] = i[k] ? await guestApi.branchMedia(branchId, k) : null;
      setPreview(out);
    } catch (e) { setError(toArabicError(e)); }
  }, [branchId]);
  useEffect(() => { load(); }, [load]);
  const pick = (kind: "logo" | "image") => async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]; e.target.value = ""; if (!file) return;
    setBusy(kind); setError(null);
    try {
      const b64 = await new Promise<string>((res, rej) => { const r = new FileReader(); r.onload = () => res(String(r.result).replace(/^data:[^,]*,/, "")); r.onerror = () => rej(new Error("VALIDATION: image")); r.readAsDataURL(file); });
      await branchMediaApi.set(branchId, kind, b64); await load();
    } catch (err) { setError(toArabicError(err)); } finally { setBusy(null); }
  };
  const clear = async (kind: "logo" | "image") => { setBusy(kind); setError(null); try { await branchMediaApi.set(branchId, kind, null); await load(); } catch (err) { setError(toArabicError(err)); } finally { setBusy(null); } };
  const kb = (n: number) => `${Math.round(n / 1024)} كيلوبايت`;
  return (
    <div className="mt-4 rounded-xl border border-ink-100 p-3" data-testid="branch-media">
      <p className="mb-2 text-xs font-semibold text-ink-600">الشعار والصورة</p>
      {error && <div className="mb-2"><ErrorBanner message={error} /></div>}
      <div className="grid gap-3 sm:grid-cols-2">
        {([["logo", "الشعار (يظهر في المطبوعات) — PNG/JPG/WebP حتى 200 كيلوبايت"], ["image", "صورة الفرع (تظهر في صفحات الضيف) — حتى 1 ميجابايت"]] as const).map(([kind, label]) => (
          <div key={kind} className="rounded-lg bg-ink-50 p-3">
            <p className="text-[11px] text-ink-500">{label}</p>
            <div className="mt-2 flex items-center gap-3">
              {preview[kind] ? <img src={preview[kind]!} alt="" className={`rounded-md object-contain ${kind === "logo" ? "h-12 max-w-[120px]" : "h-16 max-w-[160px]"}`} /> : <div className="flex h-12 w-16 items-center justify-center rounded-md bg-white text-ink-300"><ImageIcon className="h-5 w-5" /></div>}
              <div className="flex-1 text-[11px] text-ink-400">{info[kind] ? `${info[kind]!.mime.replace("image/", "").toUpperCase()} · ${kb(info[kind]!.size_bytes)}${info[kind]!.updated_by ? ` · ${info[kind]!.updated_by}` : ""}` : "لا يوجد"}</div>
            </div>
            <div className="mt-2 flex gap-2">
              <label className="btn-outline cursor-pointer text-xs">{busy === kind ? "…" : info[kind] ? "استبدال" : "رفع"}<input type="file" accept="image/png,image/jpeg,image/webp" className="hidden" onChange={pick(kind)} disabled={busy === kind} aria-label={kind === "logo" ? "رفع الشعار" : "رفع صورة الفرع"} /></label>
              {info[kind] && <button type="button" onClick={() => clear(kind)} disabled={busy === kind} className="btn-ghost text-xs text-danger-600"><Trash2 className="h-3.5 w-3.5" /> إزالة</button>}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
