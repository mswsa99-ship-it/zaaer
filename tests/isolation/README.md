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

## Executable partial gate, worker F (24 Nov 2026)

`local-smoke.sh` now bootstraps its own disposable database, creates concrete synthetic fixtures,
executes controls before actor probes and writes raw probes plus detailed JSON/CSV matrices.
It requires an explicit Unix socket, port, and `TEST_DB=iso_*`. It rejects libpq remote overrides.
It drops that named disposable DB using the existing bootstrap. Never point it at a shared instance.

```sh
PGHOST=/your/local/socket PGPORT=5432 PGUSER=postgres TEST_DB=iso_matrix \
  ISOLATION_OUT=/tmp/isolation-evidence bash tests/isolation/local-smoke.sh
```

This command is intentionally **nonzero**. Item 2.11 is not accepted. No aggregate matrix row is
reported PASS. The runner has only partial table adapters, no general RPC adapters and no complete
role-operation oracle. The two phone-link functions have a separate executed guest slice. Unsupported
cells and existing inventory exemptions remain visible as `unexecuted` and `exception-review`.
The generator's old exemption list is not a new reviewed exception grant.

Evidence files: `catalog.json`, `fixtures.json`, `seed-errors.json`, `probes.json`, `guest-links.json`,
`matrix.json`, `matrix.csv`, `summary.json`, and execution logs. The reporter exits 1 for incomplete
coverage, including an empty or all-denial run. `snapshot-tests.sql` checks all-table snapshots,
added/deleted slices, real mutation detection and rollback cleanliness.

Known gaps, do not interpret these as security denial successes:

- Composite-primary-key tables need unique tuple locators. They are not probed through a broad
  organization selector. Several singleton create controls conflict with existing rows.
- Some direct CRUD operations are not a valid application path (immutable financial/audit rows,
  FK-restricted deletes, last-owner guard). They need a source-backed exception or a valid control.
- The current update payload is a no-op SET statement, not a proven content-changing update adapter.
- Table-owner controls prove statement shape only, not allowed API-role behavior. Allowed controls
  for each role/capability remain missing. `oracle-incomplete` preserves that gap.
- Six roles appear in the inventory. Staff have 18 actual auth identities. Guest table probes use one
  anon identity, since public SQL does not consume phone-session tokens; four guest capabilities
  are tested separately, not counted as four distinct SQL logins.
- Platform tables, helpers, triggers, and inaccessible signatures retain the old inventory reasons
  pending review, never PASS. All exposed RPC signatures still need exact operation adapters.
- Full-table content snapshots detect persisted row changes before rollback, including trigger effects.
  They do not monitor sequences, advisory locks, timing channels, external network effects or storage.
- Successful same-hotel cross-branch reads in `branch_memberships`, `ai_guardrail_events` and
  `ai_tool_executions` violate the inventory's blanket branch expectation. Current policies explicitly
  allow these reads. They are policy discrepancies for review, not confirmed vulnerabilities.

`wiring.diff` is a proposal for the lead to apply sequentially. It is not applied and must not be
called a green P0 gate. All future work must keep incomplete adapters fail-closed.
