/**
 * B7 (the owner's note 8): every voucher kind and every invoice prints on an A4 page or an 80 mm receipt, with the
 * amount in figures and in words. Pure builders (HTML text) — printed through the hidden frame of exports.ts.
 */
import { amountInWords } from "./amountWords";
import { formatCurrency, formatDateTime } from "./utils";

export type PrintFormat = "a4" | "80mm";

const esc = (v: unknown) => String(v ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const sar = (h: number) => formatCurrency(h / 100);

export interface PrintContext { property: string; branch: string; reservationRef: string; externalRef?: string | null; guest?: string | null; room?: string | null; checkIn?: string; checkOut?: string; printedBy?: string | null }

export interface PrintVoucher { number: string; kind?: string; kindLabel: string; amount_halalas: number; methodLabel: string; reference: string | null; note: string | null; occurred_at: string; status: string; created_by_name?: string | null; original_number?: string | null; cancel_reason?: string | null }

export interface PrintInvoiceLine { description: string; quantity: number; unit_price_halalas: number; amount_halalas: number }
export interface PrintInvoice { number: string; kindLabel: string; status: string; version: number; issued_at: string; issued_by: string | null; period_from: string; period_to: string; bill_to: { name?: string; note?: string }; lines: PrintInvoiceLine[]; subtotal_halalas: number; tax_halalas: number; total_halalas: number }

function page(title: string, format: PrintFormat, body: string): string {
  const a4 = format === "a4";
  return `<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8"><title>${esc(title)}</title>
<style>
  * { box-sizing: border-box; }
  body { font-family: "IBM Plex Sans Arabic", "Noto Sans Arabic", Tahoma, Arial, sans-serif; color: #111; margin: 0; font-size: ${a4 ? "13px" : "11px"}; line-height: 1.6; }
  .doc { ${a4 ? "padding: 14mm 14mm;" : "width: 72mm; padding: 3mm 2mm;"} }
  header { text-align: center; border-bottom: ${a4 ? "2px solid" : "1px dashed"} #111; padding-bottom: ${a4 ? "8px" : "4px"}; margin-bottom: ${a4 ? "12px" : "6px"}; }
  header .p { font-size: ${a4 ? "18px" : "14px"}; font-weight: 700; margin: 0; }
  header .b { margin: 0; color: #333; }
  h1 { font-size: ${a4 ? "16px" : "13px"}; margin: 0 0 ${a4 ? "8px" : "4px"}; text-align: center; }
  .meta { display: grid; grid-template-columns: ${a4 ? "1fr 1fr" : "1fr"}; gap: ${a4 ? "4px 24px" : "1px"}; margin-bottom: ${a4 ? "12px" : "6px"}; }
  .meta div { display: flex; justify-content: space-between; gap: 8px; border-bottom: 1px dotted #bbb; }
  .meta span:first-child { color: #444; }
  .ltr { direction: ltr; unicode-bidi: embed; }
  .amount { margin: ${a4 ? "12px 0" : "6px 0"}; padding: ${a4 ? "10px 12px" : "4px"}; border: 1px solid #111; text-align: center; }
  .amount .fig { font-size: ${a4 ? "22px" : "16px"}; font-weight: 700; }
  .amount .words { margin-top: 2px; }
  table { width: 100%; border-collapse: collapse; margin: ${a4 ? "8px 0" : "4px 0"}; }
  th, td { border-bottom: 1px solid #bbb; padding: ${a4 ? "4px 6px" : "2px 0"}; text-align: right; vertical-align: top; }
  th { font-weight: 600; }
  td.n { white-space: nowrap; }
  .totals div { display: flex; justify-content: space-between; }
  .totals .t { font-weight: 700; border-top: 1px solid #111; margin-top: 2px; padding-top: 2px; }
  .void { text-align: center; font-weight: 700; color: #a00; border: 2px solid #a00; padding: 4px; margin-bottom: 8px; }
  .sig { display: ${a4 ? "flex" : "none"}; gap: 32px; margin-top: 36px; }
  .sig div { flex: 1; border-top: 1px solid #111; padding-top: 4px; font-size: 11px; text-align: center; }
  footer { margin-top: ${a4 ? "16px" : "6px"}; font-size: ${a4 ? "10px" : "9px"}; color: #555; text-align: center; }
  @page { size: ${a4 ? "A4 portrait; margin: 0" : "80mm 297mm; margin: 0"}; }
</style></head><body><div class="doc">${body}</div></body></html>`;
}

function header(ctx: PrintContext): string {
  return `<header><p class="p">${esc(ctx.property)}</p><p class="b">${esc(ctx.branch)}</p></header>`;
}

function stayMeta(ctx: PrintContext): string {
  const rows: Array<[string, string, boolean?]> = [["الحجز", ctx.reservationRef, true]];
  if (ctx.externalRef) rows.push(["رقم المنصة", ctx.externalRef, true]);
  if (ctx.guest) rows.push(["الضيف", ctx.guest]);
  if (ctx.room) rows.push(["الوحدة", ctx.room]);
  if (ctx.checkIn && ctx.checkOut) rows.push(["الإقامة", `${ctx.checkIn} → ${ctx.checkOut}`, true]);
  return rows.map(([k, v, ltr]) => `<div><span>${esc(k)}</span><span${ltr ? ' class="ltr"' : ""}>${esc(v)}</span></div>`).join("");
}

export function buildVoucherPrint(v: PrintVoucher, ctx: PrintContext, format: PrintFormat): string {
  const meta = [
    `<div><span>رقم السند</span><span class="ltr">${esc(v.number)}</span></div>`,
    `<div><span>التاريخ</span><span>${esc(formatDateTime(v.occurred_at))}</span></div>`,
    `<div><span>طريقة الدفع</span><span>${esc(v.methodLabel)}</span></div>`,
    v.reference ? `<div><span>المرجع</span><span class="ltr">${esc(v.reference)}</span></div>` : "",
    v.original_number ? `<div><span>تصحيح للسند</span><span class="ltr">${esc(v.original_number)}</span></div>` : "",
    stayMeta(ctx),
  ].join("");
  const body = `${header(ctx)}
${v.status === "cancelled" ? `<div class="void">سند ملغى${v.cancel_reason ? ` — ${esc(v.cancel_reason)}` : ""}</div>` : ""}
<h1>${esc(v.kindLabel)}</h1>
<div class="meta">${meta}</div>
<div class="amount"><div class="fig">${esc(sar(v.amount_halalas))}</div><div class="words">${esc(amountInWords(v.amount_halalas))}</div></div>
${v.note ? `<p>البيان: ${esc(v.note)}</p>` : ""}
<div class="sig">${v.kind === "refund" || v.kind === "deposit_refund"
  ? `<div>المُسلِّم${v.created_by_name ? `: ${esc(v.created_by_name)}` : ""}</div><div>توقيع الضيف المستلم</div>`
  : `<div>المستلم${v.created_by_name ? `: ${esc(v.created_by_name)}` : ""}</div><div>توقيع الضيف</div>`}</div>
<footer>طُبع ${esc(formatDateTime(new Date().toISOString()))}${ctx.printedBy ? ` · ${esc(ctx.printedBy)}` : ""}</footer>`;
  return page(`${v.kindLabel} ${v.number}`, format, body);
}

export function buildInvoicePrint(inv: PrintInvoice, ctx: PrintContext, format: PrintFormat): string {
  const a4 = format === "a4";
  const rows = inv.lines.map((l) => a4
    ? `<tr><td>${esc(l.description)}</td><td class="n ltr">${esc(l.quantity)}</td><td class="n">${esc(sar(l.unit_price_halalas))}</td><td class="n">${esc(sar(l.amount_halalas))}</td></tr>`
    : `<tr><td>${esc(l.description)}</td><td class="n">${esc(sar(l.amount_halalas))}</td></tr>`).join("");
  const head = a4 ? "<tr><th>البيان</th><th>الكمية</th><th>السعر</th><th>المبلغ</th></tr>" : "<tr><th>البيان</th><th>المبلغ</th></tr>";
  const meta = [
    `<div><span>رقم الفاتورة</span><span class="ltr">${esc(inv.number)}${inv.version > 1 ? ` (v${inv.version})` : ""}</span></div>`,
    `<div><span>التاريخ</span><span>${esc(formatDateTime(inv.issued_at))}</span></div>`,
    `<div><span>الفترة</span><span class="ltr">${esc(inv.period_from)} → ${esc(inv.period_to)}</span></div>`,
    inv.bill_to?.name ? `<div><span>تصدر باسم</span><span>${esc(inv.bill_to.name)}</span></div>` : "",
    stayMeta(ctx),
  ].join("");
  const body = `${header(ctx)}
${inv.status === "cancelled" ? `<div class="void">فاتورة ملغاة</div>` : ""}
<h1>${esc(inv.kindLabel)}</h1>
<div class="meta">${meta}</div>
<table><thead>${head}</thead><tbody>${rows}</tbody></table>
<div class="totals">
  <div><span>المجموع قبل الضريبة</span><span>${esc(sar(inv.subtotal_halalas))}</span></div>
  ${inv.tax_halalas ? `<div><span>الضريبة</span><span>${esc(sar(inv.tax_halalas))}</span></div>` : ""}
  <div class="t"><span>الإجمالي</span><span>${esc(sar(inv.total_halalas))}</span></div>
</div>
<div class="amount"><div class="words">${esc(amountInWords(inv.total_halalas))}</div></div>
${inv.bill_to?.note ? `<p>${esc(inv.bill_to.note)}</p>` : ""}
<div class="sig"><div>أصدرها${inv.issued_by ? `: ${esc(inv.issued_by)}` : ""}</div><div>توقيع الضيف</div></div>
<footer>طُبع ${esc(formatDateTime(new Date().toISOString()))}${ctx.printedBy ? ` · ${esc(ctx.printedBy)}` : ""}</footer>`;
  return page(`${inv.kindLabel} ${inv.number}`, format, body);
}
