# Load test report — item 2.10 (الأداء بحجم كبير)

Date: 2026-11-24. Branch `work/load-test-2.10-worker-e` on base `1325919`.
Test-only: a throwaway local PostgreSQL 16 database, synthetic data, no live
requests, no live database, no emails.

## Verdict

Criterion: **p95 < 500 ms for every named function at the full fixture
volume (50 hotels × 30 branches × one year of bookings), volume not
reduced.**

- **Before** (schema as of base, no load indexes, 0040 `fn_reservation_list`
  body): **FAIL** — 3 of 10 measured cells over the criterion:
  `fn_reservation_list` default page p95 **6521.7 ms**, date-range p95
  **1144.1 ms**, `fn_reservation_calendar` p95 **800.0 ms**.
- **After migrations 0101 + 0106**: **PASS** — every named function under the
  criterion at the same volume (worst p95 198.7 ms). Data row counts
  identical before/after; the 0106 function body returns byte-identical
  results to the 0040 body across a 23-case call matrix.

## Environment

| | |
|---|---|
| Server | PostgreSQL 16.6 (portable build, no root; sandbox has no system PostgreSQL 16) |
| Machine | 2 vCPU, 1.9 GiB RAM, 8.1 GB free disk, Linux 6.1 x86_64 sandbox |
| Config | shared_buffers 512MB, work_mem 32MB, max_wal_size 8GB; fsync=off **during fixture load only** |
| Timing | server-side `clock_timestamp()` around each call — PostgREST/network excluded |
| Schema | full migration chain: 101 files (0001–0097, with 0007 in four parts) plus 0101 and 0106 added here; applied with ON_ERROR_STOP |

The sandbox is weaker than production hardware: absolute numbers would move
on real hardware, the before/after relationships are the evidence.

## Volume (stated assumptions — the plan fixes 50×30×1y, not the booking rate)

- 20 units per branch (10 in each of 2 categories)
- **~75% average occupancy**, stays uniform 1–4 nights (avg ~2.5)
- ⇒ ~104 stays per room-year ⇒ **~2,080 bookings per branch-year ⇒ ~3.1M
  bookings** in the full fixture, each with primary guest, room allocation,
  money (receipt/deposit/refund vouchers) and charges (rent + tax + add-ons)
- rolling year: check-ins 2026-01-23 → 2027-01-22 (305 days back, 60 ahead),
  so «today» has realistic arrivals/departures/in-house data

Loaded and verified:

| table | rows |
|---|---|
| organizations | 51 (50 fixture + 1 demo seed) |
| branches | 1,501 |
| rooms | 30,010 |
| reservations | **3,142,232** (2,093 per branch, avg 2.50 nights) |
| reservation_guests | 3,142,233 |
| reservation_allocations | 3,142,230 |
| financial_vouchers | 3,233,303 |
| reservation_charges | 6,756,166 |
| guest_profiles | 627,871 |
| database size | **8,538 MB** |

Both GiST exclusion constraints (`alloc_no_overlap`,
`excl_reservation_source_ref`) were re-added after the bulk load and
validated: the fixture's room sequences are non-overlapping and source refs
unique by construction.

## Measurement design

- Three contexts: branch 7 of hotels 1, 27 and 50, called with the JWT claims
  of that hotel's **owner** account (sees every branch of the hotel, sees
  money). Calls run as the local superuser; every measured function is
  SECURITY DEFINER, so the outer role does not change row access — the JWT
  claims GUCs (`request.jwt.claim.sub`, `request.jwt.claims`) drive the
  permission logic exactly as in the app.
- Per cell (context × variant): 2 warmup calls, then 15 timed calls; each
  cell commits independently (`tests/load/21-measure-one.sql`), so an
  interrupted sweep keeps finished cells.
- Rounds: `before` (no 0101, no 0106) and `after0106` (0101 + 0106 applied,
  nothing else changed).

## Results (p50 / p95 / max, ms)

| function | variant | before p95 | before | after0106 p95 | after |
|---|---|---|---|---|---|
| fn_ops_daily_summary | today | 435.3 | PASS | 198.7 | PASS |
| fn_reservation_calendar | month (29 days) | 800.0 | **FAIL** | 30.5 | PASS |
| fn_ops_units_board | branch | 346.0 | PASS | 25.9 | PASS |
| fn_reservation_list | default page | 6521.7 | **FAIL** | 130.9 | PASS |
| fn_reservation_list | date range, sorted | 1144.1 | **FAIL** | 47.2 | PASS |
| fn_reservation_list | in-house today (arrival) | 70.8 | PASS | 34.9 | PASS |
| fn_platform_check_list | today (arrival) | 354.4 | PASS | 27.9 | PASS |
| fn_reports_finance | last 30 days | 356.7 | PASS | 58.8 | PASS |
| fn_reports_finance | full year | 378.0 | PASS | 63.8 | PASS |
| fn_account_ledger | last 30 days | 354.6 | PASS | 32.4 | PASS |

Samples: before = 60 per non-list cell (30/15/15 across ctx1/2/3), list cells
ctx1 only (30/15/15 — see Limits); after0106 = 45 per cell (15 × 3 contexts).

## Root causes and fixes

### 1. `fn_reservation_list` re-evaluated permission functions per row → migration 0106

The 0040 body calls `fn_user_branch_ids()`, `fn_sees_money()` and
`fn_has_role()` inside the main query's WHERE/SELECT, so PostgreSQL
re-evaluates them for every scanned row (STABLE functions are not hoisted
across the outer query). At 2,093 bookings/branch the default page cost p95
6,521.7 ms. Migration **0106** rewrites only the body of
`fn_reservation_list(uuid,jsonb,integer,integer)`: the user's branch ids go
into a MATERIALIZED CTE evaluated once, the money/role flags into
uncorrelated scalar subqueries evaluated once. Same signature, same columns,
same role/branch permission semantics; migration 0040 untouched.

Correctness gate: `scripts/load-roomai-equivalence.sh` captures a 23-case
call matrix (`tests/load/40-list-capture.sql`: owner/staff/accountant roles,
filters, pagination, sorting, non-member and cross-hotel isolation — a
non-member or foreign-hotel call returns `{total:0,rows:[]}`, not an error)
on a fresh 2-hotel database, with the 0040 body, then after applying 0106.
**Result: byte-identical output — PASS.**

### 2. No index on `branches(organization_id)` → migration 0101, index 1

`fn_user_branch_ids()` reads every branch of the caller's hotel; with 1,501
branches and no index each evaluation scanned the whole table. Every read
path calls it (often per row, see fix 1), so this tax was paid everywhere —
it accounts for most of the uniform before→after drop in the non-list
functions (e.g. ledger 354.6→32.4 ms). Probe measurement (100 calls):
~7.9 ms → ~0.06 ms per evaluation.
`create index idx_branches_organization on public.branches (organization_id);`

### 3. No branch-leading index on `reservation_allocations` → migration 0101, index 2

`fn_reservation_calendar`'s segments subquery filters allocations by one
branch and a date window. The table had indexes on (id), (reservation_id,
status), (room_id, from_date, to_date) for active rows, and
(organization_id) — nothing leading with branch_id — so the planner
parallel-seq-scanned all 3.14M rows per call (361 ms for the scan alone,
discarding ~1.05M rows per worker to keep ~60). Found only at full volume:
the calendar passed at smoke volume and kept failing (p95 800 ms) after fix 1
and fix 2 landed.
`create index idx_alloc_branch_dates on public.reservation_allocations (branch_id, from_date, to_date);`
Scan becomes a bitmap index scan: 361 ms → 0.24 ms; whole-call p95 800.0 →
30.5 ms. No further indexes were justified by the measurements.

## Data preservation

Row counts of the nine content tables captured before applying 0101/0106 and
after: **identical** (`0101-preservation.txt`). Both migrations are
index-only / function-body-only.

## EXPLAIN (ANALYZE, BUFFERS) evidence — after state

`tests/load/30-explain.sql`, ctx1: daily summary 116.1 ms, calendar 15.0 ms,
units board 9.6 ms, list default 66.8 ms, list date-range 22.4 ms, list
in-house 13.6 ms, platform check list 11.1 ms, finance 30d 27.3 ms, finance
year 34.1 ms, ledger 30d 15.6 ms. The calendar plan shows the bitmap index
scan on `idx_alloc_branch_dates`; the list plans show the MATERIALIZED
branch-ids CTE evaluated once.

## Runtimes

| stage | wall time |
|---|---|
| Fixture generation (50 hotels, ~3.1M bookings + money) | 39 min 35 s |
| Measurement round `before` (collectable cells) | ~9 min across sandbox sessions |
| Migrations 0101 + 0106 | < 1 s (indexes on empty-filter b-trees build in seconds even at 3.1M rows: idx_alloc_branch_dates ~2 s) |
| Measurement round `after0106` (all 30 cells) | 57 s |
| Equivalence gate (bootstrap + migrations + 2 hotels + 2 captures + diff) | ~2.5 min |

## Limits and what was not done (ما جُرب)

- **Before-round list timings are ctx1-only.** The 0040 body needed >60 s per
  measurement cell at full volume; under the sandbox's per-command time cap
  the ctx2/ctx3 list cells were not collectible for the old body. The ctx1
  samples (30/15/15) establish the failure; the fixed body is measured on all
  three contexts (45 samples/cell). All other cells have all three contexts
  in both rounds.
- **Sequential single-user measurement.** No concurrency: the criterion is a
  server-side latency bound per call, not a throughput target.
- **Server-side timing only.** PostgREST and network overhead are excluded by
  design.
- **Sandbox hardware** (2 vCPU / 1.9 GiB): weaker than production; treat
  absolute ms as a lower bound on achievable, the before/after relationship
  as the finding.
- The shared suite wiring (`tests/sql/run.sh`) was **not** modified; the
  optional gate lives in `tests/load/wiring.diff` (validated with
  `git apply --check`), for a maintainer to apply.

## Command log

| # | command / stage | result |
|---|---|---|
| 1 | Portable PostgreSQL 16.6 unpack, initdb, tuned start (socket-only, port 54333) | PASS |
| 2 | `bootstrap_db roomai_load` + apply chain except 0101/0106 | PASS |
| 3 | Fixture: `10-fixture-hotel.sql` × 50 hotels | PASS (39m35s; exclusion constraints re-added + validated) |
| 4 | Round `before`: `20-measure.sql` setup + `21-measure-one.sql` cells | PARTIAL — list cells ctx1 only; ctx2/3 list ما جُرب (see Limits) |
| 5 | Apply 0101 (`idx_branches_organization`) + row-count diff | PASS (identical) |
| 6 | Apply 0106 (fn_reservation_list hoist) | PASS |
| 7 | Round `after0106`: all 30 cells | PASS — all 10 rows p95 < 500 ms |
| 8 | Calendar still FAIL → diagnosis EXPLAIN → `idx_alloc_branch_dates` added to 0101, applied, calendar cells re-measured | PASS (p95 800.0 → 30.5 ms) |
| 9 | Row-count diff after final 0101 state | PASS (identical) |
| 10 | `30-explain.sql` evidence capture | PASS |
| 11 | `load-roomai-equivalence.sh` (staged: bootstrap+migrations, fixtures 90/91, capture → apply 0106 → capture → diff) | PASS — 23 cases byte-identical |
| 12 | `wiring.diff` validated with `git apply --check` | PASS (not applied) |
| 13 | Live requests / live DB / real emails | ما جُرب — out of scope by design (test-only) |
