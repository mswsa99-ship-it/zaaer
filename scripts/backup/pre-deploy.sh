#!/usr/bin/env bash
# Pre-deploy backup (item 7.1, O4): the production protocol requires a fresh encrypted backup with a
# proven restore before any database change. This wrapper runs that backup with reason pre-deploy.
# The deploy gate calls it before applying migrations (see the workflow wiring diff; not yet activated).
set -euo pipefail
cd "$(dirname "$0")/../.."
export BACKUP_REASON=pre-deploy
scripts/backup/backup.sh
# Fail closed unless the fresh archive can be restored and matched before deploy.
scripts/backup/restore-drill.sh
