/**
 * «الرموز» — the key-box codes of the branch's units on one screen (the supervisor and housekeeping; management too).
 *
 * After a guest leaves a unit its light turns red — here and in the alert on top of every staff page — until a new code
 * is saved: the housekeeper who cleaned it opens the box with the current code (shown on request, recorded in the audit
 * trail), sets a new combination, tries it, and saves it here. The same code as the current one is refused by the
 * server. Housekeeping never sees or changes the code of a unit with a guest in house. The rules are in
 * fn_keybox_board / fn_keybox_reveal / fn_staff_rotate_keybox_code (0025); this page only shows them.
 */
import { useCallback, useEffect, useMemo, useState, type FormEvent } from "react";
import { KeyRound, Eye, EyeOff, CheckCircle2, Info } from "lucide-react";
import { supabase } from "../../lib/supabase";
import { useBranch } from "../../lib/branch";
import { codesApi, toArabicError, type KeyboxState, type KeyboxUnit } from "../../lib/api";
import { notifyKeyboxChanged } from "../../lib/keyboxAlerts";
import { SectionTitle, LoadingScreen, EmptyState, Card, Badge, ErrorBanner, Spinner } from "../../components/ui";
import { Field } from "../../components/forms";
import { BranchPicker } from "../../components/BranchPicker";
import { CodeLight } from "../../components/KeyboxAlert";
import { ROOM_STATUS_LABELS, ROOM_STATUS_COLORS, CLEANLINESS_LABELS, CLEANLINESS_COLORS, type RoomStatus } from "../../lib/types";
import { cn, formatDateTime, sinceArabic } from "../../lib/utils";

const CODE_RE = /^\d{4,8}$/;
const RANK: Record<KeyboxState, number> = { change: 0, untested: 1, ok: 2, none: 3 };
const TONE: Record<KeyboxState, "red" | "amber" | "green" | "grey"> = { change: "red", untested: "amber", ok: "green", none: "grey" };
const FILTERS: ReadonlyArray<{ key: "all" | KeyboxState; label: string }> = [
  { key: "all", label: "الكل" },
  { key: "change", label: "يجب تغييرها" },
  { key: "untested", label: "لم تُجرَّب" },
  { key: "ok", label: "محدّثة" },
  { key: "none", label: "بلا صندوق" },
];
const EMPTY: Record<"all" | KeyboxState, string> = {
  all: "لا توجد وحدات فعالة في هذا الفرع",
  change: "لا توجد وحدة تنتظر تغيير رمزها",
  untested: "لا توجد رموز بانتظار التجربة",
  ok: "لا توجد رموز محدّثة بعد",
  none: "كل الوحدات لها صناديق مسجّلة",
};

export default function Codes() {
  const { branchId, loading: branchLoading } = useBranch();
  const [units, setUnits] = useState<KeyboxUnit[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [filter, setFilter] = useState<"all" | KeyboxState>("all");
  const [editing, setEditing] = useState<string | null>(null);
  const [shown, setShown] = useState<{ room: string; code: string } | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [, setClock] = useState(0);

  const load = useCallback(async () => {
    if (!branchId) { setLoading(false); return; }
    try { setUnits(await codesApi.board(branchId)); setError(null); } catch (e) { setError(toArabicError(e)); }
    setLoading(false);
  }, [branchId]);

  useEffect(() => { setLoading(true); setEditing(null); setShown(null); load(); }, [load]);
  useEffect(() => {
    // a check-out or a finished cleaning changes the unit: the list follows at once; the clock keeps «منذ …» current
    const ch = supabase.channel("codes-board").on("postgres_changes", { event: "*", schema: "public", table: "rooms" }, () => load()).subscribe();
    const timer = window.setInterval(() => { setClock((n) => n + 1); load(); }, 30_000);
    return () => { supabase.removeChannel(ch); window.clearInterval(timer); };
  }, [load]);
  // a shown code disappears by itself after 30 seconds
  useEffect(() => {
    if (!shown) return;
    const t = window.setTimeout(() => setShown(null), 30_000);
    return () => window.clearTimeout(t);
  }, [shown]);

  const counts = useMemo(() => {
    const c: Record<KeyboxState, number> = { change: 0, untested: 0, ok: 0, none: 0 };
    for (const u of units) c[u.state] += 1;
    return c;
  }, [units]);
  const list = useMemo(() => units
    .filter((u) => filter === "all" || u.state === filter)
    .sort((a, b) => RANK[a.state] - RANK[b.state]
      || (a.state === "change" ? (a.needs_change_since ?? "").localeCompare(b.needs_change_since ?? "") : 0)
      || a.room_number.localeCompare(b.room_number, "en", { numeric: true })), [units, filter]);

  async function reveal(u: KeyboxUnit) {
    setBusy("view:" + u.room_id); setError(null); setNotice(null);
    try { const r = await codesApi.reveal(u.room_id); setShown({ room: u.room_id, code: r.code }); } catch (e) { setError(toArabicError(e)); }
    setBusy(null);
  }
  async function markTested(u: KeyboxUnit) {
    setBusy("test:" + u.room_id); setError(null); setNotice(null);
    try {
      const r = await codesApi.markTested(u.room_id);
      setNotice(`تم تأكيد تجربة رمز وحدة ${u.room_number}. ${roomStatusText(r.room_status)}`);
      notifyKeyboxChanged(); await load();
    } catch (e) { setError(toArabicError(e)); }
    setBusy(null);
  }
  async function saved(u: KeyboxUnit, roomStatus: string) {
    setEditing(null); setShown(null); setError(null);
    setNotice(`تم حفظ الرمز الجديد لوحدة ${u.room_number}. ${roomStatusText(roomStatus)}`);
    notifyKeyboxChanged(); await load();
  }

  if (loading || branchLoading) return <LoadingScreen />;
  return (
    <div>
      <SectionTitle title="الرموز" subtitle="رموز صناديق المفاتيح — يتغيّر رمز الوحدة بعد خروج كل نزيل" action={<BranchPicker />} />
      {error && <div className="mb-4"><ErrorBanner message={error} /></div>}
      {notice && <div className="mb-4 rounded-xl border border-success-500/30 bg-success-500/10 px-4 py-3 text-sm text-success-600" role="status">{notice}</div>}

      <div className="mb-4 flex flex-wrap gap-2" role="group" aria-label="تصفية الوحدات">
        {FILTERS.map((f) => (
          <button key={f.key} type="button" onClick={() => setFilter(f.key)} aria-pressed={filter === f.key}
            className={cn("inline-flex items-center gap-2 rounded-xl border px-3 py-1.5 text-sm transition-colors",
              filter === f.key ? "border-brand-400 bg-brand-50 text-brand-700" : "border-ink-100 bg-white text-ink-600 hover:bg-ink-50")}>
            {f.key !== "all" && <CodeLight tone={TONE[f.key]} size="h-2.5 w-2.5" />}
            {f.label}
            <span className="font-semibold">{f.key === "all" ? units.length : counts[f.key]}</span>
          </button>
        ))}
      </div>

      {list.length === 0 ? <EmptyState icon={<KeyRound className="h-10 w-10" />} title={EMPTY[filter]} /> : (
        <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
          {list.map((u) => (
            <UnitCard key={u.room_id} u={u} shownCode={shown?.room === u.room_id ? shown.code : null} editing={editing === u.room_id} busy={busy}
              onReveal={() => reveal(u)} onHide={() => setShown(null)} onEdit={() => { setEditing(u.room_id); setNotice(null); }}
              onCancel={() => setEditing(null)} onSaved={(st) => saved(u, st)} onTested={() => markTested(u)} />
          ))}
        </div>
      )}

      <p className="mt-6 flex items-start gap-2 text-xs leading-relaxed text-ink-400">
        <Info className="mt-0.5 h-3.5 w-3.5 shrink-0" />
        بعد خروج أي نزيل تتحول وحدته إلى الأحمر هنا وفي أعلى كل الصفحات حتى يُحفظ رمز جديد، ولا يُسلَّم رمزها لنزيل جديد قبل ذلك. لا يُقبل الرمز الحالي نفسه. كل عرض أو تغيير للرمز يُسجَّل في سجل الإجراءات، والرمز لا يُحفظ في المتصفح.
      </p>
    </div>
  );
}

function roomStatusText(st: string): string {
  if (st === "ready") return "الوحدة جاهزة الآن.";
  return `حالة الوحدة: ${ROOM_STATUS_LABELS[st as RoomStatus] ?? st}.`;
}

function stateLine(u: KeyboxUnit): string {
  if (u.state === "change") return u.has_code ? "يجب تغيير الرمز بعد خروج النزيل" : "لا يوجد رمز — عيّن رمزًا للصندوق";
  if (u.state === "untested") return "رمز جديد لم يُجرَّب على الصندوق بعد";
  if (u.state === "ok") return "الرمز محدّث";
  return "لا يوجد صندوق مفاتيح مسجّل لهذه الوحدة";
}

const LINE_COLOR: Record<KeyboxState, string> = { change: "text-danger-600", untested: "text-warning-600", ok: "text-success-600", none: "text-ink-500" };

function UnitCard({ u, shownCode, editing, busy, onReveal, onHide, onEdit, onCancel, onSaved, onTested }: {
  u: KeyboxUnit; shownCode: string | null; editing: boolean; busy: string | null;
  onReveal: () => void; onHide: () => void; onEdit: () => void; onCancel: () => void; onSaved: (roomStatus: string) => Promise<void>; onTested: () => void;
}) {
  const red = u.state === "change";
  return (
    <Card className={cn("p-4", red && "border-danger-500/40 ring-1 ring-danger-500/20")}>
      <div data-testid="code-unit" data-room={u.room_number} data-state={u.state}>
        <div className="flex items-start justify-between gap-3">
          <div className="flex min-w-0 items-start gap-3">
            <span className="mt-1.5"><CodeLight tone={TONE[u.state]} size="h-3.5 w-3.5" /></span>
            <div className="min-w-0">
              <p className="text-base font-semibold text-ink-800">وحدة {u.room_number}</p>
              {(u.block || u.floor) && <p className="text-xs text-ink-400">{[u.block, u.floor].filter(Boolean).join(" · ")}</p>}
              <p className={cn("mt-1 text-sm font-medium", LINE_COLOR[u.state])}>
                {stateLine(u)}
                {red && u.needs_change_since && <span className="font-normal" title={formatDateTime(u.needs_change_since)}> · {sinceArabic(u.needs_change_since)}</span>}
              </p>
              {u.last_changed_at && u.state !== "none" && (
                <p className="mt-0.5 text-xs text-ink-400">آخر تغيير: {formatDateTime(u.last_changed_at)}{u.last_changed_by ? ` · ${u.last_changed_by}` : ""}</p>
              )}
            </div>
          </div>
          <div className="flex shrink-0 flex-col items-end gap-1">
            <Badge className={ROOM_STATUS_COLORS[u.room_status as RoomStatus] ?? "bg-ink-100 text-ink-500"}>{ROOM_STATUS_LABELS[u.room_status as RoomStatus] ?? u.room_status}</Badge>
            <Badge className={CLEANLINESS_COLORS[u.cleanliness] ?? "bg-ink-100 text-ink-500"}>{CLEANLINESS_LABELS[u.cleanliness] ?? u.cleanliness}</Badge>
          </div>
        </div>

        {u.guest_in_house && (
          <p className="mt-3 rounded-lg bg-ink-50 px-3 py-2 text-xs text-ink-500">
            {u.can_change ? "فيها نزيل مقيم." : "فيها نزيل مقيم — رمزها لا يُعرض ولا يُغيَّر من حسابك."}
          </p>
        )}

        {shownCode && (
          <div className="mt-3 flex items-center justify-between gap-3 rounded-xl border border-ink-100 bg-ink-50 px-3 py-2">
            <div>
              <p className="text-xs text-ink-400">الرمز الحالي (يختفي بعد 30 ثانية)</p>
              <p className="font-mono text-2xl font-semibold tracking-[0.3em] text-ink-800" dir="ltr" data-testid="shown-code">{shownCode}</p>
            </div>
            <button type="button" onClick={onHide} className="btn-ghost px-3 py-1.5 text-xs"><EyeOff className="h-3.5 w-3.5" /> إخفاء</button>
          </div>
        )}

        {!editing && (u.can_view || u.can_change) && (
          <div className="mt-3 flex flex-wrap gap-2">
            {u.can_view && !shownCode && (
              <button type="button" onClick={onReveal} disabled={busy === "view:" + u.room_id} className="btn-outline px-3 py-1.5 text-xs">
                {busy === "view:" + u.room_id ? <Spinner className="h-3.5 w-3.5" /> : <Eye className="h-3.5 w-3.5" />} إظهار الرمز
              </button>
            )}
            {u.can_change && (
              <button type="button" onClick={onEdit} className={cn(red ? "btn-danger" : "btn-outline", "px-3 py-1.5 text-xs")}>
                <KeyRound className="h-3.5 w-3.5" /> {u.has_code ? "تغيير الرمز" : "تعيين رمز"}
              </button>
            )}
            {u.state === "untested" && u.can_change && (
              <button type="button" onClick={onTested} disabled={busy === "test:" + u.room_id} className="btn-outline px-3 py-1.5 text-xs">
                <CheckCircle2 className="h-3.5 w-3.5" /> جرّبته — يعمل
              </button>
            )}
          </div>
        )}

        {editing && <ChangeForm u={u} onCancel={onCancel} onSaved={onSaved} />}
      </div>
    </Card>
  );
}

function ChangeForm({ u, onCancel, onSaved }: { u: KeyboxUnit; onCancel: () => void; onSaved: (roomStatus: string) => Promise<void> }) {
  const [code1, setCode1] = useState("");
  const [code2, setCode2] = useState("");
  const [tested, setTested] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const mismatch = code1.length > 0 && code2.length >= code1.length && code1 !== code2;
  const valid = CODE_RE.test(code1) && code1 === code2 && tested;
  const digits = (v: string) => v.replace(/\D/g, "").slice(0, 8);

  async function submit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    if (!CODE_RE.test(code1)) { setError("الرمز من 4 إلى 8 أرقام."); return; }
    if (code1 !== code2) { setError("الرمزان غير متطابقين."); return; }
    if (!tested) { setError("اضبط الرمز على الصندوق وجرّبه أولًا، ثم أكّد ذلك."); return; }
    setBusy(true);
    try {
      const r = await codesApi.change(u.room_id, code1, true);
      await onSaved(r.room_status);
    } catch (err) {
      setError(toArabicError(err));
      setBusy(false);
    }
  }

  return (
    <form onSubmit={submit} className="mt-3 space-y-3 rounded-xl border border-ink-100 bg-ink-50/60 p-3" data-testid="code-form">
      <p className="text-xs text-ink-500">اضبط الرمز الجديد على الصندوق وجرّبه، ثم اكتبه هنا مرتين. لا يُقبل الرمز الحالي نفسه.</p>
      {u.guest_in_house && <p className="text-xs text-warning-600">في الوحدة نزيل مقيم: بعد التغيير سلّمه الرمز الجديد بنفسك.</p>}
      <div className="grid grid-cols-2 gap-2">
        <Field label="الرمز الجديد">
          <input aria-label="الرمز الجديد" type="password" inputMode="numeric" autoComplete="off" value={code1} onChange={(e) => setCode1(digits(e.target.value))}
            className="input text-center font-mono tracking-widest" dir="ltr" autoFocus />
        </Field>
        <Field label="أعد كتابته">
          <input aria-label="تأكيد الرمز" type="password" inputMode="numeric" autoComplete="off" value={code2} onChange={(e) => setCode2(digits(e.target.value))}
            className="input text-center font-mono tracking-widest" dir="ltr" />
        </Field>
      </div>
      {mismatch && <p className="text-xs text-danger-600">الرمزان غير متطابقين.</p>}
      <label className="flex items-start gap-2 text-sm text-ink-700">
        <input type="checkbox" className="mt-1" checked={tested} onChange={(e) => setTested(e.target.checked)} />
        ضبطت الرمز الجديد على الصندوق وجرّبته فانفتح
      </label>
      {error && <ErrorBanner message={error} />}
      <div className="flex flex-wrap gap-2">
        <button type="submit" disabled={!valid || busy} className="btn-primary text-sm">
          {busy ? <Spinner className="h-4 w-4" /> : <KeyRound className="h-4 w-4" />} حفظ الرمز
        </button>
        <button type="button" onClick={onCancel} className="btn-outline text-sm">إلغاء</button>
      </div>
    </form>
  );
}
