import { useEffect, useRef, useState } from "react";
import { Printer } from "lucide-react";
import { printDocument } from "../lib/exports";
import type { PrintContext, PrintFormat } from "../lib/printDocs";
import { opsApi, guestApi, type ReservationDetail } from "../lib/api";
import { loadOrganization, organizationName } from "../lib/organization";

/** B7: «طباعة» opens its two forms — an A4 page or an 80 mm receipt; Escape or a tap outside closes it. */
type Identity = NonNullable<PrintContext["identity"]>;
const identityCache = new Map<string, Promise<Identity | undefined>>();
/** The hotel's own identity for a print (address, phone, register, logo) from the branch of the reservation; a failed read prints without it. */
function identityOf(reservationId: string): Promise<Identity | undefined> {
  let p = identityCache.get(reservationId);
  if (!p) {
    p = (async () => {
      try {
        const x = await opsApi.staySummary(reservationId);
        const logo = x.branch.logo_version ? await guestApi.branchMedia(x.branch.id, "logo").catch(() => null) : null;
        return { address: [x.branch.city, x.branch.address].filter(Boolean).join(" — ") || null, phone: x.branch.phone, commercialRegister: x.branch.commercial_register, logo };
      } catch { identityCache.delete(reservationId); return undefined; }
    })();
    identityCache.set(reservationId, p);
  }
  return p;
}
export function PrintButton({ build, testId, reservationId }: { build: (format: PrintFormat, identity?: Identity) => string; testId?: string; reservationId?: string }) {
  const [open, setOpen] = useState(false);
  const box = useRef<HTMLDivElement>(null);
  const first = useRef<HTMLButtonElement>(null);
  useEffect(() => { void loadOrganization(); }, []);
  useEffect(() => {
    if (!open) return;
    first.current?.focus();
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    const away = (e: PointerEvent) => { if (box.current && !box.current.contains(e.target as Node)) setOpen(false); };
    document.addEventListener("keydown", key); document.addEventListener("pointerdown", away);
    return () => { document.removeEventListener("keydown", key); document.removeEventListener("pointerdown", away); };
  }, [open]);
  const [err, setErr] = useState<string | null>(null);
  // an official-looking document is never printed without the hotel's identity because a read failed: say so and let the user retry
  const go = async (f: PrintFormat) => {
    setOpen(false); setErr(null);
    const identity = reservationId ? await identityOf(reservationId) : undefined;
    if (reservationId && !identity) { setErr("تعذّر تحميل بيانات المنشأة (العنوان والهاتف والسجل التجاري). لم تُطبع الوثيقة، أعد المحاولة."); return; }
    printDocument(build(f, identity));
  };
  return (
    <div className="relative inline-block" ref={box}>
      <button type="button" onClick={() => setOpen((x) => !x)} className="btn-ghost min-h-[44px] px-3 text-xs" aria-expanded={open} data-testid={testId}>
        <Printer className="h-4 w-4" /> طباعة
      </button>
      {err && <p role="alert" className="absolute left-0 z-20 mt-1 w-64 rounded-xl border border-rai-line bg-rai-surface p-2 text-xs text-rai-danger" data-testid="print-identity-error">{err}</p>}
      {open && (
        <div className="absolute left-0 z-20 mt-1 flex min-w-[10rem] flex-col rounded-xl border border-ink-100 bg-white p-1 shadow-lg">
          <button ref={first} type="button" onClick={() => void go("a4")} className="min-h-[44px] rounded-lg px-3 text-right text-sm hover:bg-ink-50" data-testid={testId ? `${testId}-a4` : undefined}>صفحة A4</button>
          <button type="button" onClick={() => void go("80mm")} className="min-h-[44px] rounded-lg px-3 text-right text-sm hover:bg-ink-50" data-testid={testId ? `${testId}-80mm` : undefined}>إيصال 80 مم</button>
        </div>
      )}
    </div>
  );
}
/** What a printed voucher or invoice says about its stay. */
export function stayPrintContext(d: ReservationDetail, branchName: string, printedBy?: string | null): PrintContext {
  const primary = (d.guests ?? []).find((g) => g.is_primary);
  // the organisation's own name (fn_organization_info), never one written in the code
  return { property: organizationName() ?? branchName, branch: branchName, reservationRef: d.reservation.internal_ref, reservationId: d.reservation.id, externalRef: d.reservation.external_ref ?? null, guest: primary?.full_name ?? null,
           room: d.room?.room_number ?? d.category ?? null, checkIn: d.reservation.check_in, checkOut: d.reservation.check_out, printedBy: printedBy ?? null };
}
