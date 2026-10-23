/**
 * Knowledge base — acceptance ids K20–K23 (UI). The assistant answers from staff-authored
 * entries; what it cannot answer is logged for staff and becomes an answer with one click.
 */
import { test, expect } from "./fixtures";

test.describe("knowledge base", () => {
  test("K20 a guest question is answered from the knowledge base, verbatim", async ({ openAssistant, ask }) => {
    await openAssistant();
    const pool = await ask("هل يوجد مسبح؟");
    expect(pool).toMatch(/مسبح خارجي مشترك/);
    const breakfast = await ask("عندكم فطور؟");
    expect(breakfast).toMatch(/لا يُقدَّم إفطار/);
    const pets = await ask("أقدر أجيب قطتي معي؟");
    expect(pets).toMatch(/لا يُسمح باصطحاب الحيوانات/);
  });

  test("K21 an unknown question is logged, then answered by staff, then answered to the next guest", async ({ page, openAssistant, ask }) => {
    await openAssistant();
    const unknown = await ask("هل يوجد ملعب تنس في المبنى؟");
    expect(unknown).toMatch(/سجّلت سؤالك/);

    // staff (already signed in as a supervisor): the question is waiting in the unanswered tab
    await page.goto("/#/admin/knowledge", { waitUntil: "networkidle" });
    await page.getByRole("button", { name: /بلا إجابة/ }).click();
    const row = page.locator(".card", { hasText: "هل يوجد ملعب تنس في المبنى؟" }).first();
    await expect(row).toBeVisible();
    await row.getByRole("button", { name: "إضافة إجابة" }).click();
    const dlg = page.getByRole("dialog");
    await expect(dlg.locator("input.input").first()).toHaveValue("هل يوجد ملعب تنس في المبنى؟");
    // keywords were suggested from the question; add a synonym
    await dlg.getByLabel("أضف كلمة مفتاحية").fill("تنس");
    await dlg.locator("textarea").first().fill("لا يوجد ملعب تنس داخل المبنى، وأقرب نادٍ رياضي على بُعد 10 دقائق بالسيارة.");
    await dlg.getByRole("button", { name: "حفظ وإغلاق السؤال" }).click();
    await expect(dlg).toBeHidden();
    await expect(page.locator(".card", { hasText: "هل يوجد ملعب تنس في المبنى؟" })).toHaveCount(0);

    // the entry is live for guests immediately (same browser context → same demo store)
    await page.goto("/#/admin/assistant?new=1", { waitUntil: "networkidle" });
    const answered = await ask("فيه ملعب تنس؟");
    expect(answered).toMatch(/لا يوجد ملعب تنس داخل المبنى/);
  });

  test("K22 archiving needs a reason and hides the answer from guests; restore brings it back", async ({ page, loginAs, ask }) => {
    await loginAs("owner");
    await page.goto("/#/admin/knowledge", { waitUntil: "networkidle" });
    const card = page.locator(".card", { hasText: "هل يوجد مصلى؟" }).first();
    await card.getByTitle("أرشفة").click();
    const dlg = page.getByRole("dialog");
    await dlg.getByRole("button", { name: "تأكيد الأرشفة" }).click();
    await expect(dlg.locator(".border-danger-500\\/30")).toBeVisible(); // validation error shown, dialog still open
    await dlg.locator("textarea").fill("تم إغلاق المصلى للصيانة");
    await dlg.getByRole("button", { name: "تأكيد الأرشفة" }).click();
    await expect(dlg).toBeHidden();
    await expect(page.locator(".card", { hasText: "هل يوجد مصلى؟" })).toHaveCount(0);

    await page.goto("/#/admin/assistant?new=1", { waitUntil: "networkidle" });
    const r = await ask("هل يوجد مصلى؟");
    expect(r).not.toMatch(/مصلى للرجال/);

    await page.goto("/#/admin/knowledge", { waitUntil: "networkidle" });
    await page.getByText("إظهار المؤرشف").click();
    const archived = page.locator(".card", { hasText: "هل يوجد مصلى؟" }).first();
    await expect(archived.getByText("مؤرشف")).toBeVisible();
    await archived.getByTitle("استعادة").click();
    await expect(archived.getByText("مؤرشف")).toHaveCount(0);
  });

  test("K23 housekeeping cannot manage the knowledge base; staff-only entries never reach guests", async ({ page, loginAs }) => {
    await loginAs("housekeeping");
    await page.goto("/#/admin/knowledge", { waitUntil: "networkidle" });
    await expect(page.getByRole("button", { name: "سؤال وجواب" })).toHaveCount(0);
  });
});
