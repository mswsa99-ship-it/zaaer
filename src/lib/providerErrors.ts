/**
 * What a model-provider error means for the owner, in plain Arabic. The input is the text the connection test
 * (ai-health) and the logs carry, written by providerErrorInfo() in supabase/functions/_shared/llm.ts:
 *   "quota: http 429: [free tier quota requests/min=5, retry in 41s] You exceeded your current quota…"
 *   "http: http 503: This model is currently experiencing high demand…"
 * Returns null when the text says nothing recognisable (the raw text is still shown next to it).
 */
export function providerErrorHint(error: string | null | undefined): string | null {
  if (!error) return null;
  const e = error.toLowerCase();
  const tier = isFreeTierError(error) ? " (الخطة المجانية)" : "";
  if (/http 429\b|\bquota\b|resource_exhausted/.test(e)) {
    if (/requests\/day/.test(e)) return `انتهت حصة اليوم من الطلبات لهذا النموذج${tier}`;
    if (/tokens\/day/.test(e)) return `انتهت حصة اليوم من التوكنز لهذا النموذج${tier}`;
    if (/requests\/min/.test(e)) return `تجاوز حد الطلبات في الدقيقة لهذا النموذج${tier}؛ يعود بعد قليل`;
    if (/tokens\/min/.test(e)) return `تجاوز حد التوكنز في الدقيقة لهذا النموذج${tier}؛ يعود بعد قليل`;
    return `تجاوز حصة الطلبات لدى Google${tier}`;
  }
  if (/http 40[13]\b|^auth:|api key (not valid|expired|invalid)|api_key_invalid|permission/.test(e)) return "المفتاح غير صالح أو أُلغي أو بلا صلاحية على هذا النموذج";
  if (/http 404\b/.test(e)) return "النموذج غير متاح لهذا المفتاح (معرّف قديم أو خاطئ)";
  if (/http 503\b|high demand|overloaded/.test(e)) return "ضغط مؤقت لدى Google على هذا النموذج";
  if (/\btimeout\b/.test(e)) return "انتهت المهلة قبل أن يجيب";
  if (/http 5\d\d\b/.test(e)) return "خطأ مؤقت لدى Google";
  return null;
}

/** Google counted the request against its free tier: the key's project has no billing (low per-model limits). */
export function isFreeTierError(error: string | null | undefined): boolean {
  return !!error && /free tier|freetier/i.test(error);
}
