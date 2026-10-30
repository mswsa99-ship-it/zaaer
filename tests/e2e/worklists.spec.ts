/**
 * Correction batch 4 (B8–B12): the work lists open on what is not done, with the done items of a window on demand;
 * the units board is the front desk's first page; the occupancy strip filters the units it counts.
 */
import { test, expect } from "./fixtures";

test.describe("work lists and the units board (correction batch 4)", () => {
  test("LW01 the supervisor lands on the units board, which comes first in the menu", async ({ page, loginAs }) => {
    await loginAs("supervisor");
    await expect(page).toHaveURL(/#\/staff\/rooms/);
    await expect(page.getByRole("heading", { name: "لوحة الوحدات" })).toBeVisible();
    const nav = page.locator("nav a[href*='/staff/']");
    await expect(nav.first()).toContainText("لوحة الوحدات");
  });

  test("LW02 the occupancy strip shows the figures large, and a figure filters the units it counts", async ({ page, loginAs }) => {
    await loginAs("supervisor");
    const strip = page.getByTestId("occupancy-strip");
    await expect(strip.getByTestId("strip-occupancy")).toContainText("%");
    const maint = Number((await strip.getByTestId("strip-maintenance").locator("[dir=ltr]").innerText()).replace(/[^\d]/g, ""));
    await strip.getByTestId("strip-maintenance").click();
    await expect(strip.getByTestId("strip-maintenance")).toHaveAttribute("aria-pressed", "true");
    await expect(page.locator(".card").filter({ hasText: "صيانة" })).toHaveCount(maint);
    await strip.getByTestId("strip-occupancy").click();
    await expect(strip.getByTestId("strip-occupancy")).toHaveAttribute("aria-pressed", "true");
  });

  test("LW03 identity, payments and arrivals open on «غير المعالَج»; the done items of their window are one tap away", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    for (const [path, done] of [["/staff/identity-verification", "طُوبق"], ["/staff/payments", "سُدِّد"], ["/staff/access-approvals", "تمت معالجته"]] as const) {
      await go(path);
      await expect(page.getByTestId("list-filter-open")).toHaveAttribute("aria-pressed", "true");
      await page.getByTestId("list-filter-done").click();
      await expect(page.getByTestId("list-filter-done")).toContainText(done);
      await expect(page.getByTestId("list-filter-done")).toHaveAttribute("aria-pressed", "true");
    }
    // a stay paid in part is still owed: it is listed under «غير المسدَّد»
    await go("/staff/payments");
    await expect(page.getByTestId("list-filter-open")).toContainText("غير المسدَّد");
  });

  test("PV03 a voucher and an invoice print on A4 or an 80 mm receipt, with the amount in words", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await go("/staff/reservations");
    await page.getByPlaceholder("مرجع / ضيف / جوال").fill("R-26A0008");
    const row = page.locator("table tbody tr").filter({ hasText: "R-26A0008" }).first();
    await row.getByRole("link", { name: "فتح" }).click();
    await page.waitForURL(/#\/staff\/reservations\/[0-9a-f-]+/);
    // the print frame is written and printed; the test reads what it holds
    const btn = page.locator("[data-testid^=print-voucher-]").first();
    await btn.click();
    await expect(page.getByRole("button", { name: "إيصال 80 مم" })).toBeVisible();
    await page.getByRole("button", { name: "صفحة A4" }).click();
    await expect.poll(async () => page.evaluate(() => [...document.querySelectorAll("iframe")].map((f) => f.contentDocument?.body?.innerText ?? "").join("|"))).toContain("لا غير");
  });

  test("LW04 on a phone the owner opens the administration menu and reaches every group, «تفريغ البيانات» included", async ({ page, loginAs, go }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await loginAs("owner");
    await go("/admin/dashboard");
    await page.getByTestId("admin-menu-button").click();
    const drawer = page.getByTestId("admin-menu-drawer");
    await expect(drawer).toBeVisible();
    await expect(drawer).toContainText("الحوكمة");
    await drawer.getByRole("link", { name: "تفريغ البيانات" }).click();
    await expect(page).toHaveURL(/#\/admin\/data-purge/);
    await expect(drawer).toBeHidden();
  });
});

test.describe("the imported guests (I5)", () => {
  test("LW05 a guest without a phone or a document is marked «يحتاج استكمال» and has its own filter", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/guests");
    await expect(page.getByTestId("guest-row").first()).toBeVisible();
    await page.getByTestId("guest-filter-incomplete").click();
    await expect(page.getByTestId("guest-filter-incomplete")).toHaveAttribute("aria-pressed", "true");
    const rows = page.getByTestId("guest-row");
    await expect(rows.first()).toBeVisible();
    await expect(rows.filter({ hasNot: page.getByTestId("guest-incomplete") })).toHaveCount(0);   // every row listed is incomplete
    await page.getByTestId("guest-filter-all").click();
    await expect(rows.filter({ hasNot: page.getByTestId("guest-incomplete") }).first()).toBeVisible();   // and «الكل» shows complete ones too
  });
});
