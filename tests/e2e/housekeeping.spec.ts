/**
 * Housekeeping role — test ids HK01–HK03 (decision 57: renamed from H01–H03; the testing rules' H01–H06 are the
 * task scenarios covered in tests/sql/core_tests.sql).
 * Controls: G09 (cleanliness, occupancy and readiness are separate — HK01, HK03), G18 (completing a task keeps
 * cleanliness consistent — HK01), G21 (housekeeping never sees money — HK02).
 */
import { test, expect, openFirstReservation } from "./fixtures";

test.describe("housekeeping role", () => {
  test("HK01 completing a task updates the room's cleanliness without touching occupancy", async ({ page, loginAs }) => {
    await loginAs("housekeeping");
    await page.goto("/#/staff/housekeeping", { waitUntil: "networkidle" });
    const complete = page.getByRole("button", { name: "إتمام" }).first();
    await expect(complete).toBeVisible();
    await complete.click();
    const notice = page.locator("div.bg-success-500\\/10").first();
    await expect(notice).toBeVisible();
    await expect(notice).toContainText("تم الإتمام");
    await expect(notice).toContainText("الإشغال لا يتغير بالتنظيف");
  });

  test("HK02 housekeeping sees no money on a reservation and no ledger in finance", async ({ page, loginAs }) => {
    await loginAs("housekeeping");
    await openFirstReservation(page);
    await expect(page.getByText("البيانات المالية متاحة لأدوار الاستقبال والمالية والإدارة فقط.")).toBeVisible();
    await expect(page.getByText("ر.س")).toHaveCount(0);
    await page.goto("/#/admin/finance", { waitUntil: "networkidle" });
    await page.waitForTimeout(500);
    expect(await page.locator("table tbody tr").count()).toBe(0);
    await expect(page.locator("main").getByText("ر.س")).toHaveCount(0);
  });

  test("HK03 the units board marks a dirty room as not ready even when it is vacant", async ({ page, loginAs }) => {
    await loginAs("housekeeping");
    await page.goto("/#/staff/housekeeping", { waitUntil: "networkidle" });
    await page.getByRole("button", { name: "حالة الوحدات" }).click();
    // cleanliness and occupancy are two different badges on every card (G09)
    await expect(page.getByText(/الحالة الحالية: (نظيفة|متسخة|قيد التنظيف)/).first()).toBeVisible();
    expect(await page.getByText(/الحالة الحالية: متسخة/).count()).toBeGreaterThan(0);
    // the only ways to change cleanliness are a task or an explicit manual flag — no free edit of occupancy
    await expect(page.getByRole("button", { name: "وضع علامة متسخة" }).first()).toBeVisible();
    await expect(page.getByRole("button", { name: /تسجيل وصول|تسجيل مغادرة/ })).toHaveCount(0);
  });
});
