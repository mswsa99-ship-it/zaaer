#!/usr/bin/env bash
# =====================================================================
#  The phone app that relays the bank's messages (A9; RL* in tests/acceptance-library.json).
#  1. Its rules (android/app/src/main/java/sa/fivehours/relay/core, plain Java with no Android in it) are compiled
#     with javac and tried by android/core-tests (RL01–RL06): the setup text, the account rule, what is queued and
#     what is not, the signed email, sending with no internet / a refused password / a working server.
#  2. The email it writes is the one kept in tests/android/fixtures (RL06); the mail reader reads it (RL10, vitest).
#  3. When a database is given (PGHOST), the server's own intake takes that email: inside a transaction that is
#     rolled back, the mailbox and the key are the test ones and an account has the rule 605…4321; fn_bank_ingest
#     must read it as one movement (RL11).
#  The Android screens and receivers are built into the APK by .github/workflows/android.yml.
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."
command -v javac >/dev/null || { echo "javac not found: the phone app's rules cannot be tried"; exit 1; }
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
javac -encoding UTF-8 -Xlint:-options -d "$OUT" $(find android/app/src/main/java/sa/fivehours/relay/core android/core-tests -name '*.java') 2>&1 | grep -v '^Picked up' || true
[[ -f "$OUT/sa/fivehours/relay/core/RelayCoreTests.class" ]] || { echo "the phone app's rules do not compile"; exit 1; }
java -Dstdout.encoding=UTF-8 -cp "$OUT" sa.fivehours.relay.core.RelayCoreTests tests/android/fixtures/relay-sample.eml 2>&1 | grep -v '^Picked up'
status=${PIPESTATUS[0]}
[[ $status -eq 0 ]] || exit $status

if [[ -z "${PGHOST:-}" ]]; then echo "RL11 not run here: no database (PGHOST); the verify gate runs it"; exit 0; fi
DB="${TEST_DB:-airec_test}"
psql -d "$DB" -Atc "select 1" >/dev/null 2>&1 || { echo "RL11 needs the test database $DB (tests/sql/run.sh builds it)"; exit 1; }
BODY=$(python3 -I - tests/android/fixtures/relay-sample.eml <<'PY'
import base64, sys
raw = open(sys.argv[1], 'rb').read().decode('latin-1').replace('\r\n', '\n')
print(base64.b64decode(raw.split('\n\n', 1)[1]).decode('utf-8'), end='')
PY
)
RES=$(psql -d "$DB" -v ON_ERROR_STOP=1 -At -v body="$BODY" <<'SQL'
begin;
-- the test mailbox and key (the ones RelayCoreTests signs with), and one bank account with the rule 605…4321
insert into bank_mail_settings(organization_id) select id from organizations order by created_at limit 1 on conflict (organization_id) do nothing;
update bank_mail_settings set mailbox_address = 'relay.test@example.com', allowed_senders = array['AlRajhiBank'],
  relay_key_encrypted = extensions.pgp_sym_encrypt('0123456789abcdef0123456789abcdef0123456789abcdef', fn_secret('keybox_key'));
update cash_accounts set account_prefix = null, account_suffix = null where account_prefix = '605' and account_suffix = '4321';
update cash_accounts set account_prefix = '605', account_suffix = '4321'
 where id = (select a.id from cash_accounts a join bank_mail_settings s on s.organization_id = a.organization_id
              where a.kind = 'bank_account' and a.archived_at is null order by a.created_at limit 1);
set local role service_role;
select set_config('rl.r', fn_bank_ingest(jsonb_build_object('message_id', '<rl11@example.com>', 'from', 'relay.test@example.com', 'date', '2026-11-13T06:12:00Z',
                                                            'subject', 'FIVEHOURS-RELAY', 'body', :'body'))::text, true) is not null;
reset role;
select (r->>'status') || '|' || coalesce((select amount_halalas::text || '|' || direction || '|' || coalesce(reference, '') from bank_movements where id = (r->>'movement_id')::uuid), '')
  from (select current_setting('rl.r')::jsonb r) x;
rollback;
SQL
)
RES=$(echo "$RES" | grep '|' | tail -1)
if [[ "$RES" == "parsed|45000|in|AND1001" ]]; then
  echo "PASS RL11 the server takes the app's email as one movement: 450.00 in, reference AND1001 (rolled back)"
else
  echo "FAIL RL11 the server takes the app's email as one movement — got: $RES"; exit 1
fi
