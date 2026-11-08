/* eslint-disable @typescript-eslint/no-explicit-any */
/**
 * Demo parity for migration 0066 (the accounting stage, A6 and A7): the bank mailbox settings, the owner's words that
 * read a message, the messages kept raw and the movements read from them, with the same rules, errors and shapes as the
 * SQL (fn_bank_extract, fn_bank_account_fits, fn_bank_make_movement). The demo has no mailbox: «اقرأ البريد الآن»
 * answers that none is connected, and the sample messages (invented, no real account) show what the screens look like.
 */
import { uid, nowISO, ORG, type Row } from "./data";

export interface BankCtx {
  T: (t: string) => Row[];
  byId: (t: string, id: string | null | undefined) => Row | undefined;
  can: (code: string) => boolean;
  requireCap: (code: string) => void;
  requireBranch: (b: string | null | undefined) => void;
  myBranches: () => string[];
  audit: (branch: string | null, action: string, entity: string, entityId: string | null, details: Row) => void;
  emit: (table: string) => void;
  dayOf: (iso: string) => string;
  nextNumber: (prefix: string) => string;
}

const KINDS = ["deposit", "transfer_in", "pos_settlement", "other_in", "transfer_out", "withdrawal", "fee", "pos_fee", "purchase", "other_out"];
const IN = ["deposit", "transfer_in", "pos_settlement", "other_in"];
export const SEED_RULES: Array<[string, string, number]> = [
  ["استرداد", "other_in", 5], ["رسوم نقاط البيع", "pos_fee", 10], ["عمولة نقاط البيع", "pos_fee", 11], ["POS fee", "pos_fee", 12],
  ["تسوية نقاط البيع", "pos_settlement", 20], ["مبيعات نقاط البيع", "pos_settlement", 21], ["تسوية مدى", "pos_settlement", 22], ["POS settlement", "pos_settlement", 23],
  ["حوالة واردة", "transfer_in", 30], ["تحويل وارد", "transfer_in", 31], ["Incoming transfer", "transfer_in", 32], ["واردة", "transfer_in", 35],
  ["حوالة صادرة", "transfer_out", 40], ["تحويل صادر", "transfer_out", 41], ["Outgoing transfer", "transfer_out", 42], ["صادرة", "transfer_out", 45],
  ["إيداع", "deposit", 50], ["ايداع", "deposit", 51], ["Deposit", "deposit", 52],
  ["سحب", "withdrawal", 60], ["Withdrawal", "withdrawal", 61], ["رسوم", "fee", 70], ["Fees", "fee", 71], ["شراء", "purchase", 80], ["Purchase", "purchase", 81],
];

const normalize = (s: string) => s.replace(/[٠-٩]/g, (d) => String(d.charCodeAt(0) - 0x660)).replace(/[۰-۹]/g, (d) => String(d.charCodeAt(0) - 0x6f0)).replace(/٫/g, ".").replace(/٬/g, ",").replace(/[ \t ]+/g, " ");
const halalas = (s: string | undefined) => { const x = (s ?? "").replace(/,/g, ""); return /^[0-9]{1,12}(\.[0-9]{1,2})?$/.test(x) ? Math.round(Number(x) * 100) : null; };
const CUR = "(?:SAR|ر\\.?\\s?س\\.?|ريال)";
const NUM = "([0-9][0-9,]*(?:\\.[0-9]{1,2})?)";
const BAL = `(?:الرصيد|رصيد|balance|bal)\\S*(?:\\s+(?:المتاح|الحالي|available|avail))?\\s*[:：]?\\s*(?:SAR|ر\\.?\\s?س\\.?)?\\s*${NUM}`;

/** fn_bank_account_fits */
export function accountFits(tok: string, prefix: string, suffix: string): boolean {
  if (/^[0-9]+$/.test(tok)) return tok.startsWith(prefix) && tok.endsWith(suffix);
  const head = /^([0-9]*)/.exec(tok)![1]; const tail = /([0-9]+)$/.exec(tok)?.[1];
  if (!tail) return false;
  const agree = tail.length >= suffix.length ? tail.endsWith(suffix) : suffix.endsWith(tail);
  if (!agree) return false;
  if (head === "") return tail.length >= 3;
  const k = Math.min(head.length, prefix.length);
  return head.slice(0, k) === prefix.slice(0, k);
}

/** fn_bank_extract */
export function extract(T: (t: string) => Row[], text: string, fallback: string): Row {
  const t = normalize(text); const lt = t.toLowerCase();
  const rule = T("bank_parse_rules").filter((r) => r.is_active && lt.includes(String(r.keyword).toLowerCase()))
    .sort((a, b) => a.priority - b.priority || String(a.keyword).localeCompare(String(b.keyword)))[0];
  if (!rule) return { ok: false, reason: "kind" };
  let m = new RegExp(`(?:مبلغ|المبلغ|بمبلغ|قيمة|amount|amt)\\s*[:：]?\\s*${CUR}?\\s*${NUM}`, "i").exec(t);
  if (!m) {
    const noBal = t.replace(new RegExp(`${BAL}\\s*${CUR}?`, "gi"), "");
    m = new RegExp(`${NUM}\\s*${CUR}`, "i").exec(noBal) ?? new RegExp(`(?:SAR|ر\\.?\\s?س\\.?)\\s*${NUM}`, "i").exec(t.replace(new RegExp(BAL, "gi"), ""));
  }
  const amt = halalas(m?.[1]);
  if (!amt || amt <= 0) return { ok: false, reason: "amount", kind: rule.kind };
  const bal = halalas(new RegExp(BAL, "i").exec(t)?.[1]);
  const ref = /(?:رقم المرجع|المرجع|مرجع|رقم العملية|رقم الحوالة|\bref(?:erence)?\.?(?:\s*no\.?)?)\s*[:：#]?\s*([A-Za-z0-9][A-Za-z0-9-]{3,})/i.exec(t)?.[1] ?? null;
  let at: string | null = null;
  const ymd = /(?<![0-9])([0-9]{4})[/.-]([0-9]{1,2})[/.-]([0-9]{1,2})\s*[- ,T]?\s*([0-9]{1,2}):([0-9]{2})(?![0-9])/.exec(t);
  const dmy = ymd ? null : /(?<![0-9])([0-9]{1,2})[/.-]([0-9]{1,2})[/.-]([0-9]{4}|[0-9]{2})\s*[- ,]?\s*([0-9]{1,2}):([0-9]{2})(?![0-9])/.exec(t);
  const parts = ymd ? [Number(ymd[1]), Number(ymd[2]), Number(ymd[3]), Number(ymd[4]), Number(ymd[5])] : dmy ? [Number(dmy[3]) < 100 ? Number(dmy[3]) + 2000 : Number(dmy[3]), Number(dmy[2]), Number(dmy[1]), Number(dmy[4]), Number(dmy[5])] : null;
  if (parts) {
    const [y, mo, dd, hh, mi] = parts;
    const x = new Date(Date.UTC(y, mo - 1, dd, hh - 3, mi));
    // an impossible date (31/02) or one more than three days from the phone's time is not trusted, as in the SQL
    const valid = mo >= 1 && mo <= 12 && dd >= 1 && dd <= new Date(Date.UTC(y, mo, 0)).getUTCDate() && hh <= 23 && mi <= 59;
    if (valid && Math.abs(x.getTime() - new Date(fallback).getTime()) <= 3 * 86400_000) at = x.toISOString();
  }
  at ??= fallback;
  let hint: string | null = null; let acc: Row | undefined;
  for (const tok of t.match(/(?<![0-9A-Za-z])(?:[0-9]{2,}[*xX•…]+[0-9]{2,}|[*xX•…]+[0-9]{3,}|[0-9]{10,})(?![0-9A-Za-z])/g) ?? []) {
    if (/^[0-9]+$/.test(tok) && /^(05|9665|00966)/.test(tok)) continue;
    hint ??= tok;
    const fits = T("cash_accounts").filter((a) => a.organization_id === ORG && a.kind === "bank_account" && !a.archived_at && a.account_prefix && a.account_suffix && accountFits(tok, a.account_prefix, a.account_suffix));
    if (fits.length === 1) { acc = fits[0]; hint = tok; break; }
  }
  return { ok: true, kind: rule.kind, direction: rule.direction, rule: rule.keyword, amount_halalas: amt, balance_halalas: bal, reference: ref, occurred_at: at, account_hint: hint, cash_account_id: acc?.id ?? null, branch_id: acc?.branch_id ?? null };
}

/** fn_bank_make_movement */
export function makeMovement(T: (t: string) => Row[], msg: Row): Row {
  const x = extract(T, msg.sms_text ?? "", msg.sms_received_at ?? msg.mail_date ?? msg.received_at);
  if (!x.ok) { Object.assign(msg, { status: "unparsed", reject_reason: "لم تُفهم: " + (x.reason === "kind" ? "نوع الحركة" : "المبلغ"), processed_at: nowISO() }); return { status: "unparsed", reason: x.reason }; }
  // the same movement told twice: same account, direction, kind and amount, the same reference or (one without) within two
  // minutes; a movement of no known account is never merged
  const ref = x.reference ? String(x.reference).toUpperCase() : null; const t0 = new Date(x.occurred_at).getTime();
  const found = x.cash_account_id ? T("bank_movements").find((v) => v.cash_account_id === x.cash_account_id && v.direction === x.direction && v.kind === x.kind && v.amount_halalas === x.amount_halalas
    && ((v.reference && ref && String(v.reference).toUpperCase() === ref) || ((!v.reference || !ref) && Math.abs(new Date(v.occurred_at).getTime() - t0) <= 120_000))) : undefined;
  const key = x.cash_account_id && ref ? [x.cash_account_id, x.direction, x.kind, x.amount_halalas, ref].join("|") : "msg:" + msg.id;
  if (found) { Object.assign(msg, { status: "duplicate_movement", movement_id: found.id, reject_reason: null, processed_at: nowISO() }); return { status: "duplicate_movement", movement_id: found.id }; }
  const mv = { id: uid(), organization_id: ORG, branch_id: x.branch_id, cash_account_id: x.cash_account_id, message_id: msg.id, kind: x.kind, direction: x.direction, amount_halalas: x.amount_halalas,
    occurred_at: x.occurred_at, reference: x.reference, balance_halalas: x.balance_halalas, account_hint: x.account_hint, dedupe_key: key, status: "pending", created_at: nowISO() };
  T("bank_movements").push(mv);
  Object.assign(msg, { status: "parsed", movement_id: mv.id, reject_reason: null, processed_at: nowISO() });
  return { status: "parsed", movement_id: mv.id };
}

/** the demo's sample messages, as if the phone app had relayed them this morning (invented texts) */
export function seedBank(T: (t: string) => Row[]) {
  T("bank_parse_rules").push(...SEED_RULES.map(([keyword, kind, priority]) => ({ id: uid(), organization_id: ORG, keyword, kind, direction: IN.includes(kind) ? "in" : "out", priority, is_active: true, version: 1, updated_at: nowISO() })));
  T("bank_mail_settings");
  // the demo's first bank account gets a number rule (the owner sets the real ones in «الصناديق والحسابات»)
  const banks = T("cash_accounts").filter((x) => x.kind === "bank_account" && !x.archived_at && !x.account_prefix);
  const bank = banks[banks.length - 1];   // the second branch's (the first one's IBAN examples stay as they are)
  if (bank) Object.assign(bank, { account_prefix: "605", account_suffix: "4321" });
  const today = new Date(Date.now() + 3 * 3600_000).toISOString().slice(0, 10).split("-").reverse().map((x, i) => (i === 2 ? x.slice(2) : x)).join("/");
  const samples: Array<[string, string]> = [
    [`حوالة واردة\nمبلغ: 450 SAR\nإلى: 605****4321\nرقم المرجع: DEMO1001\n${today} 09:12`, "sms"],
    [`الراجحي: حوالة واردة بمبلغ 450.00 ر.س إلى حسابك 605****4321 المرجع DEMO1001`, "notification"],
    [`تسوية نقاط البيع\nمبلغ: 1,280.00 SAR\nحساب: 605****4321\nالرصيد: 15,000 SAR\n${today} 06:30`, "sms"],
    [`رسوم نقاط البيع\nمبلغ: 9.60 SAR\nحساب: **4321\n${today} 06:31`, "sms"],
    [`قيد عكسي\nمبلغ: 40 SAR\nحساب: **4321\n${today} 08:00`, "sms"],
    [`إيداع\nمبلغ: 2 SAR\nحساب: 777****555\n${today} 08:10`, "sms"],
  ];
  samples.forEach(([text, channel], i) => {
    const at = new Date(Date.now() - (60 - i) * 60_000).toISOString();
    const msg = { id: uid(), organization_id: ORG, mail_message_id: `<demo-${i}@example.com>`, mail_from: "relay@demo.sa", mail_date: at, subject: "relay", raw_body: text, content_hash: `demo-${i}`,
      sms_sender: "AlRajhiBank", sms_received_at: at, channel, sms_text: text, status: "received", reject_reason: null, movement_id: null, received_at: at, processed_at: null };
    T("bank_messages").push(msg); makeMovement(T, msg);
  });
  const at = new Date(Date.now() - 30 * 60_000).toISOString();
  T("bank_messages").push({ id: uid(), organization_id: ORG, mail_message_id: "<demo-x@example.com>", mail_from: "someone@example.org", mail_date: at, subject: "hello", raw_body: "رسالة ليست من تطبيق الجوال",
    content_hash: "demo-x", sms_sender: null, sms_received_at: null, channel: null, sms_text: null, status: "rejected", reject_reason: "ليست من بريد التطبيق", movement_id: null, received_at: at, processed_at: at });
}

export function bankRpcs(c: BankCtx): Record<string, (a: any) => any> {
  const { T, can, requireCap, requireBranch, myBranches, audit, emit, dayOf } = c;
  const settings = () => T("bank_mail_settings").find((s) => s.organization_id === ORG);
  // 0067: a cancelled record lets its movement go (the SQL does it by trigger when the record is cancelled)
  const targetState = (type: string, id: string) => {
    if (type === "voucher") return c.byId("financial_vouchers", id)?.status === "approved";
    if (type === "expense") return c.byId("expense_vouchers", id)?.status === "approved";
    if (type === "platform_payout") return c.byId("platform_payouts", id)?.status === "confirmed";
    return true;
  };
  const release = (m: Row, reason: string) => {
    Object.assign(m, { active: false, released_at: nowISO(), release_reason: reason });
    const v = T("bank_movements").find((x) => x.id === m.movement_id); if (v) v.status = "pending";
  };
  const syncReleases = () => { for (const m of T("bank_matches").filter((x) => x.active && !targetState(x.target_type, x.target_id))) release(m, "أُلغي السجل المطابق"); };
  /** fn_bank_target */
  const target = (v: Row, type: string, id: string): Row | null => {
    if (type === "voucher") { const f = c.byId("financial_vouchers", id);
      if (!f || f.account_id !== v.cash_account_id || f.status !== "approved" || !["bank_transfer", "pos"].includes(f.method) || !((v.direction === "in" && ["receipt", "deposit"].includes(f.kind)) || (v.direction === "out" && ["refund", "deposit_refund"].includes(f.kind)))) return null;
      return { type, id, number: f.number, amount_halalas: f.amount_halalas, at: f.occurred_at, label: ({ receipt: "سند قبض", deposit: "قبض تأمين", refund: "رد مبلغ", deposit_refund: "رد تأمين" } as Record<string, string>)[f.kind] + (f.method === "pos" ? " (شبكة)" : " (تحويل)") }; }
    if (type === "expense") { const x = c.byId("expense_vouchers", id); if (!x || x.account_id !== v.cash_account_id || x.status !== "approved" || v.direction !== "out") return null;
      return { type, id, number: x.number, amount_halalas: x.amount_halalas, at: x.occurred_at, label: "سند صرف: " + x.description }; }
    if (type === "pos_settlement") { const x = c.byId("pos_settlements", id); if (!x || x.account_id !== v.cash_account_id || v.direction !== "in") return null;
      return { type, id, number: "تسوية " + x.business_date, amount_halalas: x.terminal_total_halalas, at: x.business_date + "T00:00:00Z", label: "تسوية الشبكة ليوم " + x.business_date }; }
    if (type === "platform_payout") { const x = c.byId("platform_payouts", id); if (!x || x.account_id !== v.cash_account_id || x.status !== "confirmed" || v.direction !== "in") return null;
      return { type, id, number: x.reference, amount_halalas: x.received_halalas, at: x.received_on + "T00:00:00Z", label: "دفعة منصة " + (c.byId("booking_sources", x.source_id)?.name ?? "") }; }
    return null;
  };
  const targetLabel = (m: Row) => {
    if (m.target_type === "journal") return "إيراد: " + (m.reason ?? "");
    if (m.target_type === "voucher") return "سند " + (c.byId("financial_vouchers", m.target_id)?.number ?? "");
    if (m.target_type === "expense") { const x = c.byId("expense_vouchers", m.target_id); return x ? `سند صرف ${x.number}: ${x.description}` : ""; }
    if (m.target_type === "pos_settlement") return "تسوية الشبكة ليوم " + (c.byId("pos_settlements", m.target_id)?.business_date ?? "");
    return "دفعة منصة " + (c.byId("platform_payouts", m.target_id)?.reference ?? "");
  };
  const movementForOwner = (id: string) => { requireCap("bank.manage"); const v = T("bank_movements").find((x) => x.id === id); if (!v) throw new Error("NOT_FOUND"); return v; };
  const incomplete = (s: Row | undefined) => !s || !s.mailbox_address || !s.imap_user || !s.has_password || !s.has_relay_key;
  return {
    fn_admin_bank_mail_get: () => {
      requireCap("bank.manage"); const s = settings();
      return { mailbox_address: s?.mailbox_address ?? null, imap_host: s?.imap_host ?? "imap.gmail.com", imap_port: s?.imap_port ?? 993, imap_user: s?.imap_user ?? null,
        has_password: !!s?.has_password, has_relay_key: !!s?.has_relay_key, relay_key_last4: s?.relay_key_last4 ?? null, allowed_senders: s?.allowed_senders ?? ["AlRajhiBank", "Alrajhi", "الراجحي"],
        enabled: !!s?.enabled, last_polled_at: s?.last_polled_at ?? null, last_error: s?.last_error ?? null, version: s?.version ?? 1,
        state: incomplete(s) ? "not_configured" : !s!.enabled ? "off" : s!.last_error ? "error" : "on",
        accounts: T("cash_accounts").filter((a) => a.kind === "bank_account" && !a.archived_at).map((a) => ({ id: a.id, branch: c.byId("branches", a.branch_id)?.name_ar, name: a.name, prefix: a.account_prefix ?? null, suffix: a.account_suffix ?? null })) };
    },
    fn_admin_bank_mail_set: ({ p }) => {
      requireCap("bank.manage"); const q: Row = p ?? {};
      let s = settings(); if (!s) { s = { organization_id: ORG, imap_host: "imap.gmail.com", imap_port: 993, allowed_senders: ["AlRajhiBank", "Alrajhi", "الراجحي"], enabled: false, version: 1 }; T("bank_mail_settings").push(s); }
      if (q.version == null) throw new Error("VERSION_REQUIRED: expected version must be supplied"); if (q.version !== s.version) throw new Error("VERSION_CONFLICT: record changed by another user");
      const changed: string[] = []; let key: string | null = null;
      if ("mailbox_address" in q) { const v = String(q.mailbox_address ?? "").trim().toLowerCase() || null; if (v && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(v)) throw new Error("VALIDATION: mailbox_address"); if (v !== (s.mailbox_address ?? null)) { s.mailbox_address = v; changed.push("mailbox_address"); } }
      if ("imap_host" in q) { const v = String(q.imap_host ?? "").trim().toLowerCase(); if (!/^[a-z0-9.-]{3,100}$/.test(v)) throw new Error("VALIDATION: imap_host"); if (v !== s.imap_host) { s.imap_host = v; changed.push("imap_host"); } }
      if ("imap_port" in q) { const n = Number(q.imap_port); if (!/^[0-9]{1,5}$/.test(String(q.imap_port ?? "")) || n < 1 || n > 65535) throw new Error("VALIDATION: imap_port"); if (n !== s.imap_port) { s.imap_port = n; changed.push("imap_port"); } }
      if ("imap_user" in q) { const v = String(q.imap_user ?? "").trim() || null; if (v && (v.length > 200 || /\s/.test(v))) throw new Error("VALIDATION: imap_user"); if (v !== (s.imap_user ?? null)) { s.imap_user = v; changed.push("imap_user"); } }
      if (changed.some((x) => ["imap_host", "imap_port", "imap_user"].includes(x)) && !q.password && s.has_password) { s.has_password = false; changed.push("password_cleared"); }
      if (q.password) { if (String(q.password).length > 200) throw new Error("VALIDATION: password"); s.has_password = true; changed.push("password"); }
      else if (q.clear_password && s.has_password) { s.has_password = false; changed.push("password_cleared"); }
      if ("allowed_senders" in q) { const a = [...new Set(((q.allowed_senders ?? []) as string[]).map((x) => String(x).trim()).filter(Boolean))]; if (!a.length || a.length > 20 || a.some((x) => x.length > 40)) throw new Error("VALIDATION: allowed_senders"); if (JSON.stringify(a) !== JSON.stringify(s.allowed_senders)) { s.allowed_senders = a; changed.push("allowed_senders"); } }
      if (q.new_relay_key) { key = Array.from(crypto.getRandomValues(new Uint8Array(24)), (b) => b.toString(16).padStart(2, "0")).join(""); s.has_relay_key = true; s.relay_key_last4 = key.slice(-4); changed.push("relay_key"); }
      if ("enabled" in q) { if (typeof q.enabled !== "boolean") throw new Error("VALIDATION: enabled"); if (q.enabled && incomplete(s)) throw new Error("VALIDATION: bank_mail_incomplete"); if (!!q.enabled !== !!s.enabled) { s.enabled = !!q.enabled; changed.push("enabled"); } }
      if (!changed.length) return { ok: true, unchanged: true, version: s.version };
      if (s.enabled && incomplete(s)) { s.enabled = false; changed.push("disabled_incomplete"); }
      s.version += 1; emit("bank_mail_settings");
      audit(null, "bank_mail.settings_changed", "bank_mail", null, { after: { fields: changed } });
      return { ok: true, version: s.version, relay_key: key };
    },
    fn_admin_upsert_bank_rule: ({ p }) => {
      requireCap("bank.manage"); const q: Row = p ?? {}; const kw = String(q.keyword ?? "").trim();
      if (kw.length < 2 || kw.length > 60) throw new Error("VALIDATION: keyword"); if (!KINDS.includes(q.kind)) throw new Error("VALIDATION: kind"); if (!/^[0-9]{1,4}$/.test(String(q.priority ?? ""))) throw new Error("VALIDATION: priority");
      const dup = (id?: string) => T("bank_parse_rules").some((r) => r.keyword.toLowerCase() === kw.toLowerCase() && r.id !== id);
      const direction = IN.includes(q.kind) ? "in" : "out";
      if (!q.id) {
        if (dup()) throw new Error("DUPLICATE_NAME");
        const r = { id: uid(), organization_id: ORG, keyword: kw, kind: q.kind, direction, priority: Number(q.priority), is_active: true, version: 1, updated_at: nowISO() };
        T("bank_parse_rules").push(r); emit("bank_parse_rules"); audit(null, "bank_rule.created", "bank_rule", r.id, { after: r }); return { ok: true, id: r.id, version: 1 };
      }
      const r = T("bank_parse_rules").find((x) => x.id === q.id); if (!r) throw new Error("NOT_FOUND");
      if (q.version == null) throw new Error("VERSION_REQUIRED: expected version must be supplied"); if (q.version !== r.version) throw new Error("VERSION_CONFLICT: record changed by another user");
      if (dup(r.id)) throw new Error("DUPLICATE_NAME");
      const before = { ...r }; Object.assign(r, { keyword: kw, kind: q.kind, direction, priority: Number(q.priority), is_active: q.is_active ?? r.is_active, version: r.version + 1, updated_at: nowISO() });
      emit("bank_parse_rules"); audit(null, "bank_rule.updated", "bank_rule", r.id, { before, after: r }); return { ok: true, id: r.id, version: r.version };
    },
    fn_bank_messages: ({ p_status, p_limit }) => {
      requireCap("bank.manage");
      if (p_status && !["received", "rejected", "unparsed", "parsed", "duplicate_movement"].includes(p_status)) throw new Error("VALIDATION: status");
      return T("bank_messages").filter((m) => !p_status || m.status === p_status).sort((a, b) => (a.received_at < b.received_at ? 1 : -1)).slice(0, Math.min(Math.max(p_limit ?? 100, 1), 500))
        .map((m) => ({ id: m.id, received_at: m.received_at, mail_from: m.mail_from, sms_sender: m.sms_sender, channel: m.channel, sms_received_at: m.sms_received_at, text: m.sms_text ?? String(m.raw_body).slice(0, 2000), status: m.status, reason: m.reject_reason, movement_id: m.movement_id }));
    },
    fn_bank_movements: ({ p_branch, p_from, p_to }) => {
      syncReleases();
      if (!(can("bank.view") || can("bank.manage"))) throw new Error("FORBIDDEN: bank.view");
      if (p_branch) requireBranch(p_branch); else if (!can("bank.manage")) throw new Error("FORBIDDEN: bank.manage");
      if (!p_from || !p_to || p_from > p_to || (Date.parse(p_to) - Date.parse(p_from)) / 86400000 > 366) throw new Error("VALIDATION: range");
      const mine = myBranches();
      return T("bank_movements").filter((v) => (p_branch ? v.branch_id === p_branch : v.branch_id == null || mine.includes(v.branch_id)) && dayOf(v.occurred_at) >= p_from && dayOf(v.occurred_at) <= p_to)
        .sort((a, b) => (a.occurred_at < b.occurred_at ? 1 : a.occurred_at > b.occurred_at ? -1 : a.created_at < b.created_at ? 1 : -1))
        .map((v) => { const m = T("bank_messages").find((x) => x.id === v.message_id); const a = c.byId("cash_accounts", v.cash_account_id);
          const mt = T("bank_matches").find((x) => x.movement_id === v.id && x.active);
          const match = mt ? { type: mt.target_type, kind: mt.kind, difference_halalas: mt.difference_halalas, reason: mt.reason, label: targetLabel(mt) } : null;
          return { id: v.id, branch_id: v.branch_id, branch: c.byId("branches", v.branch_id)?.name_ar ?? null, account: a?.name ?? null, kind: v.kind, direction: v.direction, amount_halalas: v.amount_halalas,
            occurred_at: v.occurred_at, reference: v.reference, balance_halalas: v.balance_halalas, account_hint: v.account_hint, status: v.status, text: m?.sms_text ?? null, channel: m?.channel ?? null, match }; });
    },
    fn_bank_assign_account: ({ p_movement, p_account, p_reason }) => {
      requireCap("bank.manage"); const v = T("bank_movements").find((x) => x.id === p_movement); if (!v) throw new Error("NOT_FOUND");
      if (v.cash_account_id) throw new Error("VALIDATION: movement_assigned");
      const reason = String(p_reason ?? "").trim(); if (!reason || reason.length > 300) throw new Error("VALIDATION: reason");
      const a = c.byId("cash_accounts", p_account); if (!a || a.kind !== "bank_account" || a.archived_at) throw new Error("VALIDATION: account");
      Object.assign(v, { cash_account_id: a.id, branch_id: a.branch_id }); emit("bank_movements");
      audit(a.branch_id, "bank_movement.assigned", "bank_movement", v.id, { after: { account: a.name, amount_halalas: v.amount_halalas }, reason });
      return { ok: true, branch_id: a.branch_id };
    },
    fn_bank_candidates: ({ p_movement }) => {
      const v = movementForOwner(p_movement); syncReleases(); if (!v.cash_account_id) return [];
      const d = dayOf(v.occurred_at); const within = (iso: string) => { const x = dayOf(iso); const lo = new Date(Date.parse(d + "T00:00:00Z") - 7 * 86400_000).toISOString().slice(0, 10); const hi = new Date(Date.parse(d + "T00:00:00Z") + 86400_000).toISOString().slice(0, 10); return x >= lo && x <= hi; };
      const used = (type: string, id: string) => T("bank_matches").some((m) => m.active && m.target_type === type && m.target_id === id);
      const rows: Row[] = [
        ...T("financial_vouchers").filter((f) => within(f.occurred_at)).map((f) => ["voucher", f.id] as const),
        ...T("expense_vouchers").filter((x) => within(x.occurred_at)).map((x) => ["expense", x.id] as const),
        ...T("pos_settlements").filter((x) => within(x.business_date + "T12:00:00Z")).map((x) => ["pos_settlement", x.id] as const),
        ...T("platform_payouts").filter((x) => within(x.received_on + "T12:00:00Z")).map((x) => ["platform_payout", x.id] as const),
      ].filter(([t, id]) => !used(t, id)).map(([t, id]) => target(v, t, id)).filter((x): x is Row => !!x);
      return rows.map((r): Row => ({ ...r, exact: r.amount_halalas === v.amount_halalas }))
        .sort((a, b) => Math.abs(a.amount_halalas - v.amount_halalas) - Math.abs(b.amount_halalas - v.amount_halalas) || Math.abs(Date.parse(a.at) - Date.parse(v.occurred_at)) - Math.abs(Date.parse(b.at) - Date.parse(v.occurred_at)));
    },
    fn_bank_match: ({ p_movement, p_type, p_target, p_reason }) => {
      const v = movementForOwner(p_movement); syncReleases();
      if (v.status !== "pending") throw new Error("VALIDATION: movement_used"); if (!v.cash_account_id) throw new Error("VALIDATION: movement_unassigned");
      if (!["voucher", "expense", "pos_settlement", "platform_payout"].includes(p_type)) throw new Error("VALIDATION: target_type");
      const t = target(v, p_type, p_target); if (!t) throw new Error("VALIDATION: target");
      if (T("bank_matches").some((m) => m.active && m.target_type === p_type && m.target_id === p_target)) throw new Error("VALIDATION: target_used");
      const diff = v.amount_halalas - t.amount_halalas; const reason = String(p_reason ?? "").trim() || null;
      if (diff !== 0 && (!reason || reason.length > 300)) throw new Error("VALIDATION: difference_reason");
      if (reason && reason.length > 300) throw new Error("VALIDATION: reason");
      const m = { id: uid(), organization_id: ORG, movement_id: v.id, target_type: p_type, target_id: p_target, kind: "link", difference_halalas: diff, reason, active: true, created_at: nowISO(), released_at: null, release_reason: null };
      T("bank_matches").push(m); v.status = "matched"; emit("bank_movements");
      audit(v.branch_id, "bank_movement.matched", "bank_movement", v.id, { after: { target: t.number, type: p_type, amount_halalas: v.amount_halalas, difference_halalas: diff }, reason });
      return { ok: true, match_id: m.id, difference_halalas: diff };
    },
    fn_bank_unmatch: ({ p_movement, p_reason }) => {
      const v = movementForOwner(p_movement); syncReleases(); const reason = String(p_reason ?? "").trim();
      if (!reason || reason.length > 300) throw new Error("VALIDATION: reason");
      const m = T("bank_matches").find((x) => x.movement_id === v.id && x.active); if (!m) throw new Error("VALIDATION: movement_not_matched");
      if (m.target_type === "expense" && m.kind === "convert") throw new Error("VALIDATION: cancel_the_expense");
      release(m, reason); emit("bank_movements");
      audit(v.branch_id, "bank_movement.unmatched", "bank_movement", v.id, { before: { type: m.target_type, kind: m.kind }, reason });
      return { ok: true };
    },
    fn_bank_convert: ({ p_movement, p }) => {
      const v = movementForOwner(p_movement); syncReleases(); const q: Row = p ?? {}; const desc = String(q.description ?? "").trim();
      if (v.status !== "pending") throw new Error("VALIDATION: movement_used"); if (!v.cash_account_id) throw new Error("VALIDATION: movement_unassigned");
      if (!desc || desc.length > 300) throw new Error("VALIDATION: description");
      const mid = uid(); let expense: Row | null = null;
      if (v.direction === "out") {
        const cat = T("expense_categories").find((x) => x.id === q.category_id && x.is_active); if (!cat) throw new Error("VALIDATION: category");
        expense = { id: uid(), organization_id: ORG, branch_id: v.branch_id, number: c.nextNumber("EXP"), account_id: v.cash_account_id, category_id: cat.id, amount_halalas: v.amount_halalas, occurred_at: v.occurred_at,
          payee: null, description: desc, reference: v.reference ?? "حركة بنكية", status: "approved", cancel_reason: null, cancelled_at: null, cancelled_by: null, idempotency_key: null, created_by: null, created_at: nowISO() };
        T("expense_vouchers").push(expense); emit("expense_vouchers");
        T("bank_matches").push({ id: mid, organization_id: ORG, movement_id: v.id, target_type: "expense", target_id: expense.id, kind: "convert", difference_halalas: 0, reason: desc, active: true, created_at: nowISO() });
      } else {
        T("bank_matches").push({ id: mid, organization_id: ORG, movement_id: v.id, target_type: "journal", target_id: mid, kind: "convert", difference_halalas: 0, reason: desc, active: true, created_at: nowISO() });
      }
      v.status = "converted"; emit("bank_movements");
      audit(v.branch_id, "bank_movement.converted", "bank_movement", v.id, { after: { direction: v.direction, amount_halalas: v.amount_halalas, expense: expense?.number ?? null }, reason: desc });
      return { ok: true, match_id: mid, expense_id: expense?.id ?? null, expense_number: expense?.number ?? null };
    },
    fn_bank_reparse: ({ p_message }) => {
      requireCap("bank.manage"); const m = T("bank_messages").find((x) => x.id === p_message); if (!m) throw new Error("NOT_FOUND");
      if (!["unparsed", "rejected"].includes(m.status)) throw new Error("VALIDATION: message_status");
      // a refused message is checked again (the demo keeps no key: its refused samples are not the app's mail)
      const r = m.status === "rejected" ? (Object.assign(m, { processed_at: nowISO() }), { status: "rejected", reason: m.reject_reason }) : makeMovement(T, m); emit("bank_messages"); emit("bank_movements"); audit(null, "bank_message.reparsed", "bank_message", m.id, { after: r });
      return { ok: true, ...r };
    },
  };
}
