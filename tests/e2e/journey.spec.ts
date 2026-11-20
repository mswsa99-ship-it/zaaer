/**
 * The guest journey after the stay through the UI (0070–0072, W3–W7) — the UI facet of tests/sql/journey_tests.sql,
 * guides_w7_tests.sql and purge_trial_tests.sql, and of the WhatsApp tests in tests/unit/journey.test.ts. The browser's
 * clock is set to a day of departure, so the demo's seed (and the journey's clock) are the same every run.
 */
import { test, expect } from "./fixtures";
import type { Page } from "@playwright/test";

const DAY = "2026-11-15";
const at = (hm: string) => new Date(`${DAY}T${hm}:00+03:00`);
const PNG = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=", "base64");

async function signOut(page: Page) {
  await page.locator('[title="تسجيل الخروج"]:visible, [aria-label="تسجيل الخروج"]:visible').first().click();
  await expect(page).toHaveURL(/#\/staff\/login/);
}
/** the stay's reference of a unit leaving today, as the reception sees it in «رحلة الضيف» */
async function departingRef(page: Page, go: (p: string) => Promise<void>, room: string) {
  await go("/staff/journey");
  const row = page.getByTestId("journey-departing-row").filter({ hasText: `غرفة ${room}` });
  await expect(row).toBeVisible();
  return (await row.locator("a").first().innerText()).trim();
}
/** the guest opens their booking from «حجوزاتي» (the number on the booking, then its reference) */
async function openAsGuest(page: Page, go: (p: string) => Promise<void>, phone: string, ref: string) {
  await go("/booking/lookup");
  // the number's session is remembered in the tab: its bookings are listed again without asking
  const listed = page.getByRole("button", { name: new RegExp(ref) });
  if (await listed.count()) await listed.first().click();
  else {
    await page.getByPlaceholder("05xxxxxxxx").fill(phone);
    await page.getByRole("button", { name: "متابعة" }).click();
    await page.getByLabel("رقم الحجز").fill(ref);
    await page.getByRole("button", { name: "عرض حجوزاتي" }).click();
  }
  await expect(page).toHaveURL(/\/booking\/status\//);
}
/** the demo's stored data (the journey's typed messages, kept for the reception computer) */
const store = (page: Page) => page.evaluate(() => JSON.parse(localStorage.getItem("zaaer_demo_store_v9") ?? "{}") as Record<string, Array<Record<string, unknown>>>);

test.describe("the guest journey after the stay", () => {
  test("CX40 on the day of departure the guest chooses on the page: hours held then cancelled, then on time; the instructions come before «غادرت وسلّمت المفتاح»; the reception sees the departure to check", async ({ page, go, loginAs }) => {
    await page.clock.install({ time: at("10:30") });
    await loginAs("owner");
    const ref = await departingRef(page, go, "U-2");
    await signOut(page);
    await openAsGuest(page, go, "0501110005", ref);

    const panel = page.getByTestId("guest-checkout");
    await expect(panel).toContainText("يوم المغادرة");
    await expect(panel.getByTestId("guest-checkout-options")).toContainText("حتى 13:00 بلا رسوم");
    // two hours after the free hour, held while the guest pays
    await panel.getByLabel("عدد الساعات").selectOption("2");
    await panel.getByTestId("choose-hours-submit").click();
    const held = panel.getByTestId("guest-extension-held");
    await expect(held).toContainText("طلبت خروجًا متأخرًا حتى 15:00");
    await expect(held).toContainText("10.00");
    await expect(held).toContainText("ادفع المبلغ لدى الاستقبال");
    // given back by the guest: the options are offered again
    await held.getByTestId("guest-extension-cancel").click();
    await expect(panel.getByTestId("guest-checkout-options")).toBeVisible();
    await panel.getByTestId("choose-on-time").click();
    await expect(panel.getByTestId("guest-on-time")).toContainText("قبل 13:00");
    // the instructions first, then the button; a second tap confirms
    const instructions = panel.getByTestId("guest-checkout-instructions");
    const button = panel.getByTestId("guest-departure-button");
    await expect(instructions).toBeVisible();
    const [iBox, bBox] = [await instructions.boundingBox(), await button.boundingBox()];
    expect(iBox!.y).toBeLessThan(bBox!.y);
    await button.click();
    await panel.getByTestId("guest-departure-confirm").click();
    await expect(panel.getByTestId("guest-departed")).toContainText("يفحص الاستقبال الوحدة ثم يؤكد خروجك");
    await expect(panel.getByTestId("guest-deposit-note")).toContainText("من تأكيد الخروج");

    // the reception: the departure to check, its alert, the badge in the menu
    await loginAs("supervisor");
    await go("/staff/journey");
    await page.getByTestId("journey-tab-awaiting").click();
    await expect(page.getByTestId("journey-awaiting-row").filter({ hasText: "غرفة U-2" })).toContainText("صفحة الحجز");
    await page.getByTestId("journey-tab-alerts").click();
    const alert = page.getByTestId("journey-alert").filter({ hasText: "غادر نزيل غرفة U-2" });
    await expect(alert).toContainText("افحص الوحدة ثم أكمل المغادرة");
    await expect(page.getByRole("link", { name: /رحلة الضيف/ }).first()).toContainText(/\d/);
  });

  test("RW40 one invitation after the confirmed check-out: the overall mark first, six aspects; under 9 the owner is alerted — in the administration too, marked «لك»; the reception's answer is shown to the guest", async ({ page, go, loginAs }) => {
    await page.clock.install({ time: at("13:30") });   // two and a half hours after this morning's check-outs
    await loginAs("owner");
    await go("/staff/journey");                           // the journey's clock: the invitations go out
    await expect(page.getByTestId("journey-totals")).toBeVisible();
    const out = (await store(page)).whatsapp_outbox ?? [];
    const link = out.map((o) => String(o.body ?? "")).find((b) => /\/booking\/review\/[0-9a-f]+/.test(b));
    expect(link, "an invitation was typed with its key").toBeTruthy();
    const token = link!.match(/\/booking\/review\/([0-9a-f]+)/)![1];
    // the stored copy of the message never keeps the key
    expect(((await store(page)).conversation_messages ?? []).some((m) => String(m.content ?? "").includes(token))).toBe(false);

    await go(`/booking/review/${token}`);
    const form = page.getByTestId("guest-review");
    await form.getByTestId("review-submit").click();
    await expect(form.getByRole("alert")).toContainText("1 إلى 10");
    await form.getByTestId("mark-overall").getByRole("radio", { name: "7", exact: true }).click();
    for (const k of ["staff", "cleanliness", "comfort", "facilities", "value", "location"]) await form.getByTestId(`mark-${k}`).getByRole("radio", { name: "8", exact: true }).click();
    await form.getByTestId("review-comment").fill("التكييف كان ضعيفًا في الليل.");
    await form.getByTestId("review-submit").click();
    await expect(form.getByTestId("review-thanks")).toBeVisible();

    // the owner works in the administration: the low review is theirs at once there too (W5)
    await go("/admin/journey");
    await expect(page.getByTestId("admin-journey-alerts")).toContainText("يخص");
    await go("/staff/journey");
    await page.getByTestId("journey-tab-alerts").click();
    const low = page.getByTestId("journey-alert").filter({ hasText: "التكييف كان ضعيفًا" });
    await expect(low).toContainText("تقييم 7 من 10");
    await expect(low.getByTestId("alert-mine")).toBeVisible();   // named to the owner by its rule: «لك»
    await page.getByTestId("journey-tab-reviews").click();
    const review = page.getByTestId("journey-review").filter({ hasText: "التكييف كان ضعيفًا" });
    await review.getByTestId("review-reply-open").click();
    await page.getByTestId("review-reply-text").fill("نعتذر عن ذلك، وتمت صيانة المكيف.");
    await page.getByRole("dialog").getByRole("button", { name: "إرسال الرد" }).click();
    await expect(review).toContainText("تمت صيانة المكيف");
    // the alert closed with the answer; the guest's page shows it
    await page.getByTestId("journey-tab-alerts").click();
    await expect(page.getByTestId("journey-alert").filter({ hasText: "التكييف كان ضعيفًا" })).toHaveCount(0);
    await go(`/booking/review/${token}`);
    await expect(page.getByTestId("review-reply")).toContainText("تمت صيانة المكيف");
  });

  test("AR40 the owner keeps the journey's numbers and the alert rules; the manager changes the numbers but only reads the rules", async ({ page, go, loginAs }) => {
    await page.clock.install({ time: at("09:00") });
    await loginAs("owner");
    await go("/admin/journey");
    await expect(page.getByTestId("journey-inputs")).toContainText("صور شرح الدخول والخروج");
    await page.getByTestId("journey-refund-hours").fill("4");
    await page.getByTestId("journey-instructions").fill("ضع البطاقة في صندوق الاستقبال عند الخروج.");
    await page.getByTestId("journey-save").click();
    await expect(page.getByRole("status").filter({ hasText: "حُفظت إعدادات رحلة الضيف" })).toBeVisible();
    // a rule: WhatsApp only, climbing to the owner after 20 minutes
    const rule = page.getByTestId("alert-rule").filter({ hasText: "تأخر رد التأمين عن مهلته" });
    await rule.getByLabel("القناة").selectOption("whatsapp");
    await rule.getByLabel("يُصعَّد بعد (دقيقة)").fill("20");
    await rule.getByLabel("إلى").selectOption("owner");
    await rule.getByRole("button", { name: "حفظ القاعدة" }).click();
    await expect(page.getByRole("status").filter({ hasText: "حُفظت قاعدة «تأخر رد التأمين عن مهلته»" })).toBeVisible();
    // the free hour cannot end before the branch's check-out time
    await page.locator("input[type=time]").nth(1).fill("11:00");
    await page.getByTestId("journey-save").click();
    await expect(page.getByRole("alert")).toContainText("لا تسبق موعد الخروج المعتمد");
    await signOut(page);

    await loginAs("manager");
    await go("/admin/journey");
    await expect(page.getByTestId("journey-refund-hours")).toHaveValue("4");
    await expect(page.getByTestId("journey-rules")).toContainText("تعديلها للمالك وحده");
    await expect(page.getByTestId("journey-rules").getByRole("button", { name: "حفظ القاعدة" })).toHaveCount(0);
  });

  test("UG40 a unit's way in is shown to its guest only once its photo is approved", async ({ page, go, loginAs }) => {
    await page.clock.install({ time: at("10:30") });
    await loginAs("owner");
    const ref = await departingRef(page, go, "U-2");
    await go("/admin/journey");
    const row = page.getByTestId("unit-guide-row").filter({ hasText: "U-2" });
    await expect(row).toContainText("بلا صور");
    await row.getByRole("button", { name: "صور الوحدة U-2" }).click();
    const dlg = page.getByRole("dialog");
    await dlg.getByLabel("إضافة صورة لشرح الدخول").setInputFiles({ name: "step1.png", mimeType: "image/png", buffer: PNG });
    await expect(dlg.getByTestId("unit-guide-checkin")).toContainText("بانتظار الاعتماد");
    await dlg.getByLabel("وصف الخطوة 1").fill("الباب الثاني على اليمين بعد المصعد");
    await dlg.getByLabel("وصف الخطوة 1").blur();
    await expect(dlg.getByTestId("unit-guide-checkin")).toContainText("بانتظار الاعتماد");
    await dlg.getByRole("button", { name: "إغلاق" }).first().click();
    await expect(dlg).toBeHidden();

    // not approved yet: the guest sees nothing of it
    await signOut(page);
    await openAsGuest(page, go, "0501110005", ref);
    await expect(page.getByTestId("guest-unit-guide-checkin")).toHaveCount(0);

    await loginAs("owner");
    await go("/admin/journey");
    await page.getByTestId("unit-guide-row").filter({ hasText: "U-2" }).getByRole("button", { name: "صور الوحدة U-2" }).click();
    await page.getByRole("dialog").getByTestId("approve-photo").click();
    await expect(page.getByRole("dialog").getByTestId("unit-guide-checkin")).toContainText("معتمدة");
    await page.getByRole("dialog").getByRole("button", { name: "إغلاق" }).first().click();
    await signOut(page);
    await openAsGuest(page, go, "0501110005", ref);
    await expect(page.getByTestId("guest-unit-guide-checkin")).toContainText("الباب الثاني على اليمين بعد المصعد");
  });

  test("TD40 the trial data stays until the owner chooses «مسح كل بيانات التجربة»: every branch, the whole period, every kind; the example catalogue is marked", async ({ page, go, loginAs }) => {
    await page.clock.install({ time: at("09:00") });
    await loginAs("owner");
    await go("/admin/products");
    await expect(page.getByTestId("products-sample-note")).toContainText("مثال تجريبي");
    await expect(page.getByTestId("product-sample")).toHaveCount(12);
    await go("/admin/data-purge");
    const card = page.getByTestId("trial-purge");
    await expect(card).toContainText("نزلاء زائر المستوردون (لا يُمسحون)");
    await expect(card).toContainText("لا تُمسح أبدًا");
    await card.getByTestId("choose-all-trial").click();
    await expect(page.getByTestId("purge-branch")).toHaveValue("");
    for (const k of ["المحادثات والذكاء الاصطناعي", "الحجوزات المنتهية", "المالية", "ملفات النزلاء", "المهام والصيانة", "الإشعارات وسجلات التكامل", "سجل الإجراءات", "البيانات التجريبية الجاهزة"]) {
      await expect(page.getByLabel(k, { exact: true })).toBeChecked();
    }
    await page.getByRole("button", { name: "معاينة ما سيُحذف" }).click();
    await expect(page.getByText("منتجات تجريبية")).toBeVisible();
  });
});
