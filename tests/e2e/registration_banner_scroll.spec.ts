/** The guest form scrolls to its error once per refused save, never while typing or ticking a box (xcombo). Demo build only. */
import { test, expect } from "./fixtures";
test("RB1 error banner: one scroll per refused save; typing and the checkbox do not scroll", async ({ page, go }) => {
  await page.setViewportSize({ width: 390, height: 780 });
  await go("/booking/lookup");
  await page.getByPlaceholder("05xxxxxxxx").fill("0501110006");
  await page.getByRole("button", { name: "متابعة" }).click();
  await page.getByPlaceholder("رقم الحجز").fill("R-26A0006");
  await page.getByRole("button", { name: "عرض حجوزاتي" }).click();
  await expect(page).toHaveURL(/\/booking\/status\//);
  const token = page.url().split("/booking/status/")[1];
  await page.evaluate((t) => { location.hash = `#/booking/registration/${t}`; }, token);
  await page.getByRole("button", { name: /استكمال البيانات|إضافة نزيل/ }).first().click();
  const dlg = page.getByRole("dialog");
  await expect(dlg).toBeVisible();
  await page.evaluate(() => { const w = window as unknown as { __sc: number }; w.__sc = 0; const o = Element.prototype.scrollIntoView; Element.prototype.scrollIntoView = function (...a) { w.__sc++; return o.apply(this, a as []); }; });
  const count = () => page.evaluate(() => (window as unknown as { __sc: number }).__sc);
  const save = dlg.getByRole("button", { name: "حفظ البيانات" });
  await save.click();
  const alert = dlg.getByText("رقم الوثيقة مطلوب.");
  await expect(alert).toBeVisible();
  await expect.poll(count).toBe(1);
  await dlg.getByPlaceholder("05XXXXXXXX").pressSequentially("05123", { delay: 30 });
  await dlg.getByRole("checkbox").first().check();
  await page.waitForTimeout(600);
  expect(await count()).toBe(1);                 // typing and the checkbox did not scroll again
  await save.click();
  await expect.poll(count).toBe(2);              // a second refusal with the same text scrolls once more
  // the banner is above the sticky save bar
  // the smooth scroll settles after the call: poll the same bound until it holds (no fixed sleep)
  await expect.poll(async () => { const a = await alert.boundingBox(), bar = await save.boundingBox(); return !!a && !!bar && a.y + a.height <= bar.y; }).toBe(true);
  await page.screenshot({ path: "/tmp/proof/rb1-390.png" });
});
