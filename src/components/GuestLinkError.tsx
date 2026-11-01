/**
 * GUEST-22: one page for a guest link that does not open — the reason in plain words, «إعادة التحقق» to find the
 * booking again, and the trace code small, for the reception if the guest calls.
 */
import { Link } from "react-router-dom";
import { AlertCircle } from "lucide-react";
import { Card } from "./ui";

export function GuestLinkError({ message }: { message: string }) {
  const m = message.match(/\s*\(رمز التتبع:\s*([^)]+)\)\s*$/);
  const text = m ? message.slice(0, m.index).trim() : message;
  return (
    <div className="mx-auto max-w-md px-4 py-12" data-testid="guest-link-error">
      <Card>
        <div className="flex items-start gap-3">
          <AlertCircle className="mt-0.5 h-5 w-5 shrink-0 text-danger-600" aria-hidden="true" />
          <div>
            <h1 className="text-base font-semibold text-ink-800">{text || "الرابط غير صالح"}</h1>
            <p className="mt-1 text-sm text-ink-600">اعرض حجزك من جديد برقم جوالك، أو تواصل مع الاستقبال.</p>
            {m && <p className="mt-2 text-[11px] text-ink-500">للاستقبال: <span className="font-mono" dir="ltr">{m[1]}</span></p>}
          </div>
        </div>
        <Link to="/booking/lookup" className="btn-primary mt-4 w-full justify-center">إعادة التحقق</Link>
      </Card>
    </div>
  );
}
