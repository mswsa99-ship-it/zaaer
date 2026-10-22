/**
 * ai-health — owner/manager-only connectivity test for the AI provider.
 * Verifies the caller's Supabase JWT + role, then sends a tiny probe to the configured model and to each fallback
 * model, separately and in parallel, so the owner sees which ones answer right now.
 * Never returns the key; only { configured, ok, primary, model, latency_ms, error, checked[] }:
 *   ok     — at least one model answered (the assistants will use the first one that does)
 *   model  — the model the assistants would use now; differs from `primary` when it is down
 *   error  — the configured model's failure, if it failed
 */
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { createProvider, ProviderError } from "../_shared/llm.ts";

const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "content-type": "application/json" } });

/** The provider's own reason (key-shaped text masked by the adapter) tells the owner what to fix. */
const describe = (e: unknown) => e instanceof ProviderError ? (e.message && e.message !== e.kind ? `${e.kind}: ${e.message}` : e.kind) : "unknown";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const auth = req.headers.get("authorization") ?? "";
  const userClient = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const { data: role } = await userClient.rpc("fn_current_role");
  if (!role || !["owner", "manager"].includes(role)) return json({ error: "forbidden" }, 403);

  const { data: settings } = await userClient.from("ai_settings").select("provider, model, timeout_ms, fallback_models").limit(1).maybeSingle();
  const providerName: string = settings?.provider ?? "gemini";
  const primary: string = settings?.model ?? "gemini-3.8-flash";
  const fallbacks: string[] = Array.isArray(settings?.fallback_models) ? settings.fallback_models : [];
  if (!createProvider(providerName, primary, Deno.env)) return json({ configured: false, ok: false, primary, model: primary, error: "GEMINI_API_KEY غير مضبوط في أسرار Edge Functions", checked: [] });

  // each model on its own (no fallback chain), all at once: one slow model does not hide the others
  const models = [...new Set([primary, ...fallbacks])].slice(0, 4);
  const checked = await Promise.all(models.map(async (model) => {
    const started = Date.now();
    try {
      const r = await createProvider(providerName, model, Deno.env)!.generate({ system: "أجب بكلمة واحدة: جاهز", history: [{ role: "user", text: "اختبار" }], tools: [], temperature: 0, maxOutputTokens: 5, timeoutMs: settings?.timeout_ms ?? 10000 });
      return { model, ok: true, latency_ms: Date.now() - started, finish: r.finishReason };
    } catch (e) {
      return { model, ok: false, latency_ms: Date.now() - started, error: describe(e) };
    }
  }));
  const answering = checked.find((c) => c.ok);
  const first = checked[0];
  return json({
    configured: true,
    ok: !!answering,
    primary,
    model: answering?.model ?? primary,
    latency_ms: (answering ?? first).latency_ms,
    error: first.ok ? undefined : first.error,
    checked,
  });
});
