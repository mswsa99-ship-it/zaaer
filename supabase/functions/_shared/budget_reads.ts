import { aiBudgetAvailable } from "./reception_scope.ts";

type Settings = Parameters<typeof aiBudgetAvailable>[0];
const counter = (value: unknown): value is number => typeof value === "number" && Number.isSafeInteger(value) && value >= 0;

/** A missing day is unused budget; a failed or malformed read is not. */
export function budgetReadAvailable(settings: Settings, result: { data: unknown; error: unknown }, ops = false): boolean {
  if (result.error) return false;
  if (result.data === null) return aiBudgetAvailable(settings, null, ops);
  if (!result.data || typeof result.data !== "object") return false;
  const usage = result.data as Record<string, unknown>;
  if (!counter(usage.requests) || !counter(usage.tokens_in) || !counter(usage.tokens_out)) return false;
  return aiBudgetAvailable(settings, { requests: usage.requests, tokens_in: usage.tokens_in, tokens_out: usage.tokens_out }, ops);
}

/** head/count responses have no rows: require the actual count, not a zero fallback. */
export function sessionCountReadable(result: { count: unknown; error: unknown }): result is { count: number; error: null } {
  return !result.error && counter(result.count);
}
