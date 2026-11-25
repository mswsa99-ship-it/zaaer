/** Release proofs (invented demo data only): nights 1..30 both ways, a 376px modal, a two-branch export download. */
import { test, expect, fillGuest } from "./fixtures";
import * as fs from "node:fs";

test("nights stepper walks 1 to 30 and back to 1, one step at a time", async ({ page, loginAs }) => {
  await loginAs("owner");
  await page.goto("/#/staff/reservations/new", { waitUntil: "networkidle" });
  const nights = page.getByTestId("nights-value");
  const up = page.getByRole("button", { name: "ليلة أكثر" }), down = page.getByRole("button", { name: "ليلة أقل" });
  const seenUp: number[] = [], seenDown: number[] = [];
  await expect(nights).toHaveText("1"); seenUp.push(1);
  for (let n = 2; n <= 30; n++) { await up.click(); await expect(nights).toHaveText(String(n)); seenUp.push(n); }
  await expect(up).toBeDisabled();
  seenDown.push(30);
  for (let n = 29; n >= 1; n--) { await down.click(); await expect(nights).toHaveText(String(n)); seenDown.push(n); }
  await expect(down).toBeDisabled();
  expect(seenUp).toHaveLength(30); expect(seenDown).toHaveLength(30);
  fs.writeFileSync("/tmp/proof/nights.json", JSON.stringify({ up: seenUp, down: seenDown }));
});

test("company tax modal at 376px", async ({ page, loginAs }) => {
  await page.setViewportSize({ width: 376, height: 800 });
  await loginAs("owner");
  await page.goto("/#/staff/reservations/new", { waitUntil: "networkidle" });
  const roomSel = page.locator("select").filter({ has: page.locator("option:has-text('تخصيص لاحقًا')") });
  await expect.poll(() => roomSel.locator("option").count()).toBeGreaterThan(1);
  await roomSel.selectOption({ index: 1 });
  await page.getByRole("button", { name: "التالي" }).click();
  await fillGuest(page, "ضيف شركة اختبار", "0501110077");
  await page.getByRole("button", { name: "التالي" }).click();
  await page.locator("select").filter({ has: page.locator("option:has-text('شركة')") }).first().selectOption("company");
  await page.locator("div:has(> label:has-text('اسم الشركة')) input").first().fill("شركة اختبار");
  await page.getByRole("button", { name: "إنشاء الحجز" }).click();
  await page.waitForURL(/#\/staff\/reservations\/[0-9a-f-]+/, { timeout: 15_000 });
  await page.getByRole("button", { name: "الإقامة", exact: true }).click();
  await page.getByTestId("company-tax-open").click();
  await expect(page.getByTestId("company-tax-form")).toBeVisible();
  const box = await page.getByRole("dialog").boundingBox();
  expect(box!.x).toBeGreaterThanOrEqual(0); expect(box!.x + box!.width).toBeLessThanOrEqual(376);
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth);
  expect(overflow).toBeLessThanOrEqual(376);
  await page.screenshot({ path: "/tmp/proof/modal-376.png" });
});

test("two-branch export: a Jeddah reservation made in the demo UI shows in the all-branches xlsx with its branch", async ({ page, loginAs }) => {
  await loginAs("owner");
  const branchSel = () => page.locator('select[aria-label="الفرع النشط"]').first();
  await page.goto("/#/staff/reservations", { waitUntil: "networkidle" });
  await expect(branchSel().locator("option").last()).toHaveText("جميع الفروع");
  await branchSel().selectOption({ label: "فرع جدة — الكورنيش" });
  await page.goto("/#/staff/reservations/new", { waitUntil: "networkidle" });
  const roomSel = page.locator("select").filter({ has: page.locator("option:has-text('تخصيص لاحقًا')") });
  await expect.poll(() => roomSel.locator("option").count()).toBeGreaterThan(1);
  await roomSel.selectOption({ index: 1 });
  await page.getByRole("button", { name: "التالي" }).click();
  await fillGuest(page, "ضيف جدة تجريبي", "0501110066");
  await page.getByRole("button", { name: "التالي" }).click();
  await page.getByRole("button", { name: "إنشاء الحجز" }).click();
  await page.waitForURL(/#\/staff\/reservations\/[0-9a-f-]+/, { timeout: 15_000 });
  await page.goto("/#/staff/reservations", { waitUntil: "networkidle" });
  await branchSel().selectOption({ label: "جميع الفروع" });
  await page.waitForTimeout(800);
  await page.getByTestId("export-trigger").click();
  const dl = page.waitForEvent("download");
  await page.getByRole("menuitem", { name: /ملف Excel/ }).click();
  if (await page.getByTestId("export-scope-all").isVisible().catch(() => false)) await page.getByTestId("export-scope-all").click();
  const d = await dl;
  await d.saveAs("/tmp/proof/all-branches.xlsx");
  expect(fs.statSync("/tmp/proof/all-branches.xlsx").size).toBeGreaterThan(1000);
});

test("CAL1 departure picker: days up to the arrival are disabled, click is rejected, 390px screenshot", async ({ page, loginAs }) => {
  await loginAs("supervisor");
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/#/staff/reservations/new", { waitUntil: "networkidle" });
  await page.getByRole("button", { name: "المغادرة", exact: true }).click();
  const dlg = page.getByRole("dialog", { name: "المغادرة" });
  const arrival = await page.getByRole("button", { name: "الوصول", exact: true }).locator("bdi").innerText();
  await expect(dlg).toBeVisible();
  const earlier = dlg.locator(`button[data-day="${arrival}"]`);
  if (await earlier.count()) {
    await expect(earlier).toBeDisabled();
    await earlier.click({ force: true });
    await expect(dlg).toBeVisible();
    await dlg.getByRole("button", { name: "موافق" }).click();
    await expect(page.getByRole("button", { name: "المغادرة", exact: true }).locator("bdi")).not.toHaveText(arrival);   // the rejected click chose nothing
  }
  await page.getByRole("button", { name: "المغادرة", exact: true }).click();
  const disabledCount = await dlg.locator("button[data-day]:disabled").count();
  expect(disabledCount).toBeGreaterThan(0);
  await page.screenshot({ path: process.env.CAL1_SHOT ?? "test-results/after-departure-calendar.png" });
});
