import process from "node:process";
import console from "node:console";
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const roles = ["owner", "manager", "supervisor", "finance", "housekeeping", "guest"];
const operations = ["read", "create", "update", "delete"];
const scopes = ["platform", "hotel", "branch"];

/** Planning inventory only. This module never connects to a database or performs a probe. */
export function generateMatrix(tenancy, functionScope, catalog) {
  const classified = Object.keys(tenancy.tables).sort();
  if (JSON.stringify(classified) !== JSON.stringify([...catalog.tables].sort())) throw new Error("Table classification differs from current database catalog");
  for (const [name, entry] of Object.entries(tenancy.tables)) {
    if (!scopes.includes(entry.scope)) throw new Error(`Invalid scope: ${name}`);
  }
  for (const fn of catalog.functions) {
    if (typeof fn.name !== "string" || typeof fn.signature !== "string" || !fn.signature.startsWith(fn.name + "(") || typeof fn.trigger !== "boolean" || typeof fn.exposed !== "boolean") {
      throw new Error("Incomplete function catalog entry");
    }
  }
  const surfaces = [
    ...classified.map(name => ({ surface: "table", name, signature: name, scope: tenancy.tables[name].scope })),
    ...catalog.functions.map(fn => ({ ...fn, surface: "function", scope: "function" })),
  ];
  if (new Set(surfaces.map(s => `${s.surface}:${s.signature}`)).size !== surfaces.length) throw new Error("Duplicate surface signature");
  const rows = [];
  for (const surface of surfaces) for (const actorHotel of ["hotel-a", "hotel-b"]) for (const actorBranch of ["branch-1", "branch-2"]) {
    for (const targetHotel of ["hotel-a", "hotel-b"]) for (const targetBranch of ["branch-1", "branch-2"]) for (const role of roles) for (const operation of operations) {
      let status = "pending", reason = "Needs real fixture, allowed-operation control, row snapshot and executed database evidence";
      let expected = actorHotel !== targetHotel || (surface.scope === "branch" && role !== "owner" && role !== "guest" && actorBranch !== targetBranch) ? "deny" : "policy-dependent";
      if (surface.scope === "platform") {
        status = "exempt"; expected = "platform-policy"; reason = "Platform registry is not a hotel-owned table; verify platform permissions separately";
      }
      if (surface.surface === "function") {
        const helper = functionScope.helpers[surface.name];
        const exception = functionScope.exceptions[surface.signature];
        if (surface.trigger || !surface.exposed || helper) {
          status = "exempt"; expected = "not-applicable";
          reason = surface.trigger ? "Trigger function, not an API operation" : helper || "Not executable by anon or authenticated in this database catalog";
        } else {
          status = "unsupported"; expected = "requires-adapter";
          reason = exception
            ? `Explicit scope exception requires a capability-aware adapter: ${exception}`
            : "RPC is invoked, not generic CRUD: map this exact signature, arguments and side effects to an operation before executing";
        }
      }
      rows.push({
        id: JSON.stringify([surface.surface, surface.signature, actorHotel, actorBranch, role, targetHotel, targetBranch, operation]),
        surface: surface.surface, name: surface.name, signature: surface.signature, scope: surface.scope,
        actor: { hotel: actorHotel, branch: actorBranch, role }, target: { hotel: targetHotel, branch: targetBranch },
        operation, expected, status, reason,
      });
    }
  }
  return rows;
}

/** Missing, unsupported, or failed probes make the proposed gate fail, never skip-to-green. */
export function summarizeResults(rows, results) {
  const index = new Map(rows.map(r => [r.id, r]));
  const seen = new Set();
  let failures = 0;
  for (const result of results) {
    const row = index.get(result.id);
    if (!row) throw new Error("unknown result id");
    if (seen.has(result.id)) throw new Error("duplicate result id");
    if (row.status !== "pending") throw new Error("Result supplied for exempt or unsupported row");
    if (!["pass", "fail"].includes(result.outcome)) throw new Error("Invalid outcome");
    if (typeof result.evidence !== "string" || !result.evidence.trim()) throw new Error("Missing execution evidence");
    seen.add(result.id);
    if (result.outcome === "fail") failures++;
  }
  const pending = rows.filter(r => r.status === "pending").length;
  const unsupported = rows.filter(r => r.status === "unsupported").length;
  return { passed: pending > 0 && seen.size === pending && unsupported === 0 && failures === 0, total: rows.length,
    pending, unsupported, exempt: rows.filter(r => r.status === "exempt").length,
    executed: seen.size, missing: pending - seen.size, failures };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [catalogPath, outputPath, resultsPath] = process.argv.slice(2);
  if (!catalogPath || !outputPath) throw new Error("Usage: node tests/isolation/matrix-generator.mjs CATALOG.json OUTPUT.json [RESULTS.json]");
  const json = path => JSON.parse(readFileSync(path, "utf8"));
  const rows = generateMatrix(json("supabase/tenancy.json"), json("supabase/function-scope.json"), json(catalogPath));
  writeFileSync(outputPath, JSON.stringify(rows, null, 2) + "\n");
  console.log(JSON.stringify(summarizeResults(rows, resultsPath ? json(resultsPath) : []), null, 2));
  if (resultsPath && !summarizeResults(rows, json(resultsPath)).passed) process.exitCode = 1;
}
