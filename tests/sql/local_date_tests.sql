-- =====================================================================
-- Branch-local dates (LD01–LD04, migration 0019). The hosted database runs sessions in UTC; between 00:00 and
-- 03:00 in Riyadh the UTC date is still yesterday. These tests do not depend on the hour they run at:
--   LD01/LD02 use receipts stamped on both sides of Riyadh midnight,
--   LD03/LD04 move the branch to a zone whose date differs from the UTC date right now.
-- Runs after the other files on the same DB (reuses org 1: owner a…01, branch …0010, category …0030, source …0021).
-- =====================================================================
\set ON_ERROR_STOP off
set time zone 'UTC';
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create temp table ld(k text primary key, v text);
grant all on ld to public;
create or replace function t_login(p_uid uuid, p_email text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email)::text, false);
end $$;
create or replace function t_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;

select t_login('a0000000-0000-0000-0000-000000000001','owner@test.local');
set role authenticated;

-- two receipts, 23:30 and 00:30 in Riyadh (20:30 and 21:30 UTC on 2033-03-10)
do $$ declare r jsonb; res uuid; begin
  r := fn_staff_create_reservation('{"branch_id":"00000000-0000-0000-0000-000000000010","category_id":"00000000-0000-0000-0000-000000000030","check_in":"2033-03-10","check_out":"2033-03-12","guest_name":"تاريخ محلي","guest_phone":"0500004444","source_id":"00000000-0000-0000-0000-000000000021"}'::jsonb);
  res := (r->>'id')::uuid;
  insert into ld values ('res', res::text);
  perform fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind', 'receipt', 'amount_halalas', 2000, 'method', 'cash',
    'idempotency_key', 'ld-before-midnight', 'occurred_at', '2033-03-10 20:30:00+00'));
  perform fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind', 'receipt', 'amount_halalas', 1000, 'method', 'cash',
    'idempotency_key', 'ld-after-midnight', 'occurred_at', '2033-03-10 21:30:00+00'));
end $$;

do $$ declare s jsonb; begin
  s := fn_ops_daily_summary('00000000-0000-0000-0000-000000000010', '2033-03-11');
  perform t_record('LD01 a receipt at 00:30 Riyadh counts on that Riyadh day (the UTC date is still the day before)',
    (s->'finance'->>'received_today')::bigint = 1000, (s->'finance')::text);
  s := fn_ops_daily_summary('00000000-0000-0000-0000-000000000010', '2033-03-10');
  perform t_record('LD02 a receipt at 23:30 Riyadh stays on its own day',
    (s->'finance'->>'received_today')::bigint = 2000, (s->'finance')::text);
end $$;
reset role;

-- LD03/LD04: put the branch in a zone whose calendar date differs from the UTC date at this very moment
-- (UTC+14 when it is past noon UTC, UTC-12 before), and make the stay start on the branch's today.
do $$
declare res uuid := (select v::uuid from ld where k = 'res');
        tz text := case when extract(hour from now() at time zone 'UTC') >= 12 then 'Etc/GMT-14' else 'Etc/GMT+12' end;
        b_today date;
begin
  insert into ld values ('tz_before', (select timezone from branches where id = '00000000-0000-0000-0000-000000000010'));
  update branches set timezone = tz where id = '00000000-0000-0000-0000-000000000010';
  b_today := fn_branch_today('00000000-0000-0000-0000-000000000010');
  insert into ld values ('b_today', b_today::text);
  update reservations set check_in = b_today, check_out = b_today + 1 where id = res;
  perform t_record('LD03 setup: the branch date differs from the session (UTC) date', b_today <> current_date,
    tz || ' branch=' || b_today || ' session=' || current_date);
end $$;

select t_login('a0000000-0000-0000-0000-000000000001','owner@test.local');
set role authenticated;
do $$ declare res uuid := (select v::uuid from ld where k = 'res'); rs text[]; begin
  select reasons into rs from fn_evaluate_access(res);
  perform t_record('LD04 a stay that starts on the branch''s today is inside the stay period, whatever the UTC date',
    not ('التاريخ الحالي خارج فترة الإقامة' = any(rs)), array_to_string(rs, ' | '));
end $$;
reset role;

-- leave branch …0010 as the other suites found it
update branches set timezone = (select v from ld where k = 'tz_before') where id = '00000000-0000-0000-0000-000000000010';

select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),110) as detail from test_results order by ok, name;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from test_results where not ok) then raise exception 'LOCAL DATE TESTS FAILED'; end if;
end $$;
