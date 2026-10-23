-- =====================================================================
-- Phone-first booking lookup (PH01–PH09, migration 0020). Runs after the other suites on the same DB.
-- Seed: BK-DEMO-1001 (R-…, primary guest +966500000111), BK-DEMO-1002 (+966500000222).
-- =====================================================================
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create temp table ph(k text primary key, v text);
grant all on ph to public;
create or replace function t_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;

select t_record('PH01 any spelling of a Saudi mobile is one key',
  (select bool_and(fn_normalize_phone(x) = '966500000111') from unnest(array['0500000111', '+966 50 000 0111', '00966500000111', '٠٥٠٠٠٠٠١١١', '500000111', '966-500-000-111']) x)
  and fn_normalize_phone('12') is null and fn_normalize_phone('9661234') is null);

-- PH02 the browser can neither start a challenge (the code would come back) nor read challenges
set role anon;
do $$ begin
  begin perform fn_guest_phone_start('0500000111'); perform t_record('PH02 anon cannot call fn_guest_phone_start', false);
  exception when insufficient_privilege then perform t_record('PH02 anon cannot call fn_guest_phone_start', true); end;
  begin perform count(*) from guest_phone_challenges; perform t_record('PH02b anon cannot read guest_phone_challenges', false);
  exception when insufficient_privilege then perform t_record('PH02b anon cannot read guest_phone_challenges', true); end;
end $$;
reset role;

insert into ph select 'other_ref', internal_ref from reservations where external_ref = 'BK-DEMO-1002';
set role service_role;
do $$ declare r jsonb; n int; begin
  r := fn_guest_phone_start('0500000111', 'ph-device');
  insert into ph values ('code', r->>'code');
  select count(*) into n from guest_phone_challenges where phone = '966500000999';
  perform t_record('PH03 a phone with bookings gets a 6-digit code; a phone without bookings gets nothing sent',
    r->>'status' = 'ok' and (r->>'code') ~ '^\d{6}$'
    and (fn_guest_phone_start('0500000999', 'ph-device'))->>'status' = 'no_reservations'
    and n = 0, r::text);
end $$;
reset role;

set role anon;
do $$ declare r jsonb; i int; wrong text := case when (select v from ph where k = 'code') = '000000' then '111111' else '000000' end; begin
  r := fn_guest_phone_verify('0500000111', wrong);
  perform t_record('PH04 a wrong code is refused and counted', r->>'status' = 'mismatch' and (r->>'attempts_left')::int = 4, r::text);
  r := fn_guest_phone_verify('+966500000111', (select v from ph where k = 'code'));
  insert into ph values ('session', r->>'token');
  perform t_record('PH05 the right code (any phone spelling) opens a phone session', r->>'status' = 'ok' and r->>'token' is not null, r::text);
  r := fn_guest_phone_reservations((select v from ph where k = 'session'));
  perform t_record('PH05b the session lists this phone''s bookings only',
    (select bool_or(x->>'ref' = 'BK-DEMO-1001') and not bool_or(x->>'ref' = 'BK-DEMO-1002') from jsonb_array_elements(r->'reservations') x)
    and r->>'phone_last4' = '0111', r::text);
end $$;

do $$ declare r jsonb; s jsonb; ref text; begin
  select x->>'internal_ref' into ref from jsonb_array_elements(fn_guest_phone_reservations((select v from ph where k = 'session'))->'reservations') x where x->>'ref' = 'BK-DEMO-1001';
  r := fn_guest_phone_open((select v from ph where k = 'session'), ref);
  s := fn_guest_session(r->>'token');
  perform t_record('PH06 opening a booking gives the usual guest token of that booking', s->'reservation'->>'internal_ref' = ref, ref);
  begin
    perform fn_guest_phone_open((select v from ph where k = 'session'), (select v from ph where k = 'other_ref'));
    perform t_record('PH08 a booking of another phone cannot be opened', false);
  exception when others then perform t_record('PH08 a booking of another phone cannot be opened', sqlerrm = 'NOT_FOUND', sqlerrm); end;
  begin
    perform fn_guest_phone_reservations('NOT-A-TOKEN');
    perform t_record('PH09 an unknown phone session is refused', false);
  exception when others then perform t_record('PH09 an unknown phone session is refused', sqlerrm = 'TOKEN_INVALID', sqlerrm); end;
end $$;

do $$ declare a jsonb; b jsonb; c jsonb; begin
  a := fn_guest_phone_verify_ref('0500000111', 'bk-demo-1001');
  b := fn_guest_phone_verify_ref('0500000111', 'BK-DEMO-1002');
  c := fn_guest_phone_verify_ref('0500000111', 'NO-SUCH');
  perform t_record('PH07 without WhatsApp: phone + one of its booking numbers opens the session; another phone''s booking does not',
    a->>'status' = 'ok' and b->>'status' = 'mismatch' and c->>'status' = 'mismatch', a::text || b::text);
end $$;
reset role;

-- PH04b five wrong codes lock the challenge
set role service_role;
do $$ begin perform fn_guest_phone_start('0500000222', 'ph-device-2'); end $$;
reset role;
set role anon;
do $$ declare r jsonb; i int; begin
  for i in 1..5 loop r := fn_guest_phone_verify('0500000222', '000001'); end loop;
  r := fn_guest_phone_verify('0500000222', '000001');
  perform t_record('PH04b after 5 wrong codes the challenge is locked', r->>'status' = 'throttled', r::text);
end $$;
reset role;

select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),110) as detail from test_results order by ok, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from test_results where ok is not true) then raise exception 'PHONE LOOKUP TESTS FAILED'; end if;
end $$;
