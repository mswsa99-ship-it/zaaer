#!/usr/bin/env bash
# =====================================================================================
#  migration-check.sh — decision 41 / control G28 / test X10: a migration loses nothing and hides no conflict.
#
#  1. Builds a database exactly as production is: the migrations listed in supabase/production-applied.txt.
#  2. Writes a synthetic history on it (tests/sql/history_fixture.sql — invented data only).
#  3. Snapshots it (rows of every table, money by kind/status, reservation states and references, allocations).
#  4. Applies every migration not yet in production, in file order, then snapshots again.
#  5. Any value that changed fails the check, unless supabase/migration-exceptions.txt explains it
#     ("<key>: <reason>"). New tables are fine; a table that disappears is a failure.
#  6. Restore drill: dumps the migrated database, restores it into a fresh one and requires an identical
#     snapshot — the dump/restore path works for this schema.
#  The report is written to $VERIFY_OUT/migration-report.txt (default verify-results/; part of the test log).
#
#  After a migration is applied in production, add its version to supabase/production-applied.txt.
#  Usage: PGHOST=... PGUSER=postgres scripts/migration-check.sh
# =====================================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
DB="${MIG_DB:-airec_migcheck}"
RESTORED="${DB}_restored"
APPLIED="supabase/production-applied.txt"
EXCEPTIONS="supabase/migration-exceptions.txt"
OUTDIR="${VERIFY_OUT:-verify-results}"
REPORT="$OUTDIR/migration-report.txt"
mkdir -p "$OUTDIR"
source tests/sql/bootstrap.sh

apply() { psql -d "$1" -v ON_ERROR_STOP=1 -q -f "$2" 2>&1 | grep -v NOTICE || true; }

bootstrap_db "$DB" >/dev/null
pending=()
for f in supabase/migrations/*.sql; do
  v=$(basename "$f" | cut -d_ -f1)
  if grep -qx "$v" "$APPLIED"; then apply "$DB" "$f"; else pending+=("$f"); fi
done
if [[ ${#pending[@]} -eq 0 ]]; then
  echo "migration-check: nothing pending — production has every migration" | tee "$REPORT"
  exit 0
fi

psql -d "$DB" -v ON_ERROR_STOP=1 -q -f tests/sql/history_fixture.sql >/dev/null
psql -d "$DB" -v ON_ERROR_STOP=1 -q -v phase=before -f scripts/migration-snapshot.sql >/dev/null
for f in "${pending[@]}"; do echo "== applying pending $f"; apply "$DB" "$f"; done
psql -d "$DB" -v ON_ERROR_STOP=1 -q -v phase=after -f scripts/migration-snapshot.sql >/dev/null

# restore drill: dump the migrated database and restore it elsewhere
psql -q -c "drop database if exists $RESTORED;" -c "create database $RESTORED;" >/dev/null
pg_dump -d "$DB" --no-owner --format=custom --file "$OUTDIR/migration-drill.dump"
pg_restore -d "$RESTORED" --no-owner "$OUTDIR/migration-drill.dump" 2>&1 | grep -v "already exists" || true
rm -f "$OUTDIR/migration-drill.dump"   # synthetic data only, but a dump is never kept with the run's results
psql -d "$RESTORED" -v ON_ERROR_STOP=1 -q -v phase=restored -f scripts/migration-snapshot.sql >/dev/null

{
  echo "Migration check — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Pending migrations checked:"; for f in "${pending[@]}"; do echo "  $(basename "$f")"; done
  echo
  echo "key | before | after"
  psql -d "$DB" -At -F ' | ' -c "select k, v, coalesce((select a.v from _mig_snapshot a where a.phase = 'after' and a.k = b.k), '(missing)')
                                   from _mig_snapshot b where b.phase = 'before' order by k"
} > "$REPORT"

changed=$(psql -d "$DB" -At -c "select b.k from _mig_snapshot b left join _mig_snapshot a on a.phase = 'after' and a.k = b.k
                                 where b.phase = 'before' and a.v is distinct from b.v order by 1")
unexplained=()
while IFS= read -r k; do
  [[ -z "$k" ]] && continue
  if [[ -f "$EXCEPTIONS" ]] && grep -q "^${k}:" "$EXCEPTIONS"; then echo "explained change: $k — $(grep "^${k}:" "$EXCEPTIONS" | head -1 | cut -d: -f2-)" >> "$REPORT"
  else unexplained+=("$k"); fi
done <<< "$changed"

drill=$(psql -d "$RESTORED" -At -c "select count(*) from _mig_snapshot a left join _mig_snapshot r on r.phase = 'restored' and r.k = a.k
                                    where a.phase = 'after' and r.v is distinct from a.v")
echo >> "$REPORT"
echo "restore drill: $([[ "$drill" == "0" ]] && echo "identical after dump and restore" || echo "$drill values differ")" >> "$REPORT"

if [[ ${#unexplained[@]} -gt 0 || "$drill" != "0" ]]; then
  echo "FAIL migration-check:"; for k in "${unexplained[@]}"; do echo "  changed without explanation: $k"; done
  [[ "$drill" != "0" ]] && echo "  restore drill: $drill values differ"
  echo "(report: $REPORT)"
  exit 1
fi
echo "PASS migration-check: ${#pending[@]} pending migration(s), nothing lost or changed, restore drill identical (report: $REPORT)"
