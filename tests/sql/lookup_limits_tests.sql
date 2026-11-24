-- =====================================================================
-- Plan 5.8 (finding S9, migration 0084): the booking-number lookup gets its extra limits per device and per
-- address — 20 failed lookups an hour per device (fingerprint), 40 per address (the last entry of the forwarded
-- list, read in the server), failures only, shared by both booking-number paths (fn_guest_lookup and
-- fn_guest_phone_verify_ref). Uncodified descriptive names (worker patch; no prefix registered yet).
-- Runs after phone_lookup_tests.sql on the same database. Seed: BK-DEMO-1001 (primary guest +966500000111).
-- =====================================================================
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create or replace function t_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;

set role service_role;   -- since 0045 the booking-number lookup is called on the server side, never by a visitor

-- sanity: a genuine lookup with no device and no address still opens the booking
do $$ declare r jsonb; begin
  r := fn_guest_lookup('BK-DEMO-1001', '0111');
  perform t_record('a genuine lookup still opens the booking', r->>'status' = 'ok', r::text);
exception when others then perform t_record('a genuine lookup still opens the booking', false, sqlerrm); end $$;

-- one device keeps guessing numbers: 20 failures in the hour, then even a fresh number is throttled
do $$ declare r jsonb; i int; begin
  for i in 1..20 loop
    r := fn_guest_lookup('N7-GUESS-' || i, '9999', null, 'n7-device-1');
  end loop;
  r := fn_guest_lookup('N7-FRESH-REF', '9999', null, 'n7-device-1');
  perform t_record('after 20 failed lookups a device is throttled even on a fresh number', r->>'status' = 'throttled', r::text);
  r := fn_guest_lookup('N7-FRESH-REF', '9999', null, 'n7-device-other');
  perform t_record('another device is not punished for the first one', r->>'status' <> 'throttled', r::text);
exception when others then perform t_record('after 20 failed lookups a device is throttled even on a fresh number', false, sqlerrm); end $$;

-- both booking-number paths share the device counter: 15 lookup failures + 5 phone-path failures = the limit
do $$ declare r jsonb; i int; begin
  for i in 1..15 loop
    r := fn_guest_lookup('N7-MIX-' || i, '9999', null, 'n7-device-2');
  end loop;
end $$;
set role anon;   -- the phone path is the one a visitor calls
do $$ declare r jsonb; i int; begin
  for i in 1..5 loop
    r := fn_guest_phone_verify_ref('0500000' || lpad(i::text, 4, '0'), 'N7-WRONG-' || i, 'n7-device-2');
  end loop;
end $$;
set role service_role;
do $$ declare r jsonb; begin
  r := fn_guest_lookup('N7-FRESH-REF-2', '9999', null, 'n7-device-2');
  perform t_record('the phone path''s failures count toward the device limit of the booking-number path', r->>'status' = 'throttled', r::text);
exception when others then perform t_record('the phone path''s failures count toward the device limit of the booking-number path', false, sqlerrm); end $$;
reset role;

-- one address keeps guessing: 40 failures (different numbers, different devices), then throttled
select set_config('request.headers', '{"x-hotel-slug":"00000000-0000-0000-0000-000000000001","x-forwarded-for":"203.0.113.7"}', false);
set role service_role;
do $$ declare r jsonb; i int; begin
  for i in 1..40 loop
    r := fn_guest_lookup('N7-ADDR-' || i, '9999', null, 'n7-addr-dev-' || i);
  end loop;
  r := fn_guest_lookup('N7-FRESH-REF-3', '9999', null, 'n7-addr-fresh');
  perform t_record('after 40 failed lookups an address is throttled even with a fresh device and number', r->>'status' = 'throttled', r::text);
exception when others then perform t_record('after 40 failed lookups an address is throttled even with a fresh device and number', false, sqlerrm); end $$;
reset role;

-- the keyed address is the last entry of the forwarded list: a caller-added first entry does not move it
select set_config('request.headers', '{"x-hotel-slug":"00000000-0000-0000-0000-000000000001","x-forwarded-for":"9.9.9.9, 203.0.113.7"}', false);
set role service_role;
do $$ declare r jsonb; begin
  r := fn_guest_lookup('N7-FRESH-REF-4', '9999', null, 'n7-addr-fresh-2');
  perform t_record('a spoofed first entry does not free a throttled address (the last entry counts)', r->>'status' = 'throttled', r::text);
exception when others then perform t_record('a spoofed first entry does not free a throttled address (the last entry counts)', false, sqlerrm); end $$;
reset role;
select set_config('request.headers', '{"x-hotel-slug":"00000000-0000-0000-0000-000000000001","x-forwarded-for":"203.0.113.7, 198.51.100.9"}', false);
set role service_role;
do $$ declare r jsonb; begin
  r := fn_guest_lookup('N7-FRESH-REF-5', '9999', null, 'n7-addr-fresh-3');
  perform t_record('a genuinely different last address answers normally', r->>'status' = 'unmatched', r::text);
exception when others then perform t_record('a genuinely different last address answers normally', false, sqlerrm); end $$;
reset role;
select set_config('request.headers', '{"x-hotel-slug":"00000000-0000-0000-0000-000000000001"}', false);   -- restore the suite default

select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),110) as detail from test_results order by ok, name;
