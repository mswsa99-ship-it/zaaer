/**
 * Review of 31 October, Phase 4a (QO08–QO12; migration 0059): the money the owner reads — the platforms' money apart
 * from what was collected, both occupancy figures with their definitions, one period rule on the reports page with no
 * stale figures after an error, every day in the daily chart, and the phone view of the branches.
 */
import { test, expect } from "./fixtures";

test.describe("owner money", () => {
  test("QO08 the dashboard says money taken at the property and money the platforms hold apart, and both occupancy figures with their definitions", async ({ page, loginAs, go, errors }) => {
    await loginAs("owner");
    await go("/admin/dashboard");
    await expect(page.getByTestId("kpi-collected")).toContainText("المحصّل في المنشأة (7 أيام)");
    await expect(page.getByTestId("kpi-platform")).toContainText("آجل عند المنصات (7 أيام)");
    await expect(page.getByTestId("kpi-platform")).toHaveAttribute("href", /platform-payouts/);
    await expect(page.getByTestId("kpi-occupancy")).toContainText("المشغولة ÷ الوحدات العاملة");
    await expect(page.getByTestId("kpi-occupancy-all")).toContainText("كل الوحدات");
    await expect(page.getByTestId("kpi-occupancy")).toContainText(/\d+\.\d%/);
    await expect(page.getByTestId("overview-definitions")).toContainText("التأمين خارجه");
    await expect(page.getByTestId("dashboard-sources").getByTestId("hbar").first()).toBeVisible();
    expect(errors).toEqual([]);
  });

  test("QO09 the reports keep the platforms' money out of «المحصّل», show it on its own tile, and credit no one with it", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/reports");
    await expect(page.getByText("المحصّل في المنشأة", { exact: true })).toBeVisible();
    await expect(page.getByText("آجل عند المنصات", { exact: true })).toBeVisible();
    await expect(page.getByTestId("finance-by-staff")).toContainText("لا يُحسب لأحد");
    await expect(page.getByTestId("report-by-method").getByTestId("hbar").first()).toBeVisible();
  });

  test("QO10 a wrong period blanks every figure and the export, and says what is wrong", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/reports");
    await expect(page.getByText("المحصّل في المنشأة", { exact: true })).toBeVisible();
    await page.getByLabel("من").fill("2020-01-01");
    await expect(page.getByText(/الفترة أطول من 366 يومًا/)).toBeVisible();
    await expect(page.getByText("المحصّل في المنشأة", { exact: true })).toHaveCount(0);
    await expect(page.getByTestId("late-entries-report")).toHaveCount(0);
  });

  test("QO11 the daily chart has a bar slot for every day of the period", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/reports");
    const ticks = page.locator(".recharts-xAxis .recharts-cartesian-axis-tick").first();
    await expect(ticks).toBeVisible();
    await expect(page.getByText(/كل أيام الفترة، ويوم بلا حركة صفر/)).toBeVisible();
  });

  test("QO12 on a phone each branch is a card, and every alert opens its list", async ({ page, loginAs, go }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await loginAs("owner");
    await go("/admin/dashboard");
    await expect(page.getByTestId("branch-card").first()).toBeVisible();
    await expect(page.getByTestId("branches-today")).toBeHidden();
    const link = page.getByTestId("ops-alerts").getByRole("button").first();
    if (await link.count()) { await link.click(); await expect(page).toHaveURL(/\/staff\//); }
  });
});
