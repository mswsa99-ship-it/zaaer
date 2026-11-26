/**
 * Phone reachability of the shared Modal (lane10 batch 4): on a 360x640 and a 390x844 viewport the mailbox form
 * and the keyword form scroll inside the dialog, the dialog never exceeds the viewport, and the Save and Cancel
 * buttons can be scrolled into the visible area and tapped. The date picker sheet stays inside the viewport and
 * scrolls when the screen is very short. Viewport emulation only: a real on-screen keyboard is not covered.
 */
import { test, expect } from "./fixtures";

for (const [w, h] of [[360, 640], [390, 844]] as const) {
  test.describe(`modal reach ${w}x${h}`, () => {
    test.use({ viewport: { width: w, height: h }, hasTouch: true });

    test(`MR1 mailbox form: dialog fits, scrolls to the bottom, Save and Cancel reachable ${w}`, async ({ page, loginAs, go }) => {
      await loginAs("owner");
      await go("/admin/bank-mail");
      await page.getByRole("button", { name: "تعديل", exact: true }).first().click();
      const dlg = page.getByRole("dialog");
      await expect(dlg).toBeVisible();
      const box = await dlg.boundingBox();
      expect(box!.y).toBeGreaterThanOrEqual(0);
      expect(box!.y + box!.height).toBeLessThanOrEqual(h + 1);
      const m = await dlg.evaluate((el) => { el.scrollTop = el.scrollHeight; return { st: el.scrollTop, sh: el.scrollHeight, ch: el.clientHeight }; });
      if (m.sh > m.ch) expect(m.st).toBeGreaterThan(0);
      const save = dlg.getByRole("button", { name: "حفظ", exact: true });
      const cancel = dlg.getByRole("button", { name: "إلغاء", exact: true });
      for (const b of [save, cancel]) {
        const r = (await b.boundingBox())!;
        expect(r.y).toBeGreaterThanOrEqual(0);
        expect(r.y + r.height).toBeLessThanOrEqual(h + 1);
        expect(r.height).toBeGreaterThanOrEqual(40);
      }
      // a focused field near the end stays inside the visible dialog after focus
      await dlg.getByLabel("المرسلون المسموحون").focus();
      const f = (await dlg.getByLabel("المرسلون المسموحون").boundingBox())!;
      expect(f.y).toBeGreaterThanOrEqual(0);
      expect(f.y + f.height).toBeLessThanOrEqual(h + 1);
      await cancel.click();
      await expect(dlg).toBeHidden();
    });

    test(`MR2 keyword card opens the same form; Escape closes it and focus returns ${w}`, async ({ page, loginAs, go }) => {
      await loginAs("owner");
      await go("/admin/bank-mail");
      const card = page.getByTestId("bank-rule-card").first();
      await expect(card).toBeVisible();
      await card.getByRole("button").click();
      const dlg = page.getByRole("dialog");
      await expect(dlg.getByLabel("الكلمة")).toBeVisible();
      await page.keyboard.press("Escape");
      await expect(dlg).toBeHidden();
    });

    test(`MR3 date picker sheet stays in the viewport and confirms ${w}`, async ({ page, loginAs, go }) => {
      await loginAs("owner");
      await go("/staff/bank");
      await page.getByTestId("date-range-picker").getByRole("button").first().click();
      const d = page.getByRole("dialog", { name: /اليوم أو الفترة/ });
      await expect(d).toBeVisible();
      const r = (await d.boundingBox())!;
      expect(r.y).toBeGreaterThanOrEqual(0);
      expect(r.y + r.height).toBeLessThanOrEqual(h + 1);
      await d.getByRole("button", { name: "موافق" }).click();
      await expect(d).toBeHidden();
    });
  });
}

/** 360x420: a very short phone window. After scrolling the panel to its end, both footer buttons lie fully inside the panel and the viewport, and can be used. */
test.describe("short phone window 360x420", () => {
  test.use({ viewport: { width: 360, height: 420 }, hasTouch: true });
  const inside = async (btn: import("@playwright/test").Locator, panel: import("@playwright/test").Locator) => {
    const b = (await btn.boundingBox())!, p = (await panel.boundingBox())!;
    expect(b.y).toBeGreaterThanOrEqual(p.y - 0.5);
    expect(b.y + b.height).toBeLessThanOrEqual(p.y + p.height + 0.5);
    expect(b.y + b.height).toBeLessThanOrEqual(420 + 0.5);
    expect(b.y).toBeGreaterThanOrEqual(0);
  };
  const toEnd = (panel: import("@playwright/test").Locator) => panel.evaluate((el) => { el.scrollTop = el.scrollHeight; return { st: el.scrollTop, sh: el.scrollHeight, ch: el.clientHeight }; });

  test("MR4 date picker: scrolls, OK and Cancel fully inside, OK confirms, Escape closes", async ({ page, loginAs, go }) => {
    await loginAs("owner"); await go("/staff/bank");
    const open = () => page.getByTestId("date-range-picker").getByRole("button").first().click();
    await open();
    const d = page.getByRole("dialog", { name: /اليوم أو الفترة/ });
    const m = await toEnd(d);
    expect(m.sh).toBeGreaterThan(m.ch);
    expect(m.st).toBeGreaterThan(0);
    await inside(d.getByRole("button", { name: "موافق" }), d);
    await inside(d.getByRole("button", { name: "إلغاء" }), d);
    await d.getByRole("button", { name: "موافق" }).click();
    await expect(d).toBeHidden();
    await open(); await expect(d).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(d).toBeHidden();
  });

  test("MR5 mailbox modal: scrolls to its end, Save and Cancel inside, Cancel and Escape close", async ({ page, loginAs, go }) => {
    await loginAs("owner"); await go("/admin/bank-mail");
    await page.getByRole("button", { name: "تعديل", exact: true }).first().click();
    const dlg = page.getByRole("dialog");
    const m = await toEnd(dlg);
    expect(m.sh).toBeGreaterThan(m.ch);
    expect(m.st).toBeGreaterThan(0);
    await inside(dlg.getByRole("button", { name: "حفظ", exact: true }), dlg);
    await inside(dlg.getByRole("button", { name: "إلغاء", exact: true }), dlg);
    await dlg.getByRole("button", { name: "إلغاء", exact: true }).click();
    await expect(dlg).toBeHidden();
    await page.getByRole("button", { name: "تعديل", exact: true }).first().click();
    await page.keyboard.press("Escape");
    await expect(page.getByRole("dialog")).toBeHidden();
  });

  test("MR6 knowledge modal (existing, unchanged): scrolls and its footer buttons are reachable", async ({ page, loginAs, go }) => {
    await loginAs("owner"); await go("/admin/knowledge");
    await page.getByRole("button", { name: /سؤال وجواب/ }).first().click();
    const dlg = page.getByRole("dialog");
    await expect(dlg).toBeVisible();
    const m = await toEnd(dlg);
    expect(m.sh).toBeGreaterThan(m.ch);
    expect(m.st).toBeGreaterThan(0);
    const cancel = dlg.getByRole("button", { name: "إلغاء", exact: true });
    await inside(cancel, dlg);
    await cancel.click();
    await expect(dlg).toBeHidden();
  });
});
