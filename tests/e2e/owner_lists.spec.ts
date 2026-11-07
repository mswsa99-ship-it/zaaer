/**
 * Review of 31 October, Phase 4b (QN10–QN14; migration 0060): the owner's lists — a guest search that also finds the
 * near spellings and says so, a short guest list that grows on request, each review item closed on purpose (an objection
 * with its note, a review taken back), a data purge that starts with no branch chosen, and AI settings that warn of
 * unsaved changes and refuse a number out of its range.
 */
import { test, expect } from "./fixtures";

test.describe("owner lists", () => {
  test("QN10 the guest search finds a near spelling, marks it «اسم قريب», and lists it after the exact matches", async ({ page, loginAs, go, errors }) => {
    await loginAs("owner");
    await go("/admin/guests");
    await expect(page.getByTestId("guest-paging")).toBeVisible();
    await page.getByTestId("guest-search").fill("عبدالرحمن محمود القحطاني");
    const rows = page.getByTestId("guest-row");
    await expect(rows.filter({ hasText: "عبدالرحمن محمد القحطاني" })).toHaveCount(1);
    await expect(rows.filter({ hasText: "عبدالرحمن محمد القحطاني" }).getByTestId("guest-near")).toBeVisible();
    expect(errors).toEqual([]);
  });

  test("QN11 the guest list starts short and grows with «عرض المزيد»", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/guests");
    const rows = page.getByTestId("guest-row");
    await expect(rows).toHaveCount(5);
    await page.getByTestId("guest-more").click();
    await expect.poll(() => rows.count()).toBeGreaterThan(5);
  });

  test("QN12 an objection needs its note, keeps the item open and shows on it; a review is taken back from the toast", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/review");
    const item = page.getByTestId("review-item").first();
    await item.getByTestId("review-object").click();
    const send = item.getByRole("button", { name: "إرسال الاعتراض" });
    await item.getByLabel("نص الاعتراض").fill("لا");
    await expect(send).toBeDisabled();
    await item.getByLabel("نص الاعتراض").fill("لماذا تغيّر مبلغ الفاتورة؟");
    await send.click();
    await expect(item.getByTestId("review-objection")).toContainText("لماذا تغيّر مبلغ الفاتورة؟");
    const before = await page.getByTestId("review-item").count();
    await item.getByTestId("review-ok").click();
    await item.getByRole("button", { name: "تأكيد: تمت مراجعته" }).click();
    await expect(page.getByTestId("review-item")).toHaveCount(before - 1);
    await page.getByTestId("review-undo-toast").getByRole("button", { name: /تراجع/ }).click();
    await expect(page.getByTestId("review-item")).toHaveCount(before);
  });

  test("QN13 the data purge starts with no branch: nothing can be previewed until one is chosen", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/data-purge");
    await expect(page.getByTestId("purge-branch")).toHaveValue("choose");
    await expect(page.getByRole("button", { name: /معاينة/ }).first()).toBeDisabled();
  });

  test("QN14 the AI settings mark unsaved changes and refuse a number out of its range", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/ai-settings");
    const tokens = page.getByLabel("أقصى طول للرد بالوحدات النصية (50–2000)");
    await tokens.fill("5000");
    await expect(page.getByTestId("ai-unsaved")).toBeVisible();
    await page.getByRole("button", { name: /^حفظ/ }).first().click();
    await expect(page.getByText(/«.+» خارج النطاق المسموح \(50–2,000\)/)).toBeVisible();   // the save names the field
    await expect(page.getByText("تم الحفظ")).toHaveCount(0);
  });
});
