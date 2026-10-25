/**
 * Invoices, voucher correction and the owner's review list through the UI (Phase 4, migration 0036–0037) — test ids
 * IU01–IU06, the UI facet of tests/sql/invoices_review_tests.sql (IV, VC, RL), tests/sql/monitors_tests.sql (MN) and the
 * demo tests in tests/unit/demo-invariants.test.ts (ID).
 * Controls: G10 and G14 (each share in whole halalas, periods adding up to the stay), G15 (an issued invoice or voucher is
 * never changed silently: a version kept, a correction linked to its original), G22 (who, when and why, in the owner's
 * list), G27 (the screen shows the server's refusal, never a fake success).
 */
import { test, expect, parseSar } from "./fixtures";
import type { Locator, Page } from "@playwright/test";

/** Opens the stay whose unit is `room`, among the reservations of `status`. */
async function openByRoom(page: Page, go: (p: string) => Promise<void>, room: string, status: string) {
  await go("/staff/reservations");
  await page.locator("select").filter({ has: page.locator(`option[value="${status}"]`) }).selectOption(status);
  const row = page.locator("table tbody tr").filter({ has: page.locator("td:nth-child(3)", { hasText: room }) }).first();
  await expect(row).toBeVisible();
  await row.getByRole("link", { name: "فتح" }).click();
  await page.waitForURL(/#\/staff\/reservations\/[0-9a-f-]+/);
  await expect(page.getByTestId("stay-cycle")).toBeVisible();
}

async function signOut(page: Page) {
  await page.locator('[title="تسجيل الخروج"]:visible, [aria-label="تسجيل الخروج"]:visible').first().click();
  await expect(page).toHaveURL(/#\/staff\/login/);
}

const addDays = (iso: string, n: number) => { const d = new Date(iso + "T00:00:00Z"); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
/** The preview's total once it has settled (the server answers a moment after the inputs change). */
/** The voucher numbers listed on the stay (to find the one a step just issued). */
const numbers = async (vouchers: Locator) => (await vouchers.locator("span.font-mono").allInnerTexts()).map((x) => x.trim());
/** Issues a 100 SAR cash receipt from the stay's ledger and returns its row. */
async function newReceipt(page: Page, vouchers: Locator): Promise<{ row: Locator; number: string }> {
  const before = await numbers(vouchers);
  await page.getByRole("button", { name: "سند قبض إقامة" }).click();
  const dlg = page.getByRole("dialog");
  await dlg.locator("input[type=number]").fill("100");
  await dlg.getByRole("button", { name: "حفظ السند" }).click();
  await expect(dlg).toBeHidden();
  await expect.poll(async () => (await numbers(vouchers)).length).toBe(before.length + 1);
  const number = (await numbers(vouchers)).find((n) => !before.includes(n))!;
  return { row: vouchers.locator("div.grid").filter({ has: page.locator("span.font-mono", { hasText: number }) }), number };
}
async function previewTotal(dlg: Locator): Promise<number> {
  const total = dlg.getByTestId("invoice-preview-total");
  await expect(total).toBeVisible();
  return parseSar(await total.innerText());
}

test.describe("invoices, voucher correction and the review list (phase 4)", () => {
  test("IU01 «إنشاء فاتورة» as in Zaaer: the stay, the guest and its dates, a period — the whole stay by default — with what it carries; «تجاهل» issues nothing, «إنشاء» a partial invoice", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await openByRoom(page, go, "205", "confirmed");
    await page.getByRole("button", { name: "إنشاء فاتورة" }).click();
    let dlg = page.getByRole("dialog");
    await expect(dlg).toContainText("لطيفة حمد السبيعي");
    const checkIn = await dlg.getByLabel("الفترة من").inputValue();
    const checkOut = await dlg.getByLabel("الفترة إلى").inputValue();
    expect(checkOut).toBe(addDays(checkIn, 4));
    const whole = await previewTotal(dlg);
    expect(whole).toBeGreaterThan(0);
    // «تجاهل»: nothing is issued
    await dlg.getByRole("button", { name: "تجاهل" }).click();
    await expect(dlg).toBeHidden();
    await expect(page.getByTestId(/^invoice-INV-/)).toHaveCount(0);
    // the first two nights: half the stay, at their saved price
    await page.getByRole("button", { name: "إنشاء فاتورة" }).click();
    dlg = page.getByRole("dialog");
    await dlg.getByLabel("الفترة إلى").fill(addDays(checkIn, 2));
    await expect.poll(() => previewTotal(dlg)).toBe(whole / 2);
    // a period ending before it starts is said, and «إنشاء» waits
    await dlg.getByLabel("الفترة من").fill(addDays(checkIn, 3));
    await expect(dlg.getByTestId("invoice-preview")).toContainText("نهاية الفترة يجب أن تكون بعد بدايتها");
    await expect(dlg.getByRole("button", { name: "إنشاء", exact: true })).toBeDisabled();
    await dlg.getByLabel("الفترة من").fill(checkIn);
    await expect.poll(() => previewTotal(dlg)).toBe(whole / 2);
    await dlg.getByRole("button", { name: "إنشاء", exact: true }).click();
    await expect(dlg).toBeHidden();
    const first = page.getByTestId(/^invoice-INV-/).first();
    await expect(first).toContainText("جزئية لفترة");
    await expect(page.getByTestId("uninvoiced")).toBeVisible();
    // the next one starts where the first ended, and takes the rest of the stay
    await page.getByRole("button", { name: "إنشاء فاتورة" }).click();
    dlg = page.getByRole("dialog");
    await expect(dlg.getByLabel("الفترة من")).toHaveValue(addDays(checkIn, 2));
    await expect.poll(() => previewTotal(dlg)).toBe(whole / 2);
    await dlg.getByRole("button", { name: "إنشاء", exact: true }).click();
    await expect(dlg).toBeHidden();
    await expect(page.getByTestId(/^invoice-INV-/)).toHaveCount(2);
    await expect(page.getByTestId("uninvoiced")).toHaveCount(0);
    await expect(page.getByRole("button", { name: "إنشاء فاتورة" })).toHaveCount(0);
  });

  test("IU02 an invoice is edited with a reason: the bill-to changes, the version before is kept and shown", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await openByRoom(page, go, "205", "confirmed");
    await page.getByRole("button", { name: "إنشاء فاتورة" }).click();
    let dlg = page.getByRole("dialog");
    await expect.poll(() => previewTotal(dlg)).toBeGreaterThan(0);
    await dlg.getByRole("button", { name: "إنشاء", exact: true }).click();
    await expect(dlg).toBeHidden();
    const row = page.getByTestId(/^invoice-INV-/).first();
    await row.getByRole("button", { name: "تعديل" }).click();
    dlg = page.getByRole("dialog");
    await dlg.getByLabel("اسم العميل على الفاتورة").fill("شركة الأفق للتجارة");
    // without a reason: refused, and the form keeps what was typed
    await dlg.getByRole("button", { name: "حفظ التعديل" }).click();
    await expect(dlg.getByText("يجب كتابة سبب.")).toBeVisible();
    await expect(dlg.getByLabel("اسم العميل على الفاتورة")).toHaveValue("شركة الأفق للتجارة");
    await dlg.locator("textarea").fill("طلب الضيف إصدارها باسم جهة عمله");
    await dlg.getByRole("button", { name: "حفظ التعديل" }).click();
    await expect(dlg).toBeHidden();
    await expect(row).toContainText("الإصدار 2");
    await expect(row).toContainText("شركة الأفق للتجارة");
    await row.getByRole("button", { name: "عرض" }).click();
    await expect(row.getByTestId("invoice-versions")).toContainText("الإصدار 1");
    await expect(row.getByTestId("invoice-versions")).toContainText("طلب الضيف إصدارها باسم جهة عمله");
  });

  test("IU03 «تصحيح سند»: the supervisor corrects the voucher they just issued — the original stays, cancelled, linked to its replacement", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await openByRoom(page, go, "205", "confirmed");
    const vouchers = page.locator(".card").filter({ has: page.getByRole("heading", { name: "السندات" }) });
    const { row: issued, number: original } = await newReceipt(page, vouchers);
    await issued.getByRole("button", { name: "تصحيح" }).click();
    const dlg = page.getByRole("dialog");
    await dlg.locator("input[type=number]").fill("80");
    await dlg.locator("textarea").fill("المقبوض 80 لا 100");
    await dlg.getByRole("button", { name: "تصحيح السند" }).click();
    await expect(dlg).toBeHidden();
    await expect(vouchers).toContainText(`تصحيح للسند ${original}`);
    const old = vouchers.locator("div.grid").filter({ has: page.locator("span.font-mono", { hasText: original }) });
    await expect(old).toContainText("ملغى");
    await expect(old).toContainText("صُحّح بالسند");
  });

  test("IU04 the owner's banner counts what waits; the list shows who, when and why; marked, it moves to «تمت مراجعتها» with the note", async ({ page, loginAs, go }) => {
    // a supervisor's correction, then the owner
    await loginAs("supervisor");
    await openByRoom(page, go, "205", "confirmed");
    const vouchers = page.locator(".card").filter({ has: page.getByRole("heading", { name: "السندات" }) });
    const { row } = await newReceipt(page, vouchers);
    await row.getByRole("button", { name: "تصحيح" }).click();
    const dlg = page.getByRole("dialog");
    await dlg.locator("input[type=number]").fill("90");
    await dlg.locator("textarea").fill("خطأ في المبلغ");
    await dlg.getByRole("button", { name: "تصحيح السند" }).click();
    await expect(dlg).toBeHidden();
    await signOut(page);

    await loginAs("owner");
    const banner = page.getByTestId("review-banner");
    await expect(banner).toContainText("بندان ينتظران");   // the seeded invoice edit, and this correction
    await banner.click();
    await expect(page).toHaveURL(/#\/admin\/review/);
    const items = page.getByTestId("review-item");
    await expect(items).toHaveCount(2);
    const corrected = items.filter({ hasText: "تصحيح سند" });
    await expect(corrected).toContainText("السبب: خطأ في المبلغ");
    await expect(corrected).toContainText("فهد الاستقبال");   // who issued the correction
    await expect(items.filter({ hasText: "تعديل فاتورة" })).toContainText("طلب الضيف إصدارها باسم جهة عمله");
    // mark the correction, with a note
    await corrected.getByRole("checkbox").check();
    await page.getByLabel("ملاحظة المراجعة").fill("راجعتها مع المشرف");
    await page.getByRole("button", { name: /تأشير المحدد كمراجَع/ }).click();
    await expect(items).toHaveCount(1);
    await page.getByRole("tab", { name: "تمت مراجعتها" }).click();
    await expect(items.first()).toContainText("راجعتها مع المشرف");
    await go("/staff/dashboard");
    await expect(page.getByTestId("review-banner")).toContainText("بند واحد ينتظر");
  });

  test("IU05 the monitors run when the owner opens the list; the filter shows them apart; nothing found, nothing raised", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/review");
    await expect(page.getByText(/آخر فحص للمراقبة/)).toBeVisible();
    await page.getByRole("button", { name: /^المراقبة/ }).click();
    await expect(page.getByText("لا شيء بانتظار المراجعة")).toBeVisible();
    await page.getByRole("button", { name: /^الفواتير/ }).click();
    await expect(page.getByTestId("review-item")).toHaveCount(1);
  });

  test("IU06 the list and the banner are the owner's alone; a manager corrects any voucher but neither sees nor marks the list", async ({ page, loginAs, go }) => {
    await loginAs("manager");
    await expect(page.getByTestId("review-banner")).toHaveCount(0);
    await go("/admin/review");
    await expect(page.getByText("هذه الصفحة غير متاحة لدورك")).toBeVisible();
    await openByRoom(page, go, "205", "confirmed");
    const vouchers = page.locator(".card").filter({ has: page.getByRole("heading", { name: "السندات" }) });
    await expect(vouchers.getByRole("button", { name: "تصحيح" }).first()).toBeVisible();
  });
});
