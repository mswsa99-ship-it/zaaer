/** A refused page names itself: one H1 and a matching tab title (housekeeping opening the payments page). Demo build only. */
import { test, expect } from "./fixtures";
test("GT1 denial card is the page's H1 and the tab title follows it", async ({ page, loginAs, go }) => {
  await loginAs("housekeeping");
  await go("/staff/reservations");
  const before = await page.title();
  await go("/staff/payments");
  const h1 = page.getByRole("heading", { level: 1 });
  await expect(h1).toHaveCount(1);
  const text = (await h1.innerText()).trim();
  await expect.poll(() => page.title()).toContain(text);
  expect(await page.title()).not.toBe(before);
});
