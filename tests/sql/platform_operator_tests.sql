-- Plan2.8: platform registry capabilities are separate from hotel employee roles.
-- No production fixtures. The initial red test only inspects API presence/privilege.
\set ON_ERROR_STOP on
begin;
create temp table operator_test_results(name text,ok boolean,detail text);
insert into operator_test_results values
 ('operator identity is separate from staff_profiles',to_regclass('public.platform_operators') is not null,null),
 ('operator hotel creation is retired',not has_function_privilege('authenticated','fn_platform_create_hotel(jsonb)','execute'),null),
 ('hotel status change is an explicit operator RPC',to_regprocedure('public.fn_platform_set_hotel_status(uuid,text,text)') is not null,null),
 ('registry listing is an explicit operator RPC',to_regprocedure('public.fn_platform_hotels()') is not null,null),
 ('owner invitation is retired',not has_function_privilege('service_role','fn_platform_owner_invite_target(uuid)','execute'),null),
 ('operator events have a separate immutable audit table',to_regclass('public.platform_events') is not null,null),
 ('guest access grants have explicit expiry and owner approval',to_regclass('public.platform_support_grants') is not null,null);
select case when ok then 'PASS' else 'FAIL' end as result,name,detail from operator_test_results;
do $$ begin if exists(select 1 from operator_test_results where ok is not true) then raise exception 'PLATFORM OPERATOR TESTS FAILED';end if;end $$;
rollback;

begin;
create temp table operator_behavior_results(name text,ok boolean,detail text);
grant all on operator_behavior_results to authenticated;
insert into platform_operators(auth_user_id,full_name) values('82000000-0000-0000-0000-000000000001','مشغل اختباري');
select t_login('82000000-0000-0000-0000-000000000002','unrelated@example.test');
set local role authenticated;
do $$ declare ok boolean:=false;begin
begin perform fn_platform_create_hotel('{"name_ar":"محاولة ممنوعة","branch_name":"فرع","owner_name":"مالك","owner_email":"deny@example.test","slug":"denied-test"}');exception when insufficient_privilege then ok:=true;end;
insert into operator_behavior_results values('unrelated authenticated user cannot create hotel',ok,null);
end $$;
reset role;
select t_login('82000000-0000-0000-0000-000000000001','operator@example.test');
set local role authenticated;
do $$ declare r jsonb;ok boolean;begin
begin perform fn_platform_create_hotel('{}');ok:=false;exception when insufficient_privilege then ok:=true;end;
insert into operator_behavior_results values('operator cannot create hotel or invite owner',ok and not has_function_privilege('authenticated','fn_platform_owner_invite_target(uuid)','execute'),null);
insert into operator_behavior_results values('operator registry is metadata only',not(fn_platform_hotels()::text like '%guest_name%'),null);
-- The operator has no hotel staff role: ordinary RLS cannot read hotel guest data.
insert into operator_behavior_results values('operator without staff profile has no hotel scope',fn_user_org_id() is null and fn_staff_id() is null,null);
begin insert into public.platform_operators(auth_user_id,full_name) values('82000000-0000-0000-0000-000000000003','تصعيد');ok:=false;exception when insufficient_privilege then ok:=true;end;
insert into operator_behavior_results values('operator cannot enroll another operator through direct writes',ok,null);
end $$;
reset role;
select case when ok then 'PASS' else 'FAIL' end as result,name,detail from operator_behavior_results;
do $$ begin if exists(select 1 from operator_behavior_results where ok is not true) then raise exception 'PLATFORM BEHAVIOR TESTS FAILED';end if;end $$;
rollback;

begin;
create temp table suspension_results(name text,ok boolean);
update organizations set platform_status='suspended' where id='00000000-0000-0000-0000-000000000001';
select t_login('a0000000-0000-0000-0000-000000000001','owner@test.local');
insert into suspension_results values('suspended hotel owner no longer has staff capabilities',fn_staff_id() is null and fn_user_org_id() is null and fn_current_role() is null);
select t_logout();
select case when ok then 'PASS' else 'FAIL' end as result,name from suspension_results;
do $$ begin if exists(select 1 from suspension_results where ok is not true) then raise exception 'SUSPENSION TEST FAILED';end if;end $$;
rollback;

-- Permission is per operator, per hotel, bounded in time and revocable. Reads are logged.
begin;
create temp table support_results(name text,ok boolean);
grant all on support_results to authenticated;
insert into platform_operators(auth_user_id,full_name) values('82000000-0000-0000-0000-000000000001','مشغّل اختباري');
select t_login('a0000000-0000-0000-0000-000000000001','owner@test.local');
set local role authenticated;
do $$ declare g uuid;bad boolean;begin
 select (fn_platform_grant_support('82000000-0000-0000-0000-000000000001','مساعدة باختبار أسماء النزلاء',1)->>'id')::uuid into g;
 perform set_config('test.support_grant',g::text,true);
 begin perform fn_platform_grant_support('82000000-0000-0000-0000-000000000001','تجاوز الوقت',25);bad:=false;exception when others then bad:=sqlerrm='VALIDATION: support_scope';end;
 insert into support_results values('support cannot exceed24hours',bad);
end $$;
reset role;
select t_login('82000000-0000-0000-0000-000000000001','operator@example.test');
set local role authenticated;
do $$ declare a jsonb;bad boolean;begin
 a:=fn_platform_support_guests(current_setting('test.support_grant')::uuid);
 insert into support_results values('approved support exposes only bounded ID and name fields',jsonb_array_length(a)<=100 and not exists(select 1 from jsonb_array_elements(a)x where x- 'id'- 'full_name'<>'{}'));
 begin perform fn_platform_support_guests('82000000-0000-0000-0000-000000000099');bad:=false;exception when insufficient_privilege then bad:=true;end;
 insert into support_results values('operator cannot read guests without exact approved grant',bad);
 begin perform fn_platform_grant_support('82000000-0000-0000-0000-000000000001','المشغل لا يوافق لنفسه',1);bad:=false;exception when others then bad:=sqlerrm like 'FORBIDDEN:%';end;
 insert into support_results values('operator cannot approve its own support access',bad);
end $$;
reset role;
insert into support_results select 'support read is audited with grant ID',exists(select 1 from platform_events where action='support.guests_read' and details->>'grant_id'=current_setting('test.support_grant'));
update platform_support_grants set expires_at=now()-interval '1 second',created_at=now()-interval '2 hours' where id=current_setting('test.support_grant')::uuid;
set local role authenticated;
do $$ declare bad boolean;begin begin perform fn_platform_support_guests(current_setting('test.support_grant')::uuid);bad:=false;exception when insufficient_privilege then bad:=true;end;insert into support_results values('expired support grant fails closed',bad);end $$;
reset role;
update platform_support_grants set expires_at=now()+interval '1 hour' where id=current_setting('test.support_grant')::uuid;
select t_login('a0000000-0000-0000-0000-000000000005','other-owner@test.local');
set local role authenticated;
do $$ declare bad boolean;begin begin perform fn_platform_revoke_support(current_setting('test.support_grant')::uuid);bad:=false;exception when others then bad:=sqlerrm='NOT_FOUND';end;insert into support_results values('other hotels owner cannot change support grant',bad);end $$;
reset role;
select t_login('a0000000-0000-0000-0000-000000000001','owner@test.local');
set local role authenticated;
select fn_platform_revoke_support(current_setting('test.support_grant')::uuid);
reset role;
select t_login('82000000-0000-0000-0000-000000000001','operator@example.test');
set local role authenticated;
do $$ declare bad boolean;begin begin perform fn_platform_support_guests(current_setting('test.support_grant')::uuid);bad:=false;exception when insufficient_privilege then bad:=true;end;insert into support_results values('revoked support grant fails closed immediately',bad);end $$;
reset role;
update platform_operators set is_active=false where auth_user_id='82000000-0000-0000-0000-000000000001';
set local role authenticated;
do $$ declare bad boolean;begin begin perform fn_platform_hotels();bad:=false;exception when insufficient_privilege then bad:=true;end;insert into support_results values('inactive operator loses registry access',bad);end $$;
reset role;
do $$ declare bad boolean;begin begin update platform_events set action='edited' where action='support.granted';bad:=false;exception when others then bad:=sqlerrm='IMMUTABLE: platform event';end;insert into support_results values('platform audit rejects updates',bad);end $$;
select case when ok then 'PASS' else 'FAIL' end as result,name from support_results;
do $$ begin if exists(select 1 from support_results where ok is not true) then raise exception 'SUPPORT TESTS FAILED';end if;end $$;
rollback;

begin;
create temp table suspension_capabilities(name text,ok boolean);
do $$ declare o uuid:='82000000-0000-0000-0000-000000000010';b uuid:='82000000-0000-0000-0000-000000000011';r uuid;tok text;ph text;bad boolean;begin
insert into organizations(id,name_ar,guest_slug) values(o,'فندق اختبار الإيقاف','suspended-fixture');
insert into branches(id,organization_id,name_ar) values(b,o,'فرع الإيقاف');
insert into reservations(organization_id,branch_id,check_in,check_out) values(o,b,current_date,current_date+1) returning id into r;
insert into registration_sessions(reservation_id,expires_at) values(r,now()+interval '1 day') returning token into tok;
ph:=fn_phone_session('0509876101','whatsapp_sender',o,b);
update organizations set platform_status='suspended' where id=o;
perform set_config('request.headers','{}',true);
insert into suspension_capabilities values('suspended public hotel slug cannot resolve',fn_guest_site('suspended-fixture') is null);
begin perform fn_token_reservation(tok);bad:=false;exception when others then bad:=sqlerrm='TOKEN_INVALID';end;
insert into suspension_capabilities values('existing registration capability is rejected',bad);
begin perform fn_guest_phone_reservations(ph);bad:=false;exception when others then bad:=sqlerrm='TOKEN_INVALID';end;
insert into suspension_capabilities values('existing WhatsApp phone capability is rejected without slug',bad);
begin perform fn_bank_mail_poll_config(o);bad:=false;exception when others then bad:=sqlerrm='HOTEL_UNAVAILABLE';end;
insert into suspension_capabilities values('suspended bank configuration cannot be read even by service',bad);
begin perform fn_bank_ingest(o,'{"body":"suspended bank message"}');bad:=false;exception when others then bad:=sqlerrm='HOTEL_UNAVAILABLE';end;
insert into suspension_capabilities values('suspended hotel cannot ingest bank messages',bad);
perform fn_run_monitors(b);
insert into suspension_capabilities values('scheduled monitors skip suspended hotels',not exists(select 1 from monitor_runs where branch_id=b));
insert into branch_whatsapp_channels(branch_id,organization_id,mode,bridge_key_hash,phone_number_id) values(b,o,'web_bridge',encode(extensions.digest('zb_'||repeat('a',64),'sha256'),'hex'),'123456789012345') on conflict(branch_id) do update set mode='web_bridge',bridge_key_hash=excluded.bridge_key_hash,phone_number_id=excluded.phone_number_id;
insert into suspension_capabilities values('existing bridge key cannot authenticate suspended hotel',fn_wa_bridge_auth('zb_'||repeat('a',64)) is null);
insert into suspension_capabilities values('webhook cannot resolve suspended hotel channel',fn_whatsapp_channel(b) is null);
begin perform fn_whatsapp_phone_session('0509876101',b);bad:=false;exception when others then bad:=sqlerrm='HOTEL_REQUIRED';end;
insert into suspension_capabilities values('trusted service cannot mint phone capabilities for suspended hotel',bad);
end $$;
select case when ok then 'PASS' else 'FAIL' end as result,name from suspension_capabilities;
do $$ begin if exists(select 1 from suspension_capabilities where ok is not true) then raise exception 'SUSPENSION CAPABILITIES FAILED';end if;end $$;
rollback;
