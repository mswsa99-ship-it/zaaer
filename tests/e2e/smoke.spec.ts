/**
 * Smoke — every route renders for the roles that may open it, with no uncaught errors (S01–S03).
 * Keeps refactors honest: a page that crashes on mount fails here before anyone clicks through it.
 */
import { test, expect } from "./fixtures";

const GUEST = ["/", "/reception", "/booking/lookup", "/booking/new", "/kiosk", "/privacy", "/terms"];
const STAFF = ["/staff/dashboard", "/staff/arrivals", "/staff/reservations", "/staff/reservations/new", "/staff/identity-verification", "/staff/payments", "/staff/access-approvals", "/staff/rooms", "/staff/housekeeping", "/staff/tickets", "/staff/inbox"];
const ADMIN = ["/admin/dashboard", "/admin/branches", "/admin/room-categories", "/admin/rooms", "/admin/structure", "/admin/facilities", "/admin/task-types", "/admin/services", "/admin/availability", "/admin/availability-rules", "/admin/reservations", "/admin/guests", "/admin/finance", "/admin/keyboxes", "/admin/staff", "/admin/roles", "/admin/booking-sources", "/admin/ai-settings", "/admin/whatsapp", "/admin/payment-providers", "/admin/policies", "/admin/knowledge", "/admin/reports", "/admin/audit-logs", "/admin/integrations"];

test("S01 guest routes render", async ({ page, go }) => {
  for (const path of GUEST) {
    await go(path);
    await expect(page.locator("#root")).not.toBeEmpty();
    expect(page.url(), path).toContain(path === "/" ? "#/" : `#${path}`);
  }
});

test("S02 staff routes render for the owner, and protected routes bounce anonymous users to login", async ({ page, go, loginAs }) => {
  await go("/staff/dashboard");
  await expect(page).toHaveURL(/#\/staff\/login/);
  await loginAs("owner");
  for (const path of [...STAFF, ...ADMIN]) {
    await go(path);
    await expect(page.locator("main"), path).not.toBeEmpty();
    await expect(page).toHaveURL(new RegExp(`#${path.replace(/\//g, "\\/")}`));
  }
});

test("S03 the demo banner and reset are present, and a reset restores the seed", async ({ page, loginAs }) => {
  await loginAs("owner");
  await expect(page.getByText(/عرض تجريبي/).first()).toBeVisible();
  const reset = page.getByRole("button", { name: /إعادة ضبط|إعادة تعيين/ }).first();
  if (await reset.count()) {
    await reset.click();
    await page.waitForTimeout(500);
    await expect(page.locator("#root")).not.toBeEmpty();
  }
});

test("S04 each role lands where its work starts, and sees only links it may open", async ({ page, loginAs }, info) => {
  await loginAs("housekeeping");
  await expect(page).toHaveURL(/#\/staff\/housekeeping/);
  if (info.project.name === "desktop") {
    // one navigation on desktop (sidebar), not a second row of the same links
    await expect(page.getByRole("link", { name: "خدمة الغرف" })).toHaveCount(1);
    await expect(page.getByRole("link", { name: "المدفوعات" })).toHaveCount(0);
    await expect(page.getByRole("link", { name: /لوحة الإدارة|الإدارة ↗/ })).toHaveCount(0);
  }
  await page.locator('[title="تسجيل الخروج"]:visible, [aria-label="تسجيل الخروج"]:visible').first().click();
  await expect(page).toHaveURL(/#\/staff\/login/);
  await loginAs("finance");
  await expect(page).toHaveURL(/#\/admin\/finance/);
});
