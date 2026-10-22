import { useEffect, useState, useRef } from "react";
import { useNavigate, Link } from "react-router-dom";
import { Hotel, RotateCcw } from "lucide-react";

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
        <h1 className="text-3xl font-bold">منازل الراحة</h1>
        <p className="mt-3 text-white/70">انقر للبدء من جديد</p>
        <button onClick={() => { setIdle(false); navigate("/kiosk"); window.location.reload(); }} className="mt-8 flex items-center gap-2 rounded-2xl bg-accent-500 px-8 py-4 text-lg font-medium hover:bg-accent-600">
          <RotateCcw className="h-5 w-5" /> ابدأ
        </button>
        <p className="mt-6 text-xs text-white/40">تم مسح بيانات الجلسة السابقة لأسباب الخصوصية.</p>
      </div>
    );
  }

  return (
    <div className="flex min-h-screen flex-col items-center justify-center bg-gradient-to-b from-brand-50 to-white px-6 text-center">
      <div className="mb-8 flex h-20 w-20 items-center justify-center rounded-3xl bg-brand-600 text-white">
        <Hotel className="h-10 w-10" />
      </div>
      <h1 className="text-4xl font-bold text-ink-800">أهلًا وسهلًا بك</h1>
      <p className="mt-4 max-w-md text-lg text-ink-500">مساعد الاستقبال الذكي جاهز لخدمتك. اختر كيف تبدأ.</p>
      <div className="mt-10 flex flex-col gap-4 sm:flex-row">
        <Link to="/reception?kiosk=1" className="btn-primary px-10 py-5 text-lg">تحدث مع الاستقبال الذكي</Link>
        <Link to="/booking/lookup" className="btn-outline px-10 py-5 text-lg">لدي حجز سابق</Link>
        <Link to="/booking/new" className="btn-accent px-10 py-5 text-lg">حجز جديد</Link>
      </div>
      <p className="mt-8 text-xs text-ink-300">تعود الشاشة للبداية تلقائيًا بعد دقيقة من الخمول.</p>
    </div>
  );
}
