-- 0150: the by-staff lines of the discounts, late-entries and identities reports carry the staff id and group by it, so two
-- different people with the same display name are two lines. Synthetic fixture, rolled back. Run after the migrations on the test database.
-- Before 0150 the three "two lines" checks are expected to FAIL (the collision); after 0150 all rows pass.
\set ON_ERROR_STOP off
begin;
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create or replace function t_login(p_uid uuid, p_email text) returns void language plpgsql as $$ begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email)::text, false); end $$;
create or replace function t_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$ insert into test_results values (p_name, p_ok, p_detail); $$;
create temp table fx(k text primary key, v text);
grant all on fx to public;
do $$ declare org uuid := '00000000-0000-0000-0000-000000000001'; br uuid := '00000000-0000-0000-0000-000000000010'; src uuid;
  a uuid := 'fe150000-0000-4000-8000-00000000000a'; b uuid := 'fe150000-0000-4000-8000-00000000000b'; o uuid := 'fe150000-0000-4000-8000-0000000000f0';
  r1 uuid; r2 uuid; ro reservations; begin
  select id into r1 from reservations where branch_id = br order by id limit 1; select id into r2 from reservations where branch_id = br and id <> r1 order by id limit 1;
  insert into staff_profiles(id,auth_user_id,organization_id,full_name,email,role,is_active) values
    (o,'a0000000-0000-0000-0000-0000000000f0',org,'مالك الاختبار','own150@example.test','owner',true),
    (a,'fe150000-0000-4000-8000-0000000001a1',org,'موظف مكرر','a150@example.test','supervisor',true),
    (b,'fe150000-0000-4000-8000-0000000001b1',org,'موظف مكرر','b150@example.test','supervisor',false);
  select id into src from booking_sources where kind='external' limit 1;
  select * into ro from reservations where branch_id=br limit 1;
  insert into reservation_charges(organization_id,branch_id,reservation_id,kind,description,quantity,unit_price_halalas,total_halalas,taxable,service_from,service_to,created_by,reason)
   values (org,br,ro.id,'discount','t1',1,-1000,-1000,false,current_date,current_date,a,'x'),(org,br,ro.id,'discount','t2',1,-2000,-2000,false,current_date,current_date,b,'y');
  -- two platform bookings entered late, one by each same-name person
  update reservations set created_by=a, source_id=src, platform_booked_on=current_date-5, created_at=now() where id = r1;
  update reservations set created_by=b, source_id=src, platform_booked_on=current_date-7, created_at=now() where id = r2;
  -- two identities verified today, one by each
  insert into reservation_guests(id,reservation_id,organization_id,branch_id,full_name,is_primary,verification_status,verified_at,verified_by,entry_path) values
    ('fe150000-0000-4000-8000-0000000000d1',r1,(select organization_id from reservations where id=r1),br,'ضيف اختبار ١',false,'verified',now(),a,'office'),
    ('fe150000-0000-4000-8000-0000000000d2',r2,(select organization_id from reservations where id=r2),br,'ضيف اختبار ٢',false,'verified',now(),b,'office');
  insert into fx values ('a', a::text), ('b', b::text);
end $$;
grant select on fx to public;
set role authenticated;
select t_login('a0000000-0000-0000-0000-0000000000f0','own150@example.test');
do $$ declare br uuid := '00000000-0000-0000-0000-000000000010'; d jsonb; l jsonb; i jsonb; a text; b text; begin
  select v into a from fx where k='a'; select v into b from fx where k='b';
  d := fn_reports_discounts(br, current_date-1, current_date+1, '{}'::jsonb);
  perform t_record('HM01 discounts: the two same-name staff are two separate by_staff lines (never one merged line)', (select count(*) from jsonb_array_elements(d->'by_staff') e where e->>'staff_id' in (a,b)) = 2, d->>'by_staff');
  perform t_record('HM02 discounts: each line carries its own staff_id, count 1 and its own amount', (select count(*) from jsonb_array_elements(d->'by_staff') e where (e->>'staff_id' = a and (e->>'total_halalas')::int = 1000 and (e->>'count')::int = 1) or (e->>'staff_id' = b and (e->>'total_halalas')::int = 2000 and (e->>'count')::int = 1)) = 2, d->>'by_staff');
  perform t_record('HM03 discounts: the report total equals the sum of its lines', (d->>'total_halalas')::bigint = (select sum((e->>'total_halalas')::bigint) from jsonb_array_elements(d->'by_staff') e) and (d->>'count')::int = (select sum((e->>'count')::int) from jsonb_array_elements(d->'by_staff') e), d->>'total_halalas');
  perform t_record('HM04 discounts: existing keys staff, role, count, total_halalas still present on every line', (select bool_and(e ? 'staff' and e ? 'role' and e ? 'count' and e ? 'total_halalas') from jsonb_array_elements(d->'by_staff') e), null);
  l := fn_reports_late_entries(br, current_date-1, current_date+1, 1, '{}'::jsonb);
  perform t_record('HM05 late entries: the two same-name staff are two lines, each with its id and count 1', (select count(*) from jsonb_array_elements(l->'by_staff') e where e->>'staff_id' in (a,b) and (e->>'count')::int = 1) = 2, l->>'by_staff');
  perform t_record('HM06 late entries: the late total equals the sum of its lines and keys staff, count, max_lag are kept', (l->>'late')::int = (select sum((e->>'count')::int) from jsonb_array_elements(l->'by_staff') e) and (select bool_and(e ? 'staff' and e ? 'count' and e ? 'max_lag') from jsonb_array_elements(l->'by_staff') e), l->>'late');
  i := fn_reports_identities(br, current_date-1, current_date+1, 'all', '{}'::jsonb);
  perform t_record('HM07 identities: the two same-name staff are two lines, each with its id and office 1', (select count(*) from jsonb_array_elements(i->'by_staff') e where e->>'staff_id' in (a,b) and (e->>'office')::int = 1) = 2, i->>'by_staff');
  perform t_record('HM08 identities: the count equals the sum of its lines and keys staff, office, guest are kept', (i->>'count')::int = (select sum((e->>'office')::int + (e->>'guest')::int) from jsonb_array_elements(i->'by_staff') e) and (select bool_and(e ? 'staff' and e ? 'office' and e ? 'guest') from jsonb_array_elements(i->'by_staff') e), i->>'count');
exception when others then perform t_record('HM00 unexpected error', false, sqlerrm); end $$;
reset role;
select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),160) as detail from test_results order by name;
rollback;
