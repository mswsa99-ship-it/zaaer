/** 0137 UI facet: the owner's individual-permission draft lists «إعدادات مزوّد الدفع» as a separate sensitive action, unchecked by default. Demo bound: no server enforcement here (SQL payment_settings tests). */
import { test, expect } from "./fixtures";
test("PS-UI1 the draft offers the payment-provider sensitive action, off by default", async ({ page, loginAs }) => {
  await loginAs("owner");
  await page.goto("/#/admin/staff", { waitUntil: "networkidle" });
  await page.getByRole("button", { name: "مسودة صلاحيات فردية" }).first().click();
  await page.getByText(/تفاصيل الإجراءات الحساسة/).click();
  const box = page.getByLabel(/إعدادات مزوّد الدفع/);
  await expect(box).toBeVisible();
  await expect(box).not.toBeChecked();
  await box.scrollIntoViewIfNeeded();
  await box.check();
  await expect(box).toBeChecked();
  await page.locator("details", { has: box }).screenshot({ path: "test-results/ps-ui1-sensitive-section.png" });
});
