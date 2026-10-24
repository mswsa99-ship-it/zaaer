#!/usr/bin/env node
/**
 * Decision 56 — the test log of one `npm run verify`, in the template of the testing rules (§11 «قالب سجل اختبار»):
 * test_id / rule_ids · app and schema version · environment · fixture · expected · actual · status · evidence ·
 * executor and date · defect and retest.
 *
 * It is generated from the run's own outputs (the gate logs, the unit and end-to-end JSON reports, the race and
 * migration-check output), never typed by hand, so a test that did not run can never appear as "passed". Everything
 * quoted from those outputs goes through redact(): no personal data, no tokens, no keys.
 *
 * Inputs (written by scripts/verify.sh under $VERIFY_OUT, default verify-results/): gates.tsv, gates/<gate>.log,
 * unit.json, e2e.json. Outputs: test-log.md (for people), test-log.json (for tools), test-log-summary.md (CI page).
 */
import { readFileSync, writeFileSync, existsSync, readdirSync } from "node:fs";
import { execSync } from "node:child_process";
import { createHash } from "node:crypto";
import { join, basename, relative, resolve } from "node:path";
import { redact } from "./lib/redact.mjs";

const ROOT = new URL("..", import.meta.url).pathname;
const OUT = resolve(ROOT, process.env.VERIFY_OUT || "verify-results");
const read = (p) => (existsSync(p) ? readFileSync(p, "utf8") : null);
const sh = (cmd) => { try { return execSync(cmd, { cwd: ROOT, stdio: ["ignore", "pipe", "ignore"] }).toString().trim(); } catch { return null; } };

const lib = JSON.parse(readFileSync(join(ROOT, "tests/acceptance-library.json"), "utf8"));
const ID = /^(G\d{2}(?:[–/]G\d{2})*|[A-Z]{1,3}(?:-[A-Z]{1,2})?\d{2}[a-z0-9]*)(?=[\s—:]|$)/;

const LETTERS = new Set(["A", "R", "F", "H", "U", "D", "X"]);
/** The controls a test covers: the library's for a code of the rules, otherwise those it names itself. */
function controlsOf(id, text) {
  const out = new Set();
  const m = id && id.match(/^([A-Z])(\d{2})/);
  if (m && LETTERS.has(m[1]) && lib.codes[`${m[1]}${m[2]}`]) for (const g of lib.codes[`${m[1]}${m[2]}`].controls) out.add(g);
  for (const g of String(text ?? "").match(/\bG\d{2}\b/g) ?? []) if (lib.controls[g]) out.add(g);
  const range = String(id ?? "").match(/^G(\d{2})–G(\d{2})/);
  if (range) for (let i = +range[1]; i <= +range[2]; i++) out.add(`G${String(i).padStart(2, "0")}`);
  return [...out].sort();
}
function expectedOf(id, title) {
  const m = id && id.match(/^([A-Z])(\d{2})/);
  const c = m && LETTERS.has(m[1]) ? lib.codes[`${m[1]}${m[2]}`] : null;
  return c ? `${c.expected} — ${title}` : title;
}
function split(title) {
  const t = String(title ?? "").trim();
  const m = t.match(ID);
  if (m) return { id: m[1], title: t.slice(m[1].length).replace(/^[\s—:]+/, "") };
  const p = t.match(/\((G\d{2}|[A-Z]{1,3}(?:-[A-Z]{1,2})?\d{2}[a-z0-9]*)\)/);
  return { id: p ? p[1] : null, title: t };
}

// ------------------------------------------------------------------ the run
const gates = (read(join(OUT, "gates.tsv")) ?? "").split("\n").filter(Boolean).map((l) => { const [name, level, status, seconds] = l.split("\t"); return { name, level, status, seconds }; });
const gate = (name) => gates.find((g) => g.name === name);
const gateLog = (name) => read(join(OUT, "gates", `${name.replace(/:/g, "-")}.log`));
const rows = [];
let auto = 0;
const add = (layer, file, rawTitle, status, actual, evidence) => {
  const { id, title } = split(rawTitle);
  rows.push({
    test_id: id ?? `${layer}/${file}#${++auto}`,
    rule_ids: controlsOf(id, rawTitle),
    layer, file, title: redact(title, 220),
    expected: redact(expectedOf(id, title), 260),
    actual: redact(actual),
    status,
    evidence,
  });
};
/** Tests of a gate that produced no results: blocked if it failed before them, not_run if it was skipped. */
const missing = (layer, name, what) => {
  const g = gate(name);
  if (!g) return;
  const st = /SKIPPED/.test(g.status) ? "not_run" : /FAIL/.test(g.status) ? "blocked" : null;
  if (st) rows.push({ test_id: `${layer}/*`, rule_ids: [], layer, file: what, title: `${what}: ${g.status}`, expected: "تعمل البوابة وتُنتج نتائجها", actual: redact(g.status), status: st, evidence: `gates/${name.replace(/:/g, "-")}.log` });
};

// SQL suites: the result table every suite prints (" PASS | <id title> | <detail>")
{
  const log = gateLog("sql");
  let suite = "sql", n = 0;
  if (log) for (const line of log.split("\n")) {
    const s = line.match(/^== running (.+?)(?: tests)?(?: \(|$)/);
    if (s) { suite = s[1].trim(); continue; }
    const m = line.match(/^\s*(PASS|FAIL)\s*\|\s*(.+?)\s*\|\s?(.*)$/);
    if (m) { n++; add("sql", suite, m[2], m[1] === "PASS" ? "passed" : "failed", m[3] || (m[1] === "PASS" ? "PASS" : "FAIL"), "gates/sql.log"); }
  }
  if (!n) missing("sql", "sql", "SQL suites");
}
// races: "PASS X01 …" / "FAIL X01 …"
{
  const log = gateLog("race"); let n = 0;
  if (log) for (const line of log.split("\n")) {
    const m = line.match(/^\s*(PASS|FAIL)\s+([A-Z]{1,3}\d{2}[a-z0-9]*)\s*(.*)$/);
    if (m) { n++; add("race", "concurrency.sh", `${m[2]} ${m[3]}`, m[1] === "PASS" ? "passed" : "failed", m[3], "gates/race.log"); }
  }
  if (!n) missing("race", "race", "two-session races");
}
// migration check (X10)
{
  const log = gateLog("migration");
  const m = log && log.match(/^(PASS|FAIL) migration-check:?(.*)$/m);
  const nothing = log && /nothing pending/.test(log);
  if (m || nothing) add("migration", "migration-check.sh", "X10 the pending migrations on a synthetic history lose nothing; the dump restores identically",
    nothing || m[1] === "PASS" ? "passed" : "failed", nothing ? "nothing pending — production has every migration" : m[2], "migration-report.txt");
  else missing("migration", "migration", "migration check");
}
// unit (vitest JSON)
{
  const j = (() => { try { return JSON.parse(read(join(OUT, "unit.json")) ?? "null"); } catch { return null; } })();
  if (j) for (const f of j.testResults ?? []) for (const a of f.assertionResults ?? []) {
    const st = a.status === "passed" ? "passed" : a.status === "failed" ? "failed" : "not_run";
    const titled = ID.test(a.title) ? a.title : [...(a.ancestorTitles ?? []), a.title].join(" › ");
    add("unit", basename(f.name), titled, st, st === "failed" ? (a.failureMessages ?? []).join(" ") : st === "passed" ? `passed in ${Math.round(a.duration ?? 0)} ms` : a.status, "unit.json");
  }
  else missing("unit", "unit", "unit tests");
}
// end to end (Playwright JSON)
{
  const j = (() => { try { return JSON.parse(read(join(OUT, "e2e.json")) ?? "null"); } catch { return null; } })();
  const walk = (suite, file) => {
    for (const spec of suite.specs ?? []) for (const t of spec.tests ?? []) {
      const results = t.results ?? [];
      const last = results[results.length - 1] ?? {};
      const status = t.status === "expected" ? "passed" : t.status === "flaky" ? "passed" : t.status === "skipped" ? "not_run" : last.status === "interrupted" ? "blocked" : "failed";
      const trace = (last.attachments ?? []).find((x) => x.name === "trace")?.path;
      const actual = status === "failed" ? (last.error?.message ?? last.status) : t.status === "flaky" ? `passed on retry ${results.length - 1} (flaky — see TESTING.md §6)` : status === "passed" ? `passed in ${Math.round((last.duration ?? 0) / 100) / 10} s` : t.status;
      add("e2e", file ?? spec.file, spec.title, status, actual, trace ? relative(ROOT, trace) : "e2e.json");
    }
    for (const s of suite.suites ?? []) walk(s, file ?? s.file);
  };
  if (j) for (const s of j.suites ?? []) walk(s, s.file);
  else missing("e2e", "e2e", "end-to-end tests");
}
// gates without individual tests (the build is evidence of compiling, not of behaviour)
for (const g of gates.filter((x) => ["typecheck", "edge", "bridge", "build", "build:demo"].includes(x.name))) {
  rows.push({ test_id: `GATE-${g.name}`, rule_ids: [], layer: "gate", file: g.name, title: `البوابة ${g.name}`, expected: "تنجح البوابة", actual: redact(`${g.status} ${g.seconds}`), status: /^PASS/.test(g.status) ? "passed" : /SKIPPED/.test(g.status) ? "not_run" : "failed", evidence: `gates/${g.name.replace(/:/g, "-")}.log` });
}

// ------------------------------------------------------------------ versions and environment
const commit = sh("git rev-parse HEAD") ?? "unknown";
const dirty = (sh("git status --porcelain --untracked-files=no") ?? "").split("\n").filter((l) => l && !l.includes("verify-results")).length > 0;
const migDir = join(ROOT, "supabase/migrations");
const migs = readdirSync(migDir).filter((f) => f.endsWith(".sql")).sort();
const schemaDigest = createHash("sha256").update(migs.map((f) => f + "\n" + readFileSync(join(migDir, f), "utf8")).join("\n")).digest("hex").slice(0, 12);
const pg = sh(`psql -Atc "show server_version" postgres`);
const e2eJson = (() => { try { return JSON.parse(read(join(OUT, "e2e.json")) ?? "null"); } catch { return null; } })();
const ci = !!process.env.GITHUB_ACTIONS;
const now = new Date();
const riyadh = new Date(now.getTime() + 3 * 3600_000).toISOString().replace("Z", "+03:00").replace(/\.\d{3}/, "");
const run = {
  app_version: `${commit.slice(0, 12)}${dirty ? " (+ uncommitted changes)" : ""}`,
  schema_version: `${migs.length} migrations, last ${migs[migs.length - 1]?.replace(/\.sql$/, "")}, sha256 ${schemaDigest}`,
  environment: [
    ci ? "CI: GitHub Actions (ubuntu)" : "local",
    `Node ${process.version}`,
    pg ? `PostgreSQL ${pg} (isolated test database, rebuilt from the migrations)` : "PostgreSQL not reachable",
    e2eJson?.config?.version ? `Playwright ${e2eJson.config.version} on the demo build (in-browser backend, no network, no real payment or WhatsApp)` : null,
  ].filter(Boolean).join(" · "),
  fixture: "synthetic only: tests/sql/bootstrap.sh + each SQL suite's own seed · tests/sql/history_fixture.sql (migration check) · src/demo/data.ts in a fresh browser context per end-to-end test · tests/sql/concurrency.sh seed",
  executor: ci ? `github-actions · ${process.env.GITHUB_WORKFLOW ?? ""} run ${process.env.GITHUB_RUN_ID ?? "?"}/${process.env.GITHUB_RUN_ATTEMPT ?? "1"} · ${process.env.GITHUB_EVENT_NAME ?? ""} ${process.env.GITHUB_REF_NAME ?? ""}` : "local run (npm run verify)",
  date: `${riyadh} (Asia/Riyadh)`,
  run_ref: ci ? `${process.env.GITHUB_REPOSITORY ?? ""}/actions/runs/${process.env.GITHUB_RUN_ID ?? ""}` : `local-${commit.slice(0, 8)}-${now.getTime().toString(36)}`,
  gates,
};
for (const r of rows) {
  r.defect_retest = r.status === "failed" ? "يحتاج مرجع عطل وشدة ومسؤولًا؛ يُعاد الاختبار في نسخة الإصلاح" : r.status === "blocked" ? "يُعاد بعد إصلاح ما منع التشغيل" : r.status === "not_run" ? "غير متحقق — لا يُعدّ ناجحًا" : "—";
  r.evidence = `${r.evidence} · ${run.run_ref}`;
}

// ------------------------------------------------------------------ controls: what this run proves
// a test counts for its own scenario, and for the scenarios the library says it covers (X01 is R02 with two sessions…)
const scenariosOf = (id) => {
  const base = id.match(/^([A-Z])(\d{2})/)?.slice(1).join("");
  const covered = lib.covers?.[id]?.codes ?? lib.covers?.[base]?.codes ?? [];
  return [base, ...covered].filter(Boolean);
};
const passedIds = new Set(rows.filter((r) => r.status === "passed").flatMap((r) => scenariosOf(r.test_id)));
const failedIds = new Set(rows.filter((r) => r.status !== "passed").flatMap((r) => scenariosOf(r.test_id)));
const controlRows = Object.entries(lib.controls).map(([g, c]) => {
  const linked = Object.entries(lib.codes).filter(([, v]) => v.controls.includes(g)).map(([k]) => k);
  const passed = linked.filter((k) => passedIds.has(k) && !failedIds.has(k));
  const failed = linked.filter((k) => failedIds.has(k));
  const absent = linked.filter((k) => !passedIds.has(k) && !failedIds.has(k));
  const extra = rows.filter((r) => r.rule_ids.includes(g) && !/^[ARFHUDX]\d{2}/.test(r.test_id)).length;
  return { control: g, priority: c.priority, rule: c.rule, passed, failed, absent, other_tests: extra };
});

const counts = rows.reduce((a, r) => ((a[r.status] = (a[r.status] ?? 0) + 1), a), {});
const byLayer = {};
for (const r of rows) { byLayer[r.layer] ??= {}; byLayer[r.layer][r.status] = (byLayer[r.layer][r.status] ?? 0) + 1; }

writeFileSync(join(OUT, "test-log.json"), JSON.stringify({ template: "ZAAER-TESTING-AND-CONTROL-RULES-AR §11 — قالب سجل اختبار (القرار 56)", run, counts, by_layer: byLayer, controls: controlRows, tests: rows }, null, 2));

// ------------------------------------------------------------------ markdown
const esc = (s) => String(s ?? "").replace(/\|/g, "／").replace(/\n/g, " ");
const ST = { passed: "passed", failed: "**failed**", blocked: "**blocked**", not_run: "not_run" };
const md = [];
md.push(`# سجل الاختبار — ${run.date}`, "");
md.push("يُولَّد آليًا من تشغيل `npm run verify` (القرار 56) بقالب ملف قواعد الاختبار §11. لا يُكتب يدويًا، ولا يحوي بيانات شخصية ولا رموز مصادقة.", "");
md.push("| الحقل | القيمة |", "| --- | --- |");
md.push(`| نسخة التطبيق | ${esc(run.app_version)} |`, `| نسخة المخطط | ${esc(run.schema_version)} |`, `| البيئة | ${esc(run.environment)} |`, `| fixture | ${esc(run.fixture)} |`, `| المنفّذ | ${esc(run.executor)} |`, `| التاريخ | ${esc(run.date)} |`, `| مرجع التشغيل | ${esc(run.run_ref)} |`, "");
md.push("## النتيجة", "", `| passed | failed | blocked | not_run | المجموع |`, "| --- | --- | --- | --- | --- |", `| ${counts.passed ?? 0} | ${counts.failed ?? 0} | ${counts.blocked ?? 0} | ${counts.not_run ?? 0} | ${rows.length} |`, "");
md.push("| الطبقة | passed | failed | blocked | not_run |", "| --- | --- | --- | --- | --- |");
for (const [l, c] of Object.entries(byLayer)) md.push(`| ${l} | ${c.passed ?? 0} | ${c.failed ?? 0} | ${c.blocked ?? 0} | ${c.not_run ?? 0} |`);
md.push("", "| البوابة | الحالة | المدة |", "| --- | --- | --- |", ...gates.map((g) => `| ${g.name} | ${esc(g.status)} | ${g.seconds} |`), "");
md.push("## الضوابط في هذا التشغيل", "", "رموز الملف المرتبطة بكل ضابط (§2): ما نجح في هذا التشغيل، وما فشل، وما ليس له اختبار بعد. «غير موجود» يعني غير متحقق، لا ناجحًا.", "");
md.push("| الضابط | الأولوية | نجح | فشل | غير موجود | اختبارات أخرى تذكره |", "| --- | --- | --- | --- | --- | --- |");
for (const c of controlRows) md.push(`| ${c.control} | ${c.priority} | ${c.passed.join("، ") || "—"} | ${c.failed.join("، ") || "—"} | ${c.absent.join("، ") || "—"} | ${c.other_tests || "—"} |`);
md.push("", "## الاختبارات", "", "| test_id | rule_ids | الطبقة | المتوقع | الفعلي | الحالة | الدليل | العطل وإعادة الاختبار |", "| --- | --- | --- | --- | --- | --- | --- | --- |");
const order = { failed: 0, blocked: 1, not_run: 2, passed: 3 };
for (const r of [...rows].sort((a, b) => order[a.status] - order[b.status])) md.push(`| ${esc(r.test_id)} | ${r.rule_ids.join(",") || "—"} | ${r.layer} | ${esc(r.expected)} | ${esc(r.actual)} | ${ST[r.status]} | ${esc(r.evidence)} | ${esc(r.defect_retest)} |`);
writeFileSync(join(OUT, "test-log.md"), md.join("\n") + "\n");

// a short version for the CI run page
const bad = rows.filter((r) => r.status !== "passed");
const summary = [
  `### سجل الاختبار (القرار 56) — ${run.app_version}`, "",
  `passed ${counts.passed ?? 0} · failed ${counts.failed ?? 0} · blocked ${counts.blocked ?? 0} · not_run ${counts.not_run ?? 0} — المجموع ${rows.length}`, "",
  `المخطط: ${run.schema_version}`, "",
  ...(bad.length ? ["| test_id | الحالة | الفعلي |", "| --- | --- | --- |", ...bad.slice(0, 40).map((r) => `| ${esc(r.test_id)} | ${r.status} | ${esc(r.actual).slice(0, 160)} |`), ""] : ["كل الاختبارات المنفّذة نجحت.", ""]),
  "السجل الكامل في الملفين test-log.md وtest-log.json ضمن ملحقات هذا التشغيل.",
];
writeFileSync(join(OUT, "test-log-summary.md"), summary.join("\n") + "\n");
console.log(`test log: ${rows.length} tests — passed ${counts.passed ?? 0}, failed ${counts.failed ?? 0}, blocked ${counts.blocked ?? 0}, not_run ${counts.not_run ?? 0} → ${relative(ROOT, join(OUT, "test-log.md"))}`);
