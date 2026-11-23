/**
 * ai-reception — the only AI entry point.
 *
 * POST { message, conversation_id?, guest_token?, branch_id?, channel?, client_fingerprint? }
 *  → { conversation_id, reply, actions[], mode: "ai"|"scripted", handed_off, verified }
 *
 * Pipeline (every step is enforced server-side, the browser can't skip any):
 *   settings → budgets/rate limits → persist guest msg → INPUT GATE →
 *   (scripted | model loop with TOOL GATE, ≤3 tool rounds) → OUTPUT GATE →
 *   persist reply → usage accounting → response
 *
 * Secrets: GEMINI_API_KEY, SUPABASE_SERVICE_ROLE_KEY, APP_BASE_URL (Edge secrets).
 */
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { projectKey } from "../_shared/keys.ts";
import { gateInput, gateOutput, scriptedReply, isEnglishMessage, buildSystemPrompt, propertyFacts, isAllowedTool, validateToolArgs, matchKnowledge, type PropertyKnowledge, type Scope } from "../_shared/guardrails.ts";
import { createProvider, ProviderError, type ChatTurn, type ToolResult } from "../_shared/llm.ts";
import { TOOL_DECLARATIONS, executeTool } from "../_shared/tools.ts";
import { mayResumeConversation, aiBudgetAvailable } from "../_shared/reception_scope.ts";
import { localDay } from "../_shared/dates.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-hotel-slug, x-guest-token",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...CORS, "content-type": "application/json" } });

const MAX_TOOL_ROUNDS = 3;
const HISTORY_TURNS = 12;
const MAX_OFFSCOPE_STRIKES = 3;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!, secret = projectKey("secret");
  const auth = req.headers.get("authorization") ?? "";
  const trustedService = req.headers.get("apikey") === secret || auth === `Bearer ${secret}`;
  const scopeHeaders = { "x-hotel-slug": req.headers.get("x-hotel-slug") ?? "", "x-guest-token": req.headers.get("x-guest-token") ?? "" };
  const db = createClient(url, secret, { global: { headers: scopeHeaders }, auth: { persistSession: false } });
  const user = createClient(url, projectKey("publishable"), { global: { headers: { Authorization: auth, ...scopeHeaders } }, auth: { persistSession: false } });
  const appBaseUrl = (Deno.env.get("APP_BASE_URL") ?? "").replace(/\/$/, "");

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "bad_json" }, 400); }

  const message = String(body.message ?? "").trim();
  const channel = body.channel === "whatsapp" ? "whatsapp" : "screen";
  const fingerprint = String(body.client_fingerprint ?? req.headers.get("x-forwarded-for") ?? "").slice(0, 120);
  let conversationId = typeof body.conversation_id === "string" ? body.conversation_id : null;
  let guestToken = typeof body.guest_token === "string" && body.guest_token.length >= 8 ? body.guest_token : null;
  if (!message) return json({ error: "empty_message" }, 400);
  if (message.length > 2000) return json({ error: "message_too_long" }, 413);
  // GUEST-10: a question in English is answered in English
  const english = isEnglishMessage(message);

  // ---- organization / branch / settings -----------------------------------
  let branchId = typeof body.branch_id === "string" ? body.branch_id : null;
  let organizationId: string | null = null;
  const { data: staffId } = trustedService ? { data: null } : await user.rpc("fn_staff_id");
  if (trustedService) {
    if (!branchId) return json({ error: "branch_required" }, 400);
    const { data: b } = await db.from("branches").select("organization_id").eq("id", branchId).eq("is_active", true).is("archived_at", null).maybeSingle();
    organizationId = b?.organization_id ?? null;
  } else if (staffId && !scopeHeaders["x-hotel-slug"]) {
    const { data: staff } = await user.from("staff_profiles").select("organization_id").eq("id", staffId).maybeSingle();
    const { data: b } = await user.from("branches").select("id").eq("id", branchId).maybeSingle();
    organizationId = b ? staff?.organization_id ?? null : null;
  } else {
    const { data } = await db.rpc("fn_guest_org_id"); organizationId = data;
  }
  if (!organizationId) return json({ error: "hotel_required" }, 400);
  const { data: org } = await db.from("organizations").select("id, name_ar").eq("id", organizationId).maybeSingle();
  if (!org) return json({ error: "org_not_found" }, 400);
  if (!branchId) {
    const { data: list } = await db.from("branches").select("id").eq("organization_id", org.id).eq("is_active", true).is("archived_at", null).limit(2);
    if (list?.length === 1) branchId = list[0].id;
  }
  const { data: branch } = await db.from("branches").select("id, name_ar, timezone").eq("id", branchId).eq("organization_id", org.id).eq("is_active", true).is("archived_at", null).maybeSingle();
  if (!branch) return json({ error: "branch_not_found" }, 400);
  if (channel === "whatsapp" && !trustedService) return json({ error: "forbidden_channel" }, 403);

  const { data: settings } = await db.from("ai_settings").select("*").eq("organization_id", org.id).maybeSingle();
  const s = settings ?? { enabled: false, provider: "gemini", model: "gemini-3.8-flash", fallback_models: ["gemini-3.6-flash", "gemini-3.5-flash-lite"], temperature: 0.2, max_output_tokens: 400, timeout_ms: 12000, daily_request_limit: 2000, daily_token_budget: 500000, per_session_message_limit: 40, strict_scope: true, extra_instructions: null };

  // ---- conversation -------------------------------------------------------
  // A token supplied by the caller must name a current booking in this exact hotel and branch.
  if (guestToken) {
    const { data: link } = await db.from("registration_sessions").select("reservation_id, organization_id, branch_id").eq("token", guestToken).gt("expires_at", new Date().toISOString()).eq("organization_id", org.id).eq("branch_id", branch.id).maybeSingle();
    if (!link) return json({ error: "invalid_guest_scope" }, 403);
  }
  if (conversationId) {
    const { data: c } = await db.from("conversations").select("id, organization_id, status, guest_token, branch_id, client_fingerprint, channel").eq("id", conversationId).eq("organization_id", org.id).eq("branch_id", branch.id).maybeSingle();
    if (!c || !mayResumeConversation(c, { organizationId: org.id, branchId: branch.id, guestToken }, { trustedService, staff: !!staffId, fingerprint, channel })) return json({ error: "invalid_conversation_scope" }, 403);
  }
  if (!conversationId) {
    const { data: c } = await db.from("conversations").insert({ organization_id: org.id, channel, status: "active", branch_id: branch.id, guest_token: guestToken, client_fingerprint: fingerprint }).select("id").single();
    conversationId = c!.id;
  } else if (guestToken) {
    await db.from("conversations").update({ guest_token: guestToken, last_message_at: new Date().toISOString() }).eq("id", conversationId);
  }

  const { data: conv } = await db.from("conversations").select("status").eq("id", conversationId).single();
  let handedOff = conv?.status === "handed_off";

  // ---- per-session limit --------------------------------------------------
  const { count: msgCount } = await db.from("conversation_messages").select("id", { count: "exact", head: true }).eq("conversation_id", conversationId).eq("sender", "guest");
  if ((msgCount ?? 0) >= s.per_session_message_limit) {
    await db.from("ai_guardrail_events").insert({ conversation_id: conversationId, stage: "budget", rule: "session_message_limit" });
    return json({ conversation_id: conversationId, mode: "scripted", verified: !!guestToken, handed_off: handedOff, reply: english ? "This chat has reached its message limit. To continue, contact the reception or start a new chat." : "وصلت المحادثة إلى الحد الأقصى للرسائل. للمتابعة، تواصل مع الاستقبال أو ابدأ جلسة جديدة.", actions: [{ label: english ? "Start again" : "البدء من جديد", route: "/reception" }] });
  }

  // ---- persist guest message (PII-redacted) --------------------------------
  const input = gateInput(message);
  await db.from("conversation_messages").insert({ conversation_id: conversationId, sender: "guest", content: input.redacted, meta: { pii: input.piiFound, scope: input.scope, channel } });

  // ---- SEC-02: the conversation's rhythm (the same message again and again, a burst, far more tokens than a normal
  // conversation) stops the AI here and hands the conversation to the supervisor with one ticket (fn_ai_conversation_guard)
  if (!handedOff) {
    const { data: guard } = await db.rpc("fn_ai_conversation_guard", { p_conversation: conversationId });
    if ((guard as { stop?: boolean } | null)?.stop) handedOff = true;
  }

  // ---- property facts the deterministic path may state (never invented) ------
  // loaded once per request (three queries in parallel), shared by the scripted path, the knowledge pre-check and the prompt
  let knowledgeOnce: Promise<PropertyKnowledge> | null = null;
  const loadKnowledge = () => knowledgeOnce ??= (async () => {
    const [{ data: bfull }, { data: pols }, { data: kb }] = await Promise.all([
      // decisions 23 and 31: the platform link every new booking goes to, and the map link
      db.from("branches").select("name_ar, check_in_time, check_out_time, address, phone, map_url, booking_platform_url").eq("id", branch.id).maybeSingle(),
      db.from("property_policies").select("topic, title, content_ar").eq("branch_id", branch.id).eq("is_public", true).order("sort_order"),
      db.rpc("fn_public_knowledge", { p_branch: branch.id }),
    ]);
    return { branchName: bfull?.name_ar, checkInTime: bfull?.check_in_time, checkOutTime: bfull?.check_out_time, address: bfull?.address, phone: bfull?.phone,
             mapUrl: bfull?.map_url ?? null, bookingUrl: bfull?.booking_platform_url ?? null,
             policies: (pols ?? []).map((p: { topic: string; title: string; content_ar: string }) => ({ topic: p.topic, title: p.title, content: p.content_ar })), entries: (kb ?? []) as PropertyKnowledge["entries"] };
  })();
  // what the deterministic path learned: count answer usage, log questions nobody has answered yet
  const noteScripted = async (r: { intent: string; knowledgeId?: string }) => {
    if (r.knowledgeId) await db.rpc("fn_knowledge_usage_bump", { p_entry: r.knowledgeId });
    if (r.intent === "unknown") await db.rpc("fn_record_unanswered", { p_branch: branch.id, p_question: message.slice(0, 300), p_conversation: conversationId });
  };

  // ---- if a human took over, the model stays out; factual FAQ still gets answered and the guest can start over ----
  if (handedOff) {
    const r = scriptedReply(message, org.name_ar, undefined, await loadKnowledge());
    await noteScripted(r);
    const informative = ["policy", "knowledge", "existing_booking", "new_booking", "access_code"].includes(r.intent);
    const reply = english
      ? (informative ? r.text + "\n\nYour chat is still with the reception supervisor, who will reply here when available."
        : "Your chat has been passed to the reception supervisor, who will reply here shortly. Meanwhile you can ask me about check-in and check-out times, internet, parking or the location, or start a new chat.")
      : informative
      ? r.text + "\n\nمحادثتك ما زالت محوّلة إلى مشرف الاستقبال وسيرد عليك هنا عند توفره."
      : "تم تحويل محادثتك إلى مشرف الاستقبال وسيرد عليك هنا قريبًا. أثناء الانتظار يمكنك سؤالي عن مواعيد الوصول والمغادرة أو الإنترنت أو المواقف أو الموقع، أو بدء محادثة جديدة.";
    await db.from("conversation_messages").insert({ conversation_id: conversationId, sender: "assistant", content: reply, meta: { mode: "scripted", reason: "handed_off" } });
    return json({ conversation_id: conversationId, mode: "scripted", verified: !!guestToken, handed_off: true, reply, intent: r.intent, actions: [...(informative ? r.actions.filter((a) => !a.value) : []), { label: english ? "New chat" : "محادثة جديدة", route: "/reception?new=1" }] });
  }

  // ---- INPUT GATE -----------------------------------------------------------
  const dayKey = new Date().toISOString().slice(0, 10);
  // atomic server-side increment (fn_ai_usage_bump, service role only): concurrent requests never overwrite counters
  const bump = async (patch: Record<string, number>) => {
    const { data } = await db.rpc("fn_ai_usage_bump", { p_org: org.id, p_day: dayKey, p_requests: patch.requests ?? 0, p_tokens_in: patch.tokens_in ?? 0, p_tokens_out: patch.tokens_out ?? 0, p_fallbacks: patch.fallbacks ?? 0, p_blocks: patch.guardrail_blocks ?? 0 });
    return data;
  };

  const respondScripted = async (reason: Scope | "fallback", extra?: Record<string, unknown>) => {
    const r = scriptedReply(message, org.name_ar, reason === "fallback" ? undefined : reason, await loadKnowledge());
    await noteScripted(r);
    if (/(موظف|مشرف|انسان|بشري|human|staff|supervisor)/.test(message)) {
      await executeTool("request_human_assistance", { reason: "طلب صريح من النزيل (مسار تقليدي)" }, ctx());
    } else if (r.handoff) {
      // GUEST-09: an arrival, a fault or an extension reaches the reception at once
      await executeTool("request_human_assistance", { reason: r.handoff }, ctx());
    }
    await db.from("conversation_messages").insert({ conversation_id: conversationId, sender: "assistant", content: r.text, meta: { mode: "scripted", reason } });
    await bump({ requests: 1, fallbacks: reason === "fallback" ? 1 : 0, guardrail_blocks: reason === "injection" || reason === "off_scope" ? 1 : 0 });
    return json({ conversation_id: conversationId, mode: "scripted", verified: !!guestToken, handed_off: false, reply: r.text, actions: r.actions, intent: r.intent, ...extra });
  };
  const ctx = () => ({ db, organizationId: org.id, branchId: branch.id, conversationId: conversationId!, guestToken, appBaseUrl, propertyName: org.name_ar });

  if (input.scope === "injection" || input.scope === "off_scope") {
    await db.from("ai_guardrail_events").insert({ conversation_id: conversationId, stage: "input", rule: input.scope + ":" + (input.rule ?? ""), detail: input.redacted.slice(0, 200) });
    // repeated abuse → hand off to a human and stop answering
    const { count: strikes } = await db.from("ai_guardrail_events").select("id", { count: "exact", head: true }).eq("conversation_id", conversationId).eq("stage", "input");
    if ((strikes ?? 0) >= MAX_OFFSCOPE_STRIKES) {
      await executeTool("open_supervisor_ticket", { reason: "محاولات متكررة خارج النطاق أو حقن تعليمات" }, ctx());
    }
    return respondScripted(input.scope);
  }

  // ---- a clear knowledge-base hit is answered deterministically, model or not --------
  // (identical wording every time, zero tokens, and the answer is exactly what staff wrote)
  {
    const k = await loadKnowledge();
    const pre = scriptedReply(message, org.name_ar, undefined, k);
    // GUEST-10: an English question with the model on goes to the model, which answers from the same approved text in English
    if (pre.intent === "knowledge" && pre.knowledgeId && matchKnowledge(message, k.entries)?.strong && !(english && s.enabled)) {
      await noteScripted(pre);
      await db.from("conversation_messages").insert({ conversation_id: conversationId, sender: "assistant", content: pre.text, meta: { mode: "scripted", reason: "knowledge", entry: pre.knowledgeId } });
      await bump({ requests: 1 });
      return json({ conversation_id: conversationId, mode: "scripted", verified: !!guestToken, handed_off: false, reply: pre.text, actions: pre.actions, intent: pre.intent, ai_status: s.enabled ? "knowledge_hit" : "disabled" });
    }
    // GUEST-09 / GUEST-21: an arrival, a fault, an extension or an ID number typed in the chat is answered the same way
    // whether the model is on or not, and the first three reach the reception at once
    if (pre.handoff || pre.intent === "privacy") return await respondScripted("in_scope", { ai_status: "scripted_route" });
  }

  // ---- AI disabled / provider missing → scripted ----------------------------
  const provider = s.enabled ? createProvider(s.provider, s.model, Deno.env, s.fallback_models ?? []) : null;
  if (!provider) return respondScripted("fallback", { ai_status: s.enabled ? "awaiting_credentials" : "disabled" });

  // ---- daily budgets ---------------------------------------------------------
  const { data: usage } = await db.from("ai_usage_daily").select("*").eq("organization_id", org.id).eq("day", dayKey).maybeSingle();
  if (!aiBudgetAvailable(s, usage)) {
    await db.from("ai_guardrail_events").insert({ conversation_id: conversationId, stage: "budget", rule: "daily_budget_exhausted" });
    return respondScripted("fallback", { ai_status: "budget_exhausted" });
  }

  // ---- build history ---------------------------------------------------------
  const { data: hist } = await db.from("conversation_messages").select("sender, content, created_at").eq("conversation_id", conversationId).order("created_at", { ascending: false }).limit(HISTORY_TURNS);
  const history: ChatTurn[] = (hist ?? []).reverse()
    .filter((m) => m.sender === "guest" || m.sender === "assistant")
    .map((m) => ({ role: m.sender === "guest" ? "user" : "model", text: m.content }));
  // the current (redacted) message is already the last element

  // the prompt states the branch's own date (dayKey is the UTC day the usage counters use)
  // the property's own facts go into the prompt, so most questions are answered in ONE model call (no tool round trip)
  const system = buildSystemPrompt({ propertyName: org.name_ar, branchName: branch.name_ar, verified: !!guestToken, extra: s.strict_scope ? s.extra_instructions : s.extra_instructions, today: localDay(branch.timezone), facts: propertyFacts(await loadKnowledge()) });
  const userWroteEnglish = english;

  let tokensIn = 0, tokensOut = 0;
  let finalText: string | null = null;
  const actions: { label: string; route?: string }[] = [];
  let answeredBy: string = s.model;          // the model that actually answered (a fallback when the configured one was down)
  const fellBack: string[] = [];             // models that failed before it, with Google's reason

  try {
    for (let round = 0; round <= MAX_TOOL_ROUNDS; round++) {
      const res = await provider.generate({ system, history, tools: TOOL_DECLARATIONS, temperature: Number(s.temperature), maxOutputTokens: s.max_output_tokens, timeoutMs: s.timeout_ms });
      tokensIn += res.usage.input; tokensOut += res.usage.output;
      if (res.model) answeredBy = res.model;
      if (res.fallbackFrom?.length) fellBack.push(...res.fallbackFrom);
      if (res.blockedBySafety) { await db.from("ai_guardrail_events").insert({ conversation_id: conversationId, stage: "output", rule: "provider_safety_block" }); break; }

      if (res.toolCalls.length === 0) { finalText = res.text; break; }
      if (round === MAX_TOOL_ROUNDS) { await db.from("ai_guardrail_events").insert({ conversation_id: conversationId, stage: "tool", rule: "max_tool_rounds" }); break; }

      const results: ToolResult[] = [];
      for (const call of res.toolCalls) {
        const started = Date.now();
        let result: unknown; let status = "ok";
        if (!isAllowedTool(call.name)) {
          status = "denied"; result = { denied: true, reason: "tool not allowed" };
          await db.from("ai_guardrail_events").insert({ conversation_id: conversationId, stage: "tool", rule: "unknown_tool", detail: call.name });
        } else {
          try {
            const args = validateToolArgs(call.name, call.args);
            result = await executeTool(call.name, args, ctx());
            if (call.name === "request_booking_verification") actions.push({ label: english ? "My bookings" : "حجوزاتي", route: "/booking/lookup" });
            if (call.name === "create_registration_session" && guestToken) actions.push({ label: english ? "Guests' details" : "تسجيل بيانات النزلاء", route: `/booking/registration/${guestToken}` });
            if (call.name === "get_verified_booking_summary" && guestToken) actions.push({ label: english ? "Booking status" : "حالة الحجز", route: `/booking/status/${guestToken}` });
            if (call.name === "get_booking_link") actions.push({ label: english ? "Book now" : "احجز الآن", route: "/booking/new" });
          } catch (e) {
            status = "error"; result = { error: String((e as Error).message).slice(0, 120) };
          }
        }
        await db.from("ai_tool_executions").insert({ conversation_id: conversationId, tool_name: call.name, args_redacted: call.args, result_status: status, latency_ms: Date.now() - started });
        results.push({ name: call.name, id: call.id, result });
      }
      // the model's step goes back exactly as it came (thought signatures), then all its results in one turn
      history.push({ role: "model", toolStep: { calls: res.toolCalls, raw: res.raw } });
      history.push({ role: "user", toolResults: results });
    }
  } catch (e) {
    const kind = e instanceof ProviderError ? e.kind : "http";
    await db.from("ai_guardrail_events").insert({ conversation_id: conversationId, stage: "output", rule: "provider_error:" + kind, detail: String((e as Error).message ?? "").slice(0, 300) });
    await bump({ tokens_in: tokensIn, tokens_out: tokensOut });
    return respondScripted("fallback", { ai_status: "provider_error:" + kind });
  }
  // a fallback model answered: the owner sees it next to the provider errors (ai-settings → events)
  if (fellBack.length) await db.from("ai_guardrail_events").insert({ conversation_id: conversationId, stage: "output", rule: "provider_fallback:" + answeredBy, detail: fellBack.join(" | ").slice(0, 300) });

  // ---- OUTPUT GATE -----------------------------------------------------------
  // the links the answer may carry: the website's pages, the branch's platform link and its map link (decisions 23, 31)
  const allowedUrls = [appBaseUrl, "/booking/", "/checkin/", "/kiosk", "/privacy", "/terms"];
  { const k = await loadKnowledge(); if (k.bookingUrl) allowedUrls.push(k.bookingUrl); if (k.mapUrl) allowedUrls.push(k.mapUrl); }

  const out = finalText ? gateOutput(finalText, { allowedUrls, userWroteEnglish }) : { ok: false, text: "", violations: ["no_text"] };
  if (!out.ok) {
    await db.from("ai_guardrail_events").insert({ conversation_id: conversationId, stage: "output", rule: out.violations.join(","), detail: (finalText ?? "").slice(0, 200) });
    await bump({ tokens_in: tokensIn, tokens_out: tokensOut, guardrail_blocks: 1 });
    return respondScripted("fallback", { ai_status: "output_blocked" });
  }

  const uniqActions = actions.filter((a, i) => actions.findIndex((b) => b.route === a.route) === i).slice(0, 3);
  await db.from("conversation_messages").insert({ conversation_id: conversationId, sender: "assistant", content: out.text, meta: { mode: "ai", model: answeredBy, violations: out.violations, tokens: { in: tokensIn, out: tokensOut } } });
  await db.from("conversations").update({ last_message_at: new Date().toISOString() }).eq("id", conversationId);
  await bump({ requests: 1, tokens_in: tokensIn, tokens_out: tokensOut });

  return json({ conversation_id: conversationId, mode: "ai", verified: !!guestToken, handed_off: false, reply: out.text, actions: uniqActions });
});
