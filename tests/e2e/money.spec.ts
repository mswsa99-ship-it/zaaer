/**
 * Core money through the staff UI (Phase 1) — the UI facet of tests/sql/money_core_tests.sql and the demo tests in
 * tests/unit/demo-invariants.test.ts: same MC codes, same scenarios (decision 57).
 * Controls: G10 (a partial payment is never "paid"), G11 (the deposit is a separate balance), G14 (money in halalas),
 * G22 (every change audited), G27 (the UI shows what the server stored, never a fake success).
 */
import { test, expect, createReservation, parseSar } from "./fixtures";
import type { Page } from "@playwright/test";

/** Sign the current user out (same control as S04), so the next loginAs() starts from the login screen. */
async function signOut(page: Page) {
  await page.locator('[title="تسجيل الخروج"]:visible, [aria-label="تسجيل الخروج"]:visible').first().click();
  await expect(page).toHaveURL(/#\/staff\/login/);
}

test.describe("core money (phase 1)", () => {
  test("MC04 a terminal payment needs its transaction number and lands in the default bank account; the deposit is never taken through the platform", async ({ page, loginAs }) => {
    await loginAs("supervisor");
    await createReservation(page, "ضيف الشبكة", "0501112233");

    await page.getByRole("button", { name: "سند قبض إقامة" }).click();
    const dlg = page.getByRole("dialog");
    await expect(dlg.getByRole("radio")).toHaveCount(4);
    await expect(dlg.getByRole("radio", { name: "نقد" })).toHaveAttribute("aria-checked", "true");
    await expect(dlg.getByLabel("الصندوق")).toContainText("صندوق الاستقبال");
    await dlg.getByRole("radio", { name: "شبكة" }).click();
    await expect(dlg.getByLabel("الحساب البنكي")).toContainText("حساب الشبكة والتحويل");
    await dlg.locator("input[data-money]").first().fill("120");
    await dlg.getByRole("button", { name: "حفظ السند" }).click();
    await expect(dlg.getByText("رقم المرجع أو رقم العملية مطلوب.")).toBeVisible();
    await dlg.getByLabel("رقم العملية").fill("TRX-445566");
    await dlg.getByRole("button", { name: "حفظ السند" }).click();
    await expect(dlg).toBeHidden();
    await expect(page.getByText(/شبكة · حساب الشبكة والتحويل · TRX-445566/)).toBeVisible();

    // the deposit: 50.00 suggested (decision 69), and the platform is not a way to take it
    await page.getByRole("button", { name: "قبض تأمين" }).click();
    const dep = page.getByRole("dialog");
    await expect(dep.getByRole("radio")).toHaveCount(3);
    await expect(dep.getByRole("radio", { name: "آجل عبر المنصة" })).toHaveCount(0);
    await expect(dep.locator("input[data-money]").first()).toHaveValue("50");   // whole riyals show without .00 (note 2)
  });

  test("MC07b the manager adds a bank account and makes it the default; archiving needs a reason; a supervisor cannot open the page", async ({ page, loginAs, go }) => {
    await loginAs("manager");
    await go("/admin/cash-accounts");
    const cards = page.getByTestId("cash-account");
    await expect(cards).toHaveCount(2);
    await expect(cards.filter({ hasText: "حساب الشبكة والتحويل" })).toContainText("الافتراضي");

    await page.getByRole("button", { name: "صندوق أو حساب" }).click();
    const dlg = page.getByRole("dialog");
    await dlg.getByLabel("النوع").selectOption("bank_account");
    await dlg.getByLabel("الاسم").fill("حساب التحويلات");
    await dlg.getByLabel("البنك").fill("بنك تجريبي");
    await dlg.getByLabel("آخر أربعة أرقام").fill("9876");
    await dlg.getByLabel(/الافتراضي لكل/).check();
    await dlg.getByRole("button", { name: "حفظ" }).click();
    await expect(dlg).toBeHidden();
    await expect(cards).toHaveCount(3);
    await expect(cards.filter({ hasText: "حساب التحويلات" })).toContainText("الافتراضي");
    await expect(cards.filter({ hasText: "حساب التحويلات" })).toContainText("••9876");
    await expect(cards.filter({ hasText: "حساب الشبكة والتحويل" })).not.toContainText("الافتراضي");

    // archiving: the reason is required; the archived account leaves the list until «إظهار المؤرشف»
    await cards.filter({ hasText: "حساب الشبكة والتحويل" }).getByRole("button", { name: "أرشفة" }).click();
    const arch = page.getByRole("dialog");
    await arch.getByRole("button", { name: "أرشفة" }).click();
    await expect(arch.getByText("يجب كتابة سبب.")).toBeVisible();
    await arch.locator("textarea").fill("أُغلق الحساب");
    await arch.getByRole("button", { name: "أرشفة" }).click();
    await expect(arch).toBeHidden();
    await expect(cards).toHaveCount(2);
    await page.getByLabel("إظهار المؤرشف").check();
    await expect(cards.filter({ hasText: "حساب الشبكة والتحويل" })).toContainText("أُغلق الحساب");

    await signOut(page);
    await loginAs("supervisor");
    await go("/admin/cash-accounts");
    await expect(page.getByText("هذه الصفحة غير متاحة لدورك")).toBeVisible();
  });

  test("MC10 the supervisor settles the day's card terminal; a difference is saved only with its reason", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await go("/staff/pos-settlement");
    const total = parseSar(await page.getByTestId("pos-system-total").innerText());
    expect(Number.isFinite(total)).toBe(true);
    const terminal = page.locator("form input[data-money]").first();

    await terminal.fill((total - 5).toFixed(2));
    await expect(page.getByTestId("pos-diff")).toContainText("الفرق");
    await page.getByRole("button", { name: "حفظ التسوية" }).click();
    await expect(page.getByRole("alert")).toHaveText("يوجد فرق: اكتب سببه.");
    await page.getByLabel("سبب الفرق").fill("عملية أُلغيت في الجهاز");
    await page.getByRole("button", { name: "حفظ التسوية" }).click();
    await expect(page.getByText("حُفظت مع الفرق وسببه، وتظهر للمالك للمراجعة.")).toBeVisible();
    await expect(page.getByTestId("pos-settlement-status")).toContainText("عملية أُلغيت في الجهاز");
    await expect(page.getByTestId("pos-history")).toContainText("فرق");

    // corrected later: the same day is updated, not duplicated
    await terminal.fill(total.toFixed(2));
    await expect(page.getByTestId("pos-diff")).toHaveText("مطابق للسندات.");
    await page.getByRole("button", { name: "تحديث التسوية" }).click();
    await expect(page.getByText("حُفظت: مطابقة.")).toBeVisible();
    await expect(page.getByTestId("pos-settlement-status")).toContainText("مطابق");
    await expect(page.getByTestId("pos-history").getByRole("button")).toHaveCount(1);
  });

  test("MC12 finance matches a platform deposit to its deferred payments; the commission is the explained difference", async ({ page, loginAs, go }) => {
    await loginAs("finance");
    await go("/admin/platform-payouts");
    const rows = page.getByTestId("platform-payment");
    const before = await rows.count();
    expect(before).toBeGreaterThan(0);

    await page.getByRole("button", { name: "تحديد الكل" }).first().click();
    await page.getByRole("button", { name: "تأكيد إيداع المنصة" }).click();
    const dlg = page.getByRole("dialog");
    const received = dlg.locator("input[data-money]").first();
    const expected = Number(await received.inputValue());
    expect(expected).toBeGreaterThan(0);
    await received.fill((expected - 25).toFixed(2));
    await dlg.getByLabel("مرجع الإيداع").fill("PAYOUT-2026-10");
    await dlg.getByRole("button", { name: "تأكيد" }).click();
    await expect(dlg.getByText("يوجد فرق: اكتب سببه.")).toBeVisible();
    await dlg.getByLabel("سبب الفرق").fill("عمولة المنصة");
    await dlg.getByRole("button", { name: "تأكيد" }).click();
    await expect(dlg).toBeHidden();
    await expect(page.getByRole("cell", { name: "PAYOUT-2026-10" })).toBeVisible();
    await expect(page.getByText("عمولة المنصة")).toBeVisible();
    expect(await rows.count()).toBeLessThan(before);
  });

  test("MC13a tax belongs to the owner: the manager sees it locked; at zero tax no tax line is quoted; the owner's 15% applies to new quotes", async ({ page, loginAs, go }) => {
    await loginAs("manager");
    await go("/admin/branches");
    await page.getByRole("button", { name: /^تعديل فرع الرياض/ }).click();
    await expect(page.getByLabel("نسبة الضريبة")).toBeDisabled();
    await expect(page.getByTestId("branch-tax")).toContainText("يعدّلها المالك فقط");
    await page.getByRole("dialog").getByRole("button", { name: "إلغاء" }).click();

    await signOut(page);
    await loginAs("owner");
    await go("/staff/reservations/new");
    await expect(page.getByText("الإجمالي").first()).toBeVisible();
    await expect(page.getByText(/^الضريبة/)).toHaveCount(0);

    await go("/admin/branches");
    await expect(page.getByText(/بلا ضريبة/).first()).toBeVisible();
    await page.getByRole("button", { name: /^تعديل فرع الرياض/ }).click();
    await page.getByLabel("نسبة الضريبة").fill("15");
    await page.getByRole("dialog").getByRole("button", { name: "حفظ" }).click();
    await expect(page.getByRole("dialog")).toBeHidden();
    await expect(page.getByText(/ضريبة 15\.00%/).first()).toBeVisible();

    await go("/staff/reservations/new");
    await expect(page.getByText(/^الضريبة 15%/)).toBeVisible();
  });
});
