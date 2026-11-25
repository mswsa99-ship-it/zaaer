#!/usr/bin/env bash
# Historical all-family fixture runner quarantined: it can invoke protected/outbound prerequisites.
# Use verify-local-candidate.sh for migrations-only bounded checks. Full acceptance remains separate.
set -euo pipefail
printf '%s\n' \
 'REFUSED: historical all-family isolation smoke loader is quarantined.' \
 'No database connection, fixture setup or application RPC was invoked.' \
 'Use tests/isolation/verify-local-candidate.sh for the documented bounded checker.' \
 'Use tests/isolation/acceptance-gate.sh for the fail-closed full acceptance boundary.'
exit 2
