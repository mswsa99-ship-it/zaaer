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
