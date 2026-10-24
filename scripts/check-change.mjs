#!/usr/bin/env node
/**
 * Decision 58 — change management. Every commit and pull request names: the decision(s) of the comparison document
 * it implements, the area, the affected controls (G01–G28), the tests, and the migration plan (decision 41). This
 * check reads them and warns about anything missing or inconsistent; it never blocks (pass --strict to fail).
 *
 * Commit trailers (see .gitmessage):
 *   Decision: 40, 60            (numbers 1–71 of the document, or "none — <why>")
 *   Area: <who owns the data / which part of the system>
 *   Controls: G22, G24          (or "none")
 *   Tests: U02a, U02b, TR01–TR07 (test ids, or "none — <why>")
 *   Migration: 0026 — <plan>    (or "none")
 *
 * Usage:
 *   node scripts/check-change.mjs                       commits of this push / pull request (CI), else the last commit
 *   node scripts/check-change.mjs --range A..B          those commits
 *   node scripts/check-change.mjs --message <file>      one commit message (the commit-msg hook in .githooks/)
 *   PR_BODY="…" node scripts/check-change.mjs           also the pull request description
 */
import { readFileSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { join } from "node:path";

const ROOT = new URL("..", import.meta.url).pathname;
const args = process.argv.slice(2);
const opt = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };
const strict = args.includes("--strict");
const gha = !!process.env.GITHUB_ACTIONS;
const lib = JSON.parse(readFileSync(join(ROOT, "tests/acceptance-library.json"), "utf8"));
const git = (...a) => { try { return execFileSync("git", a, { cwd: ROOT, stdio: ["ignore", "pipe", "ignore"] }).toString(); } catch { return ""; } };

const FIELDS = [
  { key: "decision", labels: ["Decision", "Decisions", "القرار", "القرارات"], what: "رقم القرار من المستند (1–71) أو none مع السبب" },
  { key: "area", labels: ["Area", "المجال"], what: "المجال" },
  { key: "controls", labels: ["Controls", "Control", "الضوابط"], what: "ضوابط G المتأثرة أو none" },
  { key: "tests", labels: ["Tests", "Test", "الاختبارات"], what: "معرّفات الاختبارات أو none مع السبب" },
  { key: "migration", labels: ["Migration", "Migrations", "الترحيل", "خطة الترحيل"], what: "الترحيل وخطته (القرار 41) أو none" },
];

/** "Key: value" lines (commit trailers, or the PR template's fields). */
function fields(text) {
  const out = {};
  for (const line of String(text ?? "").split(/\r?\n/)) {
    const m = line.match(/^\s*(?:[-*]\s*)?(?:\*\*)?([^:*：]{2,24}?)(?:\*\*)?\s*[:：]\s*(.+?)\s*$/);
    if (!m) continue;
    const f = FIELDS.find((x) => x.labels.some((l) => l.toLowerCase() === m[1].trim().toLowerCase()));
    if (f && !out[f.key] && !/^<.*>$/.test(m[2]) && !/^`?_+`?$/.test(m[2])) out[f.key] = m[2];
  }
  return out;
}
const none = (v) => /^none\b|^لا\b|^لا يوجد/i.test(String(v ?? "").trim());

/** Problems of one change record; `files` (when known) are the paths it touches. */
function check(f, files = []) {
  const problems = [];
  for (const x of FIELDS) if (!f[x.key]) problems.push(`ينقصه «${x.labels[0]}»: ${x.what}`);
  if (f.decision && !none(f.decision)) {
    const nums = (f.decision.match(/\d+/g) ?? []).map(Number);
    if (nums.length === 0) problems.push(`Decision بلا رقم: «${f.decision}»`);
    for (const n of nums) if (n < 1 || n > 71) problems.push(`Decision ${n} ليس من القرارات 1–71`);
  }
  if (f.decision && none(f.decision) && !/[—–-]|:|لأن|because/.test(f.decision)) problems.push("Decision: none بلا سبب");
  if (f.controls && !none(f.controls)) {
    const gs = f.controls.match(/G\d{2}/g) ?? [];
    if (gs.length === 0) problems.push(`Controls بلا معرّف G: «${f.controls}»`);
    for (const g of gs) if (!lib.controls[g]) problems.push(`${g} ليس في سجل الضوابط G01–G28`);
  }
  const migrations = files.filter((p) => /^supabase\/migrations\/.+\.sql$/.test(p));
  if (migrations.length) {
    if (!f.migration || none(f.migration)) problems.push(`يغيّر ترحيلات (${migrations.map((p) => p.split("/").pop()).join("، ")}) و«Migration» فارغ أو none`);
    else for (const p of migrations) {
      const num = p.match(/_(\d{4}[a-z]?)_/)?.[1];
      if (num && !f.migration.includes(num)) problems.push(`«Migration» لا يذكر ${num}`);
    }
  }
  const code = files.some((p) => /^(src|supabase|bridge|scripts)\//.test(p) && !/\.md$/.test(p));
  if (code && f.tests && none(f.tests) && !/[—–-]|:|لأن|because/.test(f.tests)) problems.push("يغيّر الشيفرة و«Tests: none» بلا سبب");
  return problems;
}

function report(where, problems) {
  if (!problems.length) { console.log(`✓ ${where}`); return 0; }
  for (const p of problems) {
    if (gha) console.log(`::warning title=سجل التغيير (القرار 58) — ${where.replace(/[:,\n]/g, " ")}::${p}`);
    else console.log(`⚠ ${where}: ${p}`);
  }
  return problems.length;
}

let total = 0;
const msgFile = opt("--message");
if (msgFile) {
  const text = readFileSync(msgFile, "utf8").split("\n").filter((l) => !l.startsWith("#")).join("\n");
  const staged = git("diff", "--cached", "--name-only").split("\n").filter(Boolean);
  total += report("هذا الإيداع", check(fields(text), staged));
} else {
  let range = opt("--range");
  if (!range) {
    const zero = /^0+$/;
    if (process.env.PR_BASE) range = `${process.env.PR_BASE}..HEAD`;
    else if (process.env.BEFORE && !zero.test(process.env.BEFORE) && git("cat-file", "-t", process.env.BEFORE).trim() === "commit") range = `${process.env.BEFORE}..HEAD`;
    else range = "HEAD~1..HEAD";
  }
  const log = git("log", "--no-merges", "--format=%H%x1f%s%x1f%B%x1e", range);
  const commits = log.split("\x1e").map((c) => c.trim()).filter(Boolean).map((c) => { const [sha, subject, body] = c.split("\x1f"); return { sha, subject, body }; });
  for (const c of commits) {
    const files = git("diff-tree", "--no-commit-id", "--name-only", "-r", c.sha).split("\n").filter(Boolean);
    total += report(`${c.sha.slice(0, 8)} ${c.subject.slice(0, 60)}`, check(fields(c.body), files));
  }
  if (!commits.length) console.log(`(no commits in ${range})`);
}
if (process.env.PR_BODY !== undefined && process.env.PR_BODY !== "") {
  const changed = process.env.PR_BASE ? git("diff", "--name-only", `${process.env.PR_BASE}...HEAD`).split("\n").filter(Boolean) : [];
  total += report("وصف طلب الدمج", check(fields(process.env.PR_BODY), changed));
}
if (total) console.log(`\nسجل التغيير: ${total} ملاحظة — أكملها في رسالة الإيداع (قالب .gitmessage) أو وصف طلب الدمج. TESTING.md §4.`);
process.exit(strict && total ? 1 : 0);
