import { useEffect, useState, useCallback, useRef } from "react";
import { supabase } from "../../lib/supabase";
import { useBranchQuery, must } from "../../lib/useBranchQuery";
import { toArabicError, whatsappApi } from "../../lib/api";
import { SectionTitle, LoadingScreen, EmptyState, Card, Spinner, ErrorBanner, Badge, LoadErrorCard } from "../../components/ui";
import { Inbox as InboxIcon, MessageCircle, Send, Bot, UserCheck, ShieldCheck, PauseCircle } from "lucide-react";
import { formatDateTime } from "../../lib/utils";

interface ConversationRow {
  id: string;
  channel: string;
  status: string;
  created_at: string;
  last_message_at: string | null;
  branch_id: string | null;
  handoff_reason: string | null;
  guest_token: string | null;
  human_active_until?: string | null;
}

interface MessageRow {
  id?: string;
  sender: string;
  content: string;
  created_at: string;
  meta: { mode?: string; [k: string]: unknown } | null;
}

const NO_CONVERSATIONS: ConversationRow[] = [];

const STATUS_LABELS: Record<string, string> = { active: "نشطة", handed_off: "محوّلة", closed: "مغلقة" };
const STATUS_COLORS: Record<string, string> = { active: "bg-success-500/10 text-success-600", handed_off: "bg-warning-500/10 text-warning-700", closed: "bg-ink-100 text-ink-400" };

function channelLabel(c: string) { return c === "whatsapp" ? "واتساب" : "شاشة (تجربة)"; }
const DELIVERY: Record<string, string> = { queued: "بانتظار كمبيوتر الاستقبال", sent: "أُرسلت", failed: "لم تُرسل" };

export default function Inbox() {
  const [messages, setMessages] = useState<MessageRow[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [reply, setReply] = useState("");
  const [acting, setActing] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const bottomRef = useRef<HTMLDivElement | null>(null);

  // G24 (decision 40): the active branch's conversations (and unassigned ones) only — never an unscoped list
  const q = useBranchQuery<ConversationRow[]>(async (branchId) => must(await supabase
      .from("conversations")
      .select("id, channel, status, created_at, last_message_at, branch_id, handoff_reason, guest_token, human_active_until")
      .or(`branch_id.eq.${branchId},branch_id.is.null`)
      .order("last_message_at", { ascending: false, nullsFirst: false })
      .limit(50)) as ConversationRow[], [], NO_CONVERSATIONS);
  const conversations = q.data; const loadConversations = q.reload;
  // a conversation of the previous branch is never left open after a branch switch
  useEffect(() => { setSelected(null); }, [q.branchId]);

  // the messages of the selected conversation; an answer for a conversation that is no longer selected is dropped
  const msgReq = useRef(0);
  const loadMessages = useCallback(async (conversationId: string) => {
    const token = ++msgReq.current;
    const { data, error: e } = await supabase
      .from("conversation_messages")
      .select("id, sender, content, created_at, meta")
      .eq("conversation_id", conversationId)
      .order("created_at", { ascending: true });
    if (token !== msgReq.current) return;
    if (e) setError(toArabicError(e));
    else setMessages((data as MessageRow[]) ?? []);
  }, []);

  useEffect(() => { if (selected) { setMessages([]); loadMessages(selected); } else { msgReq.current++; setMessages([]); } }, [selected, loadMessages]);
  useEffect(() => { bottomRef.current?.scrollIntoView({ block: "end" }); }, [messages.length]);

  // Realtime on messages and conversations
  useEffect(() => {
    const ch = supabase
      .channel("inbox-rt")
      // inserts and updates (a reply's delivery: waiting for the reception computer → sent)
      .on("postgres_changes", { event: "*", schema: "public", table: "conversation_messages" }, (payload) => {
        const row = payload.new as { conversation_id?: string };
        if (selected && row.conversation_id === selected) loadMessages(selected);
        loadConversations();
      })
      .on("postgres_changes", { event: "*", schema: "public", table: "conversations" }, () => loadConversations())
      .subscribe();
    return () => { supabase.removeChannel(ch); };
  }, [selected, loadMessages, loadConversations]);

  async function sendReply(e: React.FormEvent) {
    e.preventDefault();
    if (!selected || !reply.trim()) return;
    setActing("send"); setError(null); setNotice(null);
    try {
      const conv = conversations.find((c) => c.id === selected);
      if (conv?.channel === "whatsapp") {
        // stored and sent to the guest's WhatsApp by the branch's number (directly, or typed by the reception computer);
        // the inbox says honestly when it was not delivered
        const r = await whatsappApi.reply(selected, reply.trim());
        if (r.queued) setNotice(r.bridge_online ? "أُرسلت إلى كمبيوتر الاستقبال وتصل للنزيل خلال ثوانٍ. المساعد صامت في هذه المحادثة الآن." : "حُفظت وستُرسل عند تشغيل برنامج كمبيوتر الاستقبال (غير متصل الآن).");
        else if (!r.delivered) setError(r.error === "window_closed" ? "حُفظت الرسالة لكن لم تُرسل: مرّ أكثر من 24 ساعة على آخر رسالة من النزيل." : r.error === "channel_unavailable" ? "حُفظت الرسالة لكن واتساب هذا الفرع غير مفعّل." : "حُفظت الرسالة لكن تعذّر إرسالها عبر واتساب.");
        loadConversations();
      } else {
        const { error: err } = await supabase.from("conversation_messages").insert({ conversation_id: selected, sender: "supervisor", content: reply.trim() });
        if (err) throw err;
      }
      setReply("");
      await loadMessages(selected);
    } catch (err) {
      setError(toArabicError(err));
    } finally {
      setActing(null);
    }
  }

  async function setConversationStatus(status: "handed_off" | "active") {
    if (!selected) return;
    setActing(status); setError(null); setNotice(null);
    try {
      // audited; on WhatsApp taking the chat also silences the assistant there (the branch's pause), returning ends it
      await whatsappApi.take(selected, status === "handed_off");
      loadConversations();
    } catch (err) {
      setError(toArabicError(err));
    } finally {
      setActing(null);
    }
  }

  if (q.loading) return <LoadingScreen />;

  const current = conversations.find((c) => c.id === selected);
  const pausedUntil = current?.human_active_until && Date.parse(current.human_active_until) > Date.now() ? current.human_active_until : null;

  return (
    <div>
      <SectionTitle title="الوارد الموحّد" subtitle={`${conversations.length} محادثة`} />
      {(error || (q.error && conversations.length > 0)) && <div className="mb-4"><ErrorBanner message={(error ?? q.error) as string} /></div>}
      {notice && <p className="mb-4 rounded-xl bg-success-500/10 px-3 py-2 text-sm text-success-600">{notice}</p>}
      {q.error && conversations.length === 0 ? <LoadErrorCard message={q.error} onRetry={loadConversations} /> : conversations.length === 0 ? (
        <EmptyState icon={<InboxIcon className="h-10 w-10" />} title="لا توجد محادثات" description="تظهر محادثات النزلاء من الويب وواتساب هنا." />
      ) : (
        <div className="grid gap-4 lg:grid-cols-3">
          <div className="space-y-2 lg:col-span-1 max-h-[75vh] overflow-y-auto scrollbar-thin">
            {conversations.map((c) => (
              <button key={c.id} onClick={() => setSelected(c.id)} className={`card w-full p-3 text-right transition-all ${selected === c.id ? "border-brand-400" : "hover:border-ink-200"}`}>
                <div className="flex items-center justify-between gap-2">
                  <span className="text-xs font-medium text-ink-600">{channelLabel(c.channel)}</span>
                  <div className="flex items-center gap-1">
                    {c.guest_token && <Badge className="bg-accent-500/10 text-accent-600"><ShieldCheck className="h-3 w-3" /> متحقق</Badge>}
                    <Badge className={STATUS_COLORS[c.status] ?? "bg-ink-100 text-ink-400"}>{STATUS_LABELS[c.status] ?? c.status}</Badge>
                  </div>
                </div>
                <p className="mt-1 text-xs text-ink-400">{c.last_message_at ? formatDateTime(c.last_message_at) : formatDateTime(c.created_at)}</p>
                {c.handoff_reason && <p className="mt-1 truncate text-xs text-warning-700">{c.handoff_reason}</p>}
              </button>
            ))}
          </div>
          <Card className="lg:col-span-2">
            {current ? (
              <div className="flex flex-col">
                <div className="mb-3 flex flex-wrap items-center justify-between gap-2 border-b border-ink-50 pb-3">
                  <div className="flex items-center gap-2">
                    <MessageCircle className="h-5 w-5 text-brand-600" />
                    <p className="text-sm font-medium text-ink-700">محادثة {channelLabel(current.channel)}</p>
                    <Badge className={STATUS_COLORS[current.status] ?? ""}>{STATUS_LABELS[current.status] ?? current.status}</Badge>
                    {current.guest_token && <Badge className="bg-accent-500/10 text-accent-600">متحقق</Badge>}
                  </div>
                  <div className="flex gap-2">
                    {current.status !== "handed_off" && current.status !== "closed" && (
                      <button onClick={() => setConversationStatus("handed_off")} disabled={acting === "handed_off"} className="btn-accent text-xs">
                        {acting === "handed_off" ? <Spinner className="h-3.5 w-3.5" /> : <UserCheck className="h-3.5 w-3.5" />} استلام المحادثة
                      </button>
                    )}
                    {(current.status === "handed_off" || pausedUntil) && (
                      <button onClick={() => setConversationStatus("active")} disabled={acting === "active"} className="btn-outline text-xs">
                        {acting === "active" ? <Spinner className="h-3.5 w-3.5" /> : <Bot className="h-3.5 w-3.5" />} إعادة للمساعد الذكي
                      </button>
                    )}
                  </div>
                </div>
                {current.handoff_reason && <p className="mb-3 rounded-lg bg-warning-500/10 px-3 py-2 text-xs text-warning-700">سبب التحويل: {current.handoff_reason}</p>}
                {pausedUntil && <p className="mb-3 flex items-center gap-1.5 rounded-lg bg-accent-500/10 px-3 py-2 text-xs text-accent-600" data-testid="assistant-paused"><PauseCircle className="h-3.5 w-3.5" /> المساعد صامت في هذه المحادثة حتى {formatDateTime(pausedUntil)} لأن موظفًا يرد. «إعادة للمساعد الذكي» تنهي ذلك الآن.</p>}
                <div className="space-y-3 max-h-[55vh] overflow-y-auto scrollbar-thin">
                  {messages.map((m, i) => {
                    const isGuest = m.sender === "guest";
                    const isSupervisor = m.sender === "supervisor";
                    const mode = m.meta?.mode;
                    return (
                      <div key={m.id ?? i} className={`flex ${isGuest ? "justify-start" : "justify-end"}`}>
                        <div className={`max-w-[80%] rounded-2xl px-3 py-2 text-sm ${isGuest ? "bg-brand-600 text-white" : isSupervisor ? "bg-accent-500/10 text-ink-800" : "bg-ink-50 text-ink-800"}`}>
                          <p className="whitespace-pre-wrap">{m.content}</p>
                          <div className={`mt-1 flex items-center gap-1.5 text-[10px] ${isGuest ? "text-white/70" : "text-ink-400"}`}>
                            <span>{isGuest ? "النزيل" : isSupervisor ? "المشرف" : "المساعد"}</span>
                            {mode === "ai" && <span className="rounded bg-brand-50 px-1 text-brand-700">AI</span>}
                            {mode === "scripted" && <span className="rounded bg-ink-100 px-1 text-ink-600">إرشادي</span>}
                            {m.meta?.via === "whatsapp_app" && <span className="rounded bg-ink-100 px-1 text-ink-600">من واتساب الفرع</span>}
                            {typeof m.meta?.delivery === "string" && <span className={`rounded px-1 ${m.meta.delivery === "failed" ? "bg-danger-500/10 text-danger-600" : "bg-ink-100 text-ink-600"}`}>{DELIVERY[m.meta.delivery] ?? m.meta.delivery}</span>}
                            {isGuest && typeof m.meta?.unanswered === "string" && <span className="rounded bg-white/20 px-1">بلا رد آلي</span>}
                            <span>· {formatDateTime(m.created_at)}</span>
                          </div>
                        </div>
                      </div>
                    );
                  })}
                  {messages.length === 0 && <p className="text-center text-xs text-ink-400">لا توجد رسائل.</p>}
                  <div ref={bottomRef} />
                </div>
                <form onSubmit={sendReply} className="mt-3 flex gap-2 border-t border-ink-50 pt-3">
                  <input value={reply} onChange={(e) => setReply(e.target.value)} className="input flex-1" placeholder={current.status === "handed_off" ? "اكتب ردًا للنزيل…" : "استلم المحادثة أولًا أو اكتب ردًا مباشرًا…"} />
                  <button type="submit" disabled={acting === "send" || !reply.trim()} className="btn-primary text-sm">
                    {acting === "send" ? <Spinner className="h-4 w-4" /> : <Send className="h-4 w-4" />} إرسال
                  </button>
                </form>
              </div>
            ) : (
              <div className="flex h-40 items-center justify-center text-sm text-ink-400">اختر محادثة للعرض</div>
            )}
          </Card>
        </div>
      )}
    </div>
  );
}
