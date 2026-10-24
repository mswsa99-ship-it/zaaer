/**
 * Admin definitions — test ids AD01–AD04 (decision 57: renamed from U02–U05, which the testing rules reserve for
 * other interface scenarios).
 * Controls: G16 (a definition in use is archived, never deleted; deletion shows its dependencies — AD01, AD02),
 * G22 (archiving records a reason — AD01). AD03: confirmations are an in-page step (no native confirm(), which
 * embedded viewers block); AD04: tax policy and AI settings are settings, not code.
 */
import { test, expect } from "./fixtures";

test.describe("admin definitions", () => {
  test("AD01 a facility is created, archived with a reason, hidden from new choices, and restorable", async ({ page, loginAs }) => {
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

  test("AD02 a definition in use cannot be hard-deleted: the dialog shows its dependencies", async ({ page, loginAs }) => {
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

  test("AD03 policies use an in-page two-step delete (no native confirm)", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/admin/policies", { waitUntil: "networkidle" });
    page.on("dialog", (d) => { throw new Error(`native dialog opened: ${d.message()}`); });
    const del = page.getByRole("button", { name: /حذف/ }).first();
    await expect(del).toBeVisible();
    await del.click();
    await expect(page.getByText("تأكيد حذف السياسة؛ لن يتمكن المساعد الذكي من ذكرها بعد الحذف.")).toBeVisible();
  });

  test("AD04 tax policy and AI settings are settings pages, not code", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/admin/ai-settings", { waitUntil: "networkidle" });
    await expect(page.getByRole("heading", { name: "إعدادات الذكاء الاصطناعي" })).toBeVisible();
    // fallback models are a setting too: validated in the form, saved in order, Arabic comma accepted
    const fallbacks = page.getByLabel("النماذج الاحتياطية (حتى 3، بالترتيب)");
    await expect(fallbacks).toHaveValue("gemini-3.6-flash, gemini-3.5-flash-lite");
    await fallbacks.fill("Gemini 3!");
    await expect(page.getByText(/اكتب معرّفات نماذج فقط/)).toBeVisible();
    await fallbacks.fill("gemini-3.5-flash-lite، gemini-3.6-flash");
    await page.getByRole("button", { name: "حفظ الإعدادات" }).click();
    await expect(page.getByText("تم الحفظ")).toBeVisible();
    await expect(fallbacks).toHaveValue("gemini-3.5-flash-lite, gemini-3.6-flash");
    await page.goto("/#/admin/branches", { waitUntil: "networkidle" });
    await expect(page.getByText(/الضريبة|ضريبة/).first()).toBeVisible();
  });
});
