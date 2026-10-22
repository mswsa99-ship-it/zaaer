import { describe, it, expect } from "vitest";
import { validateOpsArgs, gateOpsOutput, buildBriefing, fallbackOpsReply, isOpsTool, OPS_ACTIONS, executeOpsTool, localDay, redactArgs } from "../../supabase/functions/_shared/ops";

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
  it("propose_action: only whitelisted actions, positive amounts, PII-redacted summary, primitives only", () => {
    expect(() => validateOpsArgs("propose_action", { action: "delete_branch", args: {}, summary: "حذف الفرع" })).toThrow(/action/);
    expect(() => validateOpsArgs("propose_action", { action: "create_receipt", args: { amount_halalas: -5 }, summary: "قبض سالب" })).toThrow(/amount/);
    const v = validateOpsArgs("propose_action", { action: "create_task", args: { room_id: "x", nested: { a: 1 }, priority: "high", n: 3.7 }, summary: "مهمة للضيف 1012345678 جوال 0501234567" });
    expect(v.action).toBe("create_task");
    expect((v.args as Record<string, unknown>).nested).toBeUndefined();
    expect((v.args as Record<string, unknown>).n).toBe(4);
    expect(String(v.summary)).not.toMatch(/1012345678|0501234567/);
    for (const a of OPS_ACTIONS) expect(() => validateOpsArgs("propose_action", { action: a, args: {}, summary: "وصف كافٍ" })).not.toThrow();
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
    expect(buildBriefing(quiet).headline).toMatch(/هادئ/);
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
    await executeOpsTool("propose_action", { action: "no_show", args: { reservation_id: "r" }, summary: "s" }, c);
    expect(calls.map((x) => x.fn)).toEqual(["fn_ai_ops_context", "fn_ai_ops_find_reservation", "fn_ops_units_board", "fn_ai_ops_propose"]);
    for (const x of calls.slice(0, 3)) expect(x.args.p_branch).toBe("branch-A");
    expect(calls[3].args.p_conversation).toBe("conv-1");
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
