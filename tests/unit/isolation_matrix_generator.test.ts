import { describe, expect, it } from "vitest";
// @ts-expect-error standalone Node runner has no emitted declaration file
import { generateMatrix, summarizeResults } from "../isolation/matrix-generator.mjs";

const tenancy = { tables: { organizations: { scope: "platform" }, settings: { scope: "hotel" }, rooms: { scope: "branch" } } };
const scope = { helpers: { fn_clock: "Returns date only" }, exceptions: { "fn_guest(p_token text)": "Guest capability" } };
const catalog = {
  tables: ["organizations", "settings", "rooms"],
  functions: [
    { signature: "fn_clock(p_branch uuid)", name: "fn_clock", trigger: false, exposed: true },
    { signature: "fn_guest(p_token text)", name: "fn_guest", trigger: false, exposed: true },
    { signature: "fn_private()", name: "fn_private", trigger: false, exposed: false },
    { signature: "fn_trigger()", name: "fn_trigger", trigger: true, exposed: false },
    { signature: "fn_rooms(p_branch uuid)", name: "fn_rooms", trigger: false, exposed: true },
  ],
};

describe("isolation matrix generator is fail closed", () => {
  it("covers both hotels, two branches each, six roles and CRUD for every surface", () => {
    const rows = generateMatrix(tenancy, scope, catalog);
    expect(rows).toHaveLength((3 + 5) * 2 * 2 * 2 * 2 * 6 * 4);
    expect(new Set(rows.map((r: any) => r.id)).size).toBe(rows.length);
    expect(new Set(rows.map((r: any) => r.actor.role))).toEqual(new Set(["owner", "manager", "supervisor", "finance", "housekeeping", "guest"]));
    expect(rows.filter((r: any) => r.surface === "table" && r.name === "rooms" && r.actor.hotel !== r.target.hotel).every((r: any) => r.expected === "deny")).toBe(true);
    expect(rows.filter((r: any) => r.name === "rooms" && r.actor.role === "manager" && r.actor.hotel === r.target.hotel && r.actor.branch !== r.target.branch).every((r: any) => r.expected === "deny")).toBe(true);
    expect(rows.filter((r: any) => r.name === "rooms" && r.actor.role === "owner" && r.actor.hotel === r.target.hotel).every((r: any) => r.expected === "policy-dependent")).toBe(true);
  });
  it("rejects unclassified and stale table inventory rather than silently omitting tables", () => {
    expect(() => generateMatrix(tenancy, scope, { ...catalog, tables: [...catalog.tables, "forgotten"] })).toThrow(/classification/);
    expect(() => generateMatrix(tenancy, scope, { ...catalog, tables: ["rooms"] })).toThrow(/classification/);
    expect(() => generateMatrix({ tables: { rooms: { scope: "typo" } } }, scope, { ...catalog, tables: ["rooms"] })).toThrow(/scope/);
  });
  it("rejects incomplete function catalogs instead of granting accidental exemptions", () => {
    expect(() => generateMatrix(tenancy, scope, { ...catalog, functions: [{ name: "fn_bad", signature: "fn_bad()" }] })).toThrow(/catalog/);
    expect(() => generateMatrix(tenancy, scope, { ...catalog, functions: [catalog.functions[0], catalog.functions[0]] })).toThrow(/Duplicate/);
  });
  it("records helper/platform exemptions and unsupported RPC operations explicitly", () => {
    const rows = generateMatrix(tenancy, scope, catalog);
    expect(rows.filter((r: any) => r.name === "organizations").every((r: any) => r.status === "exempt" && r.reason)).toBe(true);
    expect(rows.filter((r: any) => r.name === "fn_clock").every((r: any) => r.status === "exempt" && r.reason)).toBe(true);
    expect(rows.filter((r: any) => r.name === "fn_guest").every((r: any) => r.status === "unsupported" && r.reason.includes("capability"))).toBe(true);
  });
  it("accepts complete evidence only and preserves a failed denial", () => {
    const rows = generateMatrix(tenancy, scope, { ...catalog, functions: [] });
    const results = rows.filter((r: any) => r.status === "pending").map((r: any) => ({ id: r.id, outcome: "pass", evidence: "local/probe.log" }));
    expect(summarizeResults(rows, results).passed).toBe(true);
    results[0].outcome = "fail";
    expect(summarizeResults(rows, results).passed).toBe(false);
    expect(summarizeResults(rows, results).failures).toBe(1);
  });
  it("never reports an unexecuted matrix as a successful P0 gate", () => {
    const rows = generateMatrix(tenancy, scope, catalog);
    expect(summarizeResults(rows, []).passed).toBe(false);
    expect(() => summarizeResults(rows, [{ id: "unknown", outcome: "pass" }])).toThrow(/unknown/);
    const row = rows.find((r: any) => r.status === "pending");
    expect(() => summarizeResults(rows, [{ id: row.id, outcome: "pass", evidence: "local/probe-a.log" }, { id: row.id, outcome: "pass", evidence: "local/probe-a.log" }])).toThrow(/duplicate/);
    expect(() => summarizeResults(rows, [{ id: row.id, outcome: "pass" }])).toThrow(/evidence/);
  });
});
