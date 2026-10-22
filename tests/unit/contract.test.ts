/**
 * Contract drift guard. The UI, the SQL migrations and the in-browser demo backend must agree on
 * the names of RPCs, edge functions and tables. A rename in one place without the others is the
 * most common way a "small refactor" breaks a screen that nobody clicked during review.
 */
import { describe, it, expect } from "vitest";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

const ROOT = join(__dirname, "..", "..");
const read = (p: string) => readFileSync(join(ROOT, p), "utf8");
const walk = (dir: string, out: string[] = []): string[] => {
  for (const e of readdirSync(join(ROOT, dir), { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else if (/\.(ts|tsx)$/.test(e.name)) out.push(p);
  }
  return out;
};

const uiFiles = walk("src").filter((p) => !p.startsWith(join("src", "demo")));
const uiSource = uiFiles.map(read).join("\n");
const demoSource = readdirSync(join(ROOT, "src/demo")).filter((f) => f.endsWith(".ts")).map((f) => read(join("src/demo", f))).join("\n");
const sqlSource = readdirSync(join(ROOT, "supabase/migrations")).filter((f) => f.endsWith(".sql")).sort().map((f) => read(join("supabase/migrations", f))).join("\n");
const edgeFunctions = readdirSync(join(ROOT, "supabase/functions"), { withFileTypes: true }).filter((d) => d.isDirectory() && !d.name.startsWith("_")).map((d) => d.name);

const uniq = (xs: string[]) => [...new Set(xs)].sort();
// supabase.rpc("fn_x") and the api.ts helper rpc<T>("fn_x", …)
const rpcCallsInUi = uniq([...uiSource.matchAll(/\brpc(?:<[^>]*>)?\(\s*["'`](fn_[a-z0-9_]+)["'`]/g)].map((m) => m[1]));
const rpcDefinedInSql = new Set([...sqlSource.matchAll(/create\s+(?:or\s+replace\s+)?function\s+(?:public\.)?(fn_[a-z0-9_]+)\s*\(/gi)].map((m) => m[1].toLowerCase()));
const rpcDefinedInDemo = new Set([...demoSource.matchAll(/^\s{2,6}(fn_[a-z0-9_]+)\s*[:(]/gm)].map((m) => m[1]));
const invokesInUi = uniq([...uiSource.matchAll(/functions\.invoke(?:<[^>]*>)?\(\s*["'`]([a-z0-9-]+)["'`]/g)].map((m) => m[1]));
const tablesInUi = uniq([...uiSource.matchAll(/\.from\(\s*["'`]([a-z_]+)["'`]/g)].map((m) => m[1]));
const tablesInSql = new Set([...sqlSource.matchAll(/create\s+table\s+(?:if\s+not\s+exists\s+)?(?:public\.)?([a-z_]+)/gi)].map((m) => m[1].toLowerCase()).concat([...sqlSource.matchAll(/create\s+(?:or\s+replace\s+)?view\s+(?:public\.)?([a-z_]+)/gi)].map((m) => m[1].toLowerCase())));

describe("UI ↔ SQL ↔ demo contract", () => {
  it("every RPC the UI calls exists in the migrations", () => {
    const missing = rpcCallsInUi.filter((f) => !rpcDefinedInSql.has(f));
    expect(missing, `RPCs called from src/ but not defined in supabase/migrations: ${missing.join(", ")}`).toEqual([]);
  });

  it("every RPC the UI calls is emulated by the demo backend", () => {
    const missing = rpcCallsInUi.filter((f) => !rpcDefinedInDemo.has(f));
    expect(missing, `RPCs called from src/ but missing in src/demo/client.ts rpcs map: ${missing.join(", ")}`).toEqual([]);
  });

  it("every edge function the UI invokes exists on disk and in the demo", () => {
    for (const name of invokesInUi) {
      expect(edgeFunctions, `supabase/functions/${name} missing`).toContain(name);
      expect(demoSource.includes(`name === "${name}"`), `demo invoke() does not handle "${name}"`).toBe(true);
    }
  });

  it("every table/view the UI reads exists in the migrations", () => {
    const missing = tablesInUi.filter((t) => !tablesInSql.has(t));
    expect(missing, `tables used from src/ but not created in migrations: ${missing.join(", ")}`).toEqual([]);
  });

  it("sanity: the scan actually found things", () => {
    expect(rpcCallsInUi.length).toBeGreaterThan(20);
    expect(tablesInUi.length).toBeGreaterThan(10);
    expect(invokesInUi).toContain("ai-reception");
  });
});

describe("non-negotiable source rules", () => {
  it("no migration or seed contains personal data markers, passwords or private links", () => {
    const seedLike = readdirSync(join(ROOT, "supabase/migrations")).filter((f) => /seed/i.test(f)).map((f) => read(join("supabase/migrations", f))).join("\n") + read("src/demo/data.ts");
    expect(seedLike).not.toMatch(/password\s*[:=]\s*["'][^"']{6,}/i);
    expect(seedLike).not.toMatch(/@gmail\.com|@hotmail\.com|@yahoo\.com/i);
    expect(seedLike).not.toMatch(/https?:\/\/(?:www\.)?zaaer\.co/i);
    // identity numbers are never stored in clear text, not even for demo guests
    expect(seedLike).not.toMatch(/identity_number\s*[:=]\s*["']\d{8,}/);
  });

  it("money never travels as floats in RPC payloads (halalas only)", () => {
    expect(uiSource).not.toMatch(/amount_sar\b/);
    expect(sqlSource).not.toMatch(/amount_halalas\s+(numeric|double|real|float)/i);
  });

  it("no native confirm()/alert()/prompt() dialogs in the UI (embedded viewers swallow them)", () => {
    const stripComments = (src: string) => src.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:])\/\/.*$/gm, "$1");
    const offenders = uiFiles.filter((p) => /(^|[^.\w])(window\.)?(confirm|alert|prompt)\(/.test(stripComments(read(p))));
    expect(offenders).toEqual([]);
  });
});
