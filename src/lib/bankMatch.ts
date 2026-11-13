/**
 * Matching a bank movement with the records that explain it (A8, migration 0067): the arithmetic the form shows before
 * the server decides. A record counts for its signed amount in the movement's direction; the card-terminal vouchers are
 * also offered a day at a time, because a terminal deposit usually covers one day's card payments less its card refunds.
 */
import type { BankCandidate } from "./api";

export interface PosDay { day: string; keys: string[]; count: number; total_halalas: number }

export const candidateKey = (c: { type: string; id: string }) => c.type + ":" + c.id;

/** the card-terminal vouchers among the candidates, a day at a time, the latest day first */
export function posDays(records: BankCandidate[]): PosDay[] {
  const days = new Map<string, PosDay>();
  for (const r of records) {
    if (r.type !== "voucher" || r.method !== "pos") continue;
    const d = days.get(r.day) ?? { day: r.day, keys: [], count: 0, total_halalas: 0 };
    d.keys.push(candidateKey(r)); d.count += 1; d.total_halalas += r.signed_halalas;
    days.set(r.day, d);
  }
  return [...days.values()].sort((a, b) => (a.day < b.day ? 1 : -1));
}

/** the total of the ticked records, in the movement's direction */
export function selectedTotal(records: BankCandidate[], picked: ReadonlySet<string>): number {
  return records.reduce((sum, r) => (picked.has(candidateKey(r)) ? sum + r.signed_halalas : sum), 0);
}

/**
 * What is ticked when the form opens. Only records whose way of paying fits the movement are suggested: a terminal
 * deposit is the card vouchers (the day whose card vouchers add up to it, else one card voucher of its amount); any other
 * movement is a record that is not a card one, of exactly its amount (the nearest in time, as the server orders them).
 * When two such records tie (the same amount, the same time), nothing is ticked — the owner chooses.
 */
export function suggestTargets(records: BankCandidate[], amount: number, kind: string): string[] {
  const pos = kind === "pos_settlement";
  const fits = records.filter((r) => (r.type === "voucher" && r.method === "pos") === pos);
  if (pos) {
    const days = posDays(fits).filter((d) => d.total_halalas === amount);
    if (days.length === 1) return days[0].keys;
    if (days.length > 1) return [];
  }
  const same = fits.filter((r) => r.signed_halalas === amount);
  if (same.length === 0) return [];
  if (same.length > 1 && same[1].at === same[0].at) return [];
  return [candidateKey(same[0])];
}
