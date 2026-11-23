-- Plan 2.5: every hotel owns its settings and starts from code defaults, never another hotel's values.
\set ON_ERROR_STOP on
begin;
create temp table test_results(name text, ok boolean, detail text);
do $$
declare a uuid := '90000000-0000-0000-0000-000000000091'; b uuid := '90000000-0000-0000-0000-000000000092'; before_b text; after_b text; n int; counter_a text; counter_b text;
begin
 insert into organizations(id,name_ar) values (a,'فندق فحص الإعدادات الأول'),(b,'فندق فحص الإعدادات الثاني');
 insert into test_results select 'HS01 each new hotel has AI and system settings',
  (select count(*) from ai_settings where organization_id in(a,b))=2 and (select count(*) from system_settings where organization_id in(a,b))=2,null;
 insert into test_results select 'HS02 each new hotel has its default rules and accounts',
  (select count(*) from alert_rules where organization_id=a)=8 and (select count(*) from bank_parse_rules where organization_id=a)=25 and (select count(*) from gl_accounts where organization_id=a)=21
  and (select count(*) from alert_rules where organization_id=b)=8 and (select count(*) from bank_parse_rules where organization_id=b)=25 and (select count(*) from gl_accounts where organization_id=b)=21,null;
 select md5(concat((select jsonb_agg(to_jsonb(x)) from ai_settings x where organization_id=b),(select jsonb_agg(to_jsonb(x)) from system_settings x where organization_id=b),(select jsonb_agg(to_jsonb(x) order by event) from alert_rules x where organization_id=b),(select jsonb_agg(to_jsonb(x) order by id) from bank_parse_rules x where organization_id=b),(select jsonb_agg(to_jsonb(x) order by id) from gl_accounts x where organization_id=b))) into before_b;
 update ai_settings set daily_request_limit=17,model='hotel-a-custom-model' where organization_id=a;
 update system_settings set demo_mode=false where organization_id=a;
 update alert_rules set delay_minutes=19 where organization_id=a;
 update bank_parse_rules set priority=901 where organization_id=a;
 update gl_accounts set name='اسم محلي مخصص' where organization_id=a and system_key='assets';
 select md5(concat((select jsonb_agg(to_jsonb(x)) from ai_settings x where organization_id=b),(select jsonb_agg(to_jsonb(x)) from system_settings x where organization_id=b),(select jsonb_agg(to_jsonb(x) order by event) from alert_rules x where organization_id=b),(select jsonb_agg(to_jsonb(x) order by id) from bank_parse_rules x where organization_id=b),(select jsonb_agg(to_jsonb(x) order by id) from gl_accounts x where organization_id=b))) into after_b;
 insert into test_results values('HS03 changing hotel A leaves hotel B byte-identical',before_b=after_b,null);
 if to_regprocedure('public.fn_hotel_settings_seed(uuid)') is not null then
  perform fn_hotel_settings_seed(a); perform fn_hotel_settings_seed(a);
  insert into test_results select 'HS04 seeding twice preserves custom choices and does not duplicate defaults',
   (select daily_request_limit=17 and model='hotel-a-custom-model' from ai_settings where organization_id=a)
   and (select not demo_mode from system_settings where organization_id=a)
   and (select count(*)=25 and bool_and(priority=901) from bank_parse_rules where organization_id=a)
   and (select name='اسم محلي مخصص' from gl_accounts where organization_id=a and system_key='assets')
   and (select count(*)=21 from gl_accounts where organization_id=a),null;
  insert into test_results select 'HS05 visitors and staff cannot seed arbitrary hotels',
   not has_function_privilege('anon','fn_hotel_settings_seed(uuid)','execute') and not has_function_privilege('authenticated','fn_hotel_settings_seed(uuid)','execute'),null;
 else
  insert into test_results values('HS04 seed helper exists',false,null),('HS05 seed helper protected',false,null);
 end if;
 insert into staff_profiles(id,auth_user_id,organization_id,full_name,email,role) values
 ('90000000-0000-0000-0000-000000000093','90000000-0000-0000-0000-000000000094',a,'مالك فحص الإعدادات','hotel-settings@test.local','owner');
 perform set_config('request.jwt.claim.sub','90000000-0000-0000-0000-000000000094',true);
 perform set_config('request.jwt.claims','{"sub":"90000000-0000-0000-0000-000000000094","role":"authenticated"}',true);
 execute 'set local role authenticated';
 select count(*) into n from ai_settings where organization_id=b;
 n:=n+(select count(*) from system_settings where organization_id=b)+(select count(*) from bank_parse_rules where organization_id=b)+(select count(*) from alert_rules where organization_id=b)+(select count(*) from gl_accounts where organization_id=b);
 perform fn_admin_update_ai_settings('{"daily_request_limit":23}'::jsonb);
 execute 'reset role';
 insert into test_results select 'HS06 hotel A owner sees none of B settings and updates only A',n=0 and (select daily_request_limit=23 from ai_settings where organization_id=a) and (select daily_request_limit=2000 from ai_settings where organization_id=b),null;
 counter_a:=fn_next_document_number(a,'hs_probe','HS'); counter_b:=fn_next_document_number(b,'hs_probe','HS');
 insert into test_results select 'HS07 each hotel starts its own document counter',counter_a=counter_b and (select count(*)=2 and bool_and(last_value=1) from document_sequences where organization_id in(a,b) and kind='hs_probe'),null;
end $$;
select case when ok then 'PASS' else 'FAIL' end as result,name,detail from test_results order by name;
do $$ begin
 if exists(select 1 from test_results where ok is not true) or (select count(*) from test_results)<>7 then raise exception 'HOTEL SETTINGS TESTS FAILED'; end if;
end $$;
rollback;
