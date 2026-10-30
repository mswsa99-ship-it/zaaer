/**
 * U1 note 04: on a 390 px phone no staff or admin page is wider than the screen — wide tables scroll inside their card.
 */
import { test, expect } from "./fixtures";
const STAFF = ["/staff/dashboard", "/staff/arrivals", "/staff/reservations", "/staff/reservations/new", "/staff/identity-verification", "/staff/payments", "/staff/pos-settlement", "/staff/access-approvals", "/staff/followups", "/staff/platforms", "/staff/day-summary", "/staff/rooms", "/staff/housekeeping", "/staff/codes", "/staff/tickets", "/staff/inbox"];
const ADMIN = ["/admin/dashboard", "/admin/branches", "/admin/room-categories", "/admin/rooms", "/admin/structure", "/admin/facilities", "/admin/task-types", "/admin/services", "/admin/rates", "/admin/availability", "/admin/availability-rules", "/admin/reservations", "/admin/guests", "/admin/finance", "/admin/platform-payouts", "/admin/cash-accounts", "/admin/staff", "/admin/roles", "/admin/booking-sources", "/admin/ai-settings", "/admin/whatsapp", "/admin/payment-providers", "/admin/policies", "/admin/knowledge", "/admin/reports", "/admin/audit-logs", "/admin/usage", "/admin/review", "/admin/integrations", "/admin/assistant", "/admin/data-purge"];

test("MW01 no staff or admin page is wider than a 390 px phone", async ({ page, loginAs, go }) => {
  test.setTimeout(300_000);
  await page.setViewportSize({ width: 390, height: 844 });
  await loginAs("owner");
  const wide: string[] = [];
  for (const p of [...STAFF, ...ADMIN]) {
    await go(p);
    await page.waitForTimeout(400);
    const w = await page.evaluate(() => document.documentElement.scrollWidth);
    if (w > 390) wide.push(`${p} ${w}px`);
  }
  expect(wide).toEqual([]);
});
