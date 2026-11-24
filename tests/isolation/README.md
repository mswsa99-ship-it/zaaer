# Plan 2.11: isolation matrix inventory, not a completed security gate

No test rows here are reported as executed database probes. This is a test-only handoff scaffold. It does not change the shared SQL runner, fixtures, schema, permissions or CI gates.

## Dimensions

For every table and every exact database function signature: actor hotel A/B, actor branch 1/2, target hotel A/B, target branch 1/2, six roles (owner, manager, supervisor, finance, housekeeping, guest), and read/create/update/delete. This is 384 cells per surface. An actor branch is a synthetic membership slot within its hotel, not a globally shared branch ID. Owners may access both own-hotel branches, subject to the actual operation's policy. Other staff have one branch membership in this planned fixture. Guests need capability-aware fixtures, not staff impersonation.

`supabase/tenancy.json` supplies table scope. The generator refuses missing, stale or invalid classifications. `supabase/function-scope.json` supplies documented helper/exception reasons. The runtime catalog, rather than migration text regex, supplies active tables and function overloads, trigger types and actual API EXECUTE grants.

## Local-only usage

Use a disposable PostgreSQL 16 database built by the repository bootstrap and all migrations, never an existing or production DB. Run the existing SQL baseline first. Existing `tenancy_tests.sql` and `function_scope_tests.sql` remain authoritative for their executed coverage; this generator does not replace them.

```sh
psql -X -A -t -v ON_ERROR_STOP=1 -d roomai_disposable -f tests/isolation/catalog.sql > /tmp/roomai-catalog.json
node tests/isolation/matrix-generator.mjs /tmp/roomai-catalog.json /tmp/roomai-matrix.json
npx vitest run tests/unit/isolation_matrix_generator.test.ts
```

The first command above reads only. Creating/bootstraping the disposable database is a separate existing workflow, not performed by this generator.

## Status semantics and remaining work

- `pending`: table CRUD needs concrete synthetic rows, six actual identities per hotel, authorized-operation positive control, attempted denial and before/after snapshots. No CRUD calls are emitted automatically: malformed insert constraints must not be mistaken for authorization enforcement.
- `exempt`: platform-owned registry, trigger function, inaccessible internal function, or documented non-data helper. Every cell retains a reason. Exempt is not passed.
- `unsupported`: RPCs are calls, not generic CRUD. Every exact signature needs an explicit adapter defining valid inputs, intended operation(s), expected effects and control. Public guest-capability functions retain their original exception reason. Unsupported is not passed.
- `policy-dependent`: this is not an expectation of success. Table role policies/capabilities still need an operation-specific oracle, including guest public/capability-only APIs.

The result summarizer requires a known unique pending cell ID, pass/fail outcome and non-empty evidence reference for every executed result. Missing cells, any unsupported adapter or any failure prevents a successful result. Running with a results file exits nonzero unless this strict condition is met:

```sh
node tests/isolation/matrix-generator.mjs /tmp/roomai-catalog.json /tmp/roomai-matrix.json /tmp/roomai-results.json
```

This is intentionally not wired as P0 yet. Full plan acceptance still requires actual authorized fixtures, all table CRUD probes, all function adapters, post-call mutation detection, public-link crossover probes and integration into the shared verification gate. Review all exemptions against the authoritative schema before promoting it. Do not infer isolation from inventory generation or unit tests.
