/** 0142: company VAT number and national address modal on an open company reservation (invented demo data only). */
import { test, expect, fillGuest } from "./fixtures";

test("the owner saves a company VAT number and address; wrong values are refused in the modal; values reopen", async ({ page, loginAs }) => {
  await loginAs("owner");
  // a company reservation made the normal way, through the booking wizard
  await page.goto("/#/staff/reservations/new", { waitUntil: "networkidle" });
  const roomSel = page.locator("select").filter({ has: page.locator("option:has-text('تخصيص لاحقًا')") });
  await expect.poll(() => roomSel.locator("option").count()).toBeGreaterThan(1);
  await roomSel.selectOption({ index: 1 });
  await page.getByRole("button", { name: "التالي" }).click();
  await fillGuest(page, "ضيف شركة اختبار", "0501110088");
  await page.getByRole("button", { name: "التالي" }).click();
  const typeSel = page.locator("select").filter({ has: page.locator("option:has-text('شركة')") }).first();
  await typeSel.selectOption("company");
  await page.locator("div:has(> label:has-text('اسم الشركة')) input").first().fill("شركة اختبار");
  await page.getByRole("button", { name: "إنشاء الحجز" }).click();
  await page.waitForURL(/#\/staff\/reservations\/[0-9a-f-]+/, { timeout: 15_000 });
  await page.getByRole("button", { name: "الإقامة", exact: true }).click();
  await page.getByTestId("company-tax-open").click();
  const form = page.getByTestId("company-tax-form");
  await expect(form).toBeVisible();
  await page.getByTestId("company-vat").fill("12345");
  await page.getByRole("button", { name: "حفظ", exact: true }).click();
  await expect(page.getByRole("dialog")).toBeVisible();                       // refused: still open
  await page.getByTestId("company-vat").fill("300000000000003");
  const inputs = form.locator("input");
  await inputs.nth(1).fill("شارع الملك فهد"); await inputs.nth(2).fill("12"); await inputs.nth(3).fill("12345"); await inputs.nth(4).fill("الرياض"); await inputs.nth(5).fill("العليا");
  await page.getByRole("button", { name: "حفظ", exact: true }).click();
  await expect(page.getByRole("dialog")).toBeVisible();                       // building number has 2 digits: refused
  await inputs.nth(2).fill("1234");
  await page.screenshot({ path: "/tmp/proof/company-tax-modal.png" });
  await page.getByRole("button", { name: "حفظ", exact: true }).click();
  await expect(page.getByRole("dialog")).toBeHidden();
  await page.getByTestId("company-tax-open").click();
  await expect(page.getByTestId("company-vat")).toHaveValue("300000000000003");
  await expect(form.locator("input").nth(4)).toHaveValue("الرياض");
});
