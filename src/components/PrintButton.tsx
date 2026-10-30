import { useEffect, useRef, useState } from "react";
import { Printer } from "lucide-react";
import { printDocument } from "../lib/exports";
import type { PrintContext, PrintFormat } from "../lib/printDocs";
import type { ReservationDetail } from "../lib/api";

/** B7: «طباعة» opens its two forms — an A4 page or an 80 mm receipt; Escape or a tap outside closes it. */
export function PrintButton({ build, testId }: { build: (format: PrintFormat) => string; testId?: string }) {
  const [open, setOpen] = useState(false);
  const box = useRef<HTMLDivElement>(null);
  const first = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    if (!open) return;
    first.current?.focus();
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    const away = (e: PointerEvent) => { if (box.current && !box.current.contains(e.target as Node)) setOpen(false); };
    document.addEventListener("keydown", key); document.addEventListener("pointerdown", away);
    return () => { document.removeEventListener("keydown", key); document.removeEventListener("pointerdown", away); };
  }, [open]);
  const go = (f: PrintFormat) => { setOpen(false); printDocument(build(f)); };
  return (
    <div className="relative inline-block" ref={box}>
      <button type="button" onClick={() => setOpen((x) => !x)} className="btn-ghost min-h-[44px] px-3 text-xs" aria-expanded={open} data-testid={testId}>
        <Printer className="h-4 w-4" /> طباعة
      </button>
      {open && (
        <div className="absolute left-0 z-20 mt-1 flex min-w-[10rem] flex-col rounded-xl border border-ink-100 bg-white p-1 shadow-lg">
          <button ref={first} type="button" onClick={() => go("a4")} className="min-h-[44px] rounded-lg px-3 text-right text-sm hover:bg-ink-50" data-testid={testId ? `${testId}-a4` : undefined}>صفحة A4</button>
          <button type="button" onClick={() => go("80mm")} className="min-h-[44px] rounded-lg px-3 text-right text-sm hover:bg-ink-50" data-testid={testId ? `${testId}-80mm` : undefined}>إيصال 80 مم</button>
        </div>
      )}
    </div>
  );
}
/** What a printed voucher or invoice says about its stay. */
export function stayPrintContext(d: ReservationDetail, branchName: string, printedBy?: string | null): PrintContext {
  const primary = (d.guests ?? []).find((g) => g.is_primary);
  return { property: "فايف اورز", branch: branchName, reservationRef: d.reservation.internal_ref, externalRef: d.reservation.external_ref ?? null, guest: primary?.full_name ?? null,
           room: d.room?.room_number ?? d.category ?? null, checkIn: d.reservation.check_in, checkOut: d.reservation.check_out, printedBy: printedBy ?? null };
}
