#!/usr/bin/env node
/**
 * 5.6 (ق7) — قاعدة فحص أسلوب تمنع إدخال HTML خام في الكود.
 *
 * حدود الأداة بصراحة: هذا بوابة مراجعة (lint-style gate)، وليس معقّمًا ولا إثباتًا أن
 * الموجود آمن. يكشف نقاط دخول الحقن المعروفة — dangerouslySetInnerHTML، الكتابة في
 * innerHTML/outerHTML، insertAdjacentHTML، document.write، eval، new Function، srcdoc —
 * ويفشل عند أي استعمال جديد غير مسجل. الاستعمالات المبررة الحالية مسجلة في ALLOWLIST
 * بسببها وبعددها، فإن زاد عددها فشل الفحص حتى تُراجع.
 *
 * التشغيل: node scripts/check-raw-html.mjs [الجذر]   (الخروج 1 عند وجود استعمال غير مسجل)
 */
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

/** كل قاعدة: معرف، نمط، ولماذا هي خطرة. */
export const RULES = [
  { id: "dangerouslySetInnerHTML", pattern: /dangerouslySetInnerHTML/g, why: "يعرض HTML خامًا داخل React متجاوزًا التهريب التلقائي" },
  { id: "innerHTML-write", pattern: /\.innerHTML\s*=(?![=>])/g, why: "الكتابة في innerHTML تُنفّذ وسومًا وسمات أحداث محقونة" },
  { id: "outerHTML-write", pattern: /\.outerHTML\s*=(?![=>])/g, why: "الكتابة في outerHTML مثل innerHTML مع استبدال العنصر نفسه" },
  { id: "insertAdjacentHTML", pattern: /\.insertAdjacentHTML\s*\(/g, why: "يحقن HTML خامًا في الشجرة" },
  { id: "document-write", pattern: /\b(?:document|doc)\.write(?:ln)?\s*\(/g, why: "يكتب HTML خامًا في مستند؛ لا يقبل إلا لمستند طباعة مهرّب" },
  { id: "eval", pattern: /(?<![\w$.])eval\s*\(/g, why: "ينفّذ نصًا ككود" },
  { id: "new-Function", pattern: /\bnew\s+Function\s*\(/g, why: "ينشئ دالة من نص — مثل eval" },
  { id: "iframe-srcdoc", pattern: /\bsrcdoc\s*=/gi, why: "يحمّل HTML خامًا في إطار" },
];

/**
 * الاستعمالات الحالية المبررة. كل مدخل: لاحقة الملف، القاعدة، العدد الأقصى المسموح، والمبرر.
 * أي استعمال جديد أو زيادة في العدد تُسقط الفحص حتى تُراجع وتسجل هنا بمبررها.
 */
export const ALLOWLIST = [
  {
    file: "src/components/Guests.tsx",
    rule: "iframe-srcdoc",
    max: 1,
    why: "معاينة ملخص الإقامة: إطار sandbox بلا سكربتات يعرض القالب نفسه المستعمل في الطباعة، وكل قيمة تمر بـ esc() في printTemplates.ts",
  },
  {
    file: "src/components/Guests.tsx",
    rule: "document-write",
    max: 1,
    why: "نافذة طباعة ملخص الإقامة: مستند مستقل وكل قيمة تمر بـ esc() قبل التركيب",
  },
  {
    file: "src/lib/exports.ts",
    rule: "document-write",
    max: 1,
    why: "إطار الطباعة المخفي: printDocument يكتب HTML يبنيه printDocs.ts مع escHtml لكل خلية",
  },
];

const SCAN_DIRS = ["src"];
const SCAN_EXT = /\.(?:ts|tsx|js|jsx)$/;

/** يفحص نص ملف واحد ويرجع الاستعمالات الموجودة: {rule, line, count} لكل قاعدة. */
export function scanText(text) {
  const findings = [];
  for (const rule of RULES) {
    rule.pattern.lastIndex = 0;
    const lines = [];
    let m;
    while ((m = rule.pattern.exec(text))) {
      lines.push(text.slice(0, m.index).split("\n").length);
    }
    if (lines.length) findings.push({ rule: rule.id, count: lines.length, lines });
  }
  return findings;
}

function* walk(dir) {
  for (const name of readdirSync(dir)) {
    if (name === "node_modules" || name.startsWith(".")) continue;
    const p = join(dir, name);
    if (statSync(p).isDirectory()) yield* walk(p);
    else if (SCAN_EXT.test(name)) yield p;
  }
}

/** يفحص المستودع ويرجع {reviewed, unreviewed} — unreviewed غير الفارغ يُسقط البوابة. */
export function scanRepo(root) {
  const reviewed = [];
  const unreviewed = [];
  for (const dir of SCAN_DIRS) {
    const abs = join(root, dir);
    let files;
    try {
      files = [...walk(abs)];
    } catch {
      continue;
    }
    for (const file of files) {
      const rel = relative(root, file).replace(/\\/g, "/");
      for (const f of scanText(readFileSync(file, "utf8"))) {
        const allowed = ALLOWLIST.find((a) => a.rule === f.rule && rel === a.file);
        if (allowed && f.count <= allowed.max) {
          reviewed.push({ file: rel, ...f, why: allowed.why });
        } else {
          unreviewed.push({ file: rel, ...f });
        }
      }
    }
  }
  return { reviewed, unreviewed };
}

export function main(root = process.cwd(), out = console.log) {
  const { reviewed, unreviewed } = scanRepo(root);
  for (const r of reviewed) out(`REVIEWED ${r.file}:${r.lines.join(",")} ${r.rule} — ${r.why}`);
  for (const u of unreviewed) out(`UNREVIEWED ${u.file}:${u.lines.join(",")} ${u.rule} — ${RULES.find((r) => r.id === u.rule).why}`);
  if (unreviewed.length) {
    out(`FAIL raw-html: ${unreviewed.length} unreviewed raw-HTML sink(s); justify in ALLOWLIST of scripts/check-raw-html.mjs or remove`);
    return 1;
  }
  out(`PASS raw-html: no unreviewed raw-HTML sinks (${reviewed.length} reviewed use(s))`);
  return 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  process.exit(main(process.argv[2] ?? process.cwd()));
}
