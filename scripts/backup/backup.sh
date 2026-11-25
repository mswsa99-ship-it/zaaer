#!/usr/bin/env bash
# =====================================================================================
#  backup.sh — item 7.1 (O4): one encrypted, verified backup of the database.
#
#  Steps: dump (custom format) → per-table count+hash manifest → tar → sha256 → GPG AES256 →
#         optional offsite upload → record the run in the database state (migration 0103).
#
#  The archive holds the dump, its manifest and its hash; temporary plaintext is removed (not secure-erased). No key,
#  passphrase, URI or username is ever printed or stored in the repo. A failure at any step records
#  a failed run and exits non-zero — a backup that did not finish is never reported as taken.
#
#  Scheduled weekly and before every deploy (see README.md and the workflow wiring diff).
# =====================================================================================
set -euo pipefail
umask 077
cd "$(dirname "$0")/../.."
source scripts/backup/lib.sh

REASON="${BACKUP_REASON:-manual}"
case "$REASON" in scheduled|pre-deploy|manual|drill) ;; *) backup_die "BACKUP_REASON must be scheduled|pre-deploy|manual|drill";; esac
[ -n "${BACKUP_SOURCE_PGURI:-}" ] || backup_die "BACKUP_SOURCE_PGURI is not set"
[ -n "${BACKUP_DEST_DIR:-}" ] || backup_die "BACKUP_DEST_DIR is not set"
backup_check_tools
backup_check_passphrase_file
mkdir -p "$BACKUP_DEST_DIR"
[ -w "$BACKUP_DEST_DIR" ] || backup_die "BACKUP_DEST_DIR is not writable"

STAMP=$(date -u +%Y%m%d-%H%M%S)
REF="backup-$STAMP-$REASON.tar.gpg"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

RUN_ID=$(backup_state_start backup "$REASON" "$REF" )
backup_log "backup $REF started (reason: $REASON)"

fail_run() { # error-class
  backup_state_finish "${RUN_ID:-}" failed "" "" "" "" "" "$1"
  backup_die "$1"
}

# One exported repeatable-read snapshot is shared by the manifest and pg_dump.
# Keep the exporting session alive until both readers finish.
coproc SNAPSHOT { psql "$BACKUP_SOURCE_PGURI" -XqAt -v ON_ERROR_STOP=1 2> "$WORK/snapshot.log"; }
snapshot_pid=$SNAPSHOT_PID
exec {snapshot_in}>&"${SNAPSHOT[1]}"
exec {snapshot_out}<&"${SNAPSHOT[0]}"
printf '%s\n' 'BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;' 'SELECT pg_export_snapshot();' >&"$snapshot_in"
IFS= read -r SNAPSHOT_ID <&"$snapshot_out" || fail_run "snapshot failed"
[[ "$SNAPSHOT_ID" =~ ^[0-9A-Fa-f-]+$ ]] || fail_run "snapshot reference invalid"
if ! psql "$BACKUP_SOURCE_PGURI" -XqAt -F $'\t' -v ON_ERROR_STOP=1 \
    -v snapshot="$SNAPSHOT_ID" > "$WORK/manifest.tsv" 2> "$WORK/manifest.log" <<SQL
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET TRANSACTION SNAPSHOT :'snapshot';
SET timezone = 'UTC';
$(cat scripts/data-fingerprint.sql)
COMMIT;
SQL
then fail_run "manifest failed"; fi
TABLES=$(wc -l < "$WORK/manifest.tsv" | tr -d ' ')
ROWS=$(awk -F '\t' '{s += $2} END {print s+0}' "$WORK/manifest.tsv")
if ! pg_dump "$BACKUP_SOURCE_PGURI" --snapshot="$SNAPSHOT_ID" --format=custom --no-owner --file "$WORK/db.dump" 2> "$WORK/pg_dump.log"; then
  fail_run "pg_dump failed"
fi
printf '%s\n' 'COMMIT;' '\q' >&"$snapshot_in"
wait "$snapshot_pid" || fail_run "snapshot close failed"
exec {snapshot_in}>&-
exec {snapshot_out}<&-

# 3. pack and hash
tar -C "$WORK" -cf "$WORK/bundle.tar" db.dump manifest.tsv
SHA=$(sha256sum "$WORK/bundle.tar" | cut -d' ' -f1)
printf '%s  %s\n' "$SHA" "$REF" > "$WORK/bundle.sha256"
tar -C "$WORK" -cf "$WORK/final.tar" bundle.tar bundle.sha256
# note: the .sha256 rides inside the encrypted archive so it cannot be swapped without breaking decryption;
# a copy sits next to the archive for a quick pre-decrypt check
cp "$WORK/bundle.sha256" "$WORK/sidecar.sha256"

# 4. encrypt (AES256, passphrase read by gpg from the vault-injected file)
if ! gpg --batch --yes --quiet --cipher-algo AES256 --symmetric \
     --passphrase-file "$BACKUP_PASSPHRASE_FILE" \
     --output "$BACKUP_DEST_DIR/$REF" "$WORK/final.tar" 2> "$WORK/gpg.log"; then
  fail_run "encryption failed"
fi
cp "$WORK/sidecar.sha256" "$BACKUP_DEST_DIR/$REF.sha256"
SIZE=$(stat -c %s "$BACKUP_DEST_DIR/$REF")

# 5. offsite upload (the live destination is the owner's choice; without BACKUP_UPLOAD_HOOK the archive
#    stays local and the run says so — it is still a successful local backup, not an offsite one)
UPLOAD_NOTE="local-only (offsite upload not configured)"
if [ -n "${BACKUP_UPLOAD_HOOK:-}" ]; then
  if "$BACKUP_UPLOAD_HOOK" "$BACKUP_DEST_DIR/$REF" "$BACKUP_DEST_DIR/$REF.sha256" > "$WORK/upload.log" 2>&1; then
    UPLOAD_NOTE="uploaded"
  else
    fail_run "upload failed"
  fi
fi

# 6. state: a backup counts only with its manifest and its hash recorded
backup_state_finish "${RUN_ID:-}" success "$SIZE" "$SHA" "$TABLES" "$ROWS" "manifest+sha256; $UPLOAD_NOTE"
cat > "$BACKUP_DEST_DIR/latest.json" <<EOF
{"run_ref": "$REF", "finished_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)", "status": "success",
 "reason": "$REASON", "size_bytes": $SIZE, "sha256": "$SHA", "tables": $TABLES, "rows_total": $ROWS,
 "verification": "manifest+sha256; $UPLOAD_NOTE"}
EOF
backup_log "backup $REF done: $TABLES tables, $ROWS rows, $SIZE bytes, sha256 ${SHA:0:12}… ($UPLOAD_NOTE)"
