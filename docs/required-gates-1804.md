# Required verification gates, local correction

Original plan completion rule5 and item2.11 require no skipped acceptance gate and the full isolation matrix as P0. Source anchor before correction:a10ef32.

## Changes

- Every declared gate now fails the full aggregate on skip or failure. e2e is P0; the old ALLOW_P1_FAIL variable has no effect.
- Local QUICK mode reports PARTIAL CHECK PASSED, never the full RESULT:PASS marker. CI refuses QUICK mode before starting.
- Full verification invokes isolation acceptance as P0. CI already invokes that exact script. The new acceptance-gate.sh deliberately reports INCOMPLETE and exits1. It does not bootstrap a database, load fixtures or invoke application RPCs.
- This blocker is not the missing full matrix runner. No adapter count, bounded probe, inventory or external JSON can satisfy it. Replace it only with a qualified complete source-grounded runner after remaining controls/effects and exclusions are resolved.

## Evidence

Inert command harness exercises the actual verify orchestration in an empty temporary fixture project. Before the fix,3of5cases failed: skipped e2e returned0, legacy override accepted failed e2e, and e2e was P1. A separate added isolation wiring case failed before wiring because no matrix gate was invoked.

After correction:8orchestration tests,2blocker safety/wiring tests and4existing test-log tests pass,14total. Test command mocks do not run application SQL, browser, network or protected fixtures. Blocker safety test uses a PATH containing only trap executables and confirms no external command is invoked. Direct blocker invocation exits1 as expected. Focused eslint and bash syntax checks pass. Earlier gate-only tsc pass was followed by the final focused run; no full current-candidate verify or CI run is claimed.

The fresh-source archive sent at18:03contains the earlier gate work-in-progress, not this final wiring delta. A separate committed patch carries the complete change.

## Remaining acceptance

Full verification and CI should be RED until2.11is genuinely complete. The unit suite being green means the red release boundary works correctly. It does not mean the application is accepted or safe to publish. Publication, live migrations, Auth/email, credentials, outbound messages and spending remain outside this local change.
