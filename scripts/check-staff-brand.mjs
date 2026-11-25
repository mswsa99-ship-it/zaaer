#!/usr/bin/env node
/**
 * Plan 3.4 — inventory of what the staff and the guest see today: product-name and hotel-name occurrences and
 * every browser-tab title, each classified by surface (staff / guest / shared). This is the change list for the
 * rename to RoomAI and, after the design approval (3.1), the same scan becomes the gate of «الاسم RoomAI في كل
 * ما يراه الموظف». Always a report; it fails nothing while 3.1 is open.
 *
 *   node scripts/check-staff-brand.mjs
 */
import { readFileSync, readdirSync, statSync, existsSync } from "node:fs";
import { join, relative } from "node:path";
import { findBrandOccurrences, findTitleAssignments, classifySurface } from "./lib/brandScan.mjs";

const ROOT = new URL("..", import.meta.url).pathname;
/** The names in play: today's product name, the demo hotel's name, and the approved-candidate RoomAI name. */
const BRANDS = ["مساعد الاستقبال الذكي", "مساعد الاستقبال", "فايف اورز", "Five Hours", "RoomAI"];

function walk(dir) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) out.push(...walk(p));
    else if (/\.(ts|tsx|html|json|webmanifest)$/.test(name)) out.push(p);
  }
  return out;
}

const files = [join(ROOT, "index.html"), ...walk(join(ROOT, "src"))];
for (const extra of ["public/manifest.webmanifest", "public/manifest.json"]) {
  const p = join(ROOT, extra);
  if (existsSync(p)) files.push(p);
}

const occurrences = [];
const titles = [];
for (const abs of files) {
  const rel = relative(ROOT, abs).split("\\").join("/");
  const src = readFileSync(abs, "utf8");
  occurrences.push(...findBrandOccurrences(src, BRANDS, rel));
  titles.push(...findTitleAssignments(src, rel));
}

console.log("== أماكن الأسماء (السطح: staff يجب أن يرى RoomAI؛ guest يرى اسم فندقه) ==");
for (const o of occurrences) {
  console.log(`${classifySurface(o.file).padEnd(6)}  ${o.file}:${o.line}  «${o.brand}»  ${o.context.slice(0, 110)}`);
}
console.log(`\n== عناوين تبويب المتصفح (${titles.length}) ==`);
for (const t of titles) console.log(`${classifySurface(t.file).padEnd(6)}  ${t.file}:${t.line}  [${t.kind}]  ${t.value.slice(0, 110)}`);
console.log(`\n${occurrences.length} ظهورًا للأسماء في ${new Set(occurrences.map((o) => o.file)).size} ملفًا`);
