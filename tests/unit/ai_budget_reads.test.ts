import { describe, expect, it } from "vitest";
import { budgetReadAvailable, sessionCountReadable } from "../../supabase/functions/_shared/budget_reads";

const settings = { daily_request_limit: 2, ops_daily_request_limit: 1, daily_token_budget: 100 };
const unused = { requests: 0, tokens_in: 0, tokens_out: 0 };

describe("plan 5.1 budget reads fail closed", () => {
  it("rejects query failures even if the response also contains stale data", () => {
    for (const data of [null, unused]) {
      expect(budgetReadAvailable(settings, { data, error: { message: "synthetic unavailable" } })).toBe(false);
    }
  });
  it("accepts an absent daily row only when the query succeeded", () => {
    expect(budgetReadAvailable(settings, { data: null, error: null })).toBe(true);
    expect(budgetReadAvailable(settings, { data: unused, error: null })).toBe(true);
  });
  it("rejects incomplete, invalid, negative and unsafe usage counters", () => {
    for (const value of [undefined, null, -1, NaN, Infinity, 0.5, "0", Number.MAX_SAFE_INTEGER + 1]) {
      for (const field of ["requests", "tokens_in", "tokens_out"]) {
        expect(budgetReadAvailable(settings, { data: { ...unused, [field]: value }, error: null }), `${field}: ${value}`).toBe(false);
      }
    }
  });
  it("preserves request and combined input/output token boundaries", () => {
    expect(budgetReadAvailable(settings, { data: { ...unused, requests: 1 }, error: null })).toBe(true);
    expect(budgetReadAvailable(settings, { data: { ...unused, requests: 2 }, error: null })).toBe(false);
    expect(budgetReadAvailable(settings, { data: { ...unused, requests: 2 }, error: null }, true)).toBe(true);
    expect(budgetReadAvailable(settings, { data: { ...unused, requests: 3 }, error: null }, true)).toBe(false);
    expect(budgetReadAvailable(settings, { data: { ...unused, tokens_in: 60, tokens_out: 39 }, error: null })).toBe(true);
    expect(budgetReadAvailable(settings, { data: { ...unused, tokens_in: 60, tokens_out: 40 }, error: null })).toBe(false);
  });
  it("requires an actual successful session count, never substitutes zero", () => {
    expect(sessionCountReadable({ count: 0, error: null })).toBe(true);
    expect(sessionCountReadable({ count: 40, error: null })).toBe(true);
    for (const count of [null, undefined, -1, NaN, Infinity, 0.5, "0"]) {
      expect(sessionCountReadable({ count, error: null })).toBe(false);
    }
    expect(sessionCountReadable({ count: 0, error: { message: "synthetic failure" } })).toBe(false);
  });
});
