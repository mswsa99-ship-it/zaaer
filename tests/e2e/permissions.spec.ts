/**
 * «مصفوفة الصلاحيات» (decision 71, migration 0043) — test ids PE01–PE05, the screen facet of tests/sql/permissions_tests.sql
 * (PM) and the demo tests (MX). Controls: G01/G02 (the server decides; the screen follows), G21 (no page outside the
 * matrix), G22 (one audit row with the reason).
 */
import { test, expect } from "./fixtures";
import { readFileSync } from "node:fs";
import type { Page } from "@playwright/test";
import { firstSheetRows } from "./helpers/xlsx";

const cell = (page: Page, code: string, role: string) => page.locator(`[data-testid=perm-cell][data-code='${code}'][data-role='${role}']`);
async function save(page: Page, reason: string) {
  await page.getByTestId("perm-save").click();
  await page.getByRole("dialog").getByRole("textbox").fill(reason);
  await page.getByRole("dialog").getByRole("button", { name: "حفظ" }).click();
  await expect(page.getByTestId("perm-notice")).toContainText("حُفظ");
}
/** the demo keeps one session per browser: sign out, then in as another role (same tab) */
async function signInAs(page: Page, button: string) {
  const out = page.locator('[title="تسجيل الخروج"]:visible, [aria-label="تسجيل الخروج"]:visible').first();
  if (await out.isVisible().catch(() => false)) { await out.click(); await page.waitForURL(/#\/staff\/login/, { timeout: 15_000 }); }
  await page.goto("/#/staff/login", { waitUntil: "networkidle" });
  await page.getByRole("button", { name: button }).click();
  await page.waitForURL(/#\/(staff|admin)\//, { timeout: 15_000 });
  await page.waitForTimeout(300);
}

test.describe("«مصفوفة الصلاحيات» — the owner edits the approved matrix", () => {
  test("PE01 the owner opens the matrix: every operation, the owner's column fixed, the matrix row locked, the approved state said, an export", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/dashboard");
    await page.getByRole("link", { name: "مصفوفة الصلاحيات" }).first().click();
    await expect(page.getByTestId("perm-matrix")).toBeVisible();
    await expect(page.locator("[data-testid=perm-row]")).toHaveCount(55);
    await expect(page.getByTestId("perm-changed-count")).toHaveText("مطابقة للمصفوفة المعتمدة");
    await expect(cell(page, "res.create", "owner")).toBeChecked();
    await expect(cell(page, "res.create", "owner")).toBeDisabled();
    await expect(cell(page, "admin.permissions", "manager")).toBeDisabled();
    await expect(cell(page, "res.create", "supervisor")).toBeChecked();
    await expect(cell(page, "res.create", "finance")).not.toBeChecked();
    await expect(page.locator("[data-testid=perm-row][data-code='voucher.correct']")).toContainText("سنداته خلال 24 ساعة");
    const [download] = await Promise.all([page.waitForEvent("download"), page.getByTestId("export-xlsx").first().click()]);
    const rows = firstSheetRows(new Uint8Array(readFileSync((await download.path())!)));
    expect(rows[0][0]).toBe("مصفوفة الصلاحيات");
    const blank = rows.findIndex((r) => r.length === 0 || r.every((c) => c === ""));
    expect(rows.slice(blank + 2).filter((r) => r.some((c) => c !== "")).length).toBe(55);
  });

  test("PE02 unticking «إنشاء حجز» for the supervisor takes effect at their next operation; «استعادة المصفوفة المعتمدة» gives it back", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/roles");
    await cell(page, "res.create", "supervisor").uncheck();
    await expect(page.getByTestId("perm-draft-count")).toHaveText("1 تغيير غير محفوظ");
    await save(page, "المشرف لا ينشئ الحجوزات مؤقتًا");
    await expect(page.getByTestId("perm-changed-count")).toHaveText("1 خانة تختلف عن المصفوفة المعتمدة");
    await expect(page.getByTestId("perm-last-change")).toContainText("المشرف لا ينشئ الحجوزات مؤقتًا");
    // the supervisor: the page is closed to them
    await signInAs(page, "مشرف الاستقبال");
    await go("/staff/reservations/new");
    await expect(page.getByText("هذه الصفحة غير متاحة لدورك")).toBeVisible();
    // the owner restores the approved matrix
    await signInAs(page, "المالك — كل الصلاحيات");
    await go("/admin/roles");
    await page.getByTestId("perm-reset").click();
    await page.getByRole("dialog").getByRole("textbox").fill("العودة إلى المعتمدة");
    await page.getByRole("dialog").getByRole("button", { name: "استعادة" }).click();
    await expect(page.getByTestId("perm-notice")).toContainText("عادت 1 خانة");
    await expect(page.getByTestId("perm-changed-count")).toHaveText("مطابقة للمصفوفة المعتمدة");
    // the supervisor opens it again
    await signInAs(page, "مشرف الاستقبال");
    await go("/staff/reservations/new");
    await expect(page.getByText("هذه الصفحة غير متاحة لدورك")).toHaveCount(0);
  });

  test("PE03 ticking a cell opens the page and its link: finance given «الوحدات والأنواع…» sees «الوحدات» in the administration", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/roles");
    await cell(page, "definitions", "finance").check();
    await save(page, "المالية تراجع الوحدات");
    await signInAs(page, "المالية");
    await go("/admin/finance");
    await expect(page.getByRole("link", { name: "الوحدات" }).first()).toBeVisible();
    await go("/admin/rooms");
    await expect(page.getByText("هذه الصفحة غير متاحة لدورك")).toHaveCount(0);
  });

  test("PE04 the matrix is the owner's alone: the manager has no link to it and the page is closed", async ({ page, loginAs, go }) => {
    await loginAs("manager");
    await go("/admin/dashboard");
    await expect(page.getByRole("link", { name: "مصفوفة الصلاحيات" })).toHaveCount(0);
    await go("/admin/roles");
    await expect(page.getByText("هذه الصفحة غير متاحة لدورك")).toBeVisible();
  });

  test("PE05 every save is one row in the log, in the security category, with the reason", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/roles");
    await cell(page, "maintenance.create", "finance").check();
    await cell(page, "guest.rate", "supervisor").uncheck();
    await expect(page.getByTestId("perm-draft-count")).toHaveText("2 تغيير غير محفوظ");
    await page.getByTestId("perm-save").click();
    await expect(page.getByTestId("perm-review")).toContainText("يُسمح لـمالية");
    await expect(page.getByTestId("perm-review")).toContainText("يُمنع لـمشرف استقبال");
    await page.getByRole("dialog").getByRole("textbox").fill("توزيع جديد للعمل");
    await page.getByRole("dialog").getByRole("button", { name: "حفظ" }).click();
    await expect(page.getByTestId("perm-notice")).toContainText("حُفظ 2 تغيير");
    await go("/admin/audit-logs");
    const row = page.getByTestId("audit-table").locator("tr", { hasText: "تعديل مصفوفة الصلاحيات" }).first();
    await expect(row).toBeVisible();
    await expect(row).toContainText("أمني");
    await expect(row).toContainText("توزيع جديد للعمل");
  });
});
