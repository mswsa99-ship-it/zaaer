/**
 * The guest's journey on their booking page (migrations 0070–0071; plan «خطة تصحيح ملاحظات التجربة», م٤):
 *  - W3 «يوم المغادرة»: on the day of departure the guest chooses — leaving between 12 and 1 (free), one night more
 *    (when the unit is free tonight), or hours after the free hour at the branch's price each (a part of an hour is a
 *    whole hour), up to the next guest less the cleaning hour. A night or hours are held while the guest pays at the
 *    reception, and given back when not paid in time;
 *  - W4 the departure: the instructions (and the unit's way out, when its photos are approved) come first, then
 *    «غادرت وسلّمت المفتاح»; the reception checks the unit and confirms the check-out, and the deposit is returned
 *    within its hours from that confirmation — the guest is told on WhatsApp at each step;
 *  - W7 the unit's way in and out: approved photos only; a unit without them is explained by the reception.
 * Everything here is the server's (fn_guest_checkout, fn_guest_checkout_choose, fn_guest_departure, fn_guest_unit_guide).
 */
import { useCallback, useEffect, useState } from "react";
import { LogOut, Moon, Clock, CheckCircle2, DoorOpen, Images, Undo2 } from "lucide-react";
import { journeyApi, branchGuideApi, type CheckoutOffer, type UnitGuide } from "../lib/api";
import { Card, Spinner, ErrorBanner } from "./ui";
import { useGuestLang, guestError, moneyEn } from "../lib/guestLang";
import { formatCurrency } from "../lib/utils";

const hoursAr = (n: number) => (n === 1 ? "ساعة واحدة" : n === 2 ? "ساعتان" : n <= 10 ? `${n} ساعات` : `${n} ساعة`);
const hoursEn = (n: number) => (n === 1 ? "1 hour" : `${n} hours`);
/** "13:00" + n hours → "15:00" (midnight is 24:00, the end of the day of departure) */
const plusHours = (hm: string, n: number) => { const [h, m] = hm.split(":").map(Number); const t = h * 60 + m + n * 60; return t >= 1440 ? "24:00" : `${String(Math.floor(t / 60)).padStart(2, "0")}:${String(t % 60).padStart(2, "0")}`; };
const clock = (iso: string | null | undefined) => (iso ? new Date(iso).toLocaleTimeString("en-GB", { timeZone: "Asia/Riyadh", hour: "2-digit", minute: "2-digit" }) : "");

/** the unit's way in or out, as approved photos (nothing at all when none is approved) */
export function GuestUnitGuide({ token, purpose, className = "mt-6" }: { token: string; purpose: "checkin" | "checkout"; className?: string }) {
  const [g, setG] = useState<UnitGuide | null>(null);
  const [photos, setPhotos] = useState<Record<string, string>>({});
  const { t } = useGuestLang();
  useEffect(() => {
    let live = true;
    journeyApi.unitGuide(token, purpose).then(async (x) => {
      if (!live) return; setG(x);
      const out: Record<string, string> = {};
      for (const p of (x?.photos ?? []).slice(0, 12)) { const d = await branchGuideApi.photo(p.id).catch(() => null); if (d) out[p.id] = d; }
      if (live) setPhotos(out);
    }).catch(() => setG(null));
    return () => { live = false; };
  }, [token, purpose]);
  if (!g?.ready || !g.photos?.length) return null;
  const shown = g.photos.filter((p) => photos[p.id]);
  if (!shown.length) return null;
  return (
    <Card className={className} data-testid={`guest-unit-guide-${purpose}`}>
      <h2 className="mb-2 flex items-center gap-2 text-base font-semibold text-ink-800">
        <Images className="h-4 w-4 text-brand-600" />
        {purpose === "checkin" ? t(`طريقة الدخول إلى وحدتك ${g.room_number ?? ""}`, `How to enter your unit ${g.room_number ?? ""}`) : t("طريقة المغادرة وتسليم المفتاح", "How to leave and hand over the key")}
      </h2>
      <ol className="grid gap-3 sm:grid-cols-2">
        {shown.map((p, i) => (
          <li key={p.id}>
            <figure>
              <img src={photos[p.id]} alt={p.caption ?? t(`الخطوة ${i + 1}`, `Step ${i + 1}`)} loading="lazy" className="aspect-[4/3] w-full rounded-lg object-cover" />
              <figcaption className="mt-1 text-sm text-ink-600" dir="auto"><span className="font-semibold text-ink-700">{i + 1}.</span> {p.caption ?? ""}</figcaption>
            </figure>
          </li>
        ))}
      </ol>
    </Card>
  );
}

/** «يوم المغادرة»: the options, the held request, the instructions, then «غادرت وسلّمت المفتاح» */
export function GuestCheckoutPanel({ token, onChanged }: { token: string; onChanged?: () => void }) {
  const [o, setO] = useState<CheckoutOffer | null>(null);
  const [hours, setHours] = useState(1);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [confirming, setConfirming] = useState(false);
  const { en, t } = useGuestLang();
  const money = (h: number | null | undefined) => (en ? moneyEn((h ?? 0) / 100) : formatCurrency((h ?? 0) / 100));

  const load = useCallback(async () => {
    try { setO(await journeyApi.checkout(token)); } catch { setO(null); }
  }, [token]);
  useEffect(() => { void load(); const id = setInterval(() => { if (document.visibilityState === "visible") void load(); }, 30_000); return () => clearInterval(id); }, [load]);

  async function act(key: string, fn: () => Promise<unknown>) {
    setBusy(key); setError(null);
    try { const out = await fn(); if (out && typeof out === "object" && "open" in (out as object)) setO(out as CheckoutOffer); else await load(); onChanged?.(); }
    catch (e) { setError(guestError(e, en)); await load(); }
    setBusy(null);
  }

  if (!o || o.status !== "checked_in") return null;
  const req = o.request && ["held", "overdue"].includes(o.request.status) ? o.request : null;
  const settled = o.request && ["paid", "confirmed"].includes(o.request.status) ? o.request : null;
  // nothing to say before the day of departure (a night already added moves the day: its confirmation stays visible)
  if (!o.open && !req && !settled && !o.departed_at) return null;
  const maxH = Math.min(o.hours.max, 12);
  const pick = Math.min(Math.max(1, hours), Math.max(1, maxH));

  return (
    <Card className="mt-6 space-y-4" data-testid="guest-checkout">
      <h2 className="flex items-center gap-2 text-base font-semibold text-ink-800"><LogOut className="h-4 w-4 text-brand-600" /> {t("يوم المغادرة", "Departure day")}</h2>
      {error && <ErrorBanner message={error} />}

      {o.departed_at ? (
        <div className="space-y-2 rounded-xl bg-success-500/10 p-3 text-sm text-success-700" role="status" data-testid="guest-departed">
          <p className="flex items-center gap-2 font-semibold"><CheckCircle2 className="h-4 w-4" /> {t(`أبلغت الاستقبال بمغادرتك الساعة ${clock(o.departed_at)}`, `You told the reception you left at ${clock(o.departed_at)}`)}</p>
          <p className="text-ink-700">{t("يفحص الاستقبال الوحدة ثم يؤكد خروجك، ويصلك التأكيد على واتساب.", "The reception checks the unit and confirms your check-out; the confirmation reaches you on WhatsApp.")}</p>
          {o.deposit_halalas > 0 && <p className="text-ink-700" data-testid="guest-deposit-note">{t(`يُرد تأمينك (${money(o.deposit_halalas)}) خلال ${hoursAr(o.refund_hours)} من تأكيد الخروج: تحويلًا إلى حسابك أو نقدًا من الاستقبال، ويصلك إيصال الرد.`, `Your deposit (${money(o.deposit_halalas)}) is returned within ${hoursEn(o.refund_hours)} of the confirmed check-out — by transfer or in cash at the reception — and you receive its receipt.`)}</p>}
        </div>
      ) : (
        <>
          {req && (
            <div className="space-y-2 rounded-xl bg-warning-500/10 p-3 text-sm text-warning-800" data-testid="guest-extension-held">
              <p className="font-semibold">{req.kind === "night" ? t("طلبت ليلة إضافية", "You asked for one more night") : t(`طلبت خروجًا متأخرًا حتى ${req.late_until}`, `You asked to leave late, until ${req.late_until}`)} — {money(req.amount_halalas)}</p>
              {req.status === "held"
                ? <p className="text-ink-700">{t(`محجوزة لك حتى ${clock(req.hold_until)}. ادفع المبلغ لدى الاستقبال (نقدًا أو بالشبكة أو بالتحويل) ليُثبَّت الطلب، وإلا أُلغي تلقائيًا.`, `Held for you until ${clock(req.hold_until)}. Pay at the reception (cash, card or transfer) to keep it; otherwise it is cancelled automatically.`)}</p>
                : <p className="text-ink-700">{t("انتهت مهلة الدفع؛ تواصل مع الاستقبال لإتمام الدفع أو إلغاء الطلب.", "The time to pay is over; please see the reception to pay or cancel.")}</p>}
              {req.status === "held" && (
                <button type="button" className="btn-outline text-sm" disabled={busy !== null} onClick={() => act("cancel", () => journeyApi.choose(token, "cancel"))} data-testid="guest-extension-cancel">
                  {busy === "cancel" ? <Spinner className="h-4 w-4" /> : <><Undo2 className="h-4 w-4" /> {t("إلغاء الطلب", "Cancel the request")}</>}
                </button>
              )}
            </div>
          )}
          {settled && (
            <p className="flex items-center gap-2 rounded-xl bg-success-500/10 p-3 text-sm font-semibold text-success-700" role="status" data-testid="guest-extension-settled">
              <CheckCircle2 className="h-4 w-4" />
              {settled.kind === "night" ? t(`تم تثبيت ليلتك الإضافية. موعد خروجك ${o.check_out} بين 12 و1 ظهرًا.`, `Your extra night is confirmed. You leave on ${o.check_out}, between 12 and 1 PM.`) : t(`خروجك المتأخر حتى ${settled.late_until} مثبّت.`, `Your late check-out until ${settled.late_until} is confirmed.`)}
            </p>
          )}

          {o.open && !req && !settled && (o.choice === "on_time" ? (
            <p className="flex items-center gap-2 rounded-xl bg-brand-50 p-3 text-sm text-brand-700" role="status" data-testid="guest-on-time"><CheckCircle2 className="h-4 w-4" /> {t(`تم. موعد خروجك اليوم قبل ${o.free_until}.`, `Done. Please leave today before ${o.free_until}.`)}</p>
          ) : (
            <div className="space-y-2" data-testid="guest-checkout-options">
              <p className="text-sm text-ink-600">{t(`موعد خروجك اليوم بين 12 و1 ظهرًا (حتى ${o.free_until} بلا رسوم). ماذا تفضّل؟`, `You leave today between 12 and 1 PM (until ${o.free_until} at no charge). What would you like?`)}</p>
              <button type="button" className="btn-primary w-full justify-center" disabled={busy !== null} onClick={() => act("on_time", () => journeyApi.choose(token, "on_time"))} data-testid="choose-on-time">
                {busy === "on_time" ? <Spinner className="h-4 w-4" /> : <><DoorOpen className="h-4 w-4" /> {t("سأخرج في الموعد (12–1)", "I will leave on time (12–1)")}</>}
              </button>
              {o.night.available && (
                <button type="button" className="btn-outline w-full justify-center" disabled={busy !== null} onClick={() => act("night", () => journeyApi.choose(token, "night"))} data-testid="choose-night">
                  {busy === "night" ? <Spinner className="h-4 w-4" /> : <><Moon className="h-4 w-4" /> {t(`ليلة إضافية — ${money(o.night.price_halalas)}`, `One more night — ${money(o.night.price_halalas)}`)}</>}
                </button>
              )}
              {maxH > 0 && (
                <div className="rounded-xl border border-ink-100 p-3" data-testid="choose-hours">
                  <p className="mb-2 flex items-center gap-2 text-sm font-semibold text-ink-700"><Clock className="h-4 w-4 text-brand-600" /> {t(`ساعات بعد ${o.free_until} — ${money(o.hours.price_halalas)} للساعة`, `Hours after ${o.free_until} — ${money(o.hours.price_halalas)} per hour`)}</p>
                  <div className="flex flex-wrap items-center gap-2">
                    <label className="sr-only" htmlFor="late-hours">{t("عدد الساعات", "Number of hours")}</label>
                    <select id="late-hours" className="input w-auto min-w-0" value={pick} onChange={(e) => setHours(Number(e.target.value))}>
                      {Array.from({ length: maxH }, (_, i) => i + 1).map((n) => <option key={n} value={n}>{t(`${hoursAr(n)} — حتى ${plusHours(o.free_until, n)}`, `${hoursEn(n)} — until ${plusHours(o.free_until, n)}`)}</option>)}
                    </select>
                    <button type="button" className="btn-outline text-sm" disabled={busy !== null} onClick={() => act("hours", () => journeyApi.choose(token, "hours", pick))} data-testid="choose-hours-submit">
                      {busy === "hours" ? <Spinner className="h-4 w-4" /> : t(`اطلب (${money((o.hours.price_halalas ?? 0) * pick)})`, `Request (${money((o.hours.price_halalas ?? 0) * pick)})`)}
                    </button>
                  </div>
                  <p className="mt-2 text-xs text-ink-500">{t("جزء الساعة يُحتسب ساعة كاملة.", "Part of an hour counts as a whole hour.")}{o.hours.next_guest ? t(` الحد ${o.hours.until_limit} لوجود ضيف بعدك وساعة لتنظيف الوحدة.`, ` Until ${o.hours.until_limit} at the latest: another guest arrives after you and the unit is cleaned first.`) : ""}</p>
                </div>
              )}
              {!o.night.available && maxH === 0 && <p className="text-xs text-ink-500">{t("الوحدة محجوزة بعدك اليوم، فلا يتاح تمديد. للمساعدة تواصل مع الاستقبال.", "The unit is booked after you today, so no extension is available. Please see the reception for help.")}</p>}
            </div>
          ))}

          {o.open && (
            <div className="space-y-3 border-t border-ink-100 pt-3" data-testid="guest-departure">
              <h3 className="text-sm font-semibold text-ink-800">{t("قبل المغادرة", "Before you leave")}</h3>
              <p className="whitespace-pre-line text-sm leading-7 text-ink-600" dir="auto" data-testid="guest-checkout-instructions">
                {o.instructions || t("تأكد من أغراضك، وأطفئ الأنوار والمكيف، وأغلق الباب، ثم ضع المفتاح أو البطاقة في مكانه أو سلّمه للاستقبال.", "Check your belongings, switch off the lights and the air conditioning, close the door, then leave the key or card in its place or hand it to the reception.")}
              </p>
              {o.guide_checkout && <GuestUnitGuide token={token} purpose="checkout" className="" />}
              {confirming ? (
                <div className="space-y-2 rounded-xl border border-brand-200 bg-brand-50 p-3" role="group" aria-label={t("تأكيد المغادرة", "Confirm departure")}>
                  <p className="text-sm font-medium text-ink-800">{t("هل غادرت الوحدة وسلّمت المفتاح؟", "Have you left the unit and handed over the key?")}</p>
                  <div className="flex flex-wrap gap-2">
                    <button type="button" className="btn-primary" disabled={busy !== null} onClick={async () => { await act("depart", () => journeyApi.departure(token)); setConfirming(false); }} data-testid="guest-departure-confirm">
                      {busy === "depart" ? <Spinner className="h-4 w-4" /> : t("نعم، غادرت", "Yes, I have left")}
                    </button>
                    <button type="button" className="btn-outline" disabled={busy !== null} onClick={() => setConfirming(false)}>{t("رجوع", "Back")}</button>
                  </div>
                </div>
              ) : (
                <button type="button" className="btn-primary w-full justify-center" disabled={busy !== null} onClick={() => setConfirming(true)} data-testid="guest-departure-button">
                  <LogOut className="h-4 w-4" /> {t("غادرت وسلّمت المفتاح", "I have left and handed over the key")}
                </button>
              )}
              {o.balance_due > 0 && <p className="text-xs text-warning-700">{t(`على الحجز مبلغ مستحق ${money(o.balance_due)} يُسدَّد لدى الاستقبال قبل تأكيد الخروج.`, `${money(o.balance_due)} is still due on the booking; it is paid at the reception before the check-out is confirmed.`)}</p>}
            </div>
          )}
        </>
      )}
    </Card>
  );
}
