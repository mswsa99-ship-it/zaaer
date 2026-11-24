#!/usr/bin/env bash
# Retention for encrypted archives in BACKUP_DEST_DIR (item 7.1). DRY RUN unless BACKUP_PRUNE_APPLY=1.
# Policy (proposed, owner approves the numbers; all overridable by environment):
#   BACKUP_KEEP_DAYS     35  keep every archive newer than this
#   BACKUP_KEEP_MONTHLY  12  beyond that, keep the newest scheduled archive of each of this many months
#   BACKUP_KEEP_MIN       4  never leave fewer than this many archives
# Only files named backup-YYYYMMDD-HHMMSS-<reason>.tar.gpg are considered; each is removed with its .sha256.
# Archives are never pruned when latest.json is missing or not "success" (no proven backup, no deletion).
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/backup/lib.sh
[ -n "${BACKUP_DEST_DIR:-}" ] && [ -d "$BACKUP_DEST_DIR" ] || backup_die "BACKUP_DEST_DIR is not a directory"
KEEP_DAYS="${BACKUP_KEEP_DAYS:-35}"; KEEP_MONTHLY="${BACKUP_KEEP_MONTHLY:-12}"; KEEP_MIN="${BACKUP_KEEP_MIN:-4}"
for v in "$KEEP_DAYS" "$KEEP_MONTHLY" "$KEEP_MIN"; do [[ "$v" =~ ^[0-9]+$ ]] || backup_die "retention values must be whole numbers"; done
grep -q '"status": "success"' "$BACKUP_DEST_DIR/latest.json" 2>/dev/null || backup_die "latest.json missing or not success; refusing to prune"
NOW="${BACKUP_PRUNE_NOW:-$(date -u +%Y%m%d)}"
CUT=$(date -u -d "${NOW:0:4}-${NOW:4:2}-${NOW:6:2} -${KEEP_DAYS} days" +%Y%m%d)
mapfile -t ALL < <(cd "$BACKUP_DEST_DIR" && ls -1 | grep -E '^backup-[0-9]{8}-[0-9]{6}-(scheduled|pre-deploy|manual|drill)\.tar\.gpg$' | sort -r)
declare -A KEEP; declare -A MONTH_SEEN; n=0; months=0
for f in "${ALL[@]}"; do
  d=${f:7:8}; m=${d:0:6}; n=$((n+1))
  if [ "$d" -ge "$CUT" ] || [ "$n" -le "$KEEP_MIN" ]; then KEEP[$f]=1; continue; fi
  if [[ "$f" == *-scheduled.tar.gpg ]] && [ -z "${MONTH_SEEN[$m]:-}" ] && [ "$months" -lt "$KEEP_MONTHLY" ]; then
    MONTH_SEEN[$m]=1; months=$((months+1)); KEEP[$f]=1
  fi
done
removed=0
for f in "${ALL[@]}"; do
  [ -n "${KEEP[$f]:-}" ] && continue
  if [ "${BACKUP_PRUNE_APPLY:-0}" = "1" ]; then rm -f -- "$BACKUP_DEST_DIR/$f" "$BACKUP_DEST_DIR/$f.sha256"; backup_log "pruned $f"
  else backup_log "would prune $f"; fi
  removed=$((removed+1))
done
backup_log "retention: ${#ALL[@]} archives, kept $(( ${#ALL[@]} - removed )), $([ "${BACKUP_PRUNE_APPLY:-0}" = "1" ] && echo removed || echo "would remove") $removed"
