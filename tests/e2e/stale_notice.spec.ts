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

test("SN2 the start-of-shift arrival rows say each stay's real next step, not «سجّل الوصول» on all of them", async ({ page, loginAs, go }) => {
  await loginAs("supervisor");
  await go("/staff/dashboard");
  const rows = page.getByTestId("shift-rows").locator("li");
  await expect(rows.first()).toBeVisible();
  const labels = (await rows.locator("a[data-testid^='shift-action-']").allInnerTexts()).map((t) => t.trim());
  expect(labels.length).toBeGreaterThan(1);
  expect(new Set(labels).size, `labels: ${labels.join(" | ")}`).toBeGreaterThan(1);
  expect(labels.some((l) => /هوية|وحدة/.test(l))).toBe(true);
});

test("SN3 the arrival notice goes away when another part of the page changes the stay (a deposit saved after the arrival)", async ({ page, loginAs, go }) => {
  await loginAs("supervisor");
  await openByRoom(page, go, "203", "confirmed");
  const arrival = page.getByTestId("arrival");
  const dep = arrival.locator("fieldset").filter({ hasText: "سند قبض التأمين" });
  await dep.locator("input[data-money]").fill("50");
  await dep.getByLabel(/استلمت المبلغ/).check();
  await arrival.getByRole("button", { name: "تسجيل الوصول" }).click();
  const notice = page.getByTestId("stay-notice");
  await expect(notice).toContainText("سُجِّل الوصول");
  await page.waitForTimeout(2000);   // the clerk's own reload has settled; what follows is a different action
  await expect(notice).toContainText("سُجِّل الوصول");   // and the notice survived its own refresh
  await page.getByRole("button", { name: "قبض تأمين" }).click();
  const dlg = page.getByRole("dialog");
  await dlg.locator("input[data-money]").first().fill("10");
  await dlg.getByRole("button", { name: "حفظ السند" }).click();
  await expect(dlg).toHaveCount(0);
  await expect(notice).toHaveCount(0);
});

test("SN4 after a room switch the arrival notice about the old unit's key box is gone (no timing window involved)", async ({ page, loginAs, go }) => {
  await loginAs("owner");
  await openByRoom(page, go, "203", "confirmed");
  const arrival = page.getByTestId("arrival");
  const dep = arrival.locator("fieldset").filter({ hasText: "سند قبض التأمين" });
  await dep.locator("input[data-money]").fill("50");
  await dep.getByLabel(/استلمت المبلغ/).check();
  await arrival.getByRole("button", { name: "تسجيل الوصول" }).click();
  const notice = page.getByTestId("stay-notice");
  await expect(notice).toContainText("سُجِّل الوصول");
  await page.waitForTimeout(6000);                       // long after its own refresh: the own notice must still be there
  await expect(notice).toContainText("سُجِّل الوصول");
  await page.getByRole("button", { name: "الإقامة", exact: true }).click();
  await page.getByRole("button", { name: "تبديل الوحدة" }).click();
  const dlg = page.getByRole("dialog");
  const select = dlg.locator("select");
  await expect.poll(async () => await select.locator("option").count()).toBeGreaterThan(1);
  await select.selectOption({ index: 1 });
  await dlg.locator("textarea, input[type=text], input:not([type=date])").last().fill("اختبار تبديل الوحدة بسبب الاختبار");
  await dlg.getByRole("button", { name: /تبديل|حفظ|تأكيد/ }).last().click();
  await expect(dlg).toHaveCount(0);
  await expect(notice).toHaveCount(0);
});
