# Plan 2.5 local change record

Date: 2026-11-23, Asia/Riyadh
Status: implemented and tested locally, NOT applied or published.

## Existing behavior

The six settings domains already carry organization_id. A new organization received eight alert rules, but no AI settings, system settings, bank rules or account tree. This was reproduced on a clean database built from the 78 migration files recorded as applied in production.

## Change

0079 adds a private initialization helper and an AFTER INSERT trigger on organizations. AI and system settings use column defaults. Alert rules and the account tree reuse existing code-defined seed helpers. Bank rules use the 25 code-defined rules from 0066 only when the hotel has no rules, preserving any existing edited list. No settings, secrets, usage counters or bank messages are copied from another hotel. Existing selected settings are not overwritten.

The migration also runs the same idempotent initializer for existing hotels. That can add missing AI/system rows, missing standard alert/account entries, or the initial bank list where none exists. Its exact impact on live data must be measured from the fresh backup before applying it. No foreign keys, money rules, guest flows or UI changed.

Document counters were already hotel-scoped and start independently when first used; no eager counter rows are needed.

## Evidence

HS01-HS07 test initialization, cross-hotel content preservation, repeated initialization, private helper permissions, RLS reads and actual signed-in AI setting updates, and independent document counters. Before 0079 the original five-test suite had four failures. After it all seven tests pass. HS20-HS22 check the narrow code shape and absence of copied secret fields.

All eleven existing categories passed in separate bounded invocations, not one monolithic verify invocation. The assembled output totals 1764 passed, including 518 unit tests and all 200 end-to-end tests across eight shards, zero skipped, failed or flaky. Existing function-scope probes, migration preservation and synthetic dump/restore also passed. Final test-only strengthening of the alert-rule content check was rerun directly and passed.

## Deployment gate

0078 is still not applied. No production or remote repository writes were made for this change. Before 0079: fresh encrypted backup, independently verified restore, exact impact pre-application notice, a single transaction with file hash validation, post-application schema/data comparison, then update the production migration record. Destructive 0073 must not be applied by a blanket migration command. Pushing develop remains held because it can deploy functions/UI and pending migrations.
