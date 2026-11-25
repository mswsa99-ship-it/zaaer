/**
 * One hotel-branded document template, shared by the on-screen preview and the print window (user request 25 Nov 12:50:
 * a professional, unified look from the hotel's own identity, not plain text). Pure string builder, so it is unit-tested.
 * This template is for the STAY SUMMARY: it states the stay, the amounts and the branch policies for the guest to sign.
 * It is not a tax invoice and does not claim to be one; invoices and receipt vouchers get their own templates.
 */
import type { StaySummary } from "./api";

const esc = (x: unknown) => String(x ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c] ?? c);
const sar = (h: number, en: boolean) => `${((h ?? 0) / 100).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })} ${en ? "SAR" : "ر.س"}`;

export const DOC_ACCENT = "#0e5a63";
export const DOC_CSS = `
:root{--ink:#14232b;--muted:#5b6b73;--line:#d9e1e5;--accent:${DOC_ACCENT};--tint:#eef5f6}
*{box-sizing:border-box}
body{margin:0;background:#fff;color:var(--ink);font-family:system-ui,-apple-system,"Segoe UI",Tahoma,sans-serif;font-size:14px;line-height:1.7}
.doc{max-width:820px;margin:0 auto;padding:20px}
.hd{display:flex;align-items:center;justify-content:space-between;gap:16px;border-bottom:3px solid var(--accent);padding-bottom:14px}
.hd .brand{min-width:0}.hd .name{font-size:20px;font-weight:700;color:var(--accent);overflow-wrap:anywhere}
.hd .meta{color:var(--muted);font-size:12px;overflow-wrap:anywhere}.hd img{max-height:64px;max-width:120px;object-fit:contain}
.title{display:flex;flex-wrap:wrap;align-items:baseline;justify-content:space-between;gap:8px;margin:18px 0 12px}
.title h1{margin:0;font-size:18px}.title .ref{font-family:ui-monospace,monospace;direction:ltr;color:var(--muted);font-size:13px}
.grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px 16px;background:var(--tint);border-radius:10px;padding:12px 14px}
.grid div{min-width:0}.grid .k{font-size:11px;color:var(--muted)}.grid .v{font-weight:600;overflow-wrap:anywhere}
h2{font-size:14px;margin:20px 0 8px;color:var(--accent)}
table{width:100%;border-collapse:collapse}td{padding:7px 4px;border-bottom:1px solid var(--line);vertical-align:top}
td.n{text-align:end;white-space:nowrap;font-variant-numeric:tabular-nums;direction:ltr}tr.total td{font-weight:700;border-top:2px solid var(--ink)}
.note{font-size:12px;color:var(--muted);margin-top:6px}
.pol{border:1px solid var(--line);border-radius:10px;padding:10px 12px;margin-bottom:8px;break-inside:avoid}.pol b{display:block;margin-bottom:2px}.pol p{margin:0;white-space:pre-wrap;overflow-wrap:anywhere}
.sig{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:20px;margin-top:44px}.sig div{border-top:1px solid var(--ink);padding-top:6px;font-size:12px;color:var(--muted)}
.hash{margin-top:22px;font-family:ui-monospace,monospace;font-size:10px;color:var(--muted);direction:ltr;text-align:left;overflow-wrap:anywhere}
@media (max-width:560px){.grid{grid-template-columns:1fr}.sig{grid-template-columns:1fr;gap:28px}.hd{align-items:flex-start}}
@media print{.doc{padding:0;max-width:none}body{font-size:12.5pt}@page{size:A4;margin:16mm}}
`;

export function staySummaryHtml(s: StaySummary, logo: string | null): string {
  const en = s.language === "en";
  const b = s.branch, r = s.reservation, m = s.money;
  const L = en
    ? { title: "Stay summary", guest: "Guest", unit: "Unit", cat: "Type", src: "Source", ext: "Platform booking no.", arr: "Arrival", dep: "Departure", nights: "Nights", amounts: "Amounts", rent: "Rent", disc: "Discounts", extras: "Extras", tax: "Tax", total: "Total", paid: "Rent paid", bal: "Rent remaining", dep_req: "Deposit required", dep_held: "Deposit actually held", dep_note: "The deposit is held separately and is refunded after checkout inspection. It is not part of the rent.", pol: "Branch policies", gsig: "Guest signature", date: "Date", rec: "Reception", cr: "Commercial register", notinv: "This is a stay summary, not a tax invoice." }
    : { title: "ملخص الإقامة", guest: "النزيل", unit: "الوحدة", cat: "النوع", src: "المصدر", ext: "رقم الحجز في المنصة", arr: "الوصول", dep: "المغادرة", nights: "عدد الليالي", amounts: "المبالغ", rent: "الإيجار", disc: "الخصومات", extras: "الإضافات", tax: "الضريبة", total: "الإجمالي", paid: "المدفوع من الإيجار", bal: "المتبقي من الإيجار", dep_req: "التأمين المطلوب", dep_held: "التأمين المستلم فعلًا", dep_note: "التأمين يُحتجز منفصلًا ويُرد بعد فحص الوحدة عند المغادرة، وليس جزءًا من الإيجار.", pol: "سياسات الفرع", gsig: "توقيع النزيل", date: "التاريخ", rec: "الاستقبال", cr: "السجل التجاري", notinv: "هذا ملخص إقامة وليس فاتورة ضريبية." };
  const kv = (k: string, v: unknown, ltr = false) => (v === null || v === undefined || v === "" ? "" : `<div><div class="k">${esc(k)}</div><div class="v"${ltr ? ' dir="ltr" style="text-align:start"' : ""}>${esc(v)}</div></div>`);
  const when = (d: string, t?: string | null) => `${d}${t ? " · " + t : ""}`;
  const row = (k: string, v: number, cls = "") => `<tr class="${cls}"><td>${esc(k)}</td><td class="n">${esc(sar(v, en))}</td></tr>`;
  const meta = [b.city, b.address].filter(Boolean).join(" — ");
  return `<div class="doc" dir="${en ? "ltr" : "rtl"}" lang="${esc(s.language)}" data-testid="stay-summary-doc">
<div class="hd"><div class="brand"><div class="name">${esc(b.name)}</div>${meta ? `<div class="meta">${esc(meta)}</div>` : ""}${b.phone ? `<div class="meta" dir="ltr">${esc(b.phone)}</div>` : ""}${b.commercial_register ? `<div class="meta">${esc(L.cr)}: <span dir="ltr">${esc(b.commercial_register)}</span></div>` : ""}</div>${logo ? `<img src="${esc(logo)}" alt="">` : ""}</div>
<div class="title"><h1>${esc(L.title)}</h1><span class="ref">${esc(r.internal_ref)}</span></div>
<div class="grid">${kv(L.guest, r.guest_name)}${kv(L.unit, [r.category, r.room_number].filter(Boolean).join(" · "))}${kv(L.src, r.source)}${kv(L.ext, r.external_ref)}${kv(L.arr, when(r.check_in, r.check_in_time), true)}${kv(L.dep, when(r.check_out, r.check_out_time), true)}${kv(L.nights, r.nights)}</div>
<h2>${esc(L.amounts)}</h2>
<table>${row(L.rent, m.rent)}${m.discounts ? row(L.disc, m.discounts) : ""}${m.extras ? row(L.extras, m.extras) : ""}${m.tax ? row(L.tax, m.tax) : ""}${row(L.total, m.total, "total")}${row(L.paid, m.paid)}${row(L.bal, m.balance)}${m.deposit_required ? row(L.dep_req, m.deposit_required) + row(L.dep_held, m.deposit_held) : ""}</table>
${m.deposit_required ? `<p class="note">${esc(L.dep_note)}</p>` : ""}
${s.policies.length ? `<h2>${esc(L.pol)}</h2>${s.policies.map((p) => `<div class="pol"><b>${esc(p.title)}</b><p>${esc(p.content)}</p></div>`).join("")}` : ""}
<div class="sig"><div>${esc(L.gsig)}</div><div>${esc(L.date)}</div><div>${esc(L.rec)}</div></div>
<p class="note">${esc(L.notinv)}</p>
<p class="hash">${esc(s.hash)}</p></div>`;
}

export function printableDocument(inner: string, title: string, lang: string): string {
  return `<!doctype html><html lang="${esc(lang)}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(title)}</title><style>${DOC_CSS}</style></head><body>${inner}</body></html>`;
}
