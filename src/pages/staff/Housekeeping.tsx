import { useEffect, useMemo, useState } from "react";
import { Sparkles, CheckCircle2, Wrench, Play, Plus, UserPlus, XCircle, Landmark, DoorClosed, ClipboardCheck } from "lucide-react";
import { supabase } from "../../lib/supabase";
import { useAuth } from "../../lib/auth";
import { staffApi, opsApi, stayApi, toArabicError } from "../../lib/api";
import { SectionTitle, LoadingScreen, EmptyState, Card, Spinner, ErrorBanner, Badge, LoadErrorCard } from "../../components/ui";
import { useBranchQuery, must } from "../../lib/useBranchQuery";
import { Modal, Field, ActionForm, Submit, ReasonInput, MoneyInput } from "../../components/forms";
import { BranchPicker } from "../../components/BranchPicker";
import { ROOM_STATUS_LABELS, ROOM_STATUS_COLORS, CLEANLINESS_LABELS, CLEANLINESS_COLORS, TASK_STATUS_LABELS, TASK_PRIORITY_LABELS, type RoomStatus } from "../../lib/types";
import { formatDateTime } from "../../lib/utils";

interface Task { id: string; status: string; priority: string; room_id: string | null; facility_id: string | null; reservation_id: string | null; task_type_name_snapshot: string; assignee_id: string | null; scheduled_start: string; scheduled_end: string | null; description: string | null; created_at: string; version: number; room?: { room_number: string; status: RoomStatus; cleanliness: string } | null; facility?: { name: string } | null; assignee?: { full_name: string } | null }
interface RoomLite { id: string; room_number: string; status: RoomStatus; cleanliness: string }
interface Opt { id: string; name: string }
interface HkData { tasks: Task[]; rooms: RoomLite[]; facilities: Opt[]; types: Opt[]; staff: Opt[]; inspected: Record<string, "ok" | "notes"> }
const NO_HK: HkData = { tasks: [], rooms: [], facilities: [], types: [], staff: [], inspected: {} };
/** the cleaning a departure creates: its inspection is recorded from the task (decision 5) */
const DEPARTURE_CLEANING = "تنظيف بعد المغادرة";
/** the local clock as a datetime-local value (minutes), and back to an instant */
const localNow = () => { const d = new Date(); d.setSeconds(0, 0); const p = (n: number) => String(n).padStart(2, "0"); return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`; };
const toIso = (local: string) => new Date(local).toISOString();

export default function Housekeeping() {
  const { profile, can } = useAuth();
  const role = profile?.role;
  const canManage = can("task.manage");

  const [acting, setActing] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null); const [notice, setNotice] = useState<string | null>(null);
  const [view, setView] = useState<"open" | "done" | "board">("open");
  // decision 28: the task's start (required, «الآن» by default) and its end (optional); no reminder, no automatic end
  const [create, setCreate] = useState<null | { target: "room" | "facility"; room_id?: string; facility_id?: string; task_type_id?: string; priority: string; assignee_id?: string; description?: string; scheduled_start: string; scheduled_end: string }>(null);
  const [cancelTask, setCancelTask] = useState<Task | null>(null); const [cancelReason, setCancelReason] = useState("");
  const [assignTask, setAssignTask] = useState<Task | null>(null); const [assignee, setAssignee] = useState("");
  const [maintTarget, setMaintTarget] = useState<RoomLite | null>(null); const [maintTitle, setMaintTitle] = useState(""); const [maintDesc, setMaintDesc] = useState("");

  // G24: everything on this screen belongs to the active branch; a late answer for another branch is dropped
  const hk = useBranchQuery<HkData>(async (branchId) => {
    const [t, r, f, tt, s, ins] = await Promise.all([
      supabase.from("housekeeping_tasks").select("id, status, priority, room_id, facility_id, reservation_id, task_type_name_snapshot, assignee_id, scheduled_start, scheduled_end, description, created_at, version, room:rooms(room_number, status, cleanliness), facility:facilities(name), assignee:staff_profiles!housekeeping_tasks_assignee_id_fkey(full_name)").eq("branch_id", branchId).order("created_at", { ascending: false }).limit(300),
      supabase.from("rooms").select("id, room_number, status, cleanliness").eq("branch_id", branchId).eq("is_active", true).is("archived_at", null).order("room_number"),
      supabase.from("facilities").select("id, name").eq("branch_id", branchId).eq("is_active", true).is("archived_at", null).order("name"),
      supabase.from("task_types").select("id, name, code").eq("branch_id", branchId).eq("is_active", true).is("archived_at", null).order("name"),
      supabase.from("staff_profiles").select("id, full_name, role").eq("is_active", true),
      supabase.from("checkout_inspections").select("reservation_id, result").eq("branch_id", branchId).eq("status", "active"),
    ]);
    return {
      tasks: must(t) as unknown as Task[], rooms: must(r) as RoomLite[], facilities: must(f) as Opt[], types: must(tt) as Opt[],
      staff: (must(s) as { id: string; full_name: string }[]).map((x) => ({ id: x.id, name: x.full_name })),
      inspected: Object.fromEntries(((ins.data ?? []) as { reservation_id: string; result: "ok" | "notes" }[]).map((x) => [x.reservation_id, x.result])),
    };
  }, [], NO_HK);
  const { tasks, rooms, facilities, types, staff, inspected } = hk.data;
  const [inspect, setInspect] = useState<Task | null>(null); const [inspResult, setInspResult] = useState<"ok" | "notes">("ok"); const [inspNotes, setInspNotes] = useState(""); const [inspSuggested, setInspSuggested] = useState<number | null>(null);
  const { reload } = hk;
  useEffect(() => {
    const ch = supabase.channel("hk-rt").on("postgres_changes", { event: "*", schema: "public", table: "housekeeping_tasks" }, () => reload()).on("postgres_changes", { event: "*", schema: "public", table: "rooms" }, () => reload()).subscribe();
    return () => { supabase.removeChannel(ch); };
  }, [reload]);

  const act = async (key: string, fn: () => Promise<string | void>) => { setActing(key); setError(null); setNotice(null); try { const n = await fn(); if (n) setNotice(n); reload(); } catch (e) { setError(toArabicError(e)); } finally { setActing(null); } };
  const openTasks = useMemo(() => tasks.filter((t) => t.status === "pending" || t.status === "in_progress"), [tasks]);
  const doneTasks = useMemo(() => tasks.filter((t) => t.status === "completed" || t.status === "cancelled").slice(0, 60), [tasks]);
  const mine = (t: Task) => role !== "housekeeping" || !t.assignee_id || t.assignee_id === profile?.id;

  if (hk.loading) return <LoadingScreen />;
  if (hk.error && tasks.length === 0 && rooms.length === 0) return <div><SectionTitle title="خدمة الغرف والمرافق" action={<BranchPicker />} /><LoadErrorCard message={hk.error} onRetry={reload} /></div>;
  return (
    <div>
      <SectionTitle title="خدمة الغرف والمرافق" subtitle={`${openTasks.length} مهمة مفتوحة · ${rooms.filter((r) => r.cleanliness !== "clean").length} وحدة تحتاج تنظيفًا`} action={
        <div className="flex flex-wrap items-center gap-2"><BranchPicker /><button onClick={() => setCreate({ target: "room", priority: "medium", task_type_id: types[0]?.id, room_id: rooms[0]?.id, scheduled_start: localNow(), scheduled_end: "" })} className="btn-primary text-sm"><Plus className="h-4 w-4" /> مهمة جديدة</button></div>} />
      {(error || hk.error) && <div className="mb-4"><ErrorBanner message={(error ?? hk.error) as string} /></div>}
      {notice && <div className="mb-4 rounded-xl border border-success-500/30 bg-success-500/10 px-4 py-3 text-sm text-success-600">{notice}</div>}
      <div className="mb-4 flex gap-1 rounded-xl bg-ink-100 p-1 text-sm w-fit">
        {(["open", "board", "done"] as const).map((v) => <button key={v} onClick={() => setView(v)} className={`rounded-lg px-4 py-1.5 ${view === v ? "bg-white font-medium text-ink-800 shadow-sm" : "text-ink-500"}`}>{v === "open" ? "المهام المفتوحة" : v === "board" ? "حالة الوحدات" : "المنجزة"}</button>)}
      </div>

      {view === "open" && (openTasks.length === 0 ? <EmptyState icon={<Sparkles className="h-10 w-10" />} title="لا مهام مفتوحة" description="تُنشأ مهام التنظيف تلقائيًا بعد المغادرة، ويمكن إنشاء مهام للوحدات والمرافق يدويًا." /> : (
        <div className="space-y-3">
          {openTasks.map((t) => (
            <Card key={t.id} className="flex flex-wrap items-center justify-between gap-3">
              <div className="flex items-center gap-3">
                {t.room_id ? <DoorClosed className="h-5 w-5 text-brand-600" /> : <Landmark className="h-5 w-5 text-accent-600" />}
                <div>
                  <p className="text-sm font-medium text-ink-800">{t.room ? `وحدة ${t.room.room_number}` : t.facility?.name ?? "مرفق"} <span className="font-normal text-ink-500">· {t.task_type_name_snapshot}</span></p>
                  <p className="mt-0.5 flex flex-wrap items-center gap-1.5 text-xs text-ink-400">
                    <Badge className={t.priority === "high" ? "bg-danger-500/10 text-danger-600" : t.priority === "low" ? "bg-ink-100 text-ink-500" : "bg-warning-500/10 text-warning-600"}>{TASK_PRIORITY_LABELS[t.priority]}</Badge>
                    <Badge className={t.status === "in_progress" ? "bg-warning-500/10 text-warning-600" : "bg-ink-100 text-ink-500"}>{TASK_STATUS_LABELS[t.status]}</Badge>
                    {t.room && <Badge className={ROOM_STATUS_COLORS[t.room.status]}>{ROOM_STATUS_LABELS[t.room.status]}</Badge>}
                    <span>{t.assignee?.full_name ?? "غير مسندة"} · البداية {formatDateTime(t.scheduled_start)}{t.scheduled_end && <span data-testid="task-end"> · النهاية {formatDateTime(t.scheduled_end)}</span>}</span>
                  </p>
                  {t.description && <p className="mt-0.5 text-xs text-ink-500">{t.description}</p>}
                  {t.reservation_id && t.description === DEPARTURE_CLEANING && inspected[t.reservation_id] && <p className="mt-0.5 text-xs text-success-600">فُحصت المغادرة: {inspected[t.reservation_id] === "ok" ? "الوحدة سليمة" : "بملاحظات"}</p>}
                </div>
              </div>
              <div className="flex flex-wrap gap-2">
                {canManage && <button onClick={() => { setAssignTask(t); setAssignee(t.assignee_id ?? ""); }} className="btn-ghost text-xs"><UserPlus className="h-3.5 w-3.5" /> إسناد</button>}
                {t.room && t.reservation_id && t.description === DEPARTURE_CLEANING && !inspected[t.reservation_id] && <button onClick={() => { setInspect(t); setInspResult("ok"); setInspNotes(""); setInspSuggested(null); }} className="btn-outline text-xs"><ClipboardCheck className="h-3.5 w-3.5" /> فحص المغادرة</button>}
                {t.room && <button onClick={() => { setMaintTarget({ id: t.room_id!, room_number: t.room!.room_number, status: t.room!.status, cleanliness: t.room!.cleanliness }); setMaintTitle(""); setMaintDesc(""); }} className="btn-outline text-xs"><Wrench className="h-3.5 w-3.5" /> بلاغ صيانة</button>}
                {t.status === "pending" && mine(t) && <button onClick={() => act(t.id, async () => { await opsApi.startTask(t.id); })} disabled={acting === t.id} className="btn-outline text-xs"><Play className="h-3.5 w-3.5" /> بدء</button>}
                {mine(t) && <button onClick={() => act(t.id, async () => { const r = await opsApi.completeTask(t.id, undefined, t.version); return r.room_status ? `تم الإتمام. حالة الوحدة الآن: ${ROOM_STATUS_LABELS[r.room_status as RoomStatus] ?? r.room_status} (الإشغال لا يتغير بالتنظيف)` : "تم الإتمام."; })} disabled={acting === t.id} className="btn-accent text-xs">{acting === t.id ? <Spinner className="h-3.5 w-3.5" /> : <CheckCircle2 className="h-3.5 w-3.5" />} إتمام</button>}
                {canManage && <button onClick={() => { setCancelTask(t); setCancelReason(""); }} className="btn-ghost text-xs text-danger-600"><XCircle className="h-3.5 w-3.5" /></button>}
              </div>
            </Card>
          ))}
        </div>
      ))}

      {view === "board" && (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          {rooms.map((r) => (
            <Card key={r.id}>
              <div className="flex items-start justify-between"><p className="font-semibold text-ink-800">{r.room_number}</p><Badge className={ROOM_STATUS_COLORS[r.status]}>{ROOM_STATUS_LABELS[r.status]}</Badge></div>
              <div className="mt-2 flex items-center justify-between">
                <Badge className={CLEANLINESS_COLORS[r.cleanliness]}>الحالة الحالية: {CLEANLINESS_LABELS[r.cleanliness]}</Badge>
                {r.cleanliness === "clean" ? <button onClick={() => act("c" + r.id, async () => { await opsApi.setCleanliness(r.id, "dirty", "علامة يدوية"); })} className="btn-ghost px-2 py-1 text-[11px]">وضع علامة متسخة</button>
                  : <button onClick={() => act("c" + r.id, async () => { const x = await opsApi.setCleanliness(r.id, "clean", "علامة يدوية"); return `الوحدة الآن ${ROOM_STATUS_LABELS[x.room_status as RoomStatus] ?? x.room_status}`; })} className="btn-ghost px-2 py-1 text-[11px]">وضع علامة نظيفة</button>}
              </div>
            </Card>
          ))}
        </div>
      )}

      {view === "done" && (doneTasks.length === 0 ? <EmptyState icon={<CheckCircle2 className="h-10 w-10" />} title="لا مهام منجزة بعد" /> : (
        <div className="space-y-2">{doneTasks.map((t) => <div key={t.id} className="card flex items-center justify-between px-4 py-2 text-sm"><span>{t.room ? `وحدة ${t.room.room_number}` : t.facility?.name} · {t.task_type_name_snapshot} · {t.assignee?.full_name ?? "—"}</span><Badge className={t.status === "completed" ? "bg-success-500/10 text-success-600" : "bg-ink-100 text-ink-500"}>{TASK_STATUS_LABELS[t.status]}</Badge></div>)}</div>
      ))}

      {/* create task */}
      <Modal open={!!create} title="مهمة جديدة" onClose={() => setCreate(null)}>
        {create && (
          <ActionForm onSubmit={async () => { if (!create.scheduled_start) throw new Error("VALIDATION: schedule_start"); if (create.scheduled_end && create.scheduled_end < create.scheduled_start) throw new Error("VALIDATION: schedule"); await opsApi.createTask({ room_id: create.target === "room" ? create.room_id : null, facility_id: create.target === "facility" ? create.facility_id : null, task_type_id: create.task_type_id, priority: create.priority, assignee_id: create.assignee_id || null, description: create.description || null, scheduled_start: toIso(create.scheduled_start), scheduled_end: create.scheduled_end ? toIso(create.scheduled_end) : null }); setCreate(null); reload(); }}>
            <div className="space-y-3">
              <div className="grid grid-cols-2 gap-2">
                <button type="button" onClick={() => setCreate({ ...create, target: "room", room_id: rooms[0]?.id })} className={`rounded-xl border px-3 py-2 text-sm ${create.target === "room" ? "border-brand-400 bg-brand-50 text-brand-700" : "border-ink-100"}`}>وحدة</button>
                <button type="button" onClick={() => setCreate({ ...create, target: "facility", facility_id: facilities[0]?.id })} className={`rounded-xl border px-3 py-2 text-sm ${create.target === "facility" ? "border-brand-400 bg-brand-50 text-brand-700" : "border-ink-100"}`}>مرفق</button>
              </div>
              {create.target === "room" ? <Field label="الوحدة"><select className="input" value={create.room_id ?? ""} onChange={(e) => setCreate({ ...create, room_id: e.target.value })}>{rooms.map((r) => <option key={r.id} value={r.id}>{r.room_number} · {CLEANLINESS_LABELS[r.cleanliness]}</option>)}</select></Field>
                : <Field label="المرفق" hint={facilities.length === 0 ? "لا توجد مرافق فعالة" : undefined}><select className="input" value={create.facility_id ?? ""} onChange={(e) => setCreate({ ...create, facility_id: e.target.value })}>{facilities.map((f) => <option key={f.id} value={f.id}>{f.name}</option>)}</select></Field>}
              <Field label="نوع المهمة"><select className="input" value={create.task_type_id ?? ""} onChange={(e) => setCreate({ ...create, task_type_id: e.target.value })}>{types.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}</select></Field>
              <div className="grid grid-cols-2 gap-3">
                <Field label="الأولوية"><select className="input" value={create.priority} onChange={(e) => setCreate({ ...create, priority: e.target.value })}>{Object.entries(TASK_PRIORITY_LABELS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></Field>
                <Field label="الموكل إليه"><select className="input" value={create.assignee_id ?? ""} onChange={(e) => setCreate({ ...create, assignee_id: e.target.value })}><option value="">غير مسندة</option>{staff.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></Field>
              </div>
              <div className="grid grid-cols-2 gap-3">
                <Field label="البداية" hint="مطلوبة؛ الآن افتراضيًا"><input type="datetime-local" className="input" dir="ltr" value={create.scheduled_start} onChange={(e) => setCreate({ ...create, scheduled_start: e.target.value })} aria-label="البداية" data-testid="task-start" required /></Field>
                <Field label="النهاية (اختياري)" hint="لا تنبيه عند تجاوزها ولا إنهاء تلقائي"><input type="datetime-local" className="input" dir="ltr" value={create.scheduled_end} onChange={(e) => setCreate({ ...create, scheduled_end: e.target.value })} aria-label="النهاية" data-testid="task-end-input" /></Field>
              </div>
              <Field label="وصف"><textarea className="input" rows={2} value={create.description ?? ""} onChange={(e) => setCreate({ ...create, description: e.target.value })} /></Field>
            </div>
            <Submit label="إنشاء" onCancel={() => setCreate(null)} />
          </ActionForm>
        )}
      </Modal>
      <Modal open={!!assignTask} title="إسناد المهمة" onClose={() => setAssignTask(null)}>
        <ActionForm onSubmit={async () => { if (assignTask) await opsApi.assignTask(assignTask.id, assignee || null); setAssignTask(null); reload(); }}>
          <Field label="الموظف (عضو فعال في الفرع)"><select className="input" value={assignee} onChange={(e) => setAssignee(e.target.value)}><option value="">غير مسندة</option>{staff.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></Field>
          <Submit label="حفظ" onCancel={() => setAssignTask(null)} />
        </ActionForm>
      </Modal>
      <Modal open={!!cancelTask} title="إلغاء المهمة" onClose={() => setCancelTask(null)}>
        <ActionForm onSubmit={async () => { if (!cancelReason.trim()) throw new Error("VALIDATION: reason"); if (cancelTask) await opsApi.cancelTask(cancelTask.id, cancelReason.trim()); setCancelTask(null); reload(); }}>
          <ReasonInput value={cancelReason} onChange={setCancelReason} />
          <Submit label="إلغاء المهمة" onCancel={() => setCancelTask(null)} danger />
        </ActionForm>
      </Modal>
      <Modal open={!!inspect} title={`فحص المغادرة · وحدة ${inspect?.room?.room_number ?? ""}`} onClose={() => setInspect(null)}>
        <ActionForm onSubmit={async () => {
          if (!inspect?.reservation_id) return;
          if (inspResult === "notes" && !inspNotes.trim()) throw new Error("VALIDATION: inspection_notes");
          await stayApi.inspect({ reservation_id: inspect.reservation_id, result: inspResult, notes: inspNotes.trim() || undefined, suggested_deduction_halalas: inspResult === "notes" && inspSuggested && inspSuggested > 0 ? inspSuggested : undefined });
          setInspect(null); setNotice("سُجِّل فحص المغادرة؛ يُرد التأمين بعده."); reload();
        }}>
          <div className="space-y-3">
            <div className="grid grid-cols-2 gap-2" role="radiogroup" aria-label="نتيجة الفحص">
              {(["ok", "notes"] as const).map((v) => <button key={v} type="button" role="radio" aria-checked={inspResult === v} onClick={() => setInspResult(v)} className={`rounded-xl border px-3 py-2 text-sm ${inspResult === v ? "border-brand-400 bg-brand-50 text-brand-700" : "border-ink-100"}`}>{v === "ok" ? "الوحدة سليمة" : "بملاحظات"}</button>)}
            </div>
            {inspResult === "notes" && <>
              <Field label="الملاحظات (إلزامية)"><textarea className="input" rows={2} value={inspNotes} onChange={(e) => setInspNotes(e.target.value)} placeholder="ما الذي وُجد في الوحدة؟" /></Field>
              <Field label="خصم مقترح من التأمين (اختياري)" hint="يقرّره من يسوّي التأمين في الاستقبال."><MoneyInput valueHalalas={inspSuggested} onChange={setInspSuggested} /></Field>
            </>}
          </div>
          <Submit label="حفظ الفحص" onCancel={() => setInspect(null)} />
        </ActionForm>
      </Modal>
      <Modal open={!!maintTarget} title={`بلاغ صيانة · وحدة ${maintTarget?.room_number ?? ""}`} onClose={() => setMaintTarget(null)}>
        <ActionForm onSubmit={async () => { if (!maintTitle.trim()) throw new Error("VALIDATION: title"); if (maintTarget) await staffApi.createMaintenance(maintTarget.id, maintTitle.trim(), maintDesc.trim() || null); setMaintTarget(null); setNotice("تم فتح بلاغ الصيانة؛ الوحدة الآن خارج التسكين حتى الإغلاق."); reload(); }}>
          <div className="space-y-3"><Field label="العنوان"><input className="input" value={maintTitle} onChange={(e) => setMaintTitle(e.target.value)} placeholder="مثال: تسريب في الحمام" /></Field><Field label="الوصف"><textarea className="input" rows={2} value={maintDesc} onChange={(e) => setMaintDesc(e.target.value)} /></Field></div>
          <Submit label="إنشاء البلاغ" onCancel={() => setMaintTarget(null)} />
        </ActionForm>
      </Modal>
    </div>
  );
}
