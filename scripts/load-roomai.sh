#!/usr/bin/env bash
# =====================================================================
# Item 2.10 load test driver. Test-only: a throwaway local PostgreSQL 16
# database, synthetic data, no live requests.
#
# Prerequisites: a running PostgreSQL 16 server the user can create
# databases on (PGHOST/PGPORT/PGUSER/PGPASSWORD as usual), psql on PATH.
#
# Usage:
#   PGHOST=/tmp PGPORT=54333 PGUSER=postgres \
#     scripts/load-roomai.sh [out-dir] [hotels] [year-start]
# Defaults: out-dir /tmp/load-roomai, 50 hotels, year-start = 305 days ago
# (365 check-in days ending 60 days in the future, so arrival screens have
# realistic data «today»).
#
# Stages: fresh DB -> all migrations except 0101/0106 -> synthetic fixture
# (50 x 30 x 1y) -> ANALYZE -> measurement round "before" -> migrations
# 0101 (indexes) and 0106 (fn_reservation_list hoist) -> measurement round
# "after0106" -> EXPLAIN (ANALYZE, BUFFERS) evidence -> volume/environment
# capture. Data-row counts are captured before and after 0101+0106 to prove
# the migrations preserve data. scripts/load-roomai-equivalence.sh is the
# companion gate proving the 0106 body returns the same results as 0040.
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-/tmp/load-roomai}"
HOTELS="${2:-50}"
YEAR_START="${3:-$(date -d '305 days ago' +%F)}"
DB="${LOAD_DB:-roomai_load}"
PSQL="psql -X -q -v ON_ERROR_STOP=1 -d $DB"

mkdir -p "$OUT"
echo "== load test 2.10: out=$OUT hotels=$HOTELS year_start=$YEAR_START db=$DB"
date -Is | tee "$OUT/run-started.txt"

# ---- fresh database shaped like the hosted project (shared bootstrap) ----
source tests/sql/bootstrap.sh
bootstrap_db "$DB" >"$OUT/bootstrap.log" 2>&1
echo "== applying migrations"
for f in supabase/migrations/*.sql; do
  case "$f" in
    *_0101_load_indexes.sql | *_0106_reservation_list_hoist.sql) : ;;  # 0101+0106 are applied later, between the before/after rounds
    *) psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f "$f" >>"$OUT/migrations.log" 2>&1 ;;
  esac
done

# ---- synthetic fixture: HOTELS hotels x 30 branches x one year ----
echo "== generating fixture ($HOTELS hotels)"
date -Is > "$OUT/fixture-started.txt"
for h in $(seq 1 "$HOTELS"); do
  $PSQL -v hotel="$h" -v year_start="$YEAR_START" -f tests/load/10-fixture-hotel.sql \
    >"$OUT/fixture-h$h.log" 2>&1
  if [ $((h % 10)) -eq 0 ]; then echo "  .. hotel $h done $(date -Is)"; fi
done
date -Is > "$OUT/fixture-finished.txt"
$PSQL -c "vacuum analyze reservations, reservation_guests, financial_vouchers, reservation_charges, reservation_allocations, rooms, branches, branch_memberships;" >>"$OUT/analyze.log" 2>&1
$PSQL -c "analyze;" >>"$OUT/analyze.log" 2>&1

# ---- volume + environment capture ----
{
  echo "## environment"
  date -Is
  echo "server: $(psql -X -tA -d "$DB" -c 'show server_version;')"
  echo "shared_buffers: $(psql -X -tA -d "$DB" -c 'show shared_buffers;')"
  echo "work_mem: $(psql -X -tA -d "$DB" -c 'show work_mem;')"
  echo "cpus: $(nproc)  memory: $(free -h | awk '/^Mem:/{print $2}')  disk_free: $(df -h /tmp | awk 'NR==2{print $4}')"
  uname -a
  echo
  echo "## volume"
  psql -X -d "$DB" -c "
    select 'organizations' as t, count(*) from organizations union all
    select 'branches', count(*) from branches union all
    select 'rooms', count(*) from rooms union all
    select 'reservations', count(*) from reservations union all
    select 'reservation_guests', count(*) from reservation_guests union all
    select 'reservation_allocations', count(*) from reservation_allocations union all
    select 'financial_vouchers', count(*) from financial_vouchers union all
    select 'reservation_charges', count(*) from reservation_charges union all
    select 'guest_profiles', count(*) from guest_profiles order by 1;"
  psql -X -d "$DB" -c "select pg_size_pretty(pg_database_size(current_database())) as db_size;"
  psql -X -d "$DB" -c "select min(check_in) as first_checkin, max(check_in) as last_checkin,
    round(avg(check_out - check_in), 2) as avg_nights,
    round(count(*)::numeric / nullif((select count(*) from branches), 0), 0) as bookings_per_branch
    from reservations;"
  echo "fixture started:  $(cat "$OUT/fixture-started.txt")"
  echo "fixture finished: $(cat "$OUT/fixture-finished.txt")"
} > "$OUT/volume-env.txt" 2>&1

# ---- data snapshot before 0101 (preservation evidence) ----
$PSQL -tA -c "
  select string_agg(t||'='||c, ' ' order by t) from (
    select 'organizations' t, count(*) c from organizations union all
    select 'branches', count(*) from branches union all
    select 'rooms', count(*) from rooms union all
    select 'reservations', count(*) from reservations union all
    select 'reservation_guests', count(*) from reservation_guests union all
    select 'reservation_allocations', count(*) from reservation_allocations union all
    select 'financial_vouchers', count(*) from financial_vouchers union all
    select 'reservation_charges', count(*) from reservation_charges union all
    select 'guest_profiles', count(*) from guest_profiles) s;" \
  > "$OUT/rowcounts-before-0101.txt"
cp "$OUT/rowcounts-before-0101.txt" "$OUT/rowcounts-before-0101.txt.orig"

# ---- measurement setup + round A (before 0101/0106) ----
echo "== measurement round: before"
$PSQL -f tests/load/20-measure.sql > /dev/null 2>&1   # harness: contexts, variants, load_run_cell
date -Is > "$OUT/measure-before-started.txt"
$PSQL -v round=before -f tests/load/22-measure-all.sql > "$OUT/measure-before.log" 2>&1
date -Is > "$OUT/measure-before-finished.txt"
$PSQL -v round=before -f tests/load/23-measure-summary.sql > "$OUT/results-before.txt" 2>&1

# ---- migrations 0101 (load-driven indexes) + 0106 (fn_reservation_list hoist) ----
echo "== applying migrations 0101 and 0106"
$PSQL -f supabase/migrations/20261124170000_0101_load_indexes.sql > "$OUT/migration-0101.log" 2>&1
$PSQL -f supabase/migrations/20261124180000_0106_reservation_list_hoist.sql > "$OUT/migration-0106.log" 2>&1
$PSQL -tA -c "
  select string_agg(t||'='||c, ' ' order by t) from (
    select 'organizations' t, count(*) c from organizations union all
    select 'branches', count(*) from branches union all
    select 'rooms', count(*) from rooms union all
    select 'reservations', count(*) from reservations union all
    select 'reservation_guests', count(*) from reservation_guests union all
    select 'reservation_allocations', count(*) from reservation_allocations union all
    select 'financial_vouchers', count(*) from financial_vouchers union all
    select 'reservation_charges', count(*) from reservation_charges union all
    select 'guest_profiles', count(*) from guest_profiles) s;" \
  > "$OUT/rowcounts-after-0101.txt"
if diff -q "$OUT/rowcounts-before-0101.txt" "$OUT/rowcounts-after-0101.txt" >/dev/null; then
  echo "0101+0106 data preservation: IDENTICAL row counts" | tee "$OUT/0101-preservation.txt"
else
  echo "0101+0106 data preservation: ROW COUNTS CHANGED (investigate)" | tee "$OUT/0101-preservation.txt"
fi

# ---- measurement round B (after 0101+0106) ----
echo "== measurement round: after0106"
date -Is > "$OUT/measure-after0106-started.txt"
$PSQL -v round=after0106 -f tests/load/22-measure-all.sql > "$OUT/measure-after0106.log" 2>&1
date -Is > "$OUT/measure-after0106-finished.txt"
$PSQL -v round=after0106 -f tests/load/23-measure-summary.sql > "$OUT/results-after0106.txt" 2>&1

# ---- EXPLAIN evidence ----
echo "== explain evidence"
$PSQL -f tests/load/30-explain.sql > "$OUT/explain.txt" 2>&1

date -Is | tee "$OUT/run-finished.txt"
echo "== done: $OUT"
