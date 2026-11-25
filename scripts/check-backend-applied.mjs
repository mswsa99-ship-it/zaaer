#!/usr/bin/env node
/**
 * Publication precondition: the newest migration in the repository must be recorded as applied on the real project
 * (supabase/real-applied.json) before the site is published. The "backend" job cannot do this: it only deploys when
 * repository secrets exist, and prints a notice and passes when they do not (this is how 8b2f847 reached the live site
 * without its migration). This check fails instead.
 *
 * What it proves: the record was updated. What it does not prove: that the database has the migration. The person who
 * applies a migration by hand updates the record only after reading supabase_migrations.schema_migrations on the real
 * project (docs/RELEASE_GATES.md, step 6). Usage: node scripts/check-backend-applied.mjs [migrationsDir] [recordFile]
 */
import { readdirSync, readFileSync } from "node:fs";

export function latestMigrationVersion(files) {
  const v = files.map((f) => /^(\d{14})_/.exec(f)?.[1]).filter(Boolean).sort();
  return v.length ? v[v.length - 1] : null;
}
export function check(files, record) {
  const latest = latestMigrationVersion(files);
  const applied = typeof record?.version === "string" ? record.version : null;
  if (!latest) return { ok: false, reason: "no migrations found" };
  if (!applied) return { ok: false, reason: "supabase/real-applied.json has no version" };
  if (latest > applied) return { ok: false, reason: `newest migration ${latest} is not recorded as applied on the real project (recorded: ${applied}). Apply it first, read schema_migrations to confirm, then update the record.` };
  return { ok: true, reason: `newest migration ${latest} is recorded as applied (record: ${applied})` };
}
if (import.meta.url === `file://${process.argv[1]}`) {
  const dir = process.argv[2] ?? "supabase/migrations", rec = process.argv[3] ?? "supabase/real-applied.json";
  const r = check(readdirSync(dir), JSON.parse(readFileSync(rec, "utf8")));
  console.log(r.ok ? `OK: ${r.reason}` : `::error title=Backend migration not applied::${r.reason}`);
  process.exit(r.ok ? 0 : 1);
}
