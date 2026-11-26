#!/usr/bin/env bash
# IC01-IC02: two real sessions apply the SAME hotel policy preview at once (migration 0149).
# Session A holds its transaction 3s; session B starts 1s later, must wait on the hotel lock and then be refused
# (its token/plan is stale), and exactly one master and one copy may exist.  Usage: PGHOST=.. PGUSER=postgres tests/sql/inheritance_concurrency.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
SRC="${TEST_DB:-airec_test}"; DB=inh_conc
psql -d postgres -qc "drop database if exists $DB" -c "create database $DB template $SRC" 2>&1 | grep -i error
psql -d postgres -qc "alter database $DB set app.identity_key = 'test-identity-key'"
# fixture: lines 13-24 of the unit tests (org, branches, staff), committed, no temp tables
{ echo "create or replace function in_login(p_uid uuid) returns void language plpgsql as \$\$ begin perform set_config('request.jwt.claim.sub', p_uid::text, false); perform set_config('request.jwt.claims', json_build_object('sub', p_uid)::text, false); end \$\$;"
  echo "insert into organizations(id,name_ar) values('ac000000-0000-4000-8000-000000000001','IN org'),('ac000000-0000-4000-8000-000000000002','IN other org');"
  sed -n 13,24p tests/sql/inheritance_0149_tests.sql; } | psql -d $DB -q -v ON_ERROR_STOP=1 2>&1 | grep -i error
D='{"topic":"checkin","title":"الوصول والمغادرة","content_ar":"الوصول من الساعة 4:00 عصرًا","is_public":true,"sort_order":1}'
PV=$(psql -d $DB -At <<SQL | tail -1
set role authenticated; select in_login('ac200000-0000-4000-8000-000000000001');
select fn_policy_master_preview('$D'::jsonb);
SQL
)
APPLY="select fn_policy_master_apply('$D'::jsonb || jsonb_build_object('id', '$(echo "$PV"|jq -r .master.id)', 'token', '$(echo "$PV"|jq -r .token)'))"
run() { psql -d $DB -At 2>&1 <<SQL | grep -E "ERROR|^\{" | head -1
set role authenticated; select in_login('ac200000-0000-4000-8000-000000000001');
begin; $APPLY; select pg_sleep($1); commit;
SQL
}
OUT=$(mktemp); run 3 > "$OUT" & sleep 1
B=$(run 0); wait
A=$(cat "$OUT")
M=$(psql -d $DB -Atc "select count(*) from policy_masters where topic='checkin'")
C=$(psql -d $DB -Atc "select count(*) from property_policies where topic='checkin' and master_id is not null")
fail=0
if [[ "$A" == "{"* && "$B" == *"ERROR"* ]]; then echo "PASS IC01 second concurrent apply of the same preview is refused ($B)"; else echo "FAIL IC01 A=$A B=$B"; fail=1; fi
if [[ "$M" == 1 && "$C" == 2 ]]; then echo "PASS IC02 exactly one master ($M) and two linked branch rows ($C)"; else echo "FAIL IC02 masters=$M linked=$C"; fail=1; fi
psql -d postgres -qc "drop database $DB"
exit $fail
