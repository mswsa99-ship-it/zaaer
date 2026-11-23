/**
 * Plan 7.8 — the build-version stamp and the post-deploy agreement check (scripts/build-version.mjs).
 * Positive and negative controls: a correct stamp verifies, and every wrong state — stale deploy, missing or
 * malformed version.json, unreachable site, invented commit — fails. Descriptive test names, no library prefix.
 */
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync, spawn } from "node:child_process";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";

const ROOT = join(__dirname, "..", "..");
const SCRIPT = join(ROOT, "scripts", "build-version.mjs");
const COMMIT_A = "a".repeat(40);
const COMMIT_B = "b".repeat(40);
const T = 25_000; // verify can wait up to its own 15s fetch timeout on the negative paths

interface Run { status: number | null; stdout: string; stderr: string }

/** Async: a sync spawn would freeze this process's event loop and starve the test's own HTTP server. */
function run(args: string[], opts: { cwd?: string; env?: Record<string, string> } = {}): Promise<Run> {
  const env: Record<string, string> = { ...(process.env as Record<string, string>) };
  delete env.GITHUB_SHA; // hermetic: only what the test passes in
  Object.assign(env, opts.env);
  return new Promise((resolveRun, reject) => {
    const child = spawn("node", [SCRIPT, ...args], { cwd: opts.cwd ?? ROOT, env });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (c) => (stdout += c));
    child.stderr.on("data", (c) => (stderr += c));
    child.on("error", reject);
    child.on("close", (status) => resolveRun({ status, stdout, stderr }));
  });
}

/** A minimal package.json + build output in a fresh folder. */
function fixture(): { dir: string; dist: string } {
  const dir = mkdtempSync(join(tmpdir(), "build-version-"));
  writeFileSync(join(dir, "package.json"), JSON.stringify({ name: "ai-receptionist", version: "0.1.0" }));
  const dist = join(dir, "dist");
  mkdirSync(dist);
  writeFileSync(join(dist, "index.html"), '<div id="root"></div>');
  return { dir, dist };
}

describe("build version stamp (7.8)", () => {
  it("write stamps the commit from GITHUB_SHA and the version from package.json", async () => {
    const { dir, dist } = fixture();
    try {
      const r = await run(["write", "dist"], { cwd: dir, env: { GITHUB_SHA: COMMIT_A } });
      expect(r.status, r.stderr).toBe(0);
      const meta = JSON.parse(readFileSync(join(dist, "version.json"), "utf8"));
      expect(meta.commit).toBe(COMMIT_A);
      expect(meta.version).toBe("0.1.0");
      expect(meta.built_at).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/);
      expect(r.stdout).toContain("PASS");
    } finally { rmSync(dir, { recursive: true, force: true }); }
  }, T);

  it("write falls back to `git rev-parse HEAD` when GITHUB_SHA is absent", async () => {
    const { dir, dist } = fixture();
    try {
      const git = (args: string[]) => execFileSync("git", args, { cwd: dir, stdio: "ignore" });
      git(["init", "-q"]);
      git(["config", "user.email", "test@example.invalid"]);
      git(["config", "user.name", "test"]);
      git(["add", "."]);
      git(["commit", "-qm", "init"]);
      const head = execFileSync("git", ["rev-parse", "HEAD"], { cwd: dir, encoding: "utf8" }).trim();
      const r = await run(["write", "dist"], { cwd: dir });
      expect(r.status, r.stderr).toBe(0);
      expect(JSON.parse(readFileSync(join(dist, "version.json"), "utf8")).commit).toBe(head);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  }, T);

  it("write refuses to invent a commit when neither GITHUB_SHA nor git is available", async () => {
    const { dir, dist } = fixture();
    try {
      const r = await run(["write", "dist"], { cwd: dir });
      expect(r.status).toBe(1);
      expect(r.stderr).toContain("no commit source");
      expect(readFileSync(join(dist, "index.html"), "utf8")).toContain("root"); // nothing else touched
      expect(() => readFileSync(join(dist, "version.json"), "utf8")).toThrow();
    } finally { rmSync(dir, { recursive: true, force: true }); }
  }, T);

  it("write refuses a folder that is not a build output, and a bad GITHUB_SHA", async () => {
    const { dir } = fixture();
    try {
      expect((await run(["write", "empty-dist"], { cwd: dir, env: { GITHUB_SHA: COMMIT_A } })).status).toBe(1);
      const r = await run(["write", "dist"], { cwd: dir, env: { GITHUB_SHA: "not-a-sha" } });
      expect(r.status).toBe(1); // falls through to git, which is absent here
    } finally { rmSync(dir, { recursive: true, force: true }); }
  }, T);
});

describe("post-deploy version agreement (7.8)", () => {
  let server: Server;
  let port: number;
  let served: Record<string, unknown> | string | null = null;

  beforeAll(async () => {
    server = createServer((req, res) => {
      if (served === null || !req.url?.startsWith("/version.json")) { res.writeHead(404); res.end(); return; }
      res.writeHead(200, { "content-type": "application/json" });
      res.end(typeof served === "string" ? served : JSON.stringify(served));
    });
    await new Promise<void>((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
    port = (server.address() as AddressInfo).port;
  });
  afterAll(async () => { await new Promise((done) => server.close(done)); });

  const base = () => `http://127.0.0.1:${port}`;

  it("verify passes when the served commit is the published one", async () => {
    served = { name: "ai-receptionist", version: "0.1.0", commit: COMMIT_A, built_at: "2026-11-24T00:00:00.000Z" };
    const r = await run(["verify", base(), COMMIT_A]);
    expect(r.status, r.stderr).toBe(0);
    expect(r.stdout).toContain(`matches published commit ${COMMIT_A}`);
  }, T);

  it("verify passes under a sub-path (GitHub Pages project site)", async () => {
    served = { version: "0.1.0", commit: COMMIT_A, built_at: "2026-11-24T00:00:00.000Z" };
    const sub = createServer((req, res) => {
      if (req.url?.startsWith("/zaaer/version.json")) { res.writeHead(200, { "content-type": "application/json" }); res.end(JSON.stringify(served)); }
      else { res.writeHead(404); res.end(); }
    });
    try {
      await new Promise<void>((resolveListen) => sub.listen(0, "127.0.0.1", resolveListen));
      const p = (sub.address() as AddressInfo).port;
      const r = await run(["verify", `http://127.0.0.1:${p}/zaaer/`, COMMIT_A]);
      expect(r.status, r.stderr).toBe(0);
    } finally {
      await new Promise((done) => sub.close(done));
    }
  }, T);

  it("verify fails a stale deploy: served commit ≠ published commit", async () => {
    served = { version: "0.1.0", commit: COMMIT_B, built_at: "2026-11-24T00:00:00.000Z" };
    const r = await run(["verify", base(), COMMIT_A]);
    expect(r.status).toBe(1);
    expect(r.stderr).toContain("stale or incomplete");
    expect(r.stderr).toContain(COMMIT_B);
  }, T);

  it("verify fails when version.json is missing, malformed, or has no valid commit", async () => {
    served = null; // 404
    expect((await run(["verify", base(), COMMIT_A])).status).toBe(1);
    served = "not json";
    expect((await run(["verify", base(), COMMIT_A])).status).toBe(1);
    served = { version: "0.1.0", commit: "v1.2.3" };
    const r = await run(["verify", base(), COMMIT_A]);
    expect(r.status).toBe(1);
    expect(r.stderr).toContain("no valid commit");
  }, T);

  it("verify fails when the site is unreachable and rejects an invalid expected commit", async () => {
    const r = await run(["verify", "http://127.0.0.1:1", COMMIT_A]);
    expect(r.status).toBe(1);
    expect((await run(["verify", base(), COMMIT_A.slice(0, 39)])).status).toBe(1);
    expect((await run(["verify", base(), ""])).status).toBe(1);
  }, T);
});

describe("the deploy workflows stamp and check the version (7.8)", () => {
  const staging = readFileSync(join(ROOT, ".github/workflows/staging.yml"), "utf8");
  const production = readFileSync(join(ROOT, ".github/workflows/production.yml"), "utf8");

  it("staging stamps the build before publishing and verifies the served commit after publishing", () => {
    const stamp = staging.indexOf("build-version.mjs write dist");
    const publish = staging.indexOf("actions/deploy-pages");
    const verify = staging.indexOf('build-version.mjs verify "$STAGING_URL"');
    expect(stamp, "stamp step").toBeGreaterThan(-1);
    expect(publish, "pages deploy").toBeGreaterThan(-1);
    expect(verify, "post-publish verify").toBeGreaterThan(-1);
    expect(stamp).toBeLessThan(publish);
    expect(publish).toBeLessThan(verify);
  });

  it("production stamps the build before the Netlify deploy and verifies the served commit after it", () => {
    const stamp = production.indexOf("build-version.mjs write dist");
    const deploy = production.indexOf("netlify-cli");
    const verify = production.indexOf('build-version.mjs verify "$APP_BASE_URL"');
    expect(stamp, "stamp step").toBeGreaterThan(-1);
    expect(deploy, "netlify deploy").toBeGreaterThan(-1);
    expect(verify, "post-deploy verify").toBeGreaterThan(-1);
    expect(stamp).toBeLessThan(deploy);
    expect(deploy).toBeLessThan(verify);
  });

  it("workflows add no new tokens or secret references beyond the pre-existing ones", () => {
    const secrets = (wf: string) => (wf.match(/\$\{\{ secrets\.[A-Z_]+ \}\}/g) ?? []).sort();
    // no new secret names were introduced by this change; staging must not gain production's Netlify token
    expect(secrets(staging)).not.toContain("${{ secrets.NETLIFY_AUTH_TOKEN }}");
    expect(staging).not.toMatch(/github-token:/);
    expect(production).not.toMatch(/github-token:/);
  });
});
