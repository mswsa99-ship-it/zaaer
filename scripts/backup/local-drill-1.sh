set -euo pipefail
cd "$(dirname "$0")/../.."
EV=acceptance/backup-drill-1
mkdir -p "$EV"
source tests/sql/bootstrap.sh
uri() { echo "postgresql://postgres@%2Ftmp%2Fpgsock15/$1"; }

echo "== drill 1: build dataset A (production schema + synthetic history + bulk synthetic rows)"
bootstrap_db drill_a >/dev/null
for f in supabase/migrations/*.sql; do
  v=$(basename "$f" | cut -d_ -f1)
  if grep -qx "$v" supabase/production-applied.txt; then
    psql -d drill_a -v ON_ERROR_STOP=1 -q -f "$f" 2>&1 | awk '!/NOTICE/'
  fi
done
psql -d drill_a -v ON_ERROR_STOP=1 -q -f tests/sql/history_fixture.sql >/dev/null
psql -d drill_a -v ON_ERROR_STOP=1 -q <<'SQL'
insert into guest_profiles(organization_id, full_name, phone, nationality)
select '00000000-0000-0000-0000-000000000001', 'ضيف مصطنع ' || g, '0551' || lpad(g::text, 6, '0'), 'سعودي'
from generate_series(1, 250) g;
insert into notifications(branch_id, audience, title, body)
select '00000000-0000-0000-0000-000000000010', 'supervisor', 'تنبيه مصطنع ' || g, 'نص مصطنع للتمرين ' || g
from generate_series(1, 400) g;
SQL
echo "dataset A: $(psql -d drill_a -At -c "select count(*) from guest_profiles") guest profiles, $(psql -d drill_a -At -c "select count(*) from notifications") notifications"

echo "== drill 1: state database (full schema incl. 0103)"
bootstrap_db drill_state >/dev/null
for f in supabase/migrations/*.sql; do
  psql -d drill_state -v ON_ERROR_STOP=1 -q -f "$f" 2>&1 | awk '!/NOTICE/'
done

install -m 600 /dev/null /tmp/backup-pass-a
printf '%s' "$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')" > /tmp/backup-pass-a
export BACKUP_PASSPHRASE_FILE=/tmp/backup-pass-a
export BACKUP_DEST_DIR=/tmp/backup-dest-a
export BACKUP_STATE_PGURI="$(uri drill_state)"
export BACKUP_SOURCE_PGURI="$(uri drill_a)"
rm -rf "$BACKUP_DEST_DIR"

echo "== drill 1: backup run"
BACKUP_REASON=drill scripts/backup/backup.sh 2>&1 | tee "$EV/backup.log"
ARCHIVE=$(ls -1t "$BACKUP_DEST_DIR"/backup-*.tar.gpg | head -1)
cp "$BACKUP_DEST_DIR/latest.json" "$EV/latest.json"
cp "$ARCHIVE.sha256" "$EV/sidecar.sha256"

echo "== drill 1: keep the manifest as evidence"
WORK=$(mktemp -d)
gpg --batch --yes --quiet --decrypt --passphrase-file /tmp/backup-pass-a --output "$WORK/final.tar" "$ARCHIVE"
tar -C "$WORK" -xf "$WORK/final.tar"; tar -C "$WORK" -xf "$WORK/bundle.tar"
cp "$WORK/manifest.tsv" "$EV/manifest.tsv"
rm -rf "$WORK"
head -5 "$EV/manifest.tsv"

echo "== drill 1: restore into a fresh database with live-source comparison"
psql -q -c "drop database if exists drill_a_restored;" -c "create database drill_a_restored;" >/dev/null
export BACKUP_TARGET_PGURI="$(uri drill_a_restored)"
export BACKUP_COMPARE_SOURCE_PGURI="$(uri drill_a)"
scripts/backup/restore.sh "$ARCHIVE" 2>&1 | tee "$EV/restore.log"
source scripts/backup/lib.sh
backup_fingerprint "$(uri drill_a_restored)" > "$EV/restored-fingerprint.tsv"

echo "== drill 1: read-only archive check"
scripts/backup/verify-backup.sh "$ARCHIVE" 2>&1 | tee "$EV/verify.log"

echo "== drill 1: recorded state"
psql "$BACKUP_STATE_PGURI" -x -c "select kind, reason, status, run_ref, size_bytes, tables_count, rows_total, verification, error from backup_runs order by seq" | tee "$EV/state-rows.txt"
echo "DRILL 1 DONE"
