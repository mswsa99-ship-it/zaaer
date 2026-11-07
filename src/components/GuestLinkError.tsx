/**
 * GUEST-22: one page for a guest link that does not open — the reason in plain words, «إعادة التحقق» to find the
 * booking again, and the trace code small, for the reception if the guest calls. GUEST-10: in the guest's language.
 */
import { Link } from "react-router-dom";
import { AlertCircle } from "lucide-react";
import { Card } from "./ui";
import { useGuestLang } from "../lib/guestLang";

export function GuestLinkError({ message }: { message: string }) {
  const { t } = useGuestLang();
  const m = message.match(/\s*\((?:رمز التتبع|trace):\s*([^)]+)\)\s*$/);
  const text = m ? message.slice(0, m.index).trim() : message;
  return (
    <div className="mx-auto max-w-md px-4 py-12" data-testid="guest-link-error">
      <Card>
        <div className="flex items-start gap-3">
          <AlertCircle className="mt-0.5 h-5 w-5 shrink-0 text-danger-600" aria-hidden="true" />
          <div>
            <h1 className="text-base font-semibold text-ink-800">{text || t("الرابط غير صالح", "This link is not valid")}</h1>
            <p className="mt-1 text-sm text-ink-600">{t("افتح «حجوزاتي» برقم جوالك لتحصل على رابط جديد، أو تواصل مع الاستقبال.", "Open «My bookings» with your mobile number to get a new link, or contact the reception.")}</p>
            {m && <p className="mt-2 text-[11px] text-ink-500">{t("للاستقبال:", "For the reception:")} <span className="font-mono" dir="ltr">{m[1]}</span></p>}
          </div>
        </div>
        <Link to="/booking/lookup" className="btn-primary mt-4 w-full justify-center">{t("فتح حجوزاتي", "Open my bookings")}</Link>
      </Card>
    </div>
  );
}
