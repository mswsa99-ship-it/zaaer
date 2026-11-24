\set ON_ERROR_STOP on
begin;
insert into organizations(id,name_ar) values('fe000000-0000-4000-8000-000000000001','Draft tenant A'),('fe000000-0000-4000-8000-000000000002','Draft tenant B');
insert into staff_profiles(id,auth_user_id,organization_id,full_name,email,role) values
('fe100000-0000-4000-8000-000000000001','fe200000-0000-4000-8000-000000000001','fe000000-0000-4000-8000-000000000001','Owner test','draft-owner@example.test','owner'),
('fe100000-0000-4000-8000-000000000002','fe200000-0000-4000-8000-000000000002','fe000000-0000-4000-8000-000000000001','Finance test','draft-finance@example.test','finance'),
('fe100000-0000-4000-8000-000000000003','fe200000-0000-4000-8000-000000000003','fe000000-0000-4000-8000-000000000002','Other tenant','draft-other@example.test','finance');
create temp table test_results(name text primary key,ok boolean not null);
grant all on test_results to authenticated;
create function pg_temp.login(uid text) returns void language sql as $$select set_config('request.jwt.claim.sub',uid,false)::text::void$$;
create function pg_temp.test_fail(name text,p jsonb) returns void language plpgsql as $$begin
 begin perform fn_owner_save_permission_draft(p);insert into test_results values(name,false);exception when others then insert into test_results values(name,true);end;
end$$;
set role authenticated;
select pg_temp.login('fe200000-0000-4000-8000-000000000001');
do $$declare before_p jsonb:=fn_my_permissions();r jsonb;begin
 r:=fn_owner_save_permission_draft('{"staff_id":"fe100000-0000-4000-8000-000000000002","pages":{"/staff/reservations":{"view":true,"add":false,"export":true}},"sensitive":[],"home_page":"/staff/reservations","expected_revision":0,"reason":"local test"}');
 insert into test_results values('owner saves draft only',r->>'active'='false' and r->>'revision'='1');
 insert into test_results values('owner permissions unchanged',before_p=fn_my_permissions());
end$$;
select pg_temp.test_fail('cannot change owner','{"staff_id":"fe100000-0000-4000-8000-000000000001","pages":{},"sensitive":[],"reason":"test"}');
select pg_temp.test_fail('other tenant rejected','{"staff_id":"fe100000-0000-4000-8000-000000000003","pages":{},"sensitive":[],"reason":"test"}');
select pg_temp.test_fail('stale edit rejected','{"staff_id":"fe100000-0000-4000-8000-000000000002","pages":{},"sensitive":[],"expected_revision":0,"reason":"test"}');
select pg_temp.test_fail('add requires view','{"staff_id":"fe100000-0000-4000-8000-000000000002","pages":{"/staff/reservations":{"view":false,"add":true}},"sensitive":[],"expected_revision":1,"reason":"test"}');
select pg_temp.test_fail('unknown page rejected','{"staff_id":"fe100000-0000-4000-8000-000000000002","pages":{"/admin/not-real":{"view":true}},"sensitive":[],"expected_revision":1,"reason":"test"}');
select pg_temp.test_fail('unknown action rejected','{"staff_id":"fe100000-0000-4000-8000-000000000002","pages":{"/staff/reservations":{"view":true,"superadmin":true}},"sensitive":[],"expected_revision":1,"reason":"test"}');
select pg_temp.test_fail('unknown capability rejected','{"staff_id":"fe100000-0000-4000-8000-000000000002","pages":{},"sensitive":["bad.cap"],"expected_revision":1,"reason":"test"}');
select pg_temp.test_fail('locked owner capability rejected','{"staff_id":"fe100000-0000-4000-8000-000000000002","pages":{},"sensitive":["admin.permissions"],"expected_revision":1,"reason":"test"}');
select pg_temp.test_fail('reason required','{"staff_id":"fe100000-0000-4000-8000-000000000002","pages":{},"sensitive":[],"expected_revision":1}');
select pg_temp.test_fail('home requires view','{"staff_id":"fe100000-0000-4000-8000-000000000002","pages":{},"home_page":"/admin/finance","sensitive":[],"expected_revision":1,"reason":"test"}');
select pg_temp.login('fe200000-0000-4000-8000-000000000002');
insert into test_results values('draft does not change target effective permissions',fn_can('reports.finance'));

insert into test_results values('staff cannot read draft',(select count(*) from staff_permission_drafts)=0);
select pg_temp.test_fail('staff cannot self grant','{"staff_id":"fe100000-0000-4000-8000-000000000002","pages":{},"sensitive":[],"reason":"test"}');
do $$begin begin insert into staff_permission_drafts(staff_id,organization_id,updated_by)values('fe100000-0000-4000-8000-000000000002','fe000000-0000-4000-8000-000000000001','fe100000-0000-4000-8000-000000000002');insert into test_results values('direct write rejected',false);exception when insufficient_privilege then insert into test_results values('direct write rejected',true);end;end$$;
reset role;
insert into test_results values('draft audit recorded',(select count(*) from audit_events where action='permissions.individual_draft_saved' and organization_id='fe000000-0000-4000-8000-000000000001')=1);

-- Activation is fixture-only here, never exposed as a product endpoint.
insert into staff_page_access(staff_id,organization_id,enabled,page_grants)values('fe100000-0000-4000-8000-000000000002','fe000000-0000-4000-8000-000000000001',true,'{"/staff/reservations":{"view":true,"export":true,"edit":false}}');
set role authenticated;
select pg_temp.login('fe200000-0000-4000-8000-000000000002');
insert into test_results values('individual mode detected',fn_user_access_mode()='individual');
insert into test_results values('view explicit allowed',fn_user_page_can('/staff/reservations','view'));
insert into test_results values('detail inherits visible page',fn_user_page_can('/staff/reservations/:id','view'));
insert into test_results values('create inherits add denied',not fn_user_page_can('/staff/reservations/new','add'));
insert into test_results values('export explicit allowed',fn_user_page_can('/staff/reservations','export'));
insert into test_results values('edit explicit denied',not fn_user_page_can('/staff/reservations','edit'));
insert into test_results values('other page denied',not fn_user_page_can('/admin/staff','view'));
insert into test_results values('unknown page denied',not fn_user_page_can('/admin/unknown','view'));
insert into test_results values('unknown action denied',not fn_user_page_can('/staff/reservations','promote'));
insert into test_results values('null action denied',not fn_user_page_can('/staff/reservations',null));
do $$begin begin perform fn_require_user_page('/admin/staff','view');insert into test_results values('require throws on deny',false);exception when insufficient_privilege then insert into test_results values('require throws on deny',true);end;end$$;
do $$begin perform fn_authorize_export('/staff/reservations');insert into test_results values('export gate allows explicit grant',true);end$$;
do $$begin begin perform fn_authorize_export('/admin/reports');insert into test_results values('export gate denies missing page',false);exception when insufficient_privilege then insert into test_results values('export gate denies missing page',true);end;end$$;
insert into test_results values('direct implementation not executable',not has_function_privilege('authenticated','fn_reservation_list__impl(uuid,jsonb,integer,integer)','execute'));
do $$begin begin perform fn_review_mark('{}'::jsonb);insert into test_results values('real wrapper denies ungranted page',false);exception when insufficient_privilege then insert into test_results values('real wrapper denies ungranted page',true);end;end$$;
do $$begin begin perform fn_cancel_invoice('fe999999-0000-4000-8000-000000000001','test');insert into test_results values('real invoice wrapper denies missing page',false);exception when insufficient_privilege then insert into test_results values('real invoice wrapper denies missing page',true);end;end$$;
select pg_temp.login('fe200000-0000-4000-8000-000000000003');
insert into test_results values('other tenant remains legacy',fn_user_access_mode()='legacy');
select pg_temp.login('fe200000-0000-4000-8000-000000000001');
insert into test_results values('owner all known hotel pages',fn_user_page_can('/admin/staff','view'));
insert into test_results values('owner not platform operator',not fn_user_page_can('/platform','view'));
reset role;
update staff_page_access set page_grants=page_grants||'{"/staff/payments":{"view":true,"edit":true},"/staff/ledger":{"view":true}}'::jsonb where staff_id='fe100000-0000-4000-8000-000000000002';
set role authenticated;
select pg_temp.login('fe200000-0000-4000-8000-000000000002');
insert into test_results values('sensitive refund denied without explicit code',not fn_can('voucher.refund'));
insert into test_results values('ordinary ledger view follows mapped page',fn_can('ledger.view'));
insert into test_results values('receipt add not inferred from edit',not fn_can('voucher.receipt'));
reset role;
update staff_page_access set sensitive_grants='["voucher.refund","voucher.correct"]'::jsonb where staff_id='fe100000-0000-4000-8000-000000000002';
set role authenticated;
insert into test_results values('sensitive refund requires page plus code',fn_can('voucher.refund'));
insert into test_results values('role restriction still applies',not fn_can('voucher.correct'));
insert into test_results values('locked owner code denied',not fn_can('admin.permissions'));
insert into test_results values('unmapped security denied',not fn_can('security'));
insert into test_results values('full grant not inferred',not fn_cap_full('voucher.correct'));
reset role;
update staff_profiles set is_active=false where id='fe100000-0000-4000-8000-000000000002';
set role authenticated;
select pg_temp.login('fe200000-0000-4000-8000-000000000002');
insert into test_results values('inactive denied despite grant',not fn_user_page_can('/staff/reservations','view'));
reset role;
table test_results;
do $$begin if exists(select 1 from test_results where not ok)then raise exception 'TEST FAILED';end if;end$$;
rollback;
