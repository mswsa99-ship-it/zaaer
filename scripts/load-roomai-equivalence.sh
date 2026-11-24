#!/usr/bin/env bash
# =====================================================================
# Migration 0106 equivalence gate (item 2.10): fn_reservation_list's 0106
# body must return byte-identical results to the 0040 body across roles,
# filters, pagination, membership and cross-hotel isolation.
#
#   PGHOST=/tmp PGPORT=54333 PGUSER=postgres scripts/load-roomai-equivalence.sh [out-dir]
#
# Builds a small throwaway DB (fixture hotels 90 and 91 only), captures the
# call matrix with the 0040 body, applies 0106, captures again, diffs.
# Exits non-zero when the outputs differ.
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-/tmp/load-roomai-equiv}"
DB="${LOAD_EQ_DB:-roomai_load_equiv}"
PSQL="psql -X -q -v ON_ERROR_STOP=1 -d $DB"
mkdir -p "$OUT"

source tests/sql/bootstrap.sh
bootstrap_db "$DB" >"$OUT/bootstrap.log" 2>&1
for f in supabase/migrations/*.sql; do
  case "$f" in
    *_0106_reservation_list_hoist.sql) : ;;  # applied between the two captures
    *) psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f "$f" >>"$OUT/migrations.log" 2>&1 ;;
  esac
done
$PSQL -v hotel=90 -v year_start="${YEAR_START:-$(date -d '305 days ago' +%F)}" -f tests/load/10-fixture-hotel.sql >"$OUT/fixture-90.log" 2>&1
$PSQL -v hotel=91 -v year_start="${YEAR_START:-$(date -d '305 days ago' +%F)}" -f tests/load/10-fixture-hotel.sql >"$OUT/fixture-91.log" 2>&1

# Refresh planner statistics before comparing the two bodies. A freshly bulk-loaded
# fixture otherwise produces an unrepresentative old-body plan.
$PSQL -c 'analyze;' > "$OUT/analyze.log" 2>&1

$PSQL -tA -f tests/load/40-list-capture.sql > "$OUT/before-0106.txt" 2>&1
$PSQL -f supabase/migrations/20261124180000_0106_reservation_list_hoist.sql > "$OUT/migration-0106.log" 2>&1
$PSQL -tA -f tests/load/40-list-capture.sql > "$OUT/after-0106.txt" 2>&1

# Matching failures are not equivalence evidence. Require every case to return
# its result and reject caught SQL errors in either capture.
for capture in "$OUT/before-0106.txt" "$OUT/after-0106.txt"; do
  if grep -q '|ERR:' "$capture" || [ "$(grep -cE '^[0-9]+\\|' "$capture")" -ne 23 ]; then
    echo "EQUIVALENCE: FAIL: incomplete or errored capture: $capture"
    exit 1
  fi
done

if diff -u "$OUT/before-0106.txt" "$OUT/after-0106.txt" > "$OUT/equivalence.diff"; then
  echo "EQUIVALENCE: PASS — 0106 body byte-identical to 0040 body across the call matrix"
else
  echo "EQUIVALENCE: FAIL — see $OUT/equivalence.diff"; exit 1
fi

# Fail closed independently of the human-readable status rows below.
$PSQL <<'SQL'
do $$
begin
  perform set_config('request.jwt.claim.sub', md5('auth:90:owner'), false);
  perform set_config('request.jwt.claims', json_build_object('sub', md5('auth:90:owner'))::text, false);
  if (fn_reservation_list(md5('branch:91:5')::uuid, '{}'::jsonb, 50, 0)->>'total')::int is distinct from 0 then
    raise exception 'Cross-hotel isolation failed';
  end if;
  perform set_config('request.jwt.claim.sub', md5('auth:90:hk'), false);
  perform set_config('request.jwt.claims', json_build_object('sub', md5('auth:90:hk'))::text, false);
  if (fn_reservation_list(md5('branch:90:5')::uuid, '{}'::jsonb, 50, 0)->>'total')::int is distinct from 0 then
    raise exception 'Non-member isolation failed';
  end if;
  if jsonb_array_length(fn_reservation_list(md5('branch:90:3')::uuid, '{}'::jsonb, 50, 0)->'rows') = 0 then
    raise exception 'Housekeeping money check has no rows';
  end if;
  if exists (select 1 from jsonb_array_elements(fn_reservation_list(md5('branch:90:3')::uuid, '{}'::jsonb, 50, 0)->'rows') r
             where (r->>'total_halalas') is not null or (r->>'paid_halalas') is not null or (r->>'balance_due_halalas') is not null) then
    raise exception 'Housekeeping money visibility failed';
  end if;
end $$;
SQL

# explicit isolation/money invariants (documented intent behind the matrix)
$PSQL -tA <<'EOF'
select set_config('request.jwt.claim.sub', md5('auth:90:owner'), false);
select set_config('request.jwt.claims', json_build_object('sub', md5('auth:90:owner'))::text, false);
select case when (fn_reservation_list(md5('branch:91:5')::uuid, '{}'::jsonb, 50, 0)->>'total')::int = 0
            then 'ISOLATION cross-hotel owner: PASS (total=0)' else 'ISOLATION cross-hotel owner: FAIL' end;
select set_config('request.jwt.claim.sub', md5('auth:90:hk'), false);
select set_config('request.jwt.claims', json_build_object('sub', md5('auth:90:hk'))::text, false);
select case when (fn_reservation_list(md5('branch:90:5')::uuid, '{}'::jsonb, 50, 0)->>'total')::int = 0
            then 'ISOLATION non-member branch: PASS (total=0)' else 'ISOLATION non-member branch: FAIL' end;
select case when coalesce((select bool_and((r->>'total_halalas') is null and (r->>'paid_halalas') is null
                                           and (r->>'balance_due_halalas') is null)
                           from jsonb_array_elements(fn_reservation_list(md5('branch:90:3')::uuid, '{}'::jsonb, 50, 0)->'rows') r), true)
            then 'MONEY hidden for housekeeping: PASS' else 'MONEY hidden for housekeeping: FAIL' end;
EOF
