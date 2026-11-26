import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { validateOpsArgs, gateOpsOutput, buildBriefing, diffBriefing, fallbackOpsReply, isOpsTool, OPS_ACTIONS, OPS_READ_ONLY, OPS_TOOL_DECLARATIONS, executeOpsTool, localDay, redactArgs } from "../../supabase/functions/_shared/ops";

const ctx = {
  summary: { date: "2026-10-22", units: { active: 10, occupied: 6, reserved: 1, ready: 2, dirty: 3, maintenance: 1, out_of_service: 0 }, occupancy_pct: 60,
    arrivals: { expected: 2, arrived: 1, pending_identity: 1, unpaid: 1, overdue: 0 }, departures: { expected: 1, done: 0, overstay: 1, with_balance: 1 },
    housekeeping: { open: 3, in_progress: 1, completed_today: 2, unassigned: 2 },
    finance: { received_today: 123450, refunded_today: 0, deposits_held: 40000, outstanding_in_house: 28750, deposit_to_settle_after_checkout: 20000 }, tickets_open: 0 },
  arrivals: [{ ref: "R-1", guest: "ضيف", room: "101", status: "confirmed", identity_status: "verified", balance_due: 0 }],
  departures: [{ ref: "R-2", guest: "ضيف 2", room: "102", balance_due: 28750, deposit_balance: 20000 }],
  overstays: [{ ref: "R-3", room: "103", days_over: 2 }],
  overdue_arrivals: [],
  units_needing_attention: [{ room: "104", status: "cleaning", cleanliness: "dirty", open_tasks: 1, next_arrival: "2026-10-22" }],
  open_tasks: [{ target: "104", type: "تنظيف", priority: "high", status: "pending", assignee: null }],
  in_house_with_balance: [{ ref: "R-2", room: "102", balance_due: 28750 }],
  checked_out_with_deposit: [{ ref: "R-9", deposit_balance: 20000 }],
};

describe("ops tool argument validation", () => {
  it("accepts only known tools", () => {
    expect(isOpsTool("get_operations_context")).toBe(true);
    expect(isOpsTool("drop_table")).toBe(false);
  });
  it("rejects malformed ids and dates", () => {
    expect(() => validateOpsArgs("get_reservation_finance", { reservation_id: "1 or 1=1" })).toThrow(/INVALID_ARG/);
    expect(() => validateOpsArgs("list_available_rooms", { from: "tomorrow", to: "2026-10-30" })).toThrow(/INVALID_ARG/);
    expect(validateOpsArgs("list_available_rooms", { from: "2026-10-22", to: "2026-10-24" })).toEqual({ from: "2026-10-22", to: "2026-10-24", category_id: undefined, exclude_reservation_id: undefined });
  });
  it("READ-ONLY: propose_action is not offered to the model and is refused by the validator and the executor", async () => {
    expect(OPS_READ_ONLY).toBe(true);
    expect(OPS_TOOL_DECLARATIONS.map((t) => t.name)).not.toContain("propose_action");
    expect(isOpsTool("propose_action")).toBe(false);
    for (const a of OPS_ACTIONS) expect(() => validateOpsArgs("propose_action", { action: a, args: {}, summary: "وصف كافٍ" })).toThrow(/READ_ONLY/);
    const calls: string[] = [];
    const db = { rpc: async (fn: string) => { calls.push(fn); return { data: [], error: null }; } };
    await expect(executeOpsTool("propose_action", { action: "no_show", args: { reservation_id: "r" }, summary: "s" }, { db, branchId: "b", conversationId: "c", today: "2026-10-22" })).rejects.toThrow(/READ_ONLY/);
    expect(calls).toEqual([]);   // no write RPC was even attempted
  });
  it("READ-ONLY: every tool the model can call reads only (a fixed allowlist of read RPCs), none mutates", () => {
    expect(OPS_TOOL_DECLARATIONS.map((t) => t.name).sort()).toEqual(["find_reservation", "get_day_summary", "get_finance_report", "get_operations_context", "get_reservation_finance", "get_stay_followups", "list_available_rooms", "list_units_board", "list_vouchers"]);
    const src = readFileSync("supabase/functions/_shared/ops.ts", "utf8");
    const exec = src.slice(src.indexOf("export async function executeOpsTool"), src.indexOf("Branch-local calendar day"));
    const rpcs = [...exec.matchAll(/call\("(\w+)"/g)].map((m) => m[1]).sort();
    expect(rpcs).toEqual(["fn_ai_ops_context", "fn_ai_ops_find_reservation", "fn_available_rooms", "fn_ai_ops_propose", "fn_ops_units_board", "fn_reservation_finance", "fn_reports_finance", "fn_voucher_list", "fn_stay_followups", "fn_staff_day_summary"].sort());
    const reachable = exec.replace(/case "propose_action":[^\n]*\n/, "");
    expect(reachable).not.toMatch(/fn_ai_ops_propose|fn_ai_ops_execute/);
  });
});

describe("finance read tools (read-only, under the signed-in person's own session)", () => {
  it("validate a period and nothing else", () => {
    expect(validateOpsArgs("get_finance_report", { from: "2026-11-01", to: "2026-11-25" })).toEqual({ from: "2026-11-01", to: "2026-11-25" });
    expect(() => validateOpsArgs("get_finance_report", { from: "x", to: "2026-11-25" })).toThrow("INVALID_ARG");
    expect(() => validateOpsArgs("list_vouchers", { from: "2026-11-01" })).toThrow("INVALID_ARG");
    expect(() => validateOpsArgs("list_vouchers", { from: "2026-11-01", to: "2026-11-25", kind: "a;drop" })).toThrow("INVALID_ARG");
  });
  it("call the existing role-gated read RPCs for the active branch only", async () => {
    const calls: Array<[string, Record<string, unknown>]> = [];
    const db = { rpc: async (fn: string, a: Record<string, unknown>) => { calls.push([fn, a]); return { data: {}, error: null }; } };
    const c = { db, branchId: "b1", conversationId: "c", today: "2026-11-25" };
    await executeOpsTool("get_finance_report", { from: "2026-11-01", to: "2026-11-25" }, c);
    await executeOpsTool("list_vouchers", { from: "2026-11-01", to: "2026-11-25" }, c);
    expect(calls.map((x) => x[0])).toEqual(["fn_reports_finance", "fn_voucher_list"]);
    expect(calls[0][1].p_branch).toBe("b1");
    expect((calls[1][1].p as { branch_id: string }).branch_id).toBe("b1");
  });
  it("DENIAL: when the signed-in role or branch is refused by the RPC, the tool returns no data (the refusal is thrown, nothing is substituted)", async () => {
    for (const msg of ["FORBIDDEN: money", "FORBIDDEN: reports.finance (limited)", "FORBIDDEN: branch"]) {
      const db = { rpc: async () => ({ data: { leaked: 1 }, error: { message: msg } }) };
      const c = { db, branchId: "other-branch", conversationId: "c", today: "2026-11-25" };
      await expect(executeOpsTool("get_finance_report", { from: "2026-11-01", to: "2026-11-25" }, c)).rejects.toThrow(/FORBIDDEN/);
      await expect(executeOpsTool("list_vouchers", { from: "2026-11-01", to: "2026-11-25" }, c)).rejects.toThrow(/FORBIDDEN/);
    }
  });
  it("DENIAL: a model-supplied branch is never used (the branch is the conversation's)", async () => {
    const seen: unknown[] = [];
    const db = { rpc: async (_f: string, a: Record<string, unknown>) => { seen.push(a); return { data: {}, error: null }; } };
    const c = { db, branchId: "mine", conversationId: "c", today: "2026-11-25" };
    await executeOpsTool("get_finance_report", { from: "2026-11-01", to: "2026-11-25", branch_id: "theirs", p_branch: "theirs" } as never, c);
    await executeOpsTool("list_vouchers", { from: "2026-11-01", to: "2026-11-25", branch_id: "theirs" } as never, c);
    expect(JSON.stringify(seen)).not.toContain("theirs");
  });
});

describe("ops output gate", () => {
  it("redacts document/phone numbers but keeps money amounts and refs", () => {
    const g = gateOpsOutput("المتبقي على R-AB12CD34 هو 28750 هللة = 287.50 ر.س، الضيف هويته 1012345678 وجواله 0501234567");
    expect(g.ok).toBe(true);
    expect(g.text).toContain("287.50");
    expect(g.text).toContain("28750");
    expect(g.text).not.toMatch(/1012345678|0501234567/);
    expect(g.violations).toEqual(expect.arrayContaining(["saudi_id_or_iqama", "phone"]));
  });
  it("hard-fails on secrets or prompt echo", () => {
    expect(gateOpsOutput("api_key: AIzaSy123").ok).toBe(false);
    expect(gateOpsOutput("تعليمات النظام تقول ...").ok).toBe(false);
    expect(gateOpsOutput("").ok).toBe(false);
  });
  it("hides provider names and truncates", () => {
    const g = gateOpsOutput("أنا Gemini " + "x".repeat(3000));
    expect(g.text).not.toMatch(/gemini/i);
    expect(g.violations).toContain("truncated");
  });
});

describe("deterministic briefing", () => {
  it("orders critical items first and reports money in SAR", () => {
    const b = buildBriefing(ctx);
    expect(b.items[0].level).toBe("critical");
    expect(b.headline).toMatch(/عاجل/);
    expect(b.text).toContain("R-3");
    expect(b.text).toMatch(/287[.,]50/);
    expect(b.items.some((i) => i.text.includes("104"))).toBe(true);
  });
  it("calm day headline when nothing is pending", () => {
    const quiet = { ...ctx, overstays: [], units_needing_attention: [], departures: [], arrivals: [], in_house_with_balance: [], checked_out_with_deposit: [],
      summary: { ...ctx.summary, units: { ...ctx.summary.units, dirty: 0, maintenance: 0 }, arrivals: { expected: 0 }, departures: { expected: 0 }, finance: { received_today: 0, deposits_held: 0, outstanding_in_house: 0, deposit_to_settle_after_checkout: 0 }, tickets_open: 0 } };
    expect(buildBriefing(quiet, Date.parse(ctx.summary.date + "T09:00:00Z"), "Asia/Riyadh").headline).toMatch(/هادئ/);
  });
});

describe("fallback replies (no provider)", () => {
  it("answers arrivals / departures / housekeeping / balances from context", () => {
    expect(fallbackOpsReply("مين يوصل اليوم؟", ctx)).toContain("R-1");
    expect(fallbackOpsReply("المغادرة", ctx)).toContain("R-3");
    expect(fallbackOpsReply("الغرف المتسخة", ctx)).toContain("104");
    expect(fallbackOpsReply("كم المتبقي على النزلاء", ctx)).toContain("R-2");
    expect(fallbackOpsReply("شي ثاني", ctx)).toMatch(/غير مفعّل/);
  });
});

describe("tool executor scoping", () => {
  it("every read tool is called with the conversation's branch, never a model-supplied one", async () => {
    const calls: Array<{ fn: string; args: Record<string, unknown> }> = [];
    const db = { rpc: async (fn: string, args: Record<string, unknown>) => { calls.push({ fn, args }); return { data: [], error: null }; } };
    const c = { db, branchId: "branch-A", conversationId: "conv-1", today: "2026-10-22" };
    await executeOpsTool("get_operations_context", { date: undefined }, c);
    await executeOpsTool("find_reservation", { query: "R-1" }, c);
    await executeOpsTool("list_units_board", {}, c);
    expect(calls.map((x) => x.fn)).toEqual(["fn_ai_ops_context", "fn_ai_ops_find_reservation", "fn_ops_units_board"]);
    for (const x of calls.slice(0, 3)) expect(x.args.p_branch).toBe("branch-A");
    expect(calls[0].args.p_date).toBe("2026-10-22");
  });
});

describe("audit log hygiene and timezone safety", () => {
  it("redactArgs keeps ids/dates but hides free text such as guest names and references", () => {
    const r = redactArgs({ reservation_id: "0b7c2c6a-1a2b-4c3d-8e9f-0a1b2c3d4e5f", from: "2026-10-22", query: "محمد العتيبي", args: { reference: "POS-998877", amount_halalas: 500 } });
    expect(r.reservation_id).toBe("0b7c2c6a-1a2b-4c3d-8e9f-0a1b2c3d4e5f");
    expect(r.from).toBe("2026-10-22");
    expect(String(r.query)).not.toContain("العتيبي");
    expect(String((r.args as Record<string, unknown>).reference)).not.toContain("998877");
    expect((r.args as Record<string, unknown>).amount_halalas).toBe(500);
  });
  it("localDay falls back to Asia/Riyadh for an invalid zone instead of throwing", () => {
    expect(localDay("Riyadh")).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    expect(localDay(null)).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  });
});

describe("followups and day summary read tools (read-only, signed-in person's own session)", () => {
  it("validate: the day is required, nothing else is accepted", () => {
    expect(validateOpsArgs("get_day_summary", { date: "2026-11-25" })).toEqual({ date: "2026-11-25" });
    expect(() => validateOpsArgs("get_day_summary", {})).toThrow("INVALID_ARG");
    expect(() => validateOpsArgs("get_day_summary", { date: "tomorrow" })).toThrow("INVALID_ARG");
    expect(validateOpsArgs("get_stay_followups", { branch_id: "theirs" })).toEqual({});
  });
  it("call the existing role-gated RPCs for the conversation's branch only, and a refusal returns no data", async () => {
    const calls: Array<[string, Record<string, unknown>]> = [];
    const ok = { rpc: async (fn: string, a: Record<string, unknown>) => { calls.push([fn, a]); return { data: {}, error: null }; } };
    const c = { db: ok, branchId: "mine", conversationId: "c", today: "2026-11-25" };
    await executeOpsTool("get_stay_followups", { branch_id: "theirs" } as never, c);
    await executeOpsTool("get_day_summary", { date: "2026-11-25", branch_id: "theirs" } as never, c);
    expect(calls.map((x) => x[0])).toEqual(["fn_stay_followups", "fn_staff_day_summary"]);
    expect(JSON.stringify(calls)).not.toContain("theirs");
    for (const msg of ["FORBIDDEN: role", "FORBIDDEN: branch"]) {
      const bad = { rpc: async () => ({ data: { leaked: 1 }, error: { message: msg } }) };
      const cc = { db: bad, branchId: "other", conversationId: "c", today: "2026-11-25" };
      await expect(executeOpsTool("get_stay_followups", {}, cc)).rejects.toThrow(/FORBIDDEN/);
      await expect(executeOpsTool("get_day_summary", { date: "2026-11-25" }, cc)).rejects.toThrow(/FORBIDDEN/);
    }
  });
});

describe("the fallback for a role without money", () => {
  it("OPSNOMONEY an omitted balance list is said to be unavailable, never read as «no debts»", () => {
    const c: Record<string, any> = { ...ctx }; delete c.in_house_with_balance; delete c.checked_out_with_deposit;
    const r = fallbackOpsReply("من عليه متبقي؟", c);
    expect(r).toContain("غير متاحة لصلاحيتك"); expect(r).not.toContain("لا مديونيات");
    // a role with money and a truly empty list still gets the plain answer
    expect(fallbackOpsReply("من عليه متبقي؟", { ...ctx, in_house_with_balance: [], checked_out_with_deposit: [] })).toContain("لا مديونيات");
  });
  it("OPSNOMONEY2 a context without money (as the server sends it to a role without money) says nothing about money, for the natural phrasings too", () => {
    const strip = (rows: any[]) => rows.map((e) => { const x = { ...e }; delete x.balance_due; delete x.deposit_balance; delete x.payment_status; return x; });
    const { finance: _f, ...summaryNoFinance } = ctx.summary as any;
    const c: Record<string, any> = { ...ctx, summary: summaryNoFinance, arrivals: strip(ctx.arrivals), departures: strip(ctx.departures), overstays: strip(ctx.overstays) };
    delete c.in_house_with_balance; delete c.checked_out_with_deposit;
    // «من يوصل / من يصل»: the second wording is not matched by the arrivals pattern and gets the briefing; neither may carry money
    for (const q of ["من يوصل اليوم؟", "من يصل اليوم؟", "من يغادر اليوم؟", "ما وضع اليوم؟"]) {
      const r = fallbackOpsReply(q, c);
      expect(r, q).not.toMatch(/\d+\.\d{2}\s*ر\.س/); expect(r, q).not.toContain("تحصيل اليوم"); expect(r, q).not.toContain("تأمينات محتجزة");
      expect(r, q).not.toContain("متبقٍ ") ; expect(r, q).not.toContain("تأمين ");
    }
    // a role with money still sees money on the departure list
    expect(fallbackOpsReply("من يغادر اليوم؟", ctx)).toContain("متبقٍ");
  });
});

describe("home alerts: the coordination cross-check (read only)", () => {
  it("OPSCOORD an arrival today on a unit in maintenance is one coordination alert; no arrival, no alert", () => {
    const c: Record<string, any> = { ...ctx, units_needing_attention: [{ room: "105", status: "maintenance", cleanliness: "clean", next_arrival: ctx.summary.date }] };
    const hit = buildBriefing(c).items.filter((i) => i.area === "coordination");
    expect(hit).toHaveLength(1); expect(hit[0].text).toContain("وحدة 105"); expect(hit[0].level).toBe("critical");
    expect(buildBriefing({ ...ctx, units_needing_attention: [{ room: "105", status: "maintenance", cleanliness: "clean", next_arrival: null }] }).items.some((i) => i.area === "coordination")).toBe(false);
  });
});

describe("home alerts: current risk, upcoming risk, information, unavailable (deterministic, read only)", () => {
  const D = "2026-10-22";
  const quiet = { summary: { date: D, units: { active: 10, occupied: 3, ready: 7 }, occupancy_pct: 30, arrivals: {}, departures: {}, housekeeping: {}, finance: { outstanding_in_house: 0 }, tickets_open: 0 }, overstays: [], overdue_arrivals: [], units_needing_attention: [] };
  const lvl = (c: any, now: number = Date.parse(D + "T09:00:00Z")) => buildBriefing(c, now, "Asia/Riyadh").items;
  const hot = (c: any) => lvl(c).filter((i) => i.level !== "info");
  it("POS1 maintenance + arrival today is a critical NOW alert with evidence", () => {
    const x = lvl({ ...quiet, units_needing_attention: [{ room: "5", status: "maintenance", next_arrival: D }] }).find((i) => i.area === "coordination")!;
    expect(x.level).toBe("critical"); expect(x.horizon).toBe("now"); expect(x.why).toContain("الدليل");
  });
  it("BOUNDARY1 the day before is NOT hidden: a later arrival on a maintenance unit is listed as upcoming with its date, and does not raise the headline", () => {
    const c = { ...quiet, units_needing_attention: [{ room: "5", status: "maintenance", next_arrival: "2026-10-23" }] };
    const x = lvl(c).find((i) => i.horizon === "upcoming")!; expect(x.text).toContain("2026-10-23"); expect(x.level).toBe("info"); expect(hot(c)).toHaveLength(0);
  });
  it("BOUNDARY2 an arrival dated earlier than today on a maintenance unit is a NOW alert (not future)", () => {
    expect(hot({ ...quiet, units_needing_attention: [{ room: "5", status: "maintenance", next_arrival: "2026-10-21" }] })).toHaveLength(1);
  });
  it("NEG1 routine counts (units in maintenance, in-house balance, deposits awaiting inspection) are information, not alerts", () => {
    const c = { ...quiet, summary: { ...quiet.summary, units: { ...quiet.summary.units, maintenance: 2 }, finance: { outstanding_in_house: 50000, deposit_to_settle_after_checkout: 20000 } } };
    expect(hot(c)).toHaveLength(0); expect(lvl(c).filter((i) => i.horizon === "info").length).toBeGreaterThanOrEqual(3);
  });
  it("NEG2 dirty units with unassigned tasks and NO arrival need are information; the same unit with an arrival today is the one critical 'not ready' alert", () => {
    const base = { ...quiet.summary, units: { ...quiet.summary.units, dirty: 2 }, housekeeping: { unassigned: 2 } };
    expect(hot({ ...quiet, summary: base, units_needing_attention: [{ room: "9", status: "cleaning", next_arrival: null }] })).toHaveLength(0);
    const x = hot({ ...quiet, summary: base, units_needing_attention: [{ room: "9", status: "cleaning", next_arrival: D }] }); expect(x).toHaveLength(1); expect(x[0].level).toBe("critical");
  });
  it("BOUNDARY3 zero units / empty lists / missing arrays never throw and never alert", () => {
    expect(hot({ summary: { date: D, units: {}, arrivals: {}, departures: {}, housekeeping: {}, finance: {} }, overstays: [], overdue_arrivals: [], units_needing_attention: [] })).toHaveLength(0);
  });
  it("POS3 a departure today with a balance (deadline today) stays a warning", () => {
    expect(hot({ ...quiet, summary: { ...quiet.summary, departures: { expected: 1, done: 0, with_balance: 1 } } }).length).toBe(1);
  });
  it("UNAVAIL1 no summary: data-unavailable warning, never 'calm'", () => {
    const b = buildBriefing({}); expect(b.headline).not.toContain("هادئ"); expect(b.items.some((i) => i.horizon === "unavailable" && i.level === "warning")).toBe(true);
  });
  it("UNAVAIL2 a check whose input was not delivered is reported unavailable, and the headline is not 'a calm day'", () => {
    const { units_needing_attention: _u, ...c } = quiet as any; const b = buildBriefing(c);
    expect(b.items.some((i) => i.key === "units_unavailable")).toBe(true); expect(b.headline).not.toContain("هادئ");
  });
  it("UNAVAIL3 freshness follows the BRANCH day: yesterday 23:00 read, viewed at 00:30 today, is flagged; a 05:00 read of today is not; a future stamp is flagged", () => {
    const tz = "Asia/Riyadh"; const f = (summaryDate: string, g: string, now: string) => buildBriefing({ ...quiet, summary: { ...quiet.summary, date: summaryDate }, generated_at: g }, Date.parse(now), tz).items.some((i) => i.key === "stale_reading");
    expect(f("2026-10-22", "2026-10-22T20:00:00Z", "2026-10-22T21:30:00Z")).toBe(true);   // read 23:00 Riyadh on the 22nd, now 00:30 on the 23rd, briefing still dated the 22nd
    expect(f("2026-10-23", "2026-10-22T20:00:00Z", "2026-10-22T21:30:00Z")).toBe(true);   // briefing is today but the reading was taken yesterday
    expect(f("2026-10-23", "2026-10-23T02:00:00Z", "2026-10-23T09:00:00Z")).toBe(false);  // 05:00 on the 23rd, viewed at noon: same branch day
    expect(f("2026-10-22", "2026-10-22T13:00:00Z", "2026-10-22T09:00:00Z")).toBe(true);   // stamped in the future
    expect(buildBriefing({ ...quiet, summary: { ...quiet.summary, date: "2026-10-22" } }, Date.parse("2026-10-22T09:00:00Z"), tz).items.some((i) => i.key === "stale_reading")).toBe(false); // no stamp: no claim
  });
  it("CALM1 a fully delivered, empty day says calm", () => { expect(buildBriefing(quiet, Date.parse(D + "T09:00:00Z"), "Asia/Riyadh").headline).toContain("هادئ"); });
  it("NOMONEY1 a role without money gets no money figure or false zero", () => {
    expect(lvl({ ...ctx, summary: { ...ctx.summary, finance: undefined } }).map((i) => i.text).join(" ")).not.toMatch(/ر\.س|متبقٍ/);
  });
  it("DEDUP1 one unit is one alert (maintenance+arrival is not also 'not ready')", () => {
    expect(lvl({ ...ctx, units_needing_attention: [{ room: "105", status: "maintenance", next_arrival: ctx.summary.date }] }).filter((i) => i.text.includes("105"))).toHaveLength(1);
  });
  it("EVID1 every critical and warning item has an evidence line and a stable key", () => {
    for (const i of lvl(ctx).filter((x) => x.level !== "info")) { expect(i.why, i.text).toBeTruthy(); expect(i.key, i.text).toBeTruthy(); }
  });
  it("DIFF1 cross-day: the same unresolved risk is 'persistent' and still shown; a new one is 'new'; a worse one is 'escalated'; keys are order-independent", () => {
    const k = (o: any) => ({ level: "warning" as const, text: "a", ...o });
    const prev = [k({ key: "x" }), k({ key: "y" })]; const cur = [k({ key: "x" }), k({ key: "y", level: "critical" }), k({ key: "z" })];
    expect(diffBriefing(prev, cur).map((d) => d.state)).toEqual(["persistent", "escalated", "new"]);
    const a = buildBriefing({ ...ctx, overstays: [{ ref: "A", room: "1", days_over: 1 }, { ref: "B", room: "2", days_over: 1 }] }).items[0].key;
    expect(buildBriefing({ ...ctx, overstays: [{ ref: "B", room: "2", days_over: 1 }, { ref: "A", room: "1", days_over: 1 }] }).items[0].key).toBe(a);
  });
});
