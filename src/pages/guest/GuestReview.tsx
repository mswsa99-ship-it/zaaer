/**
 * «تقييم الإقامة» (W5, migration 0070): the one invitation a guest gets on WhatsApp 60 minutes after the confirmed
 * check-out opens this page by its key (open for 14 days, answered once). The overall mark out of 10 is asked first, on
 * its own — never the aspects' average — then the six aspects, then an optional comment. A mark under the branch's
 * threshold alerts the owner at once (the server's rule); the reception's answer reaches the guest on WhatsApp.
 */
import { useEffect, useState } from "react";
import { useParams } from "react-router-dom";
import { Star, CheckCircle2, MessageSquareText } from "lucide-react";
import { journeyApi, type PublicReview, type ReviewAspect, type ReviewMarks } from "../../lib/api";
import { Card, Spinner, ErrorBanner } from "../../components/ui";
import { GuestLinkError } from "../../components/GuestLinkError";
import { useGuestLang, guestError } from "../../lib/guestLang";

const ASPECT_EN: Record<ReviewAspect, string> = { staff: "Staff", cleanliness: "Cleanliness", comfort: "Comfort", facilities: "Facilities", value: "Value for money", location: "Location" };
const MARKS = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];

function MarkPicker({ name, label, value, onChange, big }: { name: string; label: string; value: number | null; onChange: (n: number) => void; big?: boolean }) {
  return (
    <fieldset className="min-w-0" data-testid={`mark-${name}`}>
      <legend className={big ? "mb-2 text-base font-semibold text-ink-800" : "mb-1.5 text-sm font-medium text-ink-700"}>{label}</legend>
      <div className="grid grid-cols-5 gap-1.5 sm:grid-cols-10" role="radiogroup" aria-label={label}>
        {MARKS.map((n) => (
          <button key={n} type="button" role="radio" aria-checked={value === n} onClick={() => onChange(n)}
            className={`min-h-[44px] rounded-xl border text-sm font-semibold tabular-nums transition ${value === n ? "border-brand-600 bg-brand-600 text-white" : "border-ink-200 bg-white text-ink-700 hover:border-brand-300"}`}>{n}</button>
        ))}
      </div>
    </fieldset>
  );
}

export default function GuestReview() {
  const { token } = useParams();
  const { en, t } = useGuestLang();
  const [info, setInfo] = useState<PublicReview | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [marks, setMarks] = useState<Partial<ReviewMarks>>({});
  const [comment, setComment] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState(false);

  useEffect(() => {
    if (!token) return;
    journeyApi.review(token).then(setInfo, (e) => setLoadError(guestError(e, en)));
  }, [token, en]);

  if (loadError) return <GuestLinkError message={loadError} />;
  if (!info) return <div className="mx-auto max-w-md px-4 py-12"><Spinner className="mx-auto h-8 w-8" /></div>;

  const keys: Array<"overall" | ReviewAspect> = ["overall", ...info.aspects.map((a) => a.key)];
  const complete = keys.every((k) => marks[k] != null);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    if (!token) return;
    if (!complete) { setError(t("قيّم الدرجة العامة وكل جانب من 1 إلى 10.", "Rate the overall stay and each aspect from 1 to 10.")); return; }
    setBusy(true); setError(null);
    try { await journeyApi.submitReview(token, { ...(marks as ReviewMarks), comment: comment.trim() || undefined }); setDone(true); }
    catch (err) { setError(guestError(err, en)); }
    setBusy(false);
  }

  return (
    <div className="mx-auto max-w-lg px-4 py-8" data-testid="guest-review">
      <Card className="space-y-5">
        <div>
          <p className="text-sm font-semibold text-brand-700" dir="auto">{info.branch_name}</p>
          <h1 className="mt-1 flex items-center gap-2 text-xl font-bold text-ink-800"><Star className="h-5 w-5 text-accent-600" /> {t("تقييم إقامتك", "Rate your stay")}</h1>
          {info.check_in && <p className="mt-1 text-sm text-ink-500"><span dir="ltr">{info.check_in} → {info.check_out}</span></p>}
        </div>

        {done || info.submitted ? (
          <div className="space-y-3" role="status" data-testid="review-thanks">
            <p className="flex items-center gap-2 rounded-xl bg-success-500/10 p-3 text-sm font-semibold text-success-700"><CheckCircle2 className="h-4 w-4" /> {t("شكرًا لك، وصل تقييمك.", "Thank you — your review has been received.")}</p>
            {info.reply && (
              <div className="rounded-xl bg-ink-50 p-3 text-sm text-ink-700" data-testid="review-reply">
                <p className="mb-1 flex items-center gap-1.5 font-semibold text-ink-800"><MessageSquareText className="h-4 w-4" /> {t("رد الإدارة", "The management's reply")}</p>
                <p className="whitespace-pre-line" dir="auto">{info.reply}</p>
              </div>
            )}
          </div>
        ) : (
          <form className="space-y-5" onSubmit={submit} noValidate>
            <MarkPicker name="overall" big label={t("تقييمك العام للإقامة من 10", "Your overall rating of the stay, out of 10")} value={marks.overall ?? null} onChange={(n) => setMarks({ ...marks, overall: n })} />
            <div className="space-y-4 border-t border-ink-100 pt-4">
              <p className="text-sm text-ink-500">{t("ثم قيّم كل جانب من 1 إلى 10:", "Then rate each aspect from 1 to 10:")}</p>
              {info.aspects.map((a) => (
                <MarkPicker key={a.key} name={a.key} label={en ? ASPECT_EN[a.key] ?? a.label : a.label} value={marks[a.key] ?? null} onChange={(n) => setMarks({ ...marks, [a.key]: n })} />
              ))}
            </div>
            <label className="block">
              <span className="label">{t("تعليقك (اختياري)", "Your comment (optional)")}</span>
              <textarea className="input min-h-[96px]" maxLength={1000} value={comment} onChange={(e) => setComment(e.target.value)} dir="auto" data-testid="review-comment" />
            </label>
            {error && <ErrorBanner message={error} />}
            <button type="submit" className="btn-primary w-full justify-center" disabled={busy} data-testid="review-submit">{busy ? <Spinner className="h-4 w-4" /> : t("إرسال التقييم", "Send the review")}</button>
          </form>
        )}
      </Card>
    </div>
  );
}
