import { useCallback, useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { ArrowRight, Send, Smartphone, Monitor, CheckCheck, Info } from "lucide-react";
import { useBranch } from "../../lib/branch";
import { whatsappApi } from "../../lib/api";
import { Spinner } from "../../components/ui";
import { UI_LOCALE } from "../../lib/utils";
import { simGuests, simSend, simHumanReply, simPollStaff, type SimGuest } from "../../demo/whatsappSim";
import { demoBridgeKey } from "../../demo/client";

/**
 * Demo only — what a guest sees on WhatsApp when the branch answers from the reception computer. The page plays that
 * program: each message runs the server's own code (wa-bridge → the WhatsApp flow → the reception assistant) on the
 * demo data, and the answer comes back exactly as WhatsApp Web would type it (plain text, numbered options).
 * Staff replies sent from the inbox arrive here too, the way the program picks them up.
 */
interface Bubble { id: number; from: "guest" | "bot" | "staff" | "note"; text: string; at: string }
const QUICK = ["حجوزاتي", "1", "2", "متى الدخول والخروج؟", "وصلت", "التحدث مع موظف"];
const SILENT: Record<string, string> = {
  human: "لا رد آلي: موظف يتابع هذه المحادثة الآن (تصل رسالتك إلى الوارد).",
  auto_reply_off: "الرد الآلي متوقف من الإدارة لهذا الفرع؛ رسالتك في الوارد للموظفين.",
  disabled: "واتساب هذا الفرع غير مفعّل.",
  too_old: "رسالة قديمة: تُسجل للموظفين دون رد آلي.",
};
const time = () => new Date().toLocaleTimeString(UI_LOCALE, { hour: "2-digit", minute: "2-digit" });
let bubbleSeq = 0;

function Linkified({ text }: { text: string }) {
  const parts = text.split(/(https?:\/\/[^\s]+)/g);
  return <>{parts.map((p, i) => /^https?:\/\//.test(p)
    ? <a key={i} href={p} className="break-all text-[#027eb5] underline" target={p.startsWith(window.location.href.split("#")[0]) ? undefined : "_blank"} rel="noopener noreferrer">{p}</a>
    : <span key={i}>{p}</span>)}</>;
}

export default function WhatsAppDemo() {
  const { branches, branchId, setBranchId, branch } = useBranch();
  const [guests, setGuests] = useState<SimGuest[]>([]);
  const [phone, setPhone] = useState("");
  const [chats, setChats] = useState<Record<string, Bubble[]>>({});
  const [text, setText] = useState("");
  const [typing, setTyping] = useState(false);
  const [staffText, setStaffText] = useState("");
  const [waPhone, setWaPhone] = useState<string | null>(null);
  const bottom = useRef<HTMLDivElement | null>(null);
  const linked = !!(branchId && demoBridgeKey(branchId));

  useEffect(() => { simGuests().then((g) => { setGuests(g); setPhone((p) => p || g[0]?.phone || ""); }); }, []);
  useEffect(() => { if (branchId) whatsappApi.publicInfo(branchId).then((p) => setWaPhone(p?.wa_phone ?? null)).catch(() => setWaPhone(null)); }, [branchId]);
  useEffect(() => { bottom.current?.scrollIntoView({ block: "end" }); }, [chats, phone, typing]);

  const push = useCallback((ph: string, b: Omit<Bubble, "id" | "at">) => {
    setChats((c) => ({ ...c, [ph]: [...(c[ph] ?? []), { ...b, id: ++bubbleSeq, at: time() }] }));
  }, []);

  // the reception computer: staff replies from the inbox are picked up and typed into the chat (confirmed only once
  // shown; one polling loop per branch — the linked number is read when each poll starts)
  const waPhoneRef = useRef<string | null>(null);
  waPhoneRef.current = waPhone;
  useEffect(() => {
    if (!branchId || !linked) return;
    let alive = true;
    const tick = () => simPollStaff(branchId, waPhoneRef.current, (it) => {
      if (!alive) return false;
      push(it.chat_id.split("@")[0], { from: "staff", text: it.text });
      return true;
    });
    tick();
    const t = setInterval(tick, 3000);
    return () => { alive = false; clearInterval(t); };
  }, [branchId, linked, push]);

  async function send(msg: string) {
    const m = msg.trim();
    if (!m || !branchId || !phone || typing) return;
    setText("");
    push(phone, { from: "guest", text: m });
    setTyping(true);
    const r = await simSend(branchId, phone, m);
    for (const reply of r.replies) {
      await new Promise((res) => setTimeout(res, 450));          // the program types like a person, one message at a time
      push(phone, { from: "bot", text: reply });
    }
    if (r.silent) push(phone, { from: "note", text: SILENT[r.silent] ?? r.silent });
    if (r.error) push(phone, { from: "note", text: r.error === "not_linked" ? "هذا الفرع غير مربوط بكمبيوتر الاستقبال." : "تعذّر الرد." });
    setTyping(false);
  }

  async function staffReply() {
    const m = staffText.trim();
    if (!m || !branchId || !phone) return;
    setStaffText("");
    const r = await simHumanReply(branchId, phone, m);
    push(phone, { from: "staff", text: m });
    if (r.until) push(phone, { from: "note", text: "كتب الموظف من جوال الفرع: المساعد صامت في هذه المحادثة حتى يعيدها الموظف أو تنتهي المدة." });
  }

  const bubbles = chats[phone] ?? [];
  return (
    <div className="mx-auto max-w-md px-4 py-6">
      <Link to="/" className="mb-3 inline-flex items-center gap-1 text-xs text-ink-500 hover:text-brand-600"><ArrowRight className="h-3.5 w-3.5" /> الصفحة الرئيسية</Link>
      <div className="mb-3 flex items-start gap-2 rounded-2xl bg-brand-50 px-3 py-2 text-xs text-ink-600">
        <Info className="mt-0.5 h-4 w-4 shrink-0 text-brand-600" />
        <p>محاكاة لما يراه النزيل على واتساب عندما يرد الفرع من <b>كمبيوتر الاستقبال</b>: كل رسالة تمر بمنطق الخادم نفسه على بيانات العرض، ولا يُرسل شيء فعليًا.</p>
      </div>

      <div className="mb-3 grid grid-cols-2 gap-2">
        {branches.length > 1 && (
          <select value={branchId ?? ""} onChange={(e) => setBranchId(e.target.value)} className="input text-xs" aria-label="الفرع">
            {branches.map((b) => <option key={b.id} value={b.id}>{b.name_ar}</option>)}
          </select>
        )}
        <select value={phone} onChange={(e) => setPhone(e.target.value)} className={`input text-xs ${branches.length > 1 ? "" : "col-span-2"}`} aria-label="رقمك على واتساب" data-testid="sim-guest-select">
          {guests.map((g) => <option key={g.phone} value={g.phone}>{`…${g.phone.slice(-4)} · ${g.label}`}</option>)}
        </select>
      </div>

      <div className="overflow-hidden rounded-3xl border border-ink-100 shadow-sm">
        <div className="flex items-center gap-3 bg-[#075E54] px-4 py-3 text-white">
          <div className="flex h-9 w-9 items-center justify-center rounded-full bg-white/15 text-sm font-bold">{(branch?.name_ar ?? "ف").slice(0, 1)}</div>
          <div className="min-w-0 flex-1">
            <p className="truncate text-sm font-semibold">{branch?.name_ar ?? "الاستقبال"}</p>
            <p className="truncate text-[11px] text-white/75" dir="ltr">{waPhone ? `+${waPhone}` : "—"}</p>
          </div>
          <span className="inline-flex items-center gap-1 rounded-full bg-white/15 px-2 py-0.5 text-[10px]"><Monitor className="h-3 w-3" /> كمبيوتر الاستقبال</span>
        </div>

        <div className="h-[56vh] min-h-[340px] space-y-2 overflow-y-auto bg-[#ECE5DD] px-3 py-3" aria-live="polite">
          {!linked && <p className="mx-auto w-fit rounded-lg bg-white/80 px-3 py-1.5 text-center text-xs text-ink-600">هذا الفرع غير مربوط بكمبيوتر الاستقبال في العرض. اختر فرعًا آخر أو اربطه من <Link to="/admin/whatsapp" className="text-brand-600 underline">واتساب الفروع</Link>.</p>}
          {linked && bubbles.length === 0 && <p className="mx-auto w-fit rounded-lg bg-[#FFF3C4] px-3 py-1.5 text-center text-[11px] text-ink-600">اكتب «حجوزاتي» أو أي سؤال كما يكتبه النزيل.</p>}
          {bubbles.map((b) => b.from === "note" ? (
            <p key={b.id} className="mx-auto w-fit max-w-[90%] rounded-lg bg-white/80 px-3 py-1 text-center text-[11px] text-ink-500">{b.text}</p>
          ) : (
            <div key={b.id} className={`flex ${b.from === "guest" ? "justify-end" : "justify-start"}`}>
              <div className={`max-w-[85%] whitespace-pre-wrap rounded-2xl px-3 py-2 text-sm leading-6 text-[#111b21] shadow-sm ${b.from === "guest" ? "rounded-tl-sm bg-[#DCF8C6]" : "rounded-tr-sm bg-white"}`} data-testid={b.from === "bot" ? "sim-bubble-bot" : b.from === "staff" ? "sim-bubble-staff" : "sim-bubble-guest"}>
                {b.from === "staff" && <p className="mb-0.5 flex items-center gap-1 text-[10px] font-semibold text-[#128C7E]"><Smartphone className="h-3 w-3" /> موظف الاستقبال</p>}
                <Linkified text={b.text} />
                <span className="mt-0.5 flex items-center justify-end gap-1 text-[10px] text-ink-400">{b.at}{b.from === "guest" && <CheckCheck className="h-3 w-3 text-[#34B7F1]" />}</span>
              </div>
            </div>
          ))}
          {typing && <div className="flex justify-start"><div className="rounded-2xl rounded-tr-sm bg-white px-3 py-2 text-xs text-ink-400 shadow-sm">يكتب…</div></div>}
          <div ref={bottom} />
        </div>

        <div className="flex flex-wrap gap-1.5 border-t border-ink-100 bg-[#F0F2F5] px-3 pt-2">
          {QUICK.map((q) => <button key={q} type="button" className="rounded-full border border-ink-200 bg-white px-2.5 py-1 text-[11px] text-ink-600 hover:border-[#25D366]" disabled={!linked || typing} onClick={() => send(q)}>{q}</button>)}
        </div>
        <form onSubmit={(e) => { e.preventDefault(); send(text); }} className="flex items-center gap-2 bg-[#F0F2F5] px-3 py-2">
          <input value={text} onChange={(e) => setText(e.target.value)} className="input flex-1 rounded-full bg-white" placeholder="اكتب رسالة" aria-label="رسالتك" disabled={!linked} data-testid="sim-input" />
          <button type="submit" className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-[#25D366] text-white disabled:opacity-50" disabled={!linked || typing || !text.trim()} aria-label="إرسال" data-testid="sim-send">
            {typing ? <Spinner className="h-4 w-4" /> : <Send className="h-4 w-4 -scale-x-100" />}
          </button>
        </form>
      </div>

      <details className="mt-4 rounded-2xl border border-ink-100 bg-white p-3 text-xs text-ink-600">
        <summary className="cursor-pointer font-semibold text-ink-800">تجربة رد الموظف من جوال الفرع</summary>
        <p className="mt-2">عندما يكتب الموظف للنزيل بنفسه، يصمت المساعد في تلك المحادثة (المدة من إعدادات واتساب الفروع) ويظهر الرد في الوارد. ردود الموظفين من «الوارد الموحد» تظهر هنا أيضًا.</p>
        <form onSubmit={(e) => { e.preventDefault(); staffReply(); }} className="mt-2 flex gap-2">
          <input value={staffText} onChange={(e) => setStaffText(e.target.value)} className="input flex-1" placeholder="رد الموظف…" aria-label="رد الموظف" disabled={!linked} data-testid="sim-staff-input" />
          <button type="submit" className="btn-outline text-xs" disabled={!linked || !staffText.trim()}>إرسال كموظف</button>
        </form>
      </details>
    </div>
  );
}
