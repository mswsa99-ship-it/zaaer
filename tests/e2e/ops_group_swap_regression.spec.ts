/**
 * Ops regression (tests only, demo store): group units are independent, and the unit swap keeps the price of a
 * resident stay and refuses a swap on the checkout day. Demo logic, not server behavior.
 */
import { test, expect, bookingNext, fillGuest, checkOut } from "./fixtures";
import type { Page } from "@playwright/test";

async function openSwap(page: Page, go: (p: string) => Promise<void>, ref: string) {
  await go("/staff/reservations");
  await page.locator("tbody tr", { hasText: ref }).getByRole("link").first().click();
  await page.getByRole("button", { name: "الإقامة", exact: true }).click();
  await page.getByRole("button", { name: "تبديل الوحدة" }).click();
  const d = page.getByRole("dialog");
  await d.locator("select").selectOption({ label: "205 · شقة بغرفتين · نظيفة" });
  await d.locator("input,textarea").last().fill("اختبار تبديل");
  return d;
}

test("OPS-SW1 checkout-day swap: warning shown, button stays enabled, server refuses with the period message", async ({ page, loginAs, go }) => {
  await loginAs("owner");
  const d = await openSwap(page, go, "R-26A0003");
  await expect(d.getByText(/يجب أن يسبق تاريخ المغادرة/)).toBeVisible();
  await expect(d.getByRole("button", { name: "تبديل", exact: true })).toBeEnabled();
  await d.getByRole("button", { name: "تبديل", exact: true }).click();
  await expect(page.getByText("تاريخ التبديل خارج فترة الإقامة")).toBeVisible();
});

test("OPS-SW2 resident swap keeps the price: total, paid and remaining are unchanged", async ({ page, loginAs, go }) => {
  await loginAs("owner");
  const d = await openSwap(page, go, "R-26A0002");
  await expect(d.getByText(/قبل الوصول يُعاد تسعير الليالي/)).toBeVisible();
  await d.getByRole("button", { name: "تبديل", exact: true }).click();
  await expect(d).toBeHidden();
  const amounts = page.getByTestId("stay-amounts");
  await expect(amounts).toContainText("750.00");
  await expect(amounts).toContainText("0.00");
  await expect(page.getByText("وحدة 205")).toBeVisible();
});

test("OPS-GR1 group of two units: each unit checks in and out on its own; the other keeps its status; totals are the sum", async ({ page, loginAs }) => {
  await loginAs("supervisor");
  await page.goto("/#/staff/reservations/new", { waitUntil: "networkidle" });
  await page.getByRole("button", { name: "وحدة أخرى في نفس الحجز" }).click();
  await bookingNext(page); await fillGuest(page, "عائلة المجموعة", "0501110009"); await bookingNext(page);
  await page.getByRole("button", { name: "إنشاء 2 حجوزات" }).click();
  await page.waitForURL(/#\/staff\/reservations\/[0-9a-f-]+/, { timeout: 15000 });
  const panel = page.locator("table").filter({ hasText: "الإجمالي (وحدتان)" });
  await expect(panel).toContainText("مؤكد");
  await expect(panel).not.toContainText("confirmed");
  await page.getByRole("button", { name: "اختيار وحدة" }).first().click();
  await page.locator("main select").filter({ has: page.locator("option", { hasText: /\d{3}|U-/ }) }).first().selectOption({ index: 1 });
  await page.getByRole("button", { name: "تخصيص الوحدة" }).click();
  const arrival = page.getByTestId("arrival");
  await expect(arrival).toContainText("لم تُعتمد مطابقة الهوية لجميع النزلاء");
  await page.getByTestId(/^office-enter-/).first().click();
  const dlg = page.getByRole("dialog");
  await dlg.getByLabel("الاسم الثلاثي").fill("عائلة المجموعة تجريبي");
  await dlg.getByLabel("رقم الوثيقة", { exact: true }).fill("1000000008");
  await dlg.getByLabel("تاريخ الميلاد").fill("1990-01-01");
  await dlg.getByLabel("طابقتُ الوثيقة الأصلية").check();
  await dlg.getByRole("button", { name: "حفظ واعتماد" }).click();
  await expect(dlg).toBeHidden();
  await expect(arrival).not.toContainText("لم تُعتمد مطابقة الهوية");
  await page.getByLabel("رقم التسجيل في شموس").fill("SH-1001");
  await page.getByLabel(/سُجِّل جميع النزلاء والمرافقين/).check();
  await page.getByRole("button", { name: "تسجيل شموس", exact: true }).click();
  await page.getByRole("button", { name: "تأكيد قبول شموس للتسجيل" }).click();
  await expect(arrival).toContainText("الشروط الثابتة مكتملة");
  const rent = arrival.locator("fieldset").filter({ hasText: "سند قبض الإيجار" }), dep = arrival.locator("fieldset").filter({ hasText: "سند قبض التأمين" });
  await rent.locator("input[data-money]").fill("300"); await rent.getByLabel(/استلمت المبلغ/).check();
  await dep.locator("input[data-money]").fill("50"); await dep.getByLabel(/استلمت المبلغ/).check();
  await arrival.getByRole("button", { name: "تسجيل الوصول" }).click();
  await expect(page.getByTestId("stay-notice")).toContainText("سُجِّل الوصول");
  const rows = panel.locator("tbody tr");
  await expect(rows.filter({ hasText: "مقيم" })).toHaveCount(1);
  await expect(rows.filter({ hasText: "مؤكد" })).toHaveCount(1);
  await expect(panel.locator("tfoot")).toContainText("600.00");
  // the other unit is untouched: still waits for a unit and its own checks
  await panel.getByRole("link").click();
  await expect(page.locator("main")).toContainText("الخطوة التالية: تخصيص وحدة");
  await expect(page.getByTestId("arrival")).toContainText("لم تُعتمد مطابقة الهوية لجميع النزلاء");
  // check the first unit out: it leaves, the other stays confirmed
  await panel.getByRole("link").click();
  await checkOut(page);
  await expect(rows.filter({ hasText: "غادر" })).toHaveCount(1);
  await expect(rows.filter({ hasText: "مؤكد" })).toHaveCount(1);
  await expect(panel.locator("tfoot")).toContainText("600.00");
});
