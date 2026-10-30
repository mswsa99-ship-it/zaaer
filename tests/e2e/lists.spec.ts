/**
 * Phase 6 screens (migration 0040, decisions 14, 28, 34, 35, 36, 43, 55) — test ids LE01–LE11, the UI facet of
 * tests/sql/lists_reports_tests.sql (LS, SV, CL, AL, VL, RP, TS, ST, CU) and the demo tests (DS).
 * Controls: G21 (no data outside the role), G25 (report and export match definition, filters and permissions — X09),
 * G26 (the usage report removes nothing), G27 (the screen shows the server's refusal).
 */
import { test, expect, createReservation } from "./fixtures";
import { readFileSync } from "node:fs";
import type { Download, Page } from "@playwright/test";
import { firstSheetRows } from "./helpers/xlsx";

/** The downloaded workbook's first sheet: the statement lines, a blank line, the header, the rows. */
async function workbook(download: Download) {
  const path = await download.path();
  const rows = firstSheetRows(new Uint8Array(readFileSync(path!)));
  const blank = rows.findIndex((r) => r.length === 0 || r.every((c) => c === ""));
  return { statement: rows.slice(0, blank).map((r) => r[0] ?? ""), header: rows[blank + 1] ?? [], data: rows.slice(blank + 2).filter((r) => r.some((c) => c !== "")) };
}
async function exportAll(page: Page, scope: "all" | "page" = "all") {
  await page.getByTestId("export-xlsx").first().click();
  const [download] = await Promise.all([page.waitForEvent("download"), page.getByTestId(`export-scope-${scope}`).click()]);
  return workbook(download);
}
/** The count a heading shows once the screen has settled (two equal reads 400 ms apart; a refresh in flight changes it). */
async function matching(page: Page, re: RegExp): Promise<number> {
  const read = async () => Number((await page.getByText(re).first().innerText()).match(re)![1]);
  let last = await read();
  for (let i = 0; i < 12; i++) { await page.waitForTimeout(400); const n = await read(); if (n === last) return n; last = n; }
  return last;
}

test.describe("Phase 6 — lists, calendar, log, ledger, reports, staff, usage", () => {
  test("LE01 the reservations list: every filter of the reference, the column picker, a saved view that opens by default", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/staff/reservations");
    const total = await matching(page, /(\d+) حجز مطابق/);
    expect(total).toBeGreaterThan(0);
    await page.getByTestId("toggle-advanced").click();
    await expect(page.getByTestId("advanced-filters")).toBeVisible();
    for (const label of ["الوصول من", "المغادرة من", "تاريخ الإنشاء من", "مقيم في يوم", "المصدر", "نوع الوحدة", "رقم الوحدة", "فرد / شركة", "الشركة", "نوع الإيجار", "حالة الدفع", "الهوية", "الوصول للوحدة", "المجموعة", "من يقبض", "الترتيب"]) await expect(page.getByLabel(label).first(), label).toBeVisible();
    // a status filter narrows the set and is said in words
    await page.getByLabel("الحالة").selectOption("confirmed");
    await expect(page.getByText(/الحالة: مؤكد/).first()).toBeVisible();
    const confirmed = await matching(page, /(\d+) حجز مطابق/);
    expect(confirmed).toBeLessThanOrEqual(total);
    await expect(page.locator("[data-testid=reservation-row]")).toHaveCount(Math.min(confirmed, 25));
    for (const row of await page.locator("[data-testid=reservation-row]").all()) await expect(row).toContainText("مؤكد");
    // the column picker adds the rent type and the amount collected
    await page.getByTestId("column-picker").click();
    await page.getByTestId("column-picker-menu").getByLabel("نوع الإيجار").check();
    await page.getByTestId("column-picker-menu").getByLabel("المحصّل").check();
    await page.getByTestId("column-picker-menu").getByText("إغلاق").click();
    await expect(page.locator("[data-testid=reservations-table] thead")).toContainText("نوع الإيجار");
    await expect(page.locator("[data-testid=reservations-table] thead")).toContainText("المحصّل");
    // the view is saved on the server as the default and opens with the page
    await page.getByTestId("save-view").click();
    await page.getByRole("dialog").getByRole("textbox").fill("المؤكدة");
    await page.getByRole("dialog").getByLabel(/اجعله العرض الافتراضي/).check();
    await page.getByRole("dialog").getByRole("button", { name: "حفظ" }).click();
    await expect(page.getByLabel("العروض المحفوظة")).toContainText("★ المؤكدة");
    await go("/staff/reservations");
    await expect(page.getByLabel("العروض المحفوظة")).toHaveValue(/.+/);
    await expect(page.getByText(/الحالة: مؤكد/).first()).toBeVisible();
    expect(await matching(page, /(\d+) حجز مطابق/)).toBe(confirmed);
    // another person has no such view
    await page.locator('[title="تسجيل الخروج"]:visible, [aria-label="تسجيل الخروج"]:visible').first().click();
    await loginAs("supervisor");
    await go("/staff/reservations");
    expect(await page.getByLabel("العروض المحفوظة").locator("option").count()).toBe(1);
    // removing the view archives it: the owner's list no longer offers it
    await page.locator('[title="تسجيل الخروج"]:visible, [aria-label="تسجيل الخروج"]:visible').first().click();
    await loginAs("owner");
    await go("/staff/reservations");
    await page.getByLabel("حذف العرض المحفوظ").click();
    await expect(page.getByLabel("العروض المحفوظة").locator("option")).toHaveCount(1);
  });

  test("LE02 / X09b the export of the list holds exactly the filtered set, read page after page, and says so in its first lines; the page scope says it is a page", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    // two more bookings so the set is longer than one page: «كل النتائج» has to read on past the page
    await createReservation(page, "ضيف تصدير أول", "0500110001", { pickRoom: false });
    await createReservation(page, "ضيف تصدير ثانٍ", "0500110002", { pickRoom: false });
    await go("/staff/reservations");
    await page.getByLabel("المفتوحة فقط").uncheck();
    const total = await matching(page, /(\d+) حجز مطابق/);
    expect(total).toBeGreaterThan(25);
    const all = await exportAll(page, "all");
    expect(all.statement[0]).toBe("الحجوزات");
    expect(all.statement[1]).toMatch(/^الفرع: .+/);
    expect(all.statement[3]).toBe("المرشحات: بلا مرشحات");
    expect(all.statement[4]).toBe(`النطاق: كل النتائج (${total})`);
    expect(all.header).toContain("رقم الحجز");
    expect(all.data.length).toBe(total);
    expect(new Set(all.data.map((r) => r[0])).size).toBe(total);   // every row once
    // a filter, then the page scope
    await page.getByLabel("الحالة").selectOption("cancelled");
    const cancelled = await matching(page, /(\d+) حجز مطابق/);
    const pageScope = await exportAll(page, "page");
    expect(pageScope.statement[3]).toContain("الحالة: ملغى");
    expect(pageScope.statement[4]).toBe(`النطاق: هذه الصفحة فقط (${Math.min(cancelled, 25)} من ${cancelled})`);
    expect(pageScope.data.length).toBe(Math.min(cancelled, 25));
    // the print document takes the same statement (the dialog itself cannot be asserted here)
    await expect(page.getByTestId("export-print")).toBeEnabled();
  });

  test("LE03 «تقويم الحجوزات»: the units against the days, each stay a bar that opens the booking; the type and floor filters", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await go("/staff/reservations");
    await page.getByTestId("open-calendar").click();
    await expect(page).toHaveURL(/view=calendar/);
    const cal = page.getByTestId("reservation-calendar");
    await expect(cal).toBeVisible();
    await expect(cal.locator("[data-today]")).toHaveCount(1);
    const rows = cal.locator("[data-testid=calendar-row]");
    const all = await rows.count();
    expect(all).toBeGreaterThan(5);
    const segs = cal.locator("[data-testid=calendar-segment]");
    expect(await segs.count()).toBeGreaterThan(0);
    // a type filter keeps a subset of the units
    const cat = page.getByTestId("filter-category");
    await cat.selectOption({ index: 1 });
    await expect.poll(() => rows.count()).toBeLessThan(all);
    await cat.selectOption("");
    await expect.poll(() => rows.count()).toBe(all);
    // the window moves and stays at most 62 days
    await page.getByRole("button", { name: "30 يومًا" }).click();
    await expect(cal.locator("[data-testid=calendar-row]").first()).toBeVisible();
    // a bar opens its booking
    const first = segs.first();
    const ref = await first.getAttribute("data-ref");
    await first.click();
    await page.waitForURL(/#\/staff\/reservations\/[0-9a-f-]+/);
    await expect(page.locator("main")).toContainText(ref!);
  });

  test("LE04 «سجل الإجراءات» reads in Arabic with filters and pages; security rows for the owner only; the export states its filters", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/staff");
    // a security event to find: the owner signs the supervisor out with a reason
    await page.locator("[data-testid=staff-card][data-email='reception@demo.sa']").getByTestId("staff-force-logout").click();
    await page.getByRole("dialog").getByRole("textbox").fill("اختبار السجل");
    await page.getByRole("dialog").getByRole("button", { name: "إنهاء الجلسات" }).click();
    await expect(page.getByTestId("staff-notice")).toBeVisible();
    await go("/admin/audit-logs");
    const table = page.getByTestId("audit-table");
    await expect(table).toBeVisible();
    await expect(table.locator("[data-testid=audit-action]").first()).not.toContainText(/^[a-z_.]+$/);
    await expect(table).toContainText("تسجيل خروج إجباري");
    await expect(table.locator("tr", { hasText: "تسجيل خروج إجباري" }).first()).toContainText("أمني");
    await expect(table.locator("tr", { hasText: "تسجيل خروج إجباري" }).first()).toContainText("اختبار السجل");
    // the action filter
    await page.getByLabel("الإجراء").selectOption("staff.signed_out");
    await expect(table.locator("[data-testid=audit-row]")).toHaveCount(1);
    await expect(page.getByText(/المرشحات: الإجراء: تسجيل خروج إجباري/)).toBeVisible();
    const wb = await exportAll(page, "all");
    expect(wb.statement[0]).toBe("سجل الإجراءات");
    expect(wb.statement[3]).toContain("الإجراء: تسجيل خروج إجباري");
    expect(wb.statement[4]).toBe("النطاق: كل النتائج (1)");
    expect(wb.data.length).toBe(1);
    expect(wb.data[0][1]).toBe("تسجيل خروج إجباري");
    // the row's detail shows the technical code and the masked details
    await table.locator("[data-testid=audit-row]").first().getByTestId("audit-action").click();   // the action cell: the row centre may land on «تتبّع» or «فقط هو»
    await expect(page.getByTestId("audit-detail")).toContainText("staff.signed_out");
    await page.getByTestId("audit-detail").getByLabel("إغلاق").click();
    // the supervisor: the same page without security rows and without the category filter
    await page.locator('[title="تسجيل الخروج"]:visible, [aria-label="تسجيل الخروج"]:visible').first().click();
    await loginAs("supervisor");
    await go("/admin/audit-logs");
    await expect(page.getByTestId("audit-table")).toBeVisible();
    await expect(page.getByLabel("الفئة")).toHaveCount(0);
    await page.getByLabel("الإجراء").selectOption("staff.signed_out");
    await expect(page.getByText("لا أحداث مطابقة")).toBeVisible();
  });

  test("LE05 / X09a the ledger: filters, totals over the whole set, and an export that holds exactly the matching vouchers", async ({ page, loginAs, go }) => {
    await loginAs("finance");
    await go("/admin/finance");
    await page.getByLabel("من", { exact: true }).fill("2020-01-01");
    const total = await matching(page, /السندات المطابقة: (\d+)/);
    expect(total).toBeGreaterThan(0);
    await expect(page.getByTestId("finance-totals")).toContainText("قبض إقامة");
    await page.getByLabel("الطريقة").selectOption("cash");
    const cash = await matching(page, /السندات المطابقة: (\d+)/);
    expect(cash).toBeLessThanOrEqual(total);
    for (const row of await page.locator("[data-testid=voucher-row]").all()) await expect(row).toContainText("نقد");
    const wb = await exportAll(page, "all");
    expect(wb.statement[0]).toBe("دفتر السندات");
    expect(wb.statement[3]).toContain("الطريقة: نقد");
    expect(wb.statement[4]).toBe(`النطاق: كل النتائج (${cash})`);
    expect(wb.data.length).toBe(cash + 1);   // the rows and the totals line
    expect(wb.data[wb.data.length - 1][0]).toMatch(/^الإجمالي/);
    // the cancelled are shown only when asked
    await page.getByLabel("الطريقة").selectOption("");
    await page.getByLabel("الحالة").selectOption("all");
    expect(await matching(page, /السندات المطابقة: (\d+)/)).toBeGreaterThanOrEqual(total);
  });

  test("LE06 / X09d the reports take the filters their data has: by staff member the collection rate is not claimed, by method the breakdown holds one method; the file carries the filters", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/reports");
    await expect(page.getByTestId("report-filters")).toBeVisible();
    await page.getByLabel("من", { exact: true }).fill("2020-01-01");
    await page.getByTestId("filter-method").selectOption("cash");
    await expect(page.getByTestId("report-filter-words")).toContainText("طريقة الدفع: نقد");
    await expect(page.getByText("مرشّح").first()).toBeVisible();
    await expect(page.getByTestId("finance-by-staff")).toBeVisible();
    await expect(page.locator(".card", { has: page.getByText("نسبة التحصيل (%)", { exact: true }) }).locator("p[dir=ltr]").first()).toHaveText("—");
    await expect(page.getByText(/لا تُحسب مع مرشح الموظف/).first()).toBeVisible();
    await page.getByTestId("filter-method").selectOption("");
    await page.getByTestId("filter-staff").selectOption({ index: 1 });
    await expect(page.getByTestId("report-filter-words")).toContainText("الموظف:");
    const [download] = await Promise.all([page.waitForEvent("download"), page.getByTestId("export-xlsx").first().click()]);
    const wb = await workbook(download);
    expect(wb.statement[0]).toBe("التقرير المالي");
    expect(wb.statement[3]).toContain("الموظف:");
    expect(wb.data.some((r) => r[0] === "صافي التحصيل")).toBe(true);
    // the discounts report takes the staff filter too and says «بعد الوصول» when asked
    await page.getByTestId("discounts-report").getByLabel("بعد الوصول فقط").check();
    await expect(page.getByTestId("discounts-report")).toBeVisible();
  });

  test("LE07 a task has a start (now by default) and an optional end; an end before the start is refused; both show in the list", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await go("/staff/housekeeping");
    await page.getByRole("button", { name: "مهمة جديدة" }).click();
    const dialog = page.getByRole("dialog");
    const start = await dialog.getByTestId("task-start").inputValue();
    expect(start).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/);
    await dialog.getByTestId("task-end-input").fill(start.slice(0, 11) + "00:00");
    await dialog.getByRole("button", { name: "إنشاء" }).click();
    await expect(dialog).toContainText("نهاية المهمة لا تسبق بدايتها");
    await dialog.getByTestId("task-end-input").fill(start.slice(0, 11) + "23:30");
    await dialog.getByRole("button", { name: "إنشاء" }).click();
    await expect(dialog).toBeHidden();
    await expect(page.getByTestId("task-end").first()).toContainText("النهاية");
    await expect(page.getByText(/البداية /).first()).toBeVisible();
  });

  test("LE08 «تعديل موظف»: the owner changes name, phone and branches with a reason; the log keeps before and after; activation with a reason; no one edits their own role", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/staff");
    const card = page.locator("[data-testid=staff-card][data-email='reception@demo.sa']");
    await card.getByTestId("staff-edit").click();
    const dialog = page.getByRole("dialog");
    await expect(dialog.getByRole("textbox", { disabled: true }).first()).toHaveValue("reception@demo.sa");
    await dialog.getByTestId("edit-name").fill("فهد الاستقبال (معدّل)");
    await dialog.getByTestId("edit-phone").fill("0500001234");
    const branchBoxes = dialog.getByTestId("edit-branches").getByRole("checkbox");
    const n = await branchBoxes.count();
    expect(n).toBeGreaterThan(1);
    await branchBoxes.nth(1).check();
    await dialog.getByRole("button", { name: "حفظ التعديل" }).click();
    await expect(dialog).toContainText("يجب كتابة سبب");
    await dialog.getByPlaceholder(/انتقل إلى فرع/).fill("انتقل إلى فرع آخر");
    await dialog.getByRole("button", { name: "حفظ التعديل" }).click();
    await expect(page.getByTestId("staff-notice")).toContainText("الاسم، الهاتف، الفروع");
    await expect(card).toContainText("فهد الاستقبال (معدّل)");
    await expect(card).toContainText("0500001234");
    // the owner's own role and branches are not editable
    await page.locator("[data-testid=staff-card][data-email='owner@demo.sa']").getByTestId("staff-edit").click();
    await expect(page.getByRole("dialog").getByTestId("edit-role")).toBeDisabled();
    await page.getByRole("dialog").getByLabel("إغلاق").click();
    // deactivate, then reactivate, with a reason each time
    await card.getByTestId("staff-toggle-active").click();
    await page.getByRole("dialog").getByRole("textbox").fill("إجازة طويلة");
    await page.getByRole("dialog").getByRole("button", { name: "إيقاف الحساب" }).click();
    await expect(card).toContainText("موقوف");
    await card.getByTestId("staff-toggle-active").click();
    await page.getByRole("dialog").getByRole("textbox").fill("عاد");
    await page.getByRole("dialog").getByRole("button", { name: "تفعيل الحساب" }).click();
    await expect(card).toContainText("نشط");
    // the log: one row for the edit with before and after, two for the activation
    await go("/admin/audit-logs");
    await page.getByLabel("الإجراء").selectOption("staff.updated");
    const row = page.locator("[data-testid=audit-row]").first();
    await expect(row).toContainText("تعديل بيانات موظف");
    await expect(row).toContainText("انتقل إلى فرع آخر");
    await row.click();
    const detail = page.getByTestId("audit-detail");
    await expect(detail).toContainText("فهد الاستقبال (معدّل)");
    await expect(detail).toContainText("••••1234");
    await expect(detail).not.toContainText("0500001234");
    await page.getByTestId("audit-detail").getByLabel("إغلاق").click();
    await page.getByLabel("الإجراء").selectOption("staff.deactivated");
    await expect(page.locator("[data-testid=audit-row]").first()).toContainText("إجازة طويلة");
  });

  test("LE09 «تسجيل خروج إجباري»: the supervisor's open tab is signed out on its next request and told why; the account stays active and signs in again", async ({ page, loginAs, go, context }) => {
    // tab A: the supervisor at work
    await loginAs("supervisor");
    await go("/staff/reservations");
    await expect(page.getByText(/حجز مطابق/)).toBeVisible();
    // tab B: the owner ends the supervisor's sessions with a reason
    const owner = await context.newPage();
    await owner.goto("/#/staff/login", { waitUntil: "networkidle" });
    await owner.getByRole("button", { name: "المالك — كل الصلاحيات" }).click();
    await owner.waitForURL(/#\/(staff|admin)\//);
    await owner.goto("/#/admin/staff", { waitUntil: "networkidle" });
    const card = owner.locator("[data-testid=staff-card][data-email='reception@demo.sa']");
    await card.getByTestId("staff-force-logout").click();
    await owner.getByRole("dialog").getByRole("textbox").fill("جهاز مفقود");
    await owner.getByRole("dialog").getByRole("button", { name: "إنهاء الجلسات" }).click();
    await expect(owner.getByTestId("staff-notice")).toContainText("أُنهيت جلسات");
    await expect(card).toContainText("نشط");
    await expect(card).toContainText("أُنهيت جلساته");
    // tab A: its next request is refused (the list refreshes when the store changes), the tab signs out and says so
    await page.bringToFront();
    const link = page.getByRole("link", { name: "لوحة الوحدات" }).first();
    if (await link.isVisible().catch(() => false)) await link.click({ timeout: 3_000 }).catch(() => undefined);
    await expect(page).toHaveURL(/#\/staff\/login/, { timeout: 20_000 });
    await expect(page.getByTestId("revoked-notice")).toBeVisible();
    // a fresh sign-in works: the account is active
    await page.getByRole("button", { name: "مشرف الاستقبال" }).click();
    await page.waitForURL(/#\/staff\//);
    await go("/staff/reservations");
    await expect(page.getByText(/حجز مطابق/)).toBeVisible();
    await owner.close();
  });

  test("LE10 «استعمال القدرات» for the owner: every capability with its status, the core mark, an honest «غير محسوم» where the log does not cover the window, and an export", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/usage");
    await expect(page.getByTestId("usage-table")).toBeVisible();
    const rows = page.locator("[data-testid=usage-row]");
    expect(await rows.count()).toBeGreaterThan(40);
    await expect(page.locator("[data-testid=usage-row][data-code='admin.facilities']")).toContainText("إدارة أساسية");
    await expect(page.locator("[data-testid=usage-row][data-code='screens.reports']")).toHaveAttribute("data-status", "unmeasured");
    await expect(page.locator("[data-testid=usage-row][data-code='reservations.create']")).toHaveAttribute("data-status", /used|undetermined/);
    await expect(page.getByTestId("usage-coverage")).toBeVisible();
    // no «غير مستخدم» while the log does not cover the window (the seed's log covers four weeks: then the never-used are idle)
    const covered = await page.getByTestId("usage-coverage").getAttribute("data-covered");
    const idle = await page.locator("[data-testid=usage-row][data-status='idle']").count();
    if (covered === "no") expect(idle).toBe(0); else expect(idle).toBeGreaterThan(0);
    await page.getByTestId("weeks-26").click();
    await expect(page.getByTestId("usage-coverage")).toHaveAttribute("data-covered", "no");
    await expect(page.locator("[data-testid=usage-row][data-status='idle']")).toHaveCount(0);
    await page.getByTestId("weeks-1").click();
    await expect(page.getByTestId("usage-summary")).toBeVisible();
    const [download] = await Promise.all([page.waitForEvent("download"), page.getByTestId("export-xlsx").first().click()]);
    const wb = await workbook(download);
    expect(wb.statement[0]).toBe("استعمال القدرات");
    expect(wb.data.length).toBeGreaterThan(40);
    // the manager has no such page
    await page.locator('[title="تسجيل الخروج"]:visible, [aria-label="تسجيل الخروج"]:visible').first().click();
    await loginAs("manager");
    await expect(page.getByRole("link", { name: "استعمال القدرات" })).toHaveCount(0);
  });

  test("LE11 the manager reads the staff list without phones, signs out a supervisor but not an owner, and cannot edit anyone", async ({ page, loginAs, go }) => {
    await loginAs("manager");
    await go("/admin/staff");
    await expect(page.getByTestId("staff-list")).toBeVisible();
    await expect(page.getByTestId("staff-edit")).toHaveCount(0);
    await expect(page.getByTestId("staff-toggle-active")).toHaveCount(0);
    await expect(page.locator("[data-testid=staff-card][data-email='owner@demo.sa']").getByTestId("staff-force-logout")).toHaveCount(0);
    await expect(page.locator("[data-testid=staff-card][data-email='manager@demo.sa']").getByTestId("staff-force-logout")).toHaveCount(0);
    const sup = page.locator("[data-testid=staff-card][data-email='reception@demo.sa']");
    await sup.getByTestId("staff-force-logout").click();
    await page.getByRole("dialog").getByRole("textbox").fill("مناوبة انتهت");
    await page.getByRole("dialog").getByRole("button", { name: "إنهاء الجلسات" }).click();
    await expect(page.getByTestId("staff-notice")).toContainText("أُنهيت جلسات");
    await expect(page.locator("main")).not.toContainText("+9665");
  });
});
