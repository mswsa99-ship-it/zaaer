# Additive isolation provenance, 2026-11-24 16:48 Riyadh

Local-only integration on top of 400c2bb. This is not a policy decision or new matrix acceptance run.

- Extracted only the new provenance logic from the cumulative iso16 candidate.
- Read adapters produce the original composite-text marker aggregate and a structured JSON aggregate in one execution. No second read call. Mutator execution is unchanged and its structured provenance is explicitly `unmeasured`.
- Recursive traversal visits nested arrays and objects, matches only exact `branch_id` and `branch_ids` keys and values, and guards array length with CASE for scalar/object/null inputs.
- `structuredBranchObjects` and `nullishBranchObjects` count JSON object occurrences. They do not count unique database rows, staff, or fields. One object can contribute to both signals. Nullish means null branch_id or empty branch_ids, not every possible unknown branch shape.
- Raw markers, rows_ret, assessment logic, statuses, protected skips, and inventory remain unchanged. Provenance is attached only when present in an executed base probe. No historical evidence is retroactively regenerated.

## Focused verification

Disposable local PG16 database `iso_provenance1647`, no application fixture load or application RPC calls:

- Full engine definitions loaded successfully.
- `branch-fields-tests.sql`: ten JSON-shape assertions and three single-execution/raw-representation assertions passed.
- `provenance-probe-tests.sql`: four engine sentinel assertions passed. Read produced exactly three sequence increments for three results, preserved one raw target marker/rows_ret=1, and reported three structured objects. The mutator-labelled harmless sentinel ran once and remained unmeasured.
- 38 Vitest tests passed: 29 report, 3 protected skip identity, 6 matrix generator.
- 14 static inventory baseline/negative cases passed; inventory remains 338 exposed signatures, 9 protected skips and 119 unique adapters.

No full matrix, real mutator replay, migrations, frontend changes, publication, authentication/SMTP changes, external messages or spending.
