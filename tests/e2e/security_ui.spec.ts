/** What the screen offers follows what the server allows, and the assistant says what it is: read-only. */
import { test, expect } from "./fixtures";
import type { Page } from "@playwright/test";
async function openR0006(page: Page, go: (p: string) => Promise<void>) {
  await go("/staff/reservations");
  const row = page.locator("table tbody tr").filter({ hasText: "R-26A0006" }).first();
  await expect(row).toBeVisible(); await row.getByRole("link", { name: "فتح" }).click();
  await page.waitForURL(/#\/staff\/reservations\/[0-9a-f-]+/);
}
test("SEC1 identity approval and rejection buttons show only to a role that holds identity.approve (supervisor yes, finance no)", async ({ page, loginAs, go }) => {
  await loginAs("supervisor"); await openR0006(page, go);
  await expect(page.getByRole("button", { name: "اعتمد", exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "رفض", exact: true }).first()).toBeVisible();
});
test("SEC2 a finance role sees the guest's identity state but no approve or reject button", async ({ page, loginAs, go }) => {
  await loginAs("finance"); await openR0006(page, go);
  await expect(page.getByText("الحالة:").first()).toBeVisible();
  await expect(page.getByRole("button", { name: "اعتمد", exact: true })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "رفض", exact: true })).toHaveCount(0);
});
test("SEC3 the assistant's welcome and header say it is read-only, and do not offer to create tasks or extend bookings", async ({ page, loginAs, go }) => {
  await loginAs("owner"); await go("/staff/dashboard");
  await page.getByTestId("ops-copilot-fab").click();
  const d = page.getByRole("dialog", { name: "مساعد العمليات" });
  await expect(d.getByText("للقراءة والاطلاع فقط").first()).toBeVisible();
  await expect(d).not.toContainText("اطلب إجراءً");
  await expect(d).not.toContainText("مدّد الحجز");
  await expect(d).not.toContainText("أنت من ينفذ");
});
