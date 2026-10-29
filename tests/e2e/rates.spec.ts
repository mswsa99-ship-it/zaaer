/**
 * Rates through the staff UI (Phase 2) — the UI facet of tests/sql/rates_tests.sql and the demo tests in
 * tests/unit/demo-invariants.test.ts: same PR codes, same scenarios (decision 57).
 * Controls: G06 (a stay's price moves with its nights), G14 (halalas, one rounding rule), G19 (no edit lost — the
 * calendar answers with what it changed), G22 (audited), G27 (a price change never reprices a booked stay).
 */
import { test, expect, parseSar } from "./fixtures";
import type { Page } from "@playwright/test";

const riyadhToday = () => new Date().toLocaleDateString("en-CA", { timeZone: "Asia/Riyadh" });
const plus = (iso: string, n: number) => { const d = new Date(`${iso}T00:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };

/** Fills the new-booking form up to the quote: type, dates, guest. */
async function startBooking(page: Page, type: RegExp, from: string, to: string, guest = "ضيف الأسعار") {
  await page.goto("/#/staff/reservations/new", { waitUntil: "networkidle" });
  await page.locator("div:has(> label:has-text('الاسم (مطلوب)')) input").first().fill(guest);
  await page.getByPlaceholder("05xxxxxxxx").fill("0501234500");
  const typeSelect = page.locator("select").filter({ has: page.locator("option", { hasText: type }) }).first();
  const value = await typeSelect.locator("option", { hasText: type }).first().getAttribute("value");
  await typeSelect.selectOption(value!);
  await page.locator("input[type=date]").nth(0).fill(from);
  await page.locator("input[type=date]").nth(1).fill(to);
  await expect(page.getByTestId("quote-runs")).toBeVisible();
}
const totalText = (page: Page) => page.locator('div:has(> :is(p, span):text-is("الإجمالي")) > :is(p, span)[dir=ltr]').first().innerText();
const rentOf = async (page: Page) => parseSar(await page.locator("div.flex.justify-between", { hasText: /^الإيجار \(/ }).locator("span[dir=ltr]").first().innerText());

test.describe("rates (phase 2)", () => {
  test("PR05 the manager prices selected nights in the calendar; a new booking quotes those nights at that price", async ({ page, loginAs, go }) => {
    const t = riyadhToday(); const nights = [plus(t, 10), plus(t, 11), plus(t, 12)];
    await loginAs("manager");
    await go("/admin/rates");
    await expect(page.getByTestId("rates-grid")).toBeVisible();
    await page.getByRole("button", { name: `شقة بغرفتين السعر ${nights[0]}` }).click();
    await page.getByRole("button", { name: `شقة بغرفتين السعر ${nights[2]}` }).click({ modifiers: ["Shift"] });
    await expect(page.getByText("3 خانة محددة")).toBeVisible();
    await page.getByRole("button", { name: "تعديل المحدد" }).click();
    const dlg = page.getByRole("dialog");
    await dlg.locator("input[data-money]").first().fill("650");
    await dlg.getByRole("button", { name: "حفظ" }).click();
    await expect(dlg).toBeHidden();
    await expect(page.getByText("حُدِّثت 3 خانة.")).toBeVisible();
    await expect(page.getByRole("button", { name: `شقة بغرفتين السعر ${nights[1]}` })).toHaveText("650");

    // a price under the type's minimum (480.00) is refused, with the reason
    await page.getByRole("button", { name: `شقة بغرفتين السعر ${plus(t, 14)}` }).click();
    await page.getByRole("button", { name: "تعديل المحدد" }).click();
    await dlg.locator("input[data-money]").first().fill("300");
    await dlg.getByRole("button", { name: "حفظ" }).click();
    await expect(dlg.getByText("السعر أقل من الحد الأدنى لليلة في هذا النوع.")).toBeVisible();
    await dlg.getByRole("button", { name: "إغلاق" }).click();
    await expect(dlg).toBeHidden();

    await startBooking(page, /شقة بغرفتين/, nights[0], plus(t, 13));
    await expect(page.getByTestId("quote-runs")).toContainText("التقويم");
    expect(await rentOf(page)).toBe(1950);
  });

  test("PR03 a stay of 7 nights or more is priced at the type's weekly price, spread over its nights", async ({ page, loginAs }) => {
    const t = riyadhToday();
    await loginAs("supervisor");
    await startBooking(page, /استوديو مريح/, plus(t, 80), plus(t, 87));
    await expect(page.getByTestId("quote-runs")).toContainText("بالسعر الأسبوعي للنوع");
    expect(await rentOf(page)).toBe(1575);
  });

  test("PR06 the supervisor sees how much discount is allowed and cannot go beyond it", async ({ page, loginAs }) => {
    const t = riyadhToday();
    await loginAs("supervisor");
    await startBooking(page, /استوديو مريح/, plus(t, 90), plus(t, 93), "ضيف الخصم");
    // 3 nights × 250.00 = 750.00; branch A lets the supervisor give 10%: 75.00
    await expect(page.getByText(/المسموح لك حتى/)).toBeVisible();
    const discount = page.locator("div:has(> label:has-text('خصم (إجمالي)')) input[data-money]");
    await discount.fill("100");
    await page.getByLabel("سبب الخصم").fill("ضيف دائم");
    await page.getByRole("button", { name: "إنشاء الحجز" }).click();
    await expect(page.getByText("الخصم يتجاوز النسبة المسموحة للمشرف في هذا الفرع؛ يعتمده المالك أو المدير.")).toBeVisible();
    await discount.fill("50");
    await page.getByRole("button", { name: "إنشاء الحجز" }).click();
    await page.waitForURL(/#\/staff\/reservations\/[0-9a-f-]+/, { timeout: 15_000 });
    await expect(page.getByRole("heading", { name: "الملخص المالي" })).toBeVisible();
    await expect.poll(async () => parseSar(await page.locator('div:has(> :is(p, span):text-is("الإجمالي")) > :is(p, span)[dir=ltr]').first().innerText())).toBe(700);
  });

  test("PR14 before arrival a switch to a unit of another type shows the new price first, then re-prices the stay by it (0048)", async ({ page, loginAs }) => {
    const t = riyadhToday();
    await loginAs("supervisor");
    await startBooking(page, /استوديو مريح/, plus(t, 120), plus(t, 122), "ضيف التبديل");
    await page.getByRole("button", { name: "إنشاء الحجز" }).click();
    await page.waitForURL(/#\/staff\/reservations\/[0-9a-f-]+/, { timeout: 15_000 });
    const total = async () => parseSar(await totalText(page));
    await expect.poll(total).toBe(500);                                                       // 2 nights × 250.00
    await page.getByRole("button", { name: "الإقامة", exact: true }).click();
    await page.getByRole("button", { name: "تبديل الوحدة" }).click();
    const dlg = page.getByRole("dialog");
    const unit = dlg.locator("select").last();
    const value = await unit.locator("option", { hasText: "شقة بغرفة نوم" }).first().getAttribute("value");
    await unit.selectOption(value!);
    await expect(dlg.getByTestId("switch-reprice")).toContainText("يُعاد تسعير الليالي");
    await expect.poll(async () => parseSar(await dlg.getByTestId("switch-price-delta").locator("[dir=ltr]").innerText())).toBe(300); // 2 × 400.00 − 2 × 250.00
    await dlg.locator("textarea").fill("طلب الضيف وحدة أكبر");
    await dlg.getByRole("button", { name: "تبديل", exact: true }).click();
    await expect(dlg).toBeHidden();
    await expect.poll(total).toBe(800);
  });

  test("PR09 lowering a type's capacity first lists the coming stays that would no longer fit", async ({ page, loginAs, go }) => {
    const t = riyadhToday();
    await loginAs("owner");
    await startBooking(page, /استوديو مريح/, plus(t, 100), plus(t, 102), "ثلاثة نزلاء");
    await page.locator("div:has(> label:has-text('بالغون')) input").first().fill("2");
    await page.locator("div:has(> label:has-text('مرافقون')) input").first().fill("1");
    await page.getByRole("button", { name: "إنشاء الحجز" }).click();
    await page.waitForURL(/#\/staff\/reservations\/[0-9a-f-]+/, { timeout: 15_000 });

    await go("/admin/room-categories");
    await page.getByRole("button", { name: "تعديل استوديو مريح" }).click();
    const dlg = page.getByRole("dialog");
    await dlg.getByLabel("السعة القصوى").fill("2");
    await dlg.getByRole("button", { name: "حفظ" }).click();
    await expect(dlg.getByTestId("capacity-impact")).toContainText("حجز قادم فيه نزلاء أكثر من السعة الجديدة");
    await dlg.getByRole("button", { name: "حفظ رغم ذلك" }).click();
    await expect(dlg).toBeHidden();
    await expect(page.getByText("السعة 2–2").first()).toBeVisible();
  });

  test("PR04 the price calendar is the owner's and the managers': a supervisor cannot open it", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await go("/admin/rates");
    await expect(page.getByText("هذه الصفحة غير متاحة لدورك")).toBeVisible();
  });
});
