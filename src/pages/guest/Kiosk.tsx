import { useEffect, useState, useRef } from "react";
import { useNavigate } from "react-router-dom";
import { Hotel, RotateCcw } from "lucide-react";
import WhatsAppEntry from "../../components/WhatsAppEntry";

const IDLE_LIMIT_MS = Number(import.meta.env.VITE_KIOSK_IDLE_MS ?? 90_000);

export default function Kiosk() {
  const navigate = useNavigate();
  const [idle, setIdle] = useState(false);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  function reset() {
    setIdle(false);
    if (timerRef.current) clearTimeout(timerRef.current);
    timerRef.current = setTimeout(() => {
      // wipe anything the previous guest left in this browser session (conversation id, branch, fingerprint)
      try { sessionStorage.clear(); } catch { /* ignore */ }
      setIdle(true);
    }, IDLE_LIMIT_MS);
  }

  useEffect(() => {
    reset();
    const handler = () => reset();
    window.addEventListener("mousemove", handler);
    window.addEventListener("touchstart", handler);
    window.addEventListener("keydown", handler);
    return () => {
      window.removeEventListener("mousemove", handler);
      window.removeEventListener("touchstart", handler);
      window.removeEventListener("keydown", handler);
      if (timerRef.current) clearTimeout(timerRef.current);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  if (idle) {
    return (
      <div className="flex min-h-screen flex-col items-center justify-center bg-ink-900 text-center text-white">
        <Hotel className="mb-6 h-16 w-16 text-accent-500" />
        <h1 className="text-3xl font-bold">فايف اورز</h1>
        <p className="mt-3 text-white/70">انقر للبدء من جديد</p>
        <button onClick={() => { setIdle(false); navigate("/kiosk"); window.location.reload(); }} className="mt-8 flex items-center gap-2 rounded-2xl bg-accent-500 px-8 py-4 text-lg font-medium hover:bg-accent-600">
          <RotateCcw className="h-5 w-5" /> ابدأ
        </button>
        <p className="mt-6 text-xs text-white/40">تم مسح بيانات الجلسة السابقة لأسباب الخصوصية.</p>
      </div>
    );
  }

  // the lobby screen shows the branch's WhatsApp QR: guests continue on their own phone (nothing typed on a shared screen)
  return (
    <div className="flex min-h-screen flex-col items-center justify-center bg-gradient-to-b from-brand-50 to-white">
      <WhatsAppEntry large />
      <p className="mt-2 text-xs text-ink-400">تعود الشاشة للبداية تلقائيًا بعد دقيقة من الخمول.</p>
    </div>
  );
}
