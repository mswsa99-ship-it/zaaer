/**
 * Plan 3.4 — the staff sees RoomAI in the menus and the browser tab; the guest sees only the hotel, with a quiet
 * «يعمل بـ RoomAI» in the footer. Descriptive names, no test codes: the prefix registration is reported to the
 * integrator with the work package.
 */
import { test, expect } from "./fixtures";

test.describe("اسم RoomAI في شاشات الموظفين", () => {
  test("تبويب الموظف يحمل اسم RoomAI والقائمة تعرض الشعار", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/staff/reservations");
    await expect(page).toHaveTitle(/— RoomAI$/);
    await expect(page.locator("aside img[alt='RoomAI']")).toBeVisible();
  });

  test("بوابة الدخول تعرض شعار RoomAI الكامل", async ({ page, go }) => {
    await go("/staff/login");
    await expect(page.locator("img[alt='RoomAI']")).toBeVisible();
  });

  test("الضيف يرى «يعمل بـ RoomAI» في التذييل فقط", async ({ page, go }) => {
    await go("/");
    const foot = page.getByTestId("guest-powered-by");
    await expect(foot).toBeVisible();
    await expect(foot).toContainText("RoomAI");
    // the hotel's name stays first in the header — no product name there
    await expect(page.locator("header")).not.toContainText("مساعد الاستقبال الذكي");
  });
});
