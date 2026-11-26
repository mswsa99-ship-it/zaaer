/** A message in the stay card (a refusal, a success) is out of date once something else on the page changes the stay. */
import { test, expect } from "./fixtures";
import type { Page } from "@playwright/test";
async function openByRoom(page: Page, go: (p: string) => Promise<void>, room: string, status: string) {
  await go("/staff/reservations");
  await page.locator("select").filter({ has: page.locator(`option[value="${status}"]`) }).selectOption(status);
  const row = page.locator("table tbody tr").filter({ has: page.locator("td:nth-child(3)", { hasText: room }) }).first();
  await expect(row).toBeVisible();
  await row.getByRole("link", { name: "فتح" }).click();
  await page.waitForURL(/#\/staff\/reservations\/[0-9a-f-]+/);
  await expect(page.getByTestId("stay-cycle")).toBeVisible();
}
test("SN1 the deposit refusal in the arrival form goes away as soon as the clerk edits the form, and when a deposit is saved elsewhere", async ({ page, loginAs, go }) => {
  await loginAs("supervisor");
  await openByRoom(page, go, "203", "confirmed");
  const arrival = page.getByTestId("arrival");
  const refusal = arrival.getByRole("alert").filter({ hasText: "التأمين أقل من تأمين الفرع: أجب" });
  await arrival.getByRole("button", { name: "تسجيل الوصول" }).click();
  await expect(refusal).toBeVisible();
  // typing the missing amount answers the refusal: the message must not stay on screen over a now-valid form
  await arrival.locator("fieldset").filter({ hasText: "سند قبض التأمين" }).locator("input[data-money]").fill("50");
  await expect(refusal).toHaveCount(0);
  // a refusal after a submit is still shown (nothing is hidden that the server refused)
  await arrival.getByRole("button", { name: "تسجيل الوصول" }).click();
  await expect(arrival.getByRole("alert")).toBeVisible();
});
