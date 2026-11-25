# RoomAI release gates

Each step says who does it and whether a test or a job **enforces** it, or whether it is a **checklist** that a person follows.
Nothing here promises complete coverage: a gate lowers surprises, it does not remove them.

| # | Step | Who | Status |
|---|------|-----|--------|
| 1 | Requirement: the user's words, the pages and roles it touches, what stays unchanged | coordinator | checklist |
| 2 | Early UX expectations on a 390px phone: the journey, and the empty, loading, error, role and branch states | UX reviewer | checklist |
| 3 | Implementation with a test that fails without the change | implementer | checklist (tests are run by CI) |
| 4 | Independent review: UX, operations, finance, security, performance/AI, as the change touches them | reviewers | checklist |
| 5 | Evidence: verify, unit, SQL gate, demo e2e green; each review item is pass (with evidence), fail (with steps), or not tried (left open) | CI + implementer | enforced for the tests; checklist for the review items |
| 6 | Backend preconditions: every migration the code needs is applied to the real project, read back from `supabase_migrations.schema_migrations` and the new functions checked, with a rollback script ready; then `supabase/real-applied.json` is updated | implementer | enforced only in part: `scripts/check-backend-applied.mjs` (unit BA01 to BA04) stops publication when the newest migration is newer than the record. It cannot prove the database has it; the read-back is the checklist |
| 7 | Publish to `develop` only; the staging run gates the deploy | CI | enforced |
| 8 | Post-release journeys on the live site as the owner, read only, 390px: login, dashboard, reservations, rooms, finance pages. Screenshots kept | implementer | checklist |
| 9 | Revokes (removing a grant) come only after the code that no longer needs the grant is live and checked | implementer | checklist |

Not enforced: the "backend" job in `staging.yml` deploys only when the repository secrets exist. Without them it prints a notice and passes. A green backend job is not evidence that a migration was applied.
