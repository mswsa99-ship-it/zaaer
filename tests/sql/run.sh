#!/usr/bin/env bash
# Runs all migrations + security tests on a throwaway local Postgres database.
# Usage: PGHOST=... PGPORT=... PGUSER=postgres tests/sql/run.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${TEST_DB:-airec_test}"
source "$(dirname "$0")/bootstrap.sh"
bootstrap_db "$DB"
# A test file fails the suite when psql printed an error or the file printed a FAIL row, not only when its own end
# check raised: a block that breaks records nothing, and a check that never ran must not pass for one that passed
# (23 Nov 2026: TN20 named a variable "both", a reserved word; its block failed and the suite still exited 0).
run_tests() {
  local out="${TMPDIR:-/tmp}/sql-tests-$$.log"
  psql -d "$DB" -f "$1" 2>&1 | tee "$out"
  if grep -qE '^psql:.*ERROR:' "$out" || grep -qE '^[[:space:]]*FAIL[[:space:]]*\|' "$out"; then
    echo "SQL TESTS FAILED: $1 printed an error or a FAIL row (above)"; rm -f "$out"; exit 1
  fi
  rm -f "$out"
}
for f in supabase/migrations/*.sql; do
  echo "== applying $f"
  psql -d "$DB" -v ON_ERROR_STOP=1 -q -f "$f" 2>&1 | grep -v NOTICE || true
done
echo "== running platform tests (hosted-Supabase compatibility)"
run_tests tests/sql/platform_tests.sql
echo "== running security tests"
run_tests tests/sql/security_tests.sql
echo "== running core acceptance tests"
run_tests tests/sql/core_tests.sql
echo "== running knowledge-base tests"
run_tests tests/sql/knowledge_tests.sql
echo "== running reservation-parity tests"
run_tests tests/sql/parity_tests.sql
echo "== running external-review fix tests"
run_tests tests/sql/review_tests.sql
echo "== running AI settings tests"
run_tests tests/sql/ai_settings_tests.sql
echo "== running branch-local date tests"
run_tests tests/sql/local_date_tests.sql
echo "== running phone lookup tests"
run_tests tests/sql/phone_lookup_tests.sql
echo "== running WhatsApp Web bridge tests"
run_tests tests/sql/whatsapp_bridge_tests.sql
echo "== running key-box code tests («الرموز»)"
run_tests tests/sql/keybox_codes_tests.sql
echo "== running audit trace and mid-operation failure tests (G22, X08)"
run_tests tests/sql/audit_trace_tests.sql
echo "== running core money tests (methods, accounts, settlements, tax zero — Phase 1)"
run_tests tests/sql/money_core_tests.sql
echo "== running rates tests (0030: price calendar, weekly/monthly, nights, discount limits)"
run_tests tests/sql/rates_tests.sql
echo "== running stay cycle tests (0032–0033: arrival, Shomoos, night-by-night payment, check-out, inspection, corrections, closing)"
run_tests tests/sql/stay_cycle_tests.sql
echo "== running invoice and review tests (0036: partial and automatic invoices, edits with versions, voucher correction, the review list)"
run_tests tests/sql/invoices_review_tests.sql
echo "== running monitoring tests (0037: the seven checks, once each, the owner's throttle)"
run_tests tests/sql/monitors_tests.sql
echo "== running guest and platform tests (0038–0039: two paths for guest data, bans, ratings, platform fields, groups, the stay summary, branch fields)"
run_tests tests/sql/guests_platforms_tests.sql
echo "== running lists, calendar, log, exports, report filters, task times, staff editor, forced sign-out and capability usage tests (0040–0041, Phase 6)"
run_tests tests/sql/lists_reports_tests.sql
echo "== running permissions matrix tests (0043: the owner's editable matrix, decision 71; self-escalation, decision 44)"
run_tests tests/sql/permissions_tests.sql
echo "== running Phase 7 acceptance tests (decisions 37, 38, 44, 53: branch isolation X04, G20 with manual payments, no self-escalation, D05)"
run_tests tests/sql/acceptance_tests.sql
echo "== running the review's Phase 1 tests (0052–0054: tokens by branch, money only, the AI guard, the bridge key, the front desk, money)"
run_tests tests/sql/audit_phase1_tests.sql
echo "== running review phase 2 tests (0055: the organisation, price ranges, inventory, unit numbers, invites, branches, knowledge)"
run_tests tests/sql/audit_phase2_tests.sql
echo "== running review phase 3a tests (0057: past stays, what an ended booking owes, weak key-box codes)"
run_tests tests/sql/audit_phase3_tests.sql
echo "== running review phase 4a tests (0059: the platforms apart, both occupancies, the collection rate, the period limit, every day)"
run_tests tests/sql/audit_phase4_tests.sql
echo "== running review phase 4b tests (0060: near names in the guest search, the objection and the undo on the review list)"
run_tests tests/sql/audit_phase4b_tests.sql
echo "== running review phase 5 tests (0061: Arabic counts and money in server texts, prices and filters by role, the guest phone, the lookup lock, visitor columns)"
run_tests tests/sql/audit_phase5_tests.sql
echo "== running accounting A1 tests (0062: one box and one bank account per branch, the account number rule, no posting on another branch's account)"
run_tests tests/sql/accounting_a1_tests.sql
echo "== running accounting A2/A3 tests (0063: the day's closing computed, the mandatory review, the edit window, the request after it)"
run_tests tests/sql/accounting_a2_tests.sql
echo "== running accounting A4 tests (0064: the expense voucher and its receipt, the ledger and its running balance)"
run_tests tests/sql/accounting_a4_tests.sql
echo "== running accounting A5 tests (0065: the double entry, trial balance, statements, month lock)"
run_tests tests/sql/accounting_a5_tests.sql
echo "== running accounting A6/A7 tests (0066: the bank's messages by mail, raw first, one movement, only the app's mail)"
run_tests tests/sql/accounting_a6_tests.sql
echo "== running accounting A8 tests (0067: matching the bank's movements, once, in suspense meanwhile)"
run_tests tests/sql/accounting_a8_tests.sql
echo "== running products W1 tests (0068: the catalogue by branch, ordering in the stay, payment then voucher then delivery task)"
run_tests tests/sql/products_w1_tests.sql
echo "== running tax W2 tests (0069: off by default, a switch and a rate for each of rent, services and products, what was before stays)"
run_tests tests/sql/tax_w2_tests.sql
echo "== running guest journey tests (0070: W3 the check-out options, W4 the departure and the deposit, W5 the review, W6 the alert rules)"
run_tests tests/sql/journey_tests.sql
echo "== running unit guides W7 tests (0071: a unit's way in and out shown only once approved)"
run_tests tests/sql/guides_w7_tests.sql
echo "== running accounts tests (0074: security events of sign-in and passwords, who has an account, the invitation's target)"
run_tests tests/sql/accounts_tests.sql
echo "== running unit licence tests (0075: the licence number read by the owner, the manager and the supervisor only, and changed with «definitions»)"
run_tests tests/sql/unit_license_tests.sql
echo "== running tenancy tests (0076: every row says its hotel, every branch row its branch; a row naming another hotel is refused)"
run_tests tests/sql/tenancy_tests.sql
echo "== running function scope tests (0078: every function a visitor or a staff member may call keeps to the hotel and the branch; no row points to another hotel)"
run_tests tests/sql/function_scope_tests.sql
echo "== running WhatsApp channel and data purge tests (the purge deletes data)"
run_tests tests/sql/whatsapp_purge_tests.sql
echo "== running trial data tests (0072, 0073: the example catalogue, and erasing all the trial data — last of all: it erases what the others left)"
run_tests tests/sql/purge_trial_tests.sql
