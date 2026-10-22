import { useEffect, useState, useCallback } from "react";
import { Link } from "react-router-dom";
import { supabase } from "../../lib/supabase";
import { useAuth } from "../../lib/auth";
import { useBranch } from "../../lib/branch";
import { staffApi, toArabicError } from "../../lib/api";
import { SectionTitle, LoadingScreen, EmptyState, Card, Spinner, ErrorBanner, Badge } from "../../components/ui";
import { Wrench, Plus, LifeBuoy, CheckCircle2 } from "lucide-react";
import { formatDateTime } from "../../lib/utils";

interface Ticket {
  id: string;
  title: string;
  description: string | null;
  status: string;
  room_id: string;
  room?: { room_number: string } | null;
  created_at: string;
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
}

const KIND_LABELS: Record<string, string> = {
  unmatched_reservation: "حجز غير مطابق",
  assistance: "طلب مساعدة بشرية",
  escalation: "تصعيد",
  ai_guardrail: "حماية الذكاء الاصطناعي",
  ai_fallback: "تعطل المساعد",
};

const KIND_COLORS: Record<string, string> = {
  unmatched_reservation: "bg-warning-500/10 text-warning-600",
  assistance: "bg-brand-50 text-brand-700",
  escalation: "bg-danger-500/10 text-danger-600",
  ai_guardrail: "bg-danger-500/10 text-danger-600",
  ai_fallback: "bg-ink-100 text-ink-600",
};

const HANDOFF_STATUS: Record<string, string> = { open: "مفتوح", in_progress: "قيد المعالجة", resolved: "تم الحل" };

function detailsText(d: Record<string, unknown> | null): string {
  if (!d) return "";
  const parts: string[] = [];
  for (const [k, v] of Object.entries(d)) {
    if (v === null || v === undefined || v === "") continue;
    parts.push(`${k}: ${typeof v === "string" ? v : JSON.stringify(v)}`);
  }
  return parts.join(" · ").slice(0, 300);
}

export default function Tickets() {
  const { profile } = useAuth();
  const { branchId, loading: branchLoading } = useBranch();
  const canSeeHandoff = profile?.role === "owner" || profile?.role === "manager" || profile?.role === "supervisor";

  const [tickets, setTickets] = useState<Ticket[]>([]);
  const [handoffs, setHandoffs] = useState<HandoffTicket[]>([]);
  const [loading, setLoading] = useState(true);
  const [acting, setActing] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [showForm, setShowForm] = useState(false);
  const [rooms, setRooms] = useState<{ id: string; room_number: string }[]>([]);
  const [newTitle, setNewTitle] = useState("");
  const [newDesc, setNewDesc] = useState("");
  const [newRoom, setNewRoom] = useState("");
  const [formError, setFormError] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!branchId) { setTickets([]); setHandoffs([]); setRooms([]); setLoading(false); return; }
    const [t, r, h] = await Promise.all([
      supabase.from("maintenance_tickets").select("id, title, description, status, room_id, room:rooms(room_number), created_at").eq("branch_id", branchId).order("created_at", { ascending: false }),
      supabase.from("rooms").select("id, room_number").eq("branch_id", branchId).order("room_number"),
      supabase.from("human_handoff_tickets").select("id, kind, external_ref, source_name, details, status, created_at, reservation_id, conversation_id").eq("branch_id", branchId).order("created_at", { ascending: false }).limit(100),
    ]);
    if (t.error) setError(toArabicError(t.error));
    setTickets((t.data as unknown as Ticket[]) ?? []);
    setRooms((r.data as { id: string; room_number: string }[]) ?? []);
    setHandoffs(h.error ? [] : ((h.data as HandoffTicket[]) ?? []));
    setLoading(false);
  }, [branchId]);

  useEffect(() => { load(); }, [load]);

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
    try { await staffApi.resolveMaintenance(id); await load(); }
    catch (e) { setError(toArabicError(e)); }
    finally { setActing(null); }
  }

  async function resolveHandoff(id: string) {
    setActing(id); setError(null);
    try { await staffApi.resolveTicket(id); await load(); }
    catch (e) { setError(toArabicError(e)); }
    finally { setActing(null); }
  }

  async function createTicket(e: React.FormEvent) {
    e.preventDefault();
    setFormError(null);
    if (!newTitle.trim() || !newRoom) { setFormError("العنوان والغرفة مطلوبة."); return; }
    setActing("create");
    try {
      await staffApi.createMaintenance(newRoom, newTitle.trim(), newDesc.trim() || null);
      setNewTitle(""); setNewDesc(""); setNewRoom(""); setShowForm(false);
      await load();
    } catch (err) {
      setFormError(toArabicError(err));
    } finally {
      setActing(null);
    }
  }

  if (loading || branchLoading) return <LoadingScreen />;

  const openMaint = tickets.filter((t) => t.status !== "resolved").length;
  const openHandoff = handoffs.filter((h) => h.status !== "resolved").length;

  return (
    <div className="space-y-8">
      {error && <ErrorBanner message={error} />}
      {!branchId && <ErrorBanner message="لا يوجد فرع مرتبط بحسابك." />}

      {canSeeHandoff && (
        <section>
          <SectionTitle title="طلبات التدخل البشري" subtitle={`${openHandoff} طلب مفتوح`} />
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
                        <Badge className={KIND_COLORS[h.kind] ?? "bg-ink-100 text-ink-600"}>{KIND_LABELS[h.kind] ?? h.kind}</Badge>
                        <Badge className={h.status === "resolved" ? "bg-success-500/10 text-success-600" : "bg-ink-100 text-ink-500"}>{HANDOFF_STATUS[h.status] ?? h.status}</Badge>
                      </div>
                      <p className="mt-1 text-xs text-ink-500">
                        {h.external_ref && <span dir="ltr">مرجع: {h.external_ref}</span>}
                        {h.external_ref && h.source_name && " · "}
                        {h.source_name && <span>المصدر: {h.source_name}</span>}
                      </p>
                      {h.details && <p className="mt-1 text-xs text-ink-400">{detailsText(h.details)}</p>}
                      <p className="mt-1 text-xs text-ink-400">
                        {formatDateTime(h.created_at)}
                        {h.reservation_id && <> · <Link to={`/staff/reservations/${h.reservation_id}`} className="text-brand-600 hover:underline">فتح الحجز</Link></>}
                        {h.conversation_id && <> · <Link to="/staff/inbox" className="text-brand-600 hover:underline">المحادثة</Link></>}
                      </p>
                    </div>
                  </div>
                  {h.status !== "resolved" && (
                    <button onClick={() => resolveHandoff(h.id)} disabled={acting === h.id} className="btn-outline text-xs">
                      {acting === h.id ? <Spinner className="h-3.5 w-3.5" /> : <><CheckCircle2 className="h-3.5 w-3.5" /> تحديد كمحلول</>}
                    </button>
                  )}
                </Card>
              ))}
            </div>
          )}
        </section>
      )}

      <section>
        <SectionTitle title="البلاغات والصيانة" subtitle={`${openMaint} بلاغ مفتوح`} action={
          <button onClick={() => setShowForm(!showForm)} className="btn-primary text-sm"><Plus className="h-4 w-4" /> بلاغ جديد</button>
        } />

        {showForm && (
          <Card className="mb-4">
            <form onSubmit={createTicket} className="space-y-3">
              <div><label className="label">الغرفة</label>
                <select value={newRoom} onChange={(e) => setNewRoom(e.target.value)} className="input">
                  <option value="">اختر غرفة</option>
                  {rooms.map((r) => <option key={r.id} value={r.id}>{r.room_number}</option>)}
                </select>
              </div>
              <div><label className="label">العنوان</label><input value={newTitle} onChange={(e) => setNewTitle(e.target.value)} className="input" /></div>
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
                    <p className="text-xs text-ink-400">غرفة {t.room?.room_number ?? "—"} · {t.status === "resolved" ? "تم الحل" : t.status === "in_progress" ? "قيد المعالجة" : "مفتوح"} · {formatDateTime(t.created_at)}</p>
                    {t.description && <p className="mt-1 text-xs text-ink-500">{t.description}</p>}
                  </div>
                </div>
                {t.status !== "resolved" && (
                  <button onClick={() => resolveMaintenance(t.id)} disabled={acting === t.id} className="btn-outline text-xs">
                    {acting === t.id ? <Spinner className="h-3.5 w-3.5" /> : "تحديد كمحلول"}
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
