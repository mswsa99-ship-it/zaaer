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

  test("MC07b the manager replaces the bank account: one per branch, archiving needs a reason, the new one carries the start and end of its number; a supervisor cannot open the page", async ({ page, loginAs, go }) => {
    await loginAs("manager");
    await go("/admin/cash-accounts");
    const cards = page.getByTestId("cash-account");
    await expect(cards).toHaveCount(2);
    await expect(cards.filter({ hasText: "حساب الشبكة والتحويل" })).toContainText("الافتراضي");
    // A1: both kinds are in use, so nothing can be added beside them
    await expect(page.getByRole("button", { name: /إضافة (صندوق|حساب بنكي)/ })).toHaveCount(0);
    await expect(cards.filter({ hasText: "حساب الشبكة والتحويل" }).getByTestId("account-rule-missing")).toBeVisible();

    // archiving: the reason is required; then «إضافة حساب بنكي» appears for the replacement
    await cards.filter({ hasText: "حساب الشبكة والتحويل" }).getByRole("button", { name: "أرشفة" }).click();
    const arch = page.getByRole("dialog");
    await arch.getByRole("button", { name: "أرشفة" }).click();
    await expect(arch.getByText("يجب كتابة سبب.")).toBeVisible();
    await arch.locator("textarea").fill("أُغلق الحساب");
    await arch.getByRole("button", { name: "أرشفة" }).click();
    await expect(arch).toBeHidden();
    await expect(cards).toHaveCount(1);

    await page.getByRole("button", { name: "إضافة حساب بنكي" }).click();
    const dlg = page.getByRole("dialog");
    await dlg.getByLabel("الاسم").fill("حساب التحويلات");
    await dlg.getByLabel("البنك").fill("بنك تجريبي");
    await dlg.getByLabel("بداية رقم الحساب").fill("٣٤٦");
    await dlg.getByLabel("نهاية رقم الحساب").fill("9876");
    await dlg.getByRole("button", { name: "حفظ", exact: true }).click();
    await expect(dlg).toBeHidden();
    await expect(cards).toHaveCount(2);
    const added = cards.filter({ hasText: "حساب التحويلات" });
    await expect(added).toContainText("الافتراضي");
    await expect(added.getByTestId("account-rule")).toHaveText(/يبدأ بـ 346 وينتهي بـ 9876/);
    await expect(page.getByRole("button", { name: /إضافة (صندوق|حساب بنكي)/ })).toHaveCount(0);

    // the archived one shows with its reason, and cannot come back while the new one is in use
    await page.getByLabel("إظهار المؤرشف").check();
    const old = cards.filter({ hasText: "حساب الشبكة والتحويل" });
    await expect(old).toContainText("أُغلق الحساب");
    await expect(old.getByRole("button", { name: "استعادة" })).toHaveCount(0);

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

  test("MC13a tax belongs to the owner: the manager sees it locked; at zero tax no tax line is quoted; the owner's 15% on rent applies to new quotes", async ({ page, loginAs, go }) => {
    await loginAs("manager");
    await go("/admin/branches");
    await page.getByRole("button", { name: /^تعديل فرع الرياض/ }).click();
    // 0069 (W2): a switch and a rate for each of rent, services and products — all locked for anyone but the owner
    for (const k of ["الإيجار", "الخدمات", "المنتجات"]) await expect(page.getByRole("switch", { name: `ضريبة ${k}` })).toBeDisabled();
    await expect(page.getByLabel("نسبة ضريبة الإيجار")).toBeDisabled();
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
    await page.getByRole("switch", { name: "ضريبة الإيجار" }).click();
    await page.getByRole("dialog").getByRole("button", { name: "حفظ", exact: true }).click();
    await expect(page.getByRole("dialog")).toBeHidden();
    await expect(page.getByText(/ضريبة: الإيجار 15% \(غير شاملة\)/).first()).toBeVisible();

    await go("/staff/reservations/new");
    await expect(page.getByText(/^الضريبة 15%/)).toBeVisible();
  });

  test("VT40 the tax switches: off by default with a rate ready; the owner turns products on at 5% and services on, the card says what is taxed; a rate of zero is refused with its reason", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/branches");
    await page.getByRole("button", { name: /^تعديل فرع الرياض/ }).click();
    const dlg = page.getByRole("dialog");
    for (const k of ["الإيجار", "الخدمات", "المنتجات"]) {
      await expect(dlg.getByRole("switch", { name: `ضريبة ${k}` })).toHaveAttribute("aria-checked", "false");
      await expect(dlg.getByLabel(`نسبة ضريبة ${k}`)).toHaveValue("15");
      await expect(dlg.getByLabel(`نسبة ضريبة ${k}`)).toBeDisabled();          // a rate is typed once its switch is on
    }
    await expect(dlg.getByLabel("الأسعار شاملة الضريبة")).toHaveCount(0);        // asked only when something is taxed
    await dlg.getByRole("switch", { name: "ضريبة المنتجات" }).click();
    await dlg.getByLabel("نسبة ضريبة المنتجات").fill("0");
    await dlg.getByRole("button", { name: "حفظ", exact: true }).click();
    await expect(dlg.getByRole("alert")).toContainText("نسبة الضريبة بين 0.01% و100%");
    await dlg.getByLabel("نسبة ضريبة المنتجات").fill("5");
    await dlg.getByRole("switch", { name: "ضريبة الخدمات" }).click();
    await expect(dlg.getByLabel("الأسعار شاملة الضريبة")).toBeVisible();
    await dlg.getByRole("button", { name: "حفظ", exact: true }).click();
    await expect(dlg).toBeHidden();
    await expect(page.getByText(/ضريبة: الخدمات 15%، المنتجات 5% \(غير شاملة\)/).first()).toBeVisible();
    // the rent is not taxed: a new quote has no tax line
    await go("/staff/reservations/new");
    await expect(page.getByText("الإجمالي").first()).toBeVisible();
    await expect(page.getByText(/^الضريبة/)).toHaveCount(0);
    // opened again, the switches are as saved
    await go("/admin/branches");
    await page.getByRole("button", { name: /^تعديل فرع الرياض/ }).click();
    await expect(dlg.getByRole("switch", { name: "ضريبة المنتجات" })).toHaveAttribute("aria-checked", "true");
    await expect(dlg.getByLabel("نسبة ضريبة المنتجات")).toHaveValue("5");
    await expect(dlg.getByRole("switch", { name: "ضريبة الإيجار" })).toHaveAttribute("aria-checked", "false");
  });
});

test.describe("the commission of each booking source (0051)", () => {
  test("CM02 the owner sets a source's commission; matching its deposit expects the gross less it, with no reason asked", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/booking-sources");
    await expect(page.getByTestId("commission-agoda")).toContainText("15%");
    await page.getByTestId("edit-commission-booking_com").click();
    const dlg = page.getByRole("dialog");
    await dlg.getByTestId("commission-input").fill("150");
    await dlg.getByRole("button", { name: "حفظ", exact: true }).click();
    await expect(dlg.getByText("العمولة نسبة من 0 إلى 100%")).toBeVisible();
    await dlg.getByTestId("commission-input").fill("10");
    await dlg.getByRole("button", { name: "حفظ", exact: true }).click();
    await expect(page.getByTestId("commission-booking_com")).toContainText("10%");

    await go("/admin/platform-payouts");
    const card = page.locator(".card", { hasText: "Booking.com" }).first();
    await expect(card).toBeVisible();
    await card.getByRole("button", { name: "تحديد الكل" }).click();
    await page.getByRole("button", { name: "تأكيد إيداع المنصة" }).click();
    const pay = page.getByRole("dialog");
    await expect(pay.getByTestId("payout-expected")).toContainText("عمولة المنصة 10%");
    const gross = parseSar(await pay.getByTestId("payout-expected").locator("p").first().locator("[dir=ltr]").innerText());
    const received = Number(await pay.locator("input[data-money]").first().inputValue());
    expect(received).toBeCloseTo(gross * 0.9, 2);
    await expect(pay.getByLabel("سبب الفرق")).toHaveCount(0);
    await pay.getByLabel("مرجع الإيداع").fill("PAYOUT-CM02");
    await pay.getByRole("button", { name: "تأكيد" }).click();
    await expect(pay).toHaveCount(0);
    await expect(page.locator("tr", { hasText: "PAYOUT-CM02" })).toContainText("10%");
  });
});
