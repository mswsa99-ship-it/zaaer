#!/usr/bin/env node
/**
 * Plan 3.2 — gate: no color written directly in a component; every color comes from the one token file.
 * Scans index.html and src/** for color literals (scripts/lib/colorScan.mjs) and fails while any remains.
 *
 *   node scripts/check-design-tokens.mjs              gate mode: exit 1 on violations
 *   node scripts/check-design-tokens.mjs --inventory  report only (exit 0), grouped by file
 *
 * Until the owner approves the design system (3.1) and the token file exists, run --inventory: the current
 * literals are the migration list, not yet gate failures. Wiring into npm scripts/CI is proposed separately
 * (package.json belongs to another work package).
 */
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { findHardcodedColors } from "./lib/colorScan.mjs";

const ROOT = new URL("..", import.meta.url).pathname;
const SCAN_FILES = ["index.html"];
const SCAN_DIRS = ["src"];
const EXTENSIONS = /\.(ts|tsx|css)$/;
/** The future token file (created after approval 3.1) is the one place literals are allowed. */
const ALLOWED = [/^src\/lib\/designTokens\.ts$/];

function walk(dir) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) out.push(...walk(p));
    else if (EXTENSIONS.test(name)) out.push(p);
  }
  return out;
}

const inventory = process.argv.includes("--inventory");
const files = [...SCAN_FILES.map((f) => join(ROOT, f)), ...SCAN_DIRS.flatMap((d) => walk(join(ROOT, d)))];
const violations = [];
for (const abs of files) {
  const rel = relative(ROOT, abs).split("\\").join("/");
  if (ALLOWED.some((re) => re.test(rel))) continue;
  violations.push(...findHardcodedColors(readFileSync(abs, "utf8"), rel));
}

const byFile = new Map();
for (const v of violations) {
  if (!byFile.has(v.file)) byFile.set(v.file, []);
  byFile.get(v.file).push(v);
}
for (const [file, list] of [...byFile.entries()].sort()) {
  console.log(`${file} (${list.length})`);
  for (const v of list) console.log(`  ${v.line}:${v.column}  ${v.match}  ${v.context.slice(0, 120)}`);
}
console.log(`\n${violations.length} لونًا مباشرًا في ${byFile.size} ملفًا`);
if (violations.length && !inventory) {
  console.error("فشلت قاعدة الأسلوب (3.2): لا لون يُكتب مباشرة في مكوّن — انقله إلى ملف الرموز");
  process.exit(1);
}
