/**
 * ai-ops — staff operations assistant (copilot).
 *
 * POST { mode: "chat", message, conversation_id?, branch_id }
 *   → { conversation_id, reply, proposals: [{id, action, summary, args}], mode: "ai"|"deterministic", ai_status? }
 * POST { mode: "briefing", branch_id, date? }
 *   → { headline, items[], text, insights?: string, mode }
 *
 * Security model:
 *   - The caller's JWT is forwarded to a user-scoped Supabase client: every RPC runs with the
 *     staff member's own role/branch scope (RLS + fn_require_* in SQL). The service-role key is
 *     used ONLY to read ai_settings and to write usage counters.
 *   - The model can only read via narrow functions and can only *propose* writes.
 *   - Secrets: GEMINI_API_KEY (Edge secret). Never returned.
 */
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { createProvider, ProviderError, type ChatTurn, type ToolResult } from "../_shared/llm.ts";
import { OPS_TOOL_DECLARATIONS, executeOpsTool, isOpsTool, validateOpsArgs, gateOpsOutput, buildOpsSystemPrompt, buildBriefing, fallbackOpsReply, localDay, redactArgs } from "../_shared/ops.ts";

const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...CORS, "content-type": "application/json" } });
const MAX_TOOL_ROUNDS = 4;
const HISTORY_TURNS = 16;
const MAX_TOOL_RESULT_CHARS = 14000;

/** Keeps tool results within the model budget without corrupting JSON: long arrays are cut, with a note. */
function shrink(result: unknown): unknown {
  if (JSON.stringify(result ?? null).length <= MAX_TOOL_RESULT_CHARS) return result;
  if (Array.isArray(result)) return { truncated: true, shown: 25, total: result.length, items: result.slice(0, 25) };
  if (result && typeof result === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(result as Record<string, unknown>)) out[k] = Array.isArray(v) && v.length > 15 ? { truncated: true, shown: 15, total: v.length, items: v.slice(0, 15) } : v;
    return out;
  }
  return String(result).slice(0, MAX_TOOL_RESULT_CHARS);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  const auth = req.headers.get("authorization") ?? "";
  if (!auth.toLowerCase().startsWith("bearer ")) return json({ error: "unauthorized" }, 401);

  const url = Deno.env.get("SUPABASE_URL")!;
  const user = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "bad_json" }, 400); }
  const mode = body.mode === "briefing" ? "briefing" : "chat";
  const branchId = typeof body.branch_id === "string" ? body.branch_id : null;
  if (!branchId) return json({ error: "branch_required" }, 400);

  // ---- who is calling (must be an active staff member with access to the branch) ----
  const { data: staffId } = await user.rpc("fn_staff_id");
  if (!staffId) return json({ error: "forbidden" }, 403);
  const { data: staff } = await user.from("staff_profiles").select("id, full_name, role, organization_id").eq("id", staffId).maybeSingle();
  const { data: branch } = await user.from("branches").select("id, name_ar, timezone").eq("id", branchId).maybeSingle();
  if (!staff || !branch) return json({ error: "forbidden" }, 403);
  const { data: org } = await admin.from("organizations").select("name_ar").eq("id", staff.organization_id).maybeSingle();
  const today = localDay(branch.timezone);

  const { data: settings } = await admin.from("ai_settings").select("*").eq("organization_id", staff.organization_id).maybeSingle();
  const s = settings ?? { enabled: false, ops_enabled: true, provider: "gemini", model: "gemini-3.8-flash", temperature: 0.2, max_output_tokens: 700, timeout_ms: 15000, ops_daily_request_limit: 500, daily_token_budget: 500000, briefing_with_insights: true, extra_instructions: null };
  const dayKey = new Date().toISOString().slice(0, 10);
  // atomic server-side increment (concurrent requests must not overwrite each other's counters)
  const bump = async (patch: Record<string, number>) => {
    await admin.rpc("fn_ai_usage_bump", { p_org: staff.organization_id, p_day: dayKey, p_requests: patch.requests ?? 0, p_tokens_in: patch.tokens_in ?? 0, p_tokens_out: patch.tokens_out ?? 0, p_fallbacks: patch.fallbacks ?? 0, p_blocks: patch.guardrail_blocks ?? 0 });
  };
  const provider = s.enabled && s.ops_enabled ? createProvider(s.provider, s.model, Deno.env) : null;

  // ---- context (always deterministic, always as the user) ----
  const { data: ctxData, error: ctxErr } = await user.rpc("fn_ai_ops_context", { p_branch: branchId, p_date: typeof body.date === "string" ? body.date : today });
  if (ctxErr || !ctxData) return json({ error: "forbidden_or_unavailable", detail: ctxErr?.message }, 403);

  // =========================== BRIEFING ===========================
  if (mode === "briefing") {
    const b = buildBriefing(ctxData);
    let insights: string | null = null; let aiStatus = provider ? "ok" : (s.enabled ? "awaiting_credentials" : "disabled");
    if (provider && s.briefing_with_insights) {
      try {
        const res = await provider.generate({
          system: buildOpsSystemPrompt({ propertyName: org?.name_ar ?? "المنشأة", branchName: branch.name_ar, staffName: staff.full_name, role: staff.role, today, extra: s.extra_instructions }) + "\nالمطلوب الآن: من السياق المعطى اكتب 3 توصيات تشغيلية مرتبة بالأولوية لبداية اليوم، كل توصية سطر واحد يبدأ بفعل. لا تكرر الأرقام الموجودة في الملخص، ركز على ما يجب فعله ولماذا.",
          history: [{ role: "user", text: "السياق التشغيلي (JSON):\n" + JSON.stringify(ctxData).slice(0, 12000) }],
          tools: [], temperature: 0.3, maxOutputTokens: 350, timeoutMs: Number(s.timeout_ms ?? 15000),
        });
        const g = gateOpsOutput(res.text ?? "", 900);
        insights = g.ok ? g.text : null;
        await bump({ requests: 1, tokens_in: res.usage.input, tokens_out: res.usage.output, guardrail_blocks: g.ok ? 0 : 1 });
      } catch (e) {
        aiStatus = "provider_error:" + (e instanceof ProviderError ? e.kind : "http"); await bump({ fallbacks: 1 });
        await admin.from("ai_guardrail_events").insert({ conversation_id: null, stage: "output", rule: "ops_" + aiStatus, detail: String((e as Error).message ?? "").slice(0, 300) });
      }
    }
    return json({ ...b, insights, mode: insights ? "ai" : "deterministic", ai_status: aiStatus, generated_at: ctxData.generated_at, date: ctxData.summary?.date });
  }

  // =========================== CHAT ===============================
  const message = String(body.message ?? "").trim();
  if (!message) return json({ error: "empty_message" }, 400);
  if (message.length > 2000) return json({ error: "message_too_long" }, 413);

  let conversationId = typeof body.conversation_id === "string" ? body.conversation_id : null;
  if (conversationId) {
    const { data: c } = await user.from("ai_ops_conversations").select("id, branch_id").eq("id", conversationId).maybeSingle();
    if (!c || c.branch_id !== branchId) conversationId = null;
  }
  if (!conversationId) {
    const { data: c, error } = await user.from("ai_ops_conversations").insert({ organization_id: staff.organization_id, branch_id: branchId, staff_id: staff.id, title: message.slice(0, 60) }).select("id").single();
    if (error || !c) return json({ error: "conversation_failed", detail: error?.message }, 500);
    conversationId = c.id;
  }
  await user.from("ai_ops_messages").insert({ conversation_id: conversationId, sender: "staff", content: message });

  const proposals: Array<Record<string, unknown>> = [];
  const finish = async (reply: string, modeOut: "ai" | "deterministic", extra: Record<string, unknown> = {}) => {
    await user.from("ai_ops_messages").insert({ conversation_id: conversationId, sender: "assistant", content: reply, meta: { mode: modeOut, proposals: proposals.map((p) => p.id), ...extra } });
    await user.from("ai_ops_conversations").update({ last_message_at: new Date().toISOString() }).eq("id", conversationId);
    return json({ conversation_id: conversationId, reply, proposals, mode: modeOut, ...extra });
  };

  if (!provider) { await bump({ requests: 1, fallbacks: 1 }); return finish(fallbackOpsReply(message, ctxData), "deterministic", { ai_status: s.enabled ? (s.ops_enabled ? "awaiting_credentials" : "ops_disabled") : "disabled" }); }

  const { data: usage } = await admin.from("ai_usage_daily").select("*").eq("organization_id", staff.organization_id).eq("day", dayKey).maybeSingle();
  if ((usage?.requests ?? 0) >= Number(s.ops_daily_request_limit ?? 500) + Number(s.daily_request_limit ?? 0) || ((usage?.tokens_in ?? 0) + (usage?.tokens_out ?? 0)) >= Number(s.daily_token_budget ?? 500000)) {
    await bump({ fallbacks: 1 }); return finish(fallbackOpsReply(message, ctxData), "deterministic", { ai_status: "budget_exhausted" });
  }

  const { data: hist } = await user.from("ai_ops_messages").select("sender, content").eq("conversation_id", conversationId).order("created_at", { ascending: false }).limit(HISTORY_TURNS);
  const history: ChatTurn[] = (hist ?? []).reverse().filter((m) => m.sender !== "system").map((m) => ({ role: m.sender === "staff" ? "user" : "model", text: m.content }));
  const system = buildOpsSystemPrompt({ propertyName: org?.name_ar ?? "المنشأة", branchName: branch.name_ar, staffName: staff.full_name, role: staff.role, today, extra: s.extra_instructions });
  const toolCtx = { db: user, branchId, conversationId: conversationId!, today };

  let tokensIn = 0, tokensOut = 0, finalText: string | null = null;
  try {
    for (let round = 0; round <= MAX_TOOL_ROUNDS; round++) {
      const res = await provider.generate({ system, history, tools: OPS_TOOL_DECLARATIONS, temperature: Number(s.temperature ?? 0.2), maxOutputTokens: Math.max(Number(s.max_output_tokens ?? 400), 600), timeoutMs: Number(s.timeout_ms ?? 15000) });
      tokensIn += res.usage.input; tokensOut += res.usage.output;
      if (res.blockedBySafety) break;
      if (res.toolCalls.length === 0) { finalText = res.text; break; }
      if (round === MAX_TOOL_ROUNDS) break;
      const results: ToolResult[] = [];
      for (const call of res.toolCalls) {
        const started = Date.now(); let result: unknown; let status = "ok";
        if (!isOpsTool(call.name)) { status = "denied"; result = { denied: true }; }
        else {
          try {
            const args = validateOpsArgs(call.name, call.args);
            result = await executeOpsTool(call.name, args, toolCtx);
            if (call.name === "propose_action" && (result as { proposal_id?: string })?.proposal_id) {
              proposals.push({ id: (result as { proposal_id: string }).proposal_id, action: args.action, summary: args.summary, args: args.args });
            }
          } catch (e) { status = "error"; result = { error: String((e as Error).message).slice(0, 160) }; }
        }
        await admin.from("ai_tool_executions").insert({ conversation_id: null, tool_name: "ops:" + call.name, args_redacted: redactArgs(call.args), result_status: status, latency_ms: Date.now() - started });
        results.push({ name: call.name, id: call.id, result: shrink(result) });
      }
      // the model's step goes back exactly as it came (thought signatures), then all its results in one turn
      history.push({ role: "model", toolStep: { calls: res.toolCalls, raw: res.raw } });
      history.push({ role: "user", toolResults: results });
    }
  } catch (e) {
    const kind = e instanceof ProviderError ? e.kind : "http";
    await bump({ requests: 1, fallbacks: 1, tokens_in: tokensIn, tokens_out: tokensOut });
    await admin.from("ai_guardrail_events").insert({ conversation_id: null, stage: "output", rule: "ops_provider_error:" + kind, detail: String((e as Error).message ?? "").slice(0, 300) });
    return finish(fallbackOpsReply(message, ctxData), "deterministic", { ai_status: "provider_error:" + kind });
  }

  const out = finalText ? gateOpsOutput(finalText) : { ok: false, text: "", violations: ["no_text"] };
  await bump({ requests: 1, tokens_in: tokensIn, tokens_out: tokensOut, guardrail_blocks: out.ok ? 0 : 1 });
  if (!out.ok) return finish(fallbackOpsReply(message, ctxData), "deterministic", { ai_status: "output_blocked:" + out.violations.join(",") });
  return finish(out.text, "ai");
});
