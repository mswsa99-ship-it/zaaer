/** Plan 6.15 (U15): save, search and arrivals from the keyboard alone, plus the page that lists them. */
import { test, expect } from "./fixtures";

test.describe("keyboard shortcuts (6.15)", () => {
  test("keyboard only: G T arrives at today's arrivals, / focuses search, ? lists the shortcuts, Ctrl+S saves the open form", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await go("/staff/reservations");
    await page.locator("main").click({ position: { x: 5, y: 5 } });
    await page.keyboard.press("/");
    await expect(page.locator("input:focus")).toHaveCount(1);
    await page.keyboard.type("g t");              // typing in the field must NOT navigate
    await expect(page).toHaveURL(/staff\/reservations$/);
    await page.keyboard.press("Escape"); await page.locator("main").click({ position: { x: 5, y: 5 } });
    await page.keyboard.press("g"); await page.keyboard.press("t");
    await expect(page).toHaveURL(/staff\/arrivals/);
    await page.keyboard.press("?");
    await expect(page).toHaveURL(/staff\/shortcuts/);
    await expect(page.getByTestId("shortcuts-table")).toContainText("Ctrl + S");
    if (process.env.K_SHOTS) await page.screenshot({ path: "/tmp/k-shortcuts.png" });
  });

  test("Ctrl+S saves the open form (category form, owner)", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/staff/expenses");
    await page.getByRole("button", { name: "التصنيفات" }).click();
    const dlg = page.getByRole("dialog");
    await dlg.getByLabel("تصنيف جديد").fill("تصنيف الاختصار");
    await page.keyboard.press("Control+s");
    await expect(dlg.getByTestId("expense-categories").getByText("تصنيف الاختصار")).toHaveCount(1);
  });
});
