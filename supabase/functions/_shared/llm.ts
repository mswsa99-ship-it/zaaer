/**
 * Provider-agnostic LLM adapter. Business logic never touches a vendor SDK;
 * it only sees `LLMProvider`. Gemini is the first implementation.
 *
 * The API key is read from the Edge Function secret GEMINI_API_KEY and is never
 * stored in the database nor returned to any client.
 */

export interface ToolDeclaration {
  name: string;
  description: string;
  parameters: Record<string, unknown>; // JSON schema (OpenAPI subset)
}

export interface ToolCall {
  name: string;
  args: Record<string, unknown>;
  /** provider call id — echoed on the matching result (Gemini 3+ returns one for every call) */
  id?: string;
}

export interface ToolResult {
  name: string;
  result: unknown;
  id?: string;
}

export interface ChatTurn {
  role: "user" | "model";
  text?: string;
  /**
   * One model step that called tools. `calls` is provider-neutral; `raw` is the provider's own content for that
   * step and is sent back verbatim — Gemini 3+ rejects a tool step whose thought signatures are not returned in
   * the exact parts they arrived in.
   */
  toolStep?: { calls: ToolCall[]; raw?: unknown };
  /** The results of the preceding tool step, in call order, sent back as ONE turn (never interleaved with calls). */
  toolResults?: ToolResult[];
}

export interface GenerateRequest {
  system: string;
  history: ChatTurn[];
  tools: ToolDeclaration[];
  temperature: number;
  maxOutputTokens: number;
  timeoutMs: number;
}

export interface GenerateResponse {
  text: string | null;
  toolCalls: ToolCall[];
  /** the provider's content for this response; pass it back as `toolStep.raw` when the step called tools */
  raw?: unknown;
  usage: { input: number; output: number };
  finishReason: string;
  blockedBySafety: boolean;
  /** the model that answered — one of the fallbacks when the configured model was unavailable */
  model?: string;
  /** the models tried before `model`, each with why it failed ("gemini-x: http 503: …"); empty when the first choice answered */
  fallbackFrom?: string[];
}

export interface LLMProvider {
  readonly name: string;
  generate(req: GenerateRequest): Promise<GenerateResponse>;
}

export class ProviderError extends Error {
  constructor(
    message: string,
    public readonly kind: "timeout" | "auth" | "quota" | "http" | "parse",
    public readonly status?: number,
    /** the wait the provider asked for (Gemini sends one with quota errors) */
    public readonly retryAfterMs?: number,
  ) {
    super(message);
  }
}

// ---------------------------------------------------------------------------
// Gemini (Google AI Studio REST API, generateContent)
// ---------------------------------------------------------------------------

/** Output allowance for reasoning: on thinking models maxOutputTokens counts thought tokens too. */
export const THINKING_ALLOWANCE_TOKENS = 2048;

/**
 * Gemini 3 and later think by default, take `thinkingLevel` instead of a budget, and are tuned for the default
 * temperature (Google: lower values can cause looping). Gemini 2.x keeps the classic settings.
 */
export function isThinkingGemini(model: string): boolean {
  const m = /^gemini-(\d+)/.exec(model);
  if (m) return Number(m[1]) >= 3;
  return /^gemini-(flash|pro|flash-lite)-latest$/.test(model);   // the aliases point at current (3+) models
}

/** A parameterless tool is declared without `parameters`: an OBJECT schema with no properties is rejected. */
export function toGeminiDeclaration(t: ToolDeclaration): Record<string, unknown> {
  const p = t.parameters as { type?: string; properties?: Record<string, unknown> } | undefined;
  const empty = !p || (p.type === "object" && (!p.properties || Object.keys(p.properties).length === 0));
  return empty ? { name: t.name, description: t.description } : { name: t.name, description: t.description, parameters: t.parameters };
}

const KEY_LIKE = /AIza[0-9A-Za-z_-]{20,}/g;

/** "GenerateRequestsPerMinutePerProjectPerModel" → "requests/min"; an id it does not know is kept as it is. */
function quotaLabel(quotaId: string): string {
  const id = quotaId.replace(/-?FreeTier$/i, "");
  if (/Requests?PerMinute/i.test(id)) return "requests/min";
  if (/Requests?PerDay/i.test(id)) return "requests/day";
  if (/Tokens?.*PerMinute/i.test(id)) return "input tokens/min";
  if (/Tokens?.*PerDay/i.test(id)) return "input tokens/day";
  return id;
}

/**
 * Google's error, for the logs and the owner's connection test: its own message, shortened, anything key-shaped
 * masked. A quota error (429) names the limit that ran out and the wait Google asks for first —
 * "http 429: [free tier quota requests/min=5, retry in 41s] You exceeded…" — because the message before them is the
 * same sentence on every 429 and would push them past the log limit. "free tier" means the key's Google project has
 * no billing: low per-model limits per minute and per day.
 */
export function providerErrorInfo(status: number, body: string): { text: string; retryAfterMs?: number } {
  let msg = body;
  let freeTier = false;
  const limits: string[] = [];
  let retryAfterMs: number | undefined;
  try {
    const err = (JSON.parse(body) as { error?: { message?: unknown; details?: unknown } }).error;
    msg = String(err?.message ?? "");
    for (const d of Array.isArray(err?.details) ? (err!.details as Array<Record<string, unknown>>) : []) {
      const type = String(d?.["@type"] ?? "");
      if (type.endsWith("QuotaFailure") && Array.isArray(d.violations)) {
        for (const v of d.violations as Array<{ quotaId?: unknown; quotaValue?: unknown }>) {
          if (typeof v?.quotaId !== "string" || !v.quotaId) continue;
          if (/FreeTier/i.test(v.quotaId)) freeTier = true;
          const limit = quotaLabel(v.quotaId) + (v.quotaValue != null && v.quotaValue !== "" ? `=${String(v.quotaValue).slice(0, 12)}` : "");
          if (!limits.includes(limit)) limits.push(limit);
        }
      } else if (type.endsWith("RetryInfo")) {
        const m = /^(\d+(?:\.\d+)?)s$/.exec(String(d.retryDelay ?? ""));
        if (m) retryAfterMs = Math.round(Number(m[1]) * 1000);
      }
    }
  } catch { /* not JSON (a proxy page, a cut body): the body itself */ }
  const head = [
    limits.length ? `${freeTier ? "free tier " : ""}quota ${limits.slice(0, 3).join(" + ")}` : "",
    retryAfterMs !== undefined ? `retry in ${Math.ceil(retryAfterMs / 1000)}s` : "",
  ].filter(Boolean).join(", ");
  const text = `http ${status}: ${head ? `[${head}] ` : ""}${msg.replace(KEY_LIKE, "[key]").replace(/\s+/g, " ").trim()}`;
  return { text: text.slice(0, 250), retryAfterMs };
}

/** Provider error text for logs (see providerErrorInfo). */
export function providerErrorText(status: number, body: string): string {
  return providerErrorInfo(status, body).text;
}

// ---------------------------------------------------------------------------
// Model fallback. Google answers "503 high demand" for a model for hours at a time, per model and
// sometimes per key; another current model usually still answers. So the configured model comes first,
// then the owner's fallback list (ai_settings.fallback_models), within the same time budget.
// ---------------------------------------------------------------------------

/**
 * Statuses that describe the MODEL right now, not the request, so another model may well answer:
 * 404 retired/unknown model id, 408/504 deadline, 429 that model's quota, 500/502/503 capacity.
 * 400 (the request), 401/403 (the key) and network failures are the same for every model: the chain stops.
 */
const MODEL_UNAVAILABLE = new Set([404, 408, 429, 500, 502, 503, 504]);
/**
 * How long later requests on this instance try a model that just failed that way last (ms): the wait Google asked
 * for when it sent one (quota errors: until the minute's quota frees up, or much longer once a day's is spent),
 * kept within 5 s – 10 min; otherwise by status.
 */
export const cooldownMs = (status?: number, retryAfterMs?: number): number =>
  retryAfterMs !== undefined && Number.isFinite(retryAfterMs)
    ? Math.min(Math.max(retryAfterMs, 5_000), 600_000)
    : status === 404 ? 600_000 : status === 429 ? 60_000 : 120_000;
const cooldowns = new Map<string, number>();   // model id → deprioritised until (epoch ms); shared by all requests of this isolate
/** Test hook: forget which models were cooling down. */
export function resetModelCooldowns(): void { cooldowns.clear(); }
/** Another model is tried only while at least this much of the request's time budget is left. */
export const MIN_ATTEMPT_MS = 1500;
/**
 * Google's documented placeholder for a function call the receiving model did not produce itself (thought-signature
 * docs: traces moved between models, injected calls). Used when a tool loop continues on another model: that model
 * cannot validate the first one's signatures. A step always goes back to its own model verbatim.
 */
export const FOREIGN_THOUGHT_SIGNATURE = "skip_thought_signature_validator";

/** A tool step as another model may receive it: its own signatures removed, the placeholder on the first call. */
function foreignStep(parts: Array<Record<string, unknown>>): Array<Record<string, unknown>> {
  let first = true;
  return parts.map((p) => {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(p)) if (k !== "thoughtSignature") out[k] = v;
    if (p.functionCall && first) { first = false; out.thoughtSignature = FOREIGN_THOUGHT_SIGNATURE; }
    return out;
  });
}

export class GeminiProvider implements LLMProvider {
  readonly name = "gemini";
  /** configured model first, then the fallbacks; blanks and repeats removed */
  readonly models: string[];
  constructor(private readonly apiKey: string, private readonly model: string, fallbacks: string[] = []) {
    this.models = [...new Set([model, ...fallbacks].map((m) => String(m ?? "").trim()).filter(Boolean))];
  }

  /**
   * The order to try models in for this step: the model that produced the latest tool step first (a tool loop
   * stays on its model — the signatures are its own), then the configured order; models that failed in the last
   * minutes on this instance go last, as a final resort.
   */
  candidates(history: ChatTurn[]): string[] {
    const started = ([...history].reverse().find((t) => t.toolStep)?.toolStep?.raw as { model?: string } | undefined)?.model;
    const order = started && this.models.includes(started) ? [started, ...this.models.filter((m) => m !== started)] : this.models;
    const now = Date.now();
    const cooling = (m: string) => (cooldowns.get(m) ?? 0) > now;
    return [...order.filter((m) => !cooling(m)), ...order.filter(cooling)];
  }

  toContents(history: ChatTurn[], model: string = this.model) {
    const contents: Array<{ role: string; parts: unknown[] }> = [];
    for (const t of history) {
      if (t.toolStep) {
        const raw = t.toolStep.raw as { parts?: Array<Record<string, unknown>>; model?: string } | undefined;
        if (raw && Array.isArray(raw.parts) && raw.parts.length) {
          contents.push({ role: "model", parts: raw.model && raw.model !== model ? foreignStep(raw.parts) : raw.parts });
        } else {
          const parts = t.toolStep.calls.map((c) => ({ functionCall: { name: c.name, args: c.args, ...(c.id ? { id: c.id } : {}) } }));
          contents.push({ role: "model", parts: isThinkingGemini(model) ? foreignStep(parts) : parts });
        }
      } else if (t.toolResults) {
        contents.push({ role: "user", parts: t.toolResults.map((r) => ({ functionResponse: { name: r.name, ...(r.id ? { id: r.id } : {}), response: { result: r.result } } })) });
      } else {
        contents.push({ role: t.role, parts: [{ text: t.text ?? "" }] });
      }
    }
    return contents;
  }

  buildBody(req: GenerateRequest, model: string = this.model): Record<string, unknown> {
    const thinking = isThinkingGemini(model);
    return {
      systemInstruction: { parts: [{ text: req.system }] },
      contents: this.toContents(req.history, model),
      tools: req.tools.length ? [{ functionDeclarations: req.tools.map(toGeminiDeclaration) }] : undefined,
      toolConfig: req.tools.length ? { functionCallingConfig: { mode: "AUTO" } } : undefined,
      generationConfig: thinking
        ? { maxOutputTokens: req.maxOutputTokens + THINKING_ALLOWANCE_TOKENS, candidateCount: 1, thinkingConfig: { thinkingLevel: "low" } }
        : { temperature: req.temperature, maxOutputTokens: req.maxOutputTokens, candidateCount: 1 },
      safetySettings: [
        { category: "HARM_CATEGORY_HARASSMENT", threshold: "BLOCK_LOW_AND_ABOVE" },
        { category: "HARM_CATEGORY_HATE_SPEECH", threshold: "BLOCK_LOW_AND_ABOVE" },
        { category: "HARM_CATEGORY_SEXUALLY_EXPLICIT", threshold: "BLOCK_LOW_AND_ABOVE" },
        { category: "HARM_CATEGORY_DANGEROUS_CONTENT", threshold: "BLOCK_LOW_AND_ABOVE" },
      ],
    };
  }

  /**
   * One step. `req.timeoutMs` is the budget for the whole step, fallbacks included, so a guest never waits longer
   * because a model was down. Throws the provider's error when nothing answered (several attempts → all of them).
   */
  async generate(req: GenerateRequest): Promise<GenerateResponse> {
    const deadline = Date.now() + req.timeoutMs;
    const failed: string[] = [];
    let last: ProviderError | null = null;
    for (const model of this.candidates(req.history)) {
      const left = deadline - Date.now();
      if (last && left < MIN_ATTEMPT_MS) break;
      try {
        const res = await this.call(model, req, Math.max(left, 1));
        return { ...res, model, raw: res.raw ? { ...(res.raw as Record<string, unknown>), model } : undefined, fallbackFrom: failed };
      } catch (e) {
        if (!(e instanceof ProviderError)) throw e;
        last = e;
        failed.push(`${model}: ${e.message}`.slice(0, 160));
        if (e.kind === "timeout") { cooldowns.set(model, Date.now() + 60_000); break; }   // the step's budget is spent
        if (e.status === undefined || !MODEL_UNAVAILABLE.has(e.status)) break;          // would fail the same on any model
        cooldowns.set(model, Date.now() + cooldownMs(e.status, e.retryAfterMs));
      }
    }
    if (!last) throw new ProviderError("no model configured", "http");
    throw failed.length > 1 ? new ProviderError(failed.join(" | "), last.kind, last.status, last.retryAfterMs) : last;
  }

  private async call(model: string, req: GenerateRequest, timeoutMs: number): Promise<GenerateResponse> {
    const url = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`;
    const body = this.buildBody(req, model);

    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), timeoutMs);
    let res: Response;
    try {
      res = await fetch(url, {
        method: "POST",
        headers: { "content-type": "application/json", "x-goog-api-key": this.apiKey },
        body: JSON.stringify(body),
        signal: ctrl.signal,
      });
    } catch (e) {
      clearTimeout(timer);
      if ((e as Error).name === "AbortError") throw new ProviderError("timeout", "timeout");
      throw new ProviderError(String(e).replace(KEY_LIKE, "[key]").slice(0, 240), "http");
    }
    clearTimeout(timer);

    if (!res.ok) {
      const { text: detail, retryAfterMs } = providerErrorInfo(res.status, await res.text().catch(() => ""));
      if (res.status === 401 || res.status === 403) throw new ProviderError(detail, "auth", res.status);
      if (res.status === 429) throw new ProviderError(detail, "quota", res.status, retryAfterMs);
      throw new ProviderError(detail, "http", res.status, retryAfterMs);
    }

    let json: Record<string, unknown>;
    try { json = await res.json(); } catch { throw new ProviderError("parse", "parse"); }
    return parseGeminiResponse(json);
  }
}

export function parseGeminiResponse(json: Record<string, unknown>): GenerateResponse {
  const cand = (json.candidates as Array<Record<string, unknown>> | undefined)?.[0];
  const promptFeedback = json.promptFeedback as { blockReason?: string } | undefined;
  const usage = json.usageMetadata as { promptTokenCount?: number; candidatesTokenCount?: number; thoughtsTokenCount?: number } | undefined;
  const content = cand?.content as { role?: string; parts?: Array<Record<string, unknown>> } | undefined;
  const parts = content?.parts ?? [];

  const toolCalls: ToolCall[] = [];
  const texts: string[] = [];
  for (const p of parts) {
    if (p.functionCall) {
      const fc = p.functionCall as { name: string; args?: Record<string, unknown>; id?: string };
      toolCalls.push({ name: fc.name, args: fc.args ?? {}, ...(fc.id ? { id: fc.id } : {}) });
    } else if (typeof p.text === "string" && p.thought !== true) texts.push(p.text);
  }
  return {
    text: texts.length ? texts.join("\n") : null,
    toolCalls,
    raw: content ? { role: "model", parts } : undefined,
    // thought tokens are billed as output, so the daily budget counts them too
    usage: { input: usage?.promptTokenCount ?? 0, output: (usage?.candidatesTokenCount ?? 0) + (usage?.thoughtsTokenCount ?? 0) },
    finishReason: String(cand?.finishReason ?? promptFeedback?.blockReason ?? "UNKNOWN"),
    blockedBySafety: !!promptFeedback?.blockReason || cand?.finishReason === "SAFETY",
  };
}

/** `fallbacks`: models to try, in order, when `model` is unavailable (ai_settings.fallback_models). */
export function createProvider(provider: string, model: string, env: { get(k: string): string | undefined }, fallbacks: string[] = []): LLMProvider | null {
  if (provider === "gemini") {
    const key = env.get("GEMINI_API_KEY");
    if (!key) return null;
    return new GeminiProvider(key, model, Array.isArray(fallbacks) ? fallbacks : []);
  }
  return null;
}
