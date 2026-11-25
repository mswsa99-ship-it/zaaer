#!/usr/bin/env bash
# Prove the copy at the destination is readable and intact (item 7.1). Upload success is not proof.
# Downloads a fresh copy through BACKUP_FETCH_HOOK (executable; called as: hook <archive-name> <output-dir>; it must
# write <archive-name> and <archive-name>.sha256 there), then checks:
#   1. both files arrived and are non-empty
#   2. if the local original is still in BACKUP_DEST_DIR, the bytes are identical (cmp)
#   3. decrypt + inner bundle hash + sidecar agreement + dump table of contents readable (pg_restore --list)
# Usage: verify-remote.sh [archive-name]   (default: newest in BACKUP_DEST_DIR)
set -euo pipefail
umask 077
cd "$(dirname "$0")/../.."
source scripts/backup/lib.sh
[ -x "${BACKUP_FETCH_HOOK:-}" ] || backup_die "BACKUP_FETCH_HOOK is not an executable"
backup_check_tools; backup_check_passphrase_file
NAME="${1:-}"
if [ -z "$NAME" ]; then
  [ -n "${BACKUP_DEST_DIR:-}" ] || backup_die "BACKUP_DEST_DIR is not set"
  NAME=$(ls -1t "$BACKUP_DEST_DIR"/backup-*.tar.gpg 2>/dev/null | head -1 | xargs -r basename)
  [ -n "$NAME" ] || backup_die "no archive to verify"
fi
[[ "$NAME" =~ ^backup-[0-9]{8}-[0-9]{6}-(scheduled|pre-deploy|manual|drill)\.tar\.gpg$ ]] || backup_die "invalid archive name"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
"$BACKUP_FETCH_HOOK" "$NAME" "$WORK" > "$WORK/fetch.log" 2>&1 || backup_die "download from destination failed"
[ -s "$WORK/$NAME" ] && [ -s "$WORK/$NAME.sha256" ] || backup_die "downloaded copy is missing or empty"
if [ -n "${BACKUP_DEST_DIR:-}" ] && [ -f "$BACKUP_DEST_DIR/$NAME" ]; then
  cmp -s "$BACKUP_DEST_DIR/$NAME" "$WORK/$NAME" || backup_die "downloaded archive differs from the original"
  cmp -s "$BACKUP_DEST_DIR/$NAME.sha256" "$WORK/$NAME.sha256" || backup_die "downloaded sidecar differs from the original"
fi
gpg --batch --yes --quiet --decrypt --passphrase-file "$BACKUP_PASSPHRASE_FILE" --output "$WORK/final.tar" "$WORK/$NAME" \
  || backup_die "downloaded copy cannot be decrypted"
python3 scripts/backup/unpack.py "$WORK/final.tar" "$WORK" bundle.tar bundle.sha256
ACTUAL=$(sha256sum "$WORK/bundle.tar" | cut -d' ' -f1)
[ "$(cut -d' ' -f1 "$WORK/bundle.sha256")" = "$ACTUAL" ] || backup_die "downloaded bundle is corrupt"
[ "$(cut -d' ' -f1 "$WORK/$NAME.sha256")" = "$ACTUAL" ] || backup_die "downloaded sidecar and bundle disagree"
python3 scripts/backup/unpack.py "$WORK/bundle.tar" "$WORK" db.dump manifest.tsv
pg_restore --list "$WORK/db.dump" > "$WORK/toc.txt" || backup_die "dump table of contents unreadable"
[ -s "$WORK/toc.txt" ] || backup_die "dump table of contents empty"
backup_log "remote copy verified: $NAME sha256 ${ACTUAL:0:12}… (downloaded, decrypted, hash and TOC checked)"
