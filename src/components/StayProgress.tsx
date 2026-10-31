/**
 * U3 (approved 31 Oct 2026): the top of a reservation says where the stay is and what the next step is, so the
 * supervisor does not read the whole page to find it. The stages and the next step are read from the reservation
 * itself; the step's button only moves to the section that does it — every action stays where it was, with its rules.
 */
import { Check } from "lucide-react";
import { cn, formatCurrency } from "../lib/utils";

export type StaySection = "guests" | "room" | "stay" | "ops";

export interface StayProgressInput {
  status: string; identity_status: string; has_room: boolean;
  total_halalas: number; paid_halalas: number; check_out: string; today: string;
}

const STAGES = ["الحجز", "الهوية", "الوصول", "الإقامة", "المغادرة"] as const;
const ENDED = ["cancelled", "rejected", "no_show"];

/** How many of the five stages are done (0–5). */
export function stagesDone(r: StayProgressInput): number {
  if (r.status === "closed") return 5;
  if (r.status === "checked_out") return 4;
  if (r.status === "checked_in") return 3;
  if (r.identity_status === "verified") return 2;
  if (r.status === "confirmed" || r.status === "pending_verification") return 1;
  return 0;
}

/** The next step and the section that does it; null when nothing is left (or the booking ended). */
export function nextStep(r: StayProgressInput): { title: string; why?: string; label: string; section: StaySection } | null {
  if (ENDED.includes(r.status) || r.status === "closed" || r.status === "draft") return null;
  const remaining = Math.max(0, r.total_halalas - r.paid_halalas);
  if (r.status === "checked_out") return { title: "فحص الوحدة ورد التأمين", why: "تُغلق الإقامة بعد الفحص ورد التأمين أو خصمه بسبب.", label: "فتح دورة الإقامة", section: "stay" };
  if (r.status === "checked_in") {
    if (remaining > 0) return { title: "تحصيل المتبقي", why: `على النزيل ${formatCurrency(remaining / 100)}.`, label: "فتح الملخص المالي", section: "ops" };
    if (r.check_out <= r.today) return { title: "تسجيل المغادرة", why: "موعد المغادرة اليوم أو مضى.", label: "فتح دورة الإقامة", section: "stay" };
    return null;
  }
  if (!r.has_room) return { title: "تخصيص وحدة", why: "لا وحدة لهذا الحجز بعد.", label: "اختيار وحدة", section: "room" };
  if (r.identity_status !== "verified") return { title: "مطابقة الهوية", why: "يُسلَّم الرمز بعد مطابقة الهوية مع الوثيقة الأصلية وتسجيل الوصول.", label: "مطابقة الهوية", section: "guests" };
  return { title: "تسجيل الوصول", why: "التأمين أو سببه، ثم شموس، ثم الرمز في خطوته.", label: "فتح دورة الإقامة", section: "stay" };
}

export function StayProgress({ r, canMoney, onJump }: { r: StayProgressInput; canMoney: boolean; onJump: (s: StaySection) => void }) {
  const done = stagesDone(r);
  const step = nextStep(r);
  const ended = ENDED.includes(r.status);
  const remaining = Math.max(0, r.total_halalas - r.paid_halalas);
  return (
    <div className="mb-4 space-y-3">
      {!ended && (
        <ol aria-label="مراحل الإقامة" className="flex flex-wrap gap-x-1 gap-y-2" data-testid="stay-stages">
          {STAGES.map((s, i) => {
            const state = i < done ? "done" : i === done ? "current" : "todo";
            return (
              <li key={s} className="flex items-center gap-1.5 text-xs font-medium" data-state={state} aria-current={state === "current" ? "step" : undefined}>
                <span className={cn("inline-flex h-6 w-6 flex-none items-center justify-center rounded-full text-[11px] font-bold",
                  state === "done" ? "bg-success-500/10 text-success-600" : state === "current" ? "bg-brand-600 text-white" : "bg-ink-100 text-ink-500")}>
                  {state === "done" ? <Check className="h-3.5 w-3.5" aria-hidden="true" /> : i + 1}
                </span>
                <span className={state === "todo" ? "text-ink-500" : "text-ink-800"}>{s}</span>
                {i < STAGES.length - 1 && <span aria-hidden="true" className="mx-1 h-px w-4 bg-ink-200" />}
              </li>
            );
          })}
        </ol>
      )}
      {step && (
        <section aria-label="الخطوة التالية" className="flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-brand-100 bg-brand-50/60 px-4 py-3" data-testid="next-step">
          <div className="min-w-0">
            <p className="font-semibold text-brand-700">الخطوة التالية: {step.title}</p>
            {step.why && <p className="mt-0.5 text-sm text-ink-600">{step.why}</p>}
          </div>
          <button type="button" className="btn-primary text-sm" onClick={() => onJump(step.section)} data-testid="next-step-go">{step.label}</button>
        </section>
      )}
      {canMoney && (
        <div className="grid grid-cols-[repeat(auto-fit,minmax(8.5rem,1fr))] gap-3" data-testid="stay-amounts">
          <Amount label="إجمالي الإقامة" v={r.total_halalas} />
          <Amount label="المدفوع" v={r.paid_halalas} />
          <Amount label="المتبقي على النزيل" v={remaining} warn={remaining > 0} testId="amount-remaining" />
        </div>
      )}
    </div>
  );
}

function Amount({ label, v, warn, testId }: { label: string; v: number; warn?: boolean; testId?: string }) {
  return (
    <div className="rounded-xl border border-ink-100 bg-white px-3 py-2.5" data-testid={testId}>
      <p className="text-xs font-medium text-ink-500">{label}</p>
      <p className={cn("text-lg font-bold tabular-nums", warn ? "text-warning-700" : "text-ink-800")}>{formatCurrency(v / 100)}</p>
    </div>
  );
}
