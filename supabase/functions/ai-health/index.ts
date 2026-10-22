/**
 * ai-health — owner/manager-only connectivity test for the AI provider.
 * Verifies the caller's Supabase JWT + role, then sends a 1-token probe.
 * Never returns the key; only { configured, ok, model, latency_ms, error }.
 */
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { createProvider, ProviderError } from "../_shared/llm.ts";

const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "content-type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const auth = req.headers.get("authorization") ?? "";
  const userClient = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const { data: role } = await userClient.rpc("fn_current_role");
  if (!role || !["owner", "manager"].includes(role)) return json({ error: "forbidden" }, 403);

  const { data: settings } = await userClient.from("ai_settings").select("provider, model, timeout_ms").limit(1).maybeSingle();
  const provider = createProvider(settings?.provider ?? "gemini", settings?.model ?? "gemini-2.5-flash", Deno.env);
  if (!provider) return json({ configured: false, ok: false, model: settings?.model ?? null, error: "GEMINI_API_KEY غير مضبوط في أسرار Edge Functions" });

  const started = Date.now();
  try {
    const r = await provider.generate({ system: "أجب بكلمة واحدة: جاهز", history: [{ role: "user", text: "اختبار" }], tools: [], temperature: 0, maxOutputTokens: 5, timeoutMs: settings?.timeout_ms ?? 10000 });
    return json({ configured: true, ok: true, model: settings?.model, latency_ms: Date.now() - started, finish: r.finishReason });
  } catch (e) {
    const kind = e instanceof ProviderError ? e.kind : "unknown";
    return json({ configured: true, ok: false, model: settings?.model, latency_ms: Date.now() - started, error: kind });
  }
});
