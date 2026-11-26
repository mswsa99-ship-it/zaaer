/**
 * Staff operations copilot: floating panel available on every staff/admin screen.
 *  - Chat answers come from `ai-ops` (model with read-only tools, or deterministic fallback).
 *  - Any action the assistant proposes appears as a card that the staff member must confirm;
 *    confirmation calls fn_ai_ops_execute_proposal → the regular RPC under the user's own role.
 */
import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { Bot, Send, X, Check, XCircle, Sparkles, AlertTriangle } from "lucide-react";
import { useBranch } from "../lib/branch";
import { aiOpsChat, opsApi, toArabicError, type OpsProposal, type OpsReply } from "../lib/api";
import { withTimeout } from "../lib/async";
import { opsLateReplyText } from "../lib/opsLate";
import { Spinner } from "./ui";
import { RoomAiFounding } from "./RoomAiFounding";
import { useAuth } from "../lib/auth";
import "../roomaiFounding.css";

interface Msg { role: "staff" | "assistant"; text: string; mode?: string; proposals?: OpsProposal[]; aiStatus?: string }
interface ProposalState { status: "proposed" | "executing" | "executed" | "rejected" | "failed"; detail?: string }

const ACTION_LABELS: Record<string, string> = { create_task: "إنشاء مهمة", complete_task: "إتمام مهمة", assign_task: "إسناد مهمة", set_cleanliness: "تغيير حالة النظافة", amend_stay: "تغيير المغادرة", switch_room: "تبديل الوحدة", cancel_reservation: "إلغاء حجز", no_show: "عدم حضور", create_receipt: "سند قبض", create_deposit: "قبض تأمين", add_service: "إضافة خدمة", create_invoice: "إصدار فاتورة" };
/** 6.12 (U5): the reply's upper bound (the server's own steps end long before it) and its clear message. */
export const OPS_REPLY_TIMEOUT_MS = 90_000;
const OPS_TIMEOUT_TEXT = "استغرق الرد وقتًا أطول من المعتاد (٩٠ ثانية) دون أن يصل. أعد المحاولة، أو اسأل بصيغة أبسط.";
const SUGGESTIONS = ["ما وضع اليوم؟", "من يصل اليوم ومن لم يكمل الهوية؟", "أي وحدات تحتاج تنظيفًا وعليها وصول اليوم؟", "من عليه رصيد متبقٍ من المقيمين؟", "تأمينات لم تُسوَّ بعد المغادرة"];

export function OpsCopilot() {
  const { branchId, branch } = useBranch();
  const [open, setOpen] = useState(false);
  const [dock, setDock] = useState<HTMLElement | null>(null);
  useEffect(() => {
    const breakpoint = window.matchMedia("(min-width: 1024px)");
    const place = () => setDock(document.getElementById(breakpoint.matches ? "ops-assistant-desktop-dock" : "ops-assistant-phone-dock"));
    place(); breakpoint.addEventListener("change", place);
    return () => breakpoint.removeEventListener("change", place);
  }, []);
  const { profile } = useAuth();
  const canFound = profile?.role === "owner" || profile?.role === "manager";
  const [tab, setTab] = useState<"chat" | "founding">("chat");
  const [msgs, setMsgs] = useState<Msg[]>([]);
  const [conv, setConv] = useState<string | null>(null);
  const [input, setInput] = useState("");
  const [busy, setBusy] = useState(false);
  const [elapsed, setElapsed] = useState(0);
  useEffect(() => {
    if (!busy) { setElapsed(0); return; }
    const t0 = Date.now();
    const timer = window.setInterval(() => setElapsed(Math.floor((Date.now() - t0) / 1000)), 1000);
    return () => window.clearInterval(timer);
  }, [busy]);
  const [props, setProps] = useState<Record<string, ProposalState>>({});
  const endRef = useRef<HTMLDivElement>(null);
  // U10 (6.14): smooth scrolling is motion too — the reduced-motion preference turns it off
  useEffect(() => {
    const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    endRef.current?.scrollIntoView({ behavior: still ? "auto" : "smooth" });
  }, [msgs, open]);
  // U1 (6.11): while the staff member scrolls down a page the floating button shrinks toward the corner so it
  // covers less of what lies under it; it comes back at once on scrolling up, or a moment after the scroll stops.
  // Visual only: the button keeps its place, its size for the layout, and its full keyboard operability.
  const [collapsed, setCollapsed] = useState(false);
  useEffect(() => {
    if (open) { setCollapsed(false); return; }   // the open panel owns the corner; the toggle stays full size
    let timer: number | undefined;
    let lastY = window.scrollY;
    const onScroll = () => {
      const y = window.scrollY;
      if (y > lastY + 4 && y > 96) setCollapsed(true);
      else if (y < lastY - 4) setCollapsed(false);
      lastY = y;
      window.clearTimeout(timer);
      timer = window.setTimeout(() => setCollapsed(false), 700);
    };
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => { window.removeEventListener("scroll", onScroll); window.clearTimeout(timer); };
  }, [open]);
  const epochRef = useRef(0);   // bumped on every branch change: a late reply from an earlier context can never land in a later one, even on return to the same branch
  useEffect(() => { epochRef.current += 1; setConv(null); setMsgs([]); setProps({}); }, [branchId]);   // branch change = new context (G24)
  const branchRef = useRef(branchId);
  branchRef.current = branchId;

  async function send(text: string) {
    if (!branchId || !text.trim() || busy) return;
    const sentFor = branchId;
    const sentEpoch = epochRef.current;
    setMsgs((m) => [...m, { role: "staff", text }]); setInput(""); setBusy(true);
    try {
      // U5: a clear upper bound — the employee is never left watching a spinner; a late reply is ignored
      const pending = aiOpsChat(text, branchId, conv);
      const r = await withTimeout<OpsReply | null>(pending, OPS_REPLY_TIMEOUT_MS, () => null);
      if (branchRef.current !== sentFor || epochRef.current !== sentEpoch) return;   // the branch changed meanwhile: this answer belongs to the old context (G24)
      if (r === null) {
        setMsgs((m) => [...m, { role: "assistant", text: OPS_TIMEOUT_TEXT }]);
        // F1: the original request is still running on the server. Its late reply is kept once (never duplicated, never
        // blocking the input), and its conversation id is adopted if none exists yet so the next question joins it.
        // Limit: a question sent before the late reply lands, in a first conversation, still opens a separate conversation.
        pending.then((late) => {
          if (branchRef.current !== sentFor || epochRef.current !== sentEpoch) return;
          setConv((c) => c ?? late.conversation_id);
          setMsgs((m) => [...m, { role: "assistant", text: opsLateReplyText(text, late), mode: late.mode, aiStatus: late.ai_status }]);
        }, () => { /* a late failure adds nothing: the timeout message was already shown */ });
        return;
      }
      setConv(r.conversation_id);
      setMsgs((m) => [...m, { role: "assistant", text: r.reply, mode: r.mode, proposals: r.proposals, aiStatus: r.ai_status }]);
      for (const p of r.proposals ?? []) setProps((s) => ({ ...s, [p.id]: { status: "proposed" } }));
    } catch (e) {
      if (branchRef.current === sentFor) setMsgs((m) => [...m, { role: "assistant", text: "تعذّر الوصول إلى مساعد العمليات: " + toArabicError(e) }]);
    } finally { setBusy(false); }
  }
  async function decide(p: OpsProposal, ok: boolean) {
    setProps((s) => ({ ...s, [p.id]: { status: "executing" } }));
    try {
      if (ok) { const r = await opsApi.executeProposal(p.id); setProps((s) => ({ ...s, [p.id]: r.ok ? { status: "executed" } : { status: "failed", detail: toArabicError(new Error(r.error ?? "")) } })); }
      else { await opsApi.rejectProposal(p.id); setProps((s) => ({ ...s, [p.id]: { status: "rejected" } })); }
    } catch (e) { setProps((s) => ({ ...s, [p.id]: { status: "failed", detail: toArabicError(e) } })); }
  }

  if (!branchId) return null;
  return (
    <>
      {dock && createPortal(<button onClick={() => setOpen((o) => !o)} data-testid="ops-copilot-fab" data-collapsed={collapsed || undefined} className={`flex h-[44px] w-[44px] lg:w-full origin-center items-center justify-center gap-2 rounded-xl bg-ink-800 text-sm font-medium text-white transition-transform duration-200 ease-out hover:bg-ink-900 motion-reduce:transition-none ${collapsed && !open ? "scale-[0.6]" : ""}`} aria-label="مساعد العمليات" aria-expanded={open}>
        <Bot className="h-5 w-5" /> <span className="hidden lg:inline">مساعد العمليات</span>
      </button>, dock)}
      {open && (
        <div role="dialog" aria-label="مساعد العمليات" className="fixed bottom-[136px] left-5 z-40 flex h-[min(640px,70vh)] lg:bottom-20 w-[min(420px,calc(100vw-2.5rem))] flex-col overflow-hidden rounded-2xl border border-ink-100 bg-white shadow-2xl">
          <div className="flex items-center justify-between border-b border-ink-100 bg-ink-800 px-4 py-3 text-white">
            <div className="flex items-center gap-2"><Bot className="h-5 w-5" /><div className="leading-tight"><p className="text-sm font-semibold">مساعد العمليات</p><p className="text-[11px] text-ink-200">{branch?.name_ar}</p><p className="text-[11px] text-ink-200">للقراءة والاطلاع فقط</p></div></div>
            <button onClick={() => setOpen(false)} className="rounded-lg p-2.5 text-ink-200 hover:bg-white/10 hover:text-white" aria-label="إغلاق المساعد"><X className="h-4 w-4" /></button>
          </div>
          {canFound && <div className="rfo-tabs" role="tablist" aria-label="أقسام المساعد"><button role="tab" className="rfo-tab" aria-selected={tab === "chat"} onClick={() => setTab("chat")}>محادثة</button><button role="tab" className="rfo-tab" aria-selected={tab === "founding"} onClick={() => setTab("founding")} data-testid="ops-tab-founding">تأسيس الفندق</button></div>}
          {canFound && tab === "founding" ? <div className="flex-1 overflow-y-auto p-3 scrollbar-thin"><RoomAiFounding /></div> : <>
          <div className="flex-1 space-y-3 overflow-y-auto p-3 scrollbar-thin" role="log" aria-live="polite" aria-label="المحادثة">
            {msgs.length === 0 && (
              <div className="space-y-2">
                <p className="text-xs text-ink-500">اسأل عن حالة اليوم أو الحجوزات أو الوحدات. المساعد للقراءة والاطلاع فقط: لا ينفّذ إجراءً ولا يعدّل بيانات، وتنفّذ الإجراءات من صفحاتها.</p>
                {SUGGESTIONS.map((s) => <button key={s} onClick={() => send(s)} className="block w-full rounded-xl border border-ink-100 px-3 py-2 text-right text-xs text-ink-700 hover:bg-ink-50">{s}</button>)}
              </div>
            )}
            {msgs.map((m, i) => (
              <div key={i} className={m.role === "staff" ? "flex justify-start" : "flex justify-end"}>
                <div className={`max-w-[92%] whitespace-pre-wrap rounded-2xl px-3 py-2 text-sm leading-relaxed ${m.role === "staff" ? "bg-brand-600 text-white" : "bg-ink-50 text-ink-800"}`}>
                  {m.text}
                  {m.role === "assistant" && m.mode === "deterministic" && <p className="mt-1 flex items-center gap-1 text-[10px] text-ink-400"><AlertTriangle className="h-3 w-3" /> إجابة مباشرة من بيانات النظام (المحرك الذكي {m.aiStatus === "disabled" ? "معطل" : m.aiStatus === "awaiting_credentials" ? "بانتظار المفتاح" : "غير متاح الآن"})</p>}
                  {m.role === "assistant" && m.mode === "ai" && <p className="mt-1 flex items-center gap-1 text-[10px] text-ink-400"><Sparkles className="h-3 w-3" /> مبني على أدوات القراءة فقط</p>}
                  {(m.proposals ?? []).map((p) => {
                    const st = props[p.id]?.status ?? "proposed";
                    return (
                      <div key={p.id} className="mt-2 rounded-xl border border-brand-200 bg-white p-2.5 text-xs">
                        <p className="font-semibold text-brand-700">اقتراح: {ACTION_LABELS[p.action] ?? p.action}</p>
                        <p className="mt-0.5 text-ink-600">{p.summary}</p>
                        {st === "proposed" && <div className="mt-2 flex gap-2"><button onClick={() => decide(p, true)} className="btn-accent px-2.5 py-1 text-[11px]"><Check className="h-3 w-3" /> تأكيد وتنفيذ</button><button onClick={() => decide(p, false)} className="btn-outline px-2.5 py-1 text-[11px]"><XCircle className="h-3 w-3" /> رفض</button></div>}
                        {st === "executing" && <p className="mt-2 flex items-center gap-1 text-ink-400"><Spinner className="h-3 w-3" /> جارٍ التنفيذ بصلاحيتك…</p>}
                        {st === "executed" && <p className="mt-2 text-success-600">✓ نُفذ وسُجل في سجل الإجراءات</p>}
                        {st === "rejected" && <p className="mt-2 text-ink-400">رُفض</p>}
                        {st === "failed" && <p className="mt-2 text-danger-600">لم يُنفذ: {props[p.id]?.detail}</p>}
                      </div>
                    );
                  })}
                </div>
              </div>
            ))}
            {busy && (
              <div className="flex justify-end">
                <div className="flex items-center gap-2 rounded-2xl bg-ink-50 px-3 py-2 text-xs text-ink-500" data-testid="ops-progress" role="status">
                  <Spinner className="h-4 w-4" /> يعمل على سؤالك… <span className="tabular-nums" dir="ltr" data-testid="ops-elapsed">({elapsed} ث)</span>
                </div>
              </div>
            )}
            <div ref={endRef} />
          </div>
          <form onSubmit={(e) => { e.preventDefault(); send(input); }} className="flex gap-2 border-t border-ink-100 p-2">
            <input value={input} onChange={(e) => setInput(e.target.value)} className="input" aria-label="سؤالك أو طلبك" placeholder="اكتب سؤالك أو طلبك…" disabled={busy} />
            <button type="submit" disabled={busy || !input.trim()} className="btn-primary px-3" aria-label="إرسال"><Send className="h-4 w-4" /></button>
          </form>
          </>}
        </div>
      )}
    </>
  );
}
