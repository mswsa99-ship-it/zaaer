/** 195px (400% zoom): the staff pages whose tab strips, filters and detail grid used to push the page wider than the screen, and a date range that no longer splits inside a date. Demo data only. */
import { test, expect } from "./fixtures";

for (const [name, path] of [["housekeeping", "/staff/housekeeping"], ["rooms", "/staff/rooms"], ["reservations list", "/staff/reservations"]] as const) {
  test(`SW1 195px ${name}: the page is not wider than the screen`, async ({ page, loginAs, go }) => {
    await page.setViewportSize({ width: 195, height: 700 });
    await loginAs("supervisor"); await go(path);
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(195);
  });
}

test("SW2 195px reservation detail is not wider than the screen", async ({ page, loginAs, go }) => {
  await page.setViewportSize({ width: 195, height: 700 });
  await loginAs("supervisor"); await go("/staff/reservations");
  await page.locator("a.font-mono").first().click();
  await page.getByText("النزلاء ومطابقة الهوية").first().waitFor();
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(195);
});

test("SW3 390px: a chosen period breaks only at the arrow, never inside a date", async ({ page, loginAs, go }) => {
  await page.setViewportSize({ width: 390, height: 800 });
  await loginAs("supervisor"); await go("/staff/reservations");
  await page.getByTestId("toggle-advanced").click();
  const picker = page.getByTestId("date-range-picker").first();
  await picker.getByRole("button").first().click();
  const dlg = page.getByRole("dialog").first();
  const days = dlg.locator("[data-day]:not([disabled])");
  await days.nth(2).click(); await days.nth(9).click();
  await dlg.getByRole("button", { name: "موافق" }).click();
  const parts = picker.locator('[data-testid="date-range-value"] span.whitespace-nowrap');
  expect(await parts.count()).toBe(2);
  for (let i = 0; i < 2; i++) expect((await parts.nth(i).boundingBox())!.height).toBeLessThan(26);
});

test("SW4 195px reservation detail: each money figure in the summary stays on one line", async ({ page, loginAs, go }) => {
  await page.setViewportSize({ width: 195, height: 700 });
  await loginAs("supervisor"); await go("/staff/reservations");
  await page.locator("a.font-mono").first().click();
  await page.getByText("النزلاء ومطابقة الهوية").first().waitFor();
  const amounts = page.locator("p.whitespace-nowrap", { hasText: "ر.س" });
  expect(await amounts.count()).toBeGreaterThanOrEqual(3);
  const hs = await amounts.evaluateAll((els) => els.map((e) => e.getBoundingClientRect().height / parseFloat(getComputedStyle(e).lineHeight)));
  for (const h of hs) expect(h).toBeLessThan(1.6);
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(195);
});

for (const role of ["owner", "manager"] as const) for (const [name, path] of [["housekeeping", "/staff/housekeeping"], ["rooms", "/staff/rooms"], ["reservations list", "/staff/reservations"], ["tickets", "/staff/tickets"], ["new booking", "/staff/reservations/new"]] as const) {
  test(`SW5 195px ${role} (branch picker shown) ${name}: the page is not wider than the screen`, async ({ page, loginAs, go }) => {
    await page.setViewportSize({ width: 195, height: 700 });
    await loginAs(role); await go(path);
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(195);
  });
}
