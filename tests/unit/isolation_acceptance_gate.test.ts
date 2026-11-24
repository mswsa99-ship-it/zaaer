import { describe, expect, it } from "vitest";
import { mkdtempSync, writeFileSync, chmodSync, rmSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";

describe("plan2.11 acceptance blocker", () => {
  it("fails closed with no fixture, database or network command", () => {
    const dir = mkdtempSync(join(tmpdir(), "roomai-isolation-blocker-"));
    try {
      for (const cmd of ["psql", "node", "npm", "curl", "createdb", "dropdb"]) {
        const file = join(dir, cmd);
        writeFileSync(file, '#!/bin/bash\necho "UNSAFE COMMAND INVOKED" >&2\nexit 99\n');
        chmodSync(file, 0o755);
      }
      const r = spawnSync("/bin/bash", [resolve("tests/isolation/acceptance-gate.sh")], { env: { PATH: dir }, encoding: "utf8" });
      expect(r.status).toBe(1);
      expect(r.stdout).toContain("ISOLATION ACCEPTANCE: INCOMPLETE");
      expect(r.stdout).toContain("not matrix acceptance");
      expect(r.stderr).toBe("");
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });
  it("is listed as not run in the verify script, never as a passing or required-green gate", () => {
    const verify = readFileSync("scripts/verify.sh", "utf8");
    const ci = readFileSync(".github/workflows/verify.yml", "utf8");
    expect(verify).toContain("run_gate isolation-scoped P0 SKIP_SQL bash tests/isolation/scoped-release-gate.sh");
    expect(verify).toContain('record "isolation-matrix" "report" "SKIPPED (full matrix INCOMPLETE, not PASS)"');
    expect(verify).not.toMatch(/run_gate isolation(?!-scoped)/);
    expect(ci).toContain("run: npm run verify");
    expect(ci).not.toContain("continue-on-error");
  });
});
