set -euo pipefail
cd "$(dirname "$0")/../.."
EV=acceptance/backup-drill-2
mkdir -p "$EV"
source tests/sql/bootstrap.sh
uri() { echo "postgresql://postgres@%2Ftmp%2Fpgsock15/$1"; }

echo "== drill 2: build dataset B (full current schema incl. 0103, different synthetic data)"
bootstrap_db drill_b >/dev/null || exit 1
for f in supabase/migrations/*.sql; do
  psql -d drill_b -v ON_ERROR_STOP=1 -q -f "$f" 2>&1 | awk '!/NOTICE/'
done
psql -d drill_b -v ON_ERROR_STOP=1 -q <<'SQL' || exit 1
insert into organizations(id, name_ar) select ('93000000-0000-0000-0000-' || lpad(to_hex(g), 12, '0'))::uuid, 'منشأة مصطنعة ' || g from generate_series(1, 3) g;
insert into staff_profiles(id, auth_user_id, organization_id, full_name, email, role)
select ('93000000-0000-0000-0001-' || lpad(to_hex(g), 12, '0'))::uuid, ('93000000-0000-0000-0002-' || lpad(to_hex(g), 12, '0'))::uuid,
       ('93000000-0000-0000-0000-' || lpad(to_hex(1 + (g % 3)), 12, '0'))::uuid, 'موظف مصطنع ' || g, 'synthetic-' || g || '@example.test',
       (array['owner','manager','supervisor','finance','housekeeping'])[1 + (g % 5)]::role_code
from generate_series(1, 60) g;
insert into branches(id, organization_id, name_ar)
select ('93000000-0000-0000-0003-' || lpad(to_hex(g), 12, '0'))::uuid,
       ('93000000-0000-0000-0000-' || lpad(to_hex(1 + (g % 3)), 12, '0'))::uuid, 'فرع مصطنع ' || g
from generate_series(1, 25) g;
insert into guest_profiles(organization_id, full_name, phone, nationality)
select ('93000000-0000-0000-0000-' || lpad(to_hex(1 + (g % 3)), 12, '0'))::uuid, 'نزيل تمرين ' || g, '0559' || lpad(g::text, 6, '0'),
       (array['سعودي','مصري','هندي'])[1 + (g % 3)]
from generate_series(1, 500) g;
insert into notifications(branch_id, audience, title, body)
select ('93000000-0000-0000-0003-' || lpad(to_hex(1 + (g % 25)), 12, '0'))::uuid, 'manager', 'إشعار تمرين ' || g, 'محتوى تمرين مختلف ' || g
from generate_series(1, 1000) g;
SQL
echo "dataset B: $(psql -d drill_b -At -c "select count(*) from organizations") organizations, $(psql -d drill_b -At -c "select count(*) from staff_profiles") staff, $(psql -d drill_b -At -c "select count(*) from guest_profiles") guests, $(psql -d drill_b -At -c "select count(*) from notifications") notifications"

install -m 600 /dev/null /tmp/backup-pass-b
printf '%s' "$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')" > /tmp/backup-pass-b
export BACKUP_PASSPHRASE_FILE=/tmp/backup-pass-b
export BACKUP_DEST_DIR=/tmp/backup-dest-b
export BACKUP_STATE_PGURI="$(uri drill_b)"
export BACKUP_SOURCE_PGURI="$(uri drill_b)"
rm -rf "$BACKUP_DEST_DIR"

echo "== drill 2: weekly-style backup, state recorded in the backed-up database itself (live-like)"
BACKUP_REASON=scheduled scripts/backup/backup.sh 2>&1 | tee "$EV/backup.log" || { echo "DRILL2-FAIL backup"; exit 1; }
ARCHIVE=$(ls -1t "$BACKUP_DEST_DIR"/backup-*.tar.gpg | head -1)

export BACKUP_DRILL_ADMIN_PGURI="$(uri postgres)"
echo "== drill 2: pre-deploy wrapper"
scripts/backup/pre-deploy.sh 2>&1 | tee "$EV/pre-deploy.log" || { echo "DRILL2-FAIL pre-deploy"; exit 1; }

echo "== drill 2: monthly restore drill path (restore-drill.sh)"
export BACKUP_DRILL_ADMIN_PGURI="$(uri postgres)"
scripts/backup/restore-drill.sh 2>&1 | tee "$EV/restore-drill.log" || { echo "DRILL2-FAIL restore-drill"; exit 1; }

echo "== drill 2: recorded state in the backed-up database"
psql "$BACKUP_STATE_PGURI" -x -c "select kind, reason, status, run_ref, size_bytes, tables_count, rows_total, verification, error from backup_runs order by seq" | tee "$EV/state-rows.txt"

echo "== failure drill F1: upload failure is loud and recorded"
printf '#!/bin/sh\nexit 7\n' > /tmp/backup-upload-fail-hook
chmod 700 /tmp/backup-upload-fail-hook
export BACKUP_UPLOAD_HOOK=/tmp/backup-upload-fail-hook
if BACKUP_REASON=scheduled scripts/backup/backup.sh > "$EV/f1-upload-failure.log" 2>&1; then
  echo "DRILL2-FAIL F1: backup with failing upload unexpectedly succeeded"; exit 1
else
  echo "F1 ok: exit $? (non-zero)"; tail -2 "$EV/f1-upload-failure.log"
fi
unset BACKUP_UPLOAD_HOOK

echo "== failure drill F2: corrupt archive is refused"
CORRUPT=/tmp/corrupt.tar.gpg
cp "$ARCHIVE" "$CORRUPT"; cp "$ARCHIVE.sha256" "$CORRUPT.sha256"
SIZE=$(stat -c %s "$CORRUPT"); printf '\xAA\xBB\xCC' | dd of="$CORRUPT" bs=1 seek=$((SIZE / 2)) conv=notrunc status=none
psql -q -c "drop database if exists drill_b_tampered;" -c "create database drill_b_tampered;" >/dev/null
if BACKUP_TARGET_PGURI="$(uri drill_b_tampered)" scripts/backup/restore.sh "$CORRUPT" > "$EV/f2-corrupt.log" 2>&1; then
  echo "DRILL2-FAIL F2: corrupt archive was restored"; exit 1
else
  echo "F2 ok: refused"; grep -o 'ERROR:.*' "$EV/f2-corrupt.log" | head -1
fi
psql -d drill_b_tampered -At -c "select count(*) from pg_class where relnamespace='public'::regnamespace and relkind='r'" | tee "$EV/f2-target-untouched.txt"

echo "== failure drill F3: wrong passphrase is refused"
install -m 600 /dev/null /tmp/backup-pass-wrong
od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > /tmp/backup-pass-wrong
if BACKUP_PASSPHRASE_FILE=/tmp/backup-pass-wrong BACKUP_TARGET_PGURI="$(uri drill_b_tampered)" scripts/backup/restore.sh "$ARCHIVE" > "$EV/f3-wrong-pass.log" 2>&1; then
  echo "DRILL2-FAIL F3: wrong passphrase accepted"; exit 1
else
  echo "F3 ok: refused"; grep -o 'ERROR:.*' "$EV/f3-wrong-pass.log" | head -1
fi
export BACKUP_PASSPHRASE_FILE=/tmp/backup-pass-b

echo "== failure drill F4: restore over a non-empty database is refused without the explicit flag"
if BACKUP_TARGET_PGURI="$(uri drill_b)" scripts/backup/restore.sh "$ARCHIVE" > "$EV/f4-nonempty.log" 2>&1; then
  echo "DRILL2-FAIL F4: overwrote a non-empty database"; exit 1
else
  echo "F4 ok: refused"; grep -o 'ERROR:.*' "$EV/f4-nonempty.log" | head -1
fi

echo "== failure drill F5: tampered sidecar hash is refused"
TAMP=/tmp/tampered-sidecar.tar.gpg
cp "$ARCHIVE" "$TAMP"; printf '%064d  mismatch\n' 0 > "$TAMP.sha256"
psql -q -c "drop database if exists drill_b_tampered;" -c "create database drill_b_tampered;" >/dev/null
if BACKUP_TARGET_PGURI="$(uri drill_b_tampered)" scripts/backup/restore.sh "$TAMP" > "$EV/f5-sidecar.log" 2>&1; then
  echo "DRILL2-FAIL F5: tampered sidecar accepted"; exit 1
else
  echo "F5 ok: refused"; grep -o 'ERROR:.*' "$EV/f5-sidecar.log" | head -1
fi

echo "== failure drill F1 state check: the upload failure is visible in the recorded state"
psql "$BACKUP_STATE_PGURI" -At -c "select status || ' | ' || coalesce(error,'') from backup_runs order by seq desc limit 2" | tee "$EV/f1-state.txt"

echo "DRILL 2 DONE"
