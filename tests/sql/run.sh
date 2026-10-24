#!/usr/bin/env bash
# Runs all migrations + security tests on a throwaway local Postgres database.
# Usage: PGHOST=... PGPORT=... PGUSER=postgres tests/sql/run.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${TEST_DB:-airec_test}"
source "$(dirname "$0")/bootstrap.sh"
bootstrap_db "$DB"
for f in supabase/migrations/*.sql; do
  echo "== applying $f"
  psql -d "$DB" -v ON_ERROR_STOP=1 -q -f "$f" 2>&1 | grep -v NOTICE || true
done
echo "== running platform tests (hosted-Supabase compatibility)"
psql -d "$DB" -f tests/sql/platform_tests.sql
echo "== running security tests"
psql -d "$DB" -f tests/sql/security_tests.sql
echo "== running core acceptance tests"
psql -d "$DB" -f tests/sql/core_tests.sql
echo "== running knowledge-base tests"
psql -d "$DB" -f tests/sql/knowledge_tests.sql
echo "== running reservation-parity tests"
psql -d "$DB" -f tests/sql/parity_tests.sql
echo "== running external-review fix tests"
psql -d "$DB" -f tests/sql/review_tests.sql
echo "== running AI settings tests"
psql -d "$DB" -f tests/sql/ai_settings_tests.sql
echo "== running branch-local date tests"
psql -d "$DB" -f tests/sql/local_date_tests.sql
echo "== running phone lookup tests"
psql -d "$DB" -f tests/sql/phone_lookup_tests.sql
echo "== running WhatsApp Web bridge tests"
psql -d "$DB" -f tests/sql/whatsapp_bridge_tests.sql
echo "== running key-box code tests («الرموز»)"
psql -d "$DB" -f tests/sql/keybox_codes_tests.sql
echo "== running audit trace and mid-operation failure tests (G22, X08)"
psql -d "$DB" -f tests/sql/audit_trace_tests.sql
echo "== running WhatsApp channel and data purge tests (last: the purge deletes data)"
psql -d "$DB" -f tests/sql/whatsapp_purge_tests.sql
