#!/usr/bin/env bash
# =====================================================================================
#  restore.sh — item 7.1 (T6): restore one encrypted archive into a fresh database and prove it.
#
#  Usage: BACKUP_TARGET_PGURI=... BACKUP_PASSPHRASE_FILE=... scripts/backup/restore.sh <archive.tar.gpg>
#
#  Proof: the sidecar hash is checked before decryption, the manifest's counts and content hashes are
#  compared against the restored database afterwards. With BACKUP_COMPARE_SOURCE_PGURI set, the restored
#  database's fingerprint is also compared against the live source (used by the drills). Any mismatch or
#  corruption stops the restore with a non-zero exit — a partial restore is never called a restore.
#
#  Safety: the target must have no user tables in public unless BACKUP_RESTORE_ALLOW_OVERWRITE=1.
# =====================================================================================
set -euo pipefail
umask 077
cd "$(dirname "$0")/../.."
source scripts/backup/lib.sh

ARCHIVE="${1:-}"
[ -n "$ARCHIVE" ] || backup_die "usage: restore.sh <archive.tar.gpg>"
[ -f "$ARCHIVE" ] || backup_die "archive not found: $(basename "$ARCHIVE")"
[ -n "${BACKUP_TARGET_PGURI:-}" ] || backup_die "BACKUP_TARGET_PGURI is not set"
backup_check_tools
backup_check_passphrase_file

BASE=$(basename "$ARCHIVE")
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 1. pre-decrypt check: the sidecar sha256 must match the archive's inner bundle declaration
[ -f "$ARCHIVE.sha256" ] || backup_die "sidecar hash file missing next to the archive"
cp "$ARCHIVE.sha256" "$WORK/sidecar.sha256"

# 2. decrypt
if ! gpg --batch --yes --quiet --decrypt --passphrase-file "$BACKUP_PASSPHRASE_FILE" \
     --output "$WORK/final.tar" "$ARCHIVE" 2> "$WORK/gpg.log"; then
  backup_die "decryption failed (wrong passphrase or corrupt archive)"
fi
python3 scripts/backup/unpack.py "$WORK/final.tar" "$WORK" bundle.tar bundle.sha256
[ -f "$WORK/bundle.tar" ] && [ -f "$WORK/bundle.sha256" ] || backup_die "the archive does not hold a backup bundle"

# 3. hash verification: inner declaration, sidecar declaration and the real bytes must agree
DECLARED=$(cut -d' ' -f1 "$WORK/bundle.sha256")
SIDECAR=$(cut -d' ' -f1 "$WORK/sidecar.sha256")
ACTUAL=$(sha256sum "$WORK/bundle.tar" | cut -d' ' -f1)
[ "$DECLARED" = "$ACTUAL" ] || backup_die "hash mismatch: the bundle is corrupt (declared ${DECLARED:0:12}…, actual ${ACTUAL:0:12}…)"
[ "$SIDECAR" = "$ACTUAL" ] || backup_die "hash mismatch: sidecar and bundle disagree (tampering suspected)"
python3 scripts/backup/unpack.py "$WORK/bundle.tar" "$WORK" db.dump manifest.tsv
[ -f "$WORK/db.dump" ] && [ -f "$WORK/manifest.tsv" ] || backup_die "the bundle does not hold dump and manifest"
backup_log "archive verified: sha256 ${ACTUAL:0:12}…"

# 4. target safety
EXISTING=$(psql "$BACKUP_TARGET_PGURI" -At -v ON_ERROR_STOP=1 \
  -c "select count(*) from pg_class where relnamespace = 'public'::regnamespace and relkind = 'r'")
if [ "$EXISTING" != "0" ] && [ "${BACKUP_RESTORE_ALLOW_OVERWRITE:-0}" != "1" ]; then
  backup_die "target database already holds $EXISTING tables (refusing; set BACKUP_RESTORE_ALLOW_OVERWRITE=1 to proceed)"
fi

# 5. restore
if ! pg_restore -d "$BACKUP_TARGET_PGURI" --no-owner --exit-on-error "$WORK/db.dump" 2> "$WORK/pg_restore.log"; then
  backup_die "pg_restore failed"
fi

# 6. proof: restored fingerprint must equal the manifest
backup_fingerprint "$BACKUP_TARGET_PGURI" > "$WORK/restored.tsv"
if ! diff -q "$WORK/manifest.tsv" "$WORK/restored.tsv" >/dev/null; then
  backup_die "restored data does not match the backup manifest"
fi
TABLES=$(wc -l < "$WORK/manifest.tsv" | tr -d ' ')
ROWS=$(awk -F '\t' '{s += $2} END {print s+0}' "$WORK/manifest.tsv")

# 7. optional: against the live source (drills)
if [ -n "${BACKUP_COMPARE_SOURCE_PGURI:-}" ]; then
  backup_fingerprint "$BACKUP_COMPARE_SOURCE_PGURI" > "$WORK/source.tsv"
  if ! diff -q "$WORK/source.tsv" "$WORK/restored.tsv" >/dev/null; then
    backup_die "restored data does not match the live source"
  fi
  backup_log "restored data matches the live source"
fi

backup_log "restore verified: $TABLES tables, $ROWS rows, counts and content hashes identical"
