#!/usr/bin/env bash
# hotel-exit.sh — the owner-run hotel exit path (plan item 2.12).
#
# This is a documented operator CLI, NOT a live panel feature: nothing here is
# wired into the app. It calls the owner-only RPCs from migration 0102 as the
# owner's own session (the database user must be able to set
# request.jwt.claim.sub to the owner's auth user id, i.e. run it as a
# privileged local/operator role — exactly how the SQL tests drive it).
#
# Subcommands:
#   status    --org UUID                     show the hotel's exit state
#   export    --org UUID --out DIR           run fn_hotel_exit_export, write dump + manifest
#   verify    --org UUID                     re-check the latest export against live data
#   suspend   --org UUID                     suspend the hotel (requires a completed export)
#   delete    --org UUID --name "الاسم"      delete every row of the hotel (dry-run unless --confirm)
#   restore   --org UUID --archive UUID      put the rows back from the archive
#
# Required env: PGHOST PGPORT PGUSER PGDATABASE (and PGPASSWORD if needed).
# Owner identity: EXIT_OWNER_SUB = the owner's auth.users id (uuid).
set -euo pipefail

die() { echo "hotel-exit: $*" >&2; exit 1; }
need() { [ -n "${!1:-}" ] || die "missing env $1"; }
for v in PGHOST PGPORT PGUSER PGDATABASE EXIT_OWNER_SUB; do need "$v"; done

cmd="${1:-}"; shift || true
ORG=""; OUT=""; NAME=""; ARCHIVE=""; CONFIRM=0
while [ $# -gt 0 ]; do
  case "$1" in
    --org) ORG="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --name) NAME="$2"; shift 2;;
    --archive) ARCHIVE="$2"; shift 2;;
    --confirm) CONFIRM=1; shift;;
    *) die "unknown flag $1";;
  esac
done
[ -n "$ORG" ] || die "--org UUID is required"
[[ "$ORG" =~ ^[0-9a-fA-F-]{36}$ ]] || die "--org must be a uuid"
[[ "$EXIT_OWNER_SUB" =~ ^[0-9a-fA-F-]{36}$ ]] || die "EXIT_OWNER_SUB must be a uuid"

# Every call runs inside one session as the owner: the GUC marks the session
# and the RPCs re-check the owner guard themselves.
run_rpc() { # run_rpc <sql with $ORG/$NAME/$ARCHIVE already interpolated; uuids are regex-validated, name is quote-validated>
  psql -v ON_ERROR_STOP=1 -qAt \
    -c "do \$\$ begin perform set_config('request.jwt.claim.sub', '$EXIT_OWNER_SUB', false); perform set_config('app.hotel_exit', 'on', false); end \$\$" \
    -c "$1" | grep -vxE 'DO'
}

case "$cmd" in
  status)
    run_rpc "select jsonb_pretty(jsonb_build_object(
      'hotel', (select jsonb_build_object('name', name_ar, 'platform_status', platform_status, 'license_status', license_status, 'exited_at', exited_at) from organizations where id = '$ORG'),
      'archives', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'status', status, 'requested_at', requested_at, 'tables', table_count, 'rows', row_count) order by requested_at), '[]'::jsonb) from hotel_exit_archives where organization_id = '$ORG')));"
    ;;
  export)
    [ -n "$OUT" ] || die "export needs --out DIR"
    mkdir -p "$OUT"
    run_rpc "select fn_hotel_exit_export('$ORG');" > "$OUT/export-result.json"
    aid=$(jq -r '.archive_id // empty' "$OUT/export-result.json" 2>/dev/null || true)
    [ -n "$aid" ] || die "export refused or failed: $(cat "$OUT/export-result.json")"
    run_rpc "copy (select jsonb_agg(to_jsonb(a)) from hotel_exit_archives a where a.id = '$aid') to stdout;" > "$OUT/manifest.json"
    run_rpc "copy (select jsonb_agg(to_jsonb(r)) from (select table_name, row_seq, row_data from hotel_exit_rows where archive_id = '$aid' order by table_name, row_seq) r) to stdout;" > "$OUT/rows.json"
    echo "export ok: archive $aid -> $OUT (manifest.json, rows.json, export-result.json)"
    ;;
  verify)
    aid=$(run_rpc "select id::text from hotel_exit_archives where organization_id = '$ORG' and status = 'completed' order by requested_at desc limit 1;")
    [ -n "$aid" ] || die "no completed export to verify"
    run_rpc "select fn_hotel_exit_verify('$aid');"
    ;;
  suspend)
    run_rpc "select fn_hotel_exit_suspend('$ORG');"
    ;;
  delete)
    [ -n "$NAME" ] || die "delete needs --name with the hotel's exact Arabic name"
    case "$NAME" in *"'"*) die "--name must not contain a single quote";; esac
    if [ "$CONFIRM" != "1" ]; then
      echo "DRY-RUN: would delete hotel $ORG ('$NAME'). The RPC refuses unless the hotel is suspended and the latest export verifies. Re-run with --confirm to execute."
      exit 0
    fi
    run_rpc "select fn_hotel_exit_delete('$ORG', '$NAME', '$ORG');"
    ;;
  restore)
    [ -n "$ARCHIVE" ] || die "restore needs --archive UUID"
    [[ "$ARCHIVE" =~ ^[0-9a-fA-F-]{36}$ ]] || die "--archive must be a uuid"
    run_rpc "select fn_hotel_exit_restore('$ORG', '$ARCHIVE', '$ORG');"
    ;;
  *) die "usage: hotel-exit.sh status|export|verify|suspend|delete|restore --org UUID [--out DIR] [--name NAME] [--archive UUID] [--confirm]";;
esac
