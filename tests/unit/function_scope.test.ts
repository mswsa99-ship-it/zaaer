/**
 * Functions keep to the hotel and the branch (plan item 2.4): supabase/function-scope.json says the rule and lists,
 * each with its reason, the helpers and the exceptions that tests/sql/function_scope_tests.sql (FS01–FS13) accepts.
 * Here, without a database: the list is well formed (FS20), every function a migration creates is named fn_ — the
 * database checks look at fn_ functions, so another name would pass them unseen (FS21) — and every listed name is a
 * function some migration creates (FS22).
 */
import { describe, it, expect } from "vitest";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

const ROOT = join(__dirname, "..", "..");
const sql = readdirSync(join(ROOT, "supabase/migrations")).filter((f) => f.endsWith(".sql")).sort()
  .map((f) => readFileSync(join(ROOT, "supabase/migrations", f), "utf8")).join("\n");
const created = [...sql.matchAll(/create\s+(?:or\s+replace\s+)?function\s+(?:([a-z_]+)\.)?([a-z_0-9]+)\s*\(/gi)]
  .map((m) => ({ schema: (m[1] ?? "public").toLowerCase(), name: m[2].toLowerCase() }));
const doc = JSON.parse(readFileSync(join(ROOT, "supabase/function-scope.json"), "utf8")) as {
  rule: string; helpers: Record<string, string>; exceptions: Record<string, string>;
};

describe("FS — every function keeps to the hotel and the branch", () => {
  it("FS20 the list says its rule, and every helper and exception carries its reason", () => {
    expect(doc.rule.length).toBeGreaterThan(200);
    expect(Object.keys(doc).sort()).toEqual(["exceptions", "helpers", "rule"]);
    const bad = [
      ...Object.entries(doc.helpers).filter(([k, v]) => !/^fn_[a-z_0-9]+$/.test(k) || v.trim().length < 40).map(([k]) => `helper ${k}`),
      ...Object.entries(doc.exceptions).filter(([k, v]) => !/^fn_[a-z_0-9]+\((?:[a-z_0-9]+ [a-z_ \][0-9]+(?:, [a-z_0-9]+ [a-z_ \][0-9]+)*)?\)$/.test(k) || v.trim().length < 40)
        .map(([k]) => `exception ${k}`),
    ];
    expect(bad, "entries without a function's name or signature, or with a reason under 40 characters").toEqual([]);
  });

  it("FS21 every function a migration creates in public is named fn_ (the database checks see every one)", () => {
    const odd = created.filter((f) => f.schema === "public" && !f.name.startsWith("fn_")).map((f) => f.name);
    expect([...new Set(odd)]).toEqual([]);
  });

  it("FS22 every helper and exception names a function a migration creates", () => {
    const names = new Set(created.map((f) => f.name));
    const listed = [...Object.keys(doc.helpers), ...Object.keys(doc.exceptions).map((k) => k.slice(0, k.indexOf("(")))];
    expect(listed.filter((n) => !names.has(n))).toEqual([]);
  });
});
