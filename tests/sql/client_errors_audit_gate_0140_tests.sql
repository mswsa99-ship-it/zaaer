-- 0140 client_errors audit-logs page gate tests. Scope: client_errors only; integration_events is held and not asserted.
\set ON_ERROR_STOP off
begin;
begin;
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create or replace function xg_login(p_uid uuid, p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email)::text, false); end $$;
create or replace function xg_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail); $$;
create or replace function xg_cnt(p_table text) returns int language plpgsql as $$ declare n int; begin execute format('select count(*) from %I', p_table) into n; return n; end $$;
create or replace function xg_foreign(p_table text) returns int language plpgsql as $$ declare n int; begin execute format('select count(*) from %I where organization_id <> fn_user_org_id()', p_table) into n; return n; end $$;
create or replace function xg_org(p_table text) returns int language plpgsql security definer as $$ declare n int; begin execute format('select count(*) from %I where organization_id = ''00000000-0000-0000-0000-000000000001''', p_table) into n; return n; end $$;
create or replace function xg_denied(p_sql text) returns boolean language plpgsql as $$ begin execute p_sql; return false; exception when others then return sqlstate in ('42501','P0001') ; end $$;
create or replace function xg_upd_notif() returns int language plpgsql as $$ declare n int; begin update notifications set read_at = now(); get diagnostics n = row_count; return n; end $$;
create or replace function xg_decoy(p_table text) returns int language plpgsql security definer as $$ declare n int; begin execute format('select count(*) from %I where organization_id <> ''00000000-0000-0000-0000-000000000001''', p_table) into n; return n; end $$;
grant execute on function xg_upd_notif(), xg_decoy(text) to public;
grant execute on function xg_login(uuid,text), xg_record(text,boolean,text), xg_cnt(text), xg_foreign(text), xg_org(text), xg_denied(text) to public;
insert into staff_profiles(id, auth_user_id, organization_id, full_name, email, role) values
 ('1d000000-0000-0000-0000-000000000001','cd000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','ig legacy mgr','igmgr@test.local','manager'),
 ('1d000000-0000-0000-0000-000000000002','cd000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001','ig fin ctl','igfc@test.local','manager'),
 ('1d000000-0000-0000-0000-000000000003','cd000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000001','ig journey','igj@test.local','manager'),
 ('1d000000-0000-0000-0000-000000000004','cd000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000001','ig products+guests','igpg@test.local','manager'),
 ('1d000000-0000-0000-0000-000000000005','cd000000-0000-0000-0000-000000000005','00000000-0000-0000-0000-000000000001','ig no grants','ignone@test.local','manager');
insert into branch_memberships(staff_id, branch_id, organization_id)
 select s, '00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001'
 from unnest(array['1d000000-0000-0000-0000-000000000001','1d000000-0000-0000-0000-000000000002','1d000000-0000-0000-0000-000000000003','1d000000-0000-0000-0000-000000000004','1d000000-0000-0000-0000-000000000005']::uuid[]) s;
insert into staff_page_access(staff_id, organization_id, enabled, page_grants) values
 ('1d000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001',true,'{"/admin/finance-controls":{"view":true}}'),
 ('1d000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000001',true,'{"/admin/journey":{"view":true}}'),
 ('1d000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000001',true,'{"/admin/products":{"view":true},"/admin/guests":{"view":true},"/staff/orders":{"view":true}}'),
 ('1d000000-0000-0000-0000-000000000005','00000000-0000-0000-0000-000000000001',true,'{}');
insert into staff_profiles(id, auth_user_id, organization_id, full_name, email, role) values
 ('1d000000-0000-0000-0000-000000000006','cd000000-0000-0000-0000-000000000006','00000000-0000-0000-0000-000000000001','te audit mgr','teaudit@test.local','manager'),
 ('1d000000-0000-0000-0000-000000000007','cd000000-0000-0000-0000-000000000007','00000000-0000-0000-0000-000000000001','te audit supervisor','tesup@test.local','supervisor');
insert into branch_memberships(staff_id, branch_id, organization_id) values
 ('1d000000-0000-0000-0000-000000000006','00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000001'),
 ('1d000000-0000-0000-0000-000000000007','00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000001');
insert into staff_page_access(staff_id, organization_id, enabled, page_grants) values
 ('1d000000-0000-0000-0000-000000000006','00000000-0000-0000-0000-000000000001',true,'{"/admin/audit-logs":{"view":true}}'),
 ('1d000000-0000-0000-0000-000000000007','00000000-0000-0000-0000-000000000001',true,'{"/admin/audit-logs":{"view":true}}');
insert into organizations(id, name_ar) values ('1f900000-0000-0000-0000-000000000001','te foreign org') on conflict do nothing;
insert into client_errors(organization_id,error_code,trace_id) values('00000000-0000-0000-0000-000000000001','TEOWN','TRACEOWN1'),('1f900000-0000-0000-0000-000000000001','TEFOREIGN','TRACEFOR1');
create or replace function te_own(p text) returns int language plpgsql security definer as $$ declare n int; begin execute format('select count(*) from %I where organization_id=''00000000-0000-0000-0000-000000000001'' and %s', p, case p when 'client_errors' then 'error_code=''TEOWN''' else 'source=''te''' end) into n; return n; end $$;
create or replace function te_cnt(p text) returns int language plpgsql as $$ declare n int; begin execute format('select count(*) from %I where %s', p, case p when 'client_errors' then 'error_code in (''TEOWN'',''TEFOREIGN'')' else 'source=''te''' end) into n; return n; end $$;
create or replace function te_for(p text) returns int language plpgsql as $$ declare n int; begin execute format('select count(*) from %I where organization_id<>fn_user_org_id()', p) into n; return n; end $$;
grant execute on function te_own(text),te_cnt(text),te_for(text) to public;
select xg_record('TE00 fixtures: own and foreign client_errors rows exist', te_own('client_errors')=1 and xg_decoy('client_errors')>0);
set role authenticated;
select xg_login('cd000000-0000-0000-0000-000000000001','igmgr@test.local');
do $$ begin
 perform xg_record('TE01 legacy manager reads own client_errors', te_cnt('client_errors')=1, te_cnt('client_errors')::text);
 perform xg_record('TE02 legacy manager 0 foreign rows', te_for('client_errors')=0);
end $$;
select xg_login('cd000000-0000-0000-0000-000000000006','teaudit@test.local');
do $$ begin
 perform xg_record('TE03 individual manager WITH audit-logs view: reads own client_errors (positive control)', te_cnt('client_errors')=1, te_cnt('client_errors')::text);
 perform xg_record('TE05 same user: 0 foreign rows', te_for('client_errors')=0);
 perform xg_record('TE06 same user: fn_lookup_trace allowed', not xg_denied($q$select fn_lookup_trace('TRACEOWN1')$q$));
end $$;
select xg_login('cd000000-0000-0000-0000-000000000002','igfc@test.local');
do $$ begin perform xg_record('TE07 individual with other grant (finance-controls): client_errors 0', te_cnt('client_errors')=0, te_cnt('client_errors')::text); end $$;
select xg_login('cd000000-0000-0000-0000-000000000005','ignone@test.local');
do $$ begin perform xg_record('TE08 individual zero grants: client_errors 0; fn_lookup_trace denied', te_cnt('client_errors')=0 and xg_denied($q$select fn_lookup_trace('TRACEOWN1')$q$), te_cnt('client_errors')::text); end $$;
select xg_login('cd000000-0000-0000-0000-000000000007','tesup@test.local');
do $$ begin perform xg_record('TE09 individual supervisor with audit-logs view: client_errors 0 (role predicate unchanged)', te_cnt('client_errors')=0, te_cnt('client_errors')::text); end $$;
reset role;
select res, name, detail from (select case when ok then 'PASS' else 'FAIL' end res, name, detail from test_results) q order by name;
rollback;
