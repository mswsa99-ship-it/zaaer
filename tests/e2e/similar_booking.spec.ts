/** 0154: the repeat-booking warning on the new-booking form. Demo build, not live proof. */
import { test, expect, createReservation, reachPrice, fillGuest, bookingNext } from "./fixtures";

test.describe("similar booking warning (0154)", () => {
  test("SB10 the same guest, same dates and unit type is warned (not blocked); a different guest is not", async ({ page, loginAs }, info) => {
    await loginAs("supervisor");
    await createReservation(page, "نايف المكرر", "0551234567", { pickRoom: false });
    await page.goto("/#/staff/reservations/new", { waitUntil: "networkidle" });
    await reachPrice(page, "نايف المكرر", "0551234567");
    const w = page.getByTestId("similar-booking-warning");
    await expect(w).toBeVisible();
    await expect(page.getByRole("button", { name: "إنشاء الحجز" })).toBeEnabled();   // a warning, never a block
    await w.scrollIntoViewIfNeeded();
    await page.screenshot({ path: `/tmp/SB10_${info.project.name}.png` });
    await page.setViewportSize({ width: 390, height: 844 });
    await w.scrollIntoViewIfNeeded();
    await page.screenshot({ path: `/tmp/SB10_390_${info.project.name}.png` });
    await page.getByRole("button", { name: "السابق" }).click();
    await fillGuest(page, "ناصر مختلف", "0507654321");
    await bookingNext(page);
    await expect(page.getByRole("button", { name: "إنشاء الحجز" })).toBeVisible();
    await expect(page.getByTestId("similar-booking-warning")).toHaveCount(0);
  });
});
