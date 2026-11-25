#!/usr/bin/env bash
# Scoped release gate for the changed 0114-0122 read/audit boundaries. It EXECUTES suites; it never prints success
# without running them. It is NOT the Plan 2.11 full matrix (see acceptance-gate.sh, which stays INCOMPLETE).
#   1. builds a fresh database from every migration (same bootstrap as tests/sql/run.sh)
#   2. baseline: each listed suite, run on its own clone, must print exactly the expected number of PASS rows,
#      no FAIL row and no psql error
#   3. guard-removed mutants: with one guard undone on a clone, the matching suite MUST print a FAIL row
#      (a suite that stays green without its guard proves nothing, so that fails this gate)
# Suites that only run in sequence (history_details 0125, individual_permission_drafts 0121, 0123, 0124) are covered
# by the `sql` gate (tests/sql/run.sh), not here. Exit 1 on anything unexpected.
set -uo pipefail
cd "$(dirname "$0")/../.."
BASE="${SCOPED_DB:-airec_scoped}"
source tests/sql/bootstrap.sh
bootstrap_db "$BASE"
for f in supabase/migrations/*.sql; do
  psql -d "$BASE" -v ON_ERROR_STOP=1 -q -f "$f" >/dev/null 2>/tmp/scoped-mig.err || { echo "SCOPED GATE FAILED: migration $f"; cat /tmp/scoped-mig.err; exit 1; }
done
fail=0
SEED_WANT_PASS=61   # measured: tests/sql/security_tests.sql on a correctly configured v9e clone prints 61 PASS, 0 FAIL, 0 psql ERROR
clone() { # db [seed-sql]: a fresh copy of the migrated database; the 0122 suite needs the rows tests/sql/security_tests.sql leaves
  # CREATE DATABASE ... TEMPLATE does not copy ALTER DATABASE settings (keys, time zone, search_path, request.headers): re-apply them
  # and fail closed if any is missing, so a degraded clone can never produce a baseline.
  psql -q -c "drop database if exists $1" -c "create database $1 template $BASE" >/dev/null 2>&1 || { echo "SCOPED GATE FAILED: cannot clone $BASE to $1"; return 1; }
  apply_db_settings "$1" >/dev/null 2>&1 || { echo "SCOPED GATE FAILED: apply_db_settings on $1"; return 1; }
  assert_db_settings "$1" || return 1
  if [ -n "${2:-}" ]; then
    # the seed output is no longer discarded: it must print exactly the measured PASS rows, no FAIL row and no psql error
    local sout sp sf se; sout=$(psql -X -d "$1" -f "$2" 2>&1)
    sp=$(grep -cE '^[[:space:]]*PASS[[:space:]]*\|' <<<"$sout" || true)
    sf=$(grep -cE '^[[:space:]]*FAIL[[:space:]]*\|' <<<"$sout" || true)
    se=$(grep -cE '^psql:.*ERROR:' <<<"$sout" || true)
    if [ "$sp" != "$SEED_WANT_PASS" ] || [ "$sf" != 0 ] || [ "$se" != 0 ]; then
      echo "SCOPED GATE FAILED: seed $2 on $1 printed pass=$sp (want $SEED_WANT_PASS) fail=$sf err=$se"; printf '%s\n' "$sout" | grep -E '^[[:space:]]*FAIL|^psql:.*ERROR:' | head -20; return 1
    fi
  fi
}
run_suite() { # db file -> prints "pass fail err"
  local out; out=$(psql -X -d "$1" -f "$2" 2>&1)
  local p f e
  p=$(grep -cE '^[[:space:]]*PASS[[:space:]]*\|' <<<"$out" || true)
  f=$(grep -cE '^[[:space:]]*FAIL[[:space:]]*\|' <<<"$out" || true)
  e=$(grep -cE '^psql:.*ERROR:' <<<"$out" || true)
  echo "$p $f $e"
}
# suite | expected PASS rows
SUITES=(
 "tests/sql/branch_read_boundaries_tests.sql|79"
 "tests/sql/individual_read_gates_0115_0120_tests.sql|25"
 "tests/sql/review_platform_scope_0119_0120_tests.sql|11"
 "tests/sql/audit_direct_columns_0122_tests.sql|24|tests/sql/security_tests.sql"
)
for s in "${SUITES[@]}"; do
  IFS='|' read -r file want seed <<<"$s"
  [ -f "$file" ] || { echo "SCOPED GATE FAILED: missing $file"; fail=1; continue; }
  clone "${BASE}_run" "$seed" || { echo "  FAIL $file (clone/seed precondition)"; fail=1; continue; }
  read -r p f e <<<"$(run_suite "${BASE}_run" "$file")"
  if [ "$p" = "$want" ] && [ "$f" = 0 ] && [ "$e" = 0 ]; then echo "  ok   $file pass=$p"; else echo "  FAIL $file pass=$p (want $want) fail=$f err=$e"; fail=1; fi
done
# mutant | suite | SQL that removes one guard
MUTANTS=(
 "0122 audit table SELECT restored|tests/sql/audit_direct_columns_0122_tests.sql|grant select on public.audit_events to authenticated;"
 "0114 branch read policies dropped|tests/sql/branch_read_boundaries_tests.sql|drop policy branch_membership_read_boundary on public.branch_memberships; drop policy product_branch_read_boundary on public.product_branches; drop policy ai_guard_branch_read_boundary on public.ai_guardrail_events; drop policy ai_tool_branch_read_boundary on public.ai_tool_executions;"
 "0115 settings gates opened|tests/sql/individual_read_gates_0115_0120_tests.sql|alter policy alert_rules_read on public.alert_rules using (true); alter policy staff_sys_select on public.system_settings using (true);"
 "0116 notifications opened|tests/sql/individual_read_gates_0115_0120_tests.sql|alter policy staff_notif_select on public.notifications using (true);"
 "0117 guest/product reads opened|tests/sql/individual_read_gates_0115_0120_tests.sql|alter policy staff_guests_select on public.guest_profiles using (true); alter policy products_read on public.products using (true);"
)
for m in "${MUTANTS[@]}"; do
  IFS='|' read -r name file sql <<<"$m"
  seed=""; [ "$file" = tests/sql/audit_direct_columns_0122_tests.sql ] && seed=tests/sql/security_tests.sql
  clone "${BASE}_mut" "$seed" || { echo "  FAIL mutant '$name' (clone/seed precondition)"; fail=1; continue; }
  psql -X -q -d "${BASE}_mut" -v ON_ERROR_STOP=1 -c "$sql" >/dev/null 2>&1 || { echo "  FAIL mutant '$name' could not be applied"; fail=1; continue; }
  read -r p f e <<<"$(run_suite "${BASE}_mut" "$file")"
  if [ "$f" -ge 1 ] || [ "$e" -ge 1 ]; then echo "  ok   mutant '$name' turns $file RED (fail=$f err=$e)"; else echo "  FAIL mutant '$name' left $file green (pass=$p)"; fail=1; fi
done
psql -q -c "drop database if exists ${BASE}_run" -c "drop database if exists ${BASE}_mut" >/dev/null 2>&1
echo "NOT COVERED HERE: Plan 2.11 full matrix (INCOMPLETE, see acceptance-gate.sh), 0119/0120 RPC guard mutants, WebKit, RPC refusal gates for 0115-0118."
if [ "$fail" -ne 0 ]; then echo "SCOPED RELEASE GATE: FAIL"; exit 1; fi
echo "SCOPED RELEASE GATE: PASS (changed 0114-0122 boundaries only; this is not the full isolation matrix)"
