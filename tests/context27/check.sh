#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=${CONTEXT27_LOG_DIR:-test-results/context27}
mkdir -p "$out"
npx vitest run tests/unit/reception_context_two_hotels.test.ts tests/unit/ops_context_two_hotels.test.ts tests/unit/reception_scope.test.ts tests/unit/reception_tools.test.ts > "$out/green.log" 2>&1
for mutant in history policies conversation; do
  if CONTEXT27_MUTANT=$mutant npx vitest run tests/unit/reception_context_two_hotels.test.ts > "$out/reception-red-$mutant.log" 2>&1; then
    echo "FAIL: reception mutant survived: $mutant"; exit 1
  fi
  grep -q 'AssertionError' "$out/reception-red-$mutant.log" || { echo "FAIL: mutant did not reach assertion: $mutant"; exit 1; }
  echo "reception mutant killed: $mutant"
done
for mutant in settings client; do
  if OPS_CONTEXT27_MUTANT=$mutant npx vitest run tests/unit/ops_context_two_hotels.test.ts > "$out/ops-red-$mutant.log" 2>&1; then
    echo "FAIL: Ops mutant survived: $mutant"; exit 1
  fi
  if [[ $mutant == client ]]; then
    grep -q 'ops context must use caller client, never admin' "$out/ops-red-$mutant.log"
  else
    grep -q 'AssertionError' "$out/ops-red-$mutant.log"
  fi
  echo "Ops mutant killed: $mutant"
done
echo "GREEN context tests and all five RED controls verified. Logs: $out"
