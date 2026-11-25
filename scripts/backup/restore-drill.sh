#!/usr/bin/env bash
# =====================================================================================
#  restore-drill.sh — item 7.1 (T6): the monthly restore drill.
#
#  Takes the newest archive in BACKUP_DEST_DIR (or one given as an argument), restores it into a
#  scratch database and proves counts and content hashes. The scratch database is dropped at the end;
#  no drill data is kept. The drill's result is recorded like any run (kind restore_drill), so the
#  owner's page shows when a restore was last proven.
#
#  Usage: BACKUP_DRILL_ADMIN_PGURI=... BACKUP_STATE_PGURI=... scripts/backup/restore-drill.sh [archive]
#    BACKUP_DRILL_ADMIN_PGURI  connection able to create/drop the scratch database
#    BACKUP_PASSPHRASE_FILE    as for restore.sh
# =====================================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/backup/lib.sh

[ -n "${BACKUP_DRILL_ADMIN_PGURI:-}" ] || backup_die "BACKUP_DRILL_ADMIN_PGURI is not set"
[ -n "${BACKUP_DEST_DIR:-}" ] || backup_die "BACKUP_DEST_DIR is not set"
backup_check_tools
backup_check_passphrase_file

ARCHIVE="${1:-}"
if [ -z "$ARCHIVE" ]; then
  ARCHIVE=$(ls -1t "$BACKUP_DEST_DIR"/backup-*.tar.gpg 2>/dev/null | head -1)
  [ -n "$ARCHIVE" ] || backup_die "no backup archive in BACKUP_DEST_DIR"
fi
BASE=$(basename "$ARCHIVE")
DRILL_DB="roomai_restore_drill_$(date -u +%Y%m%d%H%M%S)"
backup_log "restore drill on $BASE into scratch database"

RUN_ID=$(backup_state_start restore_drill drill "drill-$BASE" )

cleanup() {
  psql "$BACKUP_DRILL_ADMIN_PGURI" -q -c "drop database if exists $DRILL_DB with (force);" >/dev/null 2>&1 || true
}
trap cleanup EXIT

psql "$BACKUP_DRILL_ADMIN_PGURI" -v ON_ERROR_STOP=1 -q -c "create database $DRILL_DB;" \
  || { backup_state_finish "${RUN_ID:-}" failed "" "" "" "" "" "scratch database failed"; backup_die "could not create the scratch database"; }

# the scratch URI is the admin URI with its database part swapped for the scratch name
DRILL_URI=$(python3 - "$BACKUP_DRILL_ADMIN_PGURI" "$DRILL_DB" <<'PYEOF'
import sys
from urllib.parse import urlsplit, urlunsplit
u = urlsplit(sys.argv[1])
print(urlunsplit(u._replace(path="/" + sys.argv[2])))
PYEOF
)

if BACKUP_TARGET_PGURI="$DRILL_URI" scripts/backup/restore.sh "$ARCHIVE" 2>&1; then
  backup_state_finish "${RUN_ID:-}" success "" "" "" "" "restore:counts+hashes identical"
  backup_log "restore drill PASS: $BASE restores and matches its manifest"
else
  backup_state_finish "${RUN_ID:-}" failed "" "" "" "" "" "restore drill failed"
  backup_die "restore drill FAILED: $BASE"
fi
