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

  it("catalog lookups in migrations name the schema (a same-named table elsewhere must not answer for public)", () => {
    // The hosted project keeps a leftover schema with tables named like ours: 0033 looked up its grant condition in
    // information_schema by table name alone, found the leftover «reservations», and skipped the grant (fixed by 0035).
    // These four ran in production before the rule: 0035 re-decides the grants of 0011 and 0033 on public itself, and
    // the policy lookups of 0027 and 0028 found their own policies (the production schema fingerprint matches).
    const grandfathered = new Set([
      "20261022130000_0011_reservation_parity.sql", "20261024234000_0027_client_errors.sql",
      "20261025010000_0028_money_core.sql", "20261025051000_0033_stay_cycle.sql",
    ]);
    const offenders: string[] = [];
    for (const f of readdirSync(join(ROOT, "supabase/migrations")).filter((x) => x.endsWith(".sql") && !grandfathered.has(x)).sort()) {
      const sql = read(join("supabase/migrations", f)).replace(/--.*$/gm, "");
      for (const s of sql.split(";")) {
        if (/\binformation_schema\.\w+/i.test(s) && /\btable_name\s*=/i.test(s) && !/\btable_schema\s*=/i.test(s)) offenders.push(`${f}: information_schema by table_name without table_schema`);
        if (/\bpg_(?:policies|tables|views|indexes)\b/i.test(s) && /\btablename\s*=/i.test(s) && !/\bschemaname\s*=/i.test(s)) offenders.push(`${f}: pg_policies/pg_tables by tablename without schemaname`);
        if (/\bpg_class\b/i.test(s) && /\brelname\s*=/i.test(s) && !/\brelnamespace\b/i.test(s)) offenders.push(`${f}: pg_class by relname without relnamespace`);
      }
    }
    expect(offenders).toEqual([]);
  });

  it("the owner's paste file carries 0022, 0031, 0034, 0039 and 0041 verbatim, each recorded in the history, in one transaction", () => {
    // These hold DELETE or DROP, or spell the word (the purge functions; 0039's old index; 0041's retired report signatures
    // and the «حذف تعريف» labels), so the owner runs them from the SQL Editor (STAGING.md §0-ب)
    const paste = read("supabase/paste/owner-paste-0022-0031-0034-0039-0041.sql");
    for (const f of ["20261023091000_0022_data_purge.sql", "20261025040000_0031_purge_cascades.sql", "20261025052000_0034_stay_cascades.sql", "20261027020000_0039_guest_cascades.sql", "20261028020000_0041_phase6_paste.sql"]) {
      expect(paste.includes(read(join("supabase/migrations", f))), `${f} is not in the paste file as it is in supabase/migrations`).toBe(true);
      const [version, ...rest] = f.replace(/\.sql$/, "").split("_");
      expect(paste).toContain(`values ('${version}', '${rest.join("_")}') on conflict (version) do nothing;`);
    }
    expect(paste.match(/^begin;$/gm)?.length).toBe(1);
    expect(paste.match(/^commit;$/gm)?.length).toBe(1);
  });

  it("the owner's paste file for the permissions matrix carries 0044 verbatim, recorded in the history, in one transaction", () => {
    // 0044 spells the word in the «حذف تعريف» labels it moves into their own functions (STAGING.md §0-ب)
    const paste = read("supabase/paste/owner-paste-0044.sql");
    expect(paste.includes(read("supabase/migrations/20261029030000_0044_permissions_paste.sql"))).toBe(true);
    expect(paste).toContain("values ('20261029030000', '0044_permissions_paste') on conflict (version) do nothing;");
    expect(paste.match(/^begin;$/gm)?.length).toBe(1);
    expect(paste.match(/^commit;$/gm)?.length).toBe(1);
  });

  it("no native confirm()/alert()/prompt() dialogs in the UI (embedded viewers swallow them)", () => {
    const stripComments = (src: string) => src.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:])\/\/.*$/gm, "$1");
    const offenders = uiFiles.filter((p) => /(^|[^.\w])(window\.)?(confirm|alert|prompt)\(/.test(stripComments(read(p))));
    expect(offenders).toEqual([]);
  });
});
