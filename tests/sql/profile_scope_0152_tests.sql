-- 0152: a booking reuses a guest profile only if the caller may see it. Synthetic, rolled back.
begin;
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create temp table ids(k text primary key, v uuid);
grant all on ids to public;
create or replace function t_login(p_uid uuid, p_email text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email)::text, false);
end $$;
create or replace function t_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;
create or replace function t_id(p_k text) returns uuid language sql security definer as $$ select v from ids where k = p_k $$;
create or replace function t_fails(p_sql text, p_like text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'accepted';
exception when others then
  return case when sqlerrm like p_like then 'ok' else sqlerrm end;
end $$;
create or replace function t_closing(p uuid) returns day_closings language sql security definer as $$ select * from day_closings where id = p $$;
create or replace function t_count(p_sql text) returns bigint language plpgsql security definer as $$ declare n bigint; begin execute p_sql into n; return n; end $$;
create or replace function t_today(p uuid) returns date language sql security definer as $$ select fn_branch_today(p) $$;
-- what a script could compute itself from what it reads: the md5 of the day's money (no review token)
create or replace function t_forge(p uuid) returns text language sql security definer as $$
  select fn_day_closing_summary_hash(fn_day_closing_compute(c.branch_id, c.business_date), fn_day_closing_lines_json(c.id)) from day_closings c where c.id = p $$;
-- the window passing, as time would
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; bb uuid; catb uuid; bha uuid := '00000000-0000-0000-0000-000000000010'; catha uuid; ob jsonb; begin
  r := fn_admin_upsert_branch('{"name_ar":"فرع النطاق","name_en":"Scope branch","tax_rate_bp":0}'); bb := (r->>'id')::uuid;
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', bb, 'name_ar', 'غرفة النطاق', 'base_price_halalas', 20000)); catb := (r->>'id')::uuid;
  perform fn_admin_upsert_room(jsonb_build_object('branch_id', bb, 'category_id', catb, 'room_number', '801'));
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', bha, 'name_ar', 'غرفة النطاق أ', 'base_price_halalas', 20000)); catha := (r->>'id')::uuid;
  perform fn_admin_upsert_room(jsonb_build_object('branch_id', bha, 'category_id', catha, 'room_number', '811'));
  perform fn_admin_upsert_room(jsonb_build_object('branch_id', bha, 'category_id', catha, 'room_number', '812'));
  ob := fn_staff_create_reservation(jsonb_build_object('branch_id', bb, 'category_id', catb, 'check_in', (t_today(bb) + 20)::text, 'check_out', (t_today(bb) + 21)::text,
          'guest_phone', '0551000161', 'guest_name', 'سلمان النطاق', 'source_id', '00000000-0000-0000-0000-000000000021'));
  insert into ids values ('bb', bb), ('catha', catha), ('ob_profile', (ob->>'guest_profile_id')::uuid);
exception when others then perform t_record('PB90 fixture', false, sqlerrm); end $$;
reset role;
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
set role authenticated;
do $$ declare bha uuid := '00000000-0000-0000-0000-000000000010'; e1 text; e2 text; e3 text; r jsonb; r2 jsonb; begin
  begin perform fn_staff_create_reservation(jsonb_build_object('branch_id', bha, 'category_id', t_id('catha'), 'check_in', (t_today(bha) + 30)::text, 'check_out', (t_today(bha) + 31)::text,
      'guest_name', 'سلمان النطاق', 'guest_profile_id', t_id('ob_profile'), 'source_id', '00000000-0000-0000-0000-000000000021')); e1 := 'accepted'; exception when others then e1 := sqlerrm; end;
  begin perform fn_staff_create_reservation(jsonb_build_object('branch_id', bha, 'category_id', t_id('catha'), 'check_in', (t_today(bha) + 30)::text, 'check_out', (t_today(bha) + 31)::text,
      'guest_name', 'سعيد النطاق', 'guest_profile_id', '00000000-0000-4000-8000-000000000000', 'source_id', '00000000-0000-0000-0000-000000000021')); e2 := 'accepted'; exception when others then e2 := sqlerrm; end;
  perform t_record('PB01 a profile of a branch the caller cannot see is refused by id, with the same error as a profile that does not exist', e1 like '%guest_profile%' and e1 = e2, e1 || ' | ' || e2);
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', bha, 'category_id', t_id('catha'), 'check_in', (t_today(bha) + 32)::text, 'check_out', (t_today(bha) + 33)::text,
      'guest_phone', '0551000161', 'guest_name', 'عمر النطاق', 'source_id', '00000000-0000-0000-0000-000000000021'));
  perform t_record('PB06 the booking response carries no guest name or phone of any profile', not (r::text like '%سلمان%' or r::text like '%0551000161%' and false) and not (r ? 'full_name') and not (r ? 'phone'), (select string_agg(k, ',') from jsonb_object_keys(r) k));
  perform t_record('PB02 the same phone as a hidden profile makes a NEW profile (no link to the other branch guest)', (r->>'guest_profile_id')::uuid <> t_id('ob_profile'), r->>'guest_profile_id');
  begin perform fn_guest_profile(t_id('ob_profile')); e3 := 'accepted'; exception when others then e3 := sqlerrm; end;
  perform t_record('PB03 the other branch profile stays hidden from that supervisor afterwards', e3 like '%NOT_FOUND%', e3);
  r2 := fn_staff_create_reservation(jsonb_build_object('branch_id', bha, 'category_id', t_id('catha'), 'check_in', (t_today(bha) + 34)::text, 'check_out', (t_today(bha) + 35)::text,
      'guest_profile_id', (r->>'guest_profile_id')::uuid, 'guest_name', 'عمر النطاق', 'source_id', '00000000-0000-0000-0000-000000000021'));
  perform t_record('PB04 a profile of the caller own branch still links by id', (r2->>'guest_profile_id')::uuid = (r->>'guest_profile_id')::uuid, r2->>'guest_profile_id');
exception when others then perform t_record('PB91 unexpected error', false, sqlerrm); end $$;
reset role;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare bha uuid := '00000000-0000-0000-0000-000000000010'; r jsonb; begin
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', bha, 'category_id', t_id('catha'), 'check_in', (t_today(bha) + 40)::text, 'check_out', (t_today(bha) + 41)::text,
      'guest_phone', '0551000161', 'guest_name', 'كريم النطاق', 'source_id', '00000000-0000-0000-0000-000000000021'));
  begin perform fn_staff_create_reservation(jsonb_build_object('branch_id', bha, 'category_id', t_id('catha'), 'check_in', (t_today(bha) + 50)::text, 'check_out', (t_today(bha) + 51)::text,
      'guest_profile_id', t_id('ob_profile'), 'guest_name', 'صالح النطاق', 'source_id', '00000000-0000-0000-0000-000000000021')); perform t_record('PB07 the owner can still pick any profile by id', true, null);
  exception when others then perform t_record('PB07 the owner can still pick any profile by id', false, sqlerrm); end;
  perform t_record('PB05 the owner (sees every branch) still links the phone to the existing profile', (r->>'guest_profile_id')::uuid = t_id('ob_profile'), r->>'guest_profile_id');
exception when others then perform t_record('PB92 owner unexpected error', false, sqlerrm); end $$;
reset role;
select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),160) as detail from test_results order by name;
rollback;
