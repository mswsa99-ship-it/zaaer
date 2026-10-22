import { useState } from "react";
import { FlaskConical, RotateCcw, X } from "lucide-react";
import { isDemo } from "../lib/supabase";

const APP_ENV = (import.meta.env.VITE_APP_ENV ?? "").toLowerCase();

/**
 * Shown on every screen of the demo build (data is synthetic and lives in this browser only), and on
 * every screen of a non-production deployment (staging), so nobody mistakes it for the live system.
 */
export function DemoBanner() {
  const [hidden, setHidden] = useState(false);
  if (!isDemo && APP_ENV && APP_ENV !== "production") {
    return (
      <div className="relative z-30 flex items-center justify-center gap-2 bg-brand-600 px-4 py-1 text-center text-[12px] font-medium text-white" role="status">
        <FlaskConical className="h-3.5 w-3.5" /> بيئة التطوير ({APP_ENV}) — بيانات تجريبية فقط، لا تُدخل بيانات نزلاء حقيقية
      </div>
    );
  }
  if (!isDemo || hidden) return null;
  const reset = async () => { const m = await import("../demo/client"); m.resetDemo(); window.location.reload(); };
  return (
    <div className="relative z-30 flex flex-wrap items-center justify-center gap-x-4 gap-y-1 bg-warning-500/15 px-4 py-1.5 text-center text-[12px] text-warning-600">
      <span className="inline-flex items-center gap-1.5 font-medium"><FlaskConical className="h-3.5 w-3.5" /> عرض تجريبي — البيانات افتراضية وتُحفظ في متصفحك فقط؛ لا يوجد خادم أو مزود ذكاء اصطناعي متصل.</span>
      <button onClick={reset} className="inline-flex items-center gap-1 underline-offset-2 hover:underline"><RotateCcw className="h-3 w-3" /> إعادة ضبط البيانات</button>
      <button onClick={() => setHidden(true)} className="absolute left-2 top-1 text-warning-600/70 hover:text-warning-600" aria-label="إخفاء"><X className="h-3.5 w-3.5" /></button>
    </div>
  );
}
