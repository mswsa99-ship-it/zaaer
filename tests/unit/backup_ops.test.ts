/**
 * Item 7.1 — backup operations that need no database: retention, remote-copy verification, restore preflight.
 * Local synthetic files only. pg_restore/psql are stubbed on PATH; gpg is real. No secrets, no network.
 */
import { describe, it, expect, beforeAll } from "vitest";
import { mkdtempSync, mkdirSync, writeFileSync, existsSync, chmodSync, readFileSync, copyFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync, execFileSync } from "node:child_process";

const ROOT = join(__dirname, "..", "..");
const sh = (script: string, args: string[], env: Record<string, string>) =>
  spawnSync("bash", [join(ROOT, "scripts/backup", script), ...args], { env: { ...process.env, ...env }, encoding: "utf8", cwd: ROOT });
const hasGpg = spawnSync("gpg", ["--version"]).status === 0;
const d = hasGpg ? describe : describe.skip;

function tmp() { return mkdtempSync(join(tmpdir(), "bk-")); }
function archives(dir: string, names: string[], latestOk = true) {
  for (const n of names) { writeFileSync(join(dir, n), "x"); writeFileSync(join(dir, n + ".sha256"), "x"); }
  writeFileSync(join(dir, "latest.json"), latestOk ? '{"status": "success"}' : '{"status": "failed"}');
}

describe("retention (prune.sh)", () => {
  const names = [
    "backup-20261120-021500-scheduled.tar.gpg", "backup-20261113-021500-scheduled.tar.gpg", "backup-20261106-021500-scheduled.tar.gpg",
    "backup-20261101-021500-scheduled.tar.gpg", "backup-20260928-021500-scheduled.tar.gpg", "backup-20260921-021500-scheduled.tar.gpg",
    "backup-20260915-031500-manual.tar.gpg", "backup-20250101-021500-scheduled.tar.gpg",
  ];
  it("BK01 dry run deletes nothing and names what it would remove", () => {
    const dir = tmp(); archives(dir, names);
    const r = sh("prune.sh", [], { BACKUP_DEST_DIR: dir, BACKUP_PRUNE_NOW: "20261124", BACKUP_KEEP_MONTHLY: "1", BACKUP_KEEP_MIN: "2" });
    expect(r.status).toBe(0);
    expect(r.stderr).toContain("would prune backup-20250101-021500-scheduled.tar.gpg");
    expect(existsSync(join(dir, names[7]))).toBe(true);
  });
  it("BK02 apply keeps the daily window, the newest per month up to the cap, and removes the sidecar too", () => {
    const dir = tmp(); archives(dir, names);
    const r = sh("prune.sh", [], { BACKUP_DEST_DIR: dir, BACKUP_PRUNE_NOW: "20261124", BACKUP_KEEP_MONTHLY: "1", BACKUP_KEEP_MIN: "2", BACKUP_PRUNE_APPLY: "1" });
    expect(r.status).toBe(0);
    for (const k of names.slice(0, 4)) expect(existsSync(join(dir, k))).toBe(true); // within 35 days
    expect(existsSync(join(dir, names[4]))).toBe(true); // newest of Sep (the one monthly slot)
    expect(existsSync(join(dir, names[5]))).toBe(false); // older Sep, not the newest of its month
    expect(existsSync(join(dir, names[7]))).toBe(false);
    expect(existsSync(join(dir, names[7] + ".sha256"))).toBe(false);
    expect(existsSync(join(dir, "latest.json"))).toBe(true);
  });
  it("BK03 never prunes without a proven last backup, and never below the minimum count", () => {
    const dir = tmp(); archives(dir, names, false);
    const r = sh("prune.sh", [], { BACKUP_DEST_DIR: dir, BACKUP_PRUNE_APPLY: "1" });
    expect(r.status).not.toBe(0);
    expect(existsSync(join(dir, names[7]))).toBe(true);
    const dir2 = tmp(); archives(dir2, names);
    sh("prune.sh", [], { BACKUP_DEST_DIR: dir2, BACKUP_PRUNE_NOW: "20261124", BACKUP_KEEP_MONTHLY: "0", BACKUP_KEEP_MIN: "8", BACKUP_PRUNE_APPLY: "1" });
    for (const k of names) expect(existsSync(join(dir2, k))).toBe(true);
  });
  it("BK04 files that do not match the archive naming are never touched", () => {
    const dir = tmp(); archives(dir, names); writeFileSync(join(dir, "notes.txt"), "keep"); writeFileSync(join(dir, "backup-evil.tar.gpg"), "keep");
    sh("prune.sh", [], { BACKUP_DEST_DIR: dir, BACKUP_PRUNE_NOW: "20261124", BACKUP_KEEP_MONTHLY: "0", BACKUP_KEEP_MIN: "1", BACKUP_PRUNE_APPLY: "1" });
    expect(existsSync(join(dir, "notes.txt"))).toBe(true);
    expect(existsSync(join(dir, "backup-evil.tar.gpg"))).toBe(true);
  });
});

d("remote copy verification (verify-remote.sh)", () => {
  const NAME = "backup-20261124-021500-scheduled.tar.gpg";
  let base: string, pass: string, bin: string, dest: string;
  function build(dir: string, tamperSidecar = false) {
    const w = tmp();
    writeFileSync(join(w, "db.dump"), "synthetic dump"); writeFileSync(join(w, "manifest.tsv"), "t\t1\tabc\n");
    execFileSync("tar", ["-C", w, "-cf", join(w, "bundle.tar"), "db.dump", "manifest.tsv"]);
    const sha = execFileSync("sha256sum", [join(w, "bundle.tar")], { encoding: "utf8" }).split(" ")[0];
    writeFileSync(join(w, "bundle.sha256"), `${sha}  ${NAME}\n`);
    execFileSync("tar", ["-C", w, "-cf", join(w, "final.tar"), "bundle.tar", "bundle.sha256"]);
    execFileSync("gpg", ["--batch", "--yes", "--quiet", "--symmetric", "--cipher-algo", "AES256", "--passphrase-file", pass, "--output", join(dir, NAME), join(w, "final.tar")]);
    writeFileSync(join(dir, NAME + ".sha256"), `${tamperSidecar ? "0".repeat(64) : sha}  ${NAME}\n`);
  }
  beforeAll(() => {
    base = tmp(); pass = join(base, "pass"); writeFileSync(pass, "synthetic-test-phrase", { mode: 0o600 }); chmodSync(pass, 0o600);
    // the passphrase file must live outside the repo: tmpdir is outside
    bin = join(base, "bin"); mkdirSync(bin);
    writeFileSync(join(bin, "pg_restore"), '#!/bin/sh\nif [ "$1" = "--list" ]; then echo "; toc"; echo "1; 1 1 EXTENSION - pgcrypto"; exit 0; fi\nexit 0\n', { mode: 0o755 });
    writeFileSync(join(bin, "pg_dump"), "#!/bin/sh\n", { mode: 0o755 });
    writeFileSync(join(bin, "psql"), "#!/bin/sh\necho 1\n", { mode: 0o755 });
    dest = join(base, "remote"); mkdirSync(dest);
  });
  const env = (hook: string, local?: string) => ({ PATH: `${join(base, "bin")}:${process.env.PATH}`, BACKUP_PASSPHRASE_FILE: pass, BACKUP_FETCH_HOOK: hook, ...(local ? { BACKUP_DEST_DIR: local } : {}) });
  const hook = (remoteDir: string) => {
    const h = join(tmp(), "fetch.sh");
    writeFileSync(h, `#!/bin/sh\ncp "${remoteDir}/$1" "$2/$1" && cp "${remoteDir}/$1.sha256" "$2/$1.sha256"\n`, { mode: 0o755 });
    return h;
  };
  it("BK05 a good remote copy passes: downloaded, decrypted, hash and TOC checked", () => {
    const remote = tmp(); build(remote);
    const r = sh("verify-remote.sh", [NAME], env(hook(remote)));
    expect(r.stderr).toContain("remote copy verified");
    expect(r.status).toBe(0);
  });
  it("BK06 a missing remote copy, a corrupt archive and a swapped sidecar are each refused", () => {
    const empty = tmp();
    expect(sh("verify-remote.sh", [NAME], env(hook(empty))).status).not.toBe(0);
    const bad = tmp(); build(bad); writeFileSync(join(bad, NAME), Buffer.concat([readFileSync(join(bad, NAME)).subarray(0, 40), Buffer.from("corrupt")]));
    expect(sh("verify-remote.sh", [NAME], env(hook(bad))).status).not.toBe(0);
    const swapped = tmp(); build(swapped, true);
    const r = sh("verify-remote.sh", [NAME], env(hook(swapped)));
    expect(r.status).not.toBe(0);
    expect(r.stderr).toContain("disagree");
  });
  it("BK07 a remote copy that differs from the local original is refused", () => {
    const remote = tmp(), local = tmp(); build(remote); build(local);
    const r = sh("verify-remote.sh", [NAME], env(hook(remote), local));
    expect(r.status).not.toBe(0); // two separate encryptions of the same bundle differ in bytes (random salt)
    expect(r.stderr).toContain("differs");
    copyFileSync(join(remote, NAME), join(local, NAME)); copyFileSync(join(remote, NAME + ".sha256"), join(local, NAME + ".sha256"));
    expect(sh("verify-remote.sh", [NAME], env(hook(remote), local)).status).toBe(0);
  });
  it("BK08 a path-traversal archive name is refused before any download", () => {
    const r = sh("verify-remote.sh", ["../../etc/passwd"], env(hook(tmp())));
    expect(r.status).not.toBe(0);
    expect(r.stderr).toContain("invalid archive name");
  });
});

describe("restore preflight (restore-preflight.sh)", () => {
  function stubs(available: string) {
    const bin = tmp();
    writeFileSync(join(bin, "pg_restore"), '#!/bin/sh\necho "; toc"; echo "10; 1 2 EXTENSION - pgcrypto owner"; echo "11; 1 3 EXTENSION - pg_trgm owner"; echo "12; 1 4 TABLE public t owner"\n', { mode: 0o755 });
    writeFileSync(join(bin, "psql"), `#!/bin/sh\nfor a in "$@"; do :; done\ncase " ${available} " in *" $(echo "$@" | sed -n 's/.*-v e=\\([^ ]*\\).*/\\1/p') "*) echo 1;; *) echo 0;; esac\n`, { mode: 0o755 });
    return bin;
  }
  it("BK09 passes when the target offers every extension, fails and names the gap when not", () => {
    const f = join(tmp(), "db.dump"); writeFileSync(f, "x");
    const ok = sh("restore-preflight.sh", [f], { PATH: `${stubs("pgcrypto pg_trgm")}:${process.env.PATH}`, BACKUP_TARGET_PGURI: "postgresql://synthetic/x" });
    expect(ok.status).toBe(0);
    const bad = sh("restore-preflight.sh", [f], { PATH: `${stubs("pgcrypto")}:${process.env.PATH}`, BACKUP_TARGET_PGURI: "postgresql://synthetic/x" });
    expect(bad.status).not.toBe(0);
    expect(bad.stderr).toContain("pg_trgm");
  });
});

describe("contracts", () => {
  it("BK10 restore runs the preflight, and no backup script embeds a secret value or URI", () => {
    expect(readFileSync(join(ROOT, "scripts/backup/restore.sh"), "utf8")).toContain("restore-preflight.sh");
    for (const f of ["backup.sh", "restore.sh", "prune.sh", "verify-remote.sh", "drive-hook.example.sh"]) {
      const s = readFileSync(join(ROOT, "scripts/backup", f), "utf8");
      expect(s).not.toMatch(/postgres(ql)?:\/\/[^$"\s]*:[^$"\s@]+@/);
      expect(s).not.toMatch(/--passphrase\s+[^-]/);
    }
  });
});

describe("proposed backup workflow readiness (inactive; local checks only)", () => {
  const WF = join(ROOT, ".github/workflows/backup.yml.proposed");
  const text = existsSync(WF) ? readFileSync(WF, "utf8") : "";
  const live = text.split("\n").filter((l) => !/^\s*#/.test(l)).join("\n"); // comments removed
  const idx = (needle: string) => live.indexOf(needle);
  it("BK11 the workflow is inactive: not loadable by name, no live schedule, no push or PR trigger, gated by a variable", () => {
    expect(text.length).toBeGreaterThan(0);
    expect(existsSync(join(ROOT, ".github/workflows/backup.yml"))).toBe(false);
    expect(live).not.toMatch(/^\s*schedule:/m);
    expect(live).not.toMatch(/^\s*-\s*cron:/m);
    expect(live).not.toMatch(/^\s*(push|pull_request|pull_request_target):/m);
    expect(live).toContain("vars.BACKUP_SCHEDULE == 'enabled'");
  });
  it("BK12 least privilege and pinned runner; no unpinned moving refs", () => {
    expect(live).toMatch(/permissions:\s*\n\s*contents: read/);
    expect(live).not.toMatch(/runs-on:\s*ubuntu-latest/);
    expect(live).not.toMatch(/@(master|main)\b/);
  });
  it("BK13 secrets reach steps only through env, never inline in a run script or echoed", () => {
    for (const block of live.split(/\n\s*- (?:name|uses):/).slice(1)) {
      const run = /\n\s*run:\s*([\s\S]*?)(?=\n\s*(?:env|if|with):|$)/.exec(block)?.[1] ?? "";
      expect(run).not.toContain("secrets.");
    }
    expect(live).not.toMatch(/echo[^\n]*\$\{?P\b/);
    expect(live).not.toMatch(/\bset -x\b/);
    expect(live).toContain("set +x");
  });
  it("BK14 order is backup, then downloaded-copy verification, then dry-run retention; deletion is never wired", () => {
    const a = idx("scripts/backup/backup.sh"), b = idx("scripts/backup/verify-remote.sh"), c = idx("scripts/backup/prune.sh");
    expect(a).toBeGreaterThan(-1); expect(b).toBeGreaterThan(a); expect(c).toBeGreaterThan(b);
    expect(live).not.toContain("BACKUP_PRUNE_APPLY");
  });
  it("BK15 cleanup always runs and removes the passphrase file and local archives; empty secret fails closed", () => {
    expect(live).toMatch(/if: always\(\)\s*\n\s*run: rm -rf "\$BACKUP_PASSPHRASE_FILE" "\$BACKUP_DEST_DIR"/);
    expect(live).toContain("secret is empty");
    expect(live.indexOf("umask 077")).toBeLessThan(live.indexOf('> "$BACKUP_PASSPHRASE_FILE"'));
  });
  it("BK16 unfinished prerequisites fail the job instead of passing silently: unpinned PG client step exits non-zero", () => {
    expect(live).toMatch(/not pinned[^\n]*exit 1/);
  });
  it("BK17 the Drive hook the workflow names is an operator-installed file that is not in the repo, so activation fails until it exists", () => {
    expect(live).toContain("ops/backup-drive-hook.sh");
    expect(existsSync(join(ROOT, "ops/backup-drive-hook.sh"))).toBe(false);
  });
});

describe("isolated PG harness contract (pg-harness.sh)", () => {
  const h = readFileSync(join(ROOT, "scripts/backup/pg-harness.sh"), "utf8");
  it("BK18 the harness is local-only, skips loudly without a server, and never reads a production URI", () => {
    expect(h).toContain("listen_addresses=''");
    expect(h).not.toContain("ADMIN_SOCKET"); // no existing-server mode
    expect(h).toContain("show data_directory"); // proves the connected server is the harness cluster before any DROP/CREATE
    expect(h).toContain("database name collision");
    expect(h).toContain("unset PGHOST");
    expect(h).toMatch(/cleanup\(\) \{[^\n]*rm -rf "\$T"[^\n]*\}/);
    expect(h).not.toMatch(/rm -rf[^\n]*\$EV/); // evidence is kept
    expect(h).not.toMatch(/migration[^\n]*\|\| true/); // migration errors fail closed
    expect(h).not.toMatch(/PRODUCTION_DB_URI|secrets\.|rclone|curl |wget /);
    const r = spawnSync("bash", [join(ROOT, "scripts/backup/pg-harness.sh")], { env: { PATH: "/usr/bin:/bin", HOME: tmpdir() }, encoding: "utf8", cwd: ROOT });
    if (spawnSync("sh", ["-c", "command -v initdb || command -v pg_ctl"], { env: { PATH: "/usr/bin:/bin" } }).status !== 0) {
      expect(r.status).toBe(3); // no server binaries: an explicit skip code, never a pass
      expect(r.stderr).toContain("SKIP all");
    }
  });
  it("BK19 every scenario H01-H11 is present and the run fails on any failure or skip", () => {
    for (const k of ["H01a", "H02", "H03", "H04", "H05a", "H06", "H07", "H08", "H09", "H10", "H11a", "H11b"]) expect(h).toContain(k);
    expect(h).toContain('[ "$FAILS" = 0 ] && [ "$SKIPS" = 0 ]');
  });
});


describe("PG harness inherited effects and writer proof", () => {
  const h = readFileSync(join(ROOT, "scripts/backup/pg-harness.sh"), "utf8");
  it("BK20 clears all inherited BACKUP variables except its evidence location", () => {
    expect(h).toContain('for inherited in ${!BACKUP_@}');
    expect(h).toContain('unset "$inherited"');
  });
  it("BK21 requires successful writes after the exported snapshot and proves restored snapshot differs from final source", () => {
    expect(h).toContain('writer-after-snapshot');
    expect(h).toContain('WRITER_STATUS');
    expect(h).toContain('RESTORED_COUNT');
    expect(h).toContain('FINAL_COUNT');
    expect(h).toContain('H06b');
  });
});
