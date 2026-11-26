/** Day summary and POS settlement accept one day (one tap + OK) or from-to (two taps + OK). The settlement itself stays one day. Invented demo data only. */
import { test, expect } from "./fixtures";

async function pickRange(page: import("@playwright/test").Page, name: RegExp, a: number, b: number | null) {
  await page.getByRole("button", { name }).first().click();
  const days = page.locator("[data-day]:not([disabled])");
  await days.nth(a).click();
  if (b != null) await days.nth(b).click();
  await page.getByRole("button", { name: "موافق" }).click();
}

test.describe("period on day summary and POS settlement", () => {
  test("RNG1 day summary: one day, then two dates, shows the period and keeps the scope", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/staff/day-summary", { waitUntil: "networkidle" });
    await expect(page.getByTestId("date-range-value").first()).toHaveText(/^\d{4}-\d{2}-\d{2}$/);
    await pickRange(page, /اليوم أو الفترة/, 2, 6);
    await expect(page.getByTestId("date-range-value").first()).toContainText(/\d{4}-\d{2}-\d{2}.*\d{4}-\d{2}-\d{2}/);
    await expect(page.getByText(/لا سندات في هذه الفترة|ما قبضه/).first()).toBeVisible();
    await page.screenshot({ path: "/tmp/proof/rng1-day-summary.png" });
  });

  for (const role of ["supervisor", "finance"] as const) {
    test(`RNG2 ${role}: day summary takes a period too (no error banner)`, async ({ page, loginAs }) => {
      await loginAs(role);
      await page.goto("/#/staff/day-summary", { waitUntil: "networkidle" });
      await pickRange(page, /اليوم أو الفترة/, 1, 5);
      await expect(page.getByRole("alert")).toHaveCount(0);
    });
  }

  test("RNG3 POS settlement: a period lists each day read-only; «تسوية هذا اليوم» returns to the one-day settlement form", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/staff/pos-settlement", { waitUntil: "networkidle" });
    await expect(page.getByTestId("pos-range")).toHaveCount(0);
    await pickRange(page, /اليوم أو الفترة/, 2, 5);
    const overview = page.getByTestId("pos-range");
    await expect(overview).toBeVisible();
    await expect(page.getByTestId("pos-range-day").first()).toBeVisible();   // sparse: only days with vouchers or a saved settlement
    await expect(overview.getByText("عرض للقراءة فقط")).toBeVisible();
    await expect(page.getByRole("button", { name: /حفظ|تسوية الشبكة/ }).filter({ hasText: /^حفظ/ })).toHaveCount(0);
    await page.screenshot({ path: "/tmp/proof/rng3-pos-range.png" });
    await page.getByRole("button", { name: "تسوية هذا اليوم" }).first().click();
    await expect(page.getByTestId("pos-range")).toHaveCount(0);
    await expect(page.getByTestId("date-range-value").first()).toHaveText(/^\d{4}-\d{2}-\d{2}$/);
  });
});

test.describe("centre tab strip", () => {
  test("RNG4 phone: the open finance tab is inside the visible strip on entry (owner)", async ({ page, loginAs }) => {
    await page.setViewportSize({ width: 390, height: 800 });
    await loginAs("owner");
    for (const path of ["/staff/day-summary", "/staff/accounts", "/staff/ledger"]) {
      await page.goto(`/#${path}`, { waitUntil: "networkidle" });
      const strip = page.getByTestId("hub-tabs");
      const tab = strip.locator('[aria-current="page"]');
      await expect(tab).toBeVisible();
      const s = await strip.boundingBox(); const t = await tab.boundingBox();
      expect(t!.x).toBeGreaterThanOrEqual(s!.x - 1);
      expect(t!.x + t!.width).toBeLessThanOrEqual(s!.x + s!.width + 1);
    }
    await page.screenshot({ path: "/tmp/proof/rng4-tab-in-view.png" });
  });
});
