/** Plan 7.6: real screen interactions on desktop Chromium, Firefox and WebKit.
 * Uses only the reset-per-context demo store. Physical devices are tracked separately.
 * Descriptive names intentionally introduce no new acceptance-library prefix.
 */
import { test, expect, createReservation, financeCell } from "./fixtures";

test("cross-browser public reception changes branch and rejects a mismatched booking proof", async ({ page, go, errors }) => {
  await go("/reception");
  await expect(page.getByTestId("wa-qr")).toBeVisible();
  await expect(page.getByTestId("wa-open")).toHaveAttribute("href", /^https:\/\/wa\.me\//);
  await page.getByLabel("الفرع").selectOption({ label: "فرع جدة — الكورنيش" });
  await expect(page.getByTestId("wa-soon")).toBeVisible();
  await expect(page.getByTestId("wa-qr")).toHaveCount(0);

  await go("/booking/lookup");
  await page.getByPlaceholder("05xxxxxxxx").fill("0501110006");
  await page.getByRole("button", { name: "متابعة" }).click();
  await page.getByPlaceholder("رقم الحجز").fill("HMABC123");
  await page.getByRole("button", { name: "عرض حجوزاتي" }).click();
  await expect(page.getByText("لم نجد حجزًا بهذا الرقم على هذا الجوال.")).toBeVisible();
  await expect(page).toHaveURL(/#\/booking\/lookup/);
  // Correct proof then opens the matching seeded demo booking, not a dead-end form.
  await page.getByPlaceholder("رقم الحجز").fill("bk-4471029");
  await page.getByRole("button", { name: "عرض حجوزاتي" }).click();
  await expect(page).toHaveURL(/\/booking\/status\//);
  expect(errors).toEqual([]);
});

test("cross-browser reservation accepts Arabic-Indic money and keeps partial payment distinct", async ({ page, loginAs, errors }) => {
  await loginAs("owner");
  await createReservation(page, "ضيف اختبار المتصفح", "0509998811");
  const due = await financeCell(page, "المتبقي");
  expect(due).toBeGreaterThan(10);
  await page.getByRole("button", { name: "سند قبض إقامة" }).click();
  const dialog = page.getByRole("dialog");
  await dialog.locator("input[data-money]").first().fill("١٠");
  await dialog.getByRole("button", { name: "حفظ السند" }).click();
  await expect(dialog).toBeHidden();
  await expect.poll(() => financeCell(page, "المتبقي")).toBe(due - 10);
  await expect(page.getByText("دفع جزئي").first()).toBeVisible();
  await expect(page.locator("span", { hasText: /^مدفوع$/ })).toHaveCount(0);
  // Cancellation of an invoice preview must not issue an invoice.
  await page.getByRole("button", { name: "إنشاء فاتورة" }).click();
  await expect(dialog.getByTestId("invoice-preview-total")).toBeVisible();
  await dialog.getByRole("button", { name: "تجاهل" }).click();
  await expect(dialog).toBeHidden();
  await expect(page.getByTestId(/^invoice-INV-/)).toHaveCount(0);
  expect(errors).toEqual([]);
});

test("cross-browser housekeeping completes a task without gaining finance actions", async ({ page, loginAs, errors }) => {
  await loginAs("housekeeping");
  await expect(page).toHaveURL(/#\/staff\/housekeeping/);
  await page.getByRole("button", { name: "إتمام", exact: true }).first().click();
  const confirm = page.getByRole("button", { name: "لم تبدأ بعد — تأكيد الإتمام" });
  if (await confirm.count()) await confirm.first().click();
  const notice = page.locator("div.bg-success-500\\/10").first();
  await expect(notice).toContainText("تم الإتمام");
  await expect(notice).toContainText("الإشغال لا يتغير بالتنظيف");
  await page.getByRole("button", { name: "حالة الوحدات" }).click();
  await expect(page.getByText(/الحالة الحالية: (نظيفة|متسخة|قيد التنظيف)/).first()).toBeVisible();
  await expect(page.getByRole("button", { name: /تسجيل وصول|تسجيل مغادرة/ })).toHaveCount(0);
  expect(errors).toEqual([]);
});

test("cross-browser protected screen redirects anonymous users and login survives reload", async ({ page, go, loginAs, errors }) => {
  await go("/staff/reservations");
  await expect(page).toHaveURL(/#\/staff\/login/);
  await loginAs("supervisor");
  await go("/staff/reservations");
  await expect(page.locator("table tbody tr").first()).toBeVisible();
  await page.reload({ waitUntil: "networkidle" });
  await expect(page.locator("table tbody tr").first()).toBeVisible();
  await page.locator('[title="تسجيل الخروج"]:visible, [aria-label="تسجيل الخروج"]:visible').first().click();
  await expect(page).toHaveURL(/#\/staff\/login/);
  await go("/staff/reservations");
  await expect(page).toHaveURL(/#\/staff\/login/);
  expect(errors).toEqual([]);
});
