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
echo "== running core money tests (methods, accounts, settlements, tax zero — Phase 1)"
psql -d "$DB" -f tests/sql/money_core_tests.sql
echo "== running rates tests (0030: price calendar, weekly/monthly, nights, discount limits)"
psql -d "$DB" -f tests/sql/rates_tests.sql
echo "== running stay cycle tests (0032–0033: arrival, Shomoos, night-by-night payment, check-out, inspection, corrections, closing)"
psql -d "$DB" -f tests/sql/stay_cycle_tests.sql
echo "== running invoice and review tests (0036: partial and automatic invoices, edits with versions, voucher correction, the review list)"
psql -d "$DB" -f tests/sql/invoices_review_tests.sql
echo "== running monitoring tests (0037: the seven checks, once each, the owner's throttle)"
psql -d "$DB" -f tests/sql/monitors_tests.sql
echo "== running guest and platform tests (0038–0039: two paths for guest data, bans, ratings, platform fields, groups, the stay summary, branch fields)"
psql -d "$DB" -f tests/sql/guests_platforms_tests.sql
echo "== running lists, calendar, log, exports, report filters, task times, staff editor, forced sign-out and capability usage tests (0040–0041, Phase 6)"
psql -d "$DB" -f tests/sql/lists_reports_tests.sql
echo "== running permissions matrix tests (0043: the owner's editable matrix, decision 71; self-escalation, decision 44)"
psql -d "$DB" -f tests/sql/permissions_tests.sql
echo "== running Phase 7 acceptance tests (decisions 37, 38, 44, 53: branch isolation X04, G20 with manual payments, no self-escalation, D05)"
psql -d "$DB" -f tests/sql/acceptance_tests.sql
echo "== running WhatsApp channel and data purge tests (last: the purge deletes data)"
psql -d "$DB" -f tests/sql/whatsapp_purge_tests.sql
