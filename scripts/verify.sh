#!/usr/bin/env bash
# =====================================================================================
#  verify.sh — the single gate every change must pass before it is called "done".
#
#  Gates (P0 = blocks the change; P1 = must pass before release, may be skipped locally
#  with SKIP_<GATE>=1 when the tooling is unavailable — never in CI):
#
#    P0  typecheck     tsc -b                      the app compiles
#    P0  unit          vitest                      guardrails, ops logic, contract drift, demo invariants
#    P0  edge          tsc (Deno shim)             edge functions compile
#    P0  sql           tests/sql/run.sh            migrations from scratch + 51 security + 90+ core acceptance tests
#    P0  race          tests/sql/concurrency.sh    two real sessions: booking race, refund race
#    P0  build         vite build                  production bundle
#    P0  build:demo    VITE_DEMO=1 vite build      demo bundle (what the E2E suite runs against)
#    P1  e2e           playwright                  guest reception, reservation lifecycle, money, housekeeping, copilot, admin, smoke
#
#  Usage:  npm run verify            (all gates)
#          npm run verify:quick      (typecheck + unit + edge — seconds, for every edit)
#          QUICK=1 scripts/verify.sh (same as verify:quick)
#
#  Postgres: PGHOST / PGUSER / PGPASSWORD / PGPORT as for psql. TEST_DB defaults to airec_test.
#  "No PASS without running": a gate that did not run is reported as SKIPPED, never as PASS.
# =====================================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

declare -a NAMES STATUSES TIMES
overall=0
start_all=$(date +%s)

run_gate() { # name, level(P0|P1), skip-env, command...
  local name="$1" level="$2" skip="$3"; shift 3
  local t0 t1 status
  if [[ "${!skip:-}" == "1" && -z "${CI:-}" ]]; then
    NAMES+=("$name"); STATUSES+=("SKIPPED ($level, $skip=1)"); TIMES+=("-")
    echo "== [$name] SKIPPED"
    [[ "$level" == "P0" ]] && overall=1
    return
  fi
  echo; echo "== [$name] $*"
  t0=$(date +%s)
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    # On GitHub the end of a failing gate's output is also put on the run page as an annotation: the job log
    # itself is not always reachable (and a summary that only says "exit code 1" helps nobody).
    local log; log=$(mktemp)
    if "$@" 2>&1 | tee "$log"; then status="PASS"; else status="FAIL"; [[ "$level" == "P0" || -z "${ALLOW_P1_FAIL:-}" ]] && overall=1; fi
    if [[ "$status" == "FAIL" ]]; then
      local tail_text
      tail_text=$(tail -n 40 "$log" | sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/%/%25/g' -e 's/\r/%0D/g' | awk '{ printf "%s%%0A", $0 }')
      echo "::error title=verify gate ${name//:/-} failed::${tail_text}"
    fi
    rm -f "$log"
  elif "$@"; then status="PASS"; else status="FAIL"; [[ "$level" == "P0" || -z "${ALLOW_P1_FAIL:-}" ]] && overall=1; fi
  t1=$(date +%s)
  NAMES+=("$name"); STATUSES+=("$status ($level)"); TIMES+=("$((t1 - t0))s")
  echo "== [$name] $status in $((t1 - t0))s"
}

pg_reachable() { psql -Atc "select 1" postgres >/dev/null 2>&1; }

run_gate typecheck  P0 SKIP_TYPECHECK npx tsc -b --noEmit
run_gate unit       P0 SKIP_UNIT      npx vitest run
run_gate edge       P0 SKIP_EDGE      npx tsc -p tests/edge/tsconfig.json

if [[ "${QUICK:-}" != "1" ]]; then
  if pg_reachable || [[ -n "${CI:-}" ]]; then
    run_gate sql   P0 SKIP_SQL  bash tests/sql/run.sh
    run_gate race  P0 SKIP_SQL  bash tests/sql/concurrency.sh
  else
    NAMES+=("sql" "race"); STATUSES+=("SKIPPED (P0, PostgreSQL not reachable — set PGHOST/PGUSER)" "SKIPPED (P0, PostgreSQL not reachable)"); TIMES+=("-" "-")
    echo "== [sql] SKIPPED: PostgreSQL not reachable (set PGHOST/PGUSER/PGPASSWORD, or start a local 16 cluster)"
    overall=1
  fi
  run_gate build      P0 SKIP_BUILD npx vite build
  run_gate build:demo P0 SKIP_BUILD env VITE_DEMO=1 npx vite build --base ./ --outDir dist-demo
  run_gate e2e        P1 SKIP_E2E   npx playwright test
fi

end_all=$(date +%s)
echo; echo "================= verify summary ($((end_all - start_all))s) ================="
for i in "${!NAMES[@]}"; do printf "  %-12s %-56s %s\n" "${NAMES[$i]}" "${STATUSES[$i]}" "${TIMES[$i]}"; done
echo "==========================================================================="
if [[ $overall -ne 0 ]]; then echo "RESULT: FAIL — at least one P0 gate failed or was skipped"; exit 1; fi
echo "RESULT: PASS"
