/**
 * F1 (مساعد العمليات): بعد انتهاء الحد الزمني (90 ث) يبقى الطلب الأصلي جاريًا على الخادم. المطلوب: الإدخال
 * يعود متاحًا عند الحد، والرد المتأخر يُحفظ مرة واحدة، ومعرّف المحادثة منه يُستعمل في السؤال التالي.
 * الحد الزمني مُقصَّر بخطاف الاختبار (3 ث) والتأخير 8 ث؛ لا اتصال حيًا ولا نموذجًا حيًا.
 */
import { test, expect } from "./fixtures";

test("رد متأخر بعد الحد يظهر مرة واحدة ويُعاد استعمال محادثته", async ({ page, loginAs }) => {
  await loginAs("owner");
  await page.evaluate(() => {
    const w = window as unknown as { __calls: string[]; __demoLatency: (t: string, d: string[]) => number };
    w.__calls = [];
    (window as unknown as { __opsReplyTimeoutMs: number }).__opsReplyTimeoutMs = 3000;
    w.__demoLatency = (t, d) => {
      if (t !== "fn:ai-ops") return 0;
      w.__calls.push(String(d?.[0] ?? ""));
      return w.__calls.length === 1 ? 8_000 : 0;
    };
  });
  await page.getByRole("button", { name: "مساعد العمليات" }).click();
  const input = page.getByPlaceholder("اكتب سؤالك أو طلبك…");
  await input.fill("ما وضع اليوم؟");
  await input.press("Enter");
  await expect(page.getByTestId("ops-progress")).toBeVisible();

  await page.waitForTimeout(3600);
  await expect(page.getByText("وصل ردّ متأخر")).toHaveCount(0);
  await expect(page.getByTestId("ops-progress")).toBeHidden();
  await expect(input).toBeEnabled();

  await page.waitForTimeout(6000);
  await expect(page.getByText("وصل ردّ متأخر على سؤالك السابق")).toHaveCount(1);

  await input.fill("من يصل اليوم؟");
  await input.press("Enter");
  await page.waitForTimeout(1500);
  await expect(page.getByText("وصل ردّ متأخر على سؤالك السابق")).toHaveCount(1);
  const calls = await page.evaluate(() => (window as unknown as { __calls: string[] }).__calls);
  expect(calls).toHaveLength(2);
  expect(calls[0]).toContain('"conversation_id":null');
  expect(calls[1]).not.toContain('"conversation_id":null');
  expect(calls[1]).toMatch(/"conversation_id":"[^"]+"/);
});
