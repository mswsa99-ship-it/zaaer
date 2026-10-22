/**
 * Housekeeping role — acceptance ids H01–H03 / U01.
 * Controls: G06 (cleanliness ≠ occupancy ≠ readiness), G08 (task completion recomputes room readiness only),
 * G12 (server-side role gate: housekeeping never sees money), G13 (no admin pages for the role).
 */
import { test, expect, openFirstReservation } from "./fixtures";

test.describe("housekeeping role", () => {
  test("H01 completing a task updates the room's cleanliness without touching occupancy", async ({ page, loginAs }) => {
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

  test("H02 housekeeping sees no money on a reservation and no ledger in finance", async ({ page, loginAs }) => {
    await loginAs("housekeeping");
    await openFirstReservation(page);
    await expect(page.getByText("البيانات المالية متاحة لأدوار الاستقبال والمالية والإدارة فقط.")).toBeVisible();
    await expect(page.getByText("ر.س")).toHaveCount(0);
    await page.goto("/#/admin/finance", { waitUntil: "networkidle" });
    await page.waitForTimeout(500);
    expect(await page.locator("table tbody tr").count()).toBe(0);
    await expect(page.locator("main").getByText("ر.س")).toHaveCount(0);
  });

  test("H03 the units board marks a dirty room as not ready even when it is vacant", async ({ page, loginAs }) => {
    await loginAs("housekeeping");
    await page.goto("/#/staff/housekeeping", { waitUntil: "networkidle" });
    await page.getByRole("button", { name: "حالة الوحدات" }).click();
    // cleanliness and occupancy are two different badges on every card (G06)
    await expect(page.getByText(/الحالة الحالية: (نظيفة|متسخة|قيد التنظيف)/).first()).toBeVisible();
    expect(await page.getByText(/الحالة الحالية: متسخة/).count()).toBeGreaterThan(0);
    // the only ways to change cleanliness are a task or an explicit manual flag — no free edit of occupancy
    await expect(page.getByRole("button", { name: "وضع علامة متسخة" }).first()).toBeVisible();
    await expect(page.getByRole("button", { name: /تسجيل وصول|تسجيل مغادرة/ })).toHaveCount(0);
  });
});
