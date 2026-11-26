/** UX batch A: field-level errors and the open-ticket note on the maintenance form, announced notices, pill-tab edge cue. */
import { test, expect } from "./fixtures";

test("BATCHA1 maintenance form: the error sits at the field, the field is marked invalid, nothing is created", async ({ page, loginAs, go }) => {
  await page.setViewportSize({ width: 390, height: 844 }); await loginAs("owner"); await go("/staff/tickets");
  await page.getByRole("button", { name: /بلاغ/ }).first().click();
  const form = page.locator("[data-ticket-form]");
  await expect(form).toBeVisible();
  await form.getByRole("button", { name: "إنشاء البلاغ" }).click();
  const room = form.locator("select"); const title = form.locator("input").first();
  await expect(room).toHaveAttribute("aria-invalid", "true");
  await expect(title).toHaveAttribute("aria-invalid", "true");
  await expect(form.getByText("اختر الوحدة.")).toBeVisible();
  await expect(form.getByText("اكتب عنوان البلاغ.")).toBeVisible();
  await expect(room).toBeFocused();
  await room.selectOption({ index: 1 });
  await expect(room).not.toHaveAttribute("aria-invalid", "true");
  await expect(title).toHaveAttribute("aria-invalid", "true");
});

test("BATCHA2 an open report on the chosen unit is named; it does not block", async ({ page, loginAs, go }) => {
  await page.setViewportSize({ width: 390, height: 844 }); await loginAs("owner"); await go("/staff/tickets");
  await page.getByRole("button", { name: /بلاغ/ }).first().click();
  const form = page.locator("[data-ticket-form]");
  const opts = await form.locator("select option").evaluateAll((os) => os.map((o) => (o as HTMLOptionElement).value).filter(Boolean));
  let found = false;
  for (const v of opts) {
    await form.locator("select").selectOption(v);
    if (await page.getByTestId("ticket-dup-note").count()) { found = true; break; }
  }
  if (!found) {
    // no seeded open report: create one, then the same unit must show the note
    await form.locator("select").selectOption(opts[0]); await form.locator("input").first().fill("تسريب اختبار");
    await form.getByRole("button", { name: "إنشاء البلاغ" }).click();
    await page.getByRole("button", { name: /بلاغ/ }).first().click();
    await form.locator("select").selectOption(opts[0]);
  }
  await expect(page.getByTestId("ticket-dup-note")).toBeVisible();
  await form.locator("input").first().fill("عطل آخر");
  await form.getByRole("button", { name: "إنشاء البلاغ" }).click();
  await expect(form).toBeHidden();
});

test("BATCHA3 pill tab strips carry the sideways edge cue in dark and light on a phone", async ({ page, loginAs, go }) => {
  await page.setViewportSize({ width: 390, height: 844 }); await loginAs("owner");
  for (const scheme of ["dark", "light"] as const) {
    await page.emulateMedia({ colorScheme: scheme }); await go("/staff/accounts");
    const tl = page.locator('[role="tablist"].overflow-x-auto').first(); await expect(tl).toBeVisible();
    const img = await tl.evaluate((e) => getComputedStyle(e).backgroundImage);
    expect(img).toContain("gradient");
    if (scheme === "dark") expect(img).not.toContain("rgb(255, 255, 255)");
  }
});

test("BATCHA4 day close: when the review says what blocks the send, that box's own field is marked", async ({ page, loginAs, go }) => {
  await page.setViewportSize({ width: 390, height: 844 }); await loginAs("supervisor"); await go("/staff/day-close");
  const cash = page.getByTestId("closing-box-cash"); const pos = page.getByTestId("closing-box-pos");
  await cash.getByLabel("النقد: المُدخل").fill("1");
  await page.getByRole("button", { name: "مراجعة وإرسال" }).click();
  const dlg = page.getByRole("dialog");
  await expect(dlg.getByText(/ناقص قبل الإرسال/)).toBeVisible();
  await dlg.getByRole("button", { name: "إغلاق" }).first().click();
  await expect(pos.getByText("أدخل المبلغ المعدود (صفر إن لم يوجد).")).toBeVisible();
  await expect(pos.getByLabel("الشبكة: المُدخل")).toHaveAttribute("aria-invalid", "true");
  await expect(cash.getByLabel("النقد: سبب الفرق")).toBeFocused();   // the first marked field in page order
  await expect(cash.getByText("اكتب سبب الفرق.")).toBeVisible();
  await expect(cash.getByLabel("النقد: سبب الفرق")).toHaveAttribute("aria-invalid", "true");
});
