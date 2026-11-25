import { INDIVIDUAL_PERMISSION_MAP } from "../lib/individualPermissionMap";
import { useEffect, useMemo, useState } from "react";
import { PAGES } from "../lib/nav";
import { PERMISSION_CATALOG } from "../lib/permissionCatalog";
import { supabase, isDemo } from "../lib/supabase";
import { useAuth } from "../lib/auth";
import { Card, ErrorBanner } from "./ui";

const ACTIONS = ["view", "add", "edit", "delete", "export"] as const;
type Action = typeof ACTIONS[number];
const LABELS: Record<Action, string> = { view: "اطلاع", add: "إضافة", edit: "تعديل", delete: "حذف", export: "تصدير" };
type Grants = Record<string, Partial<Record<Action, boolean>>>;
export function IndividualPermissionDraft({ staffId, name }: { staffId: string; name: string }) {
 const { profile } = useAuth();
 const [query, setQuery] = useState(""); const [grants, setGrants] = useState<Grants>({}); const [caps, setCaps] = useState<string[]>([]);
 const [revision, setRevision] = useState(0); const [home, setHome] = useState(""); const [reason, setReason] = useState("");
 const [error, setError] = useState(""); const [notice, setNotice] = useState(""); const [busy, setBusy] = useState(true);
 const pages = useMemo(() => PAGES.filter(p => !p.hidden && !p.path.includes(":")), []);
 useEffect(() => { let cancelled = false; setBusy(true); setError("");
  if (isDemo) { setBusy(false); return; }
  void supabase.from("staff_permission_drafts").select("page_grants,sensitive_grants,revision,home_page").eq("staff_id", staffId).maybeSingle().then(r => {
   if (cancelled) return;
   if (r.error) { setError("تعذّر قراءة المسودة. لا يمكن الحفظ قبل التحقق."); return; }
   setGrants(r.data?.page_grants ?? {}); setCaps(r.data?.sensitive_grants ?? []); setRevision(r.data?.revision ?? 0); setHome(r.data?.home_page ?? ""); setBusy(false);
  }); return () => { cancelled = true; };
 }, [staffId]);
 if (profile?.role !== "owner") return null;
 function toggle(path: string, action: Action) {
  setNotice(""); setGrants(old => { const next = { ...old[path], [action]: !old[path]?.[action] }; if (action !== "view" && next[action]) next.view = true;
   if (action === "view" && !next.view) { for (const a of ACTIONS) next[a] = false; if (home === path) setHome(""); }
   return { ...old, [path]: next }; });
 }
 async function save() { setError(""); setNotice(""); if (!reason.trim()) { setError("اكتب سبب حفظ المسودة."); return; }
  if (isDemo) { setNotice("معاينة محلية فقط: لم تُحفظ على خادم ولم تتغير صلاحيات المستخدم."); return; }
  setBusy(true); try { const r = await supabase.rpc("fn_owner_save_permission_draft", { p: { staff_id: staffId, pages: grants, sensitive: caps, home_page: home || null, expected_revision: revision, reason: reason.trim() } });
   if (r.error) throw r.error; setRevision(r.data.revision); setNotice("حُفظت مسودة غير مفعلة. صلاحيات الحساب الحالية لم تتغير.");
  } catch { setError("لم تُحفظ المسودة. تحقق من الاتصال والإصدار ثم أعد فتحها؛ لا تعِد المحاولة فوق تعديل أحدث."); } finally { setBusy(false); }
 }
 return <Card className="mt-4" data-testid="individual-permission-draft">
  <h2 className="text-lg font-semibold">مسودة صلاحيات {name}</h2>
  <p className="my-3 rounded-xl p-3 text-sm" style={{background:"var(--surface-sunken)",color:"inherit"}} role="status">المسودة غير مفعلة. لا تغيّر الحساب الحالي، ولن تتاح للتفعيل قبل اكتمال حماية كل نقاط البيانات والتصدير.</p>
  {error && <ErrorBanner message={error} />}{notice && <p role="status" className="my-3 text-sm">{notice}</p>}
  <label className="mb-1.5 block text-sm font-medium">ابحث عن صفحة<input className="input mt-1" value={query} onChange={e => setQuery(e.target.value)} /></label>
  <div className="my-3 grid gap-3 sm:grid-cols-2" data-testid="permission-page-list">{pages.filter(p => `${p.label} ${p.path}`.includes(query)).map(p => <fieldset key={p.path} className="rounded-xl border border-ink-100 p-3" disabled={busy}>
   <legend className="px-2 text-sm font-semibold">{p.label}</legend><p className="mb-2 text-xs opacity-80" dir="ltr">{p.path}</p>
   <div className="flex flex-wrap gap-3">{ACTIONS.map(a => <label key={a} className="flex min-h-[44px] items-center gap-2 text-sm"><input type="checkbox" checked={!!grants[p.path]?.[a]} onChange={() => toggle(p.path, a)} />{LABELS[a]}</label>)}</div>
  </fieldset>)}</div>
  <details className="my-3 rounded-xl border border-ink-100 p-3"><summary>تفاصيل الإجراءات الحساسة ({caps.length})</summary><p className="my-2 text-xs">لا تمنح الإضافة أو التعديل استرداداً أو خصماً تلقائياً. هذه اختيارات مسودة فقط، وخانة الحذف لا تسمح بمحو السندات المالية. الإلغاء مستقل عن الحذف. القيود المالية وقيود الدور الحالية تبقى سارية.</p>
   <div className="grid gap-2 sm:grid-cols-2">{PERMISSION_CATALOG.filter(c => !c.locked && INDIVIDUAL_PERMISSION_MAP[c.code]?.sensitive).map(c => <label key={c.code} className="flex min-h-[44px] items-center gap-2 text-sm"><input type="checkbox" disabled={busy} checked={caps.includes(c.code)} onChange={() => setCaps(old => old.includes(c.code) ? old.filter(v => v !== c.code) : [...old, c.code])} />{c.label}</label>)}</div>
  </details>
  <p className="my-3 text-xs">خريطة الربط قيد الاختبار. التعريفات وإعدادات الفرع والأمان وتقرير استعمال القدرات لم يكتمل ربطها بعد. المسودة لا تمنح إجراءً خارج قيود الدور الحالي.</p>
  <label className="mb-1.5 block text-sm font-medium">الصفحة الرئيسية<select className="input mt-1" value={home} disabled={busy} onChange={e => setHome(e.target.value)}><option value="">أول صفحة متاحة</option>{pages.filter(p => grants[p.path]?.view).map(p => <option key={p.path} value={p.path}>{p.label}</option>)}</select></label>
  <label className="mb-1.5 block text-sm font-medium">سبب حفظ المسودة<input className="input mt-1" value={reason} disabled={busy} onChange={e => setReason(e.target.value)} /></label>
  <button type="button" disabled={busy} className="btn-primary mt-3" onClick={() => void save()}>حفظ مسودة فقط</button>
 </Card>;
}
