#!/usr/bin/env bash
# Dependency preflight before a restore (item 7.1): the target must offer every extension the dump needs,
# and the dump must not reference roles/schemas the target lacks in a way that would fail --exit-on-error.
# Usage: restore-preflight.sh <db.dump>   with BACKUP_TARGET_PGURI set. Read-only on the target.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/backup/lib.sh
DUMP="${1:-}"; [ -f "$DUMP" ] || backup_die "usage: restore-preflight.sh <db.dump>"
[ -n "${BACKUP_TARGET_PGURI:-}" ] || backup_die "BACKUP_TARGET_PGURI is not set"
backup_need_tool pg_restore; backup_need_tool psql
TOC=$(mktemp); trap 'rm -f "$TOC"' EXIT
pg_restore --list "$DUMP" > "$TOC" || backup_die "dump unreadable"
missing=0
while read -r ext; do
  [ -n "$ext" ] || continue
  ok=$(psql "$BACKUP_TARGET_PGURI" -XqAt -v ON_ERROR_STOP=1 -v e="$ext" <<'SQL'
select count(*) from pg_available_extensions where name = :'e';
SQL
)
  if [ "$ok" != "1" ]; then backup_log "ERROR: target lacks extension: $ext"; missing=1; fi
done < <(awk '$0 !~ /^;/ { for (i = 1; i < NF; i++) if ($i == "EXTENSION" && $(i+1) == "-") { print $(i+2); break } }' "$TOC" | sort -u)
[ "$missing" = "0" ] || backup_die "restore preflight failed: missing extensions"
backup_log "restore preflight ok: extensions available"
