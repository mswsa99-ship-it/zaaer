import { Link } from "react-router-dom";
import { Card, Badge } from "./ui";
import {
  RESERVATION_STATUS_LABELS,
  PAYMENT_STATUS_LABELS,
  GUEST_VERIFICATION_LABELS,
  ACCESS_STATUS_LABELS,
} from "../lib/types";
import { maskName } from "../lib/utils";

export function StatusBadge({ status, map, colorMap }: { status: string; map: Record<string, string>; colorMap?: Record<string, string> }) {
  return <Badge className={colorMap?.[status] ?? "bg-ink-100 text-ink-600"}>{map[status] ?? status}</Badge>;
}

export function ReservationCardRow({ r }: { r: import("../lib/hooks").ReservationCard }) {
  return (
    <Link to={`/staff/reservations/${r.id}`} className="block">
      <Card className="transition-all hover:border-brand-300 hover:shadow-md">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="min-w-0 flex-1">
            <div className="flex items-center gap-2">
              <p className="font-mono text-sm font-semibold text-ink-800">{r.internal_ref}</p>
              <StatusBadge status={r.status} map={RESERVATION_STATUS_LABELS} />
            </div>
            <p className="mt-1 text-sm text-ink-600">{maskName(r.primary_guest?.full_name)}</p>
            <p className="mt-0.5 text-xs text-ink-400">
              {r.room?.room_number ?? "—"} · {r.room_category?.name_ar} · {r.source?.name ?? "—"}
            </p>
          </div>
          <div className="flex flex-wrap gap-1.5">
            <StatusBadge status={r.identity_status} map={GUEST_VERIFICATION_LABELS} colorMap={{ verified: "bg-success-500/10 text-success-600", rejected: "bg-danger-500/10 text-danger-600", data_submitted: "bg-warning-500/10 text-warning-600", not_started: "bg-ink-100 text-ink-400" }} />
            <StatusBadge status={r.payment_status} map={PAYMENT_STATUS_LABELS} colorMap={{ paid: "bg-success-500/10 text-success-600", pending: "bg-warning-500/10 text-warning-600", failed: "bg-danger-500/10 text-danger-600" }} />
            <StatusBadge status={r.access_status} map={ACCESS_STATUS_LABELS} colorMap={{ approved: "bg-accent-500/10 text-accent-600", delivered: "bg-success-500/10 text-success-600", acknowledged: "bg-success-500/10 text-success-600", key_handed: "bg-success-500/10 text-success-600", eligibility_review: "bg-warning-500/10 text-warning-600", locked: "bg-ink-100 text-ink-400" }} />
          </div>
        </div>
        <div className="mt-3 flex items-center justify-between border-t border-ink-50 pt-2 text-xs text-ink-400">
          <span>وصول: {r.check_in}</span>
          <span>الإجراء التالي: {nextAction(r)}</span>
        </div>
      </Card>
    </Link>
  );
}

/** The stay's next step (0033): the arrival at reception first, then the code as its own step, then the departure. */
export function nextAction(r: import("../lib/hooks").ReservationCard): string {
  if (r.status === "closed") return "مغلق";
  if (r.status === "checked_out") return "فحص المغادرة وتسوية التأمين";
  if (["cancelled", "rejected", "no_show"].includes(r.status)) return "—";
  if (r.status === "checked_in") return r.access_status === "approved" || r.access_status === "delivery_pending" ? "تسليم الرمز" : "متابعة الإقامة والمغادرة";
  if (r.identity_status !== "verified") return "مطابقة الهوية";
  if (!r.government_registration) return "التسجيل في شموس";
  if (!r.shomoos_accepted_at) return "تأكيد قبول شموس";
  return "تسجيل الوصول";
}
