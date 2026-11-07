import { useEffect, useState, useRef } from "react";
import { GuestLinkError } from "../../components/GuestLinkError";
import { useParams, Link } from "react-router-dom";
import { ArrowRight, ArrowLeft, KeyRound, Lock, CheckCircle2, AlertCircle, EyeOff } from "lucide-react";
import { guestApi } from "../../lib/api";
import { useGuestLang, guestError, reasonEn } from "../../lib/guestLang";
import { Card, Spinner } from "../../components/ui";

const AUTO_HIDE_MS = 60_000;

/**
 * The code is fetched from the server ONLY when the guest presses "عرض" and the
 * backend gate (fn_guest_access_code) confirms delivery for this exact
 * reservation. Nothing is pre-loaded into the page, and it auto-hides.
 */
export default function CheckIn() {
  const { token } = useParams();
  const [loading, setLoading] = useState(true);
  const [reasons, setReasons] = useState<string[]>([]);
  const [eligible, setEligible] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [code, setCode] = useState<{ code: string; room: string } | null>(null);
  const [revealing, setRevealing] = useState(false);
  const hideTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const { en, t } = useGuestLang();
  const enRef = useRef(en); enRef.current = en;

  useEffect(() => {
    (async () => {
      if (!token) return;
      try {
        const s = await guestApi.session(token);
        setEligible(["delivered", "acknowledged"].includes(s.reservation.access_status) && s.access.allowed);
        setReasons(s.access.reasons ?? []);
      } catch (e) { setError(guestError(e, enRef.current)); }
      setLoading(false);
    })();
    return () => { if (hideTimer.current) clearTimeout(hideTimer.current); };
  }, [token]);

  async function reveal() {
    if (!token) return;
    setRevealing(true);
    try {
      const r = await guestApi.accessCode(token);
      if (r.allowed && r.code) {
        setCode({ code: r.code, room: r.room_number ?? "" });
        hideTimer.current = setTimeout(() => setCode(null), AUTO_HIDE_MS);
      } else {
        setEligible(false); setReasons(r.reasons ?? ["لم يُسلَّم الرمز بعد"]);
      }
    } catch (e) { setError(guestError(e, en)); }
    setRevealing(false);
  }

  if (loading) return <div className="mx-auto max-w-md px-4 py-12"><Spinner className="mx-auto h-8 w-8" /></div>;
  if (error) return <GuestLinkError message={error} />;

  return (
    <div className="mx-auto max-w-md px-4 py-8 lg:py-12">
      <Link to={`/booking/status/${token}`} className="mb-4 inline-flex items-center gap-1.5 text-sm text-ink-400 hover:text-ink-600">{en ? <ArrowLeft className="h-4 w-4" /> : <ArrowRight className="h-4 w-4" />} {t("حالة الحجز", "Booking status")}</Link>

      <div className="mb-6 text-center">
        <div className="mx-auto mb-3 flex h-14 w-14 items-center justify-center rounded-2xl bg-accent-500/10 text-accent-700"><KeyRound className="h-7 w-7" /></div>
        <h1 className="text-2xl font-bold text-ink-800">{t("رمز صندوق المفتاح", "Key-box code")}</h1>
        <p className="mt-2 text-sm text-ink-500">{t("يُعرض الرمز فقط بعد استيفاء جميع شروط تسليم الرمز واعتماد المشرف، ويختفي تلقائيًا بعد دقيقة.", "The code shows only when every entry condition is met and the reception has approved it. It hides itself after one minute.")}</p>
      </div>

      {eligible ? (
        <Card className="text-center">
          <CheckCircle2 className="mx-auto mb-3 h-10 w-10 text-success-600" />
          {code ? (
            <div className="my-6">
              <p className="text-xs text-ink-400">{t(`وحدة ${code.room} — رمز الصندوق`, `Unit ${code.room} — key-box code`)}</p>
              <p className="mt-2 select-all text-4xl font-bold tracking-[0.5em] text-brand-700" dir="ltr">{code.code}</p>
              <p className="mt-3 text-xs text-warning-700">{t("الرمز خاص بك؛ يُرجى عدم مشاركته. سيُغيَّر بعد مغادرتك.", "Do not share the code. It is changed after you leave.")}</p>
              <button onClick={() => setCode(null)} className="btn-outline mt-4 text-xs"><EyeOff className="h-3.5 w-3.5" /> {t("إخفاء", "Hide")}</button>
            </div>
          ) : (
            <>
              <p className="text-sm text-ink-600">{t("جميع شروط تسليم الرمز مستوفاة. عرض رمز الصندوق:", "All entry conditions are met. Tap to show the key-box code.")}</p>
              <button onClick={reveal} disabled={revealing} className="btn-accent mt-5">{revealing ? <Spinner /> : <><KeyRound className="h-4 w-4" /> {t("عرض الرمز", "Show the code")}</>}</button>
            </>
          )}
        </Card>
      ) : (
        <Card className="border-danger-500/30">
          <div className="flex items-start gap-3">
            <Lock className="mt-0.5 h-6 w-6 shrink-0 text-danger-500" />
            <div>
              <p className="text-sm font-semibold text-ink-800">{t("لا يمكن عرض الرمز حاليًا", "The code cannot be shown yet")}</p>
              <p className="mt-1 text-xs text-ink-500">{t("يجب استيفاء الشروط التالية واعتماد المشرف:", "Still needed, then approval by the reception:")}</p>
              <ul className="mt-3 space-y-1.5">
                {reasons.map((r, i) => <li key={i} className="flex items-start gap-2 text-xs text-danger-600"><AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" /> {en ? reasonEn(r) : r}</li>)}
              </ul>
            </div>
          </div>
        </Card>
      )}
    </div>
  );
}
