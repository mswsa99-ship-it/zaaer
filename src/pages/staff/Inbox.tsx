import { useEffect, useState, useCallback, useRef } from "react";
import { supabase } from "../../lib/supabase";
import { useBranch } from "../../lib/branch";
import { toArabicError } from "../../lib/api";
import { SectionTitle, LoadingScreen, EmptyState, Card, Spinner, ErrorBanner, Badge } from "../../components/ui";
import { Inbox as InboxIcon, MessageCircle, Send, Bot, UserCheck, ShieldCheck } from "lucide-react";
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
}

interface MessageRow {
  id?: string;
  sender: string;
  content: string;
  created_at: string;
  meta: { mode?: string; [k: string]: unknown } | null;
}

const STATUS_LABELS: Record<string, string> = { active: "نشطة", handed_off: "محوّلة", closed: "مغلقة" };
const STATUS_COLORS: Record<string, string> = { active: "bg-success-500/10 text-success-600", handed_off: "bg-warning-500/10 text-warning-600", closed: "bg-ink-100 text-ink-400" };

function channelLabel(c: string) { return c === "whatsapp" ? "واتساب" : "شاشة"; }

export default function Inbox() {
  const { branchId, loading: branchLoading } = useBranch();
  const [conversations, setConversations] = useState<ConversationRow[]>([]);
  const [messages, setMessages] = useState<MessageRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [selected, setSelected] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [reply, setReply] = useState("");
  const [acting, setActing] = useState<string | null>(null);
  const bottomRef = useRef<HTMLDivElement | null>(null);

  const loadConversations = useCallback(async () => {
    let q = supabase
      .from("conversations")
      .select("id, channel, status, created_at, last_message_at, branch_id, handoff_reason, guest_token")
      .order("last_message_at", { ascending: false, nullsFirst: false })
      .limit(50);
    if (branchId) q = q.or(`branch_id.eq.${branchId},branch_id.is.null`);
    const { data, error: e } = await q;
    if (e) setError(toArabicError(e));
    else setConversations((data as ConversationRow[]) ?? []);
    setLoading(false);
  }, [branchId]);

  const loadMessages = useCallback(async (conversationId: string) => {
    const { data, error: e } = await supabase
      .from("conversation_messages")
      .select("id, sender, content, created_at, meta")
      .eq("conversation_id", conversationId)
      .order("created_at", { ascending: true });
    if (e) setError(toArabicError(e));
    else setMessages((data as MessageRow[]) ?? []);
  }, []);

  useEffect(() => { if (!branchLoading) loadConversations(); }, [loadConversations, branchLoading]);
  useEffect(() => { if (selected) loadMessages(selected); else setMessages([]); }, [selected, loadMessages]);
  useEffect(() => { bottomRef.current?.scrollIntoView({ block: "end" }); }, [messages.length]);

  // Realtime on messages and conversations
  useEffect(() => {
    const ch = supabase
      .channel("inbox-rt")
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "conversation_messages" }, (payload) => {
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
    setActing("send"); setError(null);
    try {
      const { error: err } = await supabase.from("conversation_messages").insert({ conversation_id: selected, sender: "supervisor", content: reply.trim() });
      if (err) throw err;
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
    setActing(status); setError(null);
    try {
      const patch = status === "handed_off" ? { status, handed_off_at: new Date().toISOString() } : { status, handed_off_at: null };
      const { error: err } = await supabase.from("conversations").update(patch).eq("id", selected);
      if (err) throw err;
      await loadConversations();
    } catch (err) {
      setError(toArabicError(err));
    } finally {
      setActing(null);
    }
  }

  if (loading || branchLoading) return <LoadingScreen />;

  const current = conversations.find((c) => c.id === selected);

  return (
    <div>
      <SectionTitle title="الوارد الموحّد" subtitle={`${conversations.length} محادثة`} />
      {error && <div className="mb-4"><ErrorBanner message={error} /></div>}
      {conversations.length === 0 ? (
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
                {c.handoff_reason && <p className="mt-1 truncate text-xs text-warning-600">{c.handoff_reason}</p>}
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
                    {current.status === "handed_off" && (
                      <button onClick={() => setConversationStatus("active")} disabled={acting === "active"} className="btn-outline text-xs">
                        {acting === "active" ? <Spinner className="h-3.5 w-3.5" /> : <Bot className="h-3.5 w-3.5" />} إعادة للمساعد الذكي
                      </button>
                    )}
                  </div>
                </div>
                {current.handoff_reason && <p className="mb-3 rounded-lg bg-warning-500/10 px-3 py-2 text-xs text-warning-600">سبب التحويل: {current.handoff_reason}</p>}
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
