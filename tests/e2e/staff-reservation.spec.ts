/**
 * Reservation lifecycle through the staff UI — test ids SR01–SR05 (decision 57: renamed from R01–R03 / F01–F02;
 * the testing rules' R and F scenarios themselves run against the server in tests/sql/core_tests.sql).
 * Controls: G05 (no double allocation — SR02), G10 (a partial payment is never "paid" — SR01, SR04), G11 (the
 * deposit is a separate balance — SR01), G12 (refunds capped at what was received; cancel never refunds — SR03),
 * G22 (operations are audited — SR01).
 */
import { test, expect, createReservation, financeCell, parseSar } from "./fixtures";

test.describe("staff reservation lifecycle", () => {
  test("SR01 create → deposit → partial payment stays 'دفع جزئي' → extension is audited", async ({ page, loginAs }) => {
    await loginAs("owner");
    await createReservation(page, "عبدالعزيز سالم المالكي", "0509998877");

    // header shows the reservation + a payment badge that is NOT "paid"
    await expect(page.getByRole("heading", { name: "الملخص المالي" })).toBeVisible();
    const total = await financeCell(page, "الإجمالي");
    expect(total).toBeGreaterThan(0);

    // deposit (security) → separate ledger, does not reduce balance due
    const dueBefore = await financeCell(page, "المتبقي");
    await page.getByRole("button", { name: "قبض تأمين" }).click();
    const dlg = page.getByRole("dialog");
    await dlg.locator("input[type=number]").first().fill("200");
    await dlg.getByRole("button", { name: "حفظ السند" }).click();
    await expect(dlg).toBeHidden();
    await expect.poll(() => financeCell(page, "رصيد التأمين")).toBe(200);
    expect(await financeCell(page, "المتبقي")).toBe(dueBefore);

    // partial receipt → status must read "دفع جزئي", never "مدفوع"
    await page.getByRole("button", { name: "سند قبض إقامة" }).click();
    const dlg2 = page.getByRole("dialog");
    await dlg2.locator("input[type=number]").first().fill(String(Math.max(1, Math.floor(dueBefore / 2))));
    await dlg2.getByRole("button", { name: "حفظ السند" }).click();
    await expect(dlg2).toBeHidden();
    await expect.poll(() => financeCell(page, "المتبقي")).toBeLessThan(dueBefore);
    expect(await financeCell(page, "المتبقي")).toBeGreaterThan(0);
    await expect(page.getByText("دفع جزئي").first()).toBeVisible();
    await expect(page.locator("span", { hasText: /^مدفوع$/ })).toHaveCount(0);

    // extension: reason required, dates change, history records before/after
    await page.getByRole("button", { name: "الإقامة" }).click();
    await page.getByRole("button", { name: "تغيير المغادرة / تمديد" }).click();
    const ext = page.getByRole("dialog");
    const dateInput = ext.locator("input[type=date]");
    const cur = await dateInput.inputValue();
    const d = new Date(cur + "T00:00:00Z");
    d.setUTCDate(d.getUTCDate() + 2);
    await dateInput.fill(d.toISOString().slice(0, 10));
    await ext.locator("textarea").fill("طلب الضيف تمديد يومين");
    await ext.getByRole("button", { name: "تطبيق" }).click();
    await expect(ext).toBeHidden();
    await expect.poll(() => financeCell(page, "الإجمالي")).toBeGreaterThan(total);
    await page.getByRole("button", { name: "السجل" }).click();
    await expect(page.getByText("السبب: طلب الضيف تمديد يومين")).toBeVisible();
  });

  test("SR02 the same room cannot be booked twice for overlapping nights", async ({ page, loginAs }) => {
    await loginAs("owner");
    await createReservation(page, "ضيف الأول", "0501110001");
    const roomLine = page.getByText(/غرفة \d+/).first();
    await expect(roomLine).toBeVisible();
    const roomNumber = (await roomLine.innerText()).match(/غرفة (\S+)/)![1];

    // second reservation for the same dates: that room must no longer be offered
    await page.goto("/#/staff/reservations/new", { waitUntil: "networkidle" });
    await page.locator("div:has(> label:has-text('الاسم (مطلوب)')) input").first().fill("ضيف الثاني");
    await page.getByPlaceholder("05xxxxxxxx").fill("0501110002");
    await page.waitForTimeout(500);
    const roomSel = page.locator("select").filter({ has: page.locator("option:has-text('تخصيص لاحقًا')") });
    const options = await roomSel.locator("option").allTextContents();
    expect(options.some((o) => o.includes(roomNumber))).toBe(false);
  });

  test("SR03 refund is capped at what was actually received, and cancel never refunds by itself", async ({ page, loginAs }) => {
    await loginAs("owner");
    await createReservation(page, "ضيف الاسترداد", "0501110003");
    await page.getByRole("button", { name: "سند قبض إقامة" }).click();
    let dlg = page.getByRole("dialog");
    await dlg.locator("input[type=number]").first().fill("100");
    await dlg.getByRole("button", { name: "حفظ السند" }).click();
    await expect(dlg).toBeHidden();
    await expect.poll(() => financeCell(page, "المحصل")).toBe(100);

    // refund 150 against 100 received → rejected server-side (no fake success)
    await page.getByRole("button", { name: "استرداد إقامة" }).click();
    dlg = page.getByRole("dialog");
    await dlg.locator("input[type=number]").first().fill("150");
    await dlg.locator("textarea").fill("اختبار تجاوز المبلغ");
    await dlg.getByRole("button", { name: "تنفيذ" }).click();
    await expect(dlg.getByText("المبلغ يتجاوز الرصيد القابل للاسترداد.")).toBeVisible();
    await dlg.getByRole("button", { name: "إلغاء" }).click();
    expect(await financeCell(page, "المحصل")).toBe(100);

    // cancel the reservation: money stays, the warning says a refund is a separate decision
    await page.getByRole("button", { name: "الإقامة" }).click();
    await page.getByRole("button", { name: "إلغاء الحجز" }).click();
    dlg = page.getByRole("dialog");
    await expect(dlg.getByText(/لا يسترد أي مبلغ تلقائيًا/)).toBeVisible();
    await dlg.locator("textarea").fill("طلب الضيف الإلغاء");
    await dlg.getByRole("button", { name: "تأكيد" }).click();
    await expect(dlg).toBeHidden();
    await expect(page.getByText("ملغى", { exact: true }).first()).toBeVisible();
    expect(await financeCell(page, "المحصل")).toBe(100);
  });

  test("SR04 the reservations list shows money as SAR with partial state, never a rounded 'paid'", async ({ page, loginAs }) => {
    await loginAs("finance");
    await page.goto("/#/staff/reservations", { waitUntil: "networkidle" });
    await expect(page.locator("table tbody tr").first()).toBeVisible();
    const rows = page.locator("table tbody tr");
    const n = await rows.count();
    let partial = 0, paidInFull = 0;
    for (let i = 0; i < n; i++) {
      const cells = await rows.nth(i).locator("td[dir=ltr]").allInnerTexts();
      const sar = cells.filter((c) => c.includes("ر.س")).map(parseSar);
      expect(sar.length, "total / balance / deposit columns").toBeGreaterThanOrEqual(3);
      const [total, balance] = sar;
      expect(Number.isFinite(total) && Number.isFinite(balance)).toBe(true);
      if (balance > 0 && balance < total) partial++;
      if (balance === 0 && total > 0) paidInFull++;
    }
    // the seed contains partially paid stays: they must show a real remaining balance, not "paid"
    expect(partial).toBeGreaterThan(0);
    expect(paidInFull).toBeGreaterThan(0);
  });

  test("SR05 Zaaer parity: arrival time, named companions and two units in one booking (atomic group)", async ({ page, loginAs }) => {
    await loginAs("supervisor");
    await page.goto("/#/staff/reservations/new", { waitUntil: "networkidle" });
    await page.locator("div:has(> label:has-text('الاسم (مطلوب)')) input").first().fill("عائلة المجموعة");
    await page.getByPlaceholder("05xxxxxxxx").fill("0501110009");
    await page.locator("div:has(> label:has-text('وقت الوصول المتوقع')) input").fill("18:30");
    await page.getByRole("button", { name: /تسجيل اسم مرافق/ }).click();
    await page.getByPlaceholder("اسم المرافق 1").fill("سارة");
    await page.getByPlaceholder("صلة القرابة").fill("ابنة");
    await page.getByRole("button", { name: "وحدة أخرى في نفس الحجز" }).click();
    await page.getByRole("button", { name: "إنشاء 2 حجوزات" }).click();
    await page.waitForURL(/#\/staff\/reservations\/[0-9a-f-]+/, { timeout: 15_000 });
    await expect(page.getByText(/حجز جماعي G-[0-9A-F]+ — 2 وحدات/)).toBeVisible();
    await expect(page.getByText(/ 18:30 →/)).toBeVisible();
    await expect(page.getByText("سارة").first()).toBeVisible();
  });
});
