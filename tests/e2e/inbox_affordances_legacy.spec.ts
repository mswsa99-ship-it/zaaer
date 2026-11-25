/**
 * Inbox affordances (0128 UI facet). Bounds: the demo build's in-browser backend does not model individual-mode accounts,
 * so this proves only that LEGACY role accounts keep the reply form and the take button exactly as before. The
 * individual view/add/edit combinations are decided by src/lib/inboxAffordances.ts (tests/unit/inbox_affordances.test.ts)
 * and the server enforcement by tests/sql/inbox_reply_0128_tests.sql. No provider or bridge is called: the reply is not sent.
 */
import { test, expect } from "./fixtures";

test("legacy manager keeps the inbox reply form and the take button", async ({ page, loginAs }) => {
  await loginAs("manager");
  await page.goto("/#/staff/inbox", { waitUntil: "networkidle" });
  const first = page.locator("button", { hasText: /محادثة|واتساب|شاشة/ }).first();
  await expect(first).toBeVisible();
  await first.click();
  const input = page.getByPlaceholder(/اكتب ردًا|استلم المحادثة أولًا/);
  await expect(input).toBeVisible();
  await expect(input).toBeEnabled();
  await input.fill("x");
  await expect(page.getByTestId("inbox-send")).toBeEnabled();
  await expect(page.getByRole("button", { name: /استلام المحادثة|إعادة للمساعد/ }).first()).toBeVisible();
});
