/** Finance period views (independent review fixtures, invented demo data only; only the browser's demo store is edited).
 *  FP1 POS settlement «جميع الفروع» + a period lists each branch's saved settlement inside [from, to], both ends included, nothing outside.
 *  FP2 day summary keeps two same-name employees as two cards, and the cards add up to the same total. */
import { test, expect } from "./fixtures";
import type { Page } from "@playwright/test";

const RIYADH = "00000000-0000-0000-0000-000000000010", RIYADH_BANK = "00000000-0000-0000-0000-000000000701";
const JEDDAH = "00000000-0000-0000-0000-000000000012", JEDDAH_BANK = "00000000-0000-0000-0000-000000000703";
const KEY = "zaaer_demo_store_v9";

async function pick(page: Page, from: string, to: string | null) {
  await page.getByRole("button", { name: /اليوم أو الفترة/ }).first().click();
  await page.locator(`[data-day="${from}"]:not([disabled])`).click();
  if (to) await page.locator(`[data-day="${to}"]:not([disabled])`).click();
  await page.getByRole("button", { name: "موافق" }).click();
}
const sarNum = (t: string) => Number((t.match(/-?[\d,]+\.\d{2}/)?.[0] ?? "NaN").replace(/,/g, ""));

for (const width of [390, 1280]) {
  test.describe(`finance period fixtures @${width}`, () => {
    test.use({ viewport: { width, height: 844 } });

    test(`FP1 POS all branches + period: rows inside the period, ends included, nothing outside @${width}`, async ({ page, loginAs }) => {
      await loginAs("owner");
      await page.goto("/#/staff/pos-settlement", { waitUntil: "networkidle" });
      await page.evaluate(({ KEY, RIYADH, RIYADH_BANK, JEDDAH, JEDDAH_BANK }) => {
        const s = JSON.parse(localStorage.getItem(KEY)!);
        const mk = (id: string, b: string, a: string, d: string, st: string, diff: number) => ({ id, branch_id: b, account_id: a, business_date: d, terminal_total_halalas: 10000, system_total_halalas: 10000 - diff, difference_halalas: diff, voucher_count: 2, status: st, note: null, version: 1, updated_at: new Date().toISOString() });
        s.pos_settlements = [mk("fp-1", RIYADH, RIYADH_BANK, "2026-11-20", "matched", 0), mk("fp-2", JEDDAH, JEDDAH_BANK, "2026-11-24", "difference", 500)];
        localStorage.setItem(KEY, JSON.stringify(s));
      }, { KEY, RIYADH, RIYADH_BANK, JEDDAH, JEDDAH_BANK });
      await page.reload({ waitUntil: "networkidle" });
      await page.locator('select[aria-label="الفرع النشط"]').first().selectOption({ label: "جميع الفروع" });
      const card = page.getByTestId("pos-all-branches");

      await pick(page, "2026-11-01", "2026-11-26");
      await expect(card.getByRole("heading", { name: "تسويات الفترة المختارة في جميع الفروع" })).toBeVisible();
      await expect(card.locator("bdi", { hasText: "2026-11-20" })).toBeVisible();
      await expect(card.locator("bdi", { hasText: "2026-11-24" })).toBeVisible();
      await expect(card).toContainText("فرع جدة");
      await expect(card).toContainText("فرع الرياض");

      await pick(page, "2026-11-20", "2026-11-24");     // both end days are inside
      await expect(card.locator("bdi", { hasText: "2026-11-20" })).toBeVisible();
      await expect(card.locator("bdi", { hasText: "2026-11-24" })).toBeVisible();

      await pick(page, "2026-11-21", "2026-11-23");     // neither end day is inside
      await expect(card.getByText("لا تسويات محفوظة في هذه الفترة.")).toBeVisible();
      await expect(card.locator("bdi", { hasText: "2026-11-20" })).toHaveCount(0);
      await expect(card.locator("bdi", { hasText: "2026-11-24" })).toHaveCount(0);

      await pick(page, "2026-11-24", null);             // one day: the single-day heading, only that day's row
      await expect(card.getByRole("heading", { name: "تسويات اليوم المختار في جميع الفروع" })).toBeVisible();
      await expect(card).toContainText("فرع جدة");
      await expect(card).not.toContainText("فرع الرياض");
      expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width);
    });

    test(`FP2 day summary: two same-name employees stay two cards and add up @${width}`, async ({ page, loginAs }) => {
      await loginAs("owner");
      await page.goto("/#/staff/day-summary", { waitUntil: "networkidle" });
      await page.evaluate((KEY) => {
        const s = JSON.parse(localStorage.getItem(KEY)!);
        const a = s.staff_profiles.find((x: any) => x.id.endsWith("0002")), b = s.staff_profiles.find((x: any) => x.id.endsWith("0003"));
        b.full_name = a.full_name;
        const v = s.financial_vouchers.find((x: any) => x.created_by === a.id && x.status === "approved" && x.method === "cash" && x.kind === "deposit");
        v.created_by = b.id;
        localStorage.setItem(KEY, JSON.stringify(s));
      }, KEY);
      await page.reload({ waitUntil: "networkidle" });
      await page.locator('select[aria-label="الفرع النشط"]').first().selectOption({ label: "جميع الفروع" });
      await pick(page, "2026-11-01", "2026-11-26");
      const cards = page.getByTestId("day-summary").locator("h2");
      await expect(cards.filter({ hasText: "فهد الاستقبال" })).toHaveCount(2);
      const cash = await page.getByTestId("day-summary-cash").allInnerTexts();
      // the moved voucher is a 50.00 cash deposit: one card holds exactly that
      expect(cash.map(sarNum)).toContain(50);
      expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width);
    });
  });
}

/** FP3 one employee with vouchers in two branches is ONE card in «جميع الفروع» and the cash adds up (seed: staff 0002 has vouchers in both).
 *  FP4 a supervisor / finance user who belongs to BOTH branches (membership added in the demo store) gets a branch selector with the two
 *  branches but never «جميع الفروع», and the POS all-branches card never appears. All-branches stays owner-only. */
test.describe("finance scope fixtures", () => {
  test.use({ viewport: { width: 390, height: 844 } });
  const SEL = 'select[aria-label="الفرع النشط"]';

  test("FP3 same employee across branches merges into one card (cash adds up)", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/staff/day-summary", { waitUntil: "networkidle" });
    const cashOf = async (value: string) => {
      await page.locator(SEL).first().selectOption({ value });
      await pick(page, "2026-11-01", "2026-11-26");
      const cards = await page.getByTestId("day-summary").locator("h2").allInnerTexts();
      const cash = (await page.getByTestId("day-summary-cash").allInnerTexts()).map(sarNum);
      return { cards, cash };
    };
    const r = await cashOf(RIYADH), j = await cashOf(JEDDAH), all = await cashOf("__all__");
    const idx = (x: { cards: string[] }) => x.cards.findIndex((c) => c.includes("فهد الاستقبال"));
    expect(idx(r)).toBeGreaterThanOrEqual(0);
    expect(idx(j)).toBeGreaterThanOrEqual(0);           // the same person has vouchers in both branches
    expect(all.cards.filter((c) => c.includes("فهد الاستقبال")).length).toBe(1);
    expect(all.cash[idx(all)]).toBeCloseTo(r.cash[idx(r)] + j.cash[idx(j)], 2);
  });

  for (const role of ["supervisor", "finance"] as const) {
    test(`FP4 ${role} in two branches: selector lists both, no «جميع الفروع», no POS all-branches card`, async ({ page, loginAs }) => {
      await loginAs(role);
      await page.goto("/#/staff/pos-settlement", { waitUntil: "networkidle" });
      await page.evaluate(({ KEY, JEDDAH }) => {
        const s = JSON.parse(localStorage.getItem(KEY)!);
        const id = (suffix: string) => s.staff_profiles.find((x: any) => String(x.id).endsWith(suffix)).id;
        for (const suffix of ["0002", "0004"]) s.branch_memberships.push({ id: "fp4-" + suffix, staff_id: id(suffix), branch_id: JEDDAH, created_at: "2026-01-30T07:00:00.000Z", removed_at: null, removed_by: null });
        localStorage.setItem(KEY, JSON.stringify(s));
      }, { KEY, JEDDAH });
      await page.reload({ waitUntil: "networkidle" });
      for (const route of ["pos-settlement", "day-summary"]) {
        await page.goto(`/#/staff/${route}`, { waitUntil: "networkidle" });
        const opts = await page.locator(SEL).first().locator("option").allInnerTexts();
        expect(opts.length).toBe(2);
        expect(opts.join("|")).not.toContain("جميع الفروع");
        await expect(page.getByTestId("pos-all-branches")).toHaveCount(0);
      }
    });
  }
});
