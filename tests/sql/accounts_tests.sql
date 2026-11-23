-- =====================================================================
-- Accounts (AC*; migration 0074): the security events a signed-in staff member records — own sign-in, sign-out and
-- password change; a reset link or an invitation for a colleague only within what the caller may manage — filed
-- under «security» (owner only), with the request's IP, at most 60 an hour; the owner's and the manager's view of
-- who has an account and when they last signed in; and the invitation's target, for the owner only.
-- =====================================================================
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create or replace function ac_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;
create or replace function ac_login(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), false);
  perform set_config('request.jwt.claims', case when p_uid is null then '{"role":"anon"}' else json_build_object('sub', p_uid, 'role', 'authenticated')::text end, false);
  perform set_config('request.headers', '{"x-forwarded-for":"203.0.113.7, 10.0.0.1","user-agent":"AC-test-browser"}', false);
end $$;

-- a manager in the first organisation, accounts in auth.users for some of the staff
insert into staff_profiles(id, auth_user_id, organization_id, full_name, email, role) values
 ('10000000-0000-0000-0000-0000000074a6', 'a0000000-0000-0000-0000-0000000074a6', '00000000-0000-0000-0000-000000000001', 'مدير الحسابات', 'mgr-ac@test.local', 'manager'),
 ('10000000-0000-0000-0000-0000000074a7', null, '00000000-0000-0000-0000-000000000001', 'مدعو بلا حساب', 'invited-ac@test.local', 'supervisor')
on conflict (id) do nothing;
insert into branch_memberships(staff_id, branch_id) values ('10000000-0000-0000-0000-0000000074a6', '00000000-0000-0000-0000-000000000010') on conflict do nothing;
insert into auth.users(id, email, email_confirmed_at, last_sign_in_at) values
 ('a0000000-0000-0000-0000-000000000001', 'owner@test.local', now() - interval '30 days', now() - interval '2 hours'),
 ('a0000000-0000-0000-0000-000000000002', 'sup@test.local', now() - interval '20 days', null)
on conflict (id) do nothing;

-- ---------------------------------------------------------------- AU01–AU03 who may record, and what is recorded
select ac_login(null);
set role anon;
do $$ begin
  perform fn_auth_event('security.signed_in', null);
  perform ac_record('AU01 a visitor without a session cannot record a security event', false, 'accepted');
exception when others then perform ac_record('AU01 a visitor without a session cannot record a security event', sqlerrm like '%permission denied%' or sqlerrm like 'FORBIDDEN%', sqlerrm);
end $$;
reset role;

select ac_login('a0000000-0000-0000-0000-000000000001');
set role authenticated;
do $$ declare r jsonb; e audit_events%rowtype; begin
  begin
    perform fn_auth_event('security.made_up', null);
    perform ac_record('AU02 only the listed security events can be recorded', false, 'accepted');
  exception when others then perform ac_record('AU02 only the listed security events can be recorded', sqlerrm = 'VALIDATION: action', sqlerrm);
  end;
  r := fn_auth_event('security.signed_in', null);
  select * into e from audit_events where action = 'security.signed_in' and actor_id = '10000000-0000-0000-0000-000000000001' order by created_at desc limit 1;
  perform ac_record('AU03 the owner''s sign-in is filed under «security» on their own profile, with the first forwarded IP and the browser',
    (r->>'ok')::boolean and e.category = 'security' and e.entity_type = 'staff_profile' and e.entity_id = '10000000-0000-0000-0000-000000000001'
    and e.details->>'ip' = '203.0.113.7' and e.details->>'user_agent' = 'AC-test-browser' and e.actor_type = 'staff', r::text);
exception when others then perform ac_record('AU03 the owner''s sign-in is filed under «security»', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- AU04–AU05 a colleague's link: within what the caller may manage
select ac_login('a0000000-0000-0000-0000-000000000002');
set role authenticated;
do $$ declare ok_own boolean; begin
  ok_own := (fn_auth_event('security.password_changed', null)->>'ok')::boolean;
  begin
    perform fn_auth_event('security.password_link_sent', '10000000-0000-0000-0000-000000000003');
    perform ac_record('AU04 a supervisor records their own password change but cannot send a colleague a link', false, 'accepted');
  exception when others then perform ac_record('AU04 a supervisor records their own password change but cannot send a colleague a link', ok_own and sqlerrm like 'FORBIDDEN%', sqlerrm);
  end;
end $$;
reset role;

select ac_login('a0000000-0000-0000-0000-0000000074a6');
set role authenticated;
do $$ declare ok1 boolean; e1 text; e2 text; e3 text; begin
  ok1 := (fn_auth_event('security.password_link_sent', '10000000-0000-0000-0000-000000000002')->>'ok')::boolean;
  begin perform fn_auth_event('security.password_link_sent', '10000000-0000-0000-0000-000000000001'); e1 := 'accepted'; exception when others then e1 := sqlerrm; end;
  begin perform fn_auth_event('security.password_link_sent', '10000000-0000-0000-0000-000000000005'); e2 := 'accepted'; exception when others then e2 := sqlerrm; end;
  begin perform fn_auth_event('security.signed_out', '10000000-0000-0000-0000-000000000002'); e3 := 'accepted'; exception when others then e3 := sqlerrm; end;
  perform ac_record('AU05a a manager sends a supervisor a link, not the owner, never another organisation''s staff, and only links and invitations name a colleague',
    ok1 and e1 like 'FORBIDDEN%' and e2 = 'NOT_FOUND' and e3 = 'VALIDATION: target', concat_ws(' | ', ok1, e1, e2, e3));
end $$;
reset role;
select ac_record('AU05b the link is recorded on the colleague''s profile with their name',
  exists (select 1 from audit_events where action = 'security.password_link_sent' and entity_id = '10000000-0000-0000-0000-000000000002'
            and actor_id = '10000000-0000-0000-0000-0000000074a6' and details->>'target_name' = 'مشرف'));

-- ---------------------------------------------------------------- AU06 at most 60 security events an hour
insert into audit_events(organization_id, actor_id, action, entity_type, entity_id, details)
select '00000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000004', 'security.signed_in', 'staff_profile', '10000000-0000-0000-0000-000000000004', '{}'::jsonb
  from generate_series(1, 60);
select ac_login('a0000000-0000-0000-0000-000000000004');
set role authenticated;
do $$ declare r jsonb; begin
  r := fn_auth_event('security.signed_in', null);
  perform ac_record('AU06a the 61st security event within an hour is skipped', r->>'skipped' = 'throttled', r::text);
exception when others then perform ac_record('AU06a the 61st security event within an hour is skipped', false, sqlerrm);
end $$;
reset role;
select ac_record('AU06b and is not stored', (select count(*) from audit_events where actor_id = '10000000-0000-0000-0000-000000000004' and action = 'security.signed_in') = 60);

-- ---------------------------------------------------------------- AU07 who has an account, and the last sign-in
select ac_login('a0000000-0000-0000-0000-000000000001');
set role authenticated;
do $$ declare s jsonb; o jsonb; sup jsonb; inv jsonb; begin
  s := fn_admin_staff_auth_status();
  select x into o from jsonb_array_elements(s) x where x->>'staff_id' = '10000000-0000-0000-0000-000000000001';
  select x into sup from jsonb_array_elements(s) x where x->>'staff_id' = '10000000-0000-0000-0000-000000000002';
  select x into inv from jsonb_array_elements(s) x where x->>'staff_id' = '10000000-0000-0000-0000-0000000074a7';
  perform ac_record('AU07 the owner sees, for their organisation only, who has an account, whether its e-mail is confirmed and the last sign-in',
    (o->>'has_account')::boolean and (o->>'email_confirmed')::boolean and o->>'last_sign_in_at' is not null
    and (sup->>'has_account')::boolean and sup->>'last_sign_in_at' is null and not (inv->>'has_account')::boolean
    and not exists (select 1 from jsonb_array_elements(s) x where x->>'staff_id' = '10000000-0000-0000-0000-000000000005'), s::text);
exception when others then perform ac_record('AU07 the owner sees who has an account', false, sqlerrm);
end $$;
reset role;

select ac_login('a0000000-0000-0000-0000-000000000002');
set role authenticated;
do $$ begin
  perform fn_admin_staff_auth_status();
  perform ac_record('AU08 a supervisor cannot read the staff''s sign-in status', false, 'accepted');
exception when others then perform ac_record('AU08 a supervisor cannot read the staff''s sign-in status', sqlerrm like 'FORBIDDEN%', sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- AU09 the invitation's target: the owner only
select ac_login('a0000000-0000-0000-0000-000000000001');
set role authenticated;
do $$ declare t jsonb; e text; begin
  t := fn_admin_staff_invite_target('10000000-0000-0000-0000-0000000074a7');
  begin perform fn_admin_staff_invite_target('10000000-0000-0000-0000-000000000005'); e := 'accepted'; exception when others then e := sqlerrm; end;
  perform ac_record('AU09 the owner gets the invitation''s e-mail for a staff member without an account; another organisation''s staff is not found',
    t->>'email' = 'invited-ac@test.local' and not (t->>'linked')::boolean and e = 'NOT_FOUND', t::text || ' | ' || e);
exception when others then perform ac_record('AU09 the owner gets the invitation''s e-mail', false, sqlerrm);
end $$;
reset role;
select ac_login('a0000000-0000-0000-0000-0000000074a6');
set role authenticated;
do $$ begin
  perform fn_admin_staff_invite_target('10000000-0000-0000-0000-0000000074a7');
  perform ac_record('AU10 a manager cannot send invitations', false, 'accepted');
exception when others then perform ac_record('AU10 a manager cannot send invitations', sqlerrm like 'FORBIDDEN%', sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- AU11 only the owner reads the security events
select ac_login('a0000000-0000-0000-0000-0000000074a6');
set role authenticated;
do $$ begin
  perform ac_record('AU11 the security events are not visible to a manager (category «security» is the owner''s)',
    not exists (select 1 from audit_events where action like 'security.%'), null);
end $$;
reset role;

-- ---------------------------------------------------------------- AU12 the log reads the account events in Arabic
do $$ begin
  perform ac_record('AU12 the account events read in Arabic in the log (fn_audit_action_label asks 0074''s function)',
    fn_audit_action_label('security.signed_in') = 'تسجيل دخول'
    and fn_audit_action_label('security.password_changed') = 'تغيير كلمة المرور'
    and fn_audit_action_label('security.password_link_sent') = 'إرسال رابط تعيين كلمة المرور'
    and fn_audit_action_label('reservation.created') = 'إنشاء حجز'
    and fn_audit_action_label('day_closing.amended') = 'تعديل إقفال يوم خلال المهلة'
    and (select count(*) from regexp_matches(pg_get_functiondef('fn_audit_action_label(text)'::regprocedure), 'fn_audit_account_label\(p_action\)', 'g')) = 1,
    pg_get_functiondef('fn_audit_action_label(text)'::regprocedure));
end $$;

select ac_login(null);
select case when ok then 'PASS' else 'FAIL' end as result, name, case when ok then null else detail end as detail from test_results order by name;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from test_results where ok is not true) then raise exception 'ACCOUNTS TESTS FAILED'; end if;
  if (select count(*) from test_results) < 14 then raise exception 'ACCOUNTS TESTS INCOMPLETE: % of 14 checks ran', (select count(*) from test_results); end if;
end $$;
