-- 0101 — the index the 2.10 load test justifies (item «الأداء بحجم كبير»: 50 hotels × 30 branches × one year
-- of bookings, the main read functions under 500 ms p95; evidence in acceptance/load-report.md).
--
-- fn_user_branch_ids() decides every branch check in the read paths (lists, summaries, boards, ledgers). For an
-- owner it reads every branch of the hotel, and the read functions re-evaluate it per row. Without an index on
-- branches(organization_id) each evaluation scans the whole branches table; at the 2.10 fixture's 1,501 branches
-- that dominated fn_user_branch_ids' own cost. The measured call-chain effect (50 hotels × 30 branches loaded,
-- 100 calls): ~7.9 ms → ~0.06 ms per evaluation (see the report's before/after table).
--
-- Index-only change: no data is written, no function changes. Row counts before/after are captured identical by
-- scripts/load-roomai.sh (out/0101-preservation.txt).

create index if not exists idx_branches_organization on public.branches (organization_id);

-- fn_reservation_calendar's segments subquery filters reservation_allocations by one branch and a
-- from_date/to_date window. The table only had indexes on (id), (reservation_id, status), (room_id, from_date,
-- to_date) for active rows, and (organization_id); nothing leads with branch_id, so the planner fell back to a
-- parallel sequential scan of the whole table and discarded ~1.05M rows per worker to keep ~60. Measured at the
-- 2.10 fixture (3,142,230 allocations): segments scan ~361 ms, whole call p95 800 ms before this index; with the
-- index the call drops under the criterion (evidence in acceptance/load-report.md, fn_reservation_calendar row).

create index if not exists idx_alloc_branch_dates on public.reservation_allocations (branch_id, from_date, to_date);
