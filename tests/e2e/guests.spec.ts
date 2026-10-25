/**
 * Guests, platforms and the website through the UI (Phase 5, migration 0038) — test ids GE01–GE10, the UI facet of
 * tests/sql/guests_platforms_tests.sql (GD, BN, SO, PF, GP, SS, BR, WS) and the demo tests in tests/unit/demo-invariants.test.ts (GU).
 * Controls: G01 (server-side permissions per operation), G02 (a partial payment is never "paid" — the platform's receipt
 * covers the whole stay or nothing), G03 (every change audited with who, when and why), G19 (corrections only with a
 * reason), G22 (the owner's review list), G27 (the screen shows the server's refusal, never a fake success).
 */
import { test, expect, createReservation, financeCell } from "./fixtures";
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

/** Opens a booking by its reference through the list's search. */
async function openByRef(page: Page, go: (p: string) => Promise<void>, ref: string) {
  await go("/staff/reservations");
  await page.getByPlaceholder("مرجع / ضيف / جوال").fill(ref);
  const row = page.locator("table tbody tr").filter({ hasText: ref }).first();
  await expect(row).toBeVisible();
  await row.getByRole("link", { name: "فتح" }).click();
  await page.waitForURL(/#\/staff\/reservations\/[0-9a-f-]+/);
  await page.waitForTimeout(400);
}

/** «حجوزاتي» as the guest: the phone, then one booking number proves it. */
async function openGuestStatus(page: Page, go: (p: string) => Promise<void>, phone: string, ref: string) {
  await page.evaluate(() => { try { sessionStorage.removeItem("guest_phone_session"); } catch { /* storage blocked */ } });
  await go("/booking/lookup");
  await page.getByPlaceholder("05xxxxxxxx").fill(phone);
  await page.getByRole("button", { name: "متابعة" }).click();
  await page.getByPlaceholder("رقم الحجز").fill(ref);
  await page.getByRole("button", { name: "عرض حجوزاتي" }).click();
  // one booking on the phone opens directly; several are listed, and the one asked for is tapped
  const listed = page.getByRole("button").filter({ hasText: ref });
  await expect(page.locator("body")).toContainText(/حالة الحجز|حجوزات|حجز واحد|ملخص الإقامة/);
  if (!/\/booking\/status\//.test(page.url())) await listed.first().click();
  await expect(page).toHaveURL(/\/booking\/status\//);
}

async function signOut(page: Page) {
  await page.locator('[title="تسجيل الخروج"]:visible, [aria-label="تسجيل الخروج"]:visible').first().click();
  await expect(page).toHaveURL(/#\/staff\/login/);
}

const todayRiyadh = () => new Date().toLocaleDateString("en-CA", { timeZone: "Asia/Riyadh" });
/** A new platform booking from the staff form (decision 4): the number, who collects, the day it was booked there. */
async function createPlatformReservation(page: Page, opts: { guest: string; phone: string; ref: string; collects: "platform" | "property"; units?: number }) {
  await page.goto("/#/staff/reservations/new", { waitUntil: "networkidle" });
  await page.locator("div:has(> label:has-text('الاسم (مطلوب)')) input").first().fill(opts.guest);
  await page.getByPlaceholder("05xxxxxxxx").fill(opts.phone);
  const src = page.locator("select").filter({ has: page.locator("option:has-text('Booking.com')") });
  await src.selectOption({ label: "Booking.com" });
  await page.getByLabel("رقم الحجز في المنصة").fill(opts.ref);
  await page.getByTestId("platform-collects").selectOption(opts.collects);
  await page.getByLabel("تاريخ الحجز في المنصة").fill(todayRiyadh());
  for (let i = 1; i < (opts.units ?? 1); i++) await page.getByRole("button", { name: "وحدة أخرى في نفس الحجز" }).click();
  await page.waitForTimeout(400);
  await page.getByRole("button", { name: /إنشاء الحجز|إنشاء \d+ حجوزات/ }).click();
}

const PNG_1x1 = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==", "base64");

test.describe("guests, platforms and the website (phase 5)", () => {
  test("GE01 the office path: «طابقتُ الوثيقة الأصلية» is required, the guest is verified at once with who did it; a correction needs a reason", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await openByRef(page, go, "HMABC123");                       // arriving today from Airbnb, no guest data yet
    await page.getByTestId(/^office-enter-/).first().click();
    const dlg = page.getByRole("dialog");
    await expect(dlg).toContainText("من الوثيقة");
    await dlg.getByLabel("الاسم الثلاثي").fill("أحمد علي المنصوري");
    await dlg.getByLabel("رقم الوثيقة").fill("2345678901");
    await dlg.getByLabel("الجنسية").fill("إماراتي");
    await dlg.getByLabel("تاريخ الميلاد").fill("1985-03-12");
    await dlg.getByRole("button", { name: "حفظ واعتماد" }).click();
    await expect(dlg.getByText("أكّد «طابقتُ الوثيقة الأصلية» قبل الحفظ.")).toBeVisible();   // the server's refusal, nothing saved
    await dlg.getByLabel("طابقتُ الوثيقة الأصلية").check();
    await dlg.getByRole("button", { name: "حفظ واعتماد" }).click();
    await expect(dlg).toBeHidden();
    await expect(page.getByText("أحمد علي المنصوري")).toBeVisible();
    await expect(page.getByText(/من الوثيقة — فهد الاستقبال/)).toBeVisible();
    await expect(page.getByText("••••8901").first()).toBeVisible();        // the number itself is never shown again
    // a correction: without a reason the server refuses; with one it is saved and lands in the owner's list
    await page.getByTestId(/^office-correct-/).first().click();
    const fix = page.getByRole("dialog");
    await expect(fix).toContainText("تصحيح بيانات");
    await fix.getByLabel("تاريخ الميلاد").fill("1986-03-12");
    await fix.getByLabel("طابقتُ الوثيقة الأصلية").check();
    await fix.getByRole("button", { name: "حفظ التصحيح" }).click();
    await expect(fix.getByText("يجب كتابة سبب.")).toBeVisible();
    await fix.getByLabel("سبب التصحيح").fill("خطأ في سنة الميلاد");
    await fix.getByRole("button", { name: "حفظ التصحيح" }).click();
    await expect(fix).toBeHidden();
    await page.getByRole("button", { name: "السجل" }).click();
    await expect(page.getByText(/السبب: خطأ في سنة الميلاد/)).toBeVisible();
    await signOut(page);
    await loginAs("owner");
    await go("/admin/review");
    await expect(page.getByText(/تصحيح بيانات نزيل/).first()).toBeVisible();
  });

  test("GE02 a banned guest: the red alert on a new booking of the same phone, the arrival refused, the profile page lifts the ban with a reason and bans again", async ({ page, loginAs, go }) => {
    await loginAs("manager");
    await createReservation(page, "رامي ناصر", "0501110017");    // the seeded ban (decision 21)
    await expect(page.getByTestId("guest-ban-alert")).toContainText("الضيف محظور من الإدارة");
    await expect(page.getByTestId("guest-ban-alert")).toContainText("ملف الضيف");
    await expect(page.getByTestId("arrival").getByTestId("reasons")).toContainText("الضيف محظور من الإدارة");   // the arrival's fixed conditions, no button to try
    await page.getByTestId("guest-ban-alert").getByRole("link", { name: "ملف الضيف" }).click();
    await page.waitForURL(/#\/admin\/guests\/[0-9a-f-]+/);
    await expect(page.getByTestId("profile-ban")).toBeVisible();
    await page.getByTestId("unban-guest").click();
    let dlg = page.getByRole("dialog");
    await dlg.getByRole("button", { name: "رفع الحظر" }).click();
    await expect(dlg.getByText("يجب كتابة سبب.")).toBeVisible();
    await dlg.locator("textarea").fill("سدّد المستحقات واعتذر");
    await dlg.getByRole("button", { name: "رفع الحظر" }).click();
    await expect(dlg).toBeHidden();
    await expect(page.getByTestId("profile-ban")).toHaveCount(0);
    await expect(page.getByText(/سجل الحظر/)).toBeVisible();
    await page.getByTestId("ban-guest").click();
    dlg = page.getByRole("dialog");
    await dlg.locator("textarea").fill("أضرار متكررة في الوحدة");
    await dlg.getByRole("button", { name: "حظر", exact: true }).click();
    await expect(dlg).toBeHidden();
    await expect(page.getByTestId("profile-ban")).toContainText("أضرار متكررة في الوحدة");
    // the list marks the banned guest's bookings
    await go("/staff/reservations");
    await page.getByPlaceholder("مرجع / ضيف / جوال").fill("0501110017");
    await expect(page.getByTestId("row-ban").first()).toBeVisible();
  });

  test("GE03 the rating 1–5 with an internal note is seen on the guest's booking; a hold on one booking blocks the arrival until a manager lifts it with a reason", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await openByRoom(page, go, "204", "checked_in");                 // سارة: rated 2 in the seed
    await expect(page.getByTestId("guest-rating")).toContainText("تقييم الضيف");
    await expect(page.getByTestId("guest-rating").getByLabel("2 من 5")).toBeVisible();
    await page.getByRole("button", { name: "تعديل تقييم الضيف" }).click();
    const rate = page.getByRole("dialog");
    await rate.getByTestId("rate-stars").getByLabel("4 من 5").click();
    await rate.getByLabel("ملاحظة داخلية").fill("تحسّن الالتزام بالمواعيد");
    await rate.getByRole("button", { name: "حفظ" }).click();
    await expect(rate).toBeHidden();
    await expect(page.getByTestId("guest-rating").getByLabel("4 من 5")).toBeVisible();
    await expect(page.getByTestId("guest-rating")).toContainText("تحسّن الالتزام بالمواعيد");
    // the hold: a supervisor places it; only the manager lifts it
    await openByRoom(page, go, "203", "confirmed");
    await page.getByRole("button", { name: "وضع حظر على الحجز" }).click();
    const hold = page.getByRole("dialog");
    await hold.locator("textarea").fill("بلاغ من الجهات الأمنية");
    await hold.getByRole("button", { name: "وضع الحظر" }).click();
    await expect(hold).toBeHidden();
    await expect(page.getByTestId("hold-alert")).toContainText("بلاغ من الجهات الأمنية");
    await expect(page.getByTestId("hold-alert").getByRole("button", { name: "رفع الحظر" })).toHaveCount(0);
    await expect(page.getByTestId("arrival").getByTestId("reasons")).toContainText("يوجد حظر أمني على الحجز");
    await signOut(page);
    await loginAs("manager");
    await openByRoom(page, go, "203", "confirmed");
    await page.getByTestId("hold-alert").getByRole("button", { name: "رفع الحظر" }).click();
    const lift = page.getByRole("dialog");
    await lift.locator("textarea").fill("اتضح أن البلاغ خاطئ");
    await lift.getByRole("button", { name: "رفع الحظر" }).click();
    await expect(lift).toBeHidden();
    await expect(page.getByTestId("hold-alert")).toHaveCount(0);
  });

  test("GE04 a platform's booking: who collects and the day it was booked there are required; the platform collecting makes its receipt for the whole stay; «طابقتُ مع المنصة»; cancelled with the platform's number", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await page.goto("/#/staff/reservations/new", { waitUntil: "networkidle" });
    await page.locator("div:has(> label:has-text('الاسم (مطلوب)')) input").first().fill("ضيف بوكينق");
    await page.getByPlaceholder("05xxxxxxxx").fill("0509001001");
    await page.locator("select").filter({ has: page.locator("option:has-text('Booking.com')") }).selectOption({ label: "Booking.com" });
    await expect(page.getByText("رقم الحجز في المنصة (مطلوب)")).toBeVisible();
    await page.getByLabel("رقم الحجز في المنصة").fill("BK-E2E-1");
    await expect(page.getByRole("button", { name: "إنشاء الحجز" })).toBeDisabled();           // who collects is not chosen yet
    await page.getByTestId("platform-collects").selectOption("platform");
    await page.getByLabel("تاريخ الحجز في المنصة").fill("");
    await page.waitForTimeout(400);
    await page.getByRole("button", { name: "إنشاء الحجز" }).click();
    await expect(page.getByText(/تاريخ الحجز في المنصة مطلوب/)).toBeVisible();                 // the server's refusal
    await page.getByLabel("تاريخ الحجز في المنصة").fill(todayRiyadh());
    await page.getByRole("button", { name: "إنشاء الحجز" }).click();
    await page.waitForURL(/#\/staff\/reservations\/[0-9a-f-]+/, { timeout: 15_000 });
    const panel = page.getByTestId("platform-panel");
    await expect(panel).toContainText("BK-E2E-1");
    await expect(panel).toContainText("المنصة (آجل عبر المنصات)");
    await expect(panel).toContainText("لم يُطابَق مع المنصة بعد");
    const total = await financeCell(page, "الإجمالي");
    expect(total).toBeGreaterThan(0);
    expect(await financeCell(page, "المحصل")).toBe(total);                                   // the platform's receipt, the whole stay
    expect(await financeCell(page, "المتبقي")).toBe(0);
    await expect(page.getByText("آجل عبر المنصات").first()).toBeVisible();
    await panel.getByTestId("platform-check").click();
    await expect(panel).toContainText("طُوبق مع المنصة — فهد الاستقبال");
    // the daily list holds it, matched
    await go("/staff/platforms");
    const row = page.getByTestId("platform-row").filter({ hasText: "BK-E2E-1" });
    await expect(row).toBeVisible();
    await expect(row).toContainText("فهد الاستقبال");
    await expect(page.getByTestId("platform-row").filter({ hasText: "BK-4471029" })).toBeVisible();   // today's seeded arrival from Booking.com
    // cancelling: the platform's number is required, and nothing is refunded
    await openByRef(page, go, "BK-E2E-1");
    await page.getByRole("button", { name: "الإقامة", exact: true }).click();
    await page.getByRole("button", { name: "إلغاء الحجز" }).click();
    const dlg = page.getByRole("dialog");
    await expect(dlg.getByLabel("أُلغي على المنصة (أدخل رقم الإلغاء)")).toBeChecked();
    await dlg.locator("textarea").fill("ألغاه الضيف على المنصة");
    await dlg.getByRole("button", { name: "تأكيد الإلغاء" }).click();
    await expect(dlg.getByText("رقم الإلغاء من المنصة مطلوب (حتى 60 حرفًا).")).toBeVisible();
    await dlg.getByRole("textbox", { name: "رقم الإلغاء" }).fill("CXL-E2E-1");
    await dlg.getByRole("button", { name: "تأكيد الإلغاء" }).click();
    await expect(dlg).toContainText("أُلغي الحجز");
    await expect(dlg).toContainText("قبضت المنصة هذا الحجز");
    await dlg.getByRole("button", { name: "تم" }).click();
    await expect(page.getByTestId("platform-panel")).toContainText("CXL-E2E-1");
    expect(await financeCell(page, "المحصل")).toBe(total);                                    // cancellation is not a refund
  });

  test("GE05 a group with one platform number: every unit carries it, the group's page adds up, and the number is refused on another booking", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await createPlatformReservation(page, { guest: "وفد الشركة", phone: "0509002002", ref: "GRP-E2E", collects: "property", units: 2 });
    await page.waitForURL(/#\/staff\/reservations\/[0-9a-f-]+/, { timeout: 15_000 });
    const group = page.getByTestId("group-panel");
    await expect(group).toContainText("رقم المنصة GRP-E2E (مشترك بين الوحدات)");
    await expect(group.locator("tbody tr")).toHaveCount(2);
    await expect(group.getByTestId("group-total")).toBeVisible();
    await expect(page.getByTestId("platform-panel")).toContainText("المنشأة عند الوصول");
    expect(await financeCell(page, "المحصل")).toBe(0);                                        // the property collects: no receipt yet
    // the same number on another booking is refused by the server, and the form says so
    await createPlatformReservation(page, { guest: "ضيف آخر", phone: "0509003003", ref: "GRP-E2E", collects: "property" });
    await expect(page.getByText("رقم الحجز في المنصة مستخدم في حجز آخر أو مجموعة أخرى.")).toBeVisible();
    await expect(page).toHaveURL(/#\/staff\/reservations\/new/);
    await go("/staff/reservations");
    await page.getByPlaceholder("مرجع / ضيف / جوال").fill("GRP-E2E");
    await expect(page.locator("table tbody tr")).toHaveCount(2);
  });

  test("GE06 «ملخص الإقامة»: printed from the booking with the branch's policies; the paper signature is recorded against its text; the guest sees it accepted on their page", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await openByRoom(page, go, "203", "confirmed");                 // تركي المطيري, R-26A0008
    await page.getByTestId("stay-summary-btn").click();
    const dlg = page.getByRole("dialog");
    const text = dlg.getByTestId("stay-summary-text");
    await expect(text).toContainText("ملخص الإقامة");
    await expect(text).toContainText("الحجز: R-26A0008");
    await expect(text).toContainText("التأمين: 50.00 ر.س");
    await expect(text).toContainText("سياسات الفرع");
    await expect(text).toContainText("المواقف");
    await expect(dlg).toContainText("لم يُقر الضيف بعد");
    await dlg.getByTestId("record-paper-ack").click();
    await expect(dlg.getByTestId("ack-list")).toContainText("توقيع ورقي");
    await expect(dlg.getByTestId("ack-list")).toContainText("فهد الاستقبال");
    await expect(dlg.getByTestId("record-paper-ack")).toHaveCount(0);                          // once per text
    await page.keyboard.press("Escape");
    await signOut(page);
    await openGuestStatus(page, go, "0501110008", "R-26A0008");
    await expect(page.getByTestId("summary-link")).toContainText("(مُقرّ)");
    await expect(page.getByTestId("map-link")).toHaveAttribute("href", "https://maps.app.goo.gl/demo-riyadh");
    await page.getByTestId("summary-link").click();
    await expect(page).toHaveURL(/\/booking\/summary\//);
    await expect(page.getByTestId("guest-summary-text")).toContainText("الحجز: R-26A0008");
    await expect(page.getByTestId("summary-accepted")).toContainText("توقيع ورقي");
  });

  test("GE07 the guest accepts the summary on their page, and the first registration needs that acceptance; a payment makes a new text to accept", async ({ page, loginAs, go }) => {
    await openGuestStatus(page, go, "0501110010", "R-26A0010");       // لطيفة, arriving in two days, nothing accepted yet
    await page.getByTestId("summary-link").click();
    await expect(page.getByTestId("guest-summary-text")).toContainText("عدد الليالي: 4");
    await expect(page.getByTestId("summary-accepted")).toHaveCount(0);
    await page.getByTestId("accept-summary").click();
    await expect(page.getByTestId("summary-accepted")).toContainText("تم الإقرار");
    // the registration of another booking: the acceptance is part of the form and the server insists on it
    await openGuestStatus(page, go, "0501110009", "R-26A0009");
    await page.getByRole("link", { name: "استكمال البيانات" }).click();
    await expect(page).toHaveURL(/\/booking\/registration\//);
    await page.getByRole("button", { name: "أكمل البيانات" }).first().click();
    const form = page.getByRole("dialog");
    await form.getByPlaceholder("الاسم الأول الأب الجد").fill("بدر راشد العنزي");
    await form.locator("input[dir=ltr][inputmode=numeric]").first().fill("1077889900");
    await form.locator("input[type=date]").fill("1992-07-01");
    await form.locator("input[type=checkbox]").first().check();                                // the data consent
    await expect(form.getByTestId("summary-ack")).toBeVisible();
    await form.getByRole("button", { name: "حفظ البيانات" }).click();
    await expect(form.getByText("يجب الإقرار بملخص الإقامة.")).toBeVisible();
    await form.getByLabel("أقرّ بملخص الإقامة").check();
    await form.getByRole("button", { name: "حفظ البيانات" }).click();
    await expect(form).toBeHidden();
    await expect(page.getByText("بدر راشد العنزي")).toBeVisible();
    // a payment at the reception changes the summary: the page asks for a new acceptance
    await loginAs("supervisor");
    await openByRef(page, go, "R-26A0010");
    await page.getByRole("button", { name: "سند قبض إقامة" }).click();
    const v = page.getByRole("dialog");
    await v.locator("input[type=number]").first().fill("100");
    await v.getByRole("button", { name: "حفظ السند" }).click();
    await expect(v).toBeHidden();
    await signOut(page);
    await openGuestStatus(page, go, "0501110010", "R-26A0010");
    await page.getByTestId("summary-link").click();
    await expect(page.getByText(/تغيّر الملخص منذ إقرارك السابق/)).toBeVisible();
    await expect(page.getByTestId("accept-summary")).toBeVisible();
  });

  test("GE08 the branch's fields: the map link must be a Google Maps https link, the platform link https; the logo by its real type; a visitor's «احجز» page reads them", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/branches");
    await page.getByRole("button", { name: "تعديل فرع الرياض" }).click();
    const dlg = page.getByRole("dialog");
    await expect(dlg.getByLabel("الاسم الإنجليزي")).toHaveValue("Riyadh - King Fahd Rd");
    await dlg.getByLabel("رابط الموقع").fill("http://maps.google.com/?q=1");
    await dlg.getByRole("button", { name: "حفظ" }).click();
    await expect(dlg.getByText("رابط الموقع يجب أن يكون رابط خرائط Google يبدأ بـ https.")).toBeVisible();
    await dlg.getByLabel("رابط الموقع").fill("https://maps.app.goo.gl/e2e-riyadh");
    await dlg.getByLabel("رابط منصة الحجز").fill("javascript:alert(1)");
    await dlg.getByRole("button", { name: "حفظ" }).click();
    await expect(dlg.getByText("رابط منصة الحجز يجب أن يبدأ بـ https.")).toBeVisible();
    await dlg.getByLabel("رابط منصة الحجز").fill("https://www.booking.com/hotel/sa/e2e.html");
    // the logo: an SVG is refused by its bytes; a PNG is kept with its type and size
    const media = dlg.getByTestId("branch-media");
    await media.getByLabel("رفع الشعار").setInputFiles({ name: "logo.svg", mimeType: "image/png", buffer: Buffer.from('<svg xmlns="http://www.w3.org/2000/svg"></svg>') });
    await expect(media.getByText("الشعار والصورة بصيغة PNG أو JPG أو WebP فقط (لا SVG).")).toBeVisible();
    await media.getByLabel("رفع الشعار").setInputFiles({ name: "logo.png", mimeType: "image/png", buffer: PNG_1x1 });
    await expect(media.getByText(/PNG · 0 كيلوبايت · عبدالله المالك/)).toBeVisible();
    await dlg.getByRole("button", { name: "حفظ" }).click();
    await expect(dlg).toBeHidden();
    await signOut(page);
    await go("/booking/new");
    const card = page.getByTestId("booking-platform-card");
    await expect(card).toContainText("الحجوزات الجديدة والأسعار والتوفر عبر منصة الحجز المعتمدة فقط");
    await expect(card.getByTestId("platform-link")).toHaveAttribute("href", "https://www.booking.com/hotel/sa/e2e.html");
    await expect(card.getByTestId("map-link")).toHaveAttribute("href", "https://maps.app.goo.gl/e2e-riyadh");
    await expect(card).not.toContainText("ر.س");                                                // no prices, no availability (decision 23)
    await page.getByLabel("الفرع").selectOption({ label: "فرع جدة — الكورنيش" });
    await expect(page.getByTestId("platform-missing")).toContainText("لم يُضبط رابط منصة الحجز لهذا الفرع بعد");
  });

  test("GE09 the twelve sources are switched on or off by the owner or a manager only, and the trail keeps it; nobody edits the list", async ({ page, loginAs, go }) => {
    await loginAs("manager");
    await go("/admin/booking-sources");
    await expect(page.getByTestId(/^source-/)).toHaveCount(12);
    await expect(page.getByTestId("source-booking_engine")).toContainText("متوقف");
    await expect(page.getByTestId("source-airport")).toContainText("رقم المنصة اختياري");
    await expect(page.getByTestId("source-agoda")).toContainText("نشط");
    await page.getByTestId("source-agoda").getByRole("button", { name: "إيقاف" }).click();
    await expect(page.getByTestId("source-agoda")).toContainText("متوقف");
    await page.getByTestId("source-agoda").getByRole("button", { name: "تفعيل" }).click();
    await expect(page.getByTestId("source-agoda")).toContainText("نشط");
    await go("/admin/audit-logs");
    await expect(page.getByText("source.disabled").first()).toBeVisible();
    await expect(page.getByText("source.enabled").first()).toBeVisible();
    // the supervisor books from the list but has no screen to change it (the server refuses them too: T30, GU)
    await signOut(page);
    await loginAs("supervisor");
    await expect(page.getByRole("link", { name: "منصات الحجز" })).toHaveCount(0);
  });

  test("GE10 the owner's reports: the late platform entries with the days between the platform's booking and the entry, and the identities approved at the office", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/reports");
    const late = page.getByTestId("late-entries-report");
    await expect(late).toContainText("BK-4489931");
    await expect(late).toContainText("4");
    const ids = page.getByTestId("identities-report");
    await expect(ids).toBeVisible();
    await expect(ids).toContainText("الهويات المعتمدة");
    await expect(ids).toContainText("لا هويات معتمدة بهذا المسار في الفترة.");                 // the seed has no office entries yet
    await ids.getByLabel("المسار").selectOption("all");
    await expect(ids).toContainText("من المكتب 0 · مطابقة");
    await expect(ids).toContainText("أدخلها الضيف");
  });
});
