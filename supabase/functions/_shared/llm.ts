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

export interface ChatTurn {
  role: "user" | "model";
  text?: string;
  toolCall?: { name: string; args: Record<string, unknown> };
  toolResult?: { name: string; result: unknown };
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
  toolCalls: { name: string; args: Record<string, unknown> }[];
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
// Gemini (Google AI Studio REST API)
// ---------------------------------------------------------------------------
export class GeminiProvider implements LLMProvider {
  readonly name = "gemini";
  constructor(private readonly apiKey: string, private readonly model: string) {}

  private toContents(history: ChatTurn[]) {
    const contents: Array<{ role: string; parts: unknown[] }> = [];
    for (const t of history) {
      if (t.toolCall) {
        contents.push({ role: "model", parts: [{ functionCall: { name: t.toolCall.name, args: t.toolCall.args } }] });
      } else if (t.toolResult) {
        contents.push({ role: "user", parts: [{ functionResponse: { name: t.toolResult.name, response: { result: t.toolResult.result } } }] });
      } else {
        contents.push({ role: t.role, parts: [{ text: t.text ?? "" }] });
      }
    }
    return contents;
  }

  async generate(req: GenerateRequest): Promise<GenerateResponse> {
    const url = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(this.model)}:generateContent`;
    const body = {
      systemInstruction: { parts: [{ text: req.system }] },
      contents: this.toContents(req.history),
      tools: req.tools.length ? [{ functionDeclarations: req.tools }] : undefined,
      toolConfig: req.tools.length ? { functionCallingConfig: { mode: "AUTO" } } : undefined,
      generationConfig: {
        temperature: req.temperature,
        maxOutputTokens: req.maxOutputTokens,
        candidateCount: 1,
      },
      safetySettings: [
        { category: "HARM_CATEGORY_HARASSMENT", threshold: "BLOCK_LOW_AND_ABOVE" },
        { category: "HARM_CATEGORY_HATE_SPEECH", threshold: "BLOCK_LOW_AND_ABOVE" },
        { category: "HARM_CATEGORY_SEXUALLY_EXPLICIT", threshold: "BLOCK_LOW_AND_ABOVE" },
        { category: "HARM_CATEGORY_DANGEROUS_CONTENT", threshold: "BLOCK_LOW_AND_ABOVE" },
      ],
    };

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
      throw new ProviderError(String(e), "http");
    }
    clearTimeout(timer);

    if (res.status === 401 || res.status === 403) throw new ProviderError("auth", "auth");
    if (res.status === 429) throw new ProviderError("quota", "quota");
    if (!res.ok) throw new ProviderError(`http ${res.status}`, "http");

    let json: Record<string, unknown>;
    try { json = await res.json(); } catch { throw new ProviderError("parse", "parse"); }

    const cand = (json.candidates as Array<Record<string, unknown>> | undefined)?.[0];
    const promptFeedback = json.promptFeedback as { blockReason?: string } | undefined;
    const usage = json.usageMetadata as { promptTokenCount?: number; candidatesTokenCount?: number } | undefined;
    const parts = ((cand?.content as { parts?: Array<Record<string, unknown>> } | undefined)?.parts) ?? [];

    const toolCalls: { name: string; args: Record<string, unknown> }[] = [];
    const texts: string[] = [];
    for (const p of parts) {
      if (p.functionCall) {
        const fc = p.functionCall as { name: string; args?: Record<string, unknown> };
        toolCalls.push({ name: fc.name, args: fc.args ?? {} });
      } else if (typeof p.text === "string") texts.push(p.text);
    }
    return {
      text: texts.length ? texts.join("\n") : null,
      toolCalls,
      usage: { input: usage?.promptTokenCount ?? 0, output: usage?.candidatesTokenCount ?? 0 },
      finishReason: String(cand?.finishReason ?? promptFeedback?.blockReason ?? "UNKNOWN"),
      blockedBySafety: !!promptFeedback?.blockReason || cand?.finishReason === "SAFETY",
    };
  }
}

export function createProvider(provider: string, model: string, env: { get(k: string): string | undefined }): LLMProvider | null {
  if (provider === "gemini") {
    const key = env.get("GEMINI_API_KEY");
    if (!key) return null;
    return new GeminiProvider(key, model);
  }
  return null;
}
