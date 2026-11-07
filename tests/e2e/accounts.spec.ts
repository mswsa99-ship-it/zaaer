/**
 * The double entry through the staff UI (A5, migration 0065) — the UI facet of tests/sql/accounting_a5_tests.sql and the
 * demo test GL01–GL05: the trial balance with no difference, the deposit under the liabilities, an account's statement
 * from the chart, and the owner's month lock (with a reason) that the management cannot reach.
 */
import { test, expect } from "./fixtures";

test.describe("accounts", () => {
  test("GL20 the owner reads a trial balance with no difference, the balance sheet balanced, and an account's statement from the chart", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/staff/accounts");
    await page.getByLabel("كل فروعي").check();
    await expect(page.getByTestId("trial-difference")).toContainText("0.00");
    await page.getByRole("tab", { name: "الميزانية" }).click();
    await expect(page.getByTestId("balance-difference")).toContainText("0.00");
    await page.getByRole("tab", { name: "قائمة الدخل" }).click();
    await expect(page.getByTestId("income-net")).toBeVisible();
    await page.getByRole("tab", { name: "دليل الحسابات" }).click();
    const chart = page.getByTestId("gl-chart");
    await expect(chart).toContainText("تأمينات الضيوف");
    await expect(chart).toContainText("الالتزامات");
    await chart.getByTestId("gl-account").filter({ hasText: "إيراد الإيجار" }).click();
    await expect(page.getByRole("dialog")).toContainText("كشف حساب 41");
  });

  test("GL21 the owner locks the month with a reason and opens it again", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/staff/accounts");
    await page.getByRole("tab", { name: "قفل الشهر" }).click();
    await expect(page.getByTestId("month-state")).toContainText("مفتوح");
    await page.getByRole("button", { name: "قفل الشهر" }).click();
    const dlg = page.getByRole("dialog");
    await dlg.locator("textarea").fill("إقفال بعد المراجعة");
    await dlg.getByRole("button", { name: "قفل", exact: true }).click();
    await expect(dlg).toBeHidden();
    await expect(page.getByTestId("month-state")).toContainText("مقفل");
    await page.getByRole("button", { name: "فتح الشهر" }).click();
    const d2 = page.getByRole("dialog");
    await d2.locator("textarea").fill("تصحيح سند");
    await d2.getByRole("button", { name: "فتح", exact: true }).click();
    await expect(page.getByTestId("month-state")).toContainText("مفتوح");
  });

  test("GL22 the manager reads the books but has no month lock", async ({ page, loginAs, go }) => {
    await loginAs("manager");
    await go("/staff/accounts");
    await expect(page.getByRole("tab", { name: "ميزان المراجعة" })).toBeVisible();
    await expect(page.getByRole("tab", { name: "قفل الشهر" })).toHaveCount(0);
  });
});
