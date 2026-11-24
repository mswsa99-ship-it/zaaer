#!/usr/bin/env bash
# Quick read-only check of an archive: the bundle hash inside matches the real bytes. Does not restore;
# the full proof is restore.sh. Useful after an upload, to confirm the copy that arrived is the one made.
#   verify-backup.sh <archive.tar.gpg>
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/backup/lib.sh
ARCHIVE="${1:-}"
[ -n "$ARCHIVE" ] || backup_die "usage: verify-backup.sh <archive.tar.gpg>"
[ -f "$ARCHIVE" ] || backup_die "archive not found: $(basename "$ARCHIVE")"
backup_check_tools
backup_check_passphrase_file
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
gpg --batch --yes --quiet --decrypt --passphrase-file "$BACKUP_PASSPHRASE_FILE" --output "$WORK/final.tar" "$ARCHIVE" \
  || backup_die "decryption failed (wrong passphrase or corrupt archive)"
python3 scripts/backup/unpack.py "$WORK/final.tar" "$WORK" bundle.tar bundle.sha256
DECLARED=$(cut -d' ' -f1 "$WORK/bundle.sha256")
ACTUAL=$(sha256sum "$WORK/bundle.tar" | cut -d' ' -f1)
[ "$DECLARED" = "$ACTUAL" ] || backup_die "hash mismatch: the bundle is corrupt"
backup_log "archive intact: $(basename "$ARCHIVE") sha256 ${ACTUAL:0:12}…"
