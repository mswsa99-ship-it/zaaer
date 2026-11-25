-- 0122: audit_events direct SELECT is limited to action, created_at, actor_id, entity_id (authenticated); anon has none.
-- Run on a DB through 0125 with the seed rows. Rolls back.
\set ON_ERROR_STOP off
begin;
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create or replace function xg_login(p_uid uuid, p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email)::text, false); end $$;
create or replace function xg_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$ insert into test_results values (p_name, p_ok, p_detail); $$;
create or replace function xg_q(p_sql text) returns text language plpgsql as $$ declare n bigint; begin execute p_sql into n; return n::text; exception when others then return 'ERR:'||sqlstate; end $$;
grant execute on function xg_login(uuid,text), xg_record(text,boolean,text), xg_q(text) to public;
insert into staff_profiles(id, auth_user_id, organization_id, full_name, email, role) values
 ('1b900000-0000-0000-0000-000000000001','cb900000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','ad owner','adowner@test.local','owner'),
 ('1b900000-0000-0000-0000-000000000002','cb900000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001','ad housekeeping','adhk@test.local','housekeeping');
insert into branch_memberships(staff_id, branch_id, organization_id) values ('1b900000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000001');
select xg_record('AD00 fixtures: own-org and foreign-org audit rows exist', (select count(*) from audit_events where organization_id='00000000-0000-0000-0000-000000000001')>0 and (select count(*) from audit_events where organization_id<>'00000000-0000-0000-0000-000000000001')>0, (select count(*) from audit_events where organization_id='00000000-0000-0000-0000-000000000001')||'/'||(select count(*) from audit_events where organization_id<>'00000000-0000-0000-0000-000000000001'));
create temp table own as select count(*) c from audit_events where organization_id='00000000-0000-0000-0000-000000000001';
grant select on own to public;
set role authenticated;
select xg_login('cb900000-0000-0000-0000-000000000001','adowner@test.local');
do $$ declare col text; begin
 perform xg_record('AD01 owner: allowed columns (action, created_at, actor_id, entity_id) read own-org rows = all own rows (positive control)', xg_q('select count(action) from (select action, created_at, actor_id, entity_id from audit_events) x')=(select own.c::text from own), xg_q('select count(*) from (select action, created_at, actor_id, entity_id from audit_events) x'));
 perform xg_record('AD02 owner: 0 foreign-org rows through the allowed columns', xg_q('select count(*) from audit_events where organization_id <> fn_user_org_id()') like 'ERR:42501' or xg_q('select count(*) from (select action from audit_events) x')=(select own.c::text from own));
 perform xg_record('AD03 owner: select * is denied', xg_q('select count(*) from (select * from audit_events) x')='ERR:42501', xg_q('select count(*) from (select * from audit_events) x'));
 foreach col in array array['details','id','organization_id','branch_id','entity_type','correlation_id','source','actor_type','result','category','chain_seq','prev_hash','row_hash'] loop
  perform xg_record('AD04 owner: column '||col||' is denied', xg_q(format('select count(%I) from audit_events', col))='ERR:42501', xg_q(format('select count(%I) from audit_events', col)));
 end loop;
 perform xg_record('AD05 owner: filtering on a denied column (where details is not null) is denied', xg_q('select count(action) from audit_events where details is not null')='ERR:42501');
 perform xg_record('AD06 owner: the rich details still come through the fn_audit_list RPC', xg_q('select jsonb_array_length(coalesce(fn_audit_list(''{}''::jsonb)->''rows'', ''[]''::jsonb))') not like 'ERR:%', xg_q('select jsonb_array_length(coalesce(fn_audit_list(''{}''::jsonb)->''rows'', ''[]''::jsonb))'));
end $$;
select xg_login('cb900000-0000-0000-0000-000000000002','adhk@test.local');
do $$ begin
 perform xg_record('AD07 housekeeping (no audit.log): 0 rows through the allowed columns (row policy kept)', xg_q('select count(*) from (select action from audit_events) x')='0', xg_q('select count(*) from (select action from audit_events) x'));
 perform xg_record('AD08 housekeeping: details column denied', xg_q('select count(details) from audit_events')='ERR:42501');
end $$;
reset role;
set role anon;
do $$ begin
 perform xg_record('AD09 anon: action column denied', xg_q('select count(action) from audit_events')='ERR:42501', xg_q('select count(action) from audit_events'));
 perform xg_record('AD10 anon: select * denied', xg_q('select count(*) from (select * from audit_events) x')='ERR:42501');
end $$;
reset role;
select xg_record('AD11 catalog (has_column_privilege): authenticated has SELECT on exactly action, actor_id, created_at, entity_id; anon on none; no table-level SELECT',
  (select string_agg(attname, ',' order by attname) from pg_attribute where attrelid='public.audit_events'::regclass and attnum>0 and not attisdropped and has_column_privilege('authenticated','public.audit_events',attname,'SELECT'))='action,actor_id,created_at,entity_id'
  and not exists (select 1 from pg_attribute where attrelid='public.audit_events'::regclass and attnum>0 and not attisdropped and has_column_privilege('anon','public.audit_events',attname,'SELECT'))
  and not has_table_privilege('authenticated','public.audit_events','SELECT') and not has_table_privilege('anon','public.audit_events','SELECT'));
select res, name, detail from (select case when ok then 'PASS' else 'FAIL' end as res, name, detail from test_results) q order by res desc, name;
select count(*) filter (where ok) pass, count(*) filter (where not ok) fail from test_results;
rollback;
