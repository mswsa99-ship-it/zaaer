/**
 * The expenses and the ledger through the staff UI (A4, migration 0064) — the UI facet of tests/sql/accounting_a4_tests.sql
 * and the demo test EX03–EX07: an expense needs its receipt, it appears with its file, the ledger shows it with the
 * running balance, and the management cancels it with a reason.
 */
import { test, expect } from "./fixtures";

const PNG = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==", "base64");

test.describe("expenses and ledger", () => {
  test("EX10 the supervisor writes an expense from the cash box with its receipt; without a file it is refused", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await go("/staff/expenses");
    await page.getByRole("button", { name: "سند صرف" }).click();
    const dlg = page.getByRole("dialog");
    await dlg.getByLabel("التصنيف").selectOption({ label: "صيانة وإصلاح" });
    await dlg.getByLabel("المبلغ").fill("45");
    await dlg.getByLabel("الوصف").fill("قطع غيار للمكيف");
    await dlg.getByRole("button", { name: "حفظ السند" }).click();
    await expect(dlg.getByText("أرفق صورة الفاتورة أو الإيصال (صورة أو PDF).")).toBeVisible();
    await dlg.getByLabel("المرفق").setInputFiles({ name: "فاتورة.png", mimeType: "image/png", buffer: PNG });
    await expect(dlg.getByTestId("expense-files")).toContainText("فاتورة.png");
    await dlg.getByRole("button", { name: "حفظ السند" }).click();
    await expect(dlg).toBeHidden();
    const row = page.getByTestId("expense-row").filter({ hasText: "قطع غيار للمكيف" });
    await expect(row).toContainText("EXP-");
    await expect(row).toContainText("45.00");
    await expect(row.getByRole("button", { name: "فاتورة.png" })).toBeVisible();
    // the supervisor does not cancel
    await expect(row.getByRole("button", { name: "إلغاء" })).toHaveCount(0);
  });

  test("EX11 the owner sees the expense in the ledger with the running balance, sets the opening, and cancels the expense with a reason", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/staff/expenses");
    await page.getByRole("button", { name: "سند صرف" }).click();
    const dlg = page.getByRole("dialog");
    await dlg.getByLabel("التصنيف").selectOption({ label: "نظافة ومستلزمات" });
    await dlg.getByLabel("المبلغ").fill("12.5");
    await dlg.getByLabel("الوصف").fill("منظفات الأرضيات");
    await dlg.getByLabel("المرفق").setInputFiles({ name: "r.png", mimeType: "image/png", buffer: PNG });
    await dlg.getByRole("button", { name: "حفظ السند" }).click();
    await expect(dlg).toBeHidden();

    await go("/staff/ledger");
    await page.getByRole("button", { name: "تحديد الرصيد الافتتاحي" }).click();
    const op = page.getByRole("dialog");
    await op.getByLabel("المبلغ").fill("500");
    await op.locator("textarea").fill("رصيد الصندوق عند بدء النظام");
    await op.getByRole("button", { name: "حفظ", exact: true }).click();
    await expect(op).toBeHidden();
    const line = page.getByTestId("ledger-line").filter({ hasText: "منظفات الأرضيات" });
    await expect(line).toContainText("12.50");
    await expect(page.getByTestId("ledger-totals")).toContainText("الرصيد آخر الفترة");

    await go("/staff/expenses");
    const row = page.getByTestId("expense-row").filter({ hasText: "منظفات الأرضيات" });
    await row.getByRole("button", { name: "إلغاء" }).click();
    const c = page.getByRole("dialog");
    await c.getByRole("button", { name: "إلغاء السند" }).click();
    await expect(c.getByText("يجب كتابة سبب.")).toBeVisible();
    await c.locator("textarea").fill("سُجّل مرتين");
    await c.getByRole("button", { name: "إلغاء السند" }).click();
    await expect(row).toContainText("ملغى: سُجّل مرتين");
  });
});
