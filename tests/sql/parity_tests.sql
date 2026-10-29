-- =====================================================================
-- Reservation-creation parity tests (P01–P07) — migration 0011 (review item A07)
-- Multi-unit bookings are several reservations sharing group_ref, created atomically;
-- arrival/departure times default from the branch; companions are guest rows.
-- =====================================================================
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create or replace function t_login(p_uid uuid, p_email text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email)::text, false);
end $$;
create or replace function t_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;
create or replace function t_group_count(p_group text) returns int language sql security definer as $$ select count(*)::int from reservations where group_ref = p_group $$;
create or replace function t_res_count_by_guest(p_name text) returns int language sql security definer as $$ select count(*)::int from reservations r where exists (select 1 from reservation_guests g where g.reservation_id = r.id and g.is_primary and g.full_name = p_name) $$;
create or replace function t_companions(p_res uuid) returns int language sql security definer as $$ select count(*)::int from reservation_guests where reservation_id = p_res and not is_primary $$;

-- a free room for the race-style atomicity test
reset role;
insert into rooms(id, branch_id, organization_id, category_id, room_number, is_active, status)
values ('00000000-0000-0000-0000-000000000197','00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000030','X-PAR', true, 'available')
on conflict (id) do nothing;

select t_login('a0000000-0000-0000-0000-000000000002','sup@test.local');
set role authenticated;

-- P01: the old single-unit payload still works and gets the branch's default times
do $$ declare r jsonb; rid uuid; begin
  r := fn_staff_create_reservation('{"branch_id":"00000000-0000-0000-0000-000000000010","category_id":"00000000-0000-0000-0000-000000000030","check_in":"2031-05-01","check_out":"2031-05-03","guest_name":"فرد واحد","guest_phone":"0500001111","source_id":"00000000-0000-0000-0000-000000000021"}'::jsonb);
  rid := (r->>'id')::uuid;
  perform t_record('P01 single-unit payload unchanged; arrival/departure default from branch settings',
    (r->>'ok')::boolean and (r->'group_ref') = 'null'::jsonb and exists (select 1 from reservations x join branches b on b.id = x.branch_id where x.id = rid and x.expected_arrival_time = b.check_in_time and x.expected_departure_time = b.check_out_time), r::text);
end $$;

-- P02: explicit times are stored; a malformed time is rejected
do $$ declare r jsonb; begin
  r := fn_staff_create_reservation('{"branch_id":"00000000-0000-0000-0000-000000000010","category_id":"00000000-0000-0000-0000-000000000030","check_in":"2031-05-04","check_out":"2031-05-05","guest_name":"وقت وصول","guest_phone":"0500001112","source_id":"00000000-0000-0000-0000-000000000021","arrival_time":"21:15","departure_time":"10:00"}'::jsonb);
  perform t_record('P02 explicit arrival/departure times are stored', exists (select 1 from reservations where id = (r->>'id')::uuid and expected_arrival_time = '21:15' and expected_departure_time = '10:00'));
  begin
    perform fn_staff_create_reservation('{"branch_id":"00000000-0000-0000-0000-000000000010","category_id":"00000000-0000-0000-0000-000000000030","check_in":"2031-05-06","check_out":"2031-05-07","guest_phone":"0551000022","guest_name":"وقت خاطئ","source_id":"00000000-0000-0000-0000-000000000021","arrival_time":"25:99"}'::jsonb);
    perform t_record('P02b malformed time is rejected', false);
  exception when others then
    perform t_record('P02b malformed time is rejected', sqlerrm like 'VALIDATION: times%', sqlerrm);
  end;
end $$;

-- P03: companions' details become guest rows (not verified), count never below the list length, capacity per unit enforced
do $$ declare r jsonb; rid uuid; begin
  r := fn_staff_create_reservation('{"branch_id":"00000000-0000-0000-0000-000000000010","category_id":"00000000-0000-0000-0000-000000000030","check_in":"2031-05-08","check_out":"2031-05-09","guest_name":"رب الأسرة","guest_phone":"0500001113","source_id":"00000000-0000-0000-0000-000000000021","companions":0,"companions_details":[{"full_name":"الابن","relationship":"ابن"}]}'::jsonb);
  rid := (r->>'id')::uuid;
  perform t_record('P03 companions_details → guest rows with verification not_started; companions count raised to the list length',
    t_companions(rid) = 1 and exists (select 1 from reservations where id = rid and companions = 1)
    and exists (select 1 from reservation_guests where reservation_id = rid and not is_primary and relationship = 'ابن' and verification_status = 'not_started' and not data_submitted), r::text);
  begin
    perform fn_staff_create_reservation('{"branch_id":"00000000-0000-0000-0000-000000000010","category_id":"00000000-0000-0000-0000-000000000030","check_in":"2031-05-10","check_out":"2031-05-11","guest_phone":"0551000023","guest_name":"فوق السعة","source_id":"00000000-0000-0000-0000-000000000021","adults":2,"companions_details":[{"full_name":"مرافق أ"},{"full_name":"مرافق ب"},{"full_name":"مرافق ج"},{"full_name":"مرافق د"},{"full_name":"مرافق هـ"},{"full_name":"مرافق و"},{"full_name":"مرافق ز"}]}'::jsonb);
    perform t_record('P03b capacity is checked against adults + companion rows', false);
  exception when others then
    perform t_record('P03b capacity is checked against adults + companion rows', sqlerrm like 'CAPACITY_EXCEEDED%', sqlerrm);
  end;
  begin
    perform fn_staff_create_reservation('{"branch_id":"00000000-0000-0000-0000-000000000010","category_id":"00000000-0000-0000-0000-000000000030","check_in":"2031-05-12","check_out":"2031-05-13","guest_phone":"0551000024","guest_name":"مرافق بلا اسم","source_id":"00000000-0000-0000-0000-000000000021","companions_details":[{"relationship":"ابن"}]}'::jsonb);
    perform t_record('P03c a companion without a name is rejected', false);
  exception when others then
    perform t_record('P03c a companion without a name is rejected', sqlerrm like 'VALIDATION: companion_name%', sqlerrm);
  end;
end $$;

-- P04: multi-unit booking → one reservation per unit, shared group_ref, shared guest, per-unit allocation
do $$ declare r jsonb; g text; begin
  r := fn_staff_create_reservation('{"branch_id":"00000000-0000-0000-0000-000000000010","category_id":"00000000-0000-0000-0000-000000000030","check_in":"2031-06-01","check_out":"2031-06-03","guest_name":"عائلة الجماعي","guest_phone":"0500001114","source_id":"00000000-0000-0000-0000-000000000021","units":[{"category_id":"00000000-0000-0000-0000-000000000030","adults":2},{"category_id":"00000000-0000-0000-0000-000000000030","adults":1,"companions_details":[{"full_name":"طفل"}]},{"category_id":"00000000-0000-0000-0000-000000000031","adults":2}]}'::jsonb);
  g := r->>'group_ref';
  perform t_record('P04 three units → three reservations sharing one group_ref, ids/internal_refs returned, primary guest on each',
    (r->>'units')::int = 3 and jsonb_array_length(r->'ids') = 3 and g like 'G-%' and t_group_count(g) = 3 and (select count(*) from fn_reservation_group((r->>'id')::uuid) x where exists (select 1 from reservation_guests gg where gg.reservation_id = x.id and gg.is_primary and gg.full_name = 'عائلة الجماعي')) = 3, r::text);
  perform t_record('P04b group siblings are listed for the detail page', (select count(*) from fn_reservation_group((r->>'id')::uuid)) = 3);
  perform t_record('P04c units have independent finance and companions', exists (select 1 from reservations x where x.id = (r->'ids'->>1)::uuid and x.companions = 1) and exists (select 1 from reservations x where x.id = (r->'ids'->>0)::uuid and x.companions = 0));
end $$;

-- P05: atomicity — when one unit cannot be allocated, no reservation of the booking is created
do $$ declare r jsonb; before int; begin
  -- take room X-PAR for the period with a plain reservation first
  r := fn_staff_create_reservation('{"branch_id":"00000000-0000-0000-0000-000000000010","category_id":"00000000-0000-0000-0000-000000000030","room_id":"00000000-0000-0000-0000-000000000197","check_in":"2031-07-01","check_out":"2031-07-04","guest_name":"الحاجز الأول","guest_phone":"0500001115","source_id":"00000000-0000-0000-0000-000000000021"}'::jsonb);
  before := t_res_count_by_guest('مجموعة فاشلة');
  begin
    perform fn_staff_create_reservation('{"branch_id":"00000000-0000-0000-0000-000000000010","category_id":"00000000-0000-0000-0000-000000000030","check_in":"2031-07-02","check_out":"2031-07-03","guest_phone":"0551000025","guest_name":"مجموعة فاشلة","source_id":"00000000-0000-0000-0000-000000000021","units":[{"category_id":"00000000-0000-0000-0000-000000000030","adults":1},{"category_id":"00000000-0000-0000-0000-000000000030","adults":1,"room_id":"00000000-0000-0000-0000-000000000197"}]}'::jsonb);
    perform t_record('P05 group booking with an unavailable unit is rejected as a whole', false, 'no error raised');
  exception when others then
    perform t_record('P05 group booking with an unavailable unit is rejected as a whole', sqlerrm like 'ROOM_NOT_AVAILABLE%' or sqlerrm like 'ALLOCATION_CONFLICT%', sqlerrm);
  end;
end $$;
reset role;
select t_record('P05b no reservation of the failed group exists (atomic)', t_res_count_by_guest('مجموعة فاشلة') = 0, 'count=' || t_res_count_by_guest('مجموعة فاشلة'));

-- P06: housekeeping cannot create reservations through the new entry point either
select t_login('a0000000-0000-0000-0000-000000000003','hk@test.local');
set role authenticated;
do $$ begin
  begin
    perform fn_staff_create_reservation('{"branch_id":"00000000-0000-0000-0000-000000000010","category_id":"00000000-0000-0000-0000-000000000030","check_in":"2031-08-01","check_out":"2031-08-02","guest_phone":"0551000026","guest_name":"نظافة","source_id":"00000000-0000-0000-0000-000000000021","units":[{"category_id":"00000000-0000-0000-0000-000000000030"}]}'::jsonb);
    perform t_record('P06 housekeeping cannot create (group) reservations', false);
  exception when others then
    perform t_record('P06 housekeeping cannot create (group) reservations', sqlerrm like 'FORBIDDEN%', sqlerrm);
  end;
  begin
    perform fn_staff_create_reservation_unit('{}'::jsonb, null);
    perform t_record('P07 the internal unit function is not callable by the API role', false);
  exception when insufficient_privilege then
    perform t_record('P07 the internal unit function is not callable by the API role', true);
  when others then
    perform t_record('P07 the internal unit function is not callable by the API role', false, sqlerrm);
  end;
end $$;
reset role;

select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),110) as detail from test_results order by ok, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from test_results where ok is not true) then raise exception 'PARITY TESTS FAILED'; end if;
end $$;
