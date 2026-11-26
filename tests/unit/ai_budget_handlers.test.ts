import { describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
import ts from "typescript";
import { budgetReadAvailable, sessionCountReadable } from "../../supabase/functions/_shared/budget_reads";
import { reserveApplies, mapReserveStatus, countedRequests } from "../../supabase/functions/_shared/guest_reserve";
import { aiBudgetAvailable } from "../../supabase/functions/_shared/reception_scope";

// Execute the actual entry points with invented local database/provider responses, not a live backend.
function handler(entry: string, failed: "session" | "daily" | "page-denied" | "page-error" | null, mode = "chat") {
  let serve!: (request: Request) => Promise<Response>;
  const generate = vi.fn(async () => { throw new Error("paid provider must not be reached"); });
  const writes: string[] = [];
  const db = {
    rpc: vi.fn(async (name: string) => ({ data: name === "fn_user_page_can" ? failed !== "page-denied" && failed !== "page-error" : name === "fn_staff_id" ? "staff-a" : name === "fn_ai_ops_context" ? {} : null, error: name === "fn_user_page_can" && failed === "page-error" ? {message:"synthetic guard error"} : null })),
    from(table: string) {
      let head = false;
      let write = false;
      const result = () => {
        if (write) return { data: { id: "conversation-a" }, error: null };
        if (table === "conversation_messages" && head) return failed === "session"
          ? { count: null, data: null, error: { message: "synthetic count error" } } : { count: 0, data: null, error: null };
        if (table === "ai_usage_daily") return { data: null, error: failed === "daily" ? { message: "synthetic usage error" } : null };
        const rows: Record<string, unknown> = {
          staff_profiles: { id: "staff-a", organization_id: "hotel-a", role: "owner" },
          organizations: { id: "hotel-a", name_ar: "فندق اختباري" },
          branches: { id: "branch-a", organization_id: "hotel-a", timezone: "Asia/Riyadh" },
          conversations: { id: "conversation-a", status: "active" },
          ai_settings: { enabled: true, ops_enabled: true, briefing_with_insights: true, daily_request_limit: 2, daily_token_budget: 100, per_session_message_limit: 40 },
        };
        return { data: rows[table] ?? [], error: null };
      };
      const chain: Record<string, unknown> = {};
      for (const name of ["select", "eq", "is", "gt", "order", "limit", "maybeSingle", "single"]) chain[name] = (...args: unknown[]) => {
        if (name === "select" && (args[1] as { head?: boolean })?.head) head = true;
        return chain;
      };
      for (const name of ["insert", "update"]) chain[name] = () => { write = true; writes.push(table); return chain; };
      chain.then = (resolve: (value: unknown) => void) => Promise.resolve(result()).then(resolve);
      return chain;
    },
  };
  const dependencies: Record<string, unknown> = {
    "npm:@supabase/supabase-js@2.45.4": { createClient: () => db },
    "../_shared/guest_reserve.ts": { reserveApplies, mapReserveStatus, countedRequests },
    "../_shared/keys.ts": { projectKey: () => "synthetic-key" },
    "../_shared/budget_reads.ts": { budgetReadAvailable, sessionCountReadable },
    "../_shared/reception_scope.ts": { aiBudgetAvailable },
    "../_shared/dates.ts": { localDay: () => "2026-01-01" },
    "../_shared/llm.ts": { createProvider: () => ({ generate }), ProviderError: class extends Error {} },
    "../_shared/guardrails.ts": {
      propertyFacts: () => "", buildSystemPrompt: () => "", isEnglishMessage: () => false, gateInput: () => ({ scope: "in_scope", redacted: "سؤال تجريبي" }),
      scriptedReply: () => ({ intent: "unknown", text: "رد تجريبي", actions: [] }),
    },
    "../_shared/ops.ts": { opsModelOrder: () => ({ model: "synthetic-model", fallbacks: [] }), localDay: () => "2026-01-01", buildBriefing: () => ({}), fitOpsContext: (c: unknown) => ({ text: JSON.stringify(c), omitted: {}, droppedKeys: [], mode: "full" }), opsContextNote: () => "", buildOpsSystemPrompt: () => "", fallbackOpsReply: () => "رد تجريبي" },
    "../_shared/tools.ts": {},
  };
  const source = readFileSync(new URL(`../../supabase/functions/${entry}/index.ts`, import.meta.url), "utf8");
  const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  runInNewContext(compiled, {
    exports: {}, require: (name: string) => { if (!(name in dependencies)) throw new Error(`Unmocked import: ${name}`); return dependencies[name]; },
    Deno: { serve: (fn: typeof serve) => { serve = fn; }, env: { get: () => "https://example.test" } },
    Response, console,
  });
  const request = new Request("https://example.test", { method: "POST", headers: { authorization: "Bearer synthetic-key", "content-type": "application/json" }, body: JSON.stringify({ branch_id: "branch-a", message: "سؤال تجريبي", mode }) });
  return { run: () => serve(request), generate, writes };
}

describe("plan 5.1 actual handler budget-read failures", () => {
  it("reception rejects a failed session count before message writes or model use", async () => {
    const h = handler("ai-reception", "session");
    const response = await h.run();
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "budget_unavailable" });
    expect(h.writes).not.toContain("conversation_messages");
    expect(h.generate).not.toHaveBeenCalled();
  });
  for (const [entry, mode] of [["ai-reception", "chat"], ["ai-ops", "chat"], ["ai-ops", "briefing"]]) {
    it(`${entry} ${mode} uses no paid model when daily usage cannot be read`, async () => {
      const h = handler(entry, "daily", mode);
      const response = await h.run();
      expect(response.status).toBe(200);
      expect(h.generate).not.toHaveBeenCalled();
      expect(await response.json()).toHaveProperty("ai_status", "budget_exhausted");
    });
  }
  for (const [entry, mode] of [["ai-reception", "chat"], ["ai-ops", "chat"], ["ai-ops", "briefing"]]) {
    it(`${entry} ${mode} positive control reaches the stub provider after a successful empty-day read`, async () => {
      const h = handler(entry, null, mode);
      const response = await h.run();
      expect(h.generate).toHaveBeenCalledOnce();
      expect(await response.json()).toHaveProperty("ai_status", "provider_error:http");
    });
  }
});

describe("ops page guard",()=>{
 for(const denied of ["page-denied","page-error"] as const) it(`fails closed on ${denied} before model or writes`,async()=>{
  const h=handler("ai-ops",denied);const response=await h.run();
  expect(response.status).toBe(403);expect(h.generate).not.toHaveBeenCalled();expect(h.writes).toEqual([]);
 });
});
