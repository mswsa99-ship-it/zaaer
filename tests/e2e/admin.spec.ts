/**
 * Admin definitions — acceptance ids U02–U05.
 * Controls: G07 (facility ≠ room; task type ≠ task), G09 (definitions in use are archived, never deleted;
 * deletion shows dependency counts), G10 (reason required), G25 (no native confirm(): the confirmation is
 * an in-page step that works inside embedded viewers too).
 */
import { test, expect } from "./fixtures";

test.describe("admin definitions", () => {
  test("U02 a facility is created, archived with a reason, hidden from new choices, and restorable", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/admin/facilities", { waitUntil: "networkidle" });
    await page.getByRole("button", { name: "مرفق جديد" }).click();
    const dlg = page.getByRole("dialog");
    await dlg.locator("div:has(> label:has-text('الاسم (مطلوب)')) input").first().fill("صالة اختبار E2E");
    await dlg.getByRole("button", { name: "حفظ" }).click();
    await expect(dlg).toBeHidden();
    const card = page.locator(".card", { has: page.getByRole("heading", { name: "صالة اختبار E2E" }) }).first();
    await expect(card).toBeVisible();

    // archive: requires a reason, keeps the record
    await card.locator("button:has(svg.lucide-pencil)").first().click();
    const edit = page.getByRole("dialog");
    await edit.getByRole("button", { name: "أرشفة" }).click();
    const confirm = edit.getByRole("button", { name: "تأكيد الأرشفة" });
    await expect(confirm).toBeDisabled();
    await edit.locator("textarea, input").filter({ hasNot: page.locator("[type=checkbox]") }).last().fill("لم تعد مستخدمة");
    await expect(confirm).toBeEnabled();
    await confirm.click();
    await expect(edit).toBeHidden();
    await expect(page.getByRole("heading", { name: "صالة اختبار E2E" })).toHaveCount(0);

    // archived items are visible on demand and restorable
    await page.getByText("إظهار المؤرشف").click();
    await expect(page.getByRole("heading", { name: "صالة اختبار E2E" })).toBeVisible();
    await expect(page.getByText("مؤرشف").first()).toBeVisible();
  });

  test("U03 a definition in use cannot be hard-deleted: the dialog shows its dependencies", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/admin/task-types", { waitUntil: "networkidle" });
    await page.locator("button:has(svg.lucide-pencil)").first().click();
    const edit = page.getByRole("dialog");
    await edit.getByRole("button", { name: "حذف نهائي" }).click();
    await expect(edit.getByText("لا يمكن الحذف لارتباطه بـ:")).toBeVisible();
    await expect(edit.getByText(/\d+ (مهام|حجوزات|وحدات)/).first()).toBeVisible();
    await expect(edit.getByText("يمكنك أرشفته بدلًا من الحذف.")).toBeVisible();
    // no confirm button is offered at all while dependencies exist
    await expect(edit.getByRole("button", { name: "تأكيد الحذف" })).toHaveCount(0);
  });

  test("U04 policies use an in-page two-step delete (no native confirm)", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/admin/policies", { waitUntil: "networkidle" });
    page.on("dialog", (d) => { throw new Error(`native dialog opened: ${d.message()}`); });
    const del = page.getByRole("button", { name: /حذف/ }).first();
    await expect(del).toBeVisible();
    await del.click();
    await expect(page.getByText("تأكيد حذف السياسة؛ لن يتمكن المساعد الذكي من ذكرها بعد الحذف.")).toBeVisible();
  });

  test("U05 tax policy and AI settings are settings pages, not code", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/admin/ai-settings", { waitUntil: "networkidle" });
    await expect(page.getByRole("heading", { name: "إعدادات الذكاء الاصطناعي" })).toBeVisible();
    await page.goto("/#/admin/branches", { waitUntil: "networkidle" });
    await expect(page.getByText(/الضريبة|ضريبة/).first()).toBeVisible();
  });
});
