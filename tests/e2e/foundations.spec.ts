/**
 * Phase 0 foundations — decision 40 (one loader for every branch-scoped screen, control G24) and decision 60
 * (every failed operation shows a trace code that the owner or manager can look up).
 *
 * The demo backend answers at once; `window.__demoLatency` (src/demo/client.ts) delays chosen answers so the
 * races below are replayed deterministically.
 */
import { test, expect } from "./fixtures";

const RIYADH = "00000000-0000-0000-0000-000000000010";
const JEDDAH = "00000000-0000-0000-0000-000000000012";

test.describe("branch scope (U02, control G24)", () => {
  test("U02a switching branch clears the previous branch's data at once and shows only the new branch's", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/structure");
    const picker = page.getByLabel("الفرع النشط");
    await picker.selectOption(RIYADH);
    await expect(page.getByText("المبنى الرئيسي (B)")).toBeVisible();

    // Jeddah's structure answers slowly: during that time the screen must not keep showing Riyadh
    await page.evaluate((b) => { (window as unknown as { __demoLatency: unknown }).__demoLatency = (t: string, d: string[]) => (t === "blocks" && d.includes(`branch_id=${b}`) ? 1500 : 0); }, JEDDAH);
    await picker.selectOption(JEDDAH);
    await expect(page.getByText("المبنى الرئيسي (B)")).toHaveCount(0, { timeout: 700 });
    await expect(page.getByText("المبنى الوحيد")).toHaveCount(0);           // still loading — nothing shown yet
    await expect(page.getByText("المبنى الوحيد")).toBeVisible({ timeout: 5_000 });
    await expect(page.getByText("الملحق (U)")).toHaveCount(0);
  });

  test("U02b a late answer for the previous branch never replaces the active branch's figures", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/reports");
    const picker = page.getByLabel("الفرع النشط");
    await picker.selectOption(RIYADH);
    const periodBookings = page.locator("div.card", { has: page.locator("p", { hasText: /^حجوزات الفترة$/ }) }).locator("p.text-xl");
    await page.getByRole("button", { name: "هذا الشهر" }).click();
    await expect(periodBookings).not.toHaveText("0");                      // Riyadh has bookings this month
    await page.getByRole("button", { name: "آخر 30 يومًا" }).click();
    await expect(periodBookings).toBeVisible();

    // Riyadh's next report answers after 1.5 s; the user switches to Jeddah before that
    await page.evaluate((b) => { (window as unknown as { __demoLatency: unknown }).__demoLatency = (t: string, d: string[]) => (t === "rpc:fn_reports_finance" && (d[0] ?? "").includes(b) ? 1500 : 0); }, RIYADH);
    await page.getByRole("button", { name: "هذا الشهر" }).click();
    await picker.selectOption(JEDDAH);
    await expect(periodBookings).toHaveText("0");                          // Jeddah: no bookings
    await page.waitForTimeout(2_000);                                      // Riyadh's late answer arrives …
    await expect(periodBookings).toHaveText("0");                          // … and is dropped
    await expect(page.getByLabel("الفرع النشط")).toHaveValue(JEDDAH);
  });
});

test.describe("load and save states (U01, U04 — decision 42)", () => {
  test("U01 a server error while saving a definition keeps the dialog and what was typed, with a clear message and its trace code", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/structure");
    await page.getByLabel("الفرع النشط").selectOption(RIYADH);
    await page.getByRole("button", { name: "بلوك جديد" }).click();
    const dialog = page.getByRole("dialog");
    const name = dialog.locator("div:has(> label:has-text('اسم البلوك')) input");
    await name.fill("بلوك تجربة الحفظ");
    await page.evaluate(() => { (window as unknown as { __demoFail: unknown }).__demoFail = (t: string) => (t === "rpc:fn_admin_upsert_block" ? "network down" : null); });
    await dialog.getByRole("button", { name: "حفظ" }).click();
    await expect(dialog.getByText(/تعذّر تنفيذ العملية.*\(رمز التتبع: [A-Z0-9]{8}\)/)).toBeVisible();
    await expect(name).toHaveValue("بلوك تجربة الحفظ");                     // nothing typed is lost
    await expect(page.getByText("بلوك تجربة الحفظ", { exact: true })).toHaveCount(0);   // and nothing claims it was saved

    await page.evaluate(() => { (window as unknown as { __demoFail: unknown }).__demoFail = undefined; });
    await dialog.getByRole("button", { name: "حفظ" }).click();
    await expect(page.getByRole("dialog")).toHaveCount(0);
    await expect(page.getByText("بلوك تجربة الحفظ", { exact: true })).toBeVisible();
  });

  test("U04 an empty list and a failed load are two different states: the failure says so and offers a retry", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/facilities");
    const picker = page.getByLabel("الفرع النشط");
    await picker.selectOption(JEDDAH);                                      // Jeddah has no facilities: empty
    await expect(page.getByText("لا توجد مرافق")).toBeVisible();
    await expect(page.getByText("تعذّر تحميل البيانات")).toHaveCount(0);

    // the same screen when the read fails: an error with a retry, never "no facilities"
    await page.evaluate(() => { (window as unknown as { __demoFail: unknown }).__demoFail = (t: string) => (t === "facilities" ? "network down" : null); });
    await picker.selectOption(RIYADH);
    await expect(page.getByText("تعذّر تحميل البيانات")).toBeVisible();
    await expect(page.getByText("لا توجد مرافق")).toHaveCount(0);
    await expect(page.getByRole("button", { name: "إعادة المحاولة" })).toBeVisible();

    // the server is back: retry shows the branch's facilities
    await page.evaluate(() => { (window as unknown as { __demoFail: unknown }).__demoFail = undefined; });
    await page.getByRole("button", { name: "إعادة المحاولة" }).click();
    await expect(page.getByText("تعذّر تحميل البيانات")).toHaveCount(0);
    await expect(page.locator("div.card").first()).toBeVisible();
    await expect(page.getByText("لا توجد مرافق")).toHaveCount(0);
  });
});

test.describe("trace codes (decision 60)", () => {
  test("TR06 a failed operation shows its trace code, and the owner finds what happened by that code", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/staff/reservations/new");
    await page.locator("div:has(> label:has-text('الاسم (مطلوب)')) input").first().fill("ضيف تجربة التتبع");
    await page.getByPlaceholder("05xxxxxxxx").fill("0501112233");
    await page.locator("div:has(> label:has-text('مصدر الحجز')) select").selectOption({ label: "Booking.com" });
    await page.getByTestId("platform-collects").selectOption("property");   // 0038: who collects is chosen on the form
    await page.waitForTimeout(500);
    await page.getByRole("button", { name: "إنشاء الحجز" }).click();   // no platform reference → refused by the server

    const banner = page.getByText(/المرجع الخارجي مطلوب لهذا المصدر\. \(رمز التتبع: [A-Z0-9]{8}\)/);
    await expect(banner).toBeVisible();
    const code = (await banner.innerText()).match(/رمز التتبع: ([A-Z0-9]{8})/)![1];

    await go("/admin/audit-logs");
    await page.getByLabel("رمز التتبع").fill(` ${code.toLowerCase()} `);   // typed as read over the phone
    await page.getByRole("button", { name: "بحث" }).click();
    const result = page.getByTestId("trace-result");
    await expect(result).toContainText("عملية تعذّر تنفيذها");
    await expect(result).toContainText("المرجع الخارجي مطلوب لهذا المصدر.");
    await expect(result).toContainText("fn_staff_create_reservation");
    await expect(result).toContainText("عبدالله المالك");
    await expect(result).not.toContainText("ضيف تجربة التتبع");             // no personal data is kept with the failure
    await expect(result).not.toContainText("0501112233");
  });

  test("TR07 a successful operation's audit rows carry its trace code and source", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    // any audited operation from the staff screens: create a reservation
    await go("/staff/reservations/new");
    await page.locator("div:has(> label:has-text('الاسم (مطلوب)')) input").first().fill("ضيف تجربة السجل");
    await page.getByPlaceholder("05xxxxxxxx").fill("0501112244");
    await page.waitForTimeout(500);
    await page.getByRole("button", { name: "إنشاء الحجز" }).click();
    await page.waitForURL(/#\/staff\/reservations\/[0-9a-f-]+/, { timeout: 15_000 });

    await go("/admin/audit-logs");
    // the seeded history has no source; the rows this operation wrote say where it came from
    const mine = page.locator("table tbody tr", { hasText: "شاشات الاستقبال" }).first();
    await expect(mine).toBeVisible();
    await expect(mine).toContainText("عبدالله المالك");
    const code = (await mine.locator("td").nth(9).innerText()).trim();   // the trace code is the log's last column (0040)
    expect(code).toMatch(/^[A-Z0-9]{8}$/);

    await page.getByLabel("رمز التتبع").fill(code);
    await page.getByRole("button", { name: "بحث" }).click();
    const result = page.getByTestId("trace-result");
    await expect(result).toContainText("ما سجّلته العملية");
    await expect(result).not.toContainText("عملية تعذّر تنفيذها");
  });
});
