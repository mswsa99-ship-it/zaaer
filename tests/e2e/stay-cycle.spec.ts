/**
 * The stay cycle through the staff and guest UI (Phase 3, migration 0033) — test ids SU01–SU07, the UI facet of
 * tests/sql/stay_cycle_tests.sql (SC) and the demo tests in tests/unit/demo-invariants.test.ts (SD).
 * Controls: G08 (the arrival, the code and the departure are separate states with fixed conditions), G10 (a part of the
 * first night is not the first night; nothing owed at departure), G11 (the deposit is separate and goes back after the
 * inspection), G17 (resources with commitments), G19 (corrections only within their windows), G22 (each step audited
 * with who and when), G27 (the screen shows the server's refusal, never a fake success).
 */
import { test, expect, financeCell } from "./fixtures";
import type { Page } from "@playwright/test";

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

test.describe("the stay cycle (phase 3)", () => {
  test("SU01 the arrival waits for the deposit or its reason, records it on its own voucher, and the code is its own step after it", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await openByRoom(page, go, "203", "confirmed");
    const arrival = page.getByTestId("arrival");
    await expect(arrival).toContainText("الشروط الثابتة مكتملة");
    const deposit = arrival.locator("fieldset").filter({ hasText: "سند قبض التأمين" });
    // no deposit and no reason: the server refuses, and nothing is recorded
    await deposit.locator("input[type=number]").fill("0");
    await arrival.getByRole("button", { name: "تسجيل الوصول" }).click();
    await expect(page.getByTestId("reasons").first()).toContainText("التأمين لم يُستلم كاملًا");
    await expect(arrival).toBeVisible();
    // the branch's deposit, on its own voucher
    await deposit.locator("input[type=number]").fill("50");
    await arrival.getByRole("button", { name: "تسجيل الوصول" }).click();
    await expect(page.getByTestId("stay-notice")).toContainText("سُجِّل الوصول");
    await expect.poll(() => financeCell(page, "رصيد التأمين")).toBe(50);
    // the code: after the arrival, once, said by the supervisor
    const inHouse = page.getByTestId("in-house");
    await inHouse.getByRole("radio", { name: "شفهيًا عبر المشرف" }).click();
    await inHouse.getByRole("button", { name: "تسليم رمز الصندوق" }).click();
    await expect(page.getByTestId("revealed-code")).toHaveText(/^\d{4,8}$/);
    await page.getByRole("button", { name: "تم التسليم شفهيًا" }).click();
    await expect(inHouse).toContainText("سُلِّم رمز الصندوق لهذا النزيل");
    await expect(page.getByTestId("revealed-code")).toHaveCount(0);
  });

  test("SU02 a night unpaid past its deadline stops the extension until it is paid or a reason lets the stay go on", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await openByRoom(page, go, "101", "checked_in");
    await expect(page.getByTestId("overdue")).toContainText("ليلة غير مدفوعة بعد موعدها");
    const extend = async () => {
      await page.getByRole("button", { name: "الإقامة", exact: true }).click();
      await page.getByRole("button", { name: "تغيير المغادرة / تمديد" }).click();
      const dlg = page.getByRole("dialog");
      const date = dlg.locator("input[type=date]");
      const d = new Date((await date.inputValue()) + "T00:00:00Z");
      d.setUTCDate(d.getUTCDate() + 1);
      await date.fill(d.toISOString().slice(0, 10));
      await dlg.locator("textarea").fill("طلب الضيف ليلة إضافية");
      await dlg.getByRole("button", { name: "تطبيق" }).click();
      return dlg;
    };
    let dlg = await extend();
    await expect(dlg.getByText(/ليلة لم تُدفع بعد موعدها/)).toBeVisible();
    await dlg.getByRole("button", { name: "إلغاء" }).click();
    // the reason that lets the stay go on: kept with who and when; the amount stays owed
    await page.getByTestId("in-house").getByRole("button", { name: "تسجيل سبب الاستمرار" }).click();
    const reason = page.getByRole("dialog");
    await reason.locator("textarea").fill("وعد بالسداد مساءً");
    await reason.getByRole("button", { name: "تأكيد" }).click();
    await expect(reason).toBeHidden();
    await expect(page.getByTestId("overdue")).toContainText("سُجِّل سبب يسمح بالاستمرار");
    await expect(page.getByTestId("in-house")).toContainText("سبب الاستمرار: وعد بالسداد مساءً");
    dlg = await extend();
    await expect(dlg).toBeHidden();
  });

  test("SU03 the departure only with nothing owed; then the inspection, the deposit back, the invoice — and «مغلق» by itself", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await openByRoom(page, go, "201", "checked_in");
    const inHouse = page.getByTestId("in-house");
    await inHouse.getByRole("button", { name: "تسجيل المغادرة" }).click();
    await expect(page.getByTestId("reasons").first()).toContainText("على الحجز مبلغ مستحق");
    await expect(inHouse).toBeVisible();
    // pay what is owed (the receipt suggests the balance)
    await page.getByRole("button", { name: "سند قبض إقامة" }).click();
    const pay = page.getByRole("dialog");
    await pay.getByRole("button", { name: "حفظ السند" }).click();
    await expect(pay).toBeHidden();
    await expect.poll(() => financeCell(page, "المتبقي")).toBe(0);
    await inHouse.getByRole("button", { name: "تسجيل المغادرة" }).click();
    const departed = page.getByTestId("departed");
    await expect(departed).toContainText("غادر ولم يُغلق");
    await expect(departed).toContainText("سجّل فحص المغادرة أولًا");
    // the inspection, then the supervisor returns the deposit
    await departed.getByRole("button", { name: "حفظ الفحص" }).click();
    await expect(departed.getByTestId("inspection")).toContainText("الوحدة سليمة");
    await page.getByRole("button", { name: "رد تأمين" }).click();
    const back = page.getByRole("dialog");
    await back.locator("textarea").fill("إرجاع التأمين بعد الفحص");
    await back.getByRole("button", { name: "تنفيذ" }).click();
    await expect(back).toBeHidden();
    await expect.poll(() => financeCell(page, "رصيد التأمين")).toBe(0);
    // the invoice: the last thing missing — the stay closes by itself
    await page.getByRole("button", { name: "إصدار فاتورة" }).click();
    const inv = page.getByRole("dialog");
    await inv.getByRole("button", { name: "إصدار", exact: true }).click();
    await expect(inv).toBeHidden();
    await expect(page.getByTestId("departed")).toContainText("أُغلقت الإقامة");
  });

  test("SU04 housekeeping inspects a departure from its cleaning task; the supervisor sees the notes and the suggested deduction", async ({ page, loginAs, go }) => {
    await loginAs("housekeeping");
    const task = page.locator(".card").filter({ hasText: "وحدة 206" }).filter({ has: page.getByRole("button", { name: "فحص المغادرة" }) }).first();
    await expect(task).toBeVisible();
    await task.getByRole("button", { name: "فحص المغادرة" }).click();
    const dlg = page.getByRole("dialog");
    await dlg.getByRole("radio", { name: "بملاحظات" }).click();
    await dlg.locator("textarea").fill("كسر في مقبض الخزانة");
    await dlg.locator("input[type=number]").fill("20");
    await dlg.getByRole("button", { name: "حفظ الفحص" }).click();
    await expect(dlg).toBeHidden();
    await expect(page.locator(".card").filter({ hasText: "وحدة 206" }).first()).toContainText("فُحصت المغادرة: بملاحظات");
    await signOut(page);
    await loginAs("supervisor");
    await openByRoom(page, go, "206", "checked_out");
    const inspection = page.getByTestId("inspection");
    await expect(inspection).toContainText("بملاحظات: كسر في مقبض الخزانة");
    await expect(inspection).toContainText("خصم مقترح من التأمين");
    await expect(page.getByTestId("departed")).not.toContainText("سجّل فحص المغادرة أولًا");
  });

  test("SU05 a late check-out service moves the departure to its hour, which comes after the branch's check-out time", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/services");
    const card = page.locator(".card").filter({ hasText: "مغادرة متأخرة حتى 4 عصرًا" }).first();
    await expect(card).toContainText("تنقل المغادرة إلى الساعة");
    await card.getByRole("button").first().click();
    const dlg = page.getByRole("dialog");
    const hour = dlg.getByLabel("مغادرة متأخرة حتى الساعة");
    await expect(hour).toHaveValue("16:00");
    await hour.fill("11:00");
    await dlg.getByRole("button", { name: "حفظ", exact: true }).click();
    await expect(dlg.getByText("ساعة المغادرة المتأخرة تكون بعد موعد المغادرة في الفرع.")).toBeVisible();
    await dlg.getByRole("button", { name: "إلغاء", exact: true }).click();
    // a guest in house takes it: the departure hour of the stay moves
    await openByRoom(page, go, "104", "checked_in");
    await expect(page.getByTestId("in-house")).toContainText("المغادرة الساعة 12:00");
    await page.getByRole("button", { name: "إضافة خدمة" }).click();
    const add = page.getByRole("dialog");
    const value = await add.locator("option", { hasText: "مغادرة متأخرة" }).first().getAttribute("value");
    await add.locator("select").selectOption(value!);
    await expect(add).toContainText("ينتقل موعد مغادرة هذه الإقامة إلى الساعة");
    await add.getByRole("button", { name: "إضافة", exact: true }).click();
    await expect(add).toBeHidden();
    await expect(page.getByTestId("in-house")).toContainText("المغادرة الساعة 16:00 (مغادرة متأخرة)");
  });

  test("SU06 the day's follow-up lists the overdue nights, the departures not closed and the late departures; the supervisor's day is their own", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await go("/staff/followups");
    await expect(page.getByTestId("followups-overdue")).toContainText("وحدة 101");
    await expect(page.getByTestId("followups-departed")).toContainText("وحدة 206");
    await expect(page.getByTestId("followups-late")).toContainText("وحدة 204");
    await page.getByTestId("followups-departed").getByText(/وحدة 206/).click();
    await expect(page.getByTestId("departed")).toContainText("غادر ولم يُغلق");
    await go("/staff/day-summary");
    await expect(page.getByText("تظهر هنا سنداتك أنت")).toBeVisible();
    await expect(page.getByTestId("day-summary")).toContainText("فهد الاستقبال");
    await go("/staff/dashboard");
    await expect(page.getByTestId("followups-banner")).toContainText("غادر ولم يُغلق");
  });

  test("SU07 the guest's page: the arrival at reception first, then the code — or, in the annex, the key", async ({ page, go }) => {
    const open = async (phone: string, ref: string) => {
      // «حجوزاتي» keeps a verified phone's list for the tab; another guest starts from the phone
      await page.evaluate(() => { try { sessionStorage.removeItem("guest_phone_session"); } catch { /* storage blocked */ } });
      await go("/booking/lookup");
      await page.getByPlaceholder("05xxxxxxxx").fill(phone);
      await page.getByRole("button", { name: "متابعة" }).click();
      await page.getByPlaceholder("رقم الحجز").fill(ref);
      await page.getByRole("button", { name: "عرض حجوزاتي" }).click();
      await expect(page).toHaveURL(/\/booking\/status\//);
    };
    await open("0501110008", "R-26A0008");   // arriving today, the first night paid
    await expect(page.getByText("تسجيل الوصول في الاستقبال")).toBeVisible();
    await expect(page.getByText("عند وصولك: التسجيل في شموس والتأمين في الاستقبال")).toBeVisible();
    await expect(page.getByText("قبل تسجيل الوصول:")).toBeVisible();
    await expect(page.getByText("رمز صندوق المفتاح")).toBeVisible();
    await open("0501110005", "R-26A0005");   // in house in the annex: no key box
    await expect(page.getByText("مفتاح الوحدة")).toBeVisible();
    await expect(page.getByText("يُسلَّم في الاستقبال", { exact: true })).toBeVisible();
    await expect(page.getByText("قبل تسليم الرمز:")).toHaveCount(0);
  });
});
