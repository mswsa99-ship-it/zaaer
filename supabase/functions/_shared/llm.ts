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
}

export interface LLMProvider {
  readonly name: string;
  generate(req: GenerateRequest): Promise<GenerateResponse>;
}

export class ProviderError extends Error {
  constructor(message: string, public readonly kind: "timeout" | "auth" | "quota" | "http" | "parse") {
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
/** Provider error text for logs: Google's own message, shortened; anything key-shaped is masked. */
export function providerErrorText(status: number, body: string): string {
  let msg = "";
  try { msg = String((JSON.parse(body) as { error?: { message?: string; status?: string } }).error?.message ?? ""); } catch { msg = body; }
  return `http ${status}: ${msg.replace(KEY_LIKE, "[key]").replace(/\s+/g, " ").trim().slice(0, 240)}`;
}

export class GeminiProvider implements LLMProvider {
  readonly name = "gemini";
  constructor(private readonly apiKey: string, private readonly model: string) {}

  toContents(history: ChatTurn[]) {
    const contents: Array<{ role: string; parts: unknown[] }> = [];
    for (const t of history) {
      if (t.toolStep) {
        const raw = t.toolStep.raw as { parts?: unknown[] } | undefined;
        if (raw && Array.isArray(raw.parts) && raw.parts.length) contents.push({ role: "model", parts: raw.parts });
        else contents.push({ role: "model", parts: t.toolStep.calls.map((c) => ({ functionCall: { name: c.name, args: c.args, ...(c.id ? { id: c.id } : {}) } })) });
      } else if (t.toolResults) {
        contents.push({ role: "user", parts: t.toolResults.map((r) => ({ functionResponse: { name: r.name, ...(r.id ? { id: r.id } : {}), response: { result: r.result } } })) });
      } else {
        contents.push({ role: t.role, parts: [{ text: t.text ?? "" }] });
      }
    }
    return contents;
  }

  buildBody(req: GenerateRequest): Record<string, unknown> {
    const thinking = isThinkingGemini(this.model);
    return {
      systemInstruction: { parts: [{ text: req.system }] },
      contents: this.toContents(req.history),
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

  async generate(req: GenerateRequest): Promise<GenerateResponse> {
    const url = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(this.model)}:generateContent`;
    const body = this.buildBody(req);

    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), req.timeoutMs);
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
      const detail = providerErrorText(res.status, await res.text().catch(() => ""));
      if (res.status === 401 || res.status === 403) throw new ProviderError(detail, "auth");
      if (res.status === 429) throw new ProviderError(detail, "quota");
      throw new ProviderError(detail, "http");
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

export function createProvider(provider: string, model: string, env: { get(k: string): string | undefined }): LLMProvider | null {
  if (provider === "gemini") {
    const key = env.get("GEMINI_API_KEY");
    if (!key) return null;
    return new GeminiProvider(key, model);
  }
  return null;
}
