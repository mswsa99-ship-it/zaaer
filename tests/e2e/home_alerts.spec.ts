/** The home page's briefing is read in the team's own sections: reception, finance, operations (and coordination when an alert crosses them). Reading only. */
import { test, expect } from "./fixtures";
test("HOME1 the briefing groups its alerts by team, every row only opens a page, and a role without money has no finance section figures", async ({ page, loginAs, go }) => {
  await loginAs("owner"); await go("/staff/dashboard");
  const areas = page.getByTestId("briefing-areas");
  await expect(areas.locator("section[data-area='reception']")).toBeVisible();
  await expect(areas.locator("section[data-area='finance']")).toBeVisible();
  await expect(areas.locator("section[data-area='ops']")).toBeVisible();
  await expect(areas.getByRole("button")).toHaveCount(0);            // nothing to press: no action path
  for (const l of await areas.getByRole("link", { name: "فتح" }).all()) expect(await l.getAttribute("href")).toMatch(/^#\/staff\//);
});
test("HOME2 housekeeping sees no money alerts in the briefing", async ({ page, loginAs, go }) => {
  await loginAs("housekeeping"); await go("/staff/dashboard");
  await expect(page.getByTestId("briefing-areas").locator("section[data-area='finance']")).toHaveCount(0);
});
