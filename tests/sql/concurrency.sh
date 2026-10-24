#!/usr/bin/env bash
# X01 / X02 — true concurrency tests with TWO independent sessions (see ZAAER-TESTING-AND-CONTROL-RULES §10).
# Session A starts a transaction and holds it open for 3s before committing; session B fires 1s later and must
# block on the row/exclusion lock, then observe A's committed result. Running the two calls sequentially would
# NOT prove anything — this script is the evidence.
# Usage: PGHOST=... PGUSER=postgres TEST_DB=airec_test tests/sql/concurrency.sh   (after run.sh)
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${TEST_DB:-airec_test}"
fail=0

login="select t_login('a0000000-0000-0000-0000-000000000001','owner@test.local'); set role authenticated;"

# ---------- fixture: a free room + a reservation with 40 SAR refundable deposit ----------
psql -d "$DB" -v ON_ERROR_STOP=1 -q <<'EOF'
insert into rooms(id, branch_id, organization_id, category_id, room_number, is_active, status)
values ('00000000-0000-0000-0000-000000000198','00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000030','X-RACE', true, 'available')
on conflict (id) do nothing;
EOF
RES=$(psql -d "$DB" -At -c "$login select (fn_staff_create_reservation('{\"branch_id\":\"00000000-0000-0000-0000-000000000010\",\"category_id\":\"00000000-0000-0000-0000-000000000030\",\"check_in\":\"2030-01-01\",\"check_out\":\"2030-01-03\",\"guest_name\":\"سباق\",\"guest_phone\":\"0500009999\",\"source_id\":\"00000000-0000-0000-0000-000000000021\"}'))->>'id';" | tail -1)
psql -d "$DB" -Atq -c "$login select fn_create_voucher(jsonb_build_object('reservation_id','$RES','kind','deposit','amount_halalas',4000,'method','cash','idempotency_key','race-dep'));" >/dev/null

# ---------- X01: two reservations race for the same room/period ----------
call_res() { # $1 = guest label, $2 = sleep before commit
  psql -d "$DB" -At <<EOF 2>&1 | grep -E "ERROR|^t$|^true$|^false$|^none$" | head -1
$login
begin;
select coalesce((fn_staff_create_reservation('{"branch_id":"00000000-0000-0000-0000-000000000010","category_id":"00000000-0000-0000-0000-000000000030","room_id":"00000000-0000-0000-0000-000000000198","check_in":"2030-02-01","check_out":"2030-02-04","guest_name":"$1","guest_phone":"05000$RANDOM","source_id":"00000000-0000-0000-0000-000000000021"}'))->>'ok', 'none');
select pg_sleep($2);
commit;
EOF
}
OUT="${TMPDIR:-/tmp}/zaaer-race"; mkdir -p "$OUT"
call_res "race A" 3 > "$OUT/a" & sleep 1
B=$(call_res "race B" 0)
wait
A=$(cat "$OUT/a")
ACTIVE=$(psql -d "$DB" -At -c "select count(*) from reservation_allocations where room_id='00000000-0000-0000-0000-000000000198' and status='active'")
CHARGES=$(psql -d "$DB" -At -c "select count(*) from reservations r where r.room_id='00000000-0000-0000-0000-000000000198'")
echo "X01 session A result: $A"
echo "X01 session B result: $B"
if [[ "$ACTIVE" == "1" && "$CHARGES" == "1" && "$B" == *"ALLOCATION_CONFLICT"* || "$B" == *"ROOM_NOT_AVAILABLE"* ]]; then
  echo "PASS X01 concurrent booking race → exactly one active allocation ($ACTIVE), one reservation ($CHARGES), loser got a conflict"
else
  echo "FAIL X01 active=$ACTIVE reservations=$CHARGES B=$B"; fail=1
fi

# ---------- X02: two deposit refunds of 30 against a 40 balance ----------
call_refund() { # $1 key, $2 sleep
  psql -d "$DB" -At <<EOF 2>&1 | grep -E "ERROR|^t$|^true$|^false$|^none$" | head -1
$login
begin;
select (fn_refund(jsonb_build_object('reservation_id','$RES','kind','deposit_refund','amount_halalas',3000,'method','cash','reason','race','idempotency_key','$1')))->>'ok';
select pg_sleep($2);
commit;
EOF
}
call_refund "race-r1" 3 > "$OUT/ra" & sleep 1
RB=$(call_refund "race-r2" 0)
wait
RA=$(cat "$OUT/ra")
BAL=$(psql -d "$DB" -At -c "$login select (fn_reservation_finance('$RES')->>'deposit_balance')::int;" | tail -1)
REFUNDED=$(psql -d "$DB" -At -c "select coalesce(sum(amount_halalas),0) from financial_vouchers where reservation_id='$RES' and kind='deposit_refund' and status='approved'")
# replay of the winner with its original key must not add a refund
REPLAY=$(psql -d "$DB" -At -c "$login select (fn_refund(jsonb_build_object('reservation_id','$RES','kind','deposit_refund','amount_halalas',3000,'method','cash','reason','race','idempotency_key','race-r1')))->>'duplicate';" | tail -1)
REFUNDED2=$(psql -d "$DB" -At -c "select coalesce(sum(amount_halalas),0) from financial_vouchers where reservation_id='$RES' and kind='deposit_refund' and status='approved'")
echo "X02 session A result: $RA"
echo "X02 session B result: $RB"
if [[ "$REFUNDED" == "3000" && "$BAL" == "1000" && "$RB" == *"REFUND_EXCEEDS_AVAILABLE"* && "$REPLAY" == "true" && "$REFUNDED2" == "3000" ]]; then
  echo "PASS X02 concurrent refunds → total refunded 30 of 40, balance 10, loser rejected, replay idempotent"
else
  echo "FAIL X02 refunded=$REFUNDED balance=$BAL B=$RB replay=$REPLAY after=$REFUNDED2"; fail=1
fi
# ---------- F07c (was X03 — decision 57): two payments with the SAME idempotency key at the same time → one voucher;
#            two with DIFFERENT keys → two vouchers and the cached paid equals their sum ----------
call_pay() { # $1 key, $2 amount, $3 sleep
  psql -d "$DB" -At <<EOF 2>&1 | grep -E "ERROR|^t$|^true$|^false$|^none$" | head -1
$login
begin;
select coalesce((fn_staff_confirm_payment('$RES', 'pos', $2, 'REF-$1', '$1'))->>'ok', 'none');
select pg_sleep($3);
commit;
EOF
}
before=$(psql -d "$DB" -At -c "select count(*) from financial_vouchers where reservation_id='$RES' and kind='receipt' and status='approved'")
call_pay "race-pay-same" 5000 3 > "$OUT/pa" & sleep 1
PB=$(call_pay "race-pay-same" 5000 0)
wait
PA=$(cat "$OUT/pa")
same=$(psql -d "$DB" -At -c "select count(*) from financial_vouchers where reservation_id='$RES' and kind='receipt' and status='approved'")
paid0=$(psql -d "$DB" -At -c "select paid_halalas from reservations where id='$RES'")
call_pay "race-pay-a" 7000 3 > "$OUT/pc" & sleep 1
PD=$(call_pay "race-pay-b" 3000 0)
wait
after=$(psql -d "$DB" -At -c "select count(*) from financial_vouchers where reservation_id='$RES' and kind='receipt' and status='approved'")
paid1=$(psql -d "$DB" -At -c "select paid_halalas from reservations where id='$RES'")
echo "F07c same key: A=$PA B=$PB vouchers $before→$same | different keys: B=$PD vouchers $same→$after paid $paid0→$paid1"
if [[ "$PA" == "true" && "$PB" == "true" && $((same - before)) -eq 1 && $((after - same)) -eq 2 && $((paid1 - paid0)) -eq 10000 ]]; then
  echo "PASS F07c concurrent payments → same key recorded once (replay answered from storage); different keys both recorded, paid += 100 SAR"
else
  echo "FAIL F07c"; fail=1
fi
exit $fail
