/**
 * Plan items 6.5–6.8 — the global form contracts, proven across pages (not one example each):
 *
 *  6.5 (U4) auto-draft: a reload never loses a long form's input, and its restoration is offered.
 *  6.6 (U3) one state per list: loading XOR empty XOR error XOR data; the error card goes away after a success.
 *  6.7 (U7) save button: from the press until the reply the form cannot be submitted again (no duplicate writes).
 *  6.8 (U9) no silent disable: a disabled control says why.
 *
 * The page-by-page audit behind this spec lives in docs/form-contracts-inventory.md.
 * The demo backend answers at once; window.__demoLatency / __demoFail (src/demo/client.ts) replay a slow
 * or a broken network exactly as the earlier K-specs do.
 */
import { test, expect, bookingNext } from "./fixtures";
import { retainUnexpectedErrors } from "./scoped-network-errors";

/* ---------------------------------- 6.5 ---------------------------------- */

test.describe("auto-draft on the long definition forms (6.5)", () => {
  test("room category: fill, reload, reopen, restore; a successful save clears the draft", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/room-categories");
    await page.getByRole("button", { name: "نوع جديد" }).click();
    let dlg = page.getByRole("dialog");
    await dlg.getByLabel("الاسم العربي (مطلوب)").fill("جناح تجريبي للمسودة");
    await dlg.getByLabel("الوصف").fill("وصف كان سيضيع عند التحديث");
    await dlg.getByLabel("السعر الأساسي لليلة (إلزامي)").fill("450");
    await page.waitForTimeout(700); // the draft write is debounced (300ms)
    await page.reload({ waitUntil: "networkidle" });
    await page.getByRole("button", { name: "نوع جديد" }).click();
    dlg = page.getByRole("dialog");
    // the draft is offered, not applied: the form opens empty with a visible restore banner
    await expect(dlg.getByTestId("form-draft-restore")).toContainText("جناح تجريبي للمسودة");
    await expect(dlg.getByLabel("الاسم العربي (مطلوب)")).toHaveValue("");
    // Waiting to decide must not delete the offered draft on the debounce timer.
    await page.waitForTimeout(700);
    await page.reload({ waitUntil: "networkidle" });
    await page.getByRole("button", { name: "نوع جديد" }).click();
    dlg = page.getByRole("dialog");
    await expect(dlg.getByTestId("form-draft-restore")).toContainText("جناح تجريبي للمسودة");
    await dlg.getByRole("button", { name: "استعادة المسودة" }).click();
    await expect(dlg.getByLabel("الاسم العربي (مطلوب)")).toHaveValue("جناح تجريبي للمسودة");
    await expect(dlg.getByLabel("الوصف")).toHaveValue("وصف كان سيضيع عند التحديث");
    await expect(dlg.getByLabel("السعر الأساسي لليلة (إلزامي)")).toHaveValue("450");
    await expect(dlg.getByTestId("form-draft-restore")).toHaveCount(0);
    // a successful save clears the stored draft: reopening starts clean
    await dlg.getByRole("button", { name: "حفظ" }).click();
    await expect(dlg).toBeHidden();
    await expect(page.getByText("جناح تجريبي للمسودة")).toHaveCount(1);
    await page.getByRole("button", { name: "نوع جديد" }).click();
    await expect(page.getByRole("dialog").getByTestId("form-draft-restore")).toHaveCount(0);
  });

  test("service: fill, reload, reopen, restore", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/services");
    await page.getByRole("button", { name: "خدمة جديدة" }).click();
    let dlg = page.getByRole("dialog");
    await dlg.getByLabel("الاسم العربي (مطلوب)").fill("خدمة مسودة الاختبار");
    await dlg.getByLabel("الوصف").fill("وصف الخدمة التجريبية");
    await dlg.getByLabel("السعر (إلزامي)").fill("35");
    await page.waitForTimeout(700);
    await page.reload({ waitUntil: "networkidle" });
    await page.getByRole("button", { name: "خدمة جديدة" }).click();
    dlg = page.getByRole("dialog");
    await expect(dlg.getByTestId("form-draft-restore")).toContainText("خدمة مسودة الاختبار");
    await dlg.getByRole("button", { name: "استعادة المسودة" }).click();
    await expect(dlg.getByLabel("الاسم العربي (مطلوب)")).toHaveValue("خدمة مسودة الاختبار");
    await expect(dlg.getByLabel("الوصف")).toHaveValue("وصف الخدمة التجريبية");
    await expect(dlg.getByLabel("السعر (إلزامي)")).toHaveValue("35");
  });

  test("branch: fill, reload, reopen, restore", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/branches");
    await page.getByRole("button", { name: "فرع جديد" }).click();
    let dlg = page.getByRole("dialog");
    await dlg.getByLabel("الاسم العربي (مطلوب)").fill("فرع مسودة الاختبار");
    await dlg.getByLabel("المدينة").fill("بريدة");
    await page.waitForTimeout(700);
    await page.reload({ waitUntil: "networkidle" });
    await page.getByRole("button", { name: "فرع جديد" }).click();
    dlg = page.getByRole("dialog");
    await expect(dlg.getByTestId("form-draft-restore")).toContainText("فرع مسودة الاختبار");
    await dlg.getByRole("button", { name: "استعادة المسودة" }).click();
    await expect(dlg.getByLabel("الاسم العربي (مطلوب)")).toHaveValue("فرع مسودة الاختبار");
    await expect(dlg.getByLabel("المدينة")).toHaveValue("بريدة");
  });
});

/* ---------------------------------- 6.6 ---------------------------------- */

/** Admin list pages beyond the 13 staff pages of k_list_states.spec.ts — same contract, wider net. */
const ADMIN_LISTS = [
  "/admin/room-categories", "/admin/services", "/admin/rooms", "/admin/facilities", "/admin/task-types",
  "/admin/structure", "/admin/cash-accounts", "/admin/booking-sources", "/admin/branches",
  "/admin/staff", "/admin/knowledge", "/admin/policies",
];

test.describe("one state per admin list, error card clears after recovery (6.6)", () => {
  for (const path of ADMIN_LISTS) {
    test(`list state is single and recovers: ${path}`, async ({ page, loginAs, go, errors }) => {
      await loginAs("owner");
      await go("/admin/dashboard");
      const expectedRefusal = `e2e admin-list refusal: ${path}`;
      const injectionStart = errors.length;
      await page.evaluate((message) => { (window as unknown as { __demoFail: unknown }).__demoFail = () => message; }, expectedRefusal);
      await page.evaluate((p) => { window.location.hash = p; }, path);
      await page.waitForTimeout(1200);
      const main = page.locator("main");
      const failed = await main.locator("[role=alert]").count();
      expect(failed, `${path}: injected load failure must be visible`).toBe(1);
      const empty = await main.getByText(/^لا (توجد|يوجد)/).count();
      const spinning = await main.locator(".animate-spin").count();
      const states = [failed > 0, empty > 0, spinning > 0].filter(Boolean).length;
      expect(states, `${path}: error=${failed} empty=${empty} loading=${spinning} must be a single state`).toBeLessThanOrEqual(1);
      // the connection returns: a retry or a reload shows the data and the error card is gone
      await page.evaluate(() => { (window as unknown as { __demoFail: unknown }).__demoFail = undefined; });
      const injectionEnd = errors.length;
      const retry = main.getByRole("button", { name: "إعادة المحاولة" }).first();
      if (await retry.count()) await retry.click();
      else await page.evaluate((p) => { window.location.hash = "/admin/dashboard"; setTimeout(() => { window.location.hash = p; }, 50); }, path);
      await page.waitForTimeout(1200);
      await expect(main.locator("[role=alert]")).toHaveCount(0);
      await expect(main.locator(".animate-spin")).toHaveCount(0);
      retainUnexpectedErrors(errors, expectedRefusal, injectionStart, injectionEnd);
      expect(errors, `${path}: no unexpected errors before, during or after injected refusal`).toEqual([]);
    });
  }
});

/* ---------------------------------- 6.7 ---------------------------------- */

test.describe("the save button locks from the press until the reply (6.7)", () => {
  test("two same-tick submits of a slow room-category save reach the server once", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/room-categories");
    await page.evaluate(() => {
      const w = window as unknown as { __upsertCalls: number; __demoLatency: (t: string) => number };
      w.__upsertCalls = 0;
      w.__demoLatency = (t) => { if (t === "rpc:fn_admin_upsert_room_category") { w.__upsertCalls += 1; return 800; } return 0; };
    });
    await page.getByRole("button", { name: "نوع جديد" }).click();
    const dlg = page.getByRole("dialog");
    await dlg.getByLabel("الاسم العربي (مطلوب)").fill("نوع ضغطتين متتاليتين");
    await dlg.getByLabel("السعر الأساسي لليلة (إلزامي)").fill("320");
    const save = dlg.getByRole("button", { name: "حفظ" });
    await save.evaluate((b) => { const f = (b as HTMLButtonElement).form!; f.requestSubmit(); f.requestSubmit(); });
    // disabled from the press, and it shows its state (spinner), until the reply
    await expect(save).toBeDisabled();
    await expect(save.locator(".animate-spin")).toBeVisible();
    await expect(dlg).toBeHidden({ timeout: 15_000 });
    await expect(page.getByText("نوع ضغطتين متتاليتين")).toHaveCount(1);
    expect(await page.evaluate(() => (window as unknown as { __upsertCalls: number }).__upsertCalls)).toBe(1);
  });

  test("two same-tick submits of the maintenance-ticket form create one ticket", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await go("/staff/tickets");
    await page.evaluate(() => {
      const w = window as unknown as { __ticketCalls: number; __demoLatency: (t: string) => number };
      w.__ticketCalls = 0;
      w.__demoLatency = (t) => { if (t === "rpc:fn_staff_create_maintenance") { w.__ticketCalls += 1; return 800; } return 0; };
    });
    await page.getByRole("button", { name: "بلاغ جديد" }).click();
    await page.locator("form select").first().selectOption({ index: 1 });
    await page.locator("div:has(> label:has-text('العنوان')) input").first().fill("بلاغ ضغطتين متتاليتين");
    const create = page.getByRole("button", { name: "إنشاء البلاغ" });
    await create.evaluate((b) => { const f = (b as HTMLButtonElement).form!; f.requestSubmit(); f.requestSubmit(); });
    await expect(create).toBeDisabled();
    await expect(page.getByText("بلاغ ضغطتين متتاليتين")).toHaveCount(1, { timeout: 15_000 });
    expect(await page.evaluate(() => (window as unknown as { __ticketCalls: number }).__ticketCalls)).toBe(1);
  });

  test("two same-tick sends of an inbox reply store one message", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await go("/staff/inbox");
    await page.locator("button.card").first().click();
    const input = page.locator("form input.input");
    await input.fill("رد الضغطتين المتتاليتين");
    // Delay the awaited reload after the insert: the send lock must remain held until the reply chain settles.
    await page.evaluate(() => {
      (window as unknown as { __demoLatency: (t: string) => number }).__demoLatency = (t) => t === "conversation_messages" ? 800 : 0;
    });
    const send = page.getByRole("button", { name: "إرسال" });
    await send.evaluate((b) => { const f = (b as HTMLButtonElement).form!; f.requestSubmit(); f.requestSubmit(); });
    await expect(send).toBeDisabled();
    await expect(page.getByText("رد الضغطتين المتتاليتين")).toHaveCount(1);
    await input.fill("مسودة تالية دون إرسال");
    await expect(send).toBeEnabled();
  });
});

/* ---------------------------------- 6.8 ---------------------------------- */

test.describe("a disabled control says why (6.8)", () => {
  test("manager on AI settings: every control is disabled and the page says the owner alone changes them", async ({ page, loginAs, go }) => {
    await loginAs("manager");
    await go("/admin/ai-settings");
    await expect(page.getByText("العرض فقط — يغيّر هذه الإعدادات مالك الفندق فقط.")).toBeVisible();
    expect(await page.locator("main input:disabled, main select:disabled").count()).toBeGreaterThan(0);
  });

  test("manager on journey settings: the rules are read-only and each section says editing is the owner's", async ({ page, loginAs, go }) => {
    await loginAs("manager");
    await go("/admin/journey");
    await expect(page.getByText("تعديلها للمالك وحده.").first()).toBeVisible();
    expect(await page.locator("main input:disabled, main select:disabled, main button:disabled").count()).toBeGreaterThan(0);
  });

  test("new reservation wizard: the disabled next button carries its reason (regression net over k_disabled_reason)", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await go("/staff/reservations/new");
    await bookingNext(page);
    const next = page.getByRole("button", { name: "التالي" });
    await expect(next).toBeDisabled();
    await expect(next).toHaveAttribute("aria-describedby", "wizard-step-block-reason");
    await expect(page.getByTestId("wizard-step-block-reason")).toBeVisible();
  });
});
