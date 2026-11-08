/**
 * The bank's messages through the UI (A6/A7, migration 0066) — the UI facet of tests/sql/accounting_a6_tests.sql and the
 * demo test BK01–BK05: the owner sets the mailbox (the password never shown back), makes the relay key (shown once), adds
 * a word and reads an unread message again; the movements show with their kind, amount and account; the manager sees
 * the movements but not the raw messages.
 */
import { test, expect } from "./fixtures";

test.describe("bank messages", () => {
  test("BK30 the owner sets the bank mailbox: not connected until complete, the password kept hidden, the relay key shown once", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/bank-mail");
    await expect(page.getByTestId("bank-mail-state")).toHaveText("غير مربوط بعد");
    await page.getByRole("button", { name: "تعديل" }).first().click();
    const dlg = page.getByRole("dialog");
    await dlg.getByLabel("البريد المخصّص").fill("relay@example.com");
    await dlg.getByLabel("اسم الدخول").fill("relay@example.com");
    await dlg.getByLabel("كلمة مرور البريد").fill("app-pass-e2e");
    await dlg.getByRole("button", { name: "حفظ", exact: true }).click();
    await expect(dlg).toBeHidden();
    await expect(page.getByText("محفوظة مشفّرة")).toBeVisible();
    await expect(page.locator("body")).not.toContainText("app-pass-e2e");
    await page.getByRole("button", { name: "إنشاء المفتاح" }).click();
    const key = page.getByTestId("relay-key");
    await expect(key).toHaveText(/^[0-9a-f]{48}$/);
    const value = await key.textContent();
    await page.getByRole("button", { name: "نسخته" }).click();
    await expect(page.locator("body")).not.toContainText(value!);
    await expect(page.getByText(`ينتهي بـ ${value!.slice(-4)}`)).toBeVisible();
    await page.getByLabel("قراءة البريد تلقائيًا").check();
    await expect(page.getByTestId("bank-mail-state")).toHaveText("يعمل");
  });

  test("BK31 the owner reads an unread message again after adding its word; the SMS and the notification are one movement; an unassigned movement gets its branch account", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/staff/bank");
    await page.getByRole("tab", { name: "الرسائل كما وصلت" }).click();
    const unread = page.getByTestId("bank-message").filter({ hasText: "قيد عكسي" });
    await expect(unread).toContainText("لم تُفهم");
    await expect(page.getByTestId("bank-message").filter({ hasText: "مرفوضة" })).toContainText("ليست من بريد التطبيق");
    await go("/admin/bank-mail");
    await page.getByRole("button", { name: "كلمة", exact: true }).click();
    const dlg = page.getByRole("dialog");
    await dlg.getByLabel("الكلمة").fill("قيد عكسي");
    await dlg.getByLabel("نوع الحركة").selectOption({ label: "دخل آخر" });
    await dlg.getByLabel("الأولوية").fill("5");
    await dlg.getByRole("button", { name: "حفظ", exact: true }).click();
    await expect(page.getByTestId("bank-rule").filter({ hasText: "قيد عكسي" })).toContainText("داخل");
    await go("/staff/bank");
    await page.getByRole("tab", { name: "الرسائل كما وصلت" }).click();
    await page.getByTestId("bank-message").filter({ hasText: "قيد عكسي" }).getByRole("button", { name: "اقرأها من جديد" }).click();
    await expect(page.getByTestId("bank-message").filter({ hasText: "قيد عكسي" })).toContainText("قُرئت");
    await expect(page.getByTestId("bank-message").filter({ hasText: "مكررة لحركة سابقة" })).toHaveCount(1);
    // a movement of no known account: the owner gives it its branch account with a reason
    await page.getByRole("tab", { name: "غير المنسوبة" }).click();
    const un = page.getByTestId("bank-movement").filter({ hasText: "777****555" });
    await un.getByRole("button", { name: "نسبتها لحساب فرع" }).click();
    const d2 = page.getByRole("dialog");
    await d2.locator("textarea").fill("الحساب الوحيد لدينا بهذه الرسوم");
    await d2.getByRole("button", { name: "نسبتها", exact: true }).click();
    await expect(d2).toBeHidden();
    await expect(page.getByTestId("bank-movement").filter({ hasText: "777****555" })).toHaveCount(0);
  });

  test("BK32 the manager sees the branch's movements, not the raw messages nor the mailbox", async ({ page, loginAs, go }) => {
    await loginAs("manager");
    await go("/staff/bank");
    await expect(page.getByRole("tab", { name: "حركات الفرع" })).toBeVisible();
    await expect(page.getByRole("tab", { name: "الرسائل كما وصلت" })).toHaveCount(0);
    await expect(page.getByRole("link", { name: "بريد البنك" })).toHaveCount(0);
  });

  test("BK33 the owner gives a movement its branch account, records it as income, and undoes that with a reason (A8)", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/staff/bank");
    await page.getByRole("tab", { name: "غير المنسوبة" }).click();
    await page.getByTestId("bank-movement").filter({ hasText: "777****555" }).getByRole("button", { name: "نسبتها لحساب فرع" }).click();
    const d1 = page.getByRole("dialog");
    const select = d1.getByLabel("حساب الفرع");
    const value = await select.locator("option", { hasText: "الرياض" }).first().getAttribute("value");
    await select.selectOption(value!);
    await d1.locator("textarea").fill("حساب فرع الرياض");
    await d1.getByRole("button", { name: "نسبتها", exact: true }).click();
    await expect(d1).toBeHidden();
    await page.getByRole("tab", { name: "حركات الفرع" }).click();
    const mv = page.getByTestId("bank-movement").filter({ hasText: "+2.00" });
    await expect(mv).toContainText("بانتظار المطابقة");
    await mv.getByRole("button", { name: "تسجيلها إيرادًا" }).click();
    const d2 = page.getByRole("dialog");
    await d2.getByLabel("الوصف").fill("فرق من البنك");
    await d2.getByRole("button", { name: "تسجيل الإيراد" }).click();
    await expect(d2).toBeHidden();
    await expect(mv.getByTestId("bank-match")).toContainText("حُوّلت إلى: إيراد");
    await mv.getByRole("button", { name: "فك المطابقة" }).click();
    const d3 = page.getByRole("dialog");
    await d3.locator("textarea").fill("ليست إيرادًا");
    await d3.getByRole("button", { name: "فك المطابقة", exact: true }).click();
    await expect(d3).toBeHidden();
    await expect(mv).toContainText("بانتظار المطابقة");
  });
});
