import { describe, it, expect, vi, afterEach } from "vitest";
import { GeminiProvider, parseGeminiResponse, isThinkingGemini, toGeminiDeclaration, providerErrorText, providerErrorInfo, cooldownMs, ProviderError, THINKING_ALLOWANCE_TOKENS, FOREIGN_THOUGHT_SIGNATURE, ATTEMPT_SHARE, MIN_ATTEMPT_MS, resetModelCooldowns, createProvider, type ChatTurn } from "../../supabase/functions/_shared/llm";
import { TOOL_DECLARATIONS } from "../../supabase/functions/_shared/tools";
import { OPS_TOOL_DECLARATIONS } from "../../supabase/functions/_shared/ops";

const base = { system: "sys", tools: [], temperature: 0.2, maxOutputTokens: 400, timeoutMs: 5000 };

/** The shape Gemini answers a free-tier key with when a per-model limit runs out (google.rpc details). */
const QUOTA_429 = {
  error: {
    code: 429,
    status: "RESOURCE_EXHAUSTED",
    message: "You exceeded your current quota, please check your plan and billing details. For more information on this error, head to: https://ai.google.dev/gemini-api/docs/rate-limits. To monitor your current usage, head to: https://ai.dev/rate-limit. \n* Quota exceeded for metric: generativelanguage.googleapis.com/generate_content_free_tier_requests, limit: 5, model: gemini-3.6-flash\nPlease retry in 41.2s.",
    details: [
      { "@type": "type.googleapis.com/google.rpc.QuotaFailure", violations: [
        { quotaMetric: "generativelanguage.googleapis.com/generate_content_free_tier_requests", quotaId: "GenerateRequestsPerMinutePerProjectPerModel-FreeTier", quotaDimensions: { location: "global", model: "gemini-3.6-flash" }, quotaValue: "5" },
        { quotaMetric: "generativelanguage.googleapis.com/generate_content_free_tier_requests", quotaId: "GenerateRequestsPerDayPerProjectPerModel-FreeTier", quotaDimensions: { location: "global", model: "gemini-3.6-flash" }, quotaValue: "20" },
      ] },
      { "@type": "type.googleapis.com/google.rpc.Help", links: [{ description: "Learn more about Gemini API quotas", url: "https://ai.google.dev/gemini-api/docs/rate-limits" }] },
      { "@type": "type.googleapis.com/google.rpc.RetryInfo", retryDelay: "41.2s" },
    ],
  },
};

describe("Gemini adapter — request shape per model generation", () => {
  it("Gemini 3+ / 4 / -latest: the least thinking each model accepts (minimal on 3.6-flash and 3.5-flash-lite, else low), output allowance for thought tokens, default temperature", () => {
    for (const [model, level] of [["gemini-3.8-flash", "low"], ["gemini-3.5-flash-lite", "minimal"], ["gemini-3.6-flash", "minimal"], ["gemini-4-argon", "low"], ["gemini-flash-latest", "low"]]) {
      expect(isThinkingGemini(model), model).toBe(true);
      const g = new GeminiProvider("k", model).buildBody({ ...base, history: [{ role: "user", text: "مرحبا" }] }).generationConfig as Record<string, unknown>;
      expect(g.thinkingConfig, model).toEqual({ thinkingLevel: level });
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
  afterEach(() => { vi.unstubAllGlobals(); resetModelCooldowns(); });

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

  it("a quota error (429) names the limit that ran out, the plan, and Google's wait — before the boilerplate", () => {
    const { text, retryAfterMs } = providerErrorInfo(429, JSON.stringify(QUOTA_429));
    expect(text).toMatch(/^http 429: \[free tier quota requests\/min=5 \+ requests\/day=20, retry in 42s\] You exceeded your current quota/);
    expect(retryAfterMs).toBe(41_200);
    expect(text).not.toMatch(/AIza/);
    expect(text.length).toBeLessThanOrEqual(250);
    // a fallback log entry is cut at 160 characters: the limit and the wait must survive the cut
    expect(`gemini-3.6-flash: ${text}`.slice(0, 160)).toMatch(/free tier quota requests\/min=5 .+ retry in 42s\]/);
  });

  it("a paid-tier quota error says which limit without 'free tier'; errors without details keep the old shape", () => {
    const paid = { error: { code: 429, message: "Quota exceeded.", details: [{ "@type": "type.googleapis.com/google.rpc.QuotaFailure", violations: [{ quotaId: "GenerateRequestsPerDayPerProjectPerModel", quotaValue: "10000" }] }] } };
    expect(providerErrorText(429, JSON.stringify(paid))).toBe("http 429: [quota requests/day=10000] Quota exceeded.");
    expect(providerErrorText(503, JSON.stringify({ error: { message: "This model is currently experiencing high demand." } }))).toBe("http 503: This model is currently experiencing high demand.");
    expect(providerErrorText(502, "<html>Bad Gateway</html>")).toBe("http 502: <html>Bad Gateway</html>");
    expect(providerErrorInfo(503, "{}").retryAfterMs).toBeUndefined();
  });

  it("a 429 becomes a 'quota' ProviderError that carries Google's wait", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response(JSON.stringify(QUOTA_429), { status: 429 })));
    const err = await new GeminiProvider("k", "gemini-3.6-flash").generate({ ...base, history: [{ role: "user", text: "x" }] }).catch((e) => e) as ProviderError;
    expect(err).toBeInstanceOf(ProviderError);
    expect(err.kind).toBe("quota");
    expect(err.status).toBe(429);
    expect(err.retryAfterMs).toBe(41_200);
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

describe("Gemini adapter — fallback models (Google's 503 'high demand' lasts hours per model)", () => {
  afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks(); resetModelCooldowns(); });

  const ok = (text: string) => new Response(JSON.stringify({ candidates: [{ finishReason: "STOP", content: { role: "model", parts: [{ text }] } }] }), { status: 200 });
  const fail = (status: number, message = "This model is currently experiencing high demand.") => new Response(JSON.stringify({ error: { message } }), { status });
  const modelOf = (url: string) => decodeURIComponent(/models\/([^:]+):/.exec(url)![1]);
  /** fetch stub answering per model id in the URL; unknown models → 404 */
  const byModel = (answers: Record<string, () => Response>) => vi.fn(async (url: string) => (answers[modelOf(url)] ?? (() => fail(404, "not found")))());
  const called = (f: { mock: { calls: unknown[][] } }) => f.mock.calls.map((c) => modelOf(c[0] as string));
  const step = { ...base, history: [{ role: "user", text: "مرحبا" }] as ChatTurn[] };
  const chain = () => new GeminiProvider("k", "gemini-3.8-flash", ["gemini-3.6-flash", "gemini-3.5-flash-lite"]);

  it("the configured model first; fallbacks de-duplicated, blanks dropped; createProvider passes them through", () => {
    expect(new GeminiProvider("k", "gemini-3.8-flash", ["gemini-3.8-flash", " ", "gemini-3.6-flash"]).models).toEqual(["gemini-3.8-flash", "gemini-3.6-flash"]);
    const env = { get: (k: string) => (k === "GEMINI_API_KEY" ? "k" : undefined) };
    expect((createProvider("gemini", "gemini-3.8-flash", env, ["gemini-3.6-flash"]) as GeminiProvider).models).toEqual(["gemini-3.8-flash", "gemini-3.6-flash"]);
    expect((createProvider("gemini", "gemini-3.8-flash", env) as GeminiProvider).models).toEqual(["gemini-3.8-flash"]);
  });

  it("503 on the configured model → the next one answers; the response says which model, and why the first failed", async () => {
    const f = byModel({ "gemini-3.8-flash": () => fail(503), "gemini-3.6-flash": () => ok("أهلًا") });
    vi.stubGlobal("fetch", f);
    const r = await chain().generate(step);
    expect(r.text).toBe("أهلًا");
    expect(r.model).toBe("gemini-3.6-flash");
    expect(r.fallbackFrom).toEqual([expect.stringMatching(/^gemini-3\.8-flash: http 503: This model is currently experiencing high demand/)]);
    expect(called(f)).toEqual(["gemini-3.8-flash", "gemini-3.6-flash"]);
  });

  it("when the configured model answers nothing else is called and fallbackFrom is empty", async () => {
    const f = byModel({ "gemini-3.8-flash": () => ok("أهلًا") });
    vi.stubGlobal("fetch", f);
    const r = await chain().generate(step);
    expect(r.model).toBe("gemini-3.8-flash");
    expect(r.fallbackFrom).toEqual([]);
    expect(called(f)).toEqual(["gemini-3.8-flash"]);
  });

  it("429 / 404 / 500 / 504 move on to the next model; 400 (the request) and 403 (the key) stop at once", async () => {
    for (const status of [429, 404, 500, 504]) {
      resetModelCooldowns();
      vi.stubGlobal("fetch", byModel({ "gemini-3.8-flash": () => fail(status), "gemini-3.6-flash": () => ok("x") }));
      expect((await chain().generate(step)).model, String(status)).toBe("gemini-3.6-flash");
    }
    for (const [status, kind] of [[400, "http"], [403, "auth"]] as const) {
      resetModelCooldowns();
      const f = byModel({ "gemini-3.8-flash": () => fail(status, "bad"), "gemini-3.6-flash": () => ok("x") });
      vi.stubGlobal("fetch", f);
      const err = await chain().generate(step).catch((e) => e);
      expect(err).toBeInstanceOf(ProviderError);
      expect((err as ProviderError).kind).toBe(kind);
      expect((err as ProviderError).status).toBe(status);
      expect(called(f), String(status)).toEqual(["gemini-3.8-flash"]);
    }
  });

  it("nothing answers → one error naming every model tried, with the last one's kind", async () => {
    vi.stubGlobal("fetch", byModel({ "gemini-3.8-flash": () => fail(503), "gemini-3.6-flash": () => fail(429, "quota"), "gemini-3.5-flash-lite": () => fail(503, "busy") }));
    const err = await chain().generate(step).catch((e) => e) as ProviderError;
    expect(err.kind).toBe("http");
    expect(err.message).toMatch(/^gemini-3\.8-flash: http 503: .+ \| gemini-3\.6-flash: http 429: quota \| gemini-3\.5-flash-lite: http 503: busy$/);
  });

  it("a model that just failed goes last for the next requests on this instance (guests do not each wait for the 503)", async () => {
    const f = byModel({ "gemini-3.8-flash": () => fail(503), "gemini-3.6-flash": () => ok("x") });
    vi.stubGlobal("fetch", f);
    await chain().generate(step);
    const next = await chain().generate(step);                 // a new request, a new provider instance
    expect(next.fallbackFrom).toEqual([]);
    expect(called(f)).toEqual(["gemini-3.8-flash", "gemini-3.6-flash", "gemini-3.6-flash"]);
  });

  it("a model out of quota is moved last for as long as Google asked (5 s – 10 min); without a wait, 60 s", async () => {
    expect(cooldownMs(429, 41_200)).toBe(41_200);
    expect(cooldownMs(429, 200)).toBe(5_000);
    expect(cooldownMs(429, 86_400_000)).toBe(600_000);
    expect(cooldownMs(429)).toBe(60_000);
    expect(cooldownMs(503)).toBe(120_000);
    expect(cooldownMs(404)).toBe(600_000);

    let now = 5_000_000;
    vi.spyOn(Date, "now").mockImplementation(() => now);
    const quota = (retry: string) => new Response(JSON.stringify({ error: { code: 429, message: "quota", details: [{ "@type": "type.googleapis.com/google.rpc.RetryInfo", retryDelay: retry }] } }), { status: 429 });
    const f = byModel({ "gemini-3.8-flash": () => quota("20s"), "gemini-3.6-flash": () => ok("x") });
    vi.stubGlobal("fetch", f);
    await chain().generate(step);                                 // 3.8 → 429 (wait 20 s) → 3.6 answers
    now += 10_000;
    await chain().generate(step);                                 // 10 s later: 3.6 first, 3.8 not tried
    now += 11_000;
    await chain().generate(step);                                 // 21 s later: 3.8 first again
    expect(called(f)).toEqual(["gemini-3.8-flash", "gemini-3.6-flash", "gemini-3.6-flash", "gemini-3.8-flash", "gemini-3.6-flash"]);
  });

  it("another model is tried only while enough of the step's time budget is left", async () => {
    let now = 1_000_000;
    vi.spyOn(Date, "now").mockImplementation(() => now);
    const f = vi.fn(async () => { now += 1000; return fail(503); });   // the 503 arrives after 1 s
    vi.stubGlobal("fetch", f);
    const err = await chain().generate({ ...step, timeoutMs: 2000 }).catch((e) => e) as ProviderError;
    expect(f).toHaveBeenCalledTimes(1);                         // 1 s left < MIN_ATTEMPT_MS
    expect(err.message).toMatch(/^http 503: /);
  });

  it("a model that hangs gets only its share of the time; the next model still answers within the step's budget", async () => {
    vi.useFakeTimers();
    try {
      // fetch that never answers until the adapter aborts it (Google "high demand" can hang this way)
      const hang = (init: RequestInit) => new Promise<Response>((_, reject) => init.signal!.addEventListener("abort", () => reject(Object.assign(new Error("aborted"), { name: "AbortError" }))));
      const seen: Array<{ model: string; at: number }> = [];
      const f = vi.fn(async (url: string, init: RequestInit) => {
        const model = modelOf(url);
        seen.push({ model, at: Date.now() });
        return model === "gemini-3.8-flash" ? fail(429, "quota") : model === "gemini-3.6-flash" ? hang(init) : ok("أهلًا");
      });
      vi.stubGlobal("fetch", f);
      const t0 = Date.now();
      const pending = chain().generate({ ...step, timeoutMs: 12_000 });
      await vi.advanceTimersByTimeAsync(12_000);
      const r = await pending;
      expect(r.model).toBe("gemini-3.5-flash-lite");
      expect(r.fallbackFrom).toEqual([expect.stringMatching(/^gemini-3\.8-flash: http 429/), "gemini-3.6-flash: timeout"]);
      // 3.6 was cut at its share of the 12 s (not the whole budget), so the last model started well before the deadline
      expect(seen.map((x) => x.model)).toEqual(["gemini-3.8-flash", "gemini-3.6-flash", "gemini-3.5-flash-lite"]);
      expect(seen[2].at - t0).toBe(Math.round(12_000 * ATTEMPT_SHARE));
      expect(12_000 - (seen[2].at - t0)).toBeGreaterThanOrEqual(MIN_ATTEMPT_MS);

      // the next request on this instance does not wait for the slow model again: it goes last
      const next = await chain().generate(step);
      expect(next.model).toBe("gemini-3.5-flash-lite");
      expect(next.fallbackFrom).toEqual([]);
    } finally {
      vi.useRealTimers();
    }
  });

  it("the only model left gets all the remaining time", async () => {
    vi.useFakeTimers();
    try {
      const f = vi.fn(async (_url: string, init: RequestInit) => new Promise<Response>((_, reject) => init.signal!.addEventListener("abort", () => reject(Object.assign(new Error("aborted"), { name: "AbortError" })))));
      vi.stubGlobal("fetch", f);
      const t0 = Date.now();
      const pending = new GeminiProvider("k", "gemini-3.6-flash").generate({ ...step, timeoutMs: 5_000 }).catch((e) => e);
      await vi.advanceTimersByTimeAsync(5_000);
      const err = await pending as ProviderError;
      expect(err.kind).toBe("timeout");
      expect(Date.now() - t0).toBe(5_000);
      expect(f).toHaveBeenCalledTimes(1);
    } finally {
      vi.useRealTimers();
    }
  });

  it("a tool loop stays on its model; if it must move, the new model gets the placeholder signature, never the old one's", async () => {
    const bodies: Array<{ model: string; body: { contents: Array<{ parts: Array<Record<string, unknown>> }> } }> = [];
    let first = true;
    vi.stubGlobal("fetch", vi.fn(async (url: string, init: RequestInit) => {
      const model = modelOf(url);
      bodies.push({ model, body: JSON.parse(String(init.body)) });
      if (first) {
        first = false;
        return new Response(JSON.stringify({ candidates: [{ finishReason: "STOP", content: { role: "model", parts: [{ functionCall: { id: "c1", name: "get_public_room_types", args: {} }, thoughtSignature: "SIG-A" }] } }] }), { status: 200 });
      }
      return model === "gemini-3.8-flash" ? fail(503) : ok("الأسعار من 350 ريال");
    }));
    const p = new GeminiProvider("k", "gemini-3.6-flash", ["gemini-3.8-flash"]);
    const history: ChatTurn[] = [{ role: "user", text: "كم الأسعار؟" }];
    // round 1 is answered by gemini-3.6-flash; round 2 starts from it again (the loop stays on its model)
    const r1 = await p.generate({ ...base, history });
    expect(r1.model).toBe("gemini-3.6-flash");
    expect(r1.raw).toMatchObject({ model: "gemini-3.6-flash" });
    history.push({ role: "model", toolStep: { calls: r1.toolCalls, raw: r1.raw } }, { role: "user", toolResults: [{ name: "get_public_room_types", id: "c1", result: [] }] });
    await p.generate({ ...base, history });
    expect(bodies[1].model).toBe("gemini-3.6-flash");
    expect(bodies[1].body.contents[1].parts[0].thoughtSignature).toBe("SIG-A");   // back to its own model: verbatim

    // the same step sent to a different model (the loop's model went down): placeholder, call untouched
    const moved = p.toContents(history, "gemini-3.8-flash");
    expect(moved[1].parts[0]).toEqual({ functionCall: { id: "c1", name: "get_public_room_types", args: {} }, thoughtSignature: FOREIGN_THOUGHT_SIGNATURE });
    expect(p.toContents(history, "gemini-3.6-flash")[1].parts[0]).toMatchObject({ thoughtSignature: "SIG-A" });
  });

  it("the loop's model is preferred over the configured order, and a fallback mid-loop sends the placeholder", async () => {
    const bodies: Array<{ model: string; sig: unknown }> = [];
    vi.stubGlobal("fetch", vi.fn(async (url: string, init: RequestInit) => {
      const model = modelOf(url);
      const body = JSON.parse(String(init.body)) as { contents: Array<{ parts: Array<Record<string, unknown>> }> };
      bodies.push({ model, sig: body.contents[1]?.parts[0]?.thoughtSignature });
      return model === "gemini-3.6-flash" ? fail(503) : ok("تمام");
    }));
    const history: ChatTurn[] = [
      { role: "user", text: "كم الأسعار؟" },
      { role: "model", toolStep: { calls: [{ name: "get_public_room_types", args: {}, id: "c1" }], raw: { role: "model", model: "gemini-3.6-flash", parts: [{ functionCall: { id: "c1", name: "get_public_room_types", args: {} }, thoughtSignature: "SIG-B" }] } } },
      { role: "user", toolResults: [{ name: "get_public_room_types", id: "c1", result: [] }] },
    ];
    const r = await new GeminiProvider("k", "gemini-3.8-flash", ["gemini-3.6-flash"]).generate({ ...base, history });
    expect(r.model).toBe("gemini-3.8-flash");
    expect(bodies).toEqual([{ model: "gemini-3.6-flash", sig: "SIG-B" }, { model: "gemini-3.8-flash", sig: FOREIGN_THOUGHT_SIGNATURE }]);
  });
});
