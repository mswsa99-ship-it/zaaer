/**
 * «الرموز» — the key-box codes of the units, changed after every departure (acceptance C01–C06).
 * Controls: a unit turns red the moment its guest leaves and stays red — with an alert on every staff page — until a
 * new code is saved; the same code is refused; housekeeping never sees or changes the code of a unit with a guest in
 * house; finance has no access. Server rules: migration 0025 (tests/sql/keybox_codes_tests.sql); the demo mirrors
 * them (tests/unit/keybox_codes_demo.test.ts).
 */
import { test, expect } from "./fixtures";

const unit = (page: import("@playwright/test").Page, room: string) => page.locator(`[data-testid="code-unit"][data-room="${room}"]`);

test.describe("«الرموز» — key-box codes", () => {
  test("C01 housekeeping: the red alert leads to «الرموز»; the same code is refused; a new tested code turns the unit green", async ({ page, loginAs }) => {
    await loginAs("housekeeping");
    const alert = page.getByTestId("keybox-alert");
    await expect(alert).toBeVisible();
    await expect(alert).toContainText("تغيير رمز الصندوق");
    await alert.click();
    await expect(page).toHaveURL(/#\/staff\/codes/);

    const reds = page.locator('[data-testid="code-unit"][data-state="change"]');
    await expect(reds.first()).toBeVisible();
    const before = await reds.count();
    const room = (await reds.first().getAttribute("data-room"))!;
    const card = unit(page, room);

    await card.getByRole("button", { name: "إظهار الرمز" }).click();
    await expect(card.getByTestId("shown-code")).toHaveText(/^\d{4,8}$/);
    const old = (await card.getByTestId("shown-code").textContent())!.trim();

    await card.getByRole("button", { name: "تغيير الرمز" }).click();
    const form = card.getByTestId("code-form");
    await form.getByLabel("الرمز الجديد", { exact: true }).fill(old);
    await form.getByLabel("تأكيد الرمز", { exact: true }).fill(old);
    await form.getByRole("checkbox").check();
    await form.getByRole("button", { name: "حفظ الرمز" }).click();
    await expect(form).toContainText("هذا هو الرمز الحالي نفسه");
    await expect(card).toHaveAttribute("data-state", "change");

    const fresh = old === "7391" ? "7392" : "7391";
    await form.getByLabel("الرمز الجديد", { exact: true }).fill(fresh);
    await form.getByLabel("تأكيد الرمز", { exact: true }).fill(fresh);
    await form.getByRole("button", { name: "حفظ الرمز" }).click();
    await expect(page.getByRole("status").filter({ hasText: `تم حفظ الرمز الجديد لوحدة ${room}` })).toBeVisible();
    await expect(card).toHaveAttribute("data-state", "ok");
    await expect(reds).toHaveCount(before - 1);

    // the alert on the other pages follows at once
    await page.goto("/#/staff/housekeeping", { waitUntil: "networkidle" });
    if (before === 1) await expect(page.getByTestId("keybox-alert")).toHaveCount(0);
    else await expect(page.getByTestId("keybox-alert")).not.toContainText(room);
  });

  test("C02 housekeeping cannot see or change the code of a unit with a guest in house", async ({ page, loginAs, go }) => {
    await loginAs("housekeeping");
    await go("/staff/codes");
    const occupied = page.locator('[data-testid="code-unit"]').filter({ hasText: "فيها نزيل مقيم — رمزها لا يُعرض ولا يُغيَّر من حسابك." }).first();
    await expect(occupied).toBeVisible();
    await expect(occupied.getByRole("button")).toHaveCount(0);
  });

  test("C03 the supervisor can see the code of a unit with a guest in house", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await go("/staff/codes");
    const occupied = page.locator('[data-testid="code-unit"]').filter({ hasText: "فيها نزيل مقيم." }).first();
    await expect(occupied).toBeVisible();
    await occupied.getByRole("button", { name: "إظهار الرمز" }).click();
    await expect(occupied.getByTestId("shown-code")).toHaveText(/^\d{4,8}$/);
    await occupied.getByRole("button", { name: "إخفاء" }).click();
    await expect(occupied.getByTestId("shown-code")).toHaveCount(0);
  });

  test("C04 a check-out turns the unit red at once — on «الرموز» and in the alert on every page", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/staff/reservations");
    await page.locator("select").filter({ has: page.locator('option[value="checked_in"]') }).selectOption("checked_in");
    const row = page.locator("table tbody tr").first();
    await expect(row).toBeVisible();
    await expect(row).toContainText("تم الدخول");
    const room = (await row.locator("td").nth(2).innerText()).split("\n")[0].trim();
    await row.getByRole("link", { name: "فتح" }).click();

    await page.getByRole("button", { name: "تأكيد المغادرة", exact: true }).click();
    const override = page.getByRole("button", { name: "تأكيد المغادرة مع التجاوز" });
    await expect(override.or(page.getByText("تمت المغادرة").first())).toBeVisible();
    if (await override.isVisible()) {
      await page.getByPlaceholder("يُسجل السبب في سجل العمليات").fill("اختبار الرموز بعد المغادرة");
      await override.click();
    }
    await expect(page.getByRole("button", { name: "تأكيد المغادرة", exact: true })).toHaveCount(0);

    await go("/staff/codes");
    await expect(unit(page, room)).toHaveAttribute("data-state", "change");
    await expect(unit(page, room)).toContainText("يجب تغيير الرمز بعد خروج النزيل");
    await go("/staff/dashboard");
    await expect(page.getByTestId("keybox-alert")).toContainText(room);
  });

  test("C05 finance has no codes: no link, no alert, and the page is refused", async ({ page, loginAs, go }) => {
    await loginAs("finance");
    await go("/staff/dashboard");
    await expect(page.getByRole("link", { name: /^الرموز/ })).toHaveCount(0);
    await expect(page.getByTestId("keybox-alert")).toHaveCount(0);
    await go("/staff/codes");
    await expect(page.getByText("هذه الصفحة غير متاحة لدورك")).toBeVisible();
  });

  test("C06 the old key-box address leads to «الرموز»", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/keyboxes");
    await expect(page).toHaveURL(/#\/staff\/codes/);
    await expect(page.locator("main h2")).toHaveText("الرموز");
  });
});
