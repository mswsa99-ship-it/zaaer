/** Plan 6.9 (U8): «تصدير ▾» one button with a visible arrow and a named menu. */
import { test, expect } from "./fixtures";

test.describe("export menu (6.9)", () => {
  test("reservations list: one «تصدير» button with an arrow opens a named menu of two formats, then the scope", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await go("/staff/reservations");
    const trigger = page.getByRole("button", { name: "تصدير" });
    await expect(trigger).toHaveCount(1);
    await expect(trigger).toHaveAttribute("aria-haspopup", "menu");
    await expect(trigger.locator("svg.lucide-chevron-down")).toBeVisible();
    await expect(trigger).toHaveAttribute("aria-expanded", "false");
    await trigger.click();
    await expect(trigger).toHaveAttribute("aria-expanded", "true");
    const menu = page.getByRole("menu", { name: "تصدير" });
    await expect(menu.getByRole("menuitem")).toHaveText([/ملف Excel/, /طباعة \/ PDF/]);
    if (process.env.K_SHOTS) await page.screenshot({ path: "/tmp/k-export-open.png" });
    await menu.getByRole("menuitem", { name: /ملف Excel/ }).click();
    await expect(page.getByTestId("export-scope-all")).toBeVisible();
    await expect(page.getByTestId("export-scope-page")).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(page.getByTestId("export-scope-menu")).toHaveCount(0);
    await expect(trigger).toHaveAttribute("aria-expanded", "false");
    await page.screenshot({ path: "/tmp/k-export-closed.png" });
  });
});
