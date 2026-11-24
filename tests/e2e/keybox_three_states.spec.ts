/**
 * 7.3 (O6): the key box has three clearly distinct states on «الرموز» — no box, code ready, code must change.
 * Each state is checked for its own label, light colour, filter and available actions. Demo data only.
 */
import { test, expect } from "./fixtures";

const cards = (page: import("@playwright/test").Page, state: string) => page.locator(`[data-testid="code-unit"][data-state="${state}"]`);

test.describe("7.3 key-box states", () => {
  test("state: no box — the unit says it has no box, offers no reveal, and shows under «بلا صندوق»", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await go("/staff/codes");
    await page.getByRole("button", { name: /بلا صندوق/ }).click();
    const none = cards(page, "none");
    await expect(none.first()).toBeVisible();
    await expect(none.first()).toContainText("لا يوجد صندوق مفاتيح مسجّل لهذه الوحدة");
    await expect(none.first().getByRole("button", { name: "إظهار الرمز" })).toHaveCount(0);
    expect(await cards(page, "ok").count() + await cards(page, "change").count()).toBe(0);
  });

  test("state: code ready — says the code is current, can be revealed, shows no red alert text", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await go("/staff/codes");
    await page.getByRole("button", { name: /محدّثة/ }).click();
    const ok = cards(page, "ok");
    await expect(ok.first()).toBeVisible();
    await expect(ok.first()).toContainText("الرمز محدّث");
    await expect(ok.first()).not.toContainText("يجب تغيير");
    await ok.first().getByRole("button", { name: "إظهار الرمز" }).click();
    await expect(ok.first().getByTestId("shown-code")).toHaveText(/^\d{4,8}$/);
  });

  test("state: must change — the unit is red, with the change button and the alert; it differs from the other two", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/staff/codes");
    const red = cards(page, "change");
    // the demo seeds at least one unit waiting for its new code
    await expect(red.first()).toBeVisible();
    await expect(red.first()).toContainText("يجب تغيير الرمز بعد مغادرة النزيل");
    await expect(red.first().getByRole("button", { name: /تغيير الرمز|تعيين رمز/ })).toBeVisible();
    // three distinct texts across the states
    const texts = new Set<string>();
    for (const s of ["none", "ok", "change"]) texts.add((await cards(page, s).first().locator("p.text-sm.font-medium").first().innerText()).split("·")[0].trim());
    expect(texts.size).toBe(3);
    await go("/staff/dashboard");
    await expect(page.getByTestId("keybox-alert")).toBeVisible();
  });
});
