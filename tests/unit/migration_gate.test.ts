import { describe, it, expect } from "vitest";
import { readFileSync, mkdtempSync, writeFileSync, chmodSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
const root = new URL("../..", import.meta.url).pathname;
function fakeRun(body: string, fail: boolean) {
 const d = mkdtempSync(join(tmpdir(), "sql-gate-"));
 try {
  const executable = join(d,"psql");
  writeFileSync(executable, fail ? "#!/bin/bash\necho ERROR: deliberate-gate-negative-control >&2\nexit 17\n" : "#!/bin/bash\necho NOTICE: harmless-test-output\nexit 0\n");
  chmodSync(executable,0o755);
  return spawnSync("bash",["-c",`set -euo pipefail\n${body}`],{env:{...process.env,PATH:`${d}:${process.env.PATH}`},encoding:"utf8"}).status;
 } finally { rmSync(d,{recursive:true,force:true}); }
}
describe("migration gate error propagation",()=>{
 it("SQL suite rejects an apply failure even with notice filtering",()=>{
  const s=readFileSync(join(root,"tests/sql/run.sh"),"utf8");
  const line=s.split("\n").find(l=>l.includes('psql -d "$DB" -v ON_ERROR_STOP=1 -q -f'))!;
  expect(fakeRun(`DB=x; f=x; ${line}`,true)).not.toBe(0);
  expect(fakeRun(`DB=x; f=x; ${line}`,false)).toBe(0);
 });
 it("migration drill rejects failed apply and uses fail-fast restore",()=>{
  const s=readFileSync(join(root,"scripts/migration-check.sh"),"utf8");
  const apply=s.split("\n").find(l=>l.startsWith("apply()"))!;
  expect(fakeRun(`${apply}\napply x x`,true)).not.toBe(0);
  expect(fakeRun(`${apply}\napply x x`,false)).toBe(0);
  expect(s).toMatch(/pg_restore .*--exit-on-error/);
  expect(s).not.toMatch(/pg_restore .*\|\| true/);
 });
});
