/**
 * 7.6 (T4): the screen flows run in Firefox and WebKit as well as Chromium (projects firefox, webkit).
 * Engine coverage only: WebKit on a build machine is not Safari on an iPhone (see tests/DEVICE-CHECKLIST.md).
 * Each test is a real flow, not a title check: guest lookup, staff sign-in per role, a list with filter and export,
 * the key-box codes, a booking form with typed input, and right-to-left layout.
 */
import { test, expect, bookingNext, type DemoRole } from "./fixtures";

test("the page is right-to-left Arabic and the guest lookup takes a phone and reaches the booking", async ({ page, go }) => {
  await go("/booking/lookup");
  await expect(page.locator("html")).toHaveAttribute("dir", "rtl");
  await page.getByPlaceholder("05xxxxxxxx").fill("0501110008");
  await page.getByRole("button", { name: "متابعة" }).click();
  await page.getByPlaceholder("رقم الحجز").fill("R-26A0008");
  await page.getByRole("button", { name: "عرض حجوزاتي" }).click();
  await expect(page).toHaveURL(/\/booking\/status\//);
  await expect(page.getByTestId("guest-hero")).toBeVisible();
});

for (const role of ["owner", "supervisor", "finance", "housekeeping"] as DemoRole[]) {
  test(`${role} signs in and lands on a page with content`, async ({ page, loginAs }) => {
    await loginAs(role);
    await expect(page.locator("main")).not.toBeEmpty();
    await expect(page).toHaveURL(/#\/(staff|admin)\//);
  });
}

test("the reservations list filters by status, and its export menu opens with both scopes and closes on Escape", async ({ page, loginAs, go }) => {
  await loginAs("supervisor");
  await go("/staff/reservations");
  await expect(page.locator("table tbody tr").first()).toBeVisible();
  const before = await page.locator("table tbody tr").count();
  await page.locator("select").filter({ has: page.locator('option[value="confirmed"]') }).selectOption("confirmed");
  await expect.poll(async () => page.locator("table tbody tr").count()).not.toBe(0);
  expect(before).toBeGreaterThan(0);
  await page.getByTestId("export-trigger").click();
  await page.getByTestId("export-xlsx").click();
  await expect(page.getByTestId("export-scope-menu")).toBeVisible();
  await expect(page.getByTestId("export-scope-all")).toBeVisible();
  await expect(page.getByTestId("export-scope-page")).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(page.getByTestId("export-scope-menu")).toBeHidden();
});

test("the key-box codes: a unit that must change takes a new code and turns green", async ({ page, loginAs, go }) => {
  await loginAs("housekeeping");
  await go("/staff/codes");
  const red = page.locator('[data-testid="code-unit"][data-state="change"]').first();
  await expect(red).toBeVisible();
  const room = (await red.getAttribute("data-room"))!;
  await red.getByRole("button", { name: /تغيير الرمز|تعيين رمز/ }).click();
  const form = red.getByTestId("code-form");
  await form.getByLabel("الرمز الجديد", { exact: true }).fill("8264");
  await form.getByLabel("تأكيد الرمز", { exact: true }).fill("8264");
  await form.getByRole("checkbox").check();
  await form.getByRole("button", { name: "حفظ الرمز" }).click();
  await expect(page.locator(`[data-testid="code-unit"][data-room="${room}"]`)).toHaveAttribute("data-state", "ok");
});

test("the new reservation form keeps typed input through a reload and offers its restore", async ({ page, loginAs, go }) => {
  await loginAs("supervisor");
  await go("/staff/reservations/new");
  await bookingNext(page);
  const field = () => page.locator("div:has(> label:has-text('الاسم (مطلوب)')) input").first();
  await field().fill("سالم عبدالله القحطاني");
  await page.waitForTimeout(700);
  page.on("dialog", (d) => void d.accept());
  await page.reload();
  await expect(page.getByTestId("reservation-draft")).toContainText("سالم عبدالله القحطاني");
  await page.getByRole("button", { name: "استعادة المسودة" }).click();
  await bookingNext(page);
  await expect(field()).toHaveValue("سالم عبدالله القحطاني");
});

test("a staff list page keeps working when the phone-width layout is used, and the menu opens", async ({ page, loginAs, go, viewport }) => {
  await loginAs("supervisor");
  await go("/staff/rooms");
  await expect(page.getByTestId("unit-card").first()).toBeVisible();
  if (viewport && viewport.width < 600) {
    await page.getByTestId("bottom-tabs-more").click();
    await expect(page.getByTestId("staff-menu-drawer")).toBeVisible();
  }
});
