# Guest header candidate review, 2026-11-24 17:41

Decision: do not integrate iso18heuristic header injection. Canonical engine remains the f98d13eline at this checkpoint. Independent worker's bounded invocation results are retained as configuration observations, not guest-isolation acceptance.

## Source boundary

Effective0082fn_token_reservation accepts a live registration-session bearer token for an active hotel when no x-hotel-slug is present. If a header is present, session organization must equal fn_guest_org_id(). Thus a header is conditional binding, not a prerequisite. Guest-phone resolvers have their own scope/expiry rules and need independent exact call-chain qualification.

A regex over a public function name and one `__impl` body is neither an exact signature dependency contract nor a complete call graph. It can miss deeper calls/overloads or match text/comments that do not execute. Header behavior must be declared only for source-qualified exact signatures/scenarios, not inferred as an automatic engine rule.

## Why reported denials do not qualify the whole claim

- Substituting a target-owned token with a different hotel's header proves only header mismatch refusal when the positive control is valid.
- A same-hotel other-branch actor still sends a matching hotel header. The target's bearer token may legitimately identify the target booking, regardless of the surrounding staff JWT. This is not a different guest's credential.
- Target-owned token must not silently become an attacker-owned token by renaming actor labels. Actor identity, token owner/reservation and header relationship are distinct dimensions.
- Missing/zero/invalid own controls cannot validate attacks. Departure not-in-stay remains invalid. A mutator without exact effects/touch/non-target checks stays incomplete even if no error occurs.

## Explicit bounded scenario contract for fixture owner

For each qualified function, record exact signature/source chain and fixture token/session class, token owner reservation/hotel/branch, request header (absent/matching/wrong), JWT/DB role and targeted object. Keep these dimensions in evidence IDs or explicit fields without replacing the original actor/target meaning.

1. Positive: real anon role with target-owned live capability and valid business prerequisites; matching header, plus separately absent-header bearer behavior where the source permits it.
2. Credential negative: actor-owned other-guest capability plus target object/ref, same hotel/same branch and same hotel/different branch where the API accepts an explicit object. For a token-only endpoint with no target parameter, the correct result is the actor's own booking, not an invented target denial.
3. Hotel binding negative: valid token + wrong hotel header. Distinguish this from credential isolation.
4. Expired/invalid token negatives, with no writes. Do not use them as substitute positive controls.
5. Mutating cases: source-valid state, exact intended effect, complete touched rows and unchanged non-target actors. Protected/keybox/outbound effects remain excluded.

No new grants, policy changes, guest fixture integration or production effects in this review.

## Accepted standalone read-proof supplement

Separate guest-token-proof.sql from the isolation worker was tightened locally: NOT NULL result values and IS DISTINCT FROM TRUE failure check, required exactly two distinct live hotel/token fixtures, exact reservation.id equality instead of substring matching, symmetric A/B direction for both functions, and exact22assertion count. Missing fixtures now fail before execution. Optional standalone fixture file is synthetic and rolls back in the same transaction. No engine heuristic or matrix changes.

Local PG16run with standalone fixtures:22/22pass for fn_guest_session and fn_guest_stay_summary only. Both hotel directions: matching-header data, exact own reservation identity, wrong-header refusal, invalid-token refusal, absent-header bearer resolving its own reservation. Expiry and suspension negatives are fn_guest_session only. Missing-fixture negative run refuses as intended. This is not same-hotel cross-guest target proof, mutator proof, coverage of all token functions, or a full matrix. No returned private guest data is copied into the ledger.
