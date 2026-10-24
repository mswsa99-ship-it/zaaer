/**
 * Decisions 56 and 58 — the test log is built from the run's own outputs in the template of the testing rules, never
 * calls a test that did not run "passed", and carries no personal data or secrets; the change record check reads the
 * five fields of a commit message and warns about what is missing.
 */
import { describe, it, expect } from "vitest";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
// @ts-expect-error — a plain ES module of the scripts folder, without type declarations
import { redact } from "../../scripts/lib/redact.mjs";

const ROOT = join(__dirname, "..", "..");

describe("test log (decision 56)", () => {
  it("TL01 nothing personal or secret survives: e-mail, mobile, identity number, tokens, keys, long hex", () => {
    const raw = "guest a.b@example.com 0501234567 +966512345678 1012345678 eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijklmno Bearer abcdefghijklmnop1234 zb_d3e0d3e0d3e0d3e0d3e0 " + "a".repeat(40);
    const out = redact(raw);
    for (const leak of ["a.b@example.com", "0501234567", "512345678", "1012345678", "eyJhbGci", "abcdefghijklmnop1234", "zb_d3e0"]) expect(out).not.toContain(leak);
    expect(out).toContain("‹email›");
    expect(out).toContain("‹phone›");
    expect(out).toContain("‹id›");
    expect(redact("RCP-2026-000027 room 101 · 30000 halalas")).toBe("RCP-2026-000027 room 101 · 30000 halalas");
    expect(redact("x".repeat(500), 50)).toHaveLength(50);
  });

  it("TL02 the log is built from the outputs: statuses, controls from the library, skipped gates are not_run, no leak", () => {
    const out = mkdtempSync(join(tmpdir(), "verify-"));
    try {
      mkdirSync(join(out, "gates"));
      writeFileSync(join(out, "gates.tsv"), ["typecheck\tP0\tPASS\t3s", "unit\tP0\tPASS\t5s", "sql\tP0\tFAIL\t40s", "race\tP0\tSKIPPED (SKIP_SQL=1)\t-", "e2e\tP1\tPASS\t30s"].join("\n") + "\n");
      writeFileSync(join(out, "gates", "sql.log"), [
        "== running core acceptance tests",
        " result |                    name                     |  detail",
        " PASS   | R04 extension into booked period rejected; no partial update | ALLOCATION_CONFLICT",
        " FAIL   | F05 deposit refund 50 > available 40 rejected | accepted for guest 0509998877",
        " PASS   | RS01 future allocation does not flag the room reserved today | ok",
      ].join("\n"));
      writeFileSync(join(out, "unit.json"), JSON.stringify({ testResults: [{ name: "/x/tests/unit/trace.test.ts", assertionResults: [{ title: "TR01 a code", ancestorTitles: ["trace codes"], status: "passed", duration: 3, failureMessages: [] }] }] }));
      writeFileSync(join(out, "e2e.json"), JSON.stringify({ config: { version: "1.56.1" }, suites: [{ title: "f.spec.ts", file: "f.spec.ts", specs: [], suites: [{ title: "branch scope", specs: [
        { title: "U02a switching branch", file: "f.spec.ts", tests: [{ status: "expected", results: [{ status: "passed", duration: 1200 }] }] },
        { title: "U02b a late answer", file: "f.spec.ts", tests: [{ status: "unexpected", results: [{ status: "failed", duration: 900, error: { message: "Expected 0, owner owner@demo.sa" } }] }] },
      ] }] }] }));
      execFileSync("node", [join(ROOT, "scripts/test-log.mjs")], { cwd: ROOT, env: { ...process.env, VERIFY_OUT: out, GITHUB_ACTIONS: "" } });
      const log = JSON.parse(readFileSync(join(out, "test-log.json"), "utf8"));
      const by = (id: string) => log.tests.find((t: { test_id: string }) => t.test_id === id);
      expect(by("R04").status).toBe("passed");
      expect(by("R04").rule_ids).toEqual(["G05", "G06"]);
      expect(by("R04").expected).toContain("لا تحديث جزئي");          // the library's expected result for R04
      expect(by("F05").status).toBe("failed");
      expect(by("F05").defect_retest).toContain("مرجع عطل");
      expect(by("RS01").rule_ids).toEqual([]);
      expect(by("TR01").status).toBe("passed");
      expect(by("U02a").rule_ids).toEqual(["G24"]);
      expect(by("U02b").status).toBe("failed");
      expect(by("race/*").status).toBe("not_run");                     // a skipped gate is never "passed"
      expect(log.counts.passed).toBeGreaterThanOrEqual(4);
      const md = readFileSync(join(out, "test-log.md"), "utf8");
      for (const leak of ["0509998877", "owner@demo.sa"]) { expect(md).not.toContain(leak); expect(JSON.stringify(log)).not.toContain(leak); }
      for (const field of ["نسخة التطبيق", "نسخة المخطط", "البيئة", "fixture", "المنفّذ", "التاريخ"]) expect(md).toContain(field);
      const control = (g: string) => log.controls.find((c: { control: string }) => c.control === g);
      expect(control("G05").passed).toContain("R04");                  // R04 passed, nothing of R04 failed
      expect(control("G24").failed).toEqual(["U02"]);                  // one facet failed → the scenario is not passed
      expect(control("G24").passed).toEqual([]);
      expect(control("G28").absent).toEqual(["X10"]);                  // not run here → absent, never passed
    } finally { rmSync(out, { recursive: true, force: true }); }
  });
});

describe("change record (decision 58)", () => {
  const check = (msg: string) => {
    const dir = mkdtempSync(join(tmpdir(), "msg-"));
    try {
      writeFileSync(join(dir, "MSG"), msg);
      return execFileSync("node", [join(ROOT, "scripts/check-change.mjs"), "--message", join(dir, "MSG")], { cwd: ROOT, env: { ...process.env, GITHUB_ACTIONS: "" } }).toString();
    } finally { rmSync(dir, { recursive: true, force: true }); }
  };
  it("CC01 a complete record passes; missing or wrong fields are named, and the check never blocks", () => {
    expect(check("Do a thing\n\nDecision: 40, 60\nArea: الواجهة\nControls: G24\nTests: U02a\nMigration: none\n")).toContain("✓");
    const out = check("Do a thing\n\nDecision: 99\nControls: G77\nTests: none\n");
    expect(out).toContain("Decision 99");
    expect(out).toContain("G77");
    expect(out).toContain("Area");
    expect(out).toContain("Migration");
  });
});
