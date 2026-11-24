#!/usr/bin/env bash
# Bounded reproducible candidate check, never a complete release/isolation gate.
# Requires an explicit local Unix socket and a NEW disposable database. Does not drop/reuse any database.
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ ${PGHOST:-} = /* && ${PGPORT:-} =~ ^[0-9]+$ && ${TEST_DB:-} =~ ^iso_candidate_[a-z0-9_]+$ ]] || { echo 'Requires PGHOST local socket, numeric PGPORT and NEW TEST_DB=iso_candidate_*'; exit 2; }
[[ -z ${PGSERVICE:-} && -z ${PGDATABASE:-} && -z ${PGHOSTADDR:-} ]] || { echo 'Connection override refused'; exit 2; }
[[ $(psql -XAt -d postgres -v ON_ERROR_STOP=1 -c 'select inet_server_addr() is null') = t ]] || { echo 'Nonlocal connection refused'; exit 2; }
[[ $(psql -XAt -d postgres -v ON_ERROR_STOP=1 -v db="$TEST_DB" <<'SQL'
select count(*) from pg_database where datname = :'db';
SQL
) = 0 ]] || { echo 'Database already exists, refusing to reuse or drop it'; exit 2; }
OUT=${ISOLATION_OUT:-/tmp/roomai-local-candidate-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"
{
 echo 'BOUNDED LOCAL CHECK ONLY. No complete matrix or release acceptance.'
 git rev-parse HEAD
 git status --short
 psql -XAt -d postgres -c 'select version()'
} | tee "$OUT/context.log"
source tests/sql/bootstrap.sh
bootstrap_db "$TEST_DB" > "$OUT/bootstrap.log" 2>&1
for f in supabase/migrations/*.sql; do
 echo "$f" >> "$OUT/migrations.log"
 psql -X -v ON_ERROR_STOP=1 -d "$TEST_DB" -f "$f" >> "$OUT/migrations.log" 2>&1
done
psql -X -v ON_ERROR_STOP=1 -d "$TEST_DB" -f tests/sql/branch_read_boundaries_tests.sql > "$OUT/branch-boundary.log" 2>&1
psql -X -v ON_ERROR_STOP=1 -d "$TEST_DB" -f tests/isolation/engine.sql -f tests/isolation/branch-fields-tests.sql -f tests/isolation/provenance-probe-tests.sql -f tests/isolation/public-oracle-proof.sql > "$OUT/engine-provenance.log" 2>&1
psql -X -v ON_ERROR_STOP=1 -d "$TEST_DB" -f tests/isolation/guest-mutator-proof.sql > "$OUT/guest-mutator.log" 2>&1
psql -X -v ON_ERROR_STOP=1 -d "$TEST_DB" -f tests/isolation/guest-checkout-proof.sql > "$OUT/guest-checkout.log" 2>&1
node tests/isolation/rpc-inventory-check.mjs | tee "$OUT/inventory.log"
node --test tests/isolation/rpc-inventory-check.test.mjs > "$OUT/static-invariants.log" 2>&1
npx vitest run tests/unit/isolation_execution_report.test.ts tests/unit/isolation_skip_identity.test.ts tests/unit/isolation_matrix_generator.test.ts tests/unit/staff_branch_metadata.test.ts > "$OUT/unit.log" 2>&1
printf 'Bounded local candidate checks completed. Evidence: %s\nDisposable database retained for inspection: %s\nNot a release gate.\n' "$OUT" "$TEST_DB"
