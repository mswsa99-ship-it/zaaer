/**
 * Hotels and branches (plan item 2.1): supabase/tenancy.json classifies every table once — platform (the hotels'
 * registry), hotel (one hotel's rows) or branch (one branch's rows) — and says, for a table that does not yet carry
 * its hotel or branch in the row, which parent it comes from today and which columns item 2.2 adds (TN01–TN05).
 * A new table in a migration without a line here fails TN01.
 */
import { describe, it, expect } from "vitest";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

const ROOT = join(__dirname, "..", "..");
const sql = readdirSync(join(ROOT, "supabase/migrations")).filter((f) => f.endsWith(".sql")).sort()
  .map((f) => readFileSync(join(ROOT, "supabase/migrations", f), "utf8")).join("\n");
const created = new Set([...sql.matchAll(/create\s+table\s+(?:if\s+not\s+exists\s+)?(?:public\.)?([a-z_]+)/gi)].map((m) => m[1].toLowerCase()));
const dropped = new Set([...sql.matchAll(/drop\s+table\s+(?:if\s+exists\s+)?(?:public\.)?([a-z_]+)/gi)].map((m) => m[1].toLowerCase()));
const tables = [...created].filter((t) => !dropped.has(t)).sort();

type Entry = { scope: "platform" | "hotel" | "branch"; via?: string; adds?: string[]; note?: string };
const doc = JSON.parse(readFileSync(join(ROOT, "supabase/tenancy.json"), "utf8")) as { rule: string; tables: Record<string, Entry> };
const T = doc.tables;
const RANK = { platform: 0, hotel: 1, branch: 2 } as const;

/** the text between the brackets of «create table <t> ( … )», brackets inside counted */
function createBody(table: string): string | null {
  const m = new RegExp(`create\\s+table\\s+(?:if\\s+not\\s+exists\\s+)?(?:public\\.)?${table}\\s*\\(`, "i").exec(sql);
  if (!m) return null;
  let depth = 1, i = m.index + m[0].length;
  const start = i;
  for (; i < sql.length && depth > 0; i++) { if (sql[i] === "(") depth++; else if (sql[i] === ")") depth--; }
  return sql.slice(start, i - 1);
}
/** a column a migration gives the table: in its create table, or by alter table … add column */
function hasColumn(table: string, col: string): boolean {
  const body = createBody(table);
  if (body && new RegExp(`(^|[\\s,(])${col}\\s`, "m").test(body)) return true;
  return new RegExp(`alter\\s+table\\s+(?:if\\s+exists\\s+)?(?:only\\s+)?(?:public\\.)?${table}\\b[^;]*add\\s+column\\s+(?:if\\s+not\\s+exists\\s+)?${col}\\b`, "i").test(sql);
}

describe("TN — every table belongs to the platform, a hotel or a branch", () => {
  it("TN01 every table a migration creates (and none drops) is classified once, and nothing else is", () => {
    expect(Object.keys(T).sort()).toEqual(tables);
  });

  it("TN02 the three scopes only, and platform tables are explicitly bounded", () => {
    for (const [t, e] of Object.entries(T)) expect(["platform", "hotel", "branch"], t).toContain(e.scope);
    expect(Object.entries(T).filter(([, e]) => e.scope === "platform").map(([t]) => t).sort()).toEqual(["backup_runs","organizations","permission_page_map","platform_events","platform_operators","platform_support_grants"]);
  });

  it("TN03 a parent named in «via» is classified, and its scope is the same or wider", () => {
    for (const [t, e] of Object.entries(T)) {
      if (!e.via) continue;
      expect(T[e.via], `${t} via ${e.via}`).toBeDefined();
      expect(RANK[T[e.via].scope], `${t} via ${e.via}`).toBeLessThanOrEqual(RANK[e.scope]);
    }
  });

  it("TN04 «adds» is exactly what the scope needs and the table does not have yet", () => {
    for (const [t, e] of Object.entries(T)) {
      const need: string[] = [];
      if (e.scope !== "platform" && !hasColumn(t, "organization_id")) need.push("organization_id");
      if (e.scope === "branch" && !hasColumn(t, "branch_id")) need.push("branch_id");
      expect(e.adds ?? [], t).toEqual(need);
    }
  });

  it("TN06 the SQL tests' list of hotel tables is this file's", () => {
    const tests = readFileSync(join(ROOT, "tests/sql/tenancy_tests.sql"), "utf8");
    const block = /insert into tn_hotel_tables values([\s\S]*?);/.exec(tests)![1];
    const listed = [...block.matchAll(/\('([a-z_]+)'\)/g)].map((m) => m[1]).sort();
    expect(listed).toEqual(Object.entries(T).filter(([, e]) => e.scope === "hotel").map(([t]) => t).sort());
    const kids = /insert into tn_children values([\s\S]*?);/.exec(tests)![1];
    const pairs = [...kids.matchAll(/\('([a-z_]+)','([a-z_]+)','([a-z_]+)'\)/g)].map((m) => `${m[1]}<${m[2]}`).sort();
    expect(pairs).toEqual(Object.entries(T).filter(([, e]) => e.via && e.via !== "branches").map(([t, e]) => `${t}<${e.via}`).sort());
  });

  it("TN05 a table with no hotel column and no parent to take it from is one of the guest's three, each with its reason", () => {
    const orphans = Object.entries(T).filter(([, e]) => e.adds?.includes("organization_id") && !e.via).map(([t]) => t);
    const reasoned = orphans.filter((t) => (T[t].note ?? "").length > 20);
    expect(orphans.filter((t) => !t.startsWith("guest_") && !hasColumn(t, "branch_id"))).toEqual([]);
    expect(orphans.filter((t) => t.startsWith("guest_"))).toEqual(reasoned.filter((t) => t.startsWith("guest_")));
  });
});
