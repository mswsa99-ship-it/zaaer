#!/usr/bin/env node
/**
 * Plan 7.8 — the served version must match the published commit.
 *
 *   node scripts/build-version.mjs write  [dist-dir]
 *   node scripts/build-version.mjs verify <base-url> <expected-commit>
 *
 * write  stamps the build: dist/version.json = { name, version, commit, built_at }. The version comes from
 *        package.json and the commit from GITHUB_SHA, falling back to `git rev-parse HEAD` — never a hardcoded
 *        string. Run it after `vite build` and before the artifact is uploaded/deployed.
 * verify fetches <base-url>/version.json from the DEPLOYED site and fails unless its commit is the expected
 *        one, so a stale or half-published deploy fails the post-deploy step instead of passing silently.
 *
 * Read-only against the network; the only file it writes is version.json inside the build output.
 */
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

const SHA = /^[0-9a-f]{40}$/;

function fail(message) {
  console.error(`FAIL ${message}`);
  if (process.env.GITHUB_ACTIONS) console.error(`::error title=build-version::${message}`);
  process.exit(1);
}

/** The commit this build was made from: the workflow's checkout first, then the local clone. */
function resolveCommit() {
  const fromEnv = (process.env.GITHUB_SHA ?? "").trim().toLowerCase();
  if (SHA.test(fromEnv)) return fromEnv;
  try {
    const fromGit = execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim().toLowerCase();
    if (SHA.test(fromGit)) return fromGit;
  } catch { /* not a clone / no git */ }
  fail("no commit source: set GITHUB_SHA or run inside a git clone — the version must come from the real build commit");
}

function writeVersion(distDir) {
  const dir = resolve(distDir);
  if (!existsSync(join(dir, "index.html"))) fail(`${distDir} has no index.html — run this after the build, on the build output`);
  const pkg = JSON.parse(readFileSync(join(process.cwd(), "package.json"), "utf8"));
  if (typeof pkg.version !== "string" || !pkg.version) fail("package.json has no version");
  const meta = { name: pkg.name ?? "", version: pkg.version, commit: resolveCommit(), built_at: new Date().toISOString() };
  writeFileSync(join(dir, "version.json"), JSON.stringify(meta, null, 2) + "\n");
  console.log(`PASS version.json written: ${meta.version} @ ${meta.commit}`);
}

async function verify(baseUrl, expected) {
  if (!baseUrl) fail("verify needs the deployed base URL");
  const want = (expected ?? "").trim().toLowerCase();
  if (!SHA.test(want)) fail(`verify needs the expected commit (40 hex), got: ${expected ?? "∅"}`);
  const url = `${baseUrl.replace(/\/+$/, "")}/version.json?check=${Date.now()}`;
  let body;
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(15_000), headers: { accept: "application/json" } });
    if (!res.ok) fail(`version.json → HTTP ${res.status} at ${baseUrl}`);
    body = await res.json();
  } catch (e) {
    fail(`version.json unreadable at ${baseUrl}: ${e?.message ?? e}`);
  }
  const got = typeof body?.commit === "string" ? body.commit.toLowerCase() : "";
  if (!SHA.test(got)) fail(`version.json at ${baseUrl} has no valid commit (got: ${JSON.stringify(body?.commit ?? null)})`);
  if (got !== want) fail(`served commit ${got} ≠ published commit ${want} at ${baseUrl} — the deploy is stale or incomplete`);
  console.log(`PASS served version ${body.version ?? "?"} matches published commit ${want}`);
}

const [cmd, ...args] = process.argv.slice(2);
if (cmd === "write") writeVersion(args[0] ?? "dist");
else if (cmd === "verify") await verify(args[0], args[1]);
else fail("usage: build-version.mjs write [dist-dir] | verify <base-url> <expected-commit>");
