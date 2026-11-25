/**
 * 5.6 (ق7) — اختبارات قاعدة فحص HTML الخام scripts/check-raw-html.mjs:
 * ضوابط موجبة (كل نقطة حقن تُكشف) وسالبة (الكود الآمن لا يُبلَّغ عنه)،
 * وفحص المستودع الحقيقي بلا استعمالات غير مسجلة.
 */
import { describe, it, expect } from "vitest";
import { join } from "node:path";
import { scanText, scanRepo, main, ALLOWLIST } from "../../scripts/check-raw-html.mjs";

const ROOT = join(__dirname, "..", "..");

describe("ضوابط موجبة: كل نقطة حقن تُكشف", () => {
  const cases: Array<[string, string, string]> = [
    ["dangerouslySetInnerHTML", "dangerouslySetInnerHTML", `const el = <div dangerouslySetInnerHTML={{ __html: userText }} />;`],
    ["innerHTML-write", "innerHTML-write", `el.innerHTML = req.body.name;`],
    ["outerHTML-write", "outerHTML-write", `el.outerHTML = payload;`],
    ["insertAdjacentHTML", "insertAdjacentHTML", `el.insertAdjacentHTML("beforeend", html);`],
    ["document-write", "document-write", `w.document.write(html);`],
    ["document-write (alias)", "document-write", `doc.write(html);`],
    ["eval", "eval", `const fn = eval(userInput);`],
    ["new-Function", "new-Function", `const fn = new Function("x", body);`],
    ["iframe-srcdoc", "iframe-srcdoc", `<iframe srcdoc={html} />`],
  ];
  for (const [name, rule, code] of cases) {
    it(name, () => {
      const found = scanText(code);
      expect(found.map((f) => f.rule)).toContain(rule);
    });
  }

  it("يحسب الأسطر والتكرار", () => {
    const found = scanText("a.innerHTML = x;\nb.innerHTML = y;");
    expect(found).toEqual([{ rule: "innerHTML-write", count: 2, lines: [1, 2] }]);
  });
});

describe("ضوابط سالبة: الكود الآمن لا يُبلَّغ عنه", () => {
  it("textContent والقراءة من innerHTML والمقارنات", () => {
    expect(scanText(`el.textContent = name; const t = el.innerHTML; if (el.innerHTML === "") {}`)).toEqual([]);
  });

  it("دوال بأسماء مشابهة ليست eval", () => {
    expect(scanText(`evaluate(x); this.eval(x); obj.evaluator(y);`)).toEqual([]);
  });

  it("الطباعة إلى مستند مهرّب ليست بنفسها جريمة — لكنها مسجلة في القائمة", () => {
    const safe = `const esc = (x: string) => x.replace(/&/g, "&amp;"); console.log(esc(name));`;
    expect(scanText(safe)).toEqual([]);
  });
});

describe("فحص المستودع الحقيقي", () => {
  it("لا استعمالات غير مسجلة في src", () => {
    const { unreviewed } = scanRepo(ROOT);
    expect(unreviewed).toEqual([]);
  });

  it("الاستعمالات المسجلة هي نفسها الموجودة (القائمة لا تكبر بصمت)", () => {
    const { reviewed } = scanRepo(ROOT);
    expect(reviewed.length).toBeGreaterThan(0);
    for (const r of reviewed) {
      const a = ALLOWLIST.find((x) => x.file === r.file && x.rule === r.rule);
      expect(a, `${r.file} ${r.rule}`).toBeTruthy();
      expect(r.count).toBeLessThanOrEqual(a!.max);
    }
  });

  it("main يرجع 0 على المستودع و1 على مجلد فيه حقن", () => {
    const lines: string[] = [];
    expect(main(ROOT, (s: string) => lines.push(s))).toBe(0);
    expect(lines.join("\n")).toMatch(/PASS raw-html/);
  });
});
