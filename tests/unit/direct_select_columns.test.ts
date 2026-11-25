import { describe, it, expect } from "vitest";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

// A column revoked from `authenticated` (0146) must never appear in a direct select, and no direct select
// of these tables may use "*" (a "*" fails for the whole row once any column is revoked).
// This is a static source check of call sites. It does not prove the database grants; the SQL gate does (RS19-RS21).
const REVOKED: Record<string, string[]> = {
  reservations: ["payment_status"],
  reservation_guests: ["identity_issue_number"],
};

function files(dir: string, out: string[] = []): string[] {
  for (const n of readdirSync(dir)) {
    const p = join(dir, n);
    if (p.includes(join("src", "demo"))) continue;
    if (statSync(p).isDirectory()) files(p, out);
    else if (/\.(ts|tsx)$/.test(n) && !/\.test\./.test(n)) out.push(p);
  }
  return out;
}

describe("DS01 direct selects avoid revoked columns", () => {
  const src = files("src").map((p) => [p, readFileSync(p, "utf8")] as const);
  for (const [table, cols] of Object.entries(REVOKED)) {
    it(`${table}: no direct select names ${cols.join(",")} or uses *`, () => {
      const bad: string[] = [];
      for (const [p, text] of src) {
        const re = new RegExp(`from\\(["']${table}["']\\)\\s*\\.select\\(([^)]*)\\)`, "g");
        let m: RegExpExecArray | null;
        while ((m = re.exec(text))) {
          let arg = m[1].trim();
          const id = /^[A-Z_]+$/.test(arg) ? arg : null;
          if (id) { const d = new RegExp(`const ${id}\\s*=\\s*([\\s\\S]*?);`).exec(text); arg = d ? d[1] : arg; }
          if (arg === "" || /["'`]\s*\*\s*["'`]|select\(\s*\)/.test(arg) || /^["'`]\*/.test(arg)) bad.push(`${p}: *`);
          for (const c of cols) if (new RegExp(`\\b${c}\\b`).test(arg)) bad.push(`${p}: ${c}`);
        }
      }
      expect(bad).toEqual([]);
    });
  }
});
