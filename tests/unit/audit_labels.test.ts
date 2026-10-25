/**
 * The audit dictionary lives three times (decision 14, 10.3): src/lib/auditLabels.ts for the screens, migration 0040
 * (fn_audit_action_label / fn_audit_entity_label) for the log, its export and «استعمال القدرات», and the owner's paste
 * 0041, which re-creates both functions with the family 0040 cannot spell (the «حذف تعريف» codes). These tests keep
 * the copies identical, so a code never reads one way on the screen and another in the export (AB01–AB07). The
 * capability catalogue has a TypeScript copy too (src/lib/capabilityCatalog.ts, read by the demo): AB07 diffs it.
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

/** The CASE arms of one function body: `when 'code' then 'label'` → {code: label}. */
function caseArms(sql: string, fn: string): Record<string, string> {
  const start = sql.indexOf(`create or replace function ${fn}(`);
  expect(start, `${fn} not found`).toBeGreaterThan(-1);
  const end = sql.indexOf("$$;", sql.indexOf("as $$", start) + 5);
  const body = sql.slice(start, end);
  const out: Record<string, string> = {};
  for (const m of body.matchAll(/^\s*when '([^']+)' then '((?:[^']|'')*)'\s*$/gm)) out[m[1]] = m[2].replace(/''/g, "'");
  return out;
}
/** The verb → Arabic fallback list of a function body (one line of several `when` arms). */
function verbArms(sql: string, fn: string): Record<string, string> {
  const start = sql.indexOf(`create or replace function ${fn}(`);
  const end = sql.indexOf("$$;", start);
  const body = sql.slice(start, end);
  const a = body.indexOf("case split_part(p_action, '.', 2)");
  const b = body.indexOf("else null end, replace(split_part", a);
  expect(a, "verb fallback not found").toBeGreaterThan(-1);
  const out: Record<string, string> = {};
  for (const m of body.slice(a, b).matchAll(/when '([a-z_]+)' then '([^']+)'/g)) out[m[1]] = m[2];
  return out;
}
/** The catalogue's codes and their action arrays. */
function catalog(sql: string): Array<{ code: string; coverage: string; core: boolean; actions: string[] }> {
  const start = sql.indexOf("create or replace function fn_capability_catalog(");
  const end = sql.indexOf("$$;", start);
  const body = sql.slice(start, end);
  const rows: Array<{ code: string; coverage: string; core: boolean; actions: string[] }> = [];
  for (const m of body.matchAll(/\('([a-z_.]+)', '[^']+', '[^']+', (true|false), '(full|partial|none)', array\[([^\]]*)\]/g)) {
    rows.push({ code: m[1], core: m[2] === "true", coverage: m[3], actions: [...m[4].matchAll(/'([^']+)'/g)].map((x) => x[1]) });
  }
  return rows;
}

const removalFamily = (k: string) => /\.deleted$/.test(k);
const tsActions = AUDIT_ACTION_LABELS;
const tsEntities = AUDIT_ENTITY_LABELS;

describe("audit labels — one dictionary in three places", () => {
  it("AB01 the owner's paste (0041) carries the complete dictionary of src/lib/auditLabels.ts, actions and entities alike", () => {
    expect(caseArms(m41, "fn_audit_action_label")).toEqual(tsActions);
    expect(caseArms(m41, "fn_audit_entity_label")).toEqual(tsEntities);
  });

  it("AB02 0040 carries the same dictionary minus the removal family it cannot spell (and nothing else is missing)", () => {
    const expected = Object.fromEntries(Object.entries(tsActions).filter(([k]) => !removalFamily(k)));
    expect(caseArms(m40, "fn_audit_action_label")).toEqual(expected);
    expect(caseArms(m40, "fn_audit_entity_label")).toEqual(tsEntities);
    expect(Object.keys(tsActions).filter(removalFamily).length).toBeGreaterThan(5);
  });

  it("AB03 the humanising fallback agrees: the verb list of 0041 is the TypeScript one, 0040's lacks only the removal verb", () => {
    const v41 = verbArms(m41, "fn_audit_action_label");
    const v40 = verbArms(m40, "fn_audit_action_label");
    // the TS verbs are private; exercise them through the function instead
    for (const [verb, ar] of Object.entries(v41)) expect(auditActionLabel(`zz_unknown.${verb}`), verb).toBe(`${ar} — zz unknown`);
    expect(Object.keys(v41).sort()).toEqual([...Object.keys(v40), "deleted"].sort());
    expect(auditActionLabel("x.frobbed")).toBe("frobbed — x");
    expect(auditActionLabel("plain_code")).toBe("plain code");
    expect(auditActionLabel("room.created")).toBe("إنشاء وحدة");
    expect(auditEntityLabel("reservation")).toBe("حجز");
    expect(auditEntityLabel(null)).toBe("—");
    expect(auditEntityLabel("odd_thing")).toBe("odd thing");
  });

  it("AB04 every code of the capability catalogue has a label (no capability is measured under a code the log would show raw)", () => {
    const c41 = catalog(m41);
    expect(c41.length).toBeGreaterThan(45);
    const unlabeled = c41.flatMap((r) => r.actions.filter((a) => !tsActions[a]).map((a) => `${r.code}: ${a}`));
    expect(unlabeled).toEqual([]);
    // 0040's catalogue is 0041's minus the removal family
    const c40 = catalog(m40);
    expect(c40.map((r) => r.code)).toEqual(c41.map((r) => r.code));
    for (const r of c41) expect(c40.find((x) => x.code === r.code)!.actions).toEqual(r.actions.filter((a) => !removalFamily(a)));
  });

  it("AB05 the catalogue marks the core administration (decision 53 / G26) and says where the log sees only part of a capability (D04)", () => {
    const c = catalog(m41);
    const core = c.filter((r) => r.core).map((r) => r.code);
    for (const k of ["admin.branches", "admin.rooms", "admin.room_categories", "admin.facilities", "admin.task_types", "admin.services", "admin.staff", "admin.cash_accounts", "admin.rates", "admin.sources", "admin.knowledge"]) expect(core, k).toContain(k);
    expect(c.filter((r) => r.coverage === "partial").map((r) => r.code).sort()).toEqual(["admin.whatsapp", "guests.self_entry", "stay.summary"]);
    for (const r of c.filter((r) => r.coverage === "none" && r.code.startsWith("screens."))) expect(r.actions).toEqual([]);
    expect(new Set(c.map((r) => r.code)).size).toBe(c.length);
    const seen = new Map<string, string>();
    for (const r of c) for (const a of r.actions) { expect(seen.has(a), `${a} in ${seen.get(a)} and ${r.code}`).toBe(false); seen.set(a, r.code); }
  });

  it("AB07 the TypeScript catalogue the demo reads is the SQL catalogue of 0041, row for row", () => {
    const sql = catalog(m41).map((r) => ({ code: r.code, core: r.core, coverage: r.coverage, actions: r.actions }));
    const ts = CAPABILITY_CATALOG.map((r) => ({ code: r.code, core: r.core, coverage: r.coverage, actions: [...r.actions] }));
    expect(ts).toEqual(sql);
    const labels = [...m41.matchAll(/\('([a-z_.]+)', '([^']+)', '([^']+)', (?:true|false), '(?:full|partial|none)', array\[/g)].map((m) => [m[1], m[2], m[3]]);
    expect(CAPABILITY_CATALOG.map((r) => [r.code, r.label, r.area])).toEqual(labels);
  });

  it("AB06 the codes the migrations write are in the dictionary (the voucher family, the archive/restore/removal family, identities, conversations)", () => {
    for (const code of ["voucher.receipt_created", "voucher.deposit_created", "voucher.refund_created", "voucher.deposit_refund_created", "voucher.deposit_apply_created",
      "approve_identity", "reject_identity", "branch.logo_changed", "branch.image_changed", "room.archived", "room.restored", "room.deleted", "service.deleted",
      "conversation_taken", "conversation_returned_to_assistant", "unanswered.ignored", "unanswered.open", "staff.signed_out", "staff_invited", "data_purge_executed"]) {
      expect(tsActions[code], code).toBeTruthy();
    }
    for (const entity of ["ai_action_proposal", "review_items", "conversation", "unanswered_question", "service", "voucher", "reservation_guest"]) expect(tsEntities[entity], entity).toBeTruthy();
  });
});
