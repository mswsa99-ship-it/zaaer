import { describe, it, expect } from "vitest";
// @ts-expect-error plain .mjs script
import { check, latestMigrationVersion } from "../../scripts/check-backend-applied.mjs";
import { readdirSync, readFileSync } from "node:fs";

describe("publication precondition: newest migration recorded as applied", () => {
  const files = ["20261126042000_0144_x.sql", "20261126043000_0145_y.sql", "README.md"];
  it("BA01 refuses when a migration is newer than the applied record (the 8b2f847 case)", () => {
    expect(check(files, { version: "20261126042000" }).ok).toBe(false);
  });
  it("BA02 passes when the record is at or past the newest migration", () => {
    expect(check(files, { version: "20261126043000" }).ok).toBe(true);
    expect(latestMigrationVersion(files)).toBe("20261126043000");
  });
  it("BA03 refuses a missing or malformed record, and an empty folder", () => {
    expect(check(files, {}).ok).toBe(false);
    expect(check(files, null).ok).toBe(false);
    expect(check([], { version: "1" }).ok).toBe(false);
  });
  it("BA04 the committed record covers the committed migrations", () => {
    const r = check(readdirSync("supabase/migrations"), JSON.parse(readFileSync("supabase/real-applied.json", "utf8")));
    expect(r.ok, r.reason).toBe(true);
  });
});
