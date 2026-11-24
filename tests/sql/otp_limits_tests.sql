-- =====================================================================
-- Code-message limits (plan 5.2, S2; migration 0083). OL01–OL08.
-- Runs after the other suites on the same DB. Invented phones only, inside one rolled-back
-- transaction. Demo hotel 00000000-...-0001, branch 00000000-...-0010.
-- =====================================================================
\set ON_ERROR_STOP on
begin;
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create or replace function t_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;

-- one invented booking per invented phone, so a start reaches the send step
do $$
declare
  v_org uuid := '00000000-0000-0000-0000-000000000001';
  v_branch uuid := '00000000-0000-0000-0000-000000000010';
  v_org2 uuid := '90000000-0000-0000-0000-000000000301';
  v_branch2 uuid := '90000000-0000-0000-0000-000000000311';
  p record; r jsonb; i int; n_ok int; n int; v_id uuid; v_code text; v_wrong text;
begin
  insert into organizations(id, name_ar) values (v_org2, 'فندق فحص الرمز');
  update organizations set guest_slug = id::text where id = v_org2;
  insert into branches(id, organization_id, name_ar) values (v_branch2, v_org2, 'فرع الرمز');
  for p in select * from (values
      ('OL-P1', '966500009001', v_org,  v_branch),
      ('OL-P2', '966500009002', v_org,  v_branch),
      ('OL-P3', '966500009003', v_org,  v_branch),
      ('OL-P4', '966500009004', v_org,  v_branch),
      ('OL-P5', '966500009005', v_org,  v_branch),
      ('OL-P6', '966500009006', v_org,  v_branch),
      ('OL-P8', '966500009008', v_org2, v_branch2))
      as t(ref, phone, org, br)
  loop
    insert into reservations(organization_id, branch_id, external_ref, check_in, check_out)
    values (p.org, p.br, p.ref, current_date, current_date + 1) returning id into v_id;
    insert into reservation_guests(reservation_id, is_primary, full_name, phone) values (v_id, true, 'ضيف فحص الرمز', p.phone);
  end loop;

  -- the visitor's hotel address, then start as the service role (the guest-otp edge function's seat)
  perform set_config('request.headers', jsonb_build_object('x-hotel-slug', v_org::text)::text, true);
  execute 'set local role service_role';

  -- OL01 the cap is on sends: 3 sends per device per phone per hour, the 4th is throttled
  n_ok := 0;
  for i in 1..3 loop
    r := fn_guest_phone_start('966500009001', 'ol-a');
    if r->>'status' = 'ok' then
      n_ok := n_ok + 1;
      update guest_phone_challenges set created_at = now() - interval '2 minutes' where id = (r->>'challenge_id')::uuid;
    end if;
  end loop;
  r := fn_guest_phone_start('966500009001', 'ol-a');
  perform t_record('OL01 three sends per device per phone, the fourth is throttled', n_ok = 3 and r->>'status' = 'throttled', n_ok::text || '/' || (r->>'status'));

  -- OL02 the cooldown: a second message to the same phone inside 60 seconds is throttled, after it is not
  r := fn_guest_phone_start('966500009002', 'ol-b');
  n_ok := case when r->>'status' = 'ok' then 1 else 0 end;
  r := fn_guest_phone_start('966500009002', 'ol-b');
  n := case when r->>'status' = 'throttled' then 1 else 0 end;
  update guest_phone_challenges set created_at = now() - interval '2 minutes'
   where organization_id = v_org and phone = '966500009002';
  r := fn_guest_phone_start('966500009002', 'ol-b');
  perform t_record('OL02 a second code inside the cooldown is throttled; after it, sending resumes', n_ok = 1 and n = 1 and r->>'status' = 'ok', r->>'status');

  -- OL03 a failed send frees its slot: the owner is not choked by undelivered messages
  for i in 1..3 loop
    r := fn_guest_phone_start('966500009003', 'ol-c');
    if r->>'status' = 'ok' then perform fn_guest_phone_mark_sent((r->>'challenge_id')::uuid, false); end if;
  end loop;
  r := fn_guest_phone_start('966500009003', 'ol-c');
  perform t_record('OL03 three failed sends spend nothing: the next start is still admitted', r->>'status' = 'ok', r->>'status');

  -- OL04 each device keeps its own allowance; the phone's total stays bounded
  -- (3 sends from one stranger's device, then the owner's device still sends; 6 total per phone, then throttled)
  n_ok := 0;
  for i in 1..3 loop
    r := fn_guest_phone_start('966500009004', 'ol-stranger');
    if r->>'status' = 'ok' then
      n_ok := n_ok + 1;
      perform fn_guest_phone_mark_sent((r->>'challenge_id')::uuid, true);
      update guest_phone_challenges set created_at = now() - interval '2 minutes', sent_at = now() - interval '2 minutes' where id = (r->>'challenge_id')::uuid;
    end if;
  end loop;
  r := fn_guest_phone_start('966500009004', 'ol-stranger');
  n := case when r->>'status' = 'throttled' then 1 else 0 end;   -- the stranger's device is spent
  r := fn_guest_phone_start('966500009004', 'ol-owner');
  perform t_record('OL04 a stranger''s spent device does not spend the owner''s; the owner''s device still sends',
    n_ok = 3 and n = 1 and r->>'status' = 'ok', n_ok::text || '/' || (r->>'status'));
  perform fn_guest_phone_mark_sent((r->>'challenge_id')::uuid, true);
  update guest_phone_challenges set created_at = now() - interval '2 minutes', sent_at = now() - interval '2 minutes' where id = (r->>'challenge_id')::uuid;
  for i in 1..2 loop
    r := fn_guest_phone_start('966500009004', 'ol-owner');
    if r->>'status' = 'ok' then
      update guest_phone_challenges set created_at = now() - interval '2 minutes' where id = (r->>'challenge_id')::uuid;
    end if;
  end loop;
  r := fn_guest_phone_start('966500009004', 'ol-third-device');
  update guest_phone_challenges set created_at = now() - interval '2 minutes'
   where organization_id = v_org and phone = '966500009004';   -- cooldown aside: the ceiling is what is measured
  r := fn_guest_phone_start('966500009004', 'ol-third-device');
  perform t_record('OL04b the phone''s total of six sends an hour bounds a flood from many devices', r->>'status' = 'throttled', r->>'status');

  -- OL05 «إيقاف» is honored, «استئناف» lifts it
  perform fn_guest_phone_optout(v_org, '0500009005', 'إيقاف');
  r := fn_guest_phone_start('966500009005', 'ol-e');
  n := case when r->>'status' = 'throttled' then 1 else 0 end;
  perform fn_guest_phone_optin(v_org, '966500009005');
  r := fn_guest_phone_start('966500009005', 'ol-e');
  perform t_record('OL05 a phone that said «إيقاف» is sent nothing until it says «استئناف»', n = 1 and r->>'status' = 'ok', r->>'status');

  -- OL06 the owner is never locked out by someone else's guesses: five wrong codes throttle
  -- further guessing, the right code still passes
  r := fn_guest_phone_start('966500009006', 'ol-f-owner');
  v_id := (r->>'challenge_id')::uuid; v_code := r->>'code';
  v_wrong := case when v_code = '000000' then '111111' else '000000' end;
  execute 'reset role';
  execute 'set local role anon';
  for i in 1..5 loop r := fn_guest_phone_verify('966500009006', v_wrong, 'ol-f-stranger'); end loop;
  n_ok := case when r->>'status' = 'mismatch' then 1 else 0 end;
  r := fn_guest_phone_verify('966500009006', v_wrong, 'ol-f-stranger');
  n := case when r->>'status' = 'throttled' then 1 else 0 end;
  r := fn_guest_phone_verify('966500009006', v_code, 'ol-f-owner');
  perform t_record('OL06 five wrong guesses throttle guessing; the right code still opens the session',
    n_ok = 1 and n = 1 and r->>'status' = 'ok' and r->>'token' is not null, r->>'status');
  execute 'reset role';
  execute 'set local role service_role';

  -- OL07 only the service role marks sends or writes the stop list; nobody reads it
  execute 'reset role';
  execute 'set local role anon';
  begin
    perform fn_guest_phone_mark_sent(v_id, true);
    perform t_record('OL07 a visitor cannot mark a code message sent', false);
  exception when insufficient_privilege then perform t_record('OL07 a visitor cannot mark a code message sent', true); end;
  begin
    perform fn_guest_phone_optout(v_org, '966500009001', 'x');
    perform t_record('OL07b a visitor cannot write the stop list', false);
  exception when insufficient_privilege then perform t_record('OL07b a visitor cannot write the stop list', true); end;
  begin
    perform count(*) from guest_phone_optouts;
    perform t_record('OL07c a visitor cannot read the stop list', false);
  exception when insufficient_privilege then perform t_record('OL07c a visitor cannot read the stop list', true); end;
  execute 'reset role';
  execute 'set local role service_role';

  -- OL08 the stop list is per hotel: «إيقاف» at one hotel throttles no other hotel
  perform set_config('request.headers', jsonb_build_object('x-hotel-slug', v_org2::text)::text, true);
  r := fn_guest_phone_start('966500009008', 'ol-g');
  perform t_record('OL08 «إيقاف» at one hotel throttles no other hotel''s messages', r->>'status' = 'ok', r->>'status');
  execute 'reset role';
end $$;

select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),110) as detail from test_results order by ok, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
do $$ begin
  if exists (select 1 from test_results where ok is not true) then raise exception 'OTP LIMITS TESTS FAILED'; end if;
end $$;
rollback;
