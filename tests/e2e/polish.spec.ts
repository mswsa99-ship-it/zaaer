/**
 * Review of 31 October, Phase 5 adopted by recommendation (QP10–QP15): each page names its tab, a skip link reaches the
 * content, a new reservation's draft survives a reload, the offline line appears, the drawer keeps focus inside it and
 * returns it, and counts read as Arabic.
 */
import { test, expect } from "./fixtures";

test.describe("polish", () => {
  test("QP10 each page names the browser tab after its own title", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/staff/reservations");
    await expect(page).toHaveTitle(/^الحجوزات — /);
    await go("/admin/staff");
    await expect(page).toHaveTitle(/^الموظفون — /);
  });

  test("QP11 «تخطَّ إلى المحتوى» is the first stop and moves focus to the page's content", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/staff/reservations");
    await page.reload();   // a fresh page: Tab starts from the top
    await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
    await page.keyboard.press("Tab");
    const skip = page.getByRole("link", { name: "تخطَّ إلى المحتوى" });
    await expect(skip).toBeFocused();
    await page.keyboard.press("Enter");
    await expect(page.locator("#main")).toBeFocused();
  });

  test("QP12 a new reservation's typed details come back after a reload", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await go("/staff/reservations/new");
    await page.locator("div:has(> label:has-text('الاسم (مطلوب)')) input").first().fill("سالم عبدالله القحطاني");
    await page.waitForTimeout(700);
    page.on("dialog", (d) => void d.accept());
    await page.reload();
    await expect(page.getByTestId("reservation-draft")).toContainText("سالم عبدالله القحطاني");
    await page.getByRole("button", { name: "استعادة المسودة" }).click();
    await expect(page.locator("div:has(> label:has-text('الاسم (مطلوب)')) input").first()).toHaveValue("سالم عبدالله القحطاني");
  });

  test("QP13 offline, a line says that nothing is saved until the connection returns", async ({ page, context, loginAs, go }) => {
    await loginAs("owner");
    await go("/staff/rooms");
    await context.setOffline(true);
    await expect(page.getByTestId("offline-banner")).toBeVisible();
    await context.setOffline(false);
    await expect(page.getByTestId("offline-banner")).toHaveCount(0);
  });

  test("QP14 on a phone the «المزيد» drawer takes focus, keeps Tab inside, and Escape gives focus back", async ({ page, loginAs, go }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await loginAs("supervisor");
    await go("/staff/rooms");
    const more = page.getByTestId("bottom-tabs-more");
    await more.click();
    const drawer = page.getByTestId("staff-menu-drawer");
    await expect(drawer.locator(":focus")).toHaveCount(1);
    for (let i = 0; i < 30; i++) await page.keyboard.press("Tab");
    await expect(drawer.locator(":focus")).toHaveCount(1);
    await page.keyboard.press("Escape");
    await expect(drawer).toHaveCount(0);
    await expect(more).toBeFocused();
  });

  test("QP15 counts read as Arabic: the staff list and the branches", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/branches");
    await expect(page.getByText(/^فرعان — /)).toBeVisible();
    await go("/admin/staff");
    await expect(page.getByText(/^\d+ موظفين · النشطون \d+$|^موظفان · النشطون \d+$/)).toBeVisible();
  });
});
