/**
 * Plan 6.7 (U7): a save button is disabled from the press until the reply and shows its state.
 * Expense categories: two submits fired in the same tick must make ONE category and no false error.
 */
import { test, expect } from "./fixtures";

test.describe("save button guard (6.7)", () => {
  test("two submits in the same tick of the category form create one category, no false duplicate error", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/staff/expenses");
    await page.getByRole("button", { name: "التصنيفات" }).click();
    const dlg = page.getByRole("dialog");
    await dlg.getByLabel("تصنيف جديد").fill("تصنيف اختبار الحفظ");
    await dlg.getByLabel("تصنيف جديد").evaluate((el) => {
      const f = (el as HTMLInputElement).form!; f.requestSubmit(); f.requestSubmit();
    });
    await expect(dlg.getByTestId("expense-categories").getByText("تصنيف اختبار الحفظ")).toHaveCount(1);
    await expect(dlg.getByRole("alert")).toHaveCount(0);
  });

  test("the add button is disabled while the request is in flight and shows its state", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/staff/expenses");
    await page.getByRole("button", { name: "التصنيفات" }).click();
    const dlg = page.getByRole("dialog");
    await dlg.getByLabel("تصنيف جديد").fill("تصنيف حالة الزر");
    const add = dlg.getByRole("button", { name: "إضافة" });
    await add.click();
    // after the reply the field is empty and the button is usable again
    await expect(dlg.getByText("تصنيف حالة الزر")).toHaveCount(1);
    await expect(add).toBeEnabled();
  });
});

const PNG = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==", "base64");

test.describe("save button guard on the shared form wrapper (6.7)", () => {
  test("two submits in the same tick of the expense form record one expense", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await go("/staff/expenses");
    await page.getByRole("button", { name: "سند صرف" }).click();
    const dlg = page.getByRole("dialog");
    await dlg.getByLabel("التصنيف").selectOption({ label: "صيانة وإصلاح" });
    await dlg.getByLabel("المبلغ").fill("45");
    await dlg.getByLabel("الوصف").fill("سند ضغطتين متتاليتين");
    await dlg.getByLabel("المرفق").setInputFiles({ name: "فاتورة.png", mimeType: "image/png", buffer: PNG });
    await expect(dlg.getByTestId("expense-files")).toContainText("فاتورة.png");
    await dlg.getByRole("button", { name: "حفظ السند" }).evaluate((b) => { const f = (b as HTMLButtonElement).form!; f.requestSubmit(); f.requestSubmit(); });
    await expect(dlg).toBeHidden();
    await expect(page.getByTestId("expense-row").filter({ hasText: "سند ضغطتين متتاليتين" })).toHaveCount(1);
  });
});
