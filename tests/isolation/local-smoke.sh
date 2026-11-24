#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# Explicit socket and disposable database prefix are mandatory, no network DSN accepted.
[[ ${PGHOST:-} = /* && ${PGPORT:-} =~ ^[0-9]+$ && ${TEST_DB:-} =~ ^iso_[a-z0-9_]+$ ]] || { echo 'Requires explicit local PGHOST socket, PGPORT, TEST_DB=iso_*'; exit 2; }
[[ -z ${PGSERVICE:-} && -z ${PGDATABASE:-} && -z ${PGHOSTADDR:-} ]] || { echo 'PGSERVICE/PGDATABASE/PGHOSTADDR override refused'; exit 2; }
[[ $(psql -XAt -d postgres -v ON_ERROR_STOP=1 -c 'select inet_server_addr() is null') = t ]] || { echo 'Non-socket database connection refused'; exit 2; }
OUT=${ISOLATION_OUT:-/tmp/roomai-isolation-evidence}
mkdir -p "$OUT"
source tests/sql/bootstrap.sh
bootstrap_db "$TEST_DB" > "$OUT/bootstrap.log" 2>&1
for f in supabase/migrations/*.sql; do
  echo "$f" >> "$OUT/migrations.log"
  psql -X -d "$TEST_DB" -v ON_ERROR_STOP=1 -q -f "$f" >> "$OUT/migrations.log" 2>&1
done
psql -XAt -d "$TEST_DB" -v ON_ERROR_STOP=1 -f tests/isolation/catalog.sql > "$OUT/catalog.json"
node tests/isolation/scope-sql.mjs > "$OUT/scope.sql"
psql -X -d "$TEST_DB" -v ON_ERROR_STOP=1 -f tests/isolation/engine.sql > "$OUT/engine.log" 2>&1
psql -X -d "$TEST_DB" -v ON_ERROR_STOP=1 -f "$OUT/scope.sql" >> "$OUT/engine.log" 2>&1
psql -X -d "$TEST_DB" -v ON_ERROR_STOP=1 -f tests/isolation/fixtures.sql > "$OUT/fixtures.log" 2>&1
psql -XAt -d "$TEST_DB" -v ON_ERROR_STOP=1 -c 'select coalesce(jsonb_agg(t), '\''[]'\''::jsonb) from iso.seed_error t' > "$OUT/seed-errors.json"
psql -XAt -d "$TEST_DB" -v ON_ERROR_STOP=1 -c 'select coalesce(jsonb_agg(t), '\''[]'\''::jsonb) from iso.created t' > "$OUT/fixtures.json"
psql -X -d "$TEST_DB" -v ON_ERROR_STOP=1 -f tests/isolation/guest-links.sql > "$OUT/guest-links.log" 2>&1
psql -XAt -d "$TEST_DB" -v ON_ERROR_STOP=1 -c 'select coalesce(jsonb_agg(t), '\''[]'\''::jsonb) from iso.guest_result t' > "$OUT/guest-links.json"
# General RPC adapters are not invoked. Any limited run remains incomplete, even if every observed denial is correct.
psql -XAt -d "$TEST_DB" -v ON_ERROR_STOP=1 -c 'select iso.emit_wrapper()' > "$OUT/probes.sql"
psql -X -d "$TEST_DB" -v ON_ERROR_STOP=1 -f "$OUT/probes.sql" > "$OUT/probes.log" 2>&1
psql -XAt -d "$TEST_DB" -v ON_ERROR_STOP=1 -c 'select coalesce(jsonb_agg(t), '\''[]'\''::jsonb) from iso.probe_result t' > "$OUT/probes.json"
node tests/isolation/report.mjs "$OUT"
