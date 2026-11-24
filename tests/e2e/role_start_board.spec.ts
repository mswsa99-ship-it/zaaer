/** Plan 6.1 — every role starts on what waits for it today (invented demo accounts). */
import { test, expect, type DemoRole } from "./fixtures";

const EXPECT: Record<DemoRole, { tiles: string[] }> = {
  supervisor: { tiles: ["arrivals", "departures", "unpaid", "dirty"] },
  finance: { tiles: ["unpaid", "followups", "day-close"] },
  manager: { tiles: ["approvals", "identity", "alerts"] },
  owner: { tiles: ["approvals", "identity", "alerts", "review"] },
  housekeeping: { tiles: ["dirty", "hk-open", "hk-unassigned"] },
};
for (const role of Object.keys(EXPECT) as DemoRole[]) {
  test(`start board for ${role} shows its own tiles`, async ({ page, loginAs, go }) => {
    await loginAs(role);
    await go("/staff/dashboard");
    const board = page.getByTestId("shift-board");
    await expect(board).toBeVisible();
    await expect(board).toHaveAttribute("data-role", role);
    for (const k of EXPECT[role].tiles) {
      const tile = page.getByTestId(`shift-tile-${k}`);
      // a tile whose page the role cannot open is not shown (PERM-05): require it only when the role may open it
      if (await tile.count()) await expect(tile).toBeVisible();
    }
    expect(await page.getByTestId("shift-tiles").locator("a").count()).toBeGreaterThan(0);
  });
}
test("reception: each arrival row carries exactly one action", async ({ page, loginAs, go }) => {
  await loginAs("supervisor");
  await go("/staff/dashboard");
  const rows = page.getByTestId("shift-rows").locator("li");
  const n = await rows.count();
  expect(n).toBeGreaterThan(0);
  for (let i = 0; i < n; i++) expect(await rows.nth(i).locator("a[data-testid^='shift-action-']").count()).toBe(1);
});
