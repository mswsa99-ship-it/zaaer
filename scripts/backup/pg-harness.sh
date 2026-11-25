#!/usr/bin/env bash
# =====================================================================================
#  pg-harness.sh — item 7.1: isolated real-PostgreSQL scenarios for the backup tooling. For the integrator's run.
#
#  Needs PostgreSQL server binaries (initdb, pg_ctl) on PATH. It ONLY ever runs its own throwaway cluster; there is no
#  existing-server mode. The cluster lives in a temp dir on a unix socket (no TCP), is proven to be that cluster before any
#  DROP/CREATE, and all database names carry a random suffix. Raw logs go to the evidence dir (BACKUP_HARNESS_EVIDENCE_DIR,
#  default acceptance/backup-harness-<UTC stamp>) and are kept; cleanup removes only the temp dir and the cluster.
#  No network, no secrets (the passphrase is random and local), no Drive, no production URI.
#
#  Scenarios (each prints PASS/FAIL; exit non-zero if any fails or any is skipped):
#   H01 backup succeeds, latest.json written, state row success      H07 restore into a non-empty target refused
#   H02 restore into an empty DB: counts+hashes equal source         H08 wrong passphrase refused
#   H03 verify-backup passes                                          H09 tampered sidecar refused
#   H04 verify-remote (local fetch hook) passes                       H10 corrupt archive refused
#   H05 restore drill passes and drops its scratch DB                 H11 failed source records a failed run, exit non-zero
#   H06 concurrent writes during the dump: restored data equals the manifest snapshot, not a torn mix
# =====================================================================================
set -uo pipefail
cd "$(dirname "$0")/../.."
FAILS=0; SKIPS=0
# Keep only the requested evidence location. Never inherit hooks, remote destinations,
# overwrite switches, credentials or alternate backup connection settings.
for inherited in ${!BACKUP_@}; do
  [[ "$inherited" == BACKUP_HARNESS_EVIDENCE_DIR ]] || unset "$inherited"
done
unset PGSYSCONFDIR PGCLUSTER PGTARGETSESSIONATTRS PGREQUIRESSL PGSSLROOTCERT PGSSLCERT PGSSLKEY PGAPPNAME
command -v initdb >/dev/null && command -v pg_ctl >/dev/null || { echo "SKIP all: initdb/pg_ctl not on PATH (the harness only ever runs its own throwaway cluster)" >&2; exit 3; }
# Environment that could point psql at some other server is cleared: only this script's own socket is ever used.
unset PGHOST PGPORT PGUSER PGDATABASE PGPASSWORD PGSERVICE PGSERVICEFILE PGPASSFILE PGSSLMODE PGOPTIONS PGHOSTADDR
T=$(mktemp -d); chmod 700 "$T"
EV="${BACKUP_HARNESS_EVIDENCE_DIR:-acceptance/backup-harness-$(date -u +%Y%m%d-%H%M%S)}"   # kept after the run, never deleted by cleanup
mkdir -p "$EV"; : > "$EV/scenarios.log"
STARTED=""
cleanup() { [ -n "$STARTED" ] && pg_ctl -D "$T/data" -m immediate stop >/dev/null 2>&1; rm -rf "$T"; }   # removes only the temp dir
trap cleanup EXIT
pass() { printf 'PASS %s\n' "$1" | tee -a "$EV/scenarios.log"; }
fail() { printf 'FAIL %s\n' "$1" | tee -a "$EV/scenarios.log"; FAILS=$((FAILS+1)); }
check() { local name="$1"; shift; { echo "--- $name"; } >> "$EV/scenarios.log"
  if "$@" >>"$EV/scenarios.log" 2>&1; then pass "$name"; else fail "$name"; fi; }
checkc() { check "$1" bash -c "$2"; }
refuse() { local name="$1"; shift; { echo "--- $name (must be refused)"; } >> "$EV/scenarios.log"
  if "$@" >>"$EV/scenarios.log" 2>&1; then fail "$name (accepted, must be refused)"; else pass "$name"; fi; }

PORT=$(( 40000 + RANDOM % 20000 ))
initdb -D "$T/data" -A trust -U postgres >"$EV/initdb.log" 2>&1 || { echo "initdb failed (see $EV/initdb.log)" >&2; exit 2; }
pg_ctl -D "$T/data" -o "-c listen_addresses='' -c unix_socket_directories=$T -p $PORT" -w -l "$EV/server.log" start >/dev/null 2>&1 || { echo "server start failed (see $EV/server.log)" >&2; exit 2; }
STARTED=1
export PGHOST="$T" PGPORT="$PORT" PGUSER=postgres PGDATABASE=postgres
# prove this is the cluster we just made, and nothing else, before any DROP or CREATE
[ "$(psql -qAt -c 'show data_directory')" = "$T/data" ] || { echo "refusing: connected server is not the harness cluster" >&2; exit 2; }
[ "$(psql -qAt -c "select count(*) from pg_database where not datistemplate and datname <> 'postgres'")" = "0" ] || { echo "refusing: fresh cluster is not empty" >&2; exit 2; }
SOCK_ENC=$(python3 -c 'import sys,urllib.parse as u;print(u.quote(sys.argv[1],safe=""))' "$PGHOST")
uri() { echo "postgresql://postgres@${SOCK_ENC}:${PGPORT}/$1"; }

source tests/sql/bootstrap.sh
RUN=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
DB_SRC="hsrc_$RUN"; DB_STATE="hstate_$RUN"; DB_R1="hrest1_$RUN"; DB_R2="hrest2_$RUN"; DB_R3="hrest3_$RUN"
for d in "$DB_SRC" "$DB_STATE" "$DB_R1" "$DB_R2" "$DB_R3"; do
  [ "$(psql -qAt -c "select count(*) from pg_database where datname = '$d'")" = "0" ] || { echo "refusing: database name collision: $d" >&2; exit 2; }
done
load_schema() { # db: bootstrap, then every migration, failing closed on the first error
  bootstrap_db "$1" >>"$EV/bootstrap.log" 2>&1 || { echo "bootstrap failed for $1 (see $EV/bootstrap.log)" >&2; return 1; }
  for f in supabase/migrations/*.sql; do
    psql -d "$1" -v ON_ERROR_STOP=1 -q -f "$f" >>"$EV/migrations-$1.log" 2>&1 || { echo "migration failed for $1: $(basename "$f") (see $EV/migrations-$1.log)" >&2; return 1; }
  done
}
load_schema "$DB_SRC" || exit 2
psql -d "$DB_SRC" -v ON_ERROR_STOP=1 -q <<'SQL' >>"$EV/seed.log" 2>&1 || { echo "seed failed (see $EV/seed.log)" >&2; exit 2; }
insert into guest_profiles(organization_id, full_name, phone, nationality)
select '00000000-0000-0000-0000-000000000001', 'ضيف مصطنع ' || g, '0551' || lpad(g::text, 6, '0'), 'سعودي' from generate_series(1, 300) g;
SQL
load_schema "$DB_STATE" || exit 2

PASSF="$T/pass"; install -m 600 /dev/null "$PASSF"; od -An -N24 -tx1 /dev/urandom | tr -d ' \n' > "$PASSF"
export BACKUP_PASSPHRASE_FILE="$PASSF" BACKUP_DEST_DIR="$T/dest" BACKUP_SOURCE_PGURI="$(uri $DB_SRC)" BACKUP_STATE_PGURI="$(uri $DB_STATE)"
# the passphrase file must live outside the repo; a mktemp dir is. The BACKUP_* variables never leave this script.

BACKUP_REASON=manual scripts/backup/backup.sh >"$EV/backup-run1.log" 2>&1
checkc H01a "test -f $T/dest/latest.json && grep -q '\"status\": \"success\"' $T/dest/latest.json"
ARCH=$(ls -1 "$T/dest"/backup-*.tar.gpg | head -1)
checkc H01b "test \"\$(psql -d $DB_STATE -qAt -c \"select count(*) from backup_runs where kind='backup' and status='success'\")\" = 1"

psql -d postgres -qc "create database $DB_R1" >/dev/null
check H02 env BACKUP_TARGET_PGURI="$(uri $DB_R1)" BACKUP_COMPARE_SOURCE_PGURI="$(uri $DB_SRC)" scripts/backup/restore.sh "$ARCH"
check H03 scripts/backup/verify-backup.sh "$ARCH"
cat > "$T/fetch.sh" <<FEOF
#!/bin/sh
cp "$T/dest/\$1" "\$2/\$1" && cp "$T/dest/\$1.sha256" "\$2/\$1.sha256"
FEOF
chmod +x "$T/fetch.sh"
check H04 env BACKUP_FETCH_HOOK="$T/fetch.sh" scripts/backup/verify-remote.sh "$(basename "$ARCH")"
check H05a env BACKUP_DRILL_ADMIN_PGURI="$(uri postgres)" scripts/backup/restore-drill.sh "$ARCH"
checkc H05b "test \"\$(psql -d postgres -qAt -c \"select count(*) from pg_database where datname like 'roomai_restore_drill_%'\")\" = 0"

refuse H07 env BACKUP_TARGET_PGURI="$(uri $DB_R1)" scripts/backup/restore.sh "$ARCH"

psql -d postgres -qc "create database $DB_R2" >/dev/null
printf 'wrong-phrase' > "$T/wrong"; chmod 600 "$T/wrong"
refuse H08 env BACKUP_PASSPHRASE_FILE="$T/wrong" BACKUP_TARGET_PGURI="$(uri $DB_R2)" scripts/backup/restore.sh "$ARCH"
cp "$ARCH" "$T/t.tar.gpg"; cp "$ARCH.sha256" "$T/t.tar.gpg.sha256"; printf '%064d  x\n' 0 > "$T/t.tar.gpg.sha256"
refuse H09 env BACKUP_TARGET_PGURI="$(uri $DB_R2)" scripts/backup/restore.sh "$T/t.tar.gpg"
cp "$ARCH" "$T/c.tar.gpg"; cp "$ARCH.sha256" "$T/c.tar.gpg.sha256"; printf '\x00\xff\x00\xff' | dd of="$T/c.tar.gpg" bs=1 seek=200 conv=notrunc 2>/dev/null
refuse H10 env BACKUP_TARGET_PGURI="$(uri $DB_R2)" scripts/backup/restore.sh "$T/c.tar.gpg"
checkc H10b "test \"\$(psql -d $DB_R2 -qAt -c \"select count(*) from pg_class where relnamespace='public'::regnamespace and relkind='r'\")\" = 0"

# H06: commit successful writes after backup.sh exports its snapshot, before its
# pg_dump reader imports that same snapshot. A test-only PATH wrapper synchronizes
# this boundary, without changing production backup.sh or relying on timing luck.
REAL_PGDUMP=$(command -v pg_dump)
mkdir -p "$T/bin"
export HARNESS_REAL_PGDUMP="$REAL_PGDUMP" HARNESS_WRITER_DB="$DB_SRC" HARNESS_WRITER_LOG="$EV/writer-after-snapshot.log"
cat > "$T/bin/pg_dump" <<'WRAPPEREOF'
#!/usr/bin/env bash
set -euo pipefail
# The caller has already exported the shared snapshot and read its manifest.
psql -X -d "$HARNESS_WRITER_DB" -v ON_ERROR_STOP=1 >>"$HARNESS_WRITER_LOG" 2>&1 <<'SQL'
insert into guest_profiles(organization_id, full_name, phone, nationality)
select '00000000-0000-0000-0000-000000000001', 'Snapshot writer ' || g, '0552' || lpad(g::text,6,'0'), 'SA' from generate_series(1,20) g;
SQL
exec "$HARNESS_REAL_PGDUMP" "$@"
WRAPPEREOF
chmod +x "$T/bin/pg_dump"
# The filename uses whole seconds. Ensure the second run is distinct without trusting elapsed work time.
sleep 1
PATH="$T/bin:$PATH" BACKUP_REASON=manual scripts/backup/backup.sh >"$EV/backup-run2.log" 2>&1; B2=$?
WRITER_STATUS=1
grep -q 'INSERT 0 20' "$EV/writer-after-snapshot.log" && WRITER_STATUS=0
ARCH2=$(ls -1t "$T/dest"/backup-*.tar.gpg | head -1)
psql -d postgres -v ON_ERROR_STOP=1 -qc "create database $DB_R3" >>"$EV/scenarios.log" 2>&1 || exit 2
if [ "$B2" = 0 ] && [ "$WRITER_STATUS" = 0 ] && [ "$ARCH2" != "$ARCH" ]; then
  check H06 env BACKUP_TARGET_PGURI="$(uri $DB_R3)" scripts/backup/restore.sh "$ARCH2"
  RESTORED_COUNT=$(psql -X -d "$DB_R3" -qAt -v ON_ERROR_STOP=1 -c "select count(*) from guest_profiles where phone like '0552%'")
  FINAL_COUNT=$(psql -X -d "$DB_SRC" -qAt -v ON_ERROR_STOP=1 -c "select count(*) from guest_profiles where phone like '0552%'")
  printf 'writer_status=%s restored_post_snapshot=%s final_post_snapshot=%s\n' "$WRITER_STATUS" "$RESTORED_COUNT" "$FINAL_COUNT" >>"$EV/scenarios.log"
  [ "$RESTORED_COUNT" = 0 ] && [ "$FINAL_COUNT" = 20 ] && pass H06b || fail 'H06b (snapshot writer exclusion not proved)'
else fail 'H06 (snapshot backup or successful writer not proved)'; fi

# H11: unreachable source -> failed run recorded, non-zero exit
BEFORE=$(psql -d $DB_STATE -qAt -c "select count(*) from backup_runs where status='failed'")
BACKUP_SOURCE_PGURI="$(uri no_such_db)" BACKUP_REASON=manual scripts/backup/backup.sh >"$EV/backup-run3.log" 2>&1 && fail "H11a (accepted)" || pass H11a
AFTER=$(psql -d $DB_STATE -qAt -c "select count(*) from backup_runs where status='failed'")
[ "$AFTER" -gt "$BEFORE" ] && pass H11b || fail "H11b (no failed run recorded)"

echo "harness done: failures=$FAILS skips=$SKIPS"
[ "$FAILS" = 0 ] && [ "$SKIPS" = 0 ]
