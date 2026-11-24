/** Plan 6.5 (U4): fill, reload, restore: the expense form keeps what was typed and offers its restoration. */
import { test, expect } from "./fixtures";

test.describe("draft restore (6.5)", () => {
  test("expense form: fill, reload, reopen, restore", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await go("/staff/expenses");
    await page.getByRole("button", { name: "سند صرف" }).click();
    let dlg = page.getByRole("dialog");
    await dlg.getByLabel("المبلغ").fill("77");
    await dlg.getByLabel("الوصف").fill("مسودة قطع غيار");
    await dlg.getByLabel("المستفيد").fill("مورد الاختبار");
    await page.waitForTimeout(700);
    await page.reload({ waitUntil: "networkidle" });
    await page.getByRole("button", { name: "سند صرف" }).click();
    dlg = page.getByRole("dialog");
    await expect(dlg.getByTestId("expense-draft")).toContainText("مسودة قطع غيار");
    await expect(dlg.getByLabel("الوصف")).toHaveValue("");
    await dlg.getByRole("button", { name: "استعادة المسودة" }).click();
    await expect(dlg.getByLabel("الوصف")).toHaveValue("مسودة قطع غيار");
    await expect(dlg.getByLabel("المستفيد")).toHaveValue("مورد الاختبار");
    await expect(dlg.getByLabel("المبلغ")).toHaveValue("77");
    await expect(dlg.getByTestId("expense-draft")).toHaveCount(0);
  });
});
