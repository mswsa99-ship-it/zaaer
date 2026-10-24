/**
 * Decision 57 — test codes. The testing rules (ZAAER-TESTING-AND-CONTROL-RULES-AR §9–§10) give A, R, F, H, U, D and X
 * fixed meanings (tests/acceptance-library.json). A test may carry one of those codes only if the code exists in the
 * library (a suffix a, b, c… is another facet of the same scenario); every other test uses a prefix registered in the
 * library with its meaning, so a reader never meets the same code with two meanings. Control ids (G01–G28) must exist
 * in the register. Renames are listed old → new in the library and in TESTING.md.
 */
import { describe, it, expect } from "vitest";
import { readFileSync, readdirSync, existsSync } from "node:fs";
import { join } from "node:path";

const ROOT = join(__dirname, "..", "..");
const lib = JSON.parse(readFileSync(join(ROOT, "tests/acceptance-library.json"), "utf8")) as {
  codes: Record<string, { scenario: string; expected: string; controls: string[] }>;
  controls: Record<string, unknown>;
  prefixes: Record<string, string>;
  renamed: Array<{ old: string; new: string; where: string }>;
};

const ID = String.raw`(?:G\d{2}(?:[–/]G\d{2})*|[A-Z]{1,3}(?:-[A-Z]{1,2})?\d{2}[a-z0-9]*)`;
const suites = ["tests/sql", "tests/unit", "tests/e2e", "tests/staging"].filter((d) => existsSync(join(ROOT, d)));

/** Every test id in every suite, with where it was found and the title it names. */
function collect(): Array<{ id: string; file: string; title: string }> {
  const out: Array<{ id: string; file: string; title: string }> = [];
  const add = (id: string, file: string, title = "") => out.push({ id, file, title: title.trim() });
  for (const dir of suites) {
    for (const name of readdirSync(join(ROOT, dir))) {
      const file = `${dir}/${name}`;
      if (!/\.(sql|sh|ts)$/.test(name) || name === "test-codes.test.ts") continue;
      const src = readFileSync(join(ROOT, file), "utf8");
      if (name.endsWith(".sql")) {
        for (const m of src.matchAll(new RegExp(String.raw`t_record\(\s*'(${ID})\s([^']*)'`, "g"))) add(m[1], file, m[2]);
        for (const m of src.matchAll(new RegExp(String.raw`^\s*select\s+'(${ID})\s([^']*)'`, "gm"))) add(m[1], file, m[2]);
      } else if (name.endsWith(".sh")) {
        for (const m of src.matchAll(new RegExp(String.raw`echo\s+"(?:PASS|FAIL)\s+(${ID})\b`, "g"))) add(m[1], file, "");
      } else {
        for (const m of src.matchAll(new RegExp(String.raw`\b(?:test|it|describe)\(\s*["'\`](${ID})[\s—:]([^"'\`]*)`, "g"))) add(m[1], file, m[2]);
        for (const m of src.matchAll(new RegExp(String.raw`\b(?:test|it|describe)\(\s*["'\`]([^"'\`]*)\((${ID})\)`, "g"))) add(m[2], file, m[1]);
      }
    }
  }
  return out;
}

const all = collect();
const LETTERS = new Set(["A", "R", "F", "H", "U", "D", "X"]);

describe("test codes (decision 57)", () => {
  it("TC01 the library holds the 65 scenarios of the rules and the 28 controls", () => {
    expect(Object.keys(lib.codes)).toHaveLength(65);
    expect(Object.keys(lib.controls)).toHaveLength(28);
    for (const [code, v] of Object.entries(lib.codes)) {
      expect(v.scenario, code).not.toBe("");
      expect(v.expected, code).not.toBe("");
    }
  });

  it("TC02 the suites carry test ids (the scan itself works)", () => {
    expect(all.length).toBeGreaterThan(300);
    expect(all.some((x) => x.id === "R01" && x.file.endsWith("core_tests.sql"))).toBe(true);
    expect(all.some((x) => x.id === "X01" && x.file.endsWith("concurrency.sh"))).toBe(true);
    expect(all.some((x) => x.id === "PL01")).toBe(true);
  });

  it("TC03 a single-letter code of the rules is used only for a scenario of the library", () => {
    const wrong = all.filter(({ id }) => {
      const m = id.match(/^([A-Z])(\d{2})[a-z0-9]*$/);
      return m && LETTERS.has(m[1]) && !lib.codes[`${m[1]}${m[2]}`];
    });
    expect(wrong, "codes outside the rules' library — give the test an independent prefix (tests/acceptance-library.json)").toEqual([]);
  });

  it("TC04 every other prefix is registered with its meaning", () => {
    const unknown = all.filter(({ id }) => {
      if (/^G\d{2}/.test(id)) return false;
      const m = id.match(/^([A-Z]{1,3}(?:-[A-Z]{1,2})?)\d{2}/);
      if (!m) return true;
      if (m[1].length === 1 && LETTERS.has(m[1])) return false;
      return !lib.prefixes[m[1]];
    });
    expect(unknown, "unregistered test prefixes").toEqual([]);
  });

  it("TC05 a control named in a test exists in the register (G01–G28)", () => {
    const bad = all.flatMap(({ id, file }) => (id.match(/G\d{2}/g) ?? []).filter((g) => /^G\d{2}/.test(id) && !lib.controls[g]).map((g) => `${g} in ${file}`));
    expect(bad).toEqual([]);
  });

  it("TC06 no renamed id is still in use where it was renamed", () => {
    // a renumbering may give an old number a new meaning in the same place (G06 → G09 while G09 → G16): skip those
    const reused = (r: { old: string; where: string }) => lib.renamed.some((o) => o.new === r.old && o.where === r.where);
    const left = lib.renamed.filter((r) => r.where.startsWith("tests/") && !reused(r) && all.some((x) => x.id === r.old && r.where.includes(x.file)));
    expect(left).toEqual([]);
  });

  it("TC07 an id names one test: inside a file it never comes with two different titles", () => {
    const titles = new Map<string, Set<string>>();
    for (const { id, file, title } of all) {
      if (!title) continue;   // the race script prints its ids without titles
      const k = `${file}#${id}`;
      if (!titles.has(k)) titles.set(k, new Set());
      titles.get(k)!.add(title);
    }
    const dup = [...titles.entries()].filter(([, t]) => t.size > 1).map(([k, t]) => `${k}: ${[...t].join(" | ")}`);
    expect(dup).toEqual([]);
  });
});
