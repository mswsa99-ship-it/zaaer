/**
 * The audit dictionary lives three times (decision 14, 10.3): src/lib/auditLabels.ts for the screens, migration 0040
 * (fn_audit_action_label / fn_audit_entity_label) for the log, its export and «استعمال القدرات», and the owner's paste
 * 0041, which re-creates both functions with the family 0040 cannot spell (the «حذف تعريف» codes). These tests keep
 * the copies identical, so a code never reads one way on the screen and another in the export (AB01–AB08). The
 * capability catalogue has a TypeScript copy too (src/lib/capabilityCatalog.ts, read by the demo): AB07 diffs it.
 * Since the owner's paste 0044 the removal family lives in two small functions of its own (fn_audit_removal_label,
 * fn_capability_removal_actions), so the dictionary and the catalogue carry no refused word and later additions are
 * ordinary migrations (AB08). The current dictionary is 0048's (0044 plus the platform correction); 0040, 0041 and 0044 are checked as the history they are.
 */
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { AUDIT_ACTION_LABELS, AUDIT_ENTITY_LABELS, auditActionLabel, auditEntityLabel } from "../../src/lib/auditLabels";
import { CAPABILITY_CATALOG } from "../../src/lib/capabilityCatalog";

const ROOT = join(__dirname, "..", "..");
const read = (p: string) => readFileSync(join(ROOT, p), "utf8");
const m40 = read("supabase/migrations/20261028010000_0040_lists_reports_staff.sql");
const m41 = read("supabase/migrations/20261028020000_0041_phase6_paste.sql");
const m44 = read("supabase/migrations/20261029030000_0044_permissions_paste.sql");
const m48 = read("supabase/migrations/20261030020000_0048_switch_reprice.sql");

/** The body of one function, from its `create or replace` to its closing `$$;`. */
function fnBody(sql: string, fn: string): string {
  const start = sql.indexOf(`create or replace function ${fn}(`);
  expect(start, `${fn} not found`).toBeGreaterThan(-1);
  const end = sql.indexOf("$$;", sql.indexOf("as $$", start) + 5);
  return sql.slice(start, end);
}
/** The CASE arms of one function body: `when 'code' then 'label'` → {code: label}. */
function caseArms(sql: string, fn: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const m of fnBody(sql, fn).matchAll(/^\s*when '([^']+)' then '((?:[^']|'')*)'\s*$/gm)) out[m[1]] = m[2].replace(/''/g, "'");
  return out;
}
/** The verb → Arabic fallback list of a function body (one line of several `when` arms). */
function verbArms(sql: string, fn: string): Record<string, string> {
  const body = fnBody(sql, fn);
  const a = body.indexOf("case split_part(p_action, '.', 2)");
  const b = body.indexOf("else null end, replace(split_part", a);
  expect(a, "verb fallback not found").toBeGreaterThan(-1);
  const out: Record<string, string> = {};
  for (const m of body.slice(a, b).matchAll(/when '([a-z_]+)' then '([^']+)'/g)) out[m[1]] = m[2];
  return out;
}
/** The catalogue's codes and their action arrays (0044: the removal codes come from their own function). */
function catalog(sql: string): Array<{ code: string; coverage: string; core: boolean; actions: string[] }> {
  const body = fnBody(sql, "fn_capability_catalog");
  const removal: Record<string, string[]> = {};
  if (sql.includes("create or replace function fn_capability_removal_actions(")) {
    for (const m of fnBody(sql, "fn_capability_removal_actions").matchAll(/when '([a-z_.]+)' then array\[([^\]]*)\]/g)) removal[m[1]] = [...m[2].matchAll(/'([^']+)'/g)].map((x) => x[1]);
  }
  const rows: Array<{ code: string; coverage: string; core: boolean; actions: string[] }> = [];
  for (const m of body.matchAll(/\('([a-z_.]+)', '[^']+', '[^']+', (true|false), '(full|partial|none)', array\[([^\]]*)\]/g)) {
    // the order inside a row means nothing (the catalogue only asks whether a code is in it): kept sorted
    rows.push({ code: m[1], core: m[2] === "true", coverage: m[3], actions: [...[...m[4].matchAll(/'([^']+)'/g)].map((x) => x[1]), ...(removal[m[1]] ?? [])].sort() });
  }
  return rows;
}
/** The dictionary in force after 0044: the core function's arms and the removal family's. */
const current = () => ({ ...caseArms(m48, "fn_audit_action_label"), ...caseArms(m44, "fn_audit_removal_label") });

const removalFamily = (k: string) => /\.deleted$/.test(k);
/** codes the dictionary gained after 0044 (0048: the platform correction) */
const AFTER_44 = ["reservation.platform_updated"];
/** codes the dictionary gained after 0041 (0042–0044, and 0048's) */
const LATER_ACTIONS = ["permissions.updated", "permissions.reset", "organization.updated", ...AFTER_44];
const LATER_ENTITIES = ["role_permissions"];
const without = (o: Record<string, string>, keys: string[]) => Object.fromEntries(Object.entries(o).filter(([k]) => !keys.includes(k)));
const tsActions = AUDIT_ACTION_LABELS;
const tsEntities = AUDIT_ENTITY_LABELS;

describe("audit labels — one dictionary in three places", () => {
  it("AB01 the dictionary in force (0044: the core function and the removal family) is src/lib/auditLabels.ts, actions and entities alike", () => {
    expect(current()).toEqual(tsActions);
    expect({ ...caseArms(m44, "fn_audit_action_label"), ...caseArms(m44, "fn_audit_removal_label") }).toEqual(without(tsActions, AFTER_44));
    expect(caseArms(m44, "fn_audit_entity_label")).toEqual(tsEntities);
    for (const k of LATER_ACTIONS) expect(tsActions[k], k).toBeTruthy();
  });

  it("AB02 the history agrees: 0041 had all of it but the later codes, 0040 also lacked the removal family it cannot spell", () => {
    expect(caseArms(m41, "fn_audit_action_label")).toEqual(without(tsActions, LATER_ACTIONS));
    expect(caseArms(m41, "fn_audit_entity_label")).toEqual(without(tsEntities, LATER_ENTITIES));
    const expected = Object.fromEntries(Object.entries(without(tsActions, LATER_ACTIONS)).filter(([k]) => !removalFamily(k)));
    expect(caseArms(m40, "fn_audit_action_label")).toEqual(expected);
    expect(caseArms(m40, "fn_audit_entity_label")).toEqual(without(tsEntities, LATER_ENTITIES));
    expect(Object.keys(tsActions).filter(removalFamily).length).toBeGreaterThan(5);
    expect(Object.keys(caseArms(m44, "fn_audit_removal_label")).sort()).toEqual(Object.keys(tsActions).filter(removalFamily).sort());
  });

  it("AB03 the humanising fallback agrees: 0044's verbs and the removal verb are 0041's list and the TypeScript one", () => {
    const v41 = verbArms(m41, "fn_audit_action_label");
    const v40 = verbArms(m40, "fn_audit_action_label");
    const v44 = verbArms(m44, "fn_audit_action_label");
    for (const [verb, ar] of Object.entries(v41)) expect(auditActionLabel(`zz_unknown.${verb}`), verb).toBe(`${ar} — zz unknown`);
    expect(Object.keys(v41).sort()).toEqual([...Object.keys(v40), "deleted"].sort());
    expect(v44).toEqual(v40);
    expect(fnBody(m44, "fn_audit_removal_label")).toContain("then 'حذف — ' || fn_audit_entity_label(split_part(p_action, '.', 1))");
    expect(auditActionLabel("x.frobbed")).toBe("frobbed — x");
    expect(auditActionLabel("plain_code")).toBe("plain code");
    expect(auditActionLabel("room.created")).toBe("إنشاء وحدة");
    expect(auditEntityLabel("reservation")).toBe("حجز");
    expect(auditEntityLabel(null)).toBe("—");
    expect(auditEntityLabel("odd_thing")).toBe("odd thing");
  });

  it("AB04 every code of the capability catalogue has a label; 0041's catalogue is 0044's without the matrix row and the rename, 0040's also without the removal family", () => {
    const c44 = catalog(m44);
    expect(c44.length).toBeGreaterThan(45);
    const unlabeled = c44.flatMap((r) => r.actions.filter((a) => !tsActions[a]).map((a) => `${r.code}: ${a}`));
    expect(unlabeled).toEqual([]);
    const c41 = catalog(m41);
    const hist = c44.filter((r) => r.code !== "admin.permissions").map((r) => ({ ...r, actions: r.actions.filter((a) => !LATER_ACTIONS.includes(a)) }));
    expect(c41).toEqual(hist);
    const c40 = catalog(m40);
    expect(c40.map((r) => r.code)).toEqual(c41.map((r) => r.code));
    for (const r of c41) expect(c40.find((x) => x.code === r.code)!.actions).toEqual(r.actions.filter((a) => !removalFamily(a)));
  });

  it("AB05 the catalogue marks the core administration (decision 53 / G26) and says where the log sees only part of a capability (D04)", () => {
    const c = catalog(m44);
    const core = c.filter((r) => r.core).map((r) => r.code);
    for (const k of ["admin.branches", "admin.rooms", "admin.room_categories", "admin.facilities", "admin.task_types", "admin.services", "admin.staff", "admin.cash_accounts", "admin.rates", "admin.sources", "admin.knowledge", "admin.permissions"]) expect(core, k).toContain(k);
    expect(c.filter((r) => r.coverage === "partial").map((r) => r.code).sort()).toEqual(["admin.whatsapp", "guests.self_entry", "stay.summary"]);
    for (const r of c.filter((r) => r.coverage === "none" && r.code.startsWith("screens."))) expect(r.actions).toEqual([]);
    expect(new Set(c.map((r) => r.code)).size).toBe(c.length);
    const seen = new Map<string, string>();
    for (const r of c) for (const a of r.actions) { expect(seen.has(a), `${a} in ${seen.get(a)} and ${r.code}`).toBe(false); seen.set(a, r.code); }
  });

  it("AB07 the TypeScript catalogue the demo reads is the SQL catalogue in force (0044), row for row", () => {
    const sql = catalog(m44).map((r) => ({ code: r.code, core: r.core, coverage: r.coverage, actions: r.actions }));
    const ts = CAPABILITY_CATALOG.map((r) => ({ code: r.code, core: r.core, coverage: r.coverage, actions: [...r.actions].sort() }));
    expect(ts).toEqual(sql);
    const labels = [...fnBody(m44, "fn_capability_catalog").matchAll(/\('([a-z_.]+)', '([^']+)', '([^']+)', (?:true|false), '(?:full|partial|none)', array\[/g)].map((m) => [m[1], m[2], m[3]]);
    expect(CAPABILITY_CATALOG.map((r) => [r.code, r.label, r.area])).toEqual(labels);
  });

  it("AB06 the codes the migrations write are in the dictionary (the voucher family, the archive/restore/removal family, identities, conversations, the matrix)", () => {
    for (const code of ["voucher.receipt_created", "voucher.deposit_created", "voucher.refund_created", "voucher.deposit_refund_created", "voucher.deposit_apply_created",
      "approve_identity", "reject_identity", "branch.logo_changed", "branch.image_changed", "room.archived", "room.restored", "room.deleted", "service.deleted",
      "conversation_taken", "conversation_returned_to_assistant", "unanswered.ignored", "unanswered.open", "staff.signed_out", "staff_invited", "data_purge_executed",
      "permissions.updated", "permissions.reset", "organization.updated"]) {
      expect(tsActions[code], code).toBeTruthy();
    }
    for (const entity of ["ai_action_proposal", "review_items", "conversation", "unanswered_question", "service", "voucher", "reservation_guest", "role_permissions"]) expect(tsEntities[entity], entity).toBeTruthy();
  });

  it("AB08 after 0044 the dictionary and the catalogue carry no refused word: a later code is added by an ordinary migration", () => {
    for (const fn of ["fn_audit_action_label", "fn_audit_entity_label", "fn_capability_catalog"]) expect(fnBody(m44, fn), fn).not.toMatch(/delet|drop|truncat/i);
    expect(fnBody(m44, "fn_audit_action_label")).toContain("fn_audit_removal_label(p_action)");
    expect(fnBody(m44, "fn_capability_catalog")).toContain("fn_capability_removal_actions(c.code)");
  });
});
