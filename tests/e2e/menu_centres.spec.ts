/** Plan 6.2 — the staff menu counts at most 12 items for every role; the centres open with tabs (invented demo accounts). */
import { test, expect, type DemoRole } from "./fixtures";

const ROLES: DemoRole[] = ["owner", "manager", "supervisor", "finance", "housekeeping"];
for (const role of ROLES) {
  test(`menu count for ${role}: at most 12 links in the side menu`, async ({ page, loginAs, go }) => {
    await loginAs(role);
    await go("/staff/rooms").catch(() => undefined);
    const links = page.locator("aside nav").first().locator("a");
    const n = await links.count();
    console.log(`MENU ${role}: ${n}`);
    expect(n).toBeGreaterThan(0);
    expect(n).toBeLessThanOrEqual(12);
  });
}
test("the guest centre opens with tabs and a tab leads to its page", async ({ page, loginAs, go }) => {
  await loginAs("owner");
  await go("/staff/rooms");
  await page.locator("aside nav").first().getByRole("link", { name: /^النزيل/ }).click();
  const tabs = page.getByTestId("hub-tabs");
  await expect(tabs).toBeVisible();
  await tabs.getByRole("link", { name: "مطابقة الهويات" }).click();
  await expect(page).toHaveURL(/identity-verification/);
  await expect(page.getByTestId("hub-tabs")).toBeVisible();   // the tabs stay on the page
});
test("the finance centre holds the money pages as tabs", async ({ page, loginAs, go }) => {
  await loginAs("owner");
  await go("/staff/payments");
  const tabs = page.getByTestId("hub-tabs");
  for (const name of ["المدفوعات", "المصروفات", "دفتر الحركة", "الحسابات", "تسوية الشبكة"]) await expect(tabs.getByRole("link", { name })).toBeVisible();
});
