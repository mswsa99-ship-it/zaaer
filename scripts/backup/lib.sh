#!/usr/bin/env bash
# Shared helpers for the backup tooling (item 7.1). Source this; never run it alone.
#
# Configuration is by environment only — never flags that could land in a shell history, never files in the repo:
#   BACKUP_SOURCE_PGURI     postgres URI of the database to back up (required for backup/drill source)
#   BACKUP_TARGET_PGURI     postgres URI the restore writes into (required for restore)
#   BACKUP_PASSPHRASE_FILE  file holding the GPG symmetric passphrase (required; mode 600, outside the repo)
#   BACKUP_DEST_DIR         local directory that holds the encrypted archives (required for backup)
#   BACKUP_UPLOAD_HOOK      optional executable, called with archive and sidecar paths as two arguments
#   BACKUP_STATE_PGURI      optional postgres URI that records run state (migration 0103's functions)
#   BACKUP_REASON           scheduled | pre-deploy | manual | drill   (default: manual)
#
# Nothing here ever prints a URI, a passphrase or a path that contains a username.

backup_log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

backup_die() { backup_log "ERROR: $*"; exit 1; }

backup_need_tool() { command -v "$1" >/dev/null 2>&1 || backup_die "missing tool: $1"; }

# Config checks shared by backup and restore. The passphrase file must exist, be a regular file and be
# readable by its owner only; the passphrase itself is never read by this script — gpg reads the file.
backup_check_passphrase_file() {
  local f="${BACKUP_PASSPHRASE_FILE:-}"
  [ -n "$f" ] || backup_die "BACKUP_PASSPHRASE_FILE is not set (a vault-injected file, never an inline value)"
  [ -f "$f" ] || backup_die "BACKUP_PASSPHRASE_FILE does not point at a file"
  case "$f" in "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"/*) backup_die "the passphrase file must live outside the repository";; esac
  local mode
  mode=$(stat -c %a "$f")
  [ "$mode" = "600" ] || [ "$mode" = "400" ] || backup_die "the passphrase file must be mode 600 (it is $mode)"
}

backup_check_tools() {
  for t in pg_dump pg_restore psql gpg sha256sum tar python3; do backup_need_tool "$t"; done
}

# Record run state when BACKUP_STATE_PGURI is set; silently skip otherwise (local drills without a state DB).
# Echoes the new run id on start.
backup_state_start() {
  [ -n "${BACKUP_STATE_PGURI:-}" ] || return 0
  psql "$BACKUP_STATE_PGURI" -qAt -v ON_ERROR_STOP=1 -v kind="$1" -v reason="$2" -v ref="$3" -v org="${BACKUP_ORGANIZATION_ID:-}" 2>/dev/null <<'SQL'
select fn_backup_run_start(:'kind', :'reason', :'ref', nullif(:'org','')::uuid);
SQL
}

backup_state_finish() { # id status [size sha256 tables rows verification error]
  [ -n "${BACKUP_STATE_PGURI:-}" ] || return 0
  [ -n "$1" ] || return 0
  psql "$BACKUP_STATE_PGURI" -q -v ON_ERROR_STOP=1 \
    -v id="$1" -v st="$2" -v size="${3:-}" -v sha="${4:-}" -v tables="${5:-}" -v rows="${6:-}" -v verif="${7:-}" -v err="${8:-}" \
    >/dev/null 2>&1 <<'SQL' \
    || { backup_log "ERROR: state recording failed"; return 1; }
select fn_backup_run_finish(:'id', :'st',
  nullif(:'size','')::bigint, nullif(:'sha',''), nullif(:'tables','')::int, nullif(:'rows','')::bigint,
  nullif(:'verif',''), nullif(:'err',''));
SQL
}

# Per-table row count + content hash of the public schema, as TSV: table <tab> count <tab> md5.
# Uses the repo's data-fingerprint.sql; both sides of a comparison must share the PostgreSQL time zone.
backup_fingerprint() { # pguri
  psql "$1" -q -At -F $'\t' -v ON_ERROR_STOP=1 -c "set timezone = 'UTC'; $(cat "$(dirname "${BASH_SOURCE[0]}")/../data-fingerprint.sql")"
}
