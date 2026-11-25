import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import { formatMoneyInput, moneyTextToHalalas, sanitizeMoneyText } from "../../src/lib/money";

// Plan 7.5. Drive the actual demo RPCs, not copies of split/tax implementations.
// This is NOT evidence that the PostgreSQL implementations passed these properties.
const SEED = 0x75c0ffee;
const CASES = 10_000;
function random(seed: number) {
  let state = seed >>> 0;
  return (limit: number) => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state % limit;
  };
}
// Independent exact oracle: quotient + remainder, including signed half ties.
function rounded(n: bigint, d: bigint): number {
  const sign = n < 0n ? -1 : 1;
  const magnitude = n < 0n ? -n : n;
  const quotient = magnitude / d;
  const remainder = magnitude % d;
  const result = Number(quotient + (remainder * 2n >= d ? 1n : 0n));
  return result === 0 ? 0 : sign * result;
}
function conserved(parts: number[], total: number) {
  expect(parts.every(Number.isSafeInteger)).toBe(true);
  expect(parts.reduce((a, b) => a + b, 0)).toBe(total);
}
const storage = () => {
  const values = new Map<string, string>();
  return { getItem: (key: string) => values.get(key) ?? null, setItem: (key: string, value: string) => { values.set(key, value); }, removeItem: (key: string) => { values.delete(key); } };
};
type Client = ReturnType<typeof import("../../src/demo/client")["createDemoClient"]>;
type Row = Record<string, any>;
let client: Client;
let branch: Row;
let category: Row;
const reservation = "money-property-reservation";
const days = ["2035-01-01", "2035-01-02", "2035-01-03", "2035-01-04", "2035-01-05"];
async function rpc(name: string, args: Row): Promise<any> {
  const result = await client.rpc(name, args);
  if (result.error) throw new Error(result.error.message);
  return result.data;
}
async function checked(query: PromiseLike<any>): Promise<any> {
  const result = await query;
  if (result.error) throw new Error(result.error.message);
  return result.data;
}
function dateAfter(n: number) { return new Date(Date.UTC(2035, 0, 1 + n)).toISOString().slice(0, 10); }

beforeAll(async () => {
  vi.stubGlobal("window", globalThis);
  vi.stubGlobal("localStorage", storage());
  vi.stubGlobal("sessionStorage", storage());
  const demo = await import("../../src/demo/client");
  demo.resetDemo();
  client = demo.createDemoClient();
  const auth = await client.auth.signInWithPassword({ email: "owner@demo.sa", password: "demo" });
  expect(auth.error).toBeNull();
  branch = (await checked(client.from("branches").select("*").limit(1)))[0];
  category = (await checked(client.from("room_categories").select("*").eq("branch_id", branch.id).limit(1)))[0];
  await checked(client.from("reservations").insert({ id: reservation, organization_id: branch.organization_id, branch_id: branch.id, check_in: days[0], check_out: days[4], status: "confirmed" }));
});
afterAll(() => { vi.unstubAllGlobals(); });

describe("seeded money properties through real demo paths", () => {
  it("conserves weekly/monthly splits and exact line tax/rounding in 10,000 reproducible quotes", async () => {
    const next = random(SEED);
    const edges = [0, 1, 2, 3, 7, 99, 100, 101, 999_999_999];
    const rates = [0, 1, 500, 1500, 10000];
    let count = 0;
    for (let i = 0; i < CASES; i++) {
      const price = i < edges.length ? edges[i] : next(1_000_000_000);
      const n = i % 2 ? 30 + next(61) : 7 + next(23);
      const denominator = n >= 30 ? 30 : 7;
      const rate = rates[i % rates.length];
      const inclusive = i % 4 < 2;
      const gross = rounded(BigInt(price) * BigInt(n), BigInt(denominator));
      const discount = i % 7 === 0 ? gross : next(gross + 1);
      await checked(client.from("room_categories").update({ base_price_halalas: 0, weekly_price_halalas: price, monthly_price_halalas: price, min_nightly_halalas: null }).eq("id", category.id));
      await checked(client.from("branches").update({ tax_rate_bp: rate, prices_include_tax: inclusive }).eq("id", branch.id));
      const q = await rpc("fn_quote_stay", { p: { branch_id: branch.id, category_id: category.id, check_in: days[0], check_out: dateAfter(n), discount_halalas: discount } });
      try {
        expect(q.nights).toBe(n);
        expect(q.rent_gross).toBe(gross);
        expect(q.runs.reduce((a: number, run: Row) => a + run.nights, 0)).toBe(n);
        conserved(q.runs.flatMap((run: Row) => Array(run.nights).fill(run.price)), gross);
        expect(q.runs.every((run: Row) => Number.isSafeInteger(run.price) && run.price >= 0)).toBe(true);
        if (price > 0) expect(q.basis).toBe(n >= 30 ? "monthly" : "weekly");
        // Tax is rounded per actual charge run, not once on the whole stay.
        const lineAmounts: number[] = q.runs.map((run: Row) => run.nights * run.price);
        if (discount > 0) lineAmounts.push(-discount);
        let expectedNet = 0, expectedTax = 0;
        for (const amount of lineAmounts) {
          const net = inclusive ? rounded(BigInt(amount) * 10000n, BigInt(10000 + rate)) : amount;
          const tax = inclusive ? amount - net : rounded(BigInt(amount) * BigInt(rate), 10000n);
          expectedNet += net; expectedTax += tax;
        }
        expect(q.rent + q.discount).toBe(expectedNet);
        expect(q.tax).toBe(expectedTax);
        conserved([q.rent, q.discount, q.tax], q.total);
        expect(q.total).toBe(inclusive ? gross - discount : gross - discount + expectedTax);
      } catch (error) { throw new Error(`seed=${SEED} quote case=${i} price=${price} nights=${n} rate=${rate} inclusive=${inclusive} discount=${discount}`, { cause: error }); }
      count++;
    }
    expect(count).toBe(CASES);
    console.info(`money quote properties seed=${SEED} cases=${count}`);
  }, 120_000);

  it("conserves positive, zero, signed and linked-tax shares over weighted and unweighted periods in 10,000 cases", async () => {
    const next = random(SEED ^ 0x51a7);
    const edges = [0, 1, 2, 3, 5, 99, 100, 101, 999_999_999];
    let count = 0;
    for (let i = 0; i < CASES; i++) {
      const total = i < edges.length ? edges[i] : next(1_000_000_000);
      const weights = i % 5 === 0 ? [0, 0, 0, 0] : [next(100_000), next(100_000), next(100_000), 1 + next(100_000)];
      const weighted = i % 2 === 0;
      const signed = total === 0 ? 0 : weighted && i % 3 === 0 ? -total : total;
      const tax = rounded(BigInt(signed) * BigInt([0, 1, 500, 1500, 10000][i % 5]), 10000n);
      await checked(client.from("reservation_nights").delete().eq("reservation_id", reservation));
      await checked(client.from("reservation_charges").delete().eq("reservation_id", reservation));
      await checked(client.from("reservation_nights").insert(weights.map((price, k) => ({ reservation_id: reservation, branch_id: branch.id, night: days[k], status: "active", price_halalas: price }))));
      const base = { reservation_id: reservation, branch_id: branch.id, organization_id: branch.organization_id, quantity: 1, unit_price_halalas: signed, description: "اختبار خصائص المبالغ", service_from: days[0], service_to: days[4], invoice_id: null };
      await checked(client.from("reservation_charges").insert([
        { ...base, id: "property-base", kind: weighted ? "adjustment" : "rent", total_halalas: signed },
        { ...base, id: "property-tax", kind: "tax", base_charge_id: "property-base", total_halalas: tax },
      ]));
      const actual = [0, 0];
      const cumulative = [0, 0];
      const allWeight = weights.reduce((a, b) => a + b, 0);
      try {
        for (let k = 0; k < 4; k++) {
          const preview = await rpc("fn_invoice_preview", { p: { reservation_id: reservation, from: days[k], to: days[k + 1] } });
          const weight = weighted && allWeight > 0 ? weights.slice(0, k + 1).reduce((a, b) => a + b, 0) : k + 1;
          const denominator = weighted && allWeight > 0 ? allWeight : 4;
          for (const [index, id, value] of [[0, "property-base", signed], [1, "property-tax", tax]] as const) {
            const part = preview.lines.find((line: Row) => line.charge_id === id)?.amount_halalas ?? 0;
            const endpoint = rounded(BigInt(value) * BigInt(weight), BigInt(denominator));
            expect(part).toBe(endpoint - cumulative[index]);
            expect(Number.isSafeInteger(part)).toBe(true);
            cumulative[index] = endpoint; actual[index] += part;
          }
          conserved([preview.subtotal_halalas, preview.tax_halalas], preview.total_halalas);
        }
        expect(actual).toEqual([signed, tax]);
        // Preview of the whole remaining stay must match the sum of all periods.
        const full = await rpc("fn_invoice_preview", { p: { reservation_id: reservation } });
        expect(full.total_halalas).toBe(signed + tax);
      } catch (error) { throw new Error(`seed=${SEED ^ 0x51a7} share case=${i} total=${signed} tax=${tax} weights=${weights} weighted=${weighted}`, { cause: error }); }
      count++;
    }
    expect(count).toBe(CASES);
    console.info(`money invoice properties seed=${SEED ^ 0x51a7} cases=${count}`);
  }, 120_000);

  it("preserves a halala in text and rejects invalid precision/sign input, including zero's empty representation", () => {
    const next = random(SEED);
    for (let i = 0; i < CASES; i++) {
      const value = i === 0 ? 0 : next(1_000_000_000);
      const text = formatMoneyInput(value);
      expect(moneyTextToHalalas(text)).toBe(value === 0 ? null : value);
      expect(sanitizeMoneyText(`${value}.001`, false)).toBeNull();
      expect(sanitizeMoneyText(`-${value}`, false)).toBeNull();
    }
    console.info(`money input supplementary properties seed=${SEED} cases=${CASES}`);
  });

  it("negative controls detect a lost halala and balanced-but-wrong tax; real quote RPC rejects invalid amounts/periods", async () => {
    expect(() => conserved([33, 33, 33], 100)).toThrow();
    expect(() => conserved([34, 34, 33], 100)).toThrow();
    // Conservation alone would accept this incorrect tax split, the exact oracle does not.
    conserved([86, 14], 100);
    expect(() => expect(86).toBe(rounded(100n * 10000n, 11500n))).toThrow();
    const p = { branch_id: branch.id, category_id: category.id, check_in: days[0], check_out: days[4], nightly_rate_halalas: 100 };
    await expect(rpc("fn_quote_stay", { p: { ...p, nightly_rate_halalas: -1 } })).rejects.toThrow("VALIDATION: amount");
    await expect(rpc("fn_quote_stay", { p: { ...p, discount_halalas: -1 } })).rejects.toThrow("VALIDATION: amount");
    await expect(rpc("fn_quote_stay", { p: { ...p, discount_halalas: 401 } })).rejects.toThrow("VALIDATION: discount_exceeds_rent");
    await expect(rpc("fn_quote_stay", { p: { ...p, check_out: days[0] } })).rejects.toThrow("VALIDATION: dates");
    await expect(rpc("fn_quote_stay", { p: { ...p, check_out: dateAfter(367) } })).rejects.toThrow("VALIDATION: dates");
    console.info("negative controls: lost/extra halala and incorrect tax detected; five invalid quote inputs rejected");
  });
});
