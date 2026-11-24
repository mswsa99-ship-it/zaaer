#!/usr/bin/env bash
# EXAMPLE ONLY, not installed. Upload and fetch hooks for the approved private Drive destination via rclone.
# The rclone remote ("roomai-backup") is configured on the backup host by the owner; its token never enters the repo.
# Upload hook (BACKUP_UPLOAD_HOOK):  drive-hook.example.sh <archive> <sidecar>
# Fetch hook  (BACKUP_FETCH_HOOK):   drive-hook.example.sh fetch <archive-name> <output-dir>
set -euo pipefail
REMOTE="${BACKUP_RCLONE_REMOTE:-roomai-backup:RoomAI-backups}"
case "${1:-}" in
  fetch)  rclone copyto "$REMOTE/$2" "$3/$2"; rclone copyto "$REMOTE/$2.sha256" "$3/$2.sha256" ;;
  *) rclone copyto "$1" "$REMOTE/$(basename "$1")"; rclone copyto "$2" "$REMOTE/$(basename "$2")" ;;
esac
