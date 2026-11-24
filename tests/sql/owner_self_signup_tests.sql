\set ON_ERROR_STOP on
begin;
create temp table signup_results(name text,ok boolean);
grant all on signup_results to authenticated,anon;
insert into auth.users(id,email,email_confirmed_at) values
('98000000-0000-0000-0000-000000000001','signup-new@example.test',now()),
('98000000-0000-0000-0000-000000000002','signup-unconfirmed@example.test',null),
('98000000-0000-0000-0000-000000000003','signup-duplicate@example.test',now()),
('98000000-0000-0000-0000-000000000004','signup-pending@example.test',now()),
('98000000-0000-0000-0000-000000000005','signup-operator@example.test',now());
insert into staff_profiles(organization_id,full_name,email,role,is_active) values('00000000-0000-0000-0000-000000000001','موظف مدعو','signup-pending@example.test','supervisor',true);
insert into platform_operators(auth_user_id,full_name) values('98000000-0000-0000-0000-000000000005','مشغل اختبار التسجيل');
select t_login('98000000-0000-0000-0000-000000000002','signup-new@example.test');
set local role authenticated;
do $$declare bad boolean;begin
begin perform fn_owner_register_hotel('{}');bad:=false;exception when others then bad:=sqlerrm='EMAIL_NOT_CONFIRMED';end;
insert into signup_results values('unconfirmed real auth user rejected despite forged JWT email',bad);
end$$;
reset role;
select t_login('98000000-0000-0000-0000-000000000001','forged@example.test');
set local role authenticated;
do $$declare a jsonb;b jsonb;bad boolean;begin
begin perform fn_owner_register_hotel('{"name_ar":"x"}');bad:=false;exception when others then bad:=sqlerrm='VALIDATION: hotel_fields';end;
insert into signup_results values('invalid fields rejected before creation',bad);
a:=fn_owner_register_hotel('{"name_ar":"فندق التسجيل الذاتي","branch_name":"أول فرع","full_name":"مالك جديد موثق","slug":"owner-self-signup-test","organization_id":"00000000-0000-0000-0000-000000000001","email":"forged@example.test","role":"platform_operator"}');
perform set_config('test.signup_org',a->>'id',true);
insert into signup_results select 'new owner uses real identity and new tenant, not client email or organization',fn_user_org_id()=(a->>'id')::uuid and fn_user_org_id()<>'00000000-0000-0000-0000-000000000001'::uuid and exists(select 1 from staff_profiles where auth_user_id='98000000-0000-0000-0000-000000000001' and email='signup-new@example.test' and role='owner');
insert into signup_results select 'new owner has no branches until internal setup',count(*)=0 from branches;
b:=fn_owner_register_hotel('{}');insert into signup_results values('repeat registration idempotently returns same hotel',b->>'id'=a->>'id' and b->>'existing'='true');
insert into signup_results select 'fresh hotel settings disable demo mode',exists(select 1 from system_settings where organization_id=(a->>'id')::uuid and not demo_mode) and exists(select 1 from ai_settings where organization_id=(a->>'id')::uuid);
insert into signup_results select 'self registration is audited',exists(select 1 from audit_events where organization_id=(a->>'id')::uuid and action='hotel.owner_self_registered');
begin perform fn_admin_invite_staff('{"full_name":"مالك ممنوع","email":"owner-invite-denied@example.test","role":"owner"}');bad:=false;exception when others then bad:=sqlerrm='OWNER_SELF_SIGNUP_REQUIRED';end;
insert into signup_results values('owner cannot invite another owner through staff API',bad);
end$$;
reset role;
select t_login('98000000-0000-0000-0000-000000000003','signup-duplicate@example.test');
set local role authenticated;
do $$declare a jsonb;begin a:=fn_owner_register_hotel('{"name_ar":"فندق ثان","full_name":"مالك ثان جديد","slug":"owner-self-signup-test"}');insert into signup_results values('client slug is ignored and identity-derived site stays unique',a->>'id'<>current_setting('test.signup_org'));end$$;
reset role;
select t_login('98000000-0000-0000-0000-000000000004','signup-pending@example.test');
set local role authenticated;
do $$declare bad boolean;begin begin perform fn_owner_register_hotel('{}');bad:=false;exception when others then bad:=sqlerrm='ACCOUNT_PENDING_LINK';end;insert into signup_results values('pending invited staff cannot elevate through owner signup',bad);end$$;
reset role;
select t_login('98000000-0000-0000-0000-000000000005','signup-operator@example.test');
set local role authenticated;
do $$declare bad boolean;begin begin perform fn_owner_register_hotel('{}');bad:=false;exception when others then bad:=sqlerrm='PLATFORM_ACCOUNT';end;insert into signup_results values('platform account cannot create hotel for itself',bad);end$$;
reset role;
select t_login('a0000000-0000-0000-0000-000000000001','owner@test.local');
set local role authenticated;
insert into signup_results select 'old owner cannot read new hotel branch',not exists(select 1 from branches where organization_id=current_setting('test.signup_org')::uuid);
reset role;
select t_logout();set local role anon;
do $$declare bad boolean;begin begin perform fn_owner_register_hotel('{}');bad:=false;exception when insufficient_privilege then bad:=true;end;insert into signup_results values('anonymous cannot execute signup RPC',bad);end$$;
reset role;
select case when ok then 'PASS' else 'FAIL' end as result,name from signup_results;
do $$begin if exists(select 1 from signup_results where ok is not true) then raise exception 'OWNER SIGNUP TESTS FAILED';end if;end$$;
rollback;
