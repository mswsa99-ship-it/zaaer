-- 0154: the similar-booking warning reports the same guest (phone or name) on the same branch, dates and unit type; nothing else. Synthetic, rolled back.
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
do $$ declare r jsonb; b uuid; cat uuid; sim jsonb; src uuid := '00000000-0000-0000-0000-000000000021'; ci text; co text; base jsonb; begin
  r := fn_admin_upsert_branch('{"name_ar":"فرع التشابه","name_en":"Similar branch","tax_rate_bp":0}'); b := (r->>'id')::uuid;
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', b, 'name_ar', 'غرفة التشابه', 'base_price_halalas', 20000)); cat := (r->>'id')::uuid;
  perform fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', '901'));
  perform fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', '902'));
  ci := (t_today(b) + 20)::text; co := (t_today(b) + 22)::text;
  perform fn_staff_create_reservation(jsonb_build_object('branch_id', b, 'category_id', cat, 'check_in', ci, 'check_out', co, 'guest_phone', '0551000171', 'guest_name', 'خالد التشابه', 'source_id', src));
  base := jsonb_build_object('branch_id', b, 'category_id', cat, 'check_in', ci, 'check_out', co);
  sim := fn_staff_similar_bookings(base || '{"guest_phone":"0551000171","guest_name":"اسم آخر"}');
  perform t_record('SB01 the same phone on the same dates and unit type is reported', (sim->>'count')::int = 1 and (sim->'items'->0->>'same_phone')::boolean, sim::text);
  sim := fn_staff_similar_bookings(base || '{"guest_phone":"0551000172","guest_name":"خَالد  التشابه"}');
  perform t_record('SB02 the same name (spaces, marks ignored) with another phone is reported', (sim->>'count')::int = 1 and (sim->'items'->0->>'same_name')::boolean, sim::text);
  sim := fn_staff_similar_bookings(base || '{"guest_phone":"0551000173","guest_name":"ماجد مختلف"}');
  perform t_record('SB03 a different guest on the same dates and unit type is NOT reported', (sim->>'count')::int = 0, sim::text);
  sim := fn_staff_similar_bookings(jsonb_build_object('branch_id', b, 'category_id', cat, 'check_in', (t_today(b) + 30)::text, 'check_out', (t_today(b) + 32)::text, 'guest_phone', '0551000171', 'guest_name', 'خالد التشابه'));
  perform t_record('SB04 the same guest on other dates is NOT reported', (sim->>'count')::int = 0, sim::text);
  perform t_record('SB05 the answer never carries the other booking guest name or phone', not (sim::text like '%0551000171%') and not (fn_staff_similar_bookings(base || '{"guest_phone":"0551000171"}')::text like '%خالد%'));
  insert into ids values ('b', b), ('cat', cat);
exception when others then perform t_record('SB90 unexpected error', false, sqlerrm); end $$;
reset role;
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
set role authenticated;
do $$ declare e text; begin
  begin perform fn_staff_similar_bookings(jsonb_build_object('branch_id', t_id('b'), 'category_id', t_id('cat'), 'check_in', (t_today(t_id('b')) + 20)::text, 'check_out', (t_today(t_id('b')) + 22)::text, 'guest_phone', '0551000171')); e := 'accepted'; exception when others then e := sqlerrm; end;
  perform t_record('SB06 a supervisor of another branch cannot probe a branch they have no grant on', e like '%FORBIDDEN%', e);
end $$;
reset role;
select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),160) as detail from test_results order by name;
rollback;
