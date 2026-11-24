-- =====================================================================
-- Guest assistant budget (plan 5.1, S1; migration 0082). GQ01–GQ12.
-- Runs after the other suites on the same DB. All fixtures invented, inside one rolled-back
-- transaction. Demo hotel 00000000-...-0001, branch 00000000-...-0010.
--
-- GQ01 is the written flooding experiment (تجربة إغراق مكتوبة) the plan asks for: one device
-- fires 20 reservation calls at a counter limited to 5 — exactly 5 are admitted, the counter
-- never reads more than 5, and every later call is refused. The same statement shape
-- (check-and-increment in one upsert, behind the per-device advisory lock) is what the live
-- flood from many simultaneous browsers hits. The two-session race rehearsal the review asked
-- for is GQ-RACE in tests/sql/guest_quota_race.sh (two concurrent psql sessions; it cannot run
-- inside this suite's one rolled-back transaction).
-- =====================================================================
\set ON_ERROR_STOP on
begin;
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create or replace function t_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;

create temp table gq(k text primary key, v text);
grant all on gq to public;

do $$
declare
  v_org uuid := '00000000-0000-0000-0000-000000000001';
  v_branch uuid := '00000000-0000-0000-0000-000000000010';
  v_org2 uuid := '90000000-0000-0000-0000-000000000201';
  v_branch2 uuid := '90000000-0000-0000-0000-000000000211';
  v_branch3 uuid := '90000000-0000-0000-0000-000000000212';
  v_conv uuid; v_conv2 uuid; r jsonb; i int; n_ok int; n_total int; n int; v_req int; v_blocked boolean;
  v_b1 int;
begin
  insert into organizations(id, name_ar) values (v_org2, 'فندق فحص الحصص');
  insert into branches(id, organization_id, name_ar) values (v_branch2, v_org2, 'فرع الحصص'), (v_branch3, v_org, 'فرع الحصص الثاني');
  insert into conversations(organization_id, branch_id, channel, status, client_fingerprint)
  values (v_org, v_branch, 'screen', 'active', 'gq-flood') returning id into v_conv;

  -- generous baseline: only the limit under test is tight in each scenario
  update ai_settings set per_session_message_limit = 1000, guest_otp_after_messages = 100,
        guest_device_daily_message_limit = 100, guest_branch_daily_message_limit = 1000
   where organization_id = v_org;

  -- GQ01 the flooding experiment: 20 calls at a device capped at 5 → exactly 5 admitted
  update ai_settings set guest_device_daily_message_limit = 5 where organization_id = v_org;
  n_ok := 0;
  for i in 1..20 loop
    r := fn_ai_guest_reserve(v_branch, v_conv, 'gq-flood', false);
    if r->>'status' = 'ok' then n_ok := n_ok + 1; end if;
  end loop;
  select messages into n from ai_guest_usage_daily
   where organization_id = v_org and branch_id = v_branch and client_fingerprint = 'gq-flood' and day = (now() at time zone 'utc')::date;
  r := fn_ai_guest_reserve(v_branch, v_conv, 'gq-flood', false);
  perform t_record('GQ01 flood of 20 at a device capped at 5: exactly 5 admitted, the counter never past 5, then device_limit',
    n_ok = 5 and n = 5 and r->>'status' = 'device_limit', n_ok::text || '/' || n::text || '/' || (r->>'status'));

  -- GQ06 another device keeps its own share (an anonymous caller cannot drain someone else's)
  r := fn_ai_guest_reserve(v_branch, v_conv, 'gq-other', false);
  perform t_record('GQ06 a second device is admitted while the first is exhausted', r->>'status' = 'ok', r->>'status');
  update ai_settings set guest_device_daily_message_limit = 100 where organization_id = v_org;

  -- GQ02 the session limit is the admitted counter (review fix): three admissions at a cap of 3,
  -- then the fourth is refused for an anonymous and a verified caller alike. The cap no longer
  -- recounts conversation_messages — the message is inserted after the reserve's locks are gone.
  update ai_settings set per_session_message_limit = 3 where organization_id = v_org;
  insert into conversations(organization_id, branch_id, channel, status, client_fingerprint)
  values (v_org, v_branch, 'screen', 'active', 'gq-s2') returning id into v_conv2;
  n_ok := 0;
  for i in 1..3 loop
    r := fn_ai_guest_reserve(v_branch, v_conv2, 'gq-s2', false);
    if r->>'status' = 'ok' then n_ok := n_ok + 1; end if;
  end loop;
  r := fn_ai_guest_reserve(v_branch, v_conv2, 'gq-s2', false);
  n_total := case when r->>'status' = 'session_limit' then 1 else 0 end;
  r := fn_ai_guest_reserve(v_branch, v_conv2, 'gq-s2', true);
  perform t_record('GQ02 three admissions at a session cap of 3, then refused for an anonymous and a verified caller alike',
    n_ok = 3 and n_total = 1 and r->>'status' = 'session_limit', n_ok::text || '/' || (r->>'status'));
  update ai_settings set per_session_message_limit = 1000 where organization_id = v_org;

  -- GQ03 the phone code after a number of anonymous messages
  update ai_settings set guest_otp_after_messages = 3 where organization_id = v_org;
  n_ok := 0;
  for i in 1..3 loop
    r := fn_ai_guest_reserve(v_branch, v_conv, 'gq-otp', false);
    if r->>'status' = 'ok' then n_ok := n_ok + 1; end if;
  end loop;
  r := fn_ai_guest_reserve(v_branch, v_conv, 'gq-otp', false);
  n_total := case when r->>'status' = 'otp_required' then 1 else 0 end;
  select messages into n from ai_guest_usage_daily
   where organization_id = v_org and branch_id = v_branch and client_fingerprint = 'gq-otp' and day = (now() at time zone 'utc')::date;
  perform t_record('GQ03 after 3 anonymous messages the 4th asks for the phone code and consumes nothing',
    n_ok = 3 and n_total = 1 and n = 3, n_ok::text || '/' || (r->>'status') || '/' || n::text);
  r := fn_ai_guest_reserve(v_branch, v_conv, 'gq-otp', true);
  perform t_record('GQ03b a caller verified by the phone code carries on under the ordinary caps', r->>'status' = 'ok', r->>'status');
  update ai_settings set guest_otp_after_messages = 100 where organization_id = v_org;

  -- GQ04 the branch ceiling: two devices share it
  update ai_settings set guest_branch_daily_message_limit = 4 where organization_id = v_org;
  delete from ai_branch_usage_daily where branch_id = v_branch;
  n_ok := 0;
  for i in 1..6 loop
    r := fn_ai_guest_reserve(v_branch, v_conv, 'gq-branch-' || (i % 2), false);
    if r->>'status' = 'ok' then n_ok := n_ok + 1; end if;
  end loop;
  perform t_record('GQ04 the branch ceiling admits 4 messages across devices, then branch_limit', n_ok = 4 and r->>'status' = 'branch_limit', n_ok::text);

  -- GQ07 the branch ceiling is per branch; another hotel is untouched
  insert into conversations(organization_id, branch_id, channel, status, client_fingerprint)
  values (v_org, v_branch3, 'screen', 'active', 'gq-b3') returning id into v_conv2;
  r := fn_ai_guest_reserve(v_branch3, v_conv2, 'gq-b3', false);
  n_ok := case when r->>'status' = 'ok' then 1 else 0 end;
  insert into conversations(organization_id, branch_id, channel, status, client_fingerprint)
  values (v_org2, v_branch2, 'screen', 'active', 'gq-b2') returning id into v_conv2;
  r := fn_ai_guest_reserve(v_branch2, v_conv2, 'gq-b2', false);
  perform t_record('GQ07 an exhausted branch caps neither the next branch nor another hotel', n_ok = 1 and r->>'status' = 'ok', r->>'status');
  update ai_settings set guest_branch_daily_message_limit = 1000 where organization_id = v_org;

  -- GQ05 the hotel ceiling: the existing daily request budget, reserved atomically
  select coalesce((select requests from ai_usage_daily where organization_id = v_org and day = (now() at time zone 'utc')::date), 0) into v_req;
  update ai_settings set daily_request_limit = v_req + 2 where organization_id = v_org;
  n_ok := 0;
  for i in 1..4 loop
    r := fn_ai_guest_reserve(v_branch, v_conv, 'gq-hotel', false);
    if r->>'status' = 'ok' then n_ok := n_ok + 1; end if;
  end loop;
  perform t_record('GQ05 the hotel admits up to its daily budget, then hotel_limit', n_ok = 2 and r->>'status' = 'hotel_limit', n_ok::text || '/' || (r->>'status'));
  update ai_settings set daily_request_limit = 2000 where organization_id = v_org;

  -- GQ08 nobody else can reserve or read the counters; a conversation of another branch is not ours
  execute 'set local role anon';
  begin
    perform fn_ai_guest_reserve(v_branch, v_conv, 'gq-x', false);
    perform t_record('GQ08 a visitor cannot reserve assistant budget', false);
  exception when insufficient_privilege then perform t_record('GQ08 a visitor cannot reserve assistant budget', true); end;
  begin
    perform count(*) from ai_guest_usage_daily; perform count(*) from ai_branch_usage_daily;
    perform t_record('GQ08b a visitor cannot read the quota counters', false);
  exception when insufficient_privilege then perform t_record('GQ08b a visitor cannot read the quota counters', true); end;
  execute 'reset role';
  r := fn_ai_guest_reserve(v_branch2, v_conv, 'gq-x', false);
  perform t_record('GQ08c a conversation of another branch is refused', r->>'status' = 'conversation_not_found', r->>'status');

  -- GQ09 the limits' shape is checked
  begin
    update ai_settings set guest_otp_after_messages = 0 where organization_id = v_org;
    v_blocked := false;
  exception when check_violation then v_blocked := true; end;
  perform t_record('GQ09 a limit outside its range is refused', v_blocked, null);

  -- GQ10–GQ12 a refused message consumes nothing (review fix 1: before it, a reject after the
  -- device's +1 kept that +1). Each scenario snapshots every counter, is refused at one cap, and
  -- checks that no counter — device, branch, hotel, session — moved.
  -- GQ10 refused at the branch ceiling
  insert into conversations(organization_id, branch_id, channel, status, client_fingerprint)
  values (v_org, v_branch, 'screen', 'active', 'gq-r10') returning id into v_conv2;
  select coalesce((select messages from ai_branch_usage_daily where branch_id = v_branch and day = (now() at time zone 'utc')::date), 0) into v_b1;
  select coalesce((select requests from ai_usage_daily where organization_id = v_org and day = (now() at time zone 'utc')::date), 0) into v_req;
  update ai_settings set guest_branch_daily_message_limit = v_b1 where organization_id = v_org;
  r := fn_ai_guest_reserve(v_branch, v_conv2, 'gq-r10', false);
  perform t_record('GQ10 a branch_limit reject consumes nothing: device, branch, hotel and session counters unmoved',
    r->>'status' = 'branch_limit'
    and not exists (select 1 from ai_guest_usage_daily where organization_id = v_org and branch_id = v_branch and client_fingerprint = 'gq-r10' and day = (now() at time zone 'utc')::date)
    and (select messages from ai_branch_usage_daily where branch_id = v_branch and day = (now() at time zone 'utc')::date) = v_b1
    and (select requests from ai_usage_daily where organization_id = v_org and day = (now() at time zone 'utc')::date) = v_req
    and not exists (select 1 from ai_guest_session_usage where conversation_id = v_conv2),
    r->>'status');
  update ai_settings set guest_branch_daily_message_limit = 1000 where organization_id = v_org;

  -- GQ11 refused at the hotel ceiling
  insert into conversations(organization_id, branch_id, channel, status, client_fingerprint)
  values (v_org, v_branch, 'screen', 'active', 'gq-r11') returning id into v_conv2;
  select coalesce((select messages from ai_branch_usage_daily where branch_id = v_branch and day = (now() at time zone 'utc')::date), 0) into v_b1;
  update ai_settings set daily_request_limit = v_req where organization_id = v_org;
  r := fn_ai_guest_reserve(v_branch, v_conv2, 'gq-r11', false);
  perform t_record('GQ11 a hotel_limit reject consumes nothing: device, branch, hotel and session counters unmoved',
    r->>'status' = 'hotel_limit'
    and not exists (select 1 from ai_guest_usage_daily where organization_id = v_org and branch_id = v_branch and client_fingerprint = 'gq-r11' and day = (now() at time zone 'utc')::date)
    and (select messages from ai_branch_usage_daily where branch_id = v_branch and day = (now() at time zone 'utc')::date) = v_b1
    and (select requests from ai_usage_daily where organization_id = v_org and day = (now() at time zone 'utc')::date) = v_req
    and not exists (select 1 from ai_guest_session_usage where conversation_id = v_conv2),
    r->>'status');
  update ai_settings set daily_request_limit = 2000 where organization_id = v_org;

  -- GQ12 refused at the session cap (one admission first, then the cap tightened to it)
  insert into conversations(organization_id, branch_id, channel, status, client_fingerprint)
  values (v_org, v_branch, 'screen', 'active', 'gq-r12') returning id into v_conv2;
  r := fn_ai_guest_reserve(v_branch, v_conv2, 'gq-r12a', false);
  n_ok := case when r->>'status' = 'ok' then 1 else 0 end;
  update ai_settings set per_session_message_limit = 1 where organization_id = v_org;
  select coalesce((select messages from ai_branch_usage_daily where branch_id = v_branch and day = (now() at time zone 'utc')::date), 0) into v_b1;
  select coalesce((select requests from ai_usage_daily where organization_id = v_org and day = (now() at time zone 'utc')::date), 0) into v_req;
  r := fn_ai_guest_reserve(v_branch, v_conv2, 'gq-r12b', false);
  perform t_record('GQ12 a session_limit reject consumes nothing: device, branch and hotel counters unmoved, the session stays at 1',
    n_ok = 1 and r->>'status' = 'session_limit'
    and not exists (select 1 from ai_guest_usage_daily where organization_id = v_org and branch_id = v_branch and client_fingerprint = 'gq-r12b' and day = (now() at time zone 'utc')::date)
    and (select messages from ai_branch_usage_daily where branch_id = v_branch and day = (now() at time zone 'utc')::date) = v_b1
    and (select requests from ai_usage_daily where organization_id = v_org and day = (now() at time zone 'utc')::date) = v_req
    and (select admitted from ai_guest_session_usage where conversation_id = v_conv2) = 1,
    r->>'status');
  update ai_settings set per_session_message_limit = 1000 where organization_id = v_org;
end $$;

select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),110) as detail from test_results order by ok, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
do $$ begin
  if exists (select 1 from test_results where ok is not true) then raise exception 'GUEST QUOTA TESTS FAILED'; end if;
end $$;
rollback;
