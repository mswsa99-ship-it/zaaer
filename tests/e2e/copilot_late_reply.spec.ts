/**
 * F1 (ops assistant): after the 90 s bound the original request keeps running on the server. Required: the input is usable
 * at the bound, the late reply is kept once, its conversation id is used by the next question, and it never lands in another
 * branch's context. Time is moved by the test clock; no live connection, no live model.
 */
import { test, expect } from "./fixtures";
const RIYADH = "00000000-0000-0000-0000-000000000010";
const JEDDAH = "00000000-0000-0000-0000-000000000012";
const LATE = "وصل ردّ متأخر على سؤالك";

async function arm(page: import("@playwright/test").Page, firstDelay: number) {
  await page.evaluate((d) => {
    const w = window as unknown as { __calls: string[]; __demoLatency: (t: string, x: string[]) => number };
    w.__calls = [];
    w.__demoLatency = (t, x) => { if (t !== "fn:ai-ops") return 0; w.__calls.push(String(x?.[0] ?? "")); return w.__calls.length === 1 ? d : 0; };
  }, firstDelay);
}

test("a late reply after the bound shows once and its conversation is reused", async ({ page, loginAs, go }) => {
  await loginAs("owner"); await go("/admin/structure");
  await page.getByLabel("الفرع النشط").selectOption(RIYADH);
  await arm(page, 100_000);
  await page.clock.install();
  await page.getByRole("button", { name: "مساعد العمليات" }).click();
  const input = page.getByPlaceholder("اكتب سؤالك أو طلبك…");
  await input.fill("ما وضع اليوم؟"); await input.press("Enter");
  await expect(page.getByTestId("ops-progress")).toBeVisible();
  await page.clock.fastForward(91_000);
  await expect(page.getByText(LATE)).toHaveCount(0);
  await expect(page.getByTestId("ops-progress")).toBeHidden();
  await expect(input).toBeEnabled();
  await page.clock.fastForward(15_000);
  await expect(page.getByText(LATE)).toHaveCount(1);
  await input.fill("من يصل اليوم؟"); await input.press("Enter");
  await page.clock.fastForward(2_000);
  await expect(page.getByText(LATE)).toHaveCount(1);
  const calls = await page.evaluate(() => (window as unknown as { __calls: string[] }).__calls);
  expect(calls).toHaveLength(2);
  expect(calls[0]).toContain('"conversation_id":null');
  expect(calls[1]).toMatch(/"conversation_id":"[^"]+"/);
});

test("a late reply never lands after a branch change, including a return to the same branch", async ({ page, loginAs, go }) => {
  await loginAs("owner"); await go("/admin/structure");
  const picker = page.getByLabel("الفرع النشط");
  await picker.selectOption(RIYADH);
  await arm(page, 100_000);
  await page.clock.install();
  await page.getByRole("button", { name: "مساعد العمليات" }).click();
  const input = page.getByPlaceholder("اكتب سؤالك أو طلبك…");
  await input.fill("سؤال اختبار الفرع"); await input.press("Enter");
  await page.clock.fastForward(91_000);
  await picker.selectOption(JEDDAH);
  await picker.selectOption(RIYADH);
  await page.clock.fastForward(15_000);
  await expect(page.getByText(LATE)).toHaveCount(0);
  await expect(page.getByText("سؤال اختبار الفرع")).toHaveCount(0);   // the new context starts empty
  await input.fill("من يصل اليوم؟"); await input.press("Enter");
  await page.clock.fastForward(2_000);
  const calls = await page.evaluate(() => (window as unknown as { __calls: string[] }).__calls);
  expect(calls[calls.length - 1]).toContain('"conversation_id":null');   // the old conversation was not adopted
  await expect(page.getByText(LATE)).toHaveCount(0);
});

test("a late rejection adds no extra message", async ({ page, loginAs, go }) => {
  await loginAs("owner"); await go("/admin/structure");
  await page.getByLabel("الفرع النشط").selectOption(RIYADH);
  await page.evaluate(() => {
    const w = window as unknown as { __n: number; __demoLatency: (t: string) => number; __demoFail: (t: string) => string | null };
    w.__n = 0;
    w.__demoLatency = (t) => (t === "fn:ai-ops" && w.__n++ === 0 ? 100_000 : 0);
    w.__demoFail = (t) => (t === "fn:ai-ops" ? "boom" : null);
  });
  await page.clock.install();
  await page.getByRole("button", { name: "مساعد العمليات" }).click();
  const input = page.getByPlaceholder("اكتب سؤالك أو طلبك…");
  await input.fill("سؤال اختبار الرفض"); await input.press("Enter");
  await page.clock.fastForward(91_000);
  const before = await page.locator("div.whitespace-pre-wrap").count();
  await page.clock.fastForward(15_000);
  await expect(input).toBeEnabled();
  expect(await page.locator("div.whitespace-pre-wrap").count()).toBe(before);
  await expect(page.getByText(LATE)).toHaveCount(0);
});
