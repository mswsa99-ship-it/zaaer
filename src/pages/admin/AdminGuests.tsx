import { useEffect, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { Users, Search, ShieldBan, Star, ArrowLeft, Copy, ShieldCheck, History } from "lucide-react";
import { guestProfileApi, toArabicError, type GuestProfileRow, type GuestProfileDetail } from "../../lib/api";
import { useAuth } from "../../lib/auth";
import { SectionTitle, LoadingScreen, Card, EmptyState, Badge, ErrorBanner } from "../../components/ui";
import { Modal, ActionForm, Submit, ReasonInput } from "../../components/forms";
import { RateDialog, Stars } from "../../components/Guests";
import { IDENTITY_TYPE_LABELS, RESERVATION_STATUS_LABELS, type IdentityType, type ReservationStatus } from "../../lib/types";
import { maskId, formatDateTime } from "../../lib/utils";

const FILTERS: Array<{ key: "all" | "banned" | "duplicates" | "rated" | "low"; label: string }> = [
  { key: "all", label: "الكل" }, { key: "banned", label: "محظورون" }, { key: "duplicates", label: "تكرار محتمل" }, { key: "rated", label: "مقيَّمون" }, { key: "low", label: "تقييم منخفض" },
];

/**
 * Guest profiles (decision 2, 21): search by name, phone digits, the whole document number or its last four, or a booking
 * number; the list never shows a full phone. Two profiles that share a phone or a document are shown as a possible
 * duplicate and never merged. One profile: its stays, its rating with the internal note, the ban (owner or manager).
 */
export default function AdminGuests() {
  const { id } = useParams();
  if (id) return <GuestProfilePage id={id} />;
  return <GuestList />;
}

function GuestList() {
  const [q, setQ] = useState("");
  const [filter, setFilter] = useState<typeof FILTERS[number]["key"]>("all");
  const [rows, setRows] = useState<GuestProfileRow[] | null>(null);
  const [total, setTotal] = useState(0);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    let alive = true;
    const t = setTimeout(async () => {
      try { const r = await guestProfileApi.list({ q: q.trim() || undefined, filter, limit: 100 }); if (alive) { setRows(r.rows); setTotal(r.total); setError(null); } }
      catch (e) { if (alive) { setError(toArabicError(e)); setRows([]); } }
    }, 200);
    return () => { alive = false; clearTimeout(t); };
  }, [q, filter]);
  if (rows === null && !error) return <LoadingScreen />;
  return (
    <div>
      <SectionTitle title="النزلاء" subtitle={`${total} ملف — يبحث بالاسم أو الجوال أو رقم الوثيقة (كاملًا أو آخر 4) أو رقم الحجز`} />
      {error && <div className="mb-4"><ErrorBanner message={error} /></div>}
      <div className="mb-4 flex flex-wrap items-center gap-2">
        <div className="relative min-w-[16rem] flex-1">
          <Search className="pointer-events-none absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2 text-ink-300" />
          <input value={q} onChange={(e) => setQ(e.target.value)} className="input pr-9" placeholder="بحث…" aria-label="بحث في النزلاء" data-testid="guest-search" />
        </div>
        <div className="flex gap-1 rounded-xl bg-ink-50 p-1 text-xs">
          {FILTERS.map((f) => <button key={f.key} onClick={() => setFilter(f.key)} className={`rounded-lg px-3 py-1.5 ${filter === f.key ? "bg-white font-medium text-ink-800 shadow-sm" : "text-ink-500"}`}>{f.label}</button>)}
        </div>
      </div>
      {(rows ?? []).length === 0 ? <EmptyState icon={<Users className="h-10 w-10" />} title="لا يوجد نزلاء" /> : (
        <Card className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead><tr className="border-b border-ink-100 text-xs text-ink-400">
              <th className="py-2 text-right font-medium">الاسم</th><th className="py-2 text-right font-medium">الوثيقة</th><th className="py-2 text-right font-medium">الجنسية</th>
              <th className="py-2 text-right font-medium">الجوال</th><th className="py-2 text-right font-medium">الإقامات</th><th className="py-2 text-right font-medium">آخر وصول</th><th className="py-2 text-right font-medium">التقييم</th><th className="py-2 text-right font-medium"></th>
            </tr></thead>
            <tbody>
              {(rows ?? []).map((g) => (
                <tr key={g.id} className="border-b border-ink-50" data-testid="guest-row">
                  <td className="py-2.5"><Link to={`/admin/guests/${g.id}`} className="font-medium text-ink-800 hover:text-brand-700">{g.full_name}</Link>
                    <div className="mt-0.5 flex flex-wrap gap-1">
                      {g.banned && <Badge className="bg-danger-500/10 text-danger-600"><ShieldBan className="h-3 w-3" /> محظور</Badge>}
                      {g.duplicates > 0 && <Badge className="bg-warning-500/10 text-warning-600"><Copy className="h-3 w-3" /> تكرار محتمل ({g.duplicates})</Badge>}
                    </div></td>
                  <td className="py-2.5 text-ink-600">{g.identity_type ? `${IDENTITY_TYPE_LABELS[g.identity_type as IdentityType]} ${maskId(g.identity_last4 ?? undefined)}` : "—"}</td>
                  <td className="py-2.5 text-ink-600">{g.nationality ?? "—"}</td>
                  <td className="py-2.5 text-ink-400" dir="ltr">{g.phone_masked ?? "—"}</td>
                  <td className="py-2.5 text-ink-600">{g.stays}</td>
                  <td className="py-2.5 text-ink-400" dir="ltr">{g.last_check_in ?? "—"}</td>
                  <td className="py-2.5">{g.rating != null ? <Stars n={g.rating} /> : <span className="text-ink-300">—</span>}</td>
                  <td className="py-2.5 text-left"><Link to={`/admin/guests/${g.id}`} className="btn-ghost px-2 py-1 text-xs">الملف</Link></td>
                </tr>
              ))}
            </tbody>
          </table>
        </Card>
      )}
      <p className="mt-3 text-xs text-ink-400">رقم الوثيقة مشفَّر ولا يُعرض كاملًا لأحد؛ البحث به يتم بالمطابقة على الخادم دون فك التشفير. الملفات التي تشترك في جوال أو وثيقة تُعلَّم تكرارًا محتملًا ولا تُدمج.</p>
    </div>
  );
}

function GuestProfilePage({ id }: { id: string }) {
  const navigate = useNavigate();
  const { can } = useAuth();
  const [d, setD] = useState<GuestProfileDetail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [dialog, setDialog] = useState<null | "ban" | "unban" | "rate">(null);
  const load = async () => { try { setD(await guestProfileApi.get(id)); setError(null); } catch (e) { setError(toArabicError(e)); } };
  useEffect(() => { load(); }, [id]); // eslint-disable-line react-hooks/exhaustive-deps
  if (error && !d) return <ErrorBanner message={error} />;
  if (!d) return <LoadingScreen />;
  const p = d.profile;
  const canRate = can("guest.rate");
  return (
    <div>
      <button onClick={() => navigate("/admin/guests")} className="mb-4 inline-flex items-center gap-1.5 text-sm text-ink-400 hover:text-ink-600"><ArrowLeft className="h-4 w-4" /> النزلاء</button>
      <SectionTitle title={p.full_name} subtitle={`${p.identity_type ? `${IDENTITY_TYPE_LABELS[p.identity_type as IdentityType]} ${maskId(p.identity_last4 ?? undefined)}` : "بلا وثيقة معتمدة بعد"} · ${p.nationality ?? "—"} · ${d.stays.length} إقامة`}
        action={<div className="flex flex-wrap gap-2">
          {canRate && <button onClick={() => setDialog("rate")} className="btn-outline text-sm" data-testid="rate-guest"><Star className="h-4 w-4" /> {p.rating != null ? "تعديل التقييم" : "تقييم"}</button>}
          {d.can_ban && !d.ban && <button onClick={() => setDialog("ban")} className="btn-danger text-sm" data-testid="ban-guest"><ShieldBan className="h-4 w-4" /> حظر الضيف</button>}
          {d.can_ban && d.ban?.own && <button onClick={() => setDialog("unban")} className="btn-outline text-sm" data-testid="unban-guest"><ShieldCheck className="h-4 w-4" /> رفع الحظر</button>}
        </div>} />
      {error && <div className="mb-4"><ErrorBanner message={error} /></div>}
      {d.ban && (
        <div className="mb-4 flex items-start gap-3 rounded-xl border border-danger-500/40 bg-danger-500/10 px-4 py-3 text-sm text-danger-600" data-testid="profile-ban">
          <ShieldBan className="mt-0.5 h-5 w-5 shrink-0" />
          <div><p className="font-semibold">محظور{d.ban.own ? "" : " (بحظر على ملف آخر يشترك معه في الجوال أو الوثيقة)"}</p><p className="mt-0.5 text-xs">السبب: {d.ban.reason} · منذ {formatDateTime(d.ban.since)}{d.ban.by ? ` · ${d.ban.by}` : ""}</p><p className="mt-0.5 text-xs">تنبيه أحمر على حجوزاته ولا يُسجَّل وصوله حتى يُرفع الحظر بسبب.</p></div>
        </div>
      )}
      <div className="grid gap-4 lg:grid-cols-3">
        <Card>
          <h3 className="mb-2 text-sm font-semibold text-ink-700">البيانات</h3>
          <dl className="space-y-1.5 text-sm">
            <div className="flex justify-between gap-2"><dt className="text-ink-400">الجوال</dt><dd dir="ltr">{p.phone ?? "—"}</dd></div>
            <div className="flex justify-between gap-2"><dt className="text-ink-400">الجنسية</dt><dd>{p.nationality ?? "—"}</dd></div>
            <div className="flex justify-between gap-2"><dt className="text-ink-400">الوثيقة</dt><dd>{p.identity_type ? `${IDENTITY_TYPE_LABELS[p.identity_type as IdentityType]} ${maskId(p.identity_last4 ?? undefined)}` : "—"}</dd></div>
            <div className="flex justify-between gap-2"><dt className="text-ink-400">في النظام منذ</dt><dd dir="ltr">{p.created_at.slice(0, 10)}</dd></div>
          </dl>
          <div className="mt-3 border-t border-ink-50 pt-3" data-testid="profile-rating">
            <p className="text-xs text-ink-400">التقييم الداخلي</p>
            <p className="mt-0.5 text-sm">{p.rating != null ? <Stars n={p.rating} /> : <span className="text-ink-300">لا تقييم</span>}{p.rated_by ? <span className="text-xs text-ink-400"> — {p.rated_by}</span> : null}</p>
            {p.rating_note && <p className="mt-1 text-xs text-ink-600">{p.rating_note}</p>}
          </div>
          {d.duplicates.length > 0 && (
            <div className="mt-3 border-t border-ink-50 pt-3" data-testid="profile-duplicates">
              <p className="mb-1 flex items-center gap-1 text-xs font-semibold text-warning-600"><Copy className="h-3.5 w-3.5" /> تكرار محتمل (لا دمج تلقائي)</p>
              <ul className="space-y-1 text-xs">{d.duplicates.map((x) => <li key={x.id}><Link to={`/admin/guests/${x.id}`} className="text-brand-700 hover:underline">{x.full_name}</Link> · {x.match === "identity" ? "الوثيقة نفسها" : "الجوال نفسه"} · {x.stays} إقامة</li>)}</ul>
            </div>
          )}
        </Card>
        <Card className="lg:col-span-2">
          <h3 className="mb-2 text-sm font-semibold text-ink-700">الإقامات</h3>
          {d.stays.length === 0 ? <p className="text-xs text-ink-400">لا إقامات.</p> : (
            <table className="w-full text-sm">
              <thead><tr className="border-b border-ink-100 text-xs text-ink-400"><th className="py-1.5 text-right font-medium">الحجز</th><th className="py-1.5 text-right font-medium">الفرع</th><th className="py-1.5 text-right font-medium">الوحدة</th><th className="py-1.5 text-right font-medium">المدة</th><th className="py-1.5 text-right font-medium">المصدر</th><th className="py-1.5 text-right font-medium">الحالة</th></tr></thead>
              <tbody>{d.stays.map((s) => (
                <tr key={s.reservation_id} className="border-b border-ink-50">
                  <td className="py-1.5 font-mono text-xs"><Link to={`/staff/reservations/${s.reservation_id}`} className="text-brand-700 hover:underline">{s.internal_ref}</Link>{!s.is_primary && <span className="mr-1 text-[10px] text-ink-400">(مرافق)</span>}</td>
                  <td className="py-1.5 text-xs">{s.branch_name}</td><td className="py-1.5 text-xs">{s.room_number ?? s.category_name ?? "—"}</td>
                  <td className="py-1.5 text-xs" dir="ltr">{s.check_in} → {s.check_out}</td><td className="py-1.5 text-xs">{s.source_name ?? "—"}</td>
                  <td className="py-1.5 text-xs">{RESERVATION_STATUS_LABELS[s.status as ReservationStatus] ?? s.status}</td>
                </tr>))}</tbody>
            </table>
          )}
          {d.ban_history.length > 0 && (
            <div className="mt-4 border-t border-ink-50 pt-3">
              <p className="mb-1 flex items-center gap-1 text-xs font-semibold text-ink-600"><History className="h-3.5 w-3.5" /> سجل الحظر</p>
              <ul className="space-y-1 text-xs text-ink-600">{d.ban_history.map((b) => <li key={b.id}>{formatDateTime(b.since)} — حظر{b.by ? ` (${b.by})` : ""}: {b.reason}{b.lifted_at ? ` · رُفع ${formatDateTime(b.lifted_at)}${b.lifted_by ? ` (${b.lifted_by})` : ""}: ${b.lift_reason}` : " · قائم"}</li>)}</ul>
            </div>
          )}
        </Card>
      </div>
      <BanDialog open={dialog === "ban" || dialog === "unban"} ban={dialog === "ban"} profileId={id} onClose={() => setDialog(null)} onDone={async () => { setDialog(null); await load(); }} />
      <RateDialog open={dialog === "rate"} profileId={id} rating={p.rating} note={p.rating_note} onClose={() => setDialog(null)} onDone={async () => { setDialog(null); await load(); }} />
    </div>
  );
}

function BanDialog({ open, ban, profileId, onClose, onDone }: { open: boolean; ban: boolean; profileId: string; onClose: () => void; onDone: () => void }) {
  const [reason, setReason] = useState("");
  return (
    <Modal open={open} title={ban ? "حظر الضيف" : "رفع الحظر عن الضيف"} onClose={onClose}>
      <ActionForm onSubmit={async () => { if (!reason.trim()) throw new Error("VALIDATION: reason"); if (ban) await guestProfileApi.ban(profileId, reason.trim()); else await guestProfileApi.unban(profileId, reason.trim()); setReason(""); onDone(); }}>
        <p className="mb-3 rounded-xl bg-warning-500/10 p-3 text-xs text-warning-600">{ban ? "يُطابَق الحظر بملف الضيف وجواله ووثيقته: تنبيه أحمر على حجوزاته القائمة والقادمة، ولا يُسجَّل وصوله ولا يُسلَّم له رمز حتى يُرفع الحظر بسبب. يُدرَج في قائمة المراجعة." : "يعود الضيف إلى الوضع الطبيعي؛ يبقى الحظر في سجله مع سبب رفعه."}</p>
        <ReasonInput value={reason} onChange={setReason} />
        <Submit label={ban ? "حظر" : "رفع الحظر"} onCancel={onClose} danger={ban} />
      </ActionForm>
    </Modal>
  );
}
