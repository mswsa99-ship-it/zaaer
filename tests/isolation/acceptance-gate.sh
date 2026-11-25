#!/usr/bin/env bash
# Plan2.11 FULL MATRIX report. Not a release gate: scripts/verify.sh lists it as NOT RUN. The executable release gate for the
# changed 0114-0122 boundaries is tests/isolation/scoped-release-gate.sh. This script must never be changed to exit 0 until a
# complete runner exists.
# A complete source-qualified matrix runner has not yet been implemented.
# Until then, fail closed without bootstrapping fixtures or invoking any application RPC.
set -euo pipefail
printf '%s\n' \
  'ISOLATION ACCEPTANCE: INCOMPLETE (plan2.11)' \
  'Full table/function/role/operation controls and evidence are not complete.' \
  'Inventory, adapter counts, bounded probes and exclusions are not matrix acceptance.' \
  'No application SQL, fixture preload, protected function or external effect was invoked.' \
  'See tests/isolation/README.md and docs/remaining-security-gaps-1747.md.'
exit 1
