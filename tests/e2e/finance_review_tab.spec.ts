/**
 * 26 Nov 13:10 (user): the review joins finance. Only the entry point moved into the finance centre: the owner gets «المراجعة»
 * as the last finance tab; manager and finance have no such tab and still cannot open the page.
 */
import { test, expect } from "./fixtures";

test("FR1 owner: «المراجعة» is the last finance tab and opens the review page", async ({ page, loginAs, go }) => {
  await loginAs("owner");
  await go("/staff/payments");
  const tabs = page.getByTestId("hub-tabs").getByRole("link");
  await expect(tabs.last()).toHaveText("المراجعة");
  await tabs.last().click();
  await expect(page).toHaveURL(/\/admin\/review$/);
  await expect(page.getByRole("heading", { level: 1, name: "بحاجة لمراجعة وتدقيق" })).toBeVisible();
  await expect(page.getByTestId("hub-tabs").getByRole("link", { name: "المراجعة" })).toHaveAttribute("aria-current", "page");
});

for (const role of ["manager", "finance"] as const) {
  test(`FR2 ${role}: no review tab in the finance centre, and the page stays closed`, async ({ page, loginAs, go }) => {
    await loginAs(role);
    await go("/staff/payments");
    await expect(page.getByTestId("hub-tabs")).toBeVisible();
    await expect(page.getByTestId("hub-tabs").getByRole("link", { name: "المراجعة" })).toHaveCount(0);
    await go("/admin/review");
    await expect(page.getByRole("heading", { level: 1, name: "بحاجة لمراجعة وتدقيق" })).toHaveCount(0);
  });
}
