/**
 * GUEST-10 (owner decision, 31 Oct review) — QL08–QL09: a foreign guest completes «حجوزاتي», the booking status and
 * the registration in English, and the choice can be switched back to Arabic at any time.
 */
import { test, expect } from "./fixtures";

test.describe("guest pages in English", () => {
  test("QL08 «English» turns the lookup, the booking status and the registration into English, left to right; «العربية» turns them back", async ({ page, go, errors }) => {
    await go("/booking/lookup");
    await page.getByTestId("guest-lang").click();
    await expect(page.getByRole("heading", { name: "My bookings" })).toBeVisible();
    await expect(page.locator("div[dir='ltr'][lang='en']").first()).toBeVisible();
    await page.getByPlaceholder("05xxxxxxxx").fill("0501110006");
    await page.getByRole("button", { name: "Continue" }).click();
    await page.getByPlaceholder(/Booking number/).fill("bk-4471029");
    await page.getByRole("button", { name: "Show my bookings" }).click();
    await expect(page).toHaveURL(/\/booking\/status\//);
    await expect(page.getByTestId("guest-greeting")).toHaveText(/Welcome|pleasant stay|Thank you|arrival date/);
    await expect(page.getByText("Your booking", { exact: true })).toBeVisible();
    await expect(page.getByText(/[؀-ۿ]/).filter({ hasText: /^(قبل وصولك|حجزك|الوحدة)$/ })).toHaveCount(0);
    const complete = page.getByRole("link", { name: "Complete details" });
    if (await complete.count()) {
      await complete.click();
      await expect(page.getByRole("heading", { name: "Guests' details" })).toBeVisible();
      await expect(page.getByText("Children under 15", { exact: true })).toBeVisible();
    }
    await page.getByTestId("guest-lang").click();
    await expect(page.getByTestId("guest-lang")).toHaveText(/English/);
    await expect(page.locator("div[dir='rtl'][lang='ar']").first()).toBeVisible();
    expect(errors).toEqual([]);
  });

  test("QL09 a link with ?lang=en opens in English; the other guest pages stay Arabic and show no language button", async ({ page, go }) => {
    await go("/booking/lookup?lang=en");
    await expect(page.getByRole("heading", { name: "My bookings" })).toBeVisible();
    await go("/");
    await expect(page.getByTestId("guest-lang")).toHaveCount(0);
    await expect(page.locator("div[dir='rtl'][lang='ar']").first()).toBeVisible();
  });
});
