/**
 * Staff AI ops copilot — acceptance ids D01–D04.
 * Controls: G20 (copilot reads only through the staff user's permissions), G21 (writes only via a
 * human-confirmed proposal executed through the same RPCs), G22 (no invented facts — deterministic briefing),
 * G12 (money hidden for non-money roles).
 */
import { test, expect } from "./fixtures";

type Page = import("@playwright/test").Page;
const BUBBLE = "div.whitespace-pre-wrap";

async function openCopilot(page: Page) {
  const input = page.getByPlaceholder("اكتب سؤالك أو طلبك…");
  if (!(await input.isVisible().catch(() => false))) await page.getByRole("button", { name: "مساعد العمليات" }).click();
  await expect(input).toBeVisible();
  return input;
}

/** Sends a message and waits for the assistant bubble (staff bubble + reply). */
async function send(page: Page, text: string) {
  const bubbles = page.locator(BUBBLE);
  const before = await bubbles.count();
  const input = page.getByPlaceholder("اكتب سؤالك أو طلبك…");
  await input.fill(text);
  await input.press("Enter");
  await expect.poll(() => bubbles.count(), { timeout: 15_000 }).toBeGreaterThanOrEqual(before + 2);
  return bubbles.last();
}

test.describe("ops copilot", () => {
  test("D01 briefing answers from live context, no provider needed", async ({ page, loginAs }) => {
    await loginAs("owner");
    await openCopilot(page);
    await page.getByRole("button", { name: "ما وضع اليوم؟" }).click();
    await expect(page.locator(BUBBLE)).toHaveCount(2, { timeout: 15_000 });
    await expect(page.locator(BUBBLE).last()).toContainText(/وصول|مغادر|إشغال|وحدة/);
    const reply = await send(page, "كم وحدة متسخة الآن؟");
    await expect(reply).not.toBeEmpty();
  });

  test("D02 a write is a proposal first; confirming executes it through the real RPC and it shows up in housekeeping", async ({ page, loginAs }) => {
    await loginAs("owner");
    await openCopilot(page);
    await send(page, "أنشئ مهمة تنظيف للوحدة 102");
    const confirm = page.getByRole("button", { name: "تأكيد وتنفيذ" }).first();
    await expect(confirm).toBeVisible();
    // nothing happened yet: the task does not exist before confirmation
    await page.goto("/#/staff/housekeeping", { waitUntil: "networkidle" });
    const before = await page.getByText("وحدة 102").count();
    await page.goto("/#/staff/dashboard", { waitUntil: "networkidle" });
    await openCopilot(page);
    await send(page, "أنشئ مهمة تنظيف للوحدة 102");
    await page.getByRole("button", { name: "تأكيد وتنفيذ" }).first().click();
    await expect(page.getByText("نُفذ وسُجل").first()).toBeVisible();
    await page.goto("/#/staff/housekeeping", { waitUntil: "networkidle" });
    expect(await page.getByText("وحدة 102").count()).toBeGreaterThan(before);
  });

  test("D03 housekeeping cannot get balances from the copilot", async ({ page, loginAs }) => {
    await loginAs("housekeeping");
    await openCopilot(page);
    const reply = await send(page, "كم المتبقي على الحجوزات اليوم؟");
    await expect(reply).not.toBeEmpty();
    await expect(reply).not.toContainText("ر.س");
    await expect(reply).not.toContainText(/المتبقي \d/);
  });
});
