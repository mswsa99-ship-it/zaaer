import { describe, it, expect } from "vitest";
import { providerErrorHint, isFreeTierError } from "../../src/lib/providerErrors";
import { providerErrorText } from "../../supabase/functions/_shared/llm";

// The owner reads these on /admin/ai-settings ("اختبار الاتصال") and /admin/integrations. The input is what ai-health
// returns: "<kind>: <providerErrorText>".
describe("provider errors in plain Arabic for the owner", () => {
  it("reads the text the edge adapter writes for a free-tier per-minute limit (one contract, both sides)", () => {
    const body = { error: { code: 429, message: "You exceeded your current quota, please check your plan and billing details.", details: [
      { "@type": "type.googleapis.com/google.rpc.QuotaFailure", violations: [{ quotaId: "GenerateRequestsPerMinutePerProjectPerModel-FreeTier", quotaValue: "5" }] },
      { "@type": "type.googleapis.com/google.rpc.RetryInfo", retryDelay: "41s" },
    ] } };
    const shown = `quota: ${providerErrorText(429, JSON.stringify(body))}`;
    expect(providerErrorHint(shown)).toBe("تجاوز حد الطلبات في الدقيقة لهذا النموذج (الخطة المجانية)؛ يعود بعد قليل");
    expect(isFreeTierError(shown)).toBe(true);
  });

  it("a day's quota, and a paid-tier limit (no free-tier note)", () => {
    expect(providerErrorHint("quota: http 429: [free tier quota requests/day=20] You exceeded your current quota")).toBe("انتهت حصة اليوم من الطلبات لهذا النموذج (الخطة المجانية)");
    const paid = "quota: http 429: [quota requests/day=10000] Quota exceeded.";
    expect(providerErrorHint(paid)).toBe("انتهت حصة اليوم من الطلبات لهذا النموذج");
    expect(isFreeTierError(paid)).toBe(false);
    expect(providerErrorHint("quota: http 429: You exceeded your current quota")).toBe("تجاوز حصة الطلبات لدى Google");
  });

  it("capacity, retired model, bad key, timeout", () => {
    expect(providerErrorHint("http: http 503: This model is currently experiencing high demand.")).toBe("ضغط مؤقت لدى Google على هذا النموذج");
    expect(providerErrorHint("http: http 404: models/gemini-2.0-flash is not found for API version v1beta")).toBe("النموذج غير متاح لهذا المفتاح (معرّف قديم أو خاطئ)");
    // Google answers a wrong or deleted key with 400, not 401/403
    expect(providerErrorHint("http: http 400: API key not valid. Please pass a valid API key.")).toBe("المفتاح غير صالح أو أُلغي أو بلا صلاحية على هذا النموذج");
    expect(providerErrorHint("http: http 400: API key expired. Please renew the API key.")).toBe("المفتاح غير صالح أو أُلغي أو بلا صلاحية على هذا النموذج");
    expect(providerErrorHint("auth: http 403: Permission denied")).toBe("المفتاح غير صالح أو أُلغي أو بلا صلاحية على هذا النموذج");
    expect(providerErrorHint("timeout")).toBe("انتهت المهلة قبل أن يجيب");
  });

  it("nothing recognisable → no hint (the raw text is shown on its own)", () => {
    expect(providerErrorHint(undefined)).toBeNull();
    expect(providerErrorHint("")).toBeNull();
    expect(providerErrorHint("unknown")).toBeNull();
    expect(isFreeTierError(undefined)).toBe(false);
  });
});
