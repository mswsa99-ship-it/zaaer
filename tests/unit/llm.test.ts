import { describe, it, expect, vi, afterEach } from "vitest";
import { GeminiProvider, parseGeminiResponse, isThinkingGemini, toGeminiDeclaration, providerErrorText, ProviderError, THINKING_ALLOWANCE_TOKENS, type ChatTurn } from "../../supabase/functions/_shared/llm";
import { TOOL_DECLARATIONS } from "../../supabase/functions/_shared/tools";
import { OPS_TOOL_DECLARATIONS } from "../../supabase/functions/_shared/ops";

const base = { system: "sys", tools: [], temperature: 0.2, maxOutputTokens: 400, timeoutMs: 5000 };

describe("Gemini adapter — request shape per model generation", () => {
  it("Gemini 3+ / 4 / -latest: thinkingLevel low, output allowance for thought tokens, default temperature", () => {
    for (const model of ["gemini-3.8-flash", "gemini-3.5-flash-lite", "gemini-4-argon", "gemini-flash-latest"]) {
      expect(isThinkingGemini(model), model).toBe(true);
      const g = new GeminiProvider("k", model).buildBody({ ...base, history: [{ role: "user", text: "مرحبا" }] }).generationConfig as Record<string, unknown>;
      expect(g.thinkingConfig).toEqual({ thinkingLevel: "low" });
      expect(g.maxOutputTokens).toBe(400 + THINKING_ALLOWANCE_TOKENS);
      expect(g).not.toHaveProperty("temperature");
      expect(g).not.toHaveProperty("thinkingBudget");
    }
  });
  it("Gemini 2.x keeps temperature and the plain token cap, no thinking settings", () => {
    const g = new GeminiProvider("k", "gemini-2.5-flash").buildBody({ ...base, history: [] }).generationConfig as Record<string, unknown>;
    expect(isThinkingGemini("gemini-2.5-flash")).toBe(false);
    expect(g).toEqual({ temperature: 0.2, maxOutputTokens: 400, candidateCount: 1 });
  });
});

describe("Gemini adapter — tool declarations", () => {
  it("a parameterless tool is sent without `parameters` (an OBJECT schema with no properties is rejected)", () => {
    expect(toGeminiDeclaration({ name: "t", description: "d", parameters: { type: "object", properties: {} } })).toEqual({ name: "t", description: "d" });
    const withArgs = { name: "t", description: "d", parameters: { type: "object", properties: { q: { type: "string" } }, required: ["q"] } };
    expect(toGeminiDeclaration(withArgs)).toEqual(withArgs);
  });
  it("no declared schema anywhere has an OBJECT without properties (reception and ops tools, nested included)", () => {
    const bad: string[] = [];
    const walk = (node: unknown, path: string) => {
      if (!node || typeof node !== "object") return;
      const n = node as { type?: string; properties?: Record<string, unknown>; items?: unknown };
      if (n.type === "object" && (!n.properties || Object.keys(n.properties).length === 0)) bad.push(path);
      for (const [k, v] of Object.entries(n.properties ?? {})) walk(v, `${path}.${k}`);
      if (n.items) walk(n.items, `${path}[]`);
    };
    for (const t of [...TOOL_DECLARATIONS, ...OPS_TOOL_DECLARATIONS]) {
      const d = toGeminiDeclaration(t) as { parameters?: unknown };
      if (d.parameters) walk(d.parameters, t.name);
    }
    expect(bad).toEqual([]);
  });
});

describe("Gemini adapter — tool steps and thought signatures (Gemini 3+ rules)", () => {
  const response = {
    candidates: [{
      finishReason: "STOP",
      content: { role: "model", parts: [
        { functionCall: { id: "c1", name: "get_public_room_types", args: {} }, thoughtSignature: "SIG-A" },
        { functionCall: { id: "c2", name: "get_booking_sources", args: {} } },
      ] },
    }],
    usageMetadata: { promptTokenCount: 120, candidatesTokenCount: 30, thoughtsTokenCount: 50 },
  };

  it("parses calls with their ids, keeps the raw step, and counts thought tokens as output", () => {
    const r = parseGeminiResponse(response);
    expect(r.toolCalls).toEqual([{ name: "get_public_room_types", args: {}, id: "c1" }, { name: "get_booking_sources", args: {}, id: "c2" }]);
    expect(r.raw).toEqual({ role: "model", parts: response.candidates[0].content.parts });
    expect(r.usage).toEqual({ input: 120, output: 80 });
    expect(r.text).toBeNull();
  });

  it("sends the step back verbatim (signature in its original part) and all results together, in order, with ids", () => {
    const r = parseGeminiResponse(response);
    const history: ChatTurn[] = [
      { role: "user", text: "كم الأسعار؟" },
      { role: "model", toolStep: { calls: r.toolCalls, raw: r.raw } },
      { role: "user", toolResults: [{ name: "get_public_room_types", id: "c1", result: [1] }, { name: "get_booking_sources", id: "c2", result: [2] }] },
    ];
    const contents = new GeminiProvider("k", "gemini-3.8-flash").toContents(history);
    expect(contents).toHaveLength(3);                       // FC1+sig, FC2 | FR1, FR2 — never FC1, FR1, FC2, FR2
    expect(contents[1]).toEqual({ role: "model", parts: response.candidates[0].content.parts });
    expect(contents[2]).toEqual({ role: "user", parts: [
      { functionResponse: { name: "get_public_room_types", id: "c1", response: { result: [1] } } },
      { functionResponse: { name: "get_booking_sources", id: "c2", response: { result: [2] } } },
    ] });
  });

  it("ignores thought-summary parts when collecting the reply text", () => {
    const r = parseGeminiResponse({ candidates: [{ finishReason: "STOP", content: { role: "model", parts: [{ text: "تفكير", thought: true }, { text: "الوصول من 16:00", thoughtSignature: "S" }] } }] });
    expect(r.text).toBe("الوصول من 16:00");
  });
});

describe("Gemini adapter — errors", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("keeps Google's error message for the logs, shortened, with anything key-shaped masked", () => {
    const t = providerErrorText(404, JSON.stringify({ error: { message: "models/gemini-2.5-flash is not found for API version v1beta (key AIzaSyA1234567890abcdefghijklmnopqrstuv)", status: "NOT_FOUND" } }));
    expect(t).toMatch(/^http 404: models\/gemini-2\.5-flash is not found/);
    expect(t).not.toMatch(/AIza/);
    expect(t.length).toBeLessThanOrEqual(260);
  });

  it("maps HTTP status to an error kind and never puts the key in the message", async () => {
    const key = "AIzaSyTESTKEY000000000000000000000000";
    for (const [status, kind] of [[400, "http"], [403, "auth"], [429, "quota"]] as const) {
      vi.stubGlobal("fetch", vi.fn(async () => new Response(JSON.stringify({ error: { message: `bad request for ${key}` } }), { status })));
      const err = await new GeminiProvider(key, "gemini-3.8-flash").generate({ ...base, history: [{ role: "user", text: "x" }] }).catch((e) => e);
      expect(err).toBeInstanceOf(ProviderError);
      expect((err as ProviderError).kind).toBe(kind);
      expect((err as ProviderError).message).not.toContain(key);
    }
  });

  it("sends the key only in the x-goog-api-key header, never in the URL", async () => {
    const fetchMock = vi.fn(async () => new Response(JSON.stringify({ candidates: [{ finishReason: "STOP", content: { role: "model", parts: [{ text: "أهلًا" }] } }] }), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    const r = await new GeminiProvider("SECRET-KEY", "gemini-3.8-flash").generate({ ...base, history: [{ role: "user", text: "مرحبا" }] });
    expect(r.text).toBe("أهلًا");
    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).not.toContain("SECRET-KEY");
    expect((init.headers as Record<string, string>)["x-goog-api-key"]).toBe("SECRET-KEY");
  });
});
