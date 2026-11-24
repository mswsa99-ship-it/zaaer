#!/usr/bin/env bash
# GQ-RACE (review fix 2 of 24 Nov 2026): two concurrent psql sessions race one conversation
# whose session cap is 1 admitted guest message. With the old recount of conversation_messages
# both sessions read a passing count before either message existed and both were admitted; the
# admitted-session counter admits exactly one. This needs committed fixtures and two live
# connections, so it cannot run inside the rolled-back guest_quota_tests.sql suite. Fixtures are
# invented and deleted at the end. Usage: guest_quota_race.sh <database>
set -uo pipefail
DB="${1:?database name}"
ORG=70000000-0000-0000-0000-000000000701
BRANCH=70000000-0000-0000-0000-000000000711
CONV=70000000-0000-0000-0000-000000000721

psql -d "$DB" -v ON_ERROR_STOP=1 -q <<SQL
insert into organizations(id, name_ar) values ('$ORG', 'فندق سباق الحصص');
insert into branches(id, organization_id, name_ar) values ('$BRANCH', '$ORG', 'فرع السباق');
insert into conversations(id, organization_id, branch_id, channel, status, client_fingerprint)
values ('$CONV', '$ORG', '$BRANCH', 'screen', 'active', 'race-setup');
insert into ai_settings(organization_id) values ('$ORG') on conflict do nothing;
update ai_settings set per_session_message_limit = 1, guest_otp_after_messages = 100,
      guest_device_daily_message_limit = 100, guest_branch_daily_message_limit = 1000
 where organization_id = '$ORG';
SQL

# Two sessions, five attempts each, started together. Each attempt is its own transaction —
# exactly how the edge function calls the reserve.
race_session() { # $1 fingerprint, $2 output file
  : > "$2"
  for i in 1 2 3 4 5; do
    psql -d "$DB" -tA -c "select fn_ai_guest_reserve('$BRANCH', '$CONV', '$1', true) ->> 'status';" >> "$2" 2>&1
  done
}
A_OUT="${TMPDIR:-/tmp}/gq-race-a.$$.out"
B_OUT="${TMPDIR:-/tmp}/gq-race-b.$$.out"
race_session race-A "$A_OUT" &
PID_A=$!
race_session race-B "$B_OUT" &
PID_B=$!
wait "$PID_A" "$PID_B"

OK_TOTAL=$(grep -c '^ok$' "$A_OUT" "$B_OUT" | awk -F: '{s += $2} END {print s}')
ADMITTED=$(psql -d "$DB" -tA -c "select admitted from ai_guest_session_usage where conversation_id = '$CONV';" 2>/dev/null || echo "no-counter")
DEVICES=$(psql -d "$DB" -tA -c "select coalesce(sum(messages), 0) from ai_guest_usage_daily where organization_id = '$ORG';" 2>/dev/null || echo "?")

echo "-- session A: $(tr '\n' ' ' < "$A_OUT")"
echo "-- session B: $(tr '\n' ' ' < "$B_OUT")"
echo "-- admitted counter: $ADMITTED, device counters total: $DEVICES"

FAIL=0
if [ "$OK_TOTAL" = "1" ] && [ "$ADMITTED" = "1" ] && [ "$DEVICES" = "1" ]; then
  echo "PASS | GQ-RACE two concurrent psql sessions at a session cap of 1: exactly one admitted, the counter reads 1, one device message consumed"
else
  echo "FAIL | GQ-RACE two concurrent psql sessions at a session cap of 1: expected 1 admitted, got ok=$OK_TOTAL admitted=$ADMITTED devices=$DEVICES"
  FAIL=1
fi

psql -d "$DB" -q -c "delete from organizations where id = '$ORG';" > /dev/null 2>&1
rm -f "$A_OUT" "$B_OUT"
exit $FAIL
