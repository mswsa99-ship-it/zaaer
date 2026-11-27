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
    await expect(w).toContainText("لنفس رقم الجوال");
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

  test("SB11 same name with a different phone says so (name only), the reference is isolated LTR and does not wrap at 390", async ({ page, loginAs }, info) => {
    await loginAs("supervisor");
    await createReservation(page, "فيصل الاسم", "0551112223", { pickRoom: false });
    await page.goto("/#/staff/reservations/new", { waitUntil: "networkidle" });
    await reachPrice(page, "فيصل الاسم", "0509998887");
    const w = page.getByTestId("similar-booking-warning");
    await expect(w).toBeVisible();
    await expect(w).toContainText("برقم جوال مختلف");
    await expect(w).not.toContainText("لنفس رقم الجوال");
    await page.setViewportSize({ width: 390, height: 844 });
    const ref = w.locator("bdi");
    await expect(ref).toHaveAttribute("dir", "ltr");
    const box = await ref.boundingBox();
    expect(box!.height).toBeLessThan(24);                       // one line, not wrapped
    await w.scrollIntoViewIfNeeded();
    await page.screenshot({ path: `/tmp/SB11_390_${info.project.name}.png` });
  });

  test("SB12 mixed matches: phone wording lists only the phone-matched reference, not the name-only one", async ({ page, loginAs }) => {
    await loginAs("supervisor");
    await createReservation(page, "هادي الأول", "0551110001", { pickRoom: false });
    await createReservation(page, "منصور الثاني", "0551110002", { pickRoom: false });
    await page.goto("/#/staff/reservations/new", { waitUntil: "networkidle" });
    await reachPrice(page, "هادي الأول", "0551110002");          // name of the first, phone of the second
    const w = page.getByTestId("similar-booking-warning");
    await expect(w).toContainText("لنفس رقم الجوال");
    await expect(w.locator("bdi")).not.toContainText(",");        // one reference only (the phone match)
  });

  test("SB13 a failed check is said so (not silent), creating stays allowed; a successful zero-result shows neither", async ({ page, loginAs }) => {
    await loginAs("supervisor");
    await page.goto("/#/staff/reservations/new", { waitUntil: "networkidle" });
    await page.evaluate(() => { (globalThis as { __raiFailSimilar?: boolean }).__raiFailSimilar = true; });
    await reachPrice(page, "عبدالله الفحص", "0553334445");
    const failed = page.getByTestId("similar-booking-failed");
    await expect(failed).toBeVisible();
    await expect(failed).toContainText("تعذّر التحقق");
    await expect(page.getByTestId("similar-booking-warning")).toHaveCount(0);
    await expect(page.getByRole("button", { name: "إنشاء الحجز" })).toBeEnabled();
    await page.evaluate(() => { (globalThis as { __raiFailSimilar?: boolean }).__raiFailSimilar = false; });
    await page.getByRole("button", { name: "السابق" }).click();
    await fillGuest(page, "سعد الجديد", "0556667778");
    await bookingNext(page);
    await expect(page.getByRole("button", { name: "إنشاء الحجز" })).toBeVisible();
    await expect(page.getByTestId("similar-booking-failed")).toHaveCount(0);
    await expect(page.getByTestId("similar-booking-warning")).toHaveCount(0);
  });
});
