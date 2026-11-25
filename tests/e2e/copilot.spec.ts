/**
 * Staff AI ops copilot — test ids OC01–OC03 (decision 57: renamed from D01–D03, which the testing rules reserve for
 * reports and audit data).
 * Controls: G21 (housekeeping gets no balances through the copilot — OC03), G22 (a write is a proposal first, and
 * confirming runs the regular audited RPC under the user's own role — OC02). The briefing answers from live data
 * with no model (OC01).
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
  test("OC01 briefing answers from live context, no provider needed", async ({ page, loginAs }) => {
    await loginAs("owner");
    await openCopilot(page);
    await page.getByRole("button", { name: "ما وضع اليوم؟" }).click();
    await expect(page.locator(BUBBLE)).toHaveCount(2, { timeout: 15_000 });
    await expect(page.locator(BUBBLE).last()).toContainText(/وصول|مغادر|إشغال|وحدة/);
    const reply = await send(page, "كم وحدة متسخة الآن؟");
    await expect(reply).not.toBeEmpty();
  });

  test("OC02 the assistant is read-only: a write request gets guidance, no confirm button, and nothing is created", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/staff/housekeeping", { waitUntil: "networkidle" });
    const before = await page.locator("main").getByText("وحدة 102").count();
    await page.goto("/#/staff/dashboard", { waitUntil: "networkidle" });
    await openCopilot(page);
    await send(page, "أنشئ مهمة تنظيف للوحدة 102");
    await expect(page.getByText("للقراءة والاطلاع فقط").first()).toBeVisible();
    await expect(page.getByRole("button", { name: "تأكيد وتنفيذ" })).toHaveCount(0);
    await page.keyboard.press("Escape");                              // the chat bubble itself mentions the room: close it before counting the page
    await page.goto("/#/staff/housekeeping", { waitUntil: "networkidle" });
    expect(await page.locator("main").getByText("وحدة 102").count()).toBe(before);
  });

  test("OC03 housekeeping cannot get balances from the copilot", async ({ page, loginAs }) => {
    await loginAs("housekeeping");
    await openCopilot(page);
    const reply = await send(page, "كم المتبقي على الحجوزات اليوم؟");
    await expect(reply).not.toBeEmpty();
    await expect(reply).not.toContainText("ر.س");
    await expect(reply).not.toContainText(/المتبقي \d/);
  });
});
