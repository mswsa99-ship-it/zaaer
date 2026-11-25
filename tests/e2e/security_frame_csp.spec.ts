/**
 * 5.4 (ق6) — فحص e2e لسياسة المحتوى وحارس الإطار على نسخة العرض:
 * يقرأ السياسة من الصفحة نفسها، يتحقق أن نصًا محقونًا لا يُنفَّذ، وأن التطبيق يرفض
 * العمل داخل إطار أجنبي دون أن يسرب مساره. يستعمل @playwright/test مباشرة (لا fixtures
 * المشتركة) لأن رسائل CSP المتعمدة هنا console.error متوقعة وليست فشلًا.
 */
import { test, expect } from "@playwright/test";
import { createServer, type Server } from "node:http";

const PORT = Number(process.env.E2E_PORT || 4174);
const APP = `http://localhost:${PORT}`;

// صفحة حاضنة على أصل مختلف (127.0.0.1:5999 ≠ localhost:4174) لكنه loopback: كروم يمنع
// الصفحات العامة من تأطير localhost (Private Network Access)، لذلك تُقدَّم من خادم محلي حقيقي.
let framer: Server;
let FRAMER_PORT = 0;
test.beforeAll(async () => {
  framer = createServer((req, res) => {
    const src = new URL(req.url ?? "/", `http://127.0.0.1:${FRAMER_PORT}`).searchParams.get("src") ?? APP;
    res.setHeader("content-type", "text/html; charset=utf-8");
    res.end(`<!doctype html><html><body><iframe src="${src}"></iframe></body></html>`);
  });
  await new Promise<void>((resolve) => framer.listen(0, "127.0.0.1", resolve));
  FRAMER_PORT = (framer.address() as { port: number }).port;
});
test.afterAll(async () => {
  await new Promise<void>((resolve) => framer.close(() => resolve()));
});

test("السياسة تُقرأ من الصفحة: script-src ذاتي بلا inline، والأصول المطلوبة حاضرة", async ({ page }) => {
  await page.goto("/", { waitUntil: "domcontentloaded" });
  const csp = await page.locator('meta[http-equiv="Content-Security-Policy"]').getAttribute("content");
  expect(csp).toBeTruthy();
  expect(csp).toContain("default-src 'self'");
  expect(csp).toContain("script-src 'self'");
  expect(csp).toContain("object-src 'none'");
  expect(csp).not.toMatch(/script-src [^;]*unsafe-inline/);
  expect(csp).not.toMatch(/script-src [^;]*unsafe-eval/);
  expect(csp).toContain("https://*.supabase.co");
  expect(csp).not.toContain("https://fonts.googleapis.com");
  expect(csp).not.toContain("https://fonts.gstatic.com");
});

test("نص محقون لا يُنفَّذ: لا سكربت مضمّن ولا معالج أحداث", async ({ page }) => {
  await page.goto("/#/reception", { waitUntil: "networkidle" });
  await expect(page.locator("#root")).not.toBeEmpty();

  // حقن سكربت مضمّن كما يفعل مخزن XSS
  await page.evaluate(() => {
    const s = document.createElement("script");
    s.textContent = 'window.__probe_inline = "ran"';
    document.body.appendChild(s);
  });
  // حقن وسيلة أخرى: innerHTML مع onerror
  await page.evaluate(() => {
    const d = document.createElement("div");
    d.innerHTML = '<img src="x-invalid" onerror=\'window.__probe_handler="ran"\'>';
    document.body.appendChild(d);
  });
  await page.waitForTimeout(300);
  const probes = await page.evaluate(() => ({
    inline: (window as unknown as Record<string, unknown>).__probe_inline ?? null,
    handler: (window as unknown as Record<string, unknown>).__probe_handler ?? null,
  }));
  expect(probes.inline).toBeNull();
  expect(probes.handler).toBeNull();
  // والتطبيق نفسه ما زال يعمل بعد الحقن
  await expect(page.locator("#root")).not.toBeEmpty();
});

test("التطبيق يرفض الإطار الأجنبي: يخفي المحتوى ولا ينقل الأعلى ولا يسرب المسار ولا الجزء", async ({ page }) => {
  const SECRET = "SECRET-TOKEN-9f8e7d6c";
  await page.goto(`http://127.0.0.1:${FRAMER_PORT}/embed?src=${encodeURIComponent(`${APP}/#/booking/status/${SECRET}`)}`);
  const frame = page.locator("iframe").contentFrame();
  // التطبيق قلع داخل الإطار (الإخفاء من الحارس، ليس فشل تحميل)
  await expect(frame.locator("#root")).not.toBeEmpty({ timeout: 15_000 });
  // الحارس أخفى الصفحة كلها عن الحاضنة
  await expect.poll(async () => frame.locator("html").evaluate((el) => el.style.display)).toBe("none");
  // كروم يمنع نقل الأعلى بلا تفاعل: بقي الأعلى على الحاضنة، ولم يُحمَّل عنوان يحمل الرمز خارج الإطار
  expect(page.url()).toContain(`127.0.0.1:${FRAMER_PORT}`);
  expect(page.url()).not.toContain("#");
});

test("صفحة 404 الثابتة تحمل سياسة مغلقة وحارسها المضمّن يعمل ضمنها", async ({ page }) => {
  await page.goto("/404.html", { waitUntil: "domcontentloaded" });
  const csp = await page.locator('meta[http-equiv="Content-Security-Policy"]').getAttribute("content");
  expect(csp).toContain("default-src 'none'");
  expect(csp).toMatch(/script-src 'sha256-[^']+'/);
  // الصفحة نفسها ظاهرة (حارسها سمح لأنها نافذة عليا) ونصها العربي موجود
  await expect(page.getByText("الصفحة غير موجودة")).toBeVisible();
});
