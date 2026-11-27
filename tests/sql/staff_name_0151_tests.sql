-- 0151: a second ACTIVE staff member of the organization cannot carry the same name (case, spaces, Arabic marks, alef forms ignored);
-- a different name, an inactive namesake, an unchanged name and guests are not blocked. Synthetic fixture, rolled back.
\set ON_ERROR_STOP off
begin;
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create or replace function t_login(p_uid uuid, p_email text) returns void language plpgsql as $$ begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email)::text, false); end $$;
create or replace function t_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$ insert into test_results values (p_name, p_ok, p_detail) $$;
grant execute on function t_record(text, boolean, text) to public;
do $$ declare org uuid := '00000000-0000-0000-0000-000000000001'; begin
  insert into staff_profiles(id,auth_user_id,organization_id,full_name,email,role) values
    ('fe151000-0000-4000-8000-0000000000f0','a0000000-0000-0000-0000-0000000000f0',org,'مالك الاختبار','own151@example.test','owner');
  insert into staff_profiles(id,organization_id,full_name,email,role,is_active) values
    ('fe151000-0000-4000-8000-0000000000a1',org,'محمد الاختبار','m151a@example.test','supervisor',true),
    ('fe151000-0000-4000-8000-0000000000a2',org,'سعد قديم','s151@example.test','supervisor',false);
end $$;
set role authenticated;
select t_login('a0000000-0000-0000-0000-0000000000f0','own151@example.test');
do $$ declare br uuid := '00000000-0000-0000-0000-000000000010'; e text; r jsonb; sid uuid; begin
  -- NM01 same name, other email: refused
  begin perform fn_staff_invite('m151b@example.test','محمد الاختبار','supervisor',array[br]); e := 'accepted'; exception when others then e := sqlerrm; end;
  perform t_record('NM01 the same name for a second active person is refused', e like '%DUPLICATE_NAME%', e);
  -- NM02 same name with other case/spaces/alef form/diacritics: refused
  begin perform fn_staff_invite('m151c@example.test','  مُحَمَّد   الاختبار ','supervisor',array[br]); e := 'accepted'; exception when others then e := sqlerrm; end;
  perform t_record('NM02 extra spaces and Arabic marks do not make it a different name', e like '%DUPLICATE_NAME%', e);
  begin perform fn_staff_invite('a151a@example.test','أحمد الفحص','supervisor',array[br]); perform fn_staff_invite('a151b@example.test','احمد الفحص','supervisor',array[br]); e := 'accepted'; exception when others then e := sqlerrm; end;
  perform t_record('NM03 alef forms (أ and ا) are the same name', e like '%DUPLICATE_NAME%', e);
  -- NM04 a different name is accepted
  begin perform fn_staff_invite('m151d@example.test','محمد الاختبار - الاستقبال','supervisor',array[br]); e := 'accepted'; exception when others then e := sqlerrm; end;
  perform t_record('NM04 the same name plus a distinguishing word is accepted', e = 'accepted', e);
  -- NM05 an inactive namesake does not block
  begin perform fn_staff_invite('s151n@example.test','سعد قديم','supervisor',array[br]); e := 'accepted'; exception when others then e := sqlerrm; end;
  perform t_record('NM05 a former (inactive) staff name can be used again', e = 'accepted', e);
  -- NM06 the email rule still wins first
  begin perform fn_staff_invite('M151A@example.test','اسم مختلف تماما','supervisor',array[br]); e := 'accepted'; exception when others then e := sqlerrm; end;
  perform t_record('NM06 a duplicate email is still refused as DUPLICATE_EMAIL', e like '%DUPLICATE_EMAIL%', e);
  -- NM07 renaming onto another active person's name is refused; keeping the own name and editing another field is accepted
  select id into sid from staff_profiles where email = 'm151d@example.test';
  begin perform fn_admin_update_staff(jsonb_build_object('staff_id', sid, 'full_name', 'محمد الاختبار', 'reason', 'اختبار')); e := 'accepted'; exception when others then e := sqlerrm; end;
  perform t_record('NM07 renaming onto an active namesake is refused', e like '%DUPLICATE_NAME%', e);
  begin r := fn_admin_update_staff(jsonb_build_object('staff_id', sid, 'phone', '0555000151', 'reason', 'اختبار')); e := 'accepted'; exception when others then e := sqlerrm; end;
  perform t_record('NM08 editing another field of a person is not blocked', e = 'accepted', e);
  begin r := fn_admin_update_staff(jsonb_build_object('staff_id', sid, 'full_name', 'محمد الاختبار - الصندوق', 'reason', 'اختبار')); e := 'accepted'; exception when others then e := sqlerrm; end;
  perform t_record('NM09 renaming to a free name is accepted', e = 'accepted', e);
exception when others then perform t_record('NM00 unexpected error', false, sqlerrm); end $$;
reset role;
do $$ begin
  perform t_record('NM10 fn_person_name_key ignores case, spaces, marks, alef and ya/ta-marbuta forms', fn_person_name_key(' مُحَمَّد  اللاعبة ') = fn_person_name_key('محمد اللاعبه') and fn_person_name_key('x') <> fn_person_name_key('y') and fn_person_name_key('  ') is null, fn_person_name_key(' مُحَمَّد  اللاعبة '));
end $$;
select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),160) as detail from test_results order by name;
rollback;
