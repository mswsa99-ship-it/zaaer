-- 0141: fn_check_person_name refuses a name part of one letter and a part made of one repeated letter, and takes
-- only letters (Arabic/Latin, spaces, '’.-). The TS mirror has unit tests; the SQL function had none. Exercised
-- through fn_staff_create_reservation's guest_name (its caller since 0047/0152). Synthetic, rolled back.
begin;
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create temp table ids(k text primary key, v uuid);
grant all on ids to public;
create or replace function t_login(p_uid uuid, p_email text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_uid, 'email', p_email)::text, false);
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
create or replace function t_today(p uuid) returns date language sql security definer as $$ select fn_branch_today(p) $$;
create or replace function t_book(p_name text, p_day int) returns text language plpgsql as $$
begin
  perform fn_staff_create_reservation(jsonb_build_object('branch_id', t_id('b'), 'category_id', t_id('cat'),
    'check_in', (t_today(t_id('b')) + p_day)::text, 'check_out', (t_today(t_id('b')) + p_day + 1)::text,
    'guest_phone', '0551000191', 'guest_name', p_name, 'source_id', '00000000-0000-0000-0000-000000000021'));
  return 'accepted';
exception when others then return sqlerrm; end $$;

-- ---------------------------------------------------------------- fixtures (the owner): a branch and a room type
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; b uuid; cat uuid; begin
  r := fn_admin_upsert_branch('{"name_ar":"فرع الأسماء","name_en":"Names branch","tax_rate_bp":0}'); b := (r->>'id')::uuid;
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', b, 'name_ar', 'غرفة الأسماء', 'base_price_halalas', 20000)); cat := (r->>'id')::uuid;
  perform fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', '921'));
  insert into ids values ('b', b), ('cat', cat);
exception when others then perform t_record('NA90 fixture', false, sqlerrm); end $$;
reset role;

select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ begin
  perform t_record('NA01 a one-letter part is refused (Arabic and Latin alike)',
    t_book('ضيف ا الأسماء', 90) like '%name_letters_only%' and t_book('Ali B Smith', 91) like '%name_letters_only%', t_book('Ali B Smith', 91));
  perform t_record('NA02 a part made of one repeated letter is refused even when long enough',
    t_book('محمد اااا الحربي', 92) like '%name_letters_only%' and t_book('Oooo Smith', 93) like '%name_letters_only%', null);
  perform t_record('NA03 digits and symbols are not name letters',
    t_book('محمد 123', 94) like '%name_letters_only%' and t_book('ضيف @@', 95) like '%name_letters_only%', null);
  perform t_record('NA04 a two-letter part and ordinary Arabic and Latin names pass',
    t_book('طه النمر', 96) = 'accepted' and t_book('عبد الله', 97) = 'accepted' and t_book('Jean-Luc Picard', 98) = 'accepted', null);
  perform t_record('NA05 the refusal names the validation, not a generic error',
    t_book('احمد ا ت', 99) like 'VALIDATION: name_letters_only%', null);
exception when others then perform t_record('NA91 name checks unexpected error', false, sqlerrm); end $$;
reset role;

select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),160) as detail from test_results order by name;
rollback;
