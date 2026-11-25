# Public identity oracle integration, local only

Net delta on f21172e, extracted from the cumulative iso17 candidate while preserving184a6c8single-execution branch provenance, CASE safety, object-occurrence fields and explicitly unmeasured mutators.

- Existing read result JSON is unwrapped only when exactly one result row with one column exists. Composite record text is not JSON and is no longer used as the public payload.
- Strict JSONPath recursive descent replaces the array recursion that could hang. Nested private keys are counted, including inside arrays.
- Keys alone cannot qualify an identity lookup. Test-only iso.public_identity_ok supports only the source-qualified fn_guest_site signature from0082 and requires the exact four-key JSON object for the target organization, including exact slug/names/null value, active organization and at least one active nonarchived branch. Other generic public adapters fail closed pending a separate identity contract.
- Report public-exception classification requires both public_keys_ok=true and public_identity_ok=true. Older keys-only evidence is not retroactively accepted. This is an intentional tightening of the public exception, no role/grant/policy widening.
- No shared RPC adapter edited. Its actual public_keys must be set by its owner before this path can earn evidence. No acceptance count or inventory status changes.

## Focused local PG16 proof

Standalone rollback-only public-oracle-proof.sql completed on iso_candidate_1733:

- Exact payload passes under actual anon actor and empty claims.
- Wrong valid hotel carrying the same four keys fails identity and earns no public exception.
- Wrong slug/name, missing nullable key, scalar/null/array/nested same-key shape and unqualified signature do not qualify.
- Nested-array private key probe terminates inside a3second timeout and fails closed.
- No active branch, all branches archived and suspended hotel fail identity.

17existing branch-provenance/single-execution/sentinel assertions reran successfully against the updated engine.44Vitest tests pass (30report,6matrix,3skip,5staffmetadata);14static baseline/negative cases pass. Inventory unchanged338/protected9/adapters119. The bounded local candidate script includes the new public proof. No full guest isolation or application migration/publication implied.

RPC26adapter supplement: canonical guest_site row now registers the exact four public_keys. The proposed read effect_sql was deliberately omitted: the engine evaluates effect_sql only for mutating adapters, so that SQL would be unused and would misleadingly suggest extra execution/identity evidence. Canonical exact identity oracle remains the active protection. RPC25credit-note variant is not integrated pending independent PG16purpose-fixture/exact-effect verification; unique adapters remain119.
