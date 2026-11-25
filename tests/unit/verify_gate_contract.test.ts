import { describe, expect, it } from "vitest";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, chmodSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

// Exercise the real orchestration with inert commands in an empty fixture project.
// No application, database, browser, protected fixture or network call is run.
function run(extra: Record<string, string>) {
  const root = mkdtempSync(join(tmpdir(), "roomai-verify-contract-"));
  try {
    for (const dir of ["bin", "scripts", "tests/sql", "tests/android", "scripts/bridge"]) mkdirSync(join(root, dir), { recursive: true });
    writeFileSync(join(root, "scripts/verify.sh"), readFileSync(resolve("scripts/verify.sh")));
    writeFileSync(join(root, "scripts/test-log.mjs"), "// inert fixture logger\n");
    mkdirSync(join(root, "tests/isolation"), { recursive: true });
    writeFileSync(join(root, "tests/isolation/acceptance-gate.sh"), 'echo "ISOLATION ACCEPTANCE: INCOMPLETE"; exit 1\n');
    writeFileSync(join(root, "tests/isolation/scoped-release-gate.sh"), 'if [[ "${MOCK_SCOPED_FAIL:-}" = 1 ]]; then echo "SCOPED RELEASE GATE: FAIL"; exit 1; fi\nexit 0\n');
    for (const file of ["tests/sql/run.sh", "tests/sql/concurrency.sh", "scripts/migration-check.sh", "tests/android/run.sh", "scripts/bridge/check.sh"]) writeFileSync(join(root, file), "exit 0\n");
    for (const cmd of ["npm", "psql", "npx"]) {
      const path = join(root, "bin", cmd);
      writeFileSync(path, '#!/usr/bin/env bash\nif [[ "$*" = "playwright test" && "${MOCK_E2E_FAIL:-}" = 1 ]]; then echo "synthetic e2e failure"; exit 7; fi\necho "inert command passed"\nexit 0\n');
      chmodSync(path, 0o755);
    }
    const env = { ...process.env, PATH: `${join(root, "bin")}:${process.env.PATH}`, CI: "", GITHUB_ACTIONS: "", QUICK: "", ALLOW_P1_FAIL: "", MOCK_E2E_FAIL: "", VERIFY_OUT: join(root, "results") };
    for (const key of Object.keys(env)) if (key.startsWith("SKIP_")) delete env[key as keyof typeof env];
    const result = spawnSync("bash", [join(root, "scripts/verify.sh")], { cwd: root, env: { ...env, ...extra }, encoding: "utf8" });
    return { status: result.status, output: result.stdout + result.stderr, ledger: existsSync(join(root, "results/gates.tsv")) ? readFileSync(join(root, "results/gates.tsv"), "utf8") : "" };
  } finally { rmSync(root, { recursive: true, force: true }); }
}

describe("required verification gate contract", () => {
  it("passes only when every invoked full gate executes successfully", () => {
    const r = run({});
    expect(r.status).toBe(0);
    const gates = r.ledger.split("\n").filter((l) => !l.startsWith("isolation-matrix\t"));
    expect(gates.join("\n")).not.toContain("SKIPPED");
    expect(gates.join("\n")).not.toContain("FAIL");
    expect(r.ledger).toMatch(/isolation-scoped\tP0\tPASS/);
    expect(r.output).toContain("RESULT: PASS");
    expect(r.output).toContain("full isolation matrix was NOT RUN");
  });
  it("lists the full isolation matrix as not run, never as PASS", () => {
    const r = run({});
    expect(r.ledger).toMatch(/isolation-matrix\treport\tSKIPPED/);
    expect(r.ledger).not.toMatch(/isolation-matrix\t[^\t]*\tPASS/);
  });
  it("fails full verification when the scoped isolation gate fails", () => {
    const r = run({ MOCK_SCOPED_FAIL: "1" });
    expect(r.status).toBe(1);
    expect(r.ledger).toMatch(/isolation-scoped\tP0\tFAIL/);
    expect(r.output).not.toContain("RESULT: PASS");
  });
  it("fails full verification when the scoped isolation gate is skipped locally", () => {
    const r = run({ SKIP_SQL: "1" });
    expect(r.status).toBe(1);
    expect(r.output).not.toContain("RESULT: PASS");
  });
  it("fails full verification when required e2e is skipped locally", () => {
    const r = run({ SKIP_E2E: "1" });
    expect(r.ledger).toContain("SKIPPED");
    expect(r.status).toBe(1);
    expect(r.output).not.toContain("RESULT: PASS");
  });
  it("does not let a legacy P1 override accept a failed e2e gate", () => {
    const r = run({ MOCK_E2E_FAIL: "1", ALLOW_P1_FAIL: "1" });
    expect(r.ledger).toContain("FAIL");
    expect(r.status).toBe(1);
    expect(r.output).not.toContain("RESULT: PASS");
  });
  it("fails a skipped non-browser required gate too", () => {
    const r = run({ SKIP_BUILD: "1" });
    expect(r.status).toBe(1);
    expect(r.output).not.toContain("RESULT: PASS");
  });
  it("rejects partial QUICK execution in CI", () => {
    const r = run({ CI: "1", QUICK: "1" });
    expect(r.status).toBe(2);
    expect(r.output).toContain("full verification required");
    expect(r.output).not.toContain("RESULT: PASS");
  });
  it("quick mode cannot print the full verification success marker", () => {
    const r = run({ QUICK: "1" });
    expect(r.status).toBe(0);
    expect(r.output).toContain("RESULT: PARTIAL CHECK PASSED");
    expect(r.output).not.toContain("RESULT: PASS");
    expect(r.ledger).not.toContain("e2e\t");
  });
  it("ignores local skip switches in CI and actually invokes the fixture gate", () => {
    const r = run({ CI: "1", SKIP_E2E: "1" });
    expect(r.status).toBe(0);
    expect(r.ledger.split("\n").filter((l) => !l.startsWith("isolation-matrix\t")).join("\n")).not.toContain("SKIPPED");
    expect(r.ledger).toMatch(/e2e\tP0\tPASS/);
  });
});
