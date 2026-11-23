/**
 * 5.4 (ق6) — سياسة المحتوى داخل الصفحة: index.html يحمل سياسة صارمة تطابق أصول التطبيق
 * الفعلية، وصفحة 404 الثابتة تحمل سياسة مغلقة وبصمة حارس الإطار المضمّن تطابق محتواه فعلًا
 * (حتى لا يكسر تعديل لاحق الحارس أو يضعف السياسة دون أن ينتبه أحد).
 */
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { createHash } from "node:crypto";

const ROOT = join(__dirname, "..", "..");
const indexHtml = readFileSync(join(ROOT, "index.html"), "utf8");
const notFoundHtml = readFileSync(join(ROOT, "public", "404.html"), "utf8");

function cspOf(html: string): string {
  const m = html.match(/http-equiv="Content-Security-Policy"\s+content="([^"]+)"/);
  expect(m, "صفحة بلا meta CSP").toBeTruthy();
  return m![1];
}

describe("سياسة الصفحة الرئيسية", () => {
  const csp = cspOf(indexHtml);

  it("الأساسيات الصارمة حاضرة", () => {
    expect(csp).toContain("default-src 'self'");
    expect(csp).toContain("script-src 'self'");
    expect(csp).toContain("object-src 'none'");
    expect(csp).toContain("base-uri 'self'");
    expect(csp).toContain("form-action 'self'");
  });

  it("لا inline ولا eval في مصادر السكربت", () => {
    const scriptSrc = csp.match(/script-src ([^;]+)/)![1];
    expect(scriptSrc).not.toContain("unsafe-inline");
    expect(scriptSrc).not.toContain("unsafe-eval");
  });

  it("الأصول التي يحتاجها التطبيق فعلًا مسموحة: Supabase وRealtime وخطوط Google وصور data/blob", () => {
    expect(csp).toMatch(/connect-src [^;]*https:\/\/\*\.supabase\.co/);
    expect(csp).toMatch(/connect-src [^;]*wss:\/\/\*\.supabase\.co/);
    expect(csp).toMatch(/style-src [^;]*https:\/\/fonts\.googleapis\.com/);
    expect(csp).toMatch(/font-src [^;]*https:\/\/fonts\.gstatic\.com/);
    expect(csp).toMatch(/img-src [^;]*data:/);
    expect(csp).toMatch(/img-src [^;]*blob:/);
  });

  it("style-src يحتفظ بـ unsafe-inline لأن أنماط React السطرية وسمة style قائمة عليه (مطابق لرأس Netlify)", () => {
    expect(csp).toMatch(/style-src 'self' 'unsafe-inline'/);
  });
});

describe("صفحة 404 الثابتة", () => {
  it("سياسة مغلقة: لا مصادر خارجية ولا سكربت إلا بصمة الحارس", () => {
    const csp = cspOf(notFoundHtml);
    expect(csp).toContain("default-src 'none'");
    const scriptSrc = csp.match(/script-src ([^;]+)/)![1];
    expect(scriptSrc).not.toContain("'self'");
    expect(scriptSrc).not.toContain("unsafe-inline");
    expect(scriptSrc).toMatch(/'sha256-[A-Za-z0-9+/=]+='/);
  });

  it("بصمة sha256 في السياسة تطابق محتوى السكربت المضمّن حرفيًا", () => {
    const script = notFoundHtml.match(/<script>([\s\S]*?)<\/script>/)![1];
    const hash = createHash("sha256").update(script, "utf8").digest("base64");
    expect(cspOf(notFoundHtml)).toContain(`'sha256-${hash}'`);
  });

  it("الحارس المضمّن لا يمرر مسار الصفحة ولا استعلامها إلى الإطار الأعلى", () => {
    const script = notFoundHtml.match(/<script>([\s\S]*?)<\/script>/)![1];
    expect(script).toContain('location.origin+"/"');
    expect(script).not.toContain("location.pathname");
    expect(script).not.toContain("location.href");
  });
});
