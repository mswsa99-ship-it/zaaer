import { useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { supabase } from "../../lib/supabase";
import { useAuth } from "../../lib/auth";
import { useBranchQuery, must } from "../../lib/useBranchQuery";
import { useBranch } from "../../lib/branch";
import { BranchPicker } from "../../components/BranchPicker";
import { staffApi, toArabicError } from "../../lib/api";
import { SectionTitle, LoadingScreen, EmptyState, Card, Spinner, ErrorBanner, Badge, LoadErrorCard } from "../../components/ui";
import { Wrench, Plus, LifeBuoy, CheckCircle2 } from "lucide-react";
import { formatDateTime } from "../../lib/utils";
import { Field } from "../../components/forms";

interface Ticket {
  id: string;
  title: string;
  description: string | null;
  status: string;
  room_id: string;
  room?: { room_number: string } | null;
  created_at: string;
  branch_id?: string;
}

interface HandoffTicket {
  id: string;
  kind: string;
  external_ref: string | null;
  source_name: string | null;
  details: Record<string, unknown> | null;
  status: string;
  created_at: string;
  reservation_id: string | null;
  conversation_id: string | null;
  branch_id?: string;
}

const KIND_LABELS: Record<string, string> = {
  unmatched_reservation: "حجز غير مطابق",
  assistance: "طلب مساعدة بشرية",
  escalation: "تصعيد",
  ai_guardrail: "حماية الذكاء الاصطناعي",
  ai_fallback: "تعطل المساعد",
  guest_request: "طلب النزيل موظفًا",
};

const KIND_COLORS: Record<string, string> = {
  unmatched_reservation: "bg-warning-500/10 text-warning-700",
  assistance: "bg-brand-50 text-brand-700",
  escalation: "bg-danger-500/10 text-danger-600",
  ai_guardrail: "bg-danger-500/10 text-danger-600",
  ai_fallback: "bg-ink-100 text-ink-600",
};

const DETAIL_LABELS: Record<string, (v: unknown) => string | null> = {
  phone_last4_given: (v) => (v ? "أدخل النزيل آخر 4 أرقام من جواله" : null),
  reason: (v) => `السبب: ${String(v)}`,
  note: (v) => String(v),
  message: (v) => `رسالة النزيل: ${String(v)}`,
  channel: (v) => `القناة: ${v === "whatsapp" ? "واتساب" : v === "web" ? "الموقع" : String(v)}`,
  rule: () => null,
  stage: () => null,
};

const HANDOFF_STATUS: Record<string, string> = { open: "مفتوح", in_progress: "قيد المعالجة", resolved: "تم الحل" };

function detailsText(d: Record<string, unknown> | string | null): string {
  if (!d) return "";
  if (typeof d === "string") return d.slice(0, 300);   // FRONT-17: a plain sentence, not one letter per entry
  const parts: string[] = [];
  for (const [k, v] of Object.entries(d)) {
    if (v === null || v === undefined || v === "") continue;
    // COPY-01: a sentence per known key, never a raw key
    const known = DETAIL_LABELS[k];
    if (known) { const line = known(v); if (line) parts.push(line); continue; }
    if (typeof v === "string") parts.push(v);
  }
  return parts.join(" · ").slice(0, 300);
}

const NO_TICKETS: { tickets: Ticket[]; rooms: { id: string; room_number: string; branch_id?: string }[]; handoffs: HandoffTicket[] } = { tickets: [], rooms: [], handoffs: [] };

export default function Tickets() {
  const { profile, can } = useAuth();
  const canSeeHandoff = profile?.role === "owner" || profile?.role === "manager" || profile?.role === "supervisor";

  const [acting, setActing] = useState<string | null>(null);
  const creatingRef = useRef(false);
  const [error, setError] = useState<string | null>(null);
  const [showForm, setShowForm] = useState(false);
  const [newTitle, setNewTitle] = useState("");
  const [newDesc, setNewDesc] = useState("");
  const [newRoom, setNewRoom] = useState("");
  const [formError, setFormError] = useState<string | null>(null);
  // per-field errors: the message sits at the field it is about (UX: a banner under the form did not say which field)
  const [fieldErr, setFieldErr] = useState<{ room?: string; title?: string }>({});

  // G24: the reports of the active branch only; a late answer for another branch is dropped
  const q = useBranchQuery(async (branchId) => {
    const [t, r, h] = await Promise.all([
      supabase.from("maintenance_tickets").select("id, title, description, status, room_id, room:rooms(room_number), created_at").eq("branch_id", branchId).order("created_at", { ascending: false }),
      supabase.from("rooms").select("id, room_number").eq("branch_id", branchId).order("room_number"),
      supabase.from("human_handoff_tickets").select("id, kind, external_ref, source_name, details, status, created_at, reservation_id, conversation_id").eq("branch_id", branchId).order("created_at", { ascending: false }).limit(100),
    ]);
    return {
      tickets: (must(t) as unknown as Ticket[]).map((x) => ({ ...x, branch_id: branchId })),
      rooms: (must(r) as { id: string; room_number: string }[]).map((x) => ({ ...x, branch_id: branchId })),
      handoffs: (h.error ? [] : ((h.data as HandoffTicket[]) ?? [])).map((x) => ({ ...x, branch_id: branchId })),   // not readable by every role
    };
  }, [], NO_TICKETS,
    // «جميع الفروع» (owner): every branch's reports, rooms and hand-offs together, newest first; each row keeps its branch
    { merge: (ps) => ({
      tickets: ps.flatMap((p) => p.tickets).sort((a, b) => b.created_at.localeCompare(a.created_at)),
      rooms: ps.flatMap((p) => p.rooms),
      handoffs: ps.flatMap((p) => p.handoffs).sort((a, b) => b.created_at.localeCompare(a.created_at)),
    }) });
  const { branches } = useBranch();
  const branchOf = (id?: string) => (q.all && id ? branches.find((b) => b.id === id)?.name_ar ?? "" : "");
  const { tickets, rooms, handoffs } = q.data;
  const branchId = q.branchId;
  const load = q.reload;

  useEffect(() => {
    const ch = supabase
      .channel("tickets-rt")
      .on("postgres_changes", { event: "*", schema: "public", table: "human_handoff_tickets" }, () => load())
      .on("postgres_changes", { event: "*", schema: "public", table: "maintenance_tickets" }, () => load())
      .subscribe();
    return () => { supabase.removeChannel(ch); };
  }, [load]);

  async function resolveMaintenance(id: string) {
    setActing(id); setError(null);
    try { await staffApi.resolveMaintenance(id); load(); }
    catch (e) { setError(toArabicError(e)); }
    finally { setActing(null); }
  }

  async function resolveHandoff(id: string) {
    setActing(id); setError(null);
    try { await staffApi.resolveTicket(id); load(); }
    catch (e) { setError(toArabicError(e)); }
    finally { setActing(null); }
  }

  async function createTicket(e: React.FormEvent) {
    e.preventDefault();
    setFormError(null);
    const fe: { room?: string; title?: string } = {};
    if (!newRoom) fe.room = "اختر الوحدة.";
    if (!newTitle.trim()) fe.title = "اكتب عنوان البلاغ.";
    setFieldErr(fe);
    if (fe.room || fe.title) { setFormError(null); window.setTimeout(() => document.querySelector<HTMLElement>("[data-ticket-form] [aria-invalid=true]")?.focus(), 0); return; }
    // 6.7 (U7): the lock is a ref, not only the acting state — two submits in the same tick create one ticket
    if (creatingRef.current) return;
    creatingRef.current = true;
    setActing("create");
    try {
      await staffApi.createMaintenance(newRoom, newTitle.trim(), newDesc.trim() || null);
      setNewTitle(""); setNewDesc(""); setNewRoom(""); setFieldErr({}); setShowForm(false);
      load();
    } catch (err) {
      setFormError(toArabicError(err));
    } finally {
      creatingRef.current = false;
      setActing(null);
    }
  }

  if (q.loading) return <LoadingScreen />;
  if (q.error && tickets.length === 0) return <LoadErrorCard message={q.error} onRetry={load} />;

  const dupOpen = newRoom ? tickets.filter((t) => t.room_id === newRoom && t.status !== "resolved") : [];
  const openMaint = tickets.filter((t) => t.status !== "resolved").length;
  const openHandoff = handoffs.filter((h) => h.status !== "resolved").length;

  return (
    <div className="space-y-8">
      {(error || q.error) && <ErrorBanner message={(error ?? q.error) as string} />}
      {!branchId && <ErrorBanner message="لا يوجد فرع مرتبط بحسابك." />}

      {canSeeHandoff && (
        <section>
          <SectionTitle title="طلبات التحويل لموظف" subtitle={`طلبات مفتوحة: ${openHandoff}`} />
          {handoffs.length === 0 ? (
            <EmptyState icon={<LifeBuoy className="h-10 w-10" />} title="لا توجد طلبات تدخل" description="تظهر هنا الحالات التي أحالها المساعد الذكي إلى موظف." />
          ) : (
            <div className="space-y-3">
              {handoffs.map((h) => (
                <Card key={h.id} className="flex flex-wrap items-center justify-between gap-3">
                  <div className="flex items-start gap-3">
                    <LifeBuoy className={`mt-0.5 h-5 w-5 ${h.status === "resolved" ? "text-success-600" : "text-brand-600"}`} />
                    <div>
                      <div className="flex flex-wrap items-center gap-2">
                        <Badge className={KIND_COLORS[h.kind] ?? "bg-ink-100 text-ink-600"}>{KIND_LABELS[h.kind] ?? "طلب آخر"}</Badge>
                        <Badge className={h.status === "resolved" ? "bg-success-500/10 text-success-600" : "bg-ink-100 text-ink-500"}>{HANDOFF_STATUS[h.status] ?? h.status}</Badge>
                      </div>
                      <p className="mt-1 text-xs text-ink-500">
                        {h.external_ref && <span dir="ltr">مرجع: {h.external_ref}</span>}
                        {h.external_ref && h.source_name && " · "}
                        {h.source_name && <span>المصدر: {h.source_name}</span>}
                      </p>
                      {h.details && <p className="mt-1 text-xs text-ink-400">{detailsText(h.details)}</p>}
                      <p className="mt-1 text-xs text-ink-400">
                        {branchOf(h.branch_id) && <span data-testid="ticket-branch">{branchOf(h.branch_id)} · </span>}{formatDateTime(h.created_at)}
                        {h.reservation_id && <> · <Link to={`/staff/reservations/${h.reservation_id}`} className="inline-flex min-h-[44px] items-center text-brand-600 hover:underline">فتح الحجز</Link></>}
                        {h.conversation_id && <> · <Link to="/staff/inbox" className="inline-flex min-h-[44px] items-center text-brand-600 hover:underline">المحادثة</Link></>}
                      </p>
                    </div>
                  </div>
                  {h.status !== "resolved" && (
                    <button onClick={() => resolveHandoff(h.id)} disabled={acting === h.id} className="btn-outline text-xs">
                      {acting === h.id ? <Spinner className="h-3.5 w-3.5" /> : <><CheckCircle2 className="h-3.5 w-3.5" /> تم الحل</>}
                    </button>
                  )}
                </Card>
              ))}
            </div>
          )}
        </section>
      )}

      <section>
        <SectionTitle level={2} title="البلاغات والصيانة" subtitle={`بلاغات مفتوحة: ${openMaint}`} action={
          <div className="flex flex-wrap items-center gap-2"><BranchPicker allowAll /><button onClick={() => setShowForm(!showForm)} className="btn-primary text-sm"><Plus className="h-4 w-4" /> بلاغ جديد</button></div>
        } />

        {showForm && (
          <Card className="mb-4">
            <form onSubmit={createTicket} className="space-y-3" data-ticket-form noValidate>
              <Field label="الوحدة" error={fieldErr.room}>
                <select value={newRoom} onChange={(e) => { setNewRoom(e.target.value); setFieldErr((f) => ({ ...f, room: undefined })); }} className="input" aria-invalid={fieldErr.room ? true : undefined}>
                  <option value="">اختيار وحدة</option>
                  {rooms.map((r) => <option key={r.id} value={r.id}>{r.room_number}{branchOf(r.branch_id) ? ` — ${branchOf(r.branch_id)}` : ""}</option>)}
                </select>
              </Field>
              {dupOpen.length > 0 && <p className="rounded-xl bg-rai-warning-tint px-3 py-2 text-sm text-rai-warning" role="status" data-testid="ticket-dup-note">يوجد {dupOpen.length === 1 ? "بلاغ مفتوح" : `${dupOpen.length} بلاغات مفتوحة`} على هذه الوحدة: «{dupOpen[0].title}». يمكنك إنشاء بلاغ جديد إن كان العطل مختلفًا.</p>}
              <Field label="العنوان" error={fieldErr.title}><input value={newTitle} onChange={(e) => { setNewTitle(e.target.value); setFieldErr((f) => ({ ...f, title: undefined })); }} className="input" aria-invalid={fieldErr.title ? true : undefined} /></Field>
              <div><label className="label">الوصف</label><textarea value={newDesc} onChange={(e) => setNewDesc(e.target.value)} className="input" rows={2} /></div>
              {formError && <ErrorBanner message={formError} />}
              <button type="submit" disabled={acting === "create"} className="btn-primary text-sm">
                {acting === "create" ? <Spinner className="h-4 w-4" /> : <Plus className="h-4 w-4" />} إنشاء البلاغ
              </button>
            </form>
          </Card>
        )}

        {tickets.length === 0 ? (
          <EmptyState icon={<Wrench className="h-10 w-10" />} title="لا توجد بلاغات صيانة" />
        ) : (
          <div className="space-y-3">
            {tickets.map((t) => (
              <Card key={t.id} className="flex items-center justify-between gap-3">
                <div className="flex items-center gap-3">
                  <Wrench className={`h-5 w-5 ${t.status === "resolved" ? "text-success-600" : "text-danger-500"}`} />
                  <div>
                    <p className="text-sm font-medium text-ink-800">{t.title}</p>
                    <p className="text-xs text-ink-400">{branchOf(t.branch_id) && <span data-testid="ticket-branch">{branchOf(t.branch_id)} · </span>}وحدة {t.room?.room_number ?? "—"} · {t.status === "resolved" ? "تم الحل" : t.status === "in_progress" ? "قيد المعالجة" : "مفتوح"} · {formatDateTime(t.created_at)}</p>
                    {t.description && <p className="mt-1 text-xs text-ink-500">{t.description}</p>}
                  </div>
                </div>
                {t.status !== "resolved" && can("maintenance.resolve") && (   /* PERM-05 */
                  <button onClick={() => resolveMaintenance(t.id)} disabled={acting === t.id} className="btn-outline text-xs">
                    {acting === t.id ? <Spinner className="h-3.5 w-3.5" /> : "تم الحل"}
                  </button>
                )}
              </Card>
            ))}
          </div>
        )}
      </section>
    </div>
  );
}
