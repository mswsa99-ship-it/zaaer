/**
 * خطة التصحيح 6.10 (U2 الطباعة): صفحة طباعة مستقلة مقسّمة؛ قائمة من 5,000 صف لا تُجمّد التبويب.
 * بيانات اصطناعية مخترعة بالكامل تُزرع في مخزن العرض المحلي (localStorage) قبل الإقلاع. أسماء وصفية بلا رموز.
 */
import { test, expect } from "./fixtures";

const STORE_KEY = "zaaer_demo_store_v9";
const ROWS = 5000;

test.describe("طباعة قائمة ضخمة", () => {
  test("قائمة سجل من 5,000 صف تُبنى صفحةً صفحة دون تجميد التبويب، والمستند مقسّم مرقّم", async ({ page, loginAs }) => {
    test.setTimeout(120_000);
    // Keep the prepared document inspectable: headless Chrome closes native print immediately and fires afterprint.
    // This test checks the paginated document, not an operating-system printer dialog.
    await page.addInitScript(() => { window.print = () => {}; });
    await loginAs("owner");

    // أثّر في المخزن ليُحفظ محليًا (رسالة مساعد واحدة)، ثم ازرع 5,000 حدث اصطناعي فيه وأعد الإقلاع
    await page.getByRole("button", { name: "مساعد العمليات" }).click();
    await page.getByPlaceholder("اكتب سؤالك أو طلبك…").fill("ما وضع اليوم؟");
    await page.getByPlaceholder("اكتب سؤالك أو طلبك…").press("Enter");
    await expect(page.locator("div.whitespace-pre-wrap")).toHaveCount(2, { timeout: 15_000 });
    await page.waitForFunction((k) => !!localStorage.getItem(k), STORE_KEY);
    // تهدئة: حفظ مخزن العرض مؤجل 150مث؛ ننتظر اكتماله حتى لا يطمس زرعنا (سبب فشل عشوائي سابق)
    await page.waitForTimeout(400);

    await page.evaluate(({ k, rows }) => {
      const store = JSON.parse(localStorage.getItem(k) ?? "{}");
      const template = (store.audit_events ?? [])[0];
      if (!template) throw new Error("no audit template row in the demo store");
      const base = Date.now();
      const invented: Record<string, unknown>[] = [];
      for (let i = 0; i < rows; i++) {
        invented.push({
          ...template,
          id: `load-${i}`,
          created_at: new Date(base - (i + 1) * 1000).toISOString(),
          correlation_id: `load-${i}`,
          entity_id: template.entity_id,
          details: { reason: `حدث اصطناعي رقم ${i} لاختبار الطباعة` },
        });
      }
      store.audit_events = [...invented, ...(store.audit_events ?? [])];
      localStorage.setItem(k, JSON.stringify(store));
    }, { k: STORE_KEY, rows: ROWS });

    await page.reload({ waitUntil: "networkidle" });
    await page.goto("/#/admin/audit-logs", { waitUntil: "networkidle" });
    await expect(page.getByText(/الأحداث المطابقة: 5,?\d\d\d/)).toBeVisible({ timeout: 30_000 });

    // التبويب يبقى مستجيبًا أثناء القراءة والبناء: عداد رسم يتقدم طوال العملية
    await page.evaluate(() => {
      (window as unknown as { __frames: number }).__frames = 0;
      const tick = () => { (window as unknown as { __frames: number }).__frames++; requestAnimationFrame(tick); };
      requestAnimationFrame(tick);
    });

    const framesNow = () => page.evaluate(() => (window as unknown as { __frames: number }).__frames);
    const f0 = await framesNow();
    await page.getByTestId("export-trigger").click();
    await page.getByTestId("export-print").click();
    await page.getByTestId("export-scope-all").click();
    // أثناء التحضير الزر مشغول وعداد الرسم يتقدم (التبويب غير مجمّد)
    await expect(page.getByTestId("export-trigger")).toBeDisabled();
    const f1 = await framesNow();
    expect(f1).toBeGreaterThan(f0);

    // مستند الطباعة داخل الإطار المستقل: مقسّم إلى صفحات مرقّمة، ترويسة مكررة، وكل الصفوف موجودة
    const frame = page.locator('iframe[aria-hidden="true"]').last();
    await expect(frame).toBeAttached({ timeout: 60_000 });
    await expect(page.getByTestId("export-trigger")).toBeEnabled({ timeout: 60_000 });
    const doc = frame.contentFrame();
    const pageTables = doc.locator("table.pg");
    await expect(pageTables.first()).toBeAttached({ timeout: 30_000 });
    const tableCount = await pageTables.count();
    expect(tableCount).toBeGreaterThanOrEqual(Math.ceil(ROWS / 40));
    await expect(doc.locator("p.pageno").first()).toContainText(`صفحة 1 من ${tableCount}`);
    await expect(doc.locator("p.pageno").last()).toContainText(`صفحة ${tableCount} من ${tableCount}`);
    expect(await doc.locator("table.pg tbody tr").count()).toBeGreaterThanOrEqual(ROWS);
    // البيان في رأس المستند
    await expect(doc.locator("h1")).toHaveText("سجل الإجراءات");
    await expect(doc.locator("body")).toContainText("المرشحات");

    // لم يُجمَّد التبويب: عداد الرسم ظل يتقدم طوال القراءة والبناء
    const f2 = await framesNow();
    expect(f2).toBeGreaterThan(f1);

    // والشاشة نفسها ما زالت تعمل بعد الطباعة
    await page.getByRole("button", { name: "كل الفترات" }).click();
    await expect(page.getByText(/الأحداث المطابقة: 5,?\d\d\d/)).toBeVisible();
  });
});
