/**
 * The unit's licence number (0075, plan item 1.8) on the screens — the UI facet of tests/sql/unit_license_tests.sql
 * and UL20–UL27: the owner and the manager see it and change it in «الوحدات», the supervisor sees it on the units
 * board, finance and housekeeping see no trace of it, and no guest page carries it. The demo's two units with a
 * licence are 101 and 102 (fictional numbers).
 */
import { test, expect } from "./fixtures";

test.describe("unit licence number", () => {
  test("UL30 the owner sees each unit's licence in «الوحدات», sets one for 103, and the units board shows it", async ({ page, loginAs, go, errors }) => {
    void errors;
    await loginAs("owner");
    await go("/admin/rooms");
    await expect(page.locator('[data-testid="admin-unit-card"][data-room="101"]').getByTestId("unit-license")).toContainText("DEMO-LIC-0101");
    await expect(page.locator('[data-testid="admin-unit-card"][data-room="103"]').getByTestId("unit-license")).toHaveText("بلا رقم ترخيص");
    await page.getByRole("button", { name: "تعديل الوحدة 103" }).click();
    await expect(page.getByTestId("unit-license-input")).toHaveValue("");
    await page.getByTestId("unit-license-input").fill("tl-٢٠٢٥/0103");
    await page.getByRole("button", { name: "حفظ" }).click();
    await expect(page.getByRole("dialog")).toHaveCount(0);
    await expect(page.locator('[data-testid="admin-unit-card"][data-room="103"]').getByTestId("unit-license")).toContainText("TL-2025/0103");
    await go("/staff/rooms");
    await expect(page.locator('[data-testid="unit-card"][data-room="103"]').getByTestId("unit-license")).toContainText("TL-2025/0103");
    await expect(page.locator('[data-testid="unit-card"][data-room="101"]').getByTestId("unit-license")).toContainText("DEMO-LIC-0101");
  });

  test("UL31 a wrong number is named under the field and saves nothing — not the licence, not the unit", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/rooms");
    await page.getByRole("button", { name: "تعديل الوحدة 101" }).click();
    await expect(page.getByTestId("unit-license-input")).toHaveValue("DEMO-LIC-0101");
    await page.getByLabel("ملاحظات").fill("ملاحظة لا تُحفظ");
    await page.getByTestId("unit-license-input").fill("ترخيص 12");
    await expect(page.getByRole("alert").filter({ hasText: "رقم ترخيص الوحدة" })).toBeVisible();
    await page.getByRole("button", { name: "حفظ" }).click();
    await expect(page.getByRole("dialog")).toBeVisible();
    await page.getByRole("button", { name: "إلغاء" }).click();
    await page.getByRole("button", { name: "تعديل الوحدة 101" }).click();
    await expect(page.getByTestId("unit-license-input")).toHaveValue("DEMO-LIC-0101");
    await expect(page.getByLabel("ملاحظات")).not.toHaveValue("ملاحظة لا تُحفظ");
  });

  test("UL32 the manager sees and changes it", async ({ page, loginAs, go }) => {
    await loginAs("manager");
    await go("/admin/rooms");
    await page.getByRole("button", { name: "تعديل الوحدة 102" }).click();
    await expect(page.getByTestId("unit-license-input")).toHaveValue("DEMO-LIC-0102");
    await page.getByTestId("unit-license-input").fill("");
    await page.getByRole("button", { name: "حفظ" }).click();
    await expect(page.getByRole("dialog")).toHaveCount(0);
    await go("/staff/rooms");
    await expect(page.locator('[data-testid="unit-card"][data-room="102"]').getByTestId("unit-license")).toHaveCount(0);
    await expect(page.locator('[data-testid="unit-card"][data-room="101"]').getByTestId("unit-license")).toContainText("DEMO-LIC-0101");
  });

  test("UL33 the supervisor sees it on the units board", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await go("/staff/rooms");
    await expect(page.locator('[data-testid="unit-card"][data-room="101"]').getByTestId("unit-license")).toContainText("DEMO-LIC-0101");
  });

  for (const role of ["finance", "housekeeping"] as const) {
    test(`UL34 ${role} sees no licence on the units board, and the page asks for none`, async ({ page, loginAs, go }) => {
      await loginAs(role);
      await go("/staff/rooms");
      await expect(page.locator('[data-testid="unit-card"]').first()).toBeVisible();
      await expect(page.getByTestId("unit-license")).toHaveCount(0);
      await expect(page.getByText("DEMO-LIC")).toHaveCount(0);
    });
  }

  test("UL36 on a phone (390 px) the unit's form with the licence field fits the screen", async ({ page, loginAs, go }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await loginAs("owner");
    await go("/admin/rooms");
    await page.getByRole("button", { name: "تعديل الوحدة 101" }).click();
    await expect(page.getByTestId("unit-license-input")).toBeVisible();
    const box = await page.getByTestId("unit-license-input").boundingBox();
    expect(box && box.x >= 0 && box.x + box.width <= 390).toBe(true);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  });

  test("UL35 no guest page carries a unit's licence number (the facility's own licence, a guest-page duty, is another field)", async ({ page, go }) => {
    for (const path of ["/", "/booking/lookup", "/booking/new"]) {
      await go(path);
      await expect(page.locator("body")).not.toContainText("DEMO-LIC");
    }
  });
});
