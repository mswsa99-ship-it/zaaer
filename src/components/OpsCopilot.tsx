/**
 * Staff operations copilot: floating panel available on every staff/admin screen.
 *  - Chat answers come from `ai-ops` (model with read-only tools, or deterministic fallback).
 *  - Any action the assistant proposes appears as a card that the staff member must confirm;
 *    confirmation calls fn_ai_ops_execute_proposal → the regular RPC under the user's own role.
 */
import { useEffect, useRef, useState } from "react";
import { Bot, Send, X, Check, XCircle, Sparkles, AlertTriangle } from "lucide-react";
import { useBranch } from "../lib/branch";
import { aiOpsChat, opsApi, toArabicError, type OpsProposal } from "../lib/api";
import { Spinner } from "./ui";

interface Msg { role: "staff" | "assistant"; text: string; mode?: string; proposals?: OpsProposal[]; aiStatus?: string }
interface ProposalState { status: "proposed" | "executing" | "executed" | "rejected" | "failed"; detail?: string }

const ACTION_LABELS: Record<string, string> = { create_task: "إنشاء مهمة", complete_task: "إتمام مهمة", assign_task: "إسناد مهمة", set_cleanliness: "تغيير حالة النظافة", amend_stay: "تغيير المغادرة", switch_room: "تبديل الوحدة", cancel_reservation: "إلغاء حجز", no_show: "عدم حضور", create_receipt: "سند قبض", create_deposit: "قبض تأمين", add_service: "إضافة خدمة", create_invoice: "إصدار فاتورة" };
const SUGGESTIONS = ["ما وضع اليوم؟", "من يصل اليوم ومن لم يكمل الهوية؟", "أي وحدات تحتاج تنظيفًا وعليها وصول اليوم؟", "من عليه رصيد متبقٍ من المقيمين؟", "تأمينات لم تُسوَّ بعد المغادرة"];

export function OpsCopilot() {
  const { branchId, branch } = useBranch();
  const [open, setOpen] = useState(false);
  const [msgs, setMsgs] = useState<Msg[]>([]);
  const [conv, setConv] = useState<string | null>(null);
  const [input, setInput] = useState("");
  const [busy, setBusy] = useState(false);
  const [props, setProps] = useState<Record<string, ProposalState>>({});
  const endRef = useRef<HTMLDivElement>(null);
  useEffect(() => { endRef.current?.scrollIntoView({ behavior: "smooth" }); }, [msgs, open]);
  useEffect(() => { setConv(null); setMsgs([]); setProps({}); }, [branchId]);   // branch change = new context (G24)
  const branchRef = useRef(branchId);
  branchRef.current = branchId;

  async function send(text: string) {
    if (!branchId || !text.trim() || busy) return;
    const sentFor = branchId;
    setMsgs((m) => [...m, { role: "staff", text }]); setInput(""); setBusy(true);
    try {
      const r = await aiOpsChat(text, branchId, conv);
      if (branchRef.current !== sentFor) return;   // the branch changed meanwhile: this answer belongs to the old context (G24)
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
      <button onClick={() => setOpen((o) => !o)} className="fixed bottom-[72px] left-4 z-40 flex h-12 w-12 lg:bottom-4 items-center justify-center gap-2 rounded-full bg-ink-800 text-sm font-medium text-white shadow-lg hover:bg-ink-900 sm:w-auto sm:px-4" aria-label="مساعد العمليات" aria-expanded={open}>
        {/* U1 note 03: an icon on a phone, so it covers less of the cards beneath it */}
        <Bot className="h-5 w-5" /> <span className="hidden sm:inline">مساعد العمليات</span>
      </button>
      {open && (
        <div className="fixed bottom-[136px] left-5 z-40 flex h-[min(640px,70vh)] lg:bottom-20 w-[min(420px,calc(100vw-2.5rem))] flex-col overflow-hidden rounded-2xl border border-ink-100 bg-white shadow-2xl">
          <div className="flex items-center justify-between border-b border-ink-100 bg-ink-800 px-4 py-3 text-white">
            <div className="flex items-center gap-2"><Bot className="h-5 w-5" /><div className="leading-tight"><p className="text-sm font-semibold">مساعد العمليات</p><p className="text-[11px] text-ink-400">{branch?.name_ar} · يقرأ البيانات ويقترح؛ أنت من ينفذ</p></div></div>
            <button onClick={() => setOpen(false)} className="text-ink-400 hover:text-white"><X className="h-4 w-4" /></button>
          </div>
          <div className="flex-1 space-y-3 overflow-y-auto p-3 scrollbar-thin">
            {msgs.length === 0 && (
              <div className="space-y-2">
                <p className="text-xs text-ink-500">اسأل عن حالة اليوم أو اطلب إجراءً (مثل: «أنشئ مهمة تنظيف للوحدة 101» أو «مدّد الحجز R-… ليلة»). كل إجراء يحتاج تأكيدك.</p>
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
            {busy && <div className="flex justify-end"><div className="rounded-2xl bg-ink-50 px-3 py-2"><Spinner className="h-4 w-4" /></div></div>}
            <div ref={endRef} />
          </div>
          <form onSubmit={(e) => { e.preventDefault(); send(input); }} className="flex gap-2 border-t border-ink-100 p-2">
            <input value={input} onChange={(e) => setInput(e.target.value)} className="input" aria-label="سؤالك أو طلبك" placeholder="اكتب سؤالك أو طلبك…" disabled={busy} />
            <button type="submit" disabled={busy || !input.trim()} className="btn-primary px-3"><Send className="h-4 w-4" /></button>
          </form>
        </div>
      )}
    </>
  );
}
