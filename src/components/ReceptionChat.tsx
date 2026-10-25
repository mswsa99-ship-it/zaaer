/**
 * AI reception chat — the same assistant guests reach on WhatsApp, as a chat window. Guests no longer see it on the
 * website (the site shows the branch's WhatsApp QR code); staff use it on /admin/assistant to try the assistant.
 * Everything the assistant says comes from the `ai-reception` Edge Function (model with narrow tools, or the
 * deterministic scripted path). Decision 23: no availability and no prices are shown here; a new booking is one
 * question to the assistant, which answers with the branch's platform link.
 */
import { useEffect, useRef, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { Hotel, Send, BookCheck, ArrowLeft, ShieldCheck, UserRound, Bot, CalendarDays, Clock, Headset, RotateCcw } from "lucide-react";
import { cn } from "../lib/utils";
import { aiChat, type AiReply } from "../lib/api";
import { useBranch } from "../lib/branch";
import { supabase } from "../lib/supabase";
import { scriptedReply } from "../../supabase/functions/_shared/guardrails";

interface Message { id: string; sender: "assistant" | "guest"; content: string; mode?: "ai" | "scripted"; actions?: { label: string; route?: string; value?: string }[] }

const WELCOME = (name: string): Message => ({
  id: "init", sender: "assistant",
  content: `أهلًا بك في ${name}. كيف أخدمك؟`,
  actions: [{ label: "احجز الآن", value: "أرغب بحجز جديد" }, { label: "حجوزاتي", route: "/booking/lookup" }, { label: "مواعيد الوصول والمغادرة", value: "ما هي مواعيد الوصول والمغادرة؟" }],
});
const CONV_KEY = "reception_conversation_id";
const CONV_AT_KEY = "reception_conversation_at";
const CONV_MAX_AGE_MS = 6 * 60 * 60 * 1000;   // a conversation older than 6h starts fresh: the guest's situation has usually changed
// four shortcuts only — everything else is one question away in the chat
const QUICK = [
  { icon: CalendarDays, label: "احجز الآن", value: "أرغب بحجز جديد" },
  { icon: BookCheck, label: "حجوزاتي", route: "/booking/lookup" },
  { icon: Clock, label: "المواعيد والموقع", value: "ما هي مواعيد الوصول والمغادرة وأين يقع الفرع؟" },
  { icon: Headset, label: "موظف الاستقبال", value: "أرغب بالتحدث مع موظف الاستقبال" },
];

export default function ReceptionChat({ embedded = false }: { embedded?: boolean }) {
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const { branchId, branch } = useBranch();
  const propertyName = "منازل الراحة";
  const [messages, setMessages] = useState<Message[]>([WELCOME(propertyName)]);
  const [input, setInput] = useState("");
  const [thinking, setThinking] = useState(false);
  const [conversationId, setConversationId] = useState<string | null>(() => {
    try {
      if (new URLSearchParams(window.location.search).get("new") === "1" || window.location.hash.includes("new=1")) { sessionStorage.removeItem(CONV_KEY); sessionStorage.removeItem(CONV_AT_KEY); return null; }
      const at = Number(sessionStorage.getItem(CONV_AT_KEY) ?? 0);
      if (!at || Date.now() - at > CONV_MAX_AGE_MS) { sessionStorage.removeItem(CONV_KEY); return null; }
      return sessionStorage.getItem(CONV_KEY);
    } catch { return null; }
  });
  const [status, setStatus] = useState<{ verified: boolean; handedOff: boolean; mode: "ai" | "scripted" | null; aiStatus?: string }>({ verified: false, handedOff: false, mode: null });
  const scrollRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const guestToken = params.get("token");
  const kiosk = params.get("kiosk") === "1";

  useEffect(() => { scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight, behavior: "smooth" }); }, [messages, thinking]);

  // Supervisor replies after a hand-off arrive live
  useEffect(() => {
    if (!conversationId || !status.handedOff) return;
    const ch = supabase.channel(`guest-conv-${conversationId}`).on("postgres_changes", { event: "INSERT", schema: "public", table: "conversation_messages", filter: `conversation_id=eq.${conversationId}` }, (p) => {
      const row = p.new as { sender: string; content: string };
      if (row.sender === "supervisor") setMessages((m) => [...m, { id: crypto.randomUUID(), sender: "assistant", content: "موظف الاستقبال: " + row.content }]);
    }).subscribe();
    return () => { supabase.removeChannel(ch); };
  }, [conversationId, status.handedOff]);

  async function send(text: string) {
    const trimmed = text.trim();
    if (!trimmed || thinking) return;
    setMessages((m) => [...m, { id: crypto.randomUUID(), sender: "guest", content: trimmed }]);
    setThinking(true);
    let reply: AiReply | null = null;
    try { reply = await aiChat(trimmed, { conversationId, guestToken, branchId, channel: "screen" }); } catch { reply = null; }
    if (reply) {
      if (reply.conversation_id !== conversationId) { setConversationId(reply.conversation_id); try { sessionStorage.setItem(CONV_KEY, reply.conversation_id); sessionStorage.setItem(CONV_AT_KEY, String(Date.now())); } catch { /* ignore */ } }
      setStatus({ verified: reply.verified, handedOff: reply.handed_off, mode: reply.mode, aiStatus: reply.ai_status });
      setMessages((m) => [...m, { id: crypto.randomUUID(), sender: "assistant", content: reply!.reply, mode: reply!.mode, actions: reply!.actions }]);
    } else {
      // Edge Function unreachable → the same deterministic script runs locally (with the branch's public times) so the guest is never stuck
      const r = scriptedReply(trimmed, propertyName, undefined, { branchName: branch?.name_ar, checkInTime: branch?.check_in_time, checkOutTime: branch?.check_out_time, bookingUrl: branch?.booking_platform_url ?? null, mapUrl: branch?.map_url ?? null });
      setStatus((s) => ({ ...s, mode: "scripted", aiStatus: "offline" }));
      setMessages((m) => [...m, { id: crypto.randomUUID(), sender: "assistant", content: r.text, mode: "scripted", actions: r.actions }]);
    }
    setThinking(false);
    inputRef.current?.focus();
  }

  function resetConversation() {
    try { sessionStorage.removeItem(CONV_KEY); sessionStorage.removeItem(CONV_AT_KEY); } catch { /* ignore */ }
    setConversationId(null); setMessages([WELCOME(propertyName)]); setStatus({ verified: false, handedOff: false, mode: null });
  }

  return (
    <div className={cn("mx-auto flex max-w-6xl gap-4", embedded ? "h-[72vh]" : "px-4 py-4", !embedded && (kiosk ? "h-[calc(100vh-110px)]" : "h-[calc(100vh-120px)]"))}>
      {/* Side panel (desktop) */}
      <aside className="hidden w-72 shrink-0 flex-col gap-3 lg:flex">
        <div className="card p-4">
          <div className="flex items-center gap-3">
            <div className="flex h-11 w-11 items-center justify-center rounded-2xl bg-brand-600 text-white"><Hotel className="h-6 w-6" /></div>
            <div className="leading-tight"><p className="font-semibold text-ink-800">{branch?.name_ar ?? propertyName}</p><p className="text-[11px] text-ink-400">الاستقبال الذكي · على مدار الساعة</p></div>
          </div>
          {branch?.check_in_time && <p className="mt-3 flex items-center gap-1.5 text-xs text-ink-500"><Clock className="h-3.5 w-3.5" /> الوصول {branch.check_in_time.slice(0, 5)} · المغادرة {branch.check_out_time?.slice(0, 5)}</p>}
        </div>
        <div className="card p-3">
                    <div className="space-y-1">
            {QUICK.map((q) => (
              <button key={q.label} onClick={() => (q.route ? navigate(q.route) : send(q.value!))} className="flex w-full items-center gap-2.5 rounded-xl px-3 py-2 text-right text-sm text-ink-700 hover:bg-brand-50 hover:text-brand-700">
                <q.icon className="h-4 w-4 text-brand-500" /> {q.label}
              </button>
            ))}
          </div>
        </div>
      </aside>

      {/* Chat */}
      <div className="flex min-w-0 flex-1 flex-col">
        <div className="mb-3 flex items-center gap-3">
          {!kiosk && !embedded && <button onClick={() => navigate("/")} className="rounded-lg p-1.5 text-ink-400 hover:bg-ink-100" aria-label="رجوع"><ArrowLeft className="h-5 w-5" /></button>}
          <div className="flex h-10 w-10 items-center justify-center rounded-full bg-brand-600 text-white lg:hidden"><Hotel className="h-5 w-5" /></div>
          <div className="flex-1">
            <p className="text-sm font-semibold text-ink-800">مساعد الاستقبال الذكي</p>
            <p className="flex flex-wrap items-center gap-2 text-[11px] text-ink-400">
              {status.handedOff ? <span className="inline-flex items-center gap-1 text-warning-600"><UserRound className="h-3 w-3" /> تم التحويل إلى موظف الاستقبال — سيرد هنا</span>
                : status.mode === "ai" ? <span className="inline-flex items-center gap-1 text-accent-600"><Bot className="h-3 w-3" /> مساعد رقمي</span>
                : <span className="inline-flex items-center gap-1"><Bot className="h-3 w-3" /> مسار إرشادي</span>}
              {status.verified && <span className="inline-flex items-center gap-1 text-success-600"><ShieldCheck className="h-3 w-3" /> حجز متحقق</span>}
            </p>
          </div>
          <button onClick={resetConversation} className="inline-flex items-center gap-1 text-xs text-ink-400 hover:text-ink-600"><RotateCcw className="h-3.5 w-3.5" /> محادثة جديدة</button>
        </div>

        {status.handedOff && (
          <div className="mb-2 flex flex-wrap items-center justify-between gap-2 rounded-xl border border-warning-500/30 bg-warning-500/10 px-3 py-2 text-xs text-warning-600">
            <span className="inline-flex items-center gap-1.5"><UserRound className="h-3.5 w-3.5" /> هذه المحادثة محوّلة إلى موظف الاستقبال وسيرد هنا. الأسئلة العامة (المواعيد، الإنترنت، المواقف، الموقع) تُجاب فورًا.</span>
            <button onClick={resetConversation} className="font-medium underline-offset-2 hover:underline">بدء محادثة جديدة</button>
          </div>
        )}
        <div ref={scrollRef} className="flex-1 space-y-4 overflow-y-auto rounded-2xl border border-ink-100 bg-white p-4 scrollbar-thin" aria-live="polite">
          {messages.map((m) => (
            <div key={m.id} className={cn("flex flex-col gap-2", m.sender === "guest" ? "items-start" : "items-end")}>
              <div className={cn("max-w-[88%] whitespace-pre-line rounded-2xl px-4 py-2.5 leading-relaxed", kiosk ? "text-base" : "text-sm", m.sender === "guest" ? "bg-brand-600 text-white" : "bg-ink-50 text-ink-800")}>{m.content}</div>
              {m.actions && m.actions.length > 0 && (
                <div className="flex flex-wrap gap-2">
                  {m.actions.map((a, i) => (
                    <button key={i} onClick={() => { if (a.route === "/reception?new=1") resetConversation(); else if (a.route) navigate(a.route); else if (a.value) send(a.value); }} className="inline-flex items-center gap-1.5 rounded-full border border-brand-200 bg-brand-50 px-3 py-1.5 text-xs font-medium text-brand-700 hover:bg-brand-100">{a.label}</button>
                  ))}
                </div>
              )}
            </div>
          ))}
          {thinking && <div className="flex items-end justify-end"><div className="flex gap-1 rounded-2xl bg-ink-50 px-4 py-3"><span className="h-1.5 w-1.5 animate-bounce rounded-full bg-ink-300 [animation-delay:-0.3s]" /><span className="h-1.5 w-1.5 animate-bounce rounded-full bg-ink-300 [animation-delay:-0.15s]" /><span className="h-1.5 w-1.5 animate-bounce rounded-full bg-ink-300" /></div></div>}
        </div>

        {/* mobile quick chips */}
        <div className="mt-2 flex gap-2 overflow-x-auto pb-1 lg:hidden">
          {QUICK.map((q) => <button key={q.label} onClick={() => (q.route ? navigate(q.route) : send(q.value!))} className="inline-flex shrink-0 items-center gap-1 rounded-full border border-ink-200 bg-white px-3 py-1.5 text-xs text-ink-600"><q.icon className="h-3.5 w-3.5 text-brand-500" /> {q.label}</button>)}
        </div>

        <form onSubmit={(e) => { e.preventDefault(); send(input); setInput(""); }} className="mt-2 flex items-center gap-2">
          <input ref={inputRef} value={input} onChange={(e) => setInput(e.target.value)} placeholder={status.handedOff ? "اكتب لموظف الاستقبال…" : "اكتب سؤالك…"} className={cn("input flex-1", kiosk && "py-3 text-base")} maxLength={2000} disabled={thinking} autoFocus />
          <button type="submit" className="btn-primary" disabled={!input.trim() || thinking} aria-label="إرسال"><Send className="h-4 w-4" /></button>
        </form>
      </div>
    </div>
  );
}

