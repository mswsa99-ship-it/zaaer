/* eslint-disable @typescript-eslint/no-explicit-any */
/**
 * Demo parity for migration 0063 (the accounting stage, A2 and A3): the closing of a branch-local day. The same rules,
 * argument names, errors and return shapes as the SQL functions: the system computes the units, the table «طريقة
 * الدفع × مصدر الحجز» and a box per collection type; the supervisor enters the counts and the reasons; the review's hash
 * must travel with the send; the edit window after sending is recorded for review; after it, a request the management
 * approves or refuses.
 */
import { uid, nowISO, ORG, type Row } from "./data";

export interface AccountingCtx {
  T: (t: string) => Row[];
  byId: (t: string, id: string | null | undefined) => Row | undefined;
  can: (code: string) => boolean;
  requireCap: (code: string) => void;
  requireBranch: (b: string | null | undefined) => void;
  staffId: () => string | null;
  staffName: (id: string | null | undefined) => string | null;
  audit: (branch: string | null, action: string, entity: string, entityId: string, details: Row) => void;
  addReview: (branch: string, kind: string, entityType: string, entityId: string, resId: string | null, summary: string, reason: string | null, details: Row) => void;
  emit: (table: string) => void;
  dayOf: (iso: string) => string;
  today: (branch: string) => string;
  role: () => string | null;
}

/** fn_closing_box: the box a payment method lands in */
export const closingBox = (method: string): string | null =>
  method === "cash" ? "cash" : ["pos", "mada", "card", "payment_link"].includes(method) ? "pos" : method === "bank_transfer" ? "bank_transfer" : ["ota_deferred", "booking_platform"].includes(method) ? "platform" : null;

/** fn_day_closing_state */
export const closingState = (status: string, editUntil: string | null): "draft" | "open" | "locked" =>
  status === "draft" ? "draft" : editUntil && Date.parse(editUntil) > Date.now() ? "open" : "locked";

/** a stable text of a value (keys sorted), the demo's stand-in for jsonb::text in the review hash */
const canonical = (v: unknown): string => Array.isArray(v) ? "[" + v.map(canonical).join(",") + "]"
  : v && typeof v === "object" ? "{" + Object.keys(v as Row).sort().map((k) => JSON.stringify(k) + ":" + canonical((v as Row)[k])).join(",") + "}" : JSON.stringify(v ?? null);
/** fn_day_closing_summary_hash: the money only (each box's system amount; each line's entered amount and reason) */
const hashOf = (figures: Row, lines: Row[]) => {
  const money = [...(figures.boxes as Row[])].sort((a, b) => (a.key < b.key ? -1 : 1)).map((b) => [b.key, b.system_halalas]);
  const entered = [...lines].sort((a, b) => (a.key < b.key ? -1 : 1)).map((l) => [l.key, l.entered_halalas ?? null, l.reason ?? null]);
  let h = 5381; const s = canonical(money) + "|" + canonical(entered); for (let i = 0; i < s.length; i++) h = ((h * 33) ^ s.charCodeAt(i)) >>> 0; return h.toString(16);
};
const moneyOf = (figures: Row | null | undefined) => canonical([...((figures?.boxes ?? []) as Row[])].sort((a, b) => (a.key < b.key ? -1 : 1)).map((b) => [b.key, b.system_halalas]));

export function accountingRpcs(c: AccountingCtx): Record<string, (a: any) => any> {
  const { T, byId, can, requireCap, requireBranch, staffId, staffName, audit, addReview, emit, dayOf, today, role } = c;
  const minutesOf = (b: string) => Number(byId("branches", b)?.day_close_edit_minutes ?? 30);
  const readable = () => { if (!(can("day.close") || can("day.close.approve"))) throw new Error("FORBIDDEN: day.close"); };
  const linesOf = (closing: string) => T("day_closing_lines").filter((l) => l.closing_id === closing).sort((a, b) => (a.line_key < b.line_key ? -1 : 1))
    .map((l) => ({ key: l.line_key, box: l.box, account_id: l.account_id ?? null, source_id: l.source_id ?? null, system_halalas: l.system_halalas, entered_halalas: l.entered_halalas ?? null, difference_halalas: l.difference_halalas ?? null, reason: l.reason ?? null }));

  /** fn_day_closing_compute */
  const compute = (branch: string, date: string) => {
    const rooms = T("rooms").filter((r) => r.branch_id === branch && r.is_active !== false && !r.archived_at);
    const res = T("reservations").filter((r) => r.branch_id === branch);
    const roomsOut = {
      units: rooms.length,
      out_of_service: rooms.filter((r) => ["maintenance", "out_of_service", "blocked"].includes(r.status)).length,
      rented: res.filter((r) => r.check_in <= date && r.check_out > date && ["checked_in", "checked_out", "closed"].includes(r.status)).length,
      arrivals: res.filter((r) => r.actual_check_in && dayOf(r.actual_check_in) === date).length,
      departures: res.filter((r) => r.actual_check_out && dayOf(r.actual_check_out) === date).length,
    };
    const cells = new Map<string, Row>();
    for (const v of T("financial_vouchers").filter((x) => x.branch_id === branch && x.status === "approved" && x.kind !== "deposit_apply" && dayOf(x.occurred_at) === date)) {
      const box = closingBox(v.method); if (!box) continue; /* as the SQL: a method without a box is not counted */ const source = byId("reservations", v.reservation_id)?.source_id ?? null; const k = `${box}|${source}`;
      const cell = cells.get(k) ?? { box, source_id: source, source: source ? byId("booking_sources", source)?.name ?? "مباشر" : "مباشر", rent_in: 0, deposit_in: 0, paid_out: 0, net: 0, vouchers: 0 };
      if (v.kind === "receipt") cell.rent_in += v.amount_halalas; else if (v.kind === "deposit") cell.deposit_in += v.amount_halalas; else cell.paid_out += v.amount_halalas;
      cell.net = cell.rent_in + cell.deposit_in - cell.paid_out; cell.vouchers++; cells.set(k, cell);
    }
    const matrix = [...cells.values()].sort((a, b) => (a.box < b.box ? -1 : a.box > b.box ? 1 : String(a.source).localeCompare(String(b.source))));
    const account = (kind: string) => T("cash_accounts").filter((a) => a.branch_id === branch && a.kind === kind && !a.archived_at).sort((a, b) => Number(!!b.is_default) - Number(!!a.is_default))[0]?.id ?? null;
    const sum = (box: string) => matrix.filter((m) => m.box === box).reduce((s, m) => s + m.net, 0);
    const boxes: Row[] = [
      { key: "cash", box: "cash", sort: "1", label: "النقد", source_id: null, account_id: account("cash_box"), system_halalas: sum("cash"), required: true },
      { key: "pos", box: "pos", sort: "2", label: "الشبكة", source_id: null, account_id: account("bank_account"), system_halalas: sum("pos"), required: true },
      { key: "bank_transfer", box: "bank_transfer", sort: "3", label: "التحويل", source_id: null, account_id: account("bank_account"), system_halalas: sum("bank_transfer"), required: false },
      ...matrix.filter((m) => m.box === "platform").map((m) => ({ key: `platform:${m.source_id ?? "direct"}`, box: "platform", sort: "4", label: `آجل — ${m.source}`, source_id: m.source_id, account_id: null, system_halalas: m.net, required: false })),
    ];
    return { business_date: date, rooms: roomsOut, matrix, boxes };
  };

  /** fn_day_closing_put_lines */
  const putLines = (closing: string, figures: Row, lines: Row[] | null | undefined) => {
    for (const b of figures.boxes as Row[]) {
      const given = (lines ?? []).find((l) => l.key === b.key);
      const stored = T("day_closing_lines").find((l) => l.closing_id === closing && l.line_key === b.key);
      let entered: number | null = stored?.entered_halalas ?? null; let reason: string | null = stored?.reason ?? null;
      if (given) {
        entered = null;
        if (given.entered_halalas != null && String(given.entered_halalas) !== "") { if (!/^-?[0-9]{1,15}$/.test(String(given.entered_halalas))) throw new Error("VALIDATION: entered_amount"); entered = Number(given.entered_halalas); }
        reason = String(given.reason ?? "").trim() || null; if (reason && reason.length > 500) throw new Error("VALIDATION: reason");
      }
      const row = { closing_id: closing, line_key: b.key, box: b.box, account_id: b.account_id ?? null, source_id: b.source_id ?? null, system_halalas: b.system_halalas, entered_halalas: entered,
                    difference_halalas: entered == null ? null : entered - b.system_halalas, reason, updated_at: nowISO() };
      if (stored) Object.assign(stored, row); else T("day_closing_lines").push({ id: uid(), ...row });
    }
    const keys = new Set((figures.boxes as Row[]).map((b) => b.key));
    for (const l of T("day_closing_lines").filter((x) => x.closing_id === closing && !keys.has(x.line_key) && x.system_halalas !== 0)) Object.assign(l, { system_halalas: 0, difference_halalas: l.entered_halalas ?? null, updated_at: nowISO() });
    emit("day_closing_lines");
  };
  const closingOf = (id: string) => { const x = byId("day_closings", id); if (!x) throw new Error("NOT_FOUND"); requireBranch(x.branch_id); return x; };
  const checkVersion = (cur: number, exp: unknown) => { if (cur !== Number(exp)) throw new Error("VERSION_CONFLICT: record changed by another user"); };
  const missingOf = (figures: Row, lines: Row[]) => (figures.boxes as Row[]).filter((b) => b.required && !lines.some((l) => l.key === b.key && l.entered_halalas != null)).map((b) => b.key);
  const unexplainedOf = (lines: Row[]) => lines.filter((l) => (l.difference_halalas ?? 0) !== 0 && !l.reason).map((l) => l.key);
  const requestsOf = (closing: string) => T("day_closing_requests").filter((r) => r.closing_id === closing).sort((a, b) => (a.requested_at < b.requested_at ? 1 : -1))
    .map((r) => ({ id: r.id, status: r.status, reason: r.reason, requested_at: r.requested_at, requested_by: staffName(r.requested_by), decided_at: r.decided_at ?? null, decision_note: r.decision_note ?? null, decided_by: staffName(r.decided_by) }));
  const validDate = (branch: string, date: string) => { if (!date || date > today(branch)) throw new Error("VALIDATION: business_date"); };

  return {
    fn_admin_set_day_close_minutes: ({ p_branch, p_minutes }) => {
      requireCap("branch.settings"); requireBranch(p_branch); const m = Number(p_minutes);
      if (!Number.isInteger(m) || m < 5 || m > 240) throw new Error("VALIDATION: edit_minutes");
      const b = byId("branches", p_branch)!; const before = b.day_close_edit_minutes ?? 30;
      if (before !== m) { b.day_close_edit_minutes = m; b.updated_at = nowISO(); emit("branches"); audit(p_branch, "branch.day_close_rules_changed", "branch", p_branch, { before: { day_close_edit_minutes: before }, after: { day_close_edit_minutes: m } }); }
      return { ok: true, minutes: m };
    },
    fn_day_closing_get: ({ p_branch, p_date }) => {
      readable(); requireBranch(p_branch); validDate(p_branch, p_date);
      const live = compute(p_branch, p_date); const x = T("day_closings").find((r) => r.branch_id === p_branch && r.business_date === p_date);
      if (!x) return { closing: null, state: "none", live, lines: [], requests: [], edit_minutes: minutesOf(p_branch), changed_since_sent: false };
      return {
        closing: { id: x.id, status: x.status, version: x.version, note: x.note ?? null, submitted_at: x.submitted_at ?? null, submitted_by: staffName(x.submitted_by), edit_until: x.edit_until ?? null, figures: x.figures ?? null },
        state: closingState(x.status, x.edit_until), live, lines: linesOf(x.id), requests: requestsOf(x.id), edit_minutes: minutesOf(p_branch),
        changed_since_sent: x.status === "submitted" && moneyOf(x.figures) !== moneyOf(live),
      };
    },
    fn_day_closing_save: ({ p }) => {
      requireCap("day.close"); const q: Row = p ?? {}; requireBranch(q.branch_id); validDate(q.branch_id, q.business_date);
      const note = String(q.note ?? "").trim() || null; if (note && note.length > 1000) throw new Error("VALIDATION: note");
      for (const l of (q.lines ?? []) as Row[]) {   // checked before anything is written, as the SQL call rolls back
        if (l.entered_halalas != null && String(l.entered_halalas) !== "" && !/^-?[0-9]{1,15}$/.test(String(l.entered_halalas))) throw new Error("VALIDATION: entered_amount");
        if (String(l.reason ?? "").trim().length > 500) throw new Error("VALIDATION: reason");
      }
      let x = T("day_closings").find((r) => r.branch_id === q.branch_id && r.business_date === q.business_date);
      if (!x) {
        x = { id: uid(), organization_id: ORG, branch_id: q.branch_id, business_date: q.business_date, status: "draft", figures: null, review_hash: null, note, submitted_at: null, submitted_by: null, edit_until: null, version: 1, created_by: staffId(), created_at: nowISO(), updated_by: staffId(), updated_at: nowISO() };
        T("day_closings").push(x); audit(q.branch_id, "day_closing.created", "day_closing", x.id, { after: { business_date: q.business_date } });
      } else {
        checkVersion(x.version, q.version); if (x.status !== "draft") throw new Error("CLOSING_SENT");
        Object.assign(x, { note: "note" in q ? note : x.note, review_token: null, version: x.version + 1, updated_by: staffId(), updated_at: nowISO() });
      }
      putLines(x.id, compute(q.branch_id, q.business_date), q.lines); emit("day_closings");
      return { ok: true, id: x.id, version: x.version };
    },
    fn_day_closing_review: ({ p_id }) => {
      requireCap("day.close"); const x = closingOf(p_id); if (x.status !== "draft") throw new Error("CLOSING_SENT");
      const live = compute(x.branch_id, x.business_date); putLines(x.id, live, null); const lines = linesOf(x.id);
      x.review_hash = hashOf(live, lines); x.review_token = uid();   // the one token a send accepts
      return { id: x.id, version: x.version, figures: live, lines, missing: missingOf(live, lines), unexplained: unexplainedOf(lines), hash: x.review_token, edit_minutes: minutesOf(x.branch_id) };
    },
    fn_day_closing_submit: ({ p_id, p_version, p_hash }) => {
      requireCap("day.close"); const x = closingOf(p_id); checkVersion(x.version, p_version); if (x.status !== "draft") throw new Error("CLOSING_SENT");
      const live = compute(x.branch_id, x.business_date); putLines(x.id, live, null); const lines = linesOf(x.id);
      if (!p_hash || !x.review_token || p_hash !== x.review_token || x.review_hash !== hashOf(live, lines)) throw new Error("REVIEW_STALE");
      if (missingOf(live, lines).length) throw new Error("VALIDATION: closing_counts");
      if (unexplainedOf(lines).length) throw new Error("VALIDATION: closing_reason");
      Object.assign(x, { status: "submitted", figures: live, review_token: null, submitted_at: nowISO(), submitted_by: staffId(), edit_until: new Date(Date.now() + minutesOf(x.branch_id) * 60000).toISOString(), version: x.version + 1, updated_by: staffId(), updated_at: nowISO() });
      emit("day_closings"); audit(x.branch_id, "day_closing.submitted", "day_closing", x.id, { after: { business_date: x.business_date, lines, edit_until: x.edit_until } });
      return { ok: true, id: x.id, version: x.version, edit_until: x.edit_until };
    },
    fn_day_closing_amend: ({ p }) => {
      requireCap("day.close"); const q: Row = p ?? {}; const x = closingOf(q.id); checkVersion(x.version, q.version);
      if (x.status !== "submitted") throw new Error("CLOSING_NOT_SENT"); if (Date.parse(x.edit_until) <= Date.now()) throw new Error("CLOSING_LOCKED");
      const reason = String(q.reason ?? "").trim(); if (!reason || reason.length > 500) throw new Error("VALIDATION: reason");
      const before = linesOf(x.id); const snapshot = T("day_closing_lines").filter((l) => l.closing_id === x.id).map((l) => ({ ...l }));
      const restore = () => { for (const s of snapshot) Object.assign(T("day_closing_lines").find((l) => l.id === s.id)!, s); };
      try { putLines(x.id, x.figures, q.lines); } catch (e) { restore(); throw e; }
      const after = linesOf(x.id);
      if (missingOf(x.figures, after).length) { restore(); throw new Error("VALIDATION: closing_counts"); }
      if (unexplainedOf(after).length) { restore(); throw new Error("VALIDATION: closing_reason"); }
      if (canonical(after) === canonical(before)) return { ok: true, unchanged: true, version: x.version };
      Object.assign(x, { version: x.version + 1, updated_by: staffId(), updated_at: nowISO() }); emit("day_closings");
      audit(x.branch_id, "day_closing.amended", "day_closing", x.id, { before: { lines: before }, after: { lines: after }, reason });
      addReview(x.branch_id, "day_closing_amended", "day_closing", x.id, null, `تعديل إقفال يوم ${x.business_date} بعد إرساله`, reason, { business_date: x.business_date, before, after });
      return { ok: true, version: x.version };
    },
    fn_day_closing_request_edit: ({ p_id, p_reason }) => {
      requireCap("day.close"); const x = closingOf(p_id); if (x.status !== "submitted") throw new Error("CLOSING_NOT_SENT");
      if (Date.parse(x.edit_until) > Date.now()) throw new Error("CLOSING_OPEN");
      const reason = String(p_reason ?? "").trim(); if (!reason || reason.length > 500) throw new Error("VALIDATION: reason");
      if (T("day_closing_requests").some((r) => r.closing_id === x.id && r.status === "pending")) throw new Error("REQUEST_PENDING");
      const r = { id: uid(), closing_id: x.id, branch_id: x.branch_id, reason, status: "pending", requested_by: staffId(), requested_at: nowISO(), decided_by: null, decided_at: null, decision_note: null };
      T("day_closing_requests").push(r); emit("day_closing_requests"); audit(x.branch_id, "day_closing.edit_requested", "day_closing", x.id, { after: { request_id: r.id }, reason });
      return { ok: true, request_id: r.id };
    },
    fn_day_closing_decide: ({ p_request, p_approve, p_note }) => {
      requireCap("day.close.approve"); const r = byId("day_closing_requests", p_request); if (!r) throw new Error("NOT_FOUND"); requireBranch(r.branch_id);
      if (r.status !== "pending") throw new Error("REQUEST_DECIDED");
      if (r.requested_by === staffId() && role() !== "owner") throw new Error("SELF_DECISION");
      if (p_approve == null) throw new Error("VALIDATION: decision");
      const note = String(p_note ?? "").trim() || null; if (!p_approve && !note) throw new Error("VALIDATION: note_required"); if (note && note.length > 500) throw new Error("VALIDATION: note");
      Object.assign(r, { status: p_approve ? "approved" : "rejected", decided_by: staffId(), decided_at: nowISO(), decision_note: note });
      const x = byId("day_closings", r.closing_id)!;
      if (p_approve) Object.assign(x, { edit_until: new Date(Date.now() + minutesOf(x.branch_id) * 60000).toISOString(), version: x.version + 1, updated_at: nowISO() });
      emit("day_closing_requests"); emit("day_closings");
      audit(x.branch_id, p_approve ? "day_closing.edit_approved" : "day_closing.edit_rejected", "day_closing", x.id, { after: { request_id: r.id, edit_until: p_approve ? x.edit_until : null }, reason: note ?? r.reason });
      return { ok: true, status: r.status, edit_until: p_approve ? x.edit_until : null };
    },
    fn_day_closing_list: ({ p_branch, p_from, p_to }) => {
      readable(); requireBranch(p_branch);
      if (!p_from || !p_to || p_from > p_to || (Date.parse(p_to) - Date.parse(p_from)) / 86400000 > 366) throw new Error("VALIDATION: range");
      const mine = T("day_closings").filter((x) => x.branch_id === p_branch);
      const closings = mine.filter((x) => x.business_date >= p_from && x.business_date <= p_to).sort((a, b) => (a.business_date < b.business_date ? 1 : -1)).map((x) => {
        const ls = T("day_closing_lines").filter((l) => l.closing_id === x.id);
        return { id: x.id, business_date: x.business_date, state: closingState(x.status, x.edit_until), submitted_at: x.submitted_at ?? null, submitted_by: staffName(x.submitted_by), edit_until: x.edit_until ?? null,
                 system_halalas: ls.reduce((s, l) => s + (l.system_halalas ?? 0), 0), difference_halalas: ls.reduce((s, l) => s + (l.difference_halalas ?? 0), 0),
                 pending_request: T("day_closing_requests").some((r) => r.closing_id === x.id && r.status === "pending") };
      });
      const pending_requests = T("day_closing_requests").filter((r) => r.branch_id === p_branch && r.status === "pending").sort((a, b) => (a.requested_at < b.requested_at ? -1 : 1))
        .map((r) => ({ id: r.id, closing_id: r.closing_id, business_date: byId("day_closings", r.closing_id)?.business_date, reason: r.reason, requested_at: r.requested_at, requested_by: staffName(r.requested_by) }));
      const first = mine.map((x) => x.business_date).sort()[0] ?? today(p_branch);
      const missing_days: string[] = []; const end = [p_to, addDaysIso(today(p_branch), -1)].sort()[0];
      for (let d = end; d >= (p_from > first ? p_from : first); d = addDaysIso(d, -1)) if (!mine.some((x) => x.business_date === d && x.status === "submitted")) missing_days.push(d);
      return { closings, pending_requests, missing_days };
    },
  };
}

function addDaysIso(d: string, n: number): string { const t = new Date(d + "T00:00:00Z"); t.setUTCDate(t.getUTCDate() + n); return t.toISOString().slice(0, 10); }
