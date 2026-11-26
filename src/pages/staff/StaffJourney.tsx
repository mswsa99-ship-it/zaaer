/**
 * «رحلة الضيف» (migration 0070; plan «خطة تصحيح ملاحظات التجربة», م٤): the reception's page for the guest's journey
 * after the stay — today's departures and what each guest chose (W3), the nights and late hours held while the guest
 * pays, the guests who said «غادرت وسلّمت المفتاح» and wait for the unit's check (W4), the deposits counting down from
 * the confirmed check-out, the reviews and their answers (W5), and the open alerts with who was told and when they climb
 * (W6) — each alert marked «لك» when its rule names the reader (the menu's badge counts those). Amounts show only to
 * those the permissions give money. The journey's clock runs when this page looks (and when the reception computer asks
 * for its messages).
 */
import { useCallback, useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { LogOut, Moon, Clock, Wallet, Star, BellRing, CheckCircle2, AlertTriangle, MessageCircle, ExternalLink, Settings } from "lucide-react";
import { mergeReviews } from "../../lib/journeyMerge";
import { journeyApi, toArabicError, type StaffJourney as Board, type StaffReviews, type StaffReview, type JourneyAlert, type ExtensionStatus } from "../../lib/api";
import { useBranch } from "../../lib/branch";
import { useAuth } from "../../lib/auth";
import { SectionTitle, Card, Badge, Spinner, LoadErrorCard, EmptyState, AmountBox, AmountGrid } from "../../components/ui";
import { Modal, ActionForm, Submit, ReasonInput, Field } from "../../components/forms";
import { BranchPicker } from "../../components/BranchPicker";
import { formatCurrency, formatDateTime, formatClock } from "../../lib/utils";

const sar = (h: number) => formatCurrency(h / 100);
const clock = (iso: string | null | undefined) => (iso ? new Date(iso).toLocaleTimeString("en-GB", { timeZone: "Asia/Riyadh", hour: "2-digit", minute: "2-digit" }) : "—");
const hoursAr = (n: number) => (n === 1 ? "ساعة واحدة" : n === 2 ? "ساعتان" : n <= 10 ? `${n} ساعات` : `${n} ساعة`);
/** "باقي ساعتان و10 دقائق" / "متأخر 25 دقيقة" */
function remaining(dueIso: string, now: number) {
  const m = Math.round((Date.parse(dueIso) - now) / 60_000);
  const span = (x: number) => { const h = Math.floor(x / 60), mm = x % 60; return [h ? hoursAr(h) : "", mm ? `${mm} دقيقة` : ""].filter(Boolean).join(" و") || "أقل من دقيقة"; };
  return m >= 0 ? { late: false, text: `باقي ${span(m)}` } : { late: true, text: `متأخر ${span(-m)}` };
}
const EXT_STATUS: Record<ExtensionStatus, [string, string]> = {
  held: ["محجوز بانتظار الدفع", "bg-warning-500/10 text-warning-700"], overdue: ["انتهت مهلة الدفع", "bg-danger-500/10 text-danger-600"],
  paid: ["مدفوع ومثبّت", "bg-success-50 text-success-700"], confirmed: ["مثبّت دون دفع", "bg-brand-50 text-brand-700"], released: ["أُلغي", "bg-ink-100 text-ink-600"],
};
const MESSAGE_AR: Record<string, string> = {
  queued: "أُرسلت الخيارات على واتساب", "skipped:no_phone": "لم تُرسل: لا جوال للنزيل", "skipped:channel_unavailable": "لم تُرسل: واتساب الفرع غير مربوط",
  "skipped:journey_off": "رسائل الرحلة متوقفة في الإعدادات",
};
type Tab = "departing" | "requests" | "awaiting" | "deposits" | "reviews" | "alerts";

export default function StaffJourney() {
  const { branchId, branches, allBranches, setBranchId } = useBranch();
  const [perBranch, setPerBranch] = useState<Array<{ id: string; name: string; settings: Board["settings"]; channel_ready: boolean }>>([]);
  const [branchOf, setBranchOf] = useState<Record<string, string>>({});   // owner «جميع الفروع»: row id to its branch name
  const { can, profile } = useAuth();
  const [tab, setTab] = useState<Tab>("departing");
  const [board, setBoard] = useState<Board | null>(null);
  const [reviews, setReviews] = useState<StaffReviews | null>(null);
  const [reviewParts, setReviewParts] = useState<Array<{ name: string; count: number; overall: number | null }>>([]);
  const [approx, setApprox] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const [now, setNow] = useState(Date.now());
  const [deciding, setDeciding] = useState<{ id: string; version: number; action: "confirm" | "release"; title: string } | null>(null);
  const [replying, setReplying] = useState<StaffReview | null>(null);
  const [resolving, setResolving] = useState<JourneyAlert | null>(null);
  const [onlyMine, setOnlyMine] = useState(false);
  const reload = useCallback(() => setTick((t) => t + 1), []);
  const canReviews = can("conversation.take");

  useEffect(() => {
    if (!branchId) return;
    let alive = true; setError(null);
    const ids = allBranches ? branches.map((x) => x.id) : [branchId];
    // the journey's clock first (its messages, its alerts), then the board; owner «جميع الفروع»: every branch, merged, each row keeps its branch
    Promise.all(ids.map((id) => journeyApi.tick(id).catch(() => null))).finally(() => {
      Promise.all(ids.map(async (id) => ({ id, board: await journeyApi.board(id), reviews: canReviews ? await journeyApi.reviews(id, 30).catch(() => null) : null })))
        .then((parts) => {
          if (!alive) return;
          if (parts.length === 1) { setPerBranch([]); setReviewParts([]); setApprox(false); setBranchOf({}); setBoard(parts[0].board); setReviews(parts[0].reviews); setNow(Date.now()); return; }
          const name = (id: string) => branches.find((x) => x.id === id)?.name_ar ?? "";
          const of: Record<string, string> = {};
          const tag = <T,>(rows: T[], key: (r: T) => string, id: string) => { rows.forEach((r) => { of[key(r)] = name(id); }); return rows; };
          const first = parts[0].board;
          const merged: Board = {
            settings: first.settings, sees_money: parts.every((x) => x.board.sees_money), channel_ready: parts.every((x) => x.board.channel_ready),
            departing: parts.flatMap((x) => tag(x.board.departing, (r) => r.reservation_id, x.id)),
            requests: parts.flatMap((x) => tag(x.board.requests, (r) => r.id, x.id)),
            awaiting_check: parts.flatMap((x) => tag(x.board.awaiting_check, (r) => r.reservation_id, x.id)),
            deposits: parts.flatMap((x) => tag(x.board.deposits, (r) => r.reservation_id, x.id)),
            alerts: parts.flatMap((x) => tag(x.board.alerts, (r) => r.id, x.id)),
          };
          const rvIds = parts.filter((y) => y.reviews).map((y) => y.id);
          const { merged: mergedReviews, exact } = mergeReviews(parts.map((x) => x.reviews).filter((x): x is StaffReviews => !!x));
          parts.filter((y) => y.reviews).forEach((y, k) => tag(y.reviews!.reviews, (r) => r.id, rvIds[k]));
          const complete0 = exact;
          setApprox(!!mergedReviews && !complete0); setReviewParts(parts.filter((x) => x.reviews).map((x) => ({ name: name(x.id), count: x.reviews!.summary.count, overall: x.reviews!.summary.overall })));
          setPerBranch(parts.map((x) => ({ id: x.id, name: name(x.id), settings: x.board.settings, channel_ready: x.board.channel_ready }))); setBranchOf(of); setBoard(merged); setReviews(mergedReviews); setNow(Date.now());
        }, (e) => { if (alive) setError(toArabicError(e)); });
    });
    return () => { alive = false; };
  }, [branchId, branches, allBranches, tick, canReviews]);
  // a guest's choice or departure arrives while the page is open: looked for again every minute
  useEffect(() => {
    const id = setInterval(() => { if (typeof document === "undefined" || document.visibilityState === "visible") reload(); }, 60_000);
    return () => clearInterval(id);
  }, [reload]);

  const b = board;
  const openRequests = useMemo(() => (b?.requests ?? []).filter((x) => x.status === "held" || x.status === "overdue"), [b]);
  const overdueDeposits = (b?.deposits ?? []).filter((d) => d.overdue).length;
  const mineCount = (b?.alerts ?? []).filter((a) => a.mine).length;
  const shownAlerts = (b?.alerts ?? []).filter((a) => !onlyMine || a.mine);
  const TABS: Array<[Tab, string, number | null]> = [
    ["departing", "المغادرون اليوم", b?.departing.length ?? null],
    ["requests", "طلبات التمديد", openRequests.length || null],
    ["awaiting", "بانتظار التحقق", b?.awaiting_check.length ?? null],
    ["deposits", "رد التأمين", b?.deposits.length ?? null],
    ...(canReviews ? [["reviews", "التقييمات", reviews?.summary.count ?? null] as [Tab, string, number | null]] : []),
    ["alerts", "التنبيهات", b?.alerts.length ?? null],
  ];

  return (
    <div>
      <SectionTitle title="رحلة الضيف" subtitle="يوم المغادرة وخيارات النزيل، والتحقق من الوحدة، وعدّاد رد التأمين، والتقييمات، والتنبيهات" action={
        <div className="flex min-w-0 flex-wrap items-center gap-2"><BranchPicker allowAll />
          {["owner", "manager"].includes(profile?.role ?? "") && <Link to="/admin/journey" className="btn-outline text-sm"><Settings className="h-4 w-4" /> الإعدادات</Link>}
        </div>} />
      {error ? <LoadErrorCard message={error} onRetry={reload} /> : !b ? <div className="py-10 text-center"><Spinner /></div> : (
        <>
          {!b.channel_ready && (
            <p className="mb-3 flex items-start gap-2 rounded-xl bg-warning-500/10 px-3 py-2 text-sm text-warning-800" role="alert" data-testid="journey-channel-warning">
              <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" /> {allBranches && perBranch.length ? `واتساب ${perBranch.filter((x) => !x.channel_ready).map((x) => x.name).join(" و")}` : "واتساب الفرع"} غير مربوط بكمبيوتر الاستقبال: رسائل الرحلة لا تصل للنزلاء، فأبلغهم بنفسك. يُربط من «واتساب الفروع» في الإدارة.
            </p>
          )}
          {!b.settings.journey_enabled && <p className="mb-3 rounded-xl bg-ink-50 px-3 py-2 text-sm text-ink-600" role="status">رسائل الرحلة متوقفة لهذا الفرع من الإعدادات؛ التنبيهات تعمل.</p>}
          <Card className="mb-4">
            <AmountGrid testId="journey-totals">
              {!allBranches && <AmountBox label="رسالة صباح المغادرة" value={formatClock(b.settings.checkout_message_time)} />}   {/* per-branch settings: not merged */}
              {!allBranches && <AmountBox label="الخروج بلا رسوم حتى" value={formatClock(b.settings.free_until)} />}
              <AmountBox label="بانتظار التحقق" value={<span data-testid="journey-awaiting-count">{b.awaiting_check.length}</span>} tone={b.awaiting_check.length ? "text-warning-700" : "text-ink-900"} />
              <AmountBox label={allBranches ? "رد التأمين" : `رد التأمين خلال ${hoursAr(b.settings.refund_hours)}`} value={overdueDeposits ? `${overdueDeposits} متأخر` : `${b.deposits.length}`} tone={overdueDeposits ? "text-danger-600" : "text-ink-900"} />
              <AmountBox label="تنبيهات مفتوحة" value={<span data-testid="journey-alerts-count">{b.alerts.length}</span>} tone={b.alerts.length ? "text-danger-600" : "text-ink-900"} />
            </AmountGrid>
          </Card>
          {allBranches && perBranch.length > 0 && (
            <Card className="mb-4" data-testid="journey-branch-settings">
              <h3 className="mb-2 text-sm font-semibold">إعدادات كل فرع (تختلف من فرع لآخر)</h3>
              <div className="divide-y divide-ink-50 text-sm">
                {perBranch.map((x) => (
                  <div key={x.id} className="flex flex-wrap items-center justify-between gap-2 py-2">
                    <span className="font-medium">{x.name}</span>
                    <span className="text-xs opacity-70">رسالة الصباح {formatClock(x.settings.checkout_message_time)} · الخروج بلا رسوم حتى {formatClock(x.settings.free_until)} · رد التأمين خلال {hoursAr(x.settings.refund_hours)}{x.settings.journey_enabled ? "" : " · الرحلة متوقفة"}</span>
                    <button type="button" className="btn-outline text-sm" onClick={() => setBranchId(x.id)} data-testid="journey-open-branch">افتح {x.name}</button>
                  </div>
                ))}
              </div>
            </Card>
          )}
          <div className="mb-4 flex gap-1 overflow-x-auto rounded-2xl bg-ink-50 p-1" role="tablist" aria-label="أقسام رحلة الضيف">
            {TABS.map(([v, label, n]) => (
              <button key={v} type="button" role="tab" aria-selected={tab === v} onClick={() => setTab(v)} data-testid={`journey-tab-${v}`}
                className={`min-h-[44px] shrink-0 rounded-xl px-3 text-sm font-semibold transition ${tab === v ? "bg-white text-brand-700 shadow-sm" : "text-ink-500 hover:text-ink-700"}`}>
                {label}{n ? <span className="ms-1.5 rounded-full bg-ink-200/70 px-1.5 text-xs tabular-nums text-ink-700">{n}</span> : null}
              </button>
            ))}
          </div>

          {tab === "departing" && (b.departing.length === 0
            ? <EmptyState icon={<LogOut className="h-10 w-10" />} title="لا مغادرين اليوم" description={`في ${formatClock(b.settings.checkout_message_time)} تصل كل نزيل يغادر اليوم خياراته على واتساب: الخروج في موعده، أو ليلة إضافية، أو ساعات بعد ${formatClock(b.settings.free_until)}.`} />
            : <div className="grid gap-3 lg:grid-cols-2" data-testid="journey-departing">{b.departing.map((d) => (
              <Card key={d.reservation_id} data-testid="journey-departing-row">
                <div className="flex flex-wrap items-start justify-between gap-2">
                  <div className="min-w-0">
                    <h3 className="font-semibold text-ink-800">غرفة {d.room_number ?? "—"}{allBranches && branchOf[d.reservation_id] ? <Badge className="ms-2" testId="journey-branch">{branchOf[d.reservation_id]}</Badge> : null}</h3>
                    <p className="text-xs text-ink-500"><Link className="font-mono hover:underline" dir="ltr" to={`/staff/reservations/${d.reservation_id}`}>{d.internal_ref}</Link></p>
                  </div>
                  {d.departed_at ? <Badge className="bg-success-50 text-success-700">أبلغ بمغادرته {clock(d.departed_at)}</Badge>
                    : d.late_checkout_until ? <Badge className="bg-brand-50 text-brand-700">خروج متأخر حتى {d.late_checkout_until}</Badge>
                    : d.choice === "on_time" ? <Badge className="bg-brand-50 text-brand-700">سيخرج في الموعد</Badge>
                    : <Badge className="bg-ink-100 text-ink-600">لم يختر بعد</Badge>}
                </div>
                <p className="mt-2 flex items-center gap-1.5 text-xs text-ink-500"><MessageCircle className="h-3.5 w-3.5" /> {d.message ? MESSAGE_AR[d.message] ?? d.message : `تُرسل الخيارات في ${formatClock(b.settings.checkout_message_time)}`}</p>
              </Card>))}</div>)}

          {tab === "requests" && (b.requests.length === 0
            ? <EmptyState icon={<Moon className="h-10 w-10" />} title="لا طلبات تمديد" description="يطلب النزيل ليلة إضافية أو ساعات بعد موعد الخروج من واتساب أو صفحة حجزه؛ يُحجز له الطلب حتى يدفع، ويُثبَّت تلقائيًا عند سداد رصيد الحجز." />
            : <div className="grid gap-3 lg:grid-cols-2" data-testid="journey-requests">{b.requests.map((x) => {
              const [label, tone] = EXT_STATUS[x.status];
              const open = x.status === "held" || x.status === "overdue";
              return (
                <Card key={x.id} className={open ? "" : "opacity-80"} data-testid="journey-request">
                  <div className="flex flex-wrap items-start justify-between gap-2">
                    <div className="min-w-0">
                      <h3 className="flex items-center gap-1.5 font-semibold text-ink-800">{x.kind === "night" ? <Moon className="h-4 w-4 text-brand-600" /> : <Clock className="h-4 w-4 text-brand-600" />} غرفة {x.room_number ?? "—"} — {x.kind === "night" ? "ليلة إضافية" : `خروج متأخر ${hoursAr(x.hours ?? 0)} حتى ${x.late_until}`}{allBranches && branchOf[x.id] ? <Badge className="ms-2" testId="journey-branch">{branchOf[x.id]}</Badge> : null}</h3>
                      <p className="text-xs text-ink-500"><Link className="font-mono hover:underline" dir="ltr" to={`/staff/reservations/${x.reservation_id}`}>{x.internal_ref}</Link> · {x.source === "whatsapp" ? "من واتساب" : "من صفحة الحجز"} · {formatDateTime(x.created_at)}</p>
                    </div>
                    <Badge className={tone}>{label}</Badge>
                  </div>
                  <p className="mt-2 text-sm text-ink-700">{x.amount_halalas != null ? <>المبلغ <span className="font-semibold tabular-nums">{sar(x.amount_halalas)}</span></> : "يُسدَّد لدى الاستقبال"}{x.status === "held" ? <> · محجوز حتى <span className="tabular-nums">{clock(x.hold_until)}</span></> : null}</p>
                  {open && can("stay.extend") && (
                    <div className="mt-3 flex flex-wrap gap-2">
                      <Link to={`/staff/reservations/${x.reservation_id}`} className="btn-primary text-sm"><Wallet className="h-4 w-4" /> تسلّم الدفع</Link>
                      <button type="button" className="btn-outline text-sm" onClick={() => setDeciding({ id: x.id, version: x.version, action: "confirm", title: "تثبيت الطلب دون دفعه الآن" })} data-testid="extension-confirm">تثبيت دون دفع</button>
                      <button type="button" className="btn-outline text-sm text-danger-600" onClick={() => setDeciding({ id: x.id, version: x.version, action: "release", title: "إلغاء الطلب وإعادة الإقامة كما كانت" })} data-testid="extension-release">إلغاء الطلب</button>
                    </div>
                  )}
                </Card>
              );
            })}</div>)}

          {tab === "awaiting" && (b.awaiting_check.length === 0
            ? <EmptyState icon={<CheckCircle2 className="h-10 w-10" />} title="لا أحد بانتظار التحقق" description="حين يضغط النزيل «غادرت وسلّمت المفتاح» يظهر هنا: افحص الوحدة من صفحة الحجز ثم أكمل المغادرة، فيصله تأكيد خروجه ويبدأ عدّاد رد التأمين." />
            : <div className="grid gap-3 lg:grid-cols-2" data-testid="journey-awaiting">{b.awaiting_check.map((a) => (
              <Card key={a.reservation_id} data-testid="journey-awaiting-row">
                <div className="flex flex-wrap items-start justify-between gap-2">
                  <div className="min-w-0">
                    <h3 className="font-semibold text-ink-800">غرفة {a.room_number ?? "—"}{allBranches && branchOf[a.reservation_id] ? <Badge className="ms-2" testId="journey-branch">{branchOf[a.reservation_id]}</Badge> : null}</h3>
                    <p className="text-xs text-ink-500"><span className="font-mono" dir="ltr">{a.internal_ref}</span> · غادر {clock(a.departed_at)} {a.via === "whatsapp" ? "(واتساب)" : a.via === "page" ? "(صفحة الحجز)" : ""}</p>
                  </div>
                  <Badge className="bg-warning-500/10 text-warning-700">افحص ثم أكمل المغادرة</Badge>
                </div>
                <p className="mt-2 text-sm text-ink-700">{a.has_deposit ? (a.deposit_halalas != null ? <>التأمين <span className="font-semibold tabular-nums">{sar(a.deposit_halalas)}</span></> : "عليه تأمين يُرد بعد الفحص") : "لا تأمين"}{a.balance_due != null && a.balance_due > 0 ? <> · <span className="text-danger-600">مستحق {sar(a.balance_due)}</span></> : null}</p>
                <Link to={`/staff/reservations/${a.reservation_id}`} className="btn-primary mt-3 text-sm"><ExternalLink className="h-4 w-4" /> فحص المغادرة وإكمالها</Link>
              </Card>))}</div>)}

          {tab === "deposits" && (b.deposits.length === 0
            ? <EmptyState icon={<Wallet className="h-10 w-10" />} title="لا تأمينات بانتظار الرد" description={`من تأكيد الخروج يُرد التأمين خلال ${hoursAr(b.settings.refund_hours)}: تحويلًا برقم العملية أو نقدًا من صندوق الفرع، ويصل النزيلَ إيصالُ الرد بعد تسجيله.`} />
            : <div className="grid gap-3 lg:grid-cols-2" data-testid="journey-deposits">{b.deposits.map((d) => { const left = remaining(d.due_at, now); return (
              <Card key={d.reservation_id} data-testid="journey-deposit">
                <div className="flex flex-wrap items-start justify-between gap-2">
                  <div className="min-w-0">
                    <h3 className="font-semibold text-ink-800">غرفة {d.room_number ?? "—"}{d.deposit_halalas != null ? <> — <span className="tabular-nums">{sar(d.deposit_halalas)}</span></> : null}{allBranches && branchOf[d.reservation_id] ? <Badge className="ms-2" testId="journey-branch">{branchOf[d.reservation_id]}</Badge> : null}</h3>
                    <p className="text-xs text-ink-500"><span className="font-mono" dir="ltr">{d.internal_ref}</span> · خرج {formatDateTime(d.checked_out_at)}</p>
                  </div>
                  <Badge className={left.late ? "bg-danger-500/10 text-danger-600" : "bg-brand-50 text-brand-700"} testId="deposit-countdown">{left.text}</Badge>
                </div>
                <Link to={`/staff/reservations/${d.reservation_id}`} className="btn-outline mt-3 text-sm"><Wallet className="h-4 w-4" /> رد التأمين</Link>
              </Card>); })}</div>)}

          {tab === "reviews" && canReviews && <ReviewsTab data={reviews} approx={approx} parts={reviewParts} onReply={setReplying} />}

          {tab === "alerts" && (b.alerts.length === 0
            ? <EmptyState icon={<BellRing className="h-10 w-10" />} title="لا تنبيهات مفتوحة" description="لكل حدث في رحلة الضيف قاعدة: من يُبلَّغ، وبأي قناة، وبعد كم دقيقة، وإلى من يُصعَّد إن لم يُعالَج. القواعد من «رحلة الضيف» في الإدارة." />
            : <div className="space-y-3" data-testid="journey-alerts">
              <div className="flex flex-wrap items-center gap-2" role="group" aria-label="عرض التنبيهات">
                <button type="button" aria-pressed={!onlyMine} onClick={() => setOnlyMine(false)} className={`min-h-[44px] rounded-xl px-3 text-sm font-semibold ${!onlyMine ? "bg-brand-50 text-brand-700" : "text-ink-500 hover:text-ink-700"}`}>كل تنبيهات الفرع ({b.alerts.length})</button>
                <button type="button" aria-pressed={onlyMine} onClick={() => setOnlyMine(true)} className={`min-h-[44px] rounded-xl px-3 text-sm font-semibold ${onlyMine ? "bg-brand-50 text-brand-700" : "text-ink-500 hover:text-ink-700"}`} data-testid="alerts-mine">لي ({mineCount})</button>
              </div>
              {shownAlerts.length === 0 && <p className="rounded-xl bg-ink-50 px-3 py-2 text-sm text-ink-600" role="status">لا تنبيهات مفتوحة تسمّيك قواعدها.</p>}
              {shownAlerts.map((a) => (
              <Card key={a.id} data-testid="journey-alert">
                <div className="flex flex-wrap items-start justify-between gap-2">
                  <div className="min-w-0">
                    <p className="flex items-center gap-1.5 text-xs font-semibold text-ink-500">{a.label}{a.mine && <span className="rounded-full bg-brand-50 px-1.5 text-[11px] text-brand-700" data-testid="alert-mine">لك</span>}</p>
                    <h3 className="font-semibold text-ink-800" dir="auto">{a.title}{allBranches && branchOf[a.id] ? <Badge className="ms-2" testId="journey-branch">{branchOf[a.id]}</Badge> : null}</h3>
                    {a.body && <p className="mt-1 text-sm text-ink-600" dir="auto">{a.body}</p>}
                  </div>
                  {a.escalated_at ? <Badge className="bg-danger-500/10 text-danger-600">صُعِّد {clock(a.escalated_at)}</Badge> : a.notified_at ? <Badge className="bg-warning-500/10 text-warning-700">أُبلغ {clock(a.notified_at)}</Badge> : <Badge className="bg-ink-100 text-ink-600">يُبلَّغ {clock(a.notify_at)}</Badge>}
                </div>
                {(a.notified_to?.length || a.escalated_to?.length) ? (
                  <p className="mt-2 text-xs text-ink-500">أُبلغ: {[...(a.notified_to ?? []), ...(a.escalated_to ?? [])].map((w) => `${w.name}${w.whatsapp === "queued" ? " (واتساب)" : w.whatsapp === "no_phone" ? " (بلا جوال)" : ""}`).join("، ")}</p>
                ) : null}
                <div className="mt-3 flex flex-wrap gap-2">
                  {a.link && <Link to={a.link} className="btn-outline text-sm"><ExternalLink className="h-4 w-4" /> فتح</Link>}
                  <button type="button" className="btn-outline text-sm" onClick={() => setResolving(a)} data-testid="alert-resolve">إغلاق التنبيه</button>
                </div>
              </Card>))}</div>)}
        </>
      )}

      <Modal open={!!deciding} title={deciding?.title ?? ""} onClose={() => setDeciding(null)}>
        {deciding && <DecideForm d={deciding} onDone={() => { setDeciding(null); reload(); }} onCancel={() => setDeciding(null)} />}
      </Modal>
      <Modal open={!!replying} title="الرد على التقييم" onClose={() => setReplying(null)}>
        {replying && <ReplyForm review={replying} onDone={() => { setReplying(null); reload(); }} onCancel={() => setReplying(null)} />}
      </Modal>
      <Modal open={!!resolving} title="إغلاق التنبيه" onClose={() => setResolving(null)}>
        {resolving && <ResolveForm alert={resolving} onDone={() => { setResolving(null); reload(); }} onCancel={() => setResolving(null)} />}
      </Modal>
    </div>
  );
}

function ReviewsTab({ data, approx, parts, onReply }: { data: StaffReviews | null; approx: boolean; parts: Array<{ name: string; count: number; overall: number | null }>; onReply: (r: StaffReview) => void }) {
  if (!data) return <div className="py-10 text-center"><Spinner /></div>;
  const s = data.summary;
  return (
    <div className="space-y-4" data-testid="journey-reviews">
      {parts.length > 1 && (
        <Card data-testid="journey-reviews-branches">
          <div className="divide-y divide-ink-50 text-sm">
            {parts.map((x) => <div key={x.name} className="flex justify-between gap-2 py-1"><span className="font-medium">{x.name}</span><span><bdi dir="ltr">{x.overall != null ? `${x.overall} / 10` : "—"}</bdi>{" "}<span>({x.count} تقييم)</span></span></div>)}
          </div>
          {approx && <p className="mt-2 text-xs opacity-70" data-testid="journey-reviews-approx">المتوسط الإجمالي تقريبي: محسوب من متوسطات الفروع المقرّبة، والأرقام الدقيقة لكل فرع أعلاه.</p>}
        </Card>
      )}
      <Card>
        <AmountGrid>
          <AmountBox label={`التقييم العام (30 يومًا)${approx ? " (تقريبي)" : ""}`} value={s.overall != null ? <bdi dir="ltr">{`${s.overall} / 10`}</bdi> : "—"} tone={s.overall != null && s.overall < data.alert_below ? "text-danger-600" : "text-ink-900"} />
          {data.aspects.map((a) => <AmountBox key={a.key} label={a.label} value={s[a.key] != null ? String(s[a.key]) : "—"} />)}
          <AmountBox label="أُرسلت / دُعي" value={`${s.count} / ${data.invited}`} />
          <AmountBox label={`أقل من ${data.alert_below}`} value={s.below} tone={s.below ? "text-danger-600" : "text-ink-900"} />
        </AmountGrid>
      </Card>
      {data.reviews.length === 0
        ? <EmptyState icon={<Star className="h-10 w-10" />} title="لا تقييمات في الفترة" description="بعد تأكيد الخروج بساعة تصل النزيلَ دعوةٌ واحدة للتقييم: درجة عامة من 10 وستة جوانب. التقييم تحت الحد يُبلَّغ به المالك فورًا." />
        : <div className="grid gap-3 lg:grid-cols-2">{data.reviews.map((r) => (
          <Card key={r.id} data-testid="journey-review">
            <div className="flex flex-wrap items-start justify-between gap-2">
              <div className="min-w-0">
                <h3 className="font-semibold text-ink-800">غرفة {r.room_number ?? "—"}</h3>
                <p className="text-xs text-ink-500"><span className="font-mono" dir="ltr">{r.internal_ref ?? ""}</span> · {formatDateTime(r.submitted_at)}</p>
              </div>
              <Badge className={(r.overall ?? 10) < data.alert_below ? "bg-danger-500/10 text-danger-600" : "bg-success-50 text-success-700"}><bdi dir="ltr">{`${r.overall} / 10`}</bdi></Badge>
            </div>
            <p className="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-xs text-ink-500">{data.aspects.map((a) => <span key={a.key}>{a.label}: <span className="font-semibold text-ink-700 tabular-nums">{r[a.key]}</span></span>)}</p>
            {r.comment && <p className="mt-2 rounded-lg bg-ink-50 p-2 text-sm text-ink-700" dir="auto">{r.comment}</p>}
            {r.reply ? <p className="mt-2 text-sm text-ink-600"><span className="font-semibold text-ink-700">الرد:</span> <span dir="auto">{r.reply}</span></p>
              : <button type="button" className="btn-outline mt-3 text-sm" onClick={() => onReply(r)} data-testid="review-reply-open">الرد على النزيل</button>}
          </Card>))}</div>}
    </div>
  );
}

function DecideForm({ d, onDone, onCancel }: { d: { id: string; version: number; action: "confirm" | "release" }; onDone: () => void; onCancel: () => void }) {
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  return (
    <ActionForm error={error} onSubmit={async () => {
      if (!reason.trim()) { setError(toArabicError(new Error("VALIDATION: reason"))); return; }
      try { await journeyApi.decide(d.id, d.action, reason.trim(), d.version); onDone(); } catch (e) { setError(toArabicError(e)); }
    }}>
      <p className="mb-3 text-sm text-ink-600">{d.action === "confirm" ? "يبقى الطلب قائمًا ويبقى مبلغه على الحجز ليُحصَّل لاحقًا." : "تُعاد الليلة إلى الوحدة أو يُعكس سطر الخروج المتأخر وضريبته، وتعود الإقامة كما كانت."}</p>
      <ReasonInput value={reason} onChange={setReason} />
      <Submit label={d.action === "confirm" ? "تثبيت" : "إلغاء الطلب"} danger={d.action === "release"} onCancel={onCancel} />
    </ActionForm>
  );
}

function ReplyForm({ review, onDone, onCancel }: { review: StaffReview; onDone: () => void; onCancel: () => void }) {
  const [reply, setReply] = useState("");
  const [error, setError] = useState<string | null>(null);
  return (
    <ActionForm error={error} onSubmit={async () => {
      if (!reply.trim()) { setError(toArabicError(new Error("VALIDATION: review_reply"))); return; }
      try { await journeyApi.reply(review.id, reply.trim(), review.version); onDone(); } catch (e) { setError(toArabicError(e)); }
    }}>
      {review.comment && <p className="mb-3 rounded-lg bg-ink-50 p-2 text-sm text-ink-700" dir="auto">{review.comment}</p>}
      <Field label="ردك (يصل النزيل على واتساب)">
        <textarea className="input min-h-[96px]" maxLength={1000} value={reply} onChange={(e) => setReply(e.target.value)} dir="auto" data-testid="review-reply-text" />
      </Field>
      <Submit label="إرسال الرد" onCancel={onCancel} />
    </ActionForm>
  );
}

function ResolveForm({ alert, onDone, onCancel }: { alert: JourneyAlert; onDone: () => void; onCancel: () => void }) {
  const [note, setNote] = useState("");
  const [error, setError] = useState<string | null>(null);
  return (
    <ActionForm error={error} onSubmit={async () => {
      try { await journeyApi.resolveAlert(alert.id, note.trim() || null); onDone(); } catch (e) { setError(toArabicError(e)); }
    }}>
      <p className="mb-3 text-sm text-ink-700" dir="auto">{alert.title}</p>
      <Field label="ملاحظة (اختياري)"><input className="input" maxLength={300} value={note} onChange={(e) => setNote(e.target.value)} /></Field>
      <Submit label="إغلاق التنبيه" onCancel={onCancel} />
    </ActionForm>
  );
}
