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

test("HOME3 a reception role WITHOUT money: the whole rendered briefing carries no balance, deposit, due or amount wording, and still groups by team", async ({ page, loginAs, go }) => {
  await loginAs("owner");
  await page.evaluate(() => { const S = JSON.parse(localStorage.getItem("zaaer_demo_store_v9")!); const org = S.branches[0].organization_id;
    for (const code of ["voucher.receipt", "voucher.refund", "deposit.refund", "deposit.apply", "voucher.correct", "voucher.cancel", "pos.settle", "platform.payouts", "invoice.issue", "invoice.edit", "reports.finance"]) { S.role_permissions = (S.role_permissions ?? []).filter((x: any) => !(x.role === "supervisor" && x.capability === code)); S.role_permissions.push({ organization_id: org, capability: code, role: "supervisor", allowed: false, updated_at: new Date().toISOString(), updated_by: null }); }
    localStorage.setItem("zaaer_demo_store_v9", JSON.stringify(S)); sessionStorage.clear(); localStorage.removeItem("zaaer_demo_session"); });
  await page.goto("about:blank"); await loginAs("supervisor"); await go("/staff/dashboard");
  const areas = page.getByTestId("briefing-areas"); await expect(areas.locator("section[data-area='reception']")).toBeVisible();
  const html = await page.locator(".ops-briefing").innerHTML();
  expect(html).not.toMatch(/ر\.س|متبقٍ|رصيد|تأمين|SAR/);
  await expect(areas.locator("section[data-area='finance']")).toHaveCount(0);
});
test("HOME4 two branches with the SAME unit number: the maintenance+arrival alert belongs to the branch that has the arrival only", async ({ page, loginAs, go }) => {
  await loginAs("owner");
  await page.evaluate(() => { const S = JSON.parse(localStorage.getItem("zaaer_demo_store_v9")!); const A = S.branches[0].id;
    const roomA = S.rooms.find((r: any) => r.status === "maintenance" && r.branch_id === A); const al = S.reservation_allocations.find((x: any) => x.status === "active" && S.reservations.find((r: any) => r.id === x.reservation_id && r.status === "confirmed" && r.branch_id === A));
    al.room_id = roomA.id; al.from_date = S.__today;
    const roomB = S.rooms.find((r: any) => r.room_number === "J-1"); roomB.room_number = roomA.room_number; roomB.status = "maintenance";   // same number, distinct ids, no arrival
    localStorage.setItem("zaaer_demo_store_v9", JSON.stringify(S)); (window as any).__n = roomA.room_number; });
  await page.reload(); await page.waitForTimeout(1500);
  const sel = page.locator('select[aria-label="الفرع النشط"]').first(); await sel.selectOption({ label: "جميع الفروع" }); await page.waitForTimeout(2500);
  const coord = page.getByTestId("briefing-areas").locator("section[data-area='coordination'] li");
  await expect(coord).toHaveCount(1); await expect(coord.first()).toContainText("الرياض"); await expect(coord.first()).not.toContainText("جدة");
});
