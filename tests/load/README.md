# Load test — item 2.10 (الأداء بحجم كبير)

Test-only. A throwaway local PostgreSQL 16 database, synthetic data, no live
requests, no live database, no emails.

## Run

```sh
# prerequisite: a local PostgreSQL 16 server (createdb rights)
PGHOST=/tmp PGPORT=54333 PGUSER=postgres scripts/load-roomai.sh /tmp/load-roomai 50
```

The driver (`scripts/load-roomai.sh`):

1. creates a fresh database shaped like the hosted project (tests/sql/bootstrap.sh);
2. applies every migration except 0101 and 0106;
3. generates the fixture: **50 hotels × 30 branches × one rolling year of
   bookings** (`tests/load/10-fixture-hotel.sql`, one run per hotel);
4. measures the main read functions with real session contexts (staff JWT
   claims of the hotel's owner): 2 warmup + 15 measured calls per variant per
   context, 3 branch contexts in 3 hotels. `tests/load/20-measure.sql` is the
   setup (contexts, variants, `load_run_cell`); `tests/load/22-measure-all.sql`
   sweeps every cell, `tests/load/21-measure-one.sql` measures one cell
   (resumable — each cell commits on its own), `tests/load/23-measure-summary.sql`
   renders p50/p95/max per round;
5. applies migrations **0101** (load-driven indexes) and **0106**
   (fn_reservation_list hoist) between the before/after0106 rounds and verifies
   row counts are identical (data preservation);
6. captures EXPLAIN (ANALYZE, BUFFERS) for every measured function
   (`tests/load/30-explain.sql`).

The companion gate `scripts/load-roomai-equivalence.sh` builds a small
database (2 fixture hotels), captures the fn_reservation_list call matrix
(`tests/load/40-list-capture.sql` — roles, filters, pagination, membership,
cross-hotel isolation) with the 0040 body, applies 0106, captures again and
diffs: the two bodies must return byte-identical results.

Criterion: **p95 < 500 ms for every named function**, measured server-side
(clock_timestamp around the call — PostgREST/network overhead excluded).

## Volume assumptions (stated, plan fixes 50×30×1y but not the booking rate)

- 20 units per branch (10 in each of 2 categories)
- ~75% average occupancy, average stay ~2.5 nights (uniform 1–4)
- ⇒ ~104 stays per room-year ⇒ **~2,080 bookings per branch-year ⇒ ~3.1M
  bookings** in the full fixture, each with its primary guest, allocation,
  money (receipt/deposit/refund vouchers) and charges (rent + tax + add-ons)

The year is rolling: 305 days back, 60 days ahead, so «today» has realistic
arrivals/departures/in-house data.

## Bulk-load note

The fixture sets `session_replication_role = replica` while bulk-inserting:
the row-level business triggers (tax snapshot, voucher GL mirror, deposit
gate) are writers' concerns, and every value they would derive is written
explicitly in the same shape. Unique/exclusion/CHECK constraints stay
enforced (index/check-enforced, not trigger-enforced): room sequences are
non-overlapping by construction (`alloc_no_overlap` holds) and every natural
key is unique by construction.
