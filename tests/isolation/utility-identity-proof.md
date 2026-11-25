# Utility/identity lane, base 48c6635

53 exact signatures remain explicit in utility-identity-contracts.json. This is a source/contract and bounded proof increment, not 53 accepted endpoints or a full isolation gate.

## Files and execution

Disposable local PG16 DB with current migrations, engine.sql, generated scope and base fixtures.sql only. Do not load rpc-fixtures or the all-family local-smoke loop. Execute both scripts with psql -X -v ON_ERROR_STOP=1. Each script begins a transaction and rolls back; fixture page/cap changes are local, no production migrations or page-gate edits.

- utility-literal-proof.sql: 30 input-only transform/catalog signatures. 78 value/error assertions, plus successful version checks. Literal expected values, NULL/unknown/invalid cases where listed, exact SQLSTATE/message for error boundaries. Runs as authenticated, with whole-public snapshot equality. No real messaging/integration calls: WhatsApp status receives a synthetic composite, never reads stored credentials/config.
- utility-identity-proof.sql: proposed 23 actor/page/org/branch helper contracts. Base18staff actors across two orgs/four branches; exact staff UUID/role/org/branch sets; own, same-org-other-branch and foreign-org checks. Two managers get explicit local role permission fixtures, then empty individual page grants versus reports view and knowledge edit. No-actor negatives. Hotel slug selector exact identity/invalid/malformed under anon. Whole-public snapshots after fixture preparation/stages.

## Evidence available now

Supplemental PGlite extracted-production-body run:78literal/error assertions passed. Extracted functions used a synthetic branch_whatsapp_channels composite with only accessed columns; no full migrations, grants or public-table snapshot claim from this run. Canonical full-schema PG16 execution is pending, especially the identity file. No adapter count or gate result changed.

## Source-qualified treatment

Input-only/catalog signatures have no row/tenant input in their latest bodies or utility dependencies; proposed N_A applies only to tenant-target and CRUD cells. Authenticated EXECUTE grants/output contracts still require qualification. Actor helpers are NOT N_A: they resolve current identity or permissions. Read gates returning true in legacy/none mode are compositional gates, not standalone authorization. Guest-org resolution selects public site identity, not guest authority.

## Explicit remaining

- Canonical PG16 execution/current effective-grant check for both files.
- Utility test branches are representative, not all mappings or all invalid strings.
- Actual guest registration/review token fallback, expired/inactive targets and single-org fallback not covered here.
- Session revocation/inactive actor, sensitive grant toggles, legacy override denies, owner/full-role contrasts not covered here.
- fn_is_staff lacks fn_session_ok while current_role/staff_id/user_org_id include it. This source semantic difference is recorded, not patched or treated as endpoint authorization proof.
- No role/page/migration policy edits, outbound effects, protected functions, all-family preloads or live access.

Canonical supplement: revised proof executed on PG16.6 iso_credit1745,78literal and301identity assertions pass, whole-public snapshots unchanged. Effective grant verification is recorded separately by integrator. No full endpoint-matrix or exhaustive-mapping claim.
