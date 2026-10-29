#!/usr/bin/env bash
# X01 / X02 / X05 — true concurrency tests with TWO independent sessions (see ZAAER-TESTING-AND-CONTROL-RULES §10),
# with the races of decisions 45 (extending, switching and several units, each against a new booking), 46 (check-out
# against an extension read at the same version; one correction run twice at once), 49 (deactivating a unit and
# archiving a type, each against a booking, in both orders), 11 and 27 (IR01–IR03: overlapping partial invoices,
# one voucher corrected twice, the departure's invoice against a partial one), and 4, 21 and 69 (PX01–PX03: one platform
# number on two bookings at once, one platform cancellation number twice, a guest ban against the guest's arrival).
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
select coalesce((fn_staff_create_reservation('{"branch_id":"00000000-0000-0000-0000-000000000010","category_id":"00000000-0000-0000-0000-000000000030","room_id":"00000000-0000-0000-0000-000000000198","check_in":"2030-02-01","check_out":"2030-02-04","guest_name":"$1","guest_phone":"0550$(printf %06d $RANDOM)","source_id":"00000000-0000-0000-0000-000000000021"}'))->>'ok', 'none');
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
# decision 45: the counts are required whatever the loser's message (the parentheses were missing before)
if [[ "$ACTIVE" == "1" && "$CHARGES" == "1" && ( "$B" == *"ALLOCATION_CONFLICT"* || "$B" == *"ROOM_NOT_AVAILABLE"* ) ]]; then
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

# =====================================================================================================================
# Decisions 45, 46, 49 — every race below: session A holds its transaction 3 s, session B starts 1 s later.
# Accepted outcomes only: one valid order, or a declared conflict for the loser. Never a hybrid.
# =====================================================================================================================
psql -d "$DB" -v ON_ERROR_STOP=1 -q <<'SQL'
insert into rooms(id, branch_id, organization_id, category_id, room_number, is_active, status) values
 ('00000000-0000-0000-0000-000000000170','00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000030','X-R0', true, 'available'),
 ('00000000-0000-0000-0000-000000000171','00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000030','X-R1', true, 'available'),
 ('00000000-0000-0000-0000-000000000172','00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000030','X-R2', true, 'available'),
 ('00000000-0000-0000-0000-000000000173','00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000030','X-R3', true, 'available'),
 ('00000000-0000-0000-0000-000000000174','00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000030','X-R4', true, 'available'),
 ('00000000-0000-0000-0000-000000000175','00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000030','X-R5', true, 'available'),
 ('00000000-0000-0000-0000-000000000176','00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000030','X-R6', true, 'available'),
 ('00000000-0000-0000-0000-000000000177','00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000030','X-R7', true, 'available'),
 ('00000000-0000-0000-0000-000000000178','00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000030','X-R8', true, 'available'),
 ('00000000-0000-0000-0000-000000000179','00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000030','X-R9', true, 'available'),
 ('00000000-0000-0000-0000-000000000180','00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000030','X-R10', true, 'available'),
 ('00000000-0000-0000-0000-000000000181','00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000030','X-R11', true, 'available')
on conflict (id) do nothing;
-- guests matched and Shomoos accepted (those paths have their own tests; here only the arrival matters)
create or replace function t_race_ready(p uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  update reservation_guests set data_submitted = true, verification_status = 'verified' where reservation_id = p;
  update reservations set identity_status = 'verified', government_registration = true, gov_registration_ref = 'SHM-RACE',
         shomoos_guest_count = adults + companions, shomoos_accepted_at = now() where id = p;
end $$;
SQL
BR='00000000-0000-0000-0000-000000000010'; CAT='00000000-0000-0000-0000-000000000030'; SRC='00000000-0000-0000-0000-000000000021'
q() { psql -d "$DB" -At -c "$login $1" | tail -1; }
qs() { psql -d "$DB" -At -c "$1" | tail -1; }
booking() { # $1 room (or empty for a type-level stay), $2 from, $3 to, $4 category (default the studio)
  local room=""; [[ -n "$1" ]] && room="'room_id','$1',"
  echo "fn_staff_create_reservation(jsonb_build_object('branch_id','$BR','category_id','${4:-$CAT}',${room}'check_in','$2','check_out','$3','guest_phone','0552' || lpad((floor(random()*1000000))::int::text, 6, '0'),'guest_name','سباق','source_id','$SRC'))->>'ok'"
}
sess() { # $1 expression returning text, $2 seconds to hold the transaction
  psql -d "$DB" -At <<SQL 2>&1 | grep -E "ERROR|^R:" | head -1
$login
begin;
select 'R:' || coalesce(($1)::text, 'null');
select pg_sleep($2);
commit;
SQL
}
race() { # $1 session A (holds), $2 session B (starts 1 s later) → RA, RB
  sess "$1" 3 > "$OUT/race_a" & sleep 1
  RB=$(sess "$2" 0)
  wait
  RA=$(cat "$OUT/race_a")
}
conflict() { [[ "$1" == *"ALLOCATION_CONFLICT"* || "$1" == *"ROOM_NOT_AVAILABLE"* ]]; }
check() { # $1 name, $2 0|1 (the condition's status), $3 detail
  if [[ "$2" == "0" ]]; then echo "PASS $1"; else echo "FAIL $1 — $3"; fail=1; fi
}
TODAY=$(qs "select fn_branch_today('$BR')")
D2=$(qs "select fn_branch_today('$BR') + 2"); D3=$(qs "select fn_branch_today('$BR') + 3")
# a stay in house today on $1, its nights paid, no deposit (with the reason)
in_house() {
  local res; res=$(q "select (fn_staff_create_reservation(jsonb_build_object('branch_id','$BR','category_id','$CAT','room_id','$1','check_in','$TODAY','check_out','$D2','guest_phone','0552' || lpad((floor(random()*1000000))::int::text, 6, '0'),'guest_name','سباق مقيم','source_id','$SRC')))->>'id';")
  qs "select t_race_ready('$res');" >/dev/null
  q "select fn_staff_check_in(jsonb_build_object('reservation_id','$res','deposit_reason','سباق',
       'rent', jsonb_build_object('amount_halalas', (fn_reservation_finance('$res')->>'balance_due')::bigint, 'method','cash','idempotency_key','race-rent-$res')))->>'ok';" >/dev/null
  echo "$res"
}

# ---------- X01b (decision 45): extending a stay against a new booking of the added nights ----------
R1=$(q "select (fn_staff_create_reservation(jsonb_build_object('branch_id','$BR','category_id','$CAT','room_id','00000000-0000-0000-0000-000000000170','check_in','2031-01-01','check_out','2031-01-03','guest_phone','0552' || lpad((floor(random()*1000000))::int::text, 6, '0'),'guest_name','سباق تمديد','source_id','$SRC')))->>'id';")
V1=$(qs "select version from reservations where id = '$R1'")
race "fn_staff_amend_stay('$R1', '2031-01-05', 'keep_rate', 'سباق', $V1)->>'ok'" "$(booking 00000000-0000-0000-0000-000000000170 2031-01-03 2031-01-05)"
N=$(qs "select count(*) from reservation_allocations where room_id = '00000000-0000-0000-0000-000000000170' and status = 'active'")
M=$(qs "select count(*) from reservations where room_id = '00000000-0000-0000-0000-000000000170'")
CO=$(qs "select check_out from reservations where id = '$R1'")
echo "X01b A=$RA B=$RB active=$N stays=$M check_out=$CO"
conflict "$RB" && [[ "$RA" == "R:true" && "$N" == "1" && "$M" == "1" && "$CO" == "2031-01-05" ]] && rc=0 || rc=1; check "X01b extend vs new booking → the extension holds the added nights, exactly one active allocation, the booking gets a clear conflict" $rc "A=$RA B=$RB"

# ---------- X01c (decision 45): switching a stay's unit against a new booking of that unit ----------
R2=$(q "select (fn_staff_create_reservation(jsonb_build_object('branch_id','$BR','category_id','$CAT','room_id','00000000-0000-0000-0000-000000000171','check_in','2031-02-01','check_out','2031-02-03','guest_phone','0552' || lpad((floor(random()*1000000))::int::text, 6, '0'),'guest_name','سباق تبديل','source_id','$SRC')))->>'id';")
V2=$(qs "select version from reservations where id = '$R2'")
race "fn_staff_switch_room('$R2', '00000000-0000-0000-0000-000000000172', null, 'سباق', $V2)->>'ok'" "$(booking 00000000-0000-0000-0000-000000000172 2031-02-01 2031-02-03)"
N=$(qs "select count(*) from reservation_allocations where room_id = '00000000-0000-0000-0000-000000000172' and status = 'active'")
M=$(qs "select count(*) from reservations where room_id = '00000000-0000-0000-0000-000000000172'")
echo "X01c A=$RA B=$RB active=$N stays=$M"
conflict "$RB" && [[ "$RA" == "R:true" && "$N" == "1" && "$M" == "1" ]] && rc=0 || rc=1; check "X01c switch vs new booking → exactly one active allocation on the unit, the booking gets a clear conflict" $rc "A=$RA B=$RB"

# ---------- X01d (decision 45): a single booking against a booking of several units, one of them the same ----------
race "$(booking 00000000-0000-0000-0000-000000000174 2031-03-01 2031-03-03)" \
     "fn_staff_create_reservation(jsonb_build_object('branch_id','$BR','category_id','$CAT','check_in','2031-03-01','check_out','2031-03-03','guest_phone','0552' || lpad((floor(random()*1000000))::int::text, 6, '0'),'guest_name','سباق جماعي','source_id','$SRC','units', jsonb_build_array(jsonb_build_object('room_id','00000000-0000-0000-0000-000000000173'), jsonb_build_object('room_id','00000000-0000-0000-0000-000000000174'))))->>'ok'"
N=$(qs "select count(*) from reservation_allocations where room_id = '00000000-0000-0000-0000-000000000174' and status = 'active'")
P=$(qs "select count(*) from reservations where room_id = '00000000-0000-0000-0000-000000000173'")
echo "X01d A=$RA B=$RB active=$N partial=$P"
conflict "$RB" && [[ "$RA" == "R:true" && "$N" == "1" && "$P" == "0" ]] && rc=0 || rc=1; check "X01d single vs several units → one allocation on the shared unit, and no part of the several-unit booking survives" $rc "A=$RA B=$RB partial=$P"

# ---------- X05 (decision 46): check-out against an extension, both read at the same version ----------
R4=$(in_house 00000000-0000-0000-0000-000000000175)
V4=$(qs "select version from reservations where id = '$R4'")
race "fn_staff_check_out(jsonb_build_object('reservation_id','$R4'))->>'ok'" "fn_staff_amend_stay('$R4', '$D3', 'keep_rate', 'سباق', $V4)->>'ok'"
ST=$(qs "select status || ' ' || check_out from reservations where id = '$R4'")
echo "X05a A=$RA B=$RB state=$ST"
# departed: the check-out invoiced the stay (0036), and with nothing owed or held it closed by itself
[[ "$RA" == "R:true" && ( "$RB" == *"VERSION_CONFLICT"* || "$RB" == *"RESERVATION_STATUS_INVALID"* ) && "$ST" == "closed $D2" ]] && rc=0 || rc=1; check "X05a check-out first → the extension gets a declared conflict; the stay stays departed (never back in house)" $rc "A=$RA B=$RB $ST"
R5=$(in_house 00000000-0000-0000-0000-000000000176)
V5=$(qs "select version from reservations where id = '$R5'")
race "fn_staff_amend_stay('$R5', '$D3', 'keep_rate', 'سباق', $V5)->>'ok'" "fn_staff_check_out(jsonb_build_object('reservation_id','$R5'))->>'ok'"
ST=$(qs "select status || ' ' || check_out from reservations where id = '$R5'")
echo "X05b A=$RA B=$RB state=$ST"
[[ "$RA" == "R:true" && "$RB" == "R:false" && "$ST" == "checked_in $D3" ]] && rc=0 || rc=1; check "X05b extension first → the check-out sees the added night owed and is refused; one valid order, no hybrid" $rc "A=$RA B=$RB $ST"

# ---------- X05c (decision 49): deactivating a unit against a booking of it, both orders ----------
V7=$(qs "select version from rooms where id = '00000000-0000-0000-0000-000000000177'")
race "$(booking 00000000-0000-0000-0000-000000000177 2031-04-01 2031-04-03)" "fn_admin_upsert_room(jsonb_build_object('id','00000000-0000-0000-0000-000000000177','is_active',false,'version',$V7))->>'ok'"
ST=$(qs "select is_active || ' ' || (select count(*) from reservation_allocations a where a.room_id = r.id and a.status = 'active') from rooms r where id = '00000000-0000-0000-0000-000000000177'")
echo "X05c1 A=$RA B=$RB unit=$ST"
[[ "$RA" == "R:true" && "$RB" == *"HAS_FUTURE_COMMITMENTS"* && "$ST" == "true 1" ]] && rc=0 || rc=1; check "X05c1 booking first → the unit stays active with its booking; deactivating gets a clear conflict" $rc "A=$RA B=$RB $ST"
V8=$(qs "select version from rooms where id = '00000000-0000-0000-0000-000000000178'")
race "fn_admin_upsert_room(jsonb_build_object('id','00000000-0000-0000-0000-000000000178','is_active',false,'version',$V8))->>'ok'" "$(booking 00000000-0000-0000-0000-000000000178 2031-04-01 2031-04-03)"
ST=$(qs "select is_active || ' ' || (select count(*) from reservations x where x.room_id = r.id) from rooms r where id = '00000000-0000-0000-0000-000000000178'")
echo "X05c2 A=$RA B=$RB unit=$ST"
conflict "$RB" && [[ "$RA" == "R:true" && "$ST" == "false 0" ]] && rc=0 || rc=1; check "X05c2 deactivation first → the unit is inactive with no new booking; the booking gets a clear conflict" $rc "A=$RA B=$RB $ST"

# ---------- X05d (decision 49): archiving a unit type against a booking of it, both orders ----------
C1=$(q "select (fn_admin_upsert_room_category(jsonb_build_object('branch_id','$BR','name_ar','نوع سباق 1','base_price_halalas',9000)))->>'id';")
C2=$(q "select (fn_admin_upsert_room_category(jsonb_build_object('branch_id','$BR','name_ar','نوع سباق 2','base_price_halalas',9000)))->>'id';")
race "$(booking '' 2031-05-01 2031-05-02 "$C1")" "fn_admin_archive_definition('room_category', '$C1', 'سباق')->>'ok'"
ST=$(qs "select (archived_at is null) || ' ' || (select count(*) from reservations x where x.room_category_id = c.id) from room_categories c where id = '$C1'")
echo "X05d1 A=$RA B=$RB type=$ST"
[[ "$RA" == "R:true" && "$RB" == *"HAS_OPEN_COMMITMENTS"* && "$ST" == "true 1" ]] && rc=0 || rc=1; check "X05d1 booking first → the type stays with its booking; archiving gets a clear conflict" $rc "A=$RA B=$RB $ST"
race "fn_admin_archive_definition('room_category', '$C2', 'سباق')->>'ok'" "$(booking '' 2031-05-01 2031-05-02 "$C2")"
ST=$(qs "select (archived_at is null) || ' ' || (select count(*) from reservations x where x.room_category_id = c.id) from room_categories c where id = '$C2'")
echo "X05d2 A=$RA B=$RB type=$ST"
[[ "$RA" == "R:true" && ( "$RB" == *"CATEGORY_ARCHIVED"* || "$RB" == *"BRANCH_MISMATCH"* ) && "$ST" == "false 0" ]] && rc=0 || rc=1; check "X05d2 archiving first → the type is archived with no new booking; the booking gets a clear refusal" $rc "A=$RA B=$RB $ST"

# ---------- X05e (decision 46): the same correction run twice at once succeeds once ----------
R6=$(in_house 00000000-0000-0000-0000-000000000179)
q "select fn_staff_check_out(jsonb_build_object('reservation_id','$R6'))->>'ok';" >/dev/null
race "fn_staff_reopen_stay(jsonb_build_object('reservation_id','$R6','reason','سباق'))->>'ok'" "fn_staff_reopen_stay(jsonb_build_object('reservation_id','$R6','reason','سباق'))->>'ok'"
ST=$(qs "select status || ' ' || (select count(*) from review_items v where v.entity_id = r.id and v.kind = 'stay_reopened') from reservations r where id = '$R6'")
echo "X05e A=$RA B=$RB state=$ST"
[[ "$RA" == "R:true" && "$RB" == *"RESERVATION_STATUS_INVALID"* && "$ST" == "checked_in 1" ]] && rc=0 || rc=1; check "X05e reopening a departure twice at once → reopened once, one review item; the second is refused" $rc "A=$RA B=$RB $ST"

# ---------- IR01–IR03 (decisions 11, 27): invoices and voucher corrections at the same time ----------
# two partial invoices of one stay for overlapping nights: one invoice, the other refused with the overlap
R7=$(q "select (fn_staff_create_reservation(jsonb_build_object('branch_id','$BR','category_id','$CAT','check_in','2031-06-01','check_out','2031-06-05','guest_phone','0552' || lpad((floor(random()*1000000))::int::text, 6, '0'),'guest_name','سباق فاتورة','source_id','$SRC')))->>'id';")
race "fn_staff_issue_invoice(jsonb_build_object('reservation_id','$R7','from','2031-06-01','to','2031-06-04'))->>'ok'" \
     "fn_staff_issue_invoice(jsonb_build_object('reservation_id','$R7','from','2031-06-02','to','2031-06-05'))->>'ok'"
ST=$(qs "select count(*) from invoices where reservation_id = '$R7' and status = 'issued'")
echo "IR01 A=$RA B=$RB invoices=$ST"
[[ "$RA" == "R:true" && "$RB" == *"INVOICE_PERIOD_OVERLAP"* && "$ST" == "1" ]] && rc=0 || rc=1; check "IR01 two partial invoices for overlapping nights at once → one invoice; the other is refused with the overlap" $rc "A=$RA B=$RB $ST"
# one voucher corrected twice at once (two keys): one replacement and one review item; the second finds it cancelled
V8=$(q "select (fn_create_voucher(jsonb_build_object('reservation_id','$R7','kind','receipt','amount_halalas',10000,'method','cash','idempotency_key','race-v8')))->>'voucher_id';")
race "fn_staff_correct_voucher(jsonb_build_object('voucher_id','$V8','reason','سباق','amount_halalas',9000,'idempotency_key','race-c1'))->>'ok'" \
     "fn_staff_correct_voucher(jsonb_build_object('voucher_id','$V8','reason','سباق','amount_halalas',8000,'idempotency_key','race-c2'))->>'ok'"
ST=$(qs "select count(*) filter (where status = 'approved') || ' ' || coalesce(sum(amount_halalas) filter (where status = 'approved'), 0) || ' '
          || (select count(*) from review_items v where v.kind = 'voucher_corrected' and v.reservation_id = '$R7') from financial_vouchers where reservation_id = '$R7'")
echo "IR02 A=$RA B=$RB state=$ST"
[[ "$RA" == "R:true" && "$RB" == *"VOUCHER_STATUS_INVALID"* && "$ST" == "1 9000 1" ]] && rc=0 || rc=1; check "IR02 one voucher corrected twice at once → one replacement, one review item; the second finds it cancelled" $rc "A=$RA B=$RB $ST"
# the departure's automatic invoice against a partial invoice of the whole stay: either order, the stay is invoiced once
R9=$(in_house 00000000-0000-0000-0000-000000000180)
race "fn_staff_check_out(jsonb_build_object('reservation_id','$R9'))->>'ok'" \
     "fn_staff_issue_invoice(jsonb_build_object('reservation_id','$R9','from','$TODAY','to','$D2'))->>'ok'"
ST=$(qs "select count(*) || ' ' || (select status from reservations where id = '$R9') || ' ' || fn_uninvoiced_value('$R9') from invoices where reservation_id = '$R9' and status = 'issued'")
echo "IR03 A=$RA B=$RB state=$ST"
[[ "$RA" == "R:true" && "$RB" == *"NOTHING_TO_INVOICE"* && "$ST" == "1 closed 0" ]] && rc=0 || rc=1; check "IR03 check-out against a partial invoice of the whole stay → one invoice carries the stay; the other finds nothing left" $rc "A=$RA B=$RB $ST"

# ---------- PX01–PX03 (decisions 4, 21, 69): platform numbers, cancellation numbers and bans at the same time ----------
OTA=$(qs "select id from booking_sources where organization_id = '00000000-0000-0000-0000-000000000001' and code = 'booking_com'")
ota() { # $1 platform number, $2 from, $3 to
  echo "fn_staff_create_reservation(jsonb_build_object('branch_id','$BR','category_id','$CAT','check_in','$2','check_out','$3','guest_phone','0552' || lpad((floor(random()*1000000))::int::text, 6, '0'),'guest_name','سباق منصة','source_id','$OTA','external_ref','$1','platform_collects',false,'platform_booked_on','$TODAY'))->>'ok'"
}
# one platform number on two new bookings at once: one is made, the other is refused (the constraint, not the pre-check)
P1=$(qs "select fn_branch_today('$BR') + 300"); P2=$(qs "select fn_branch_today('$BR') + 301"); P3=$(qs "select fn_branch_today('$BR') + 305"); P4=$(qs "select fn_branch_today('$BR') + 306")
race "$(ota PX-RACE-1 $P1 $P2)" "$(ota PX-RACE-1 $P3 $P4)"
ST=$(qs "select count(*) from reservations where external_ref = 'PX-RACE-1'")
echo "PX01 A=$RA B=$RB bookings=$ST"
[[ "$RA" == "R:true" && "$RB" == *"DUPLICATE_EXTERNAL_REF"* && "$ST" == "1" ]] && rc=0 || rc=1; check "PX01 one platform number on two new bookings at once → one booking; the other is refused as a duplicate" $rc "A=$RA B=$RB $ST"
# one platform cancellation number entered twice at once: cancelled once, the second is told it was already done
R10=$(q "select (fn_staff_create_reservation(jsonb_build_object('branch_id','$BR','category_id','$CAT','check_in','$P3','check_out','$P4','guest_phone','0552' || lpad((floor(random()*1000000))::int::text, 6, '0'),'guest_name','سباق إلغاء','source_id','$OTA','external_ref','PX-RACE-2','platform_collects',false,'platform_booked_on','$TODAY')))->>'id';")
race "fn_staff_cancel(jsonb_build_object('reservation_id','$R10','reason','سباق','cancel_number','PX-CXL-2'))->>'cancelled'" \
     "fn_staff_cancel(jsonb_build_object('reservation_id','$R10','reason','سباق','cancel_number','PX-CXL-2'))->>'duplicate'"
ST=$(qs "select status || ' ' || (select count(*) from audit_events where entity_id = r.id and action = 'reservation.cancelled') from reservations r where id = '$R10'")
echo "PX02 A=$RA B=$RB state=$ST"
[[ "$RA" == "R:1" && "$RB" == "R:true" && "$ST" == "cancelled 1" ]] && rc=0 || rc=1; check "PX02 one cancellation number twice at once → cancelled once; the second is a duplicate" $rc "A=$RA B=$RB $ST"
# a guest ban against that guest's arrival: one valid order — here the arrival, then the ban, which then holds back the code
R11=$(q "select (fn_staff_create_reservation(jsonb_build_object('branch_id','$BR','category_id','$CAT','room_id','00000000-0000-0000-0000-000000000181','check_in','$TODAY','check_out','$D2','guest_name','سباق حظر','guest_phone','0500077011','source_id','$SRC')))->>'id';")
qs "select t_race_ready('$R11');" >/dev/null
P11=$(qs "select guest_profile_id from reservation_guests where reservation_id = '$R11' and is_primary")
race "fn_guest_ban(jsonb_build_object('profile_id','$P11','ban',true,'reason','سباق'))->>'ok'" \
     "fn_staff_check_in(jsonb_build_object('reservation_id','$R11','deposit_reason','سباق','rent', jsonb_build_object('amount_halalas', (fn_reservation_finance('$R11')->>'balance_due')::bigint, 'method','cash','idempotency_key','race-rent-$R11')))->>'ok'"
ST=$(qs "select r.status || ' ' || (select count(*) from guest_bans b where b.guest_profile_id = '$P11' and b.lifted_at is null) || ' ' || ('الضيف محظور من الإدارة' = any(fn_code_blockers(r.id))) from reservations r where r.id = '$R11'")
echo "PX03 A=$RA B=$RB state=$ST"
[[ "$RA" == "R:true" && ( ( "$RB" == "R:true" && "$ST" == "checked_in 1 true" ) || ( "$RB" == "R:false" && "$ST" == "confirmed 1 false" ) ) ]] && rc=0 || rc=1; check "PX03 a ban against the guest's arrival → one valid order: in and banned with the code held back, or banned and not in" $rc "A=$RA B=$RB $ST"

# ---------- VD08 (0047, the owner's note 14): two units of one branch given the same new code at once ----------
psql -d "$DB" -q -c "insert into rooms(id, branch_id, organization_id, category_id, room_number, is_active, status) values
 ('00000000-0000-0000-0000-000000000190','00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000030','X-KC1', true, 'available'),
 ('00000000-0000-0000-0000-000000000191','00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000030','X-KC2', true, 'available')" > /dev/null
race "fn_staff_rotate_keybox_code('00000000-0000-0000-0000-000000000190', '739146', true)->>'ok'" \
     "fn_staff_rotate_keybox_code('00000000-0000-0000-0000-000000000191', '739146', true)->>'ok'"
ST=$(qs "select count(*) from keyboxes where room_id in ('00000000-0000-0000-0000-000000000190', '00000000-0000-0000-0000-000000000191')")
echo "VD08 A=$RA B=$RB boxes=$ST"
[[ "$RA" == "R:true" && "$RB" == *"CODE_IN_USE"* && "$ST" == "1" ]] && rc=0 || rc=1; check "VD08 one new code saved for two units of a branch at once → one box takes it; the other is refused as in use" $rc "A=$RA B=$RB $ST"

exit $fail
