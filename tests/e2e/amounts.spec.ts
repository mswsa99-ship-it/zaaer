/**
 * The money field and the amount boxes (correction batch 2, the owner's notes 2 and 7; tasks B2 and B6).
 * AM01 is the unit facet (tests/unit/amount_input.test.ts); these are the screen facets.
 */
import { test, expect, createReservation } from "./fixtures";

test.describe("amounts (correction batch 2)", () => {
  test("AM02 typing 2 in a money field gives 2 riyals, Arabic digits are read, halalas only after the point", async ({ page, loginAs }) => {
    await loginAs("supervisor");
    await page.goto("/#/staff/reservations/new", { waitUntil: "networkidle" });
    const discount = page.locator("div:has(> label:has-text('خصم (إجمالي)')) input[data-money]");
    await expect(discount).toHaveValue("");                       // starts empty, not 0.00
    await discount.fill("2");
    await expect(discount).toHaveValue("2");
    await discount.blur();
    await expect(discount).toHaveValue("2");                      // never rewritten to 0.002 or 2.00
    await discount.fill("٢٥٠٫٥");
    await discount.blur();
    await expect(discount).toHaveValue("250.50");
    await discount.fill("");
    await discount.pressSequentially("12.345");                    // a third decimal is not taken
    await expect(discount).toHaveValue("12.34");
  });

  test("AM03 on a phone the financial summary's boxes never overlap and no amount is cut", async ({ page, loginAs }) => {
    await loginAs("supervisor");
    await page.setViewportSize({ width: 390, height: 844 });
    await createReservation(page, "ضيف الصناديق", "0551239876");
    const boxes = page.getByTestId("finance-grid").locator(":scope > div");
    await expect(boxes.first()).toBeVisible();
    const rects = await boxes.evaluateAll((els) => els.map((e) => {
      const r = e.getBoundingClientRect();
      const v = e.lastElementChild as HTMLElement;
      return { x: r.x, y: r.y, w: r.width, h: r.height, cut: v.scrollWidth > v.clientWidth + 1, right: r.right };
    }));
    expect(rects.length).toBeGreaterThanOrEqual(7);
    for (const r of rects) { expect(r.cut).toBe(false); expect(r.right).toBeLessThanOrEqual(390); }
    for (let i = 0; i < rects.length; i++) for (let j = i + 1; j < rects.length; j++) {
      const a = rects[i], b = rects[j];
      const overlap = a.x < b.x + b.w - 1 && b.x < a.x + a.w - 1 && a.y < b.y + b.h - 1 && b.y < a.y + a.h - 1;
      expect(overlap, `box ${i} overlaps box ${j}`).toBe(false);
    }
  });
});
