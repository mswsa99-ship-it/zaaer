-- Local-archive-draft2 qualification: fn_admin_archive_definition (0033) and fn_owner_save_permission_draft (0108).
-- Disposable database only. Synthetic rows only (ids fa0...). Runs in one transaction and rolls back.
begin;
create temp table test_results(name text primary key, ok boolean not null, detail text);
grant all on test_results to public;
insert into organizations(id,name_ar) values ('fa000000-0000-4000-8000-00000000000a','RA org A'),('fa000000-0000-4000-8000-00000000000b','RA org B');
insert into branches(id,organization_id,name_ar) values
 ('fa100000-0000-4000-8000-000000000001','fa000000-0000-4000-8000-00000000000a','RA branch A1'),
 ('fa100000-0000-4000-8000-000000000002','fa000000-0000-4000-8000-00000000000a','RA branch A2'),
 ('fa100000-0000-4000-8000-000000000003','fa000000-0000-4000-8000-00000000000b','RA branch B1');
insert into staff_profiles(id,auth_user_id,organization_id,full_name,email,role) values
 ('fa200000-0000-4000-8000-000000000001','fa300000-0000-4000-8000-000000000001','fa000000-0000-4000-8000-00000000000a','RA owner A','ra-owner-a@example.test','owner'),
 ('fa200000-0000-4000-8000-000000000002','fa300000-0000-4000-8000-000000000002','fa000000-0000-4000-8000-00000000000a','RA manager A1','ra-mgr-a1@example.test','manager'),
 ('fa200000-0000-4000-8000-000000000003','fa300000-0000-4000-8000-000000000003','fa000000-0000-4000-8000-00000000000a','RA finance A','ra-fin-a@example.test','finance'),
 ('fa200000-0000-4000-8000-000000000004','fa300000-0000-4000-8000-000000000004','fa000000-0000-4000-8000-00000000000b','RA owner B','ra-owner-b@example.test','owner'),
 ('fa200000-0000-4000-8000-000000000005','fa300000-0000-4000-8000-000000000005','fa000000-0000-4000-8000-00000000000a','RA inactive','ra-off@example.test','finance'),
 ('fa200000-0000-4000-8000-000000000006','fa300000-0000-4000-8000-000000000006','fa000000-0000-4000-8000-00000000000a','RA supervisor A1','ra-sup@example.test','supervisor');
update staff_profiles set is_active=false where id='fa200000-0000-4000-8000-000000000005';
insert into branch_memberships(staff_id,branch_id) values
 ('fa200000-0000-4000-8000-000000000002','fa100000-0000-4000-8000-000000000001'),
 ('fa200000-0000-4000-8000-000000000006','fa100000-0000-4000-8000-000000000001'),
 ('fa200000-0000-4000-8000-000000000004','fa100000-0000-4000-8000-000000000003')
 on conflict do nothing;
insert into service_definitions(id,organization_id,branch_id,name_ar) values
 ('fa400000-0000-4000-8000-000000000001','fa000000-0000-4000-8000-00000000000a','fa100000-0000-4000-8000-000000000001','RA service target'),
 ('fa400000-0000-4000-8000-000000000002','fa000000-0000-4000-8000-00000000000a','fa100000-0000-4000-8000-000000000001','RA service decoy same branch'),
 ('fa400000-0000-4000-8000-000000000003','fa000000-0000-4000-8000-00000000000a','fa100000-0000-4000-8000-000000000002','RA service foreign branch same org');
insert into task_types(id,organization_id,branch_id,name) values
 ('fa500000-0000-4000-8000-000000000001','fa000000-0000-4000-8000-00000000000a','fa100000-0000-4000-8000-000000000001','RA task type target'),
 ('fa500000-0000-4000-8000-000000000002','fa000000-0000-4000-8000-00000000000a','fa100000-0000-4000-8000-000000000001','RA task type decoy');

create function pg_temp.rec(n text, ok boolean, d text default null) returns void language sql security definer as $$ insert into test_results values(n, coalesce(ok,false), d) $$;
create function pg_temp.login(uid text) returns void language sql as $$ select set_config('request.jwt.claim.sub',uid,false)::text::void $$;
-- expects the statement to fail with a message beginning like p_like; records ok only on that failure
create function pg_temp.fails(n text, stmt text, p_like text) returns void language plpgsql as $$
declare m text; st text; begin
  begin execute stmt; perform pg_temp.rec(n,false,'did not fail');
  exception when others then get stacked diagnostics m = message_text, st = returned_sqlstate; perform pg_temp.rec(n, m like p_like and st=case when p_like like 'FORBIDDEN%' or p_like like '%permission denied%' then '42501' else 'P0001' end, st||':'||m); end;
end $$;
create function pg_temp.fp(table_name text, id uuid) returns text language plpgsql security definer as $$ declare r text; begin execute format('select to_jsonb(t)::text from %I t where id=$1',table_name) into r using id; return r; end $$;
create function pg_temp.cnt(q text) returns bigint language plpgsql security definer as $$ declare n bigint; begin execute q into n; return n; end $$;
-- outbound preconditions (B-style guard): no enabled bridge key, nothing queued
select pg_temp.rec('pre: no web_bridge channel with a bridge key', pg_temp.cnt('select count(*) from branch_whatsapp_channels where bridge_key_hash is not null')=0);
select pg_temp.rec('pre: outbox, journey_messages empty', pg_temp.cnt('select count(*) from whatsapp_outbox')=0 and pg_temp.cnt('select count(*) from journey_messages')=0);

grant execute on function pg_temp.rec(text,boolean,text), pg_temp.login(text), pg_temp.fails(text,text,text), pg_temp.fp(text,uuid), pg_temp.cnt(text) to public;
create temp table snap(k text primary key, v text);
grant all on snap to public;
insert into snap select 'svc_decoy1', pg_temp.fp('service_definitions','fa400000-0000-4000-8000-000000000002');
insert into snap select 'svc_foreign', pg_temp.fp('service_definitions','fa400000-0000-4000-8000-000000000003');
insert into snap select 'svc_target0', pg_temp.fp('service_definitions','fa400000-0000-4000-8000-000000000001');
insert into snap select 'tt_decoy', pg_temp.fp('task_types','fa500000-0000-4000-8000-000000000002');
insert into snap select 'audit0', pg_temp.cnt('select count(*) from audit_events')::text;

set role authenticated;
-- ===== ARCHIVE: positive =====
select pg_temp.login('fa300000-0000-4000-8000-000000000002');
do $$ declare r jsonb; v0 int; row_ service_definitions%rowtype; begin
  select version into v0 from service_definitions where id='fa400000-0000-4000-8000-000000000001';
  r := fn_admin_archive_definition('service','fa400000-0000-4000-8000-000000000001','RA archive reason');
  select * into row_ from service_definitions where id='fa400000-0000-4000-8000-000000000001';
  perform pg_temp.rec('A1 archive sets archived_at, is_active false, reason, actor, version+1',
    row_.archived_at is not null and row_.is_active=false and row_.archive_reason='RA archive reason'
    and row_.archived_by='fa200000-0000-4000-8000-000000000002' and row_.version=v0+1, r::text);
end $$;
select pg_temp.rec('A1 decoys unchanged (same-branch service, foreign-branch service, task type)',
  pg_temp.fp('service_definitions','fa400000-0000-4000-8000-000000000002')=(select v from snap where k='svc_decoy1')
  and pg_temp.fp('service_definitions','fa400000-0000-4000-8000-000000000003')=(select v from snap where k='svc_foreign')
  and pg_temp.fp('task_types','fa500000-0000-4000-8000-000000000002')=(select v from snap where k='tt_decoy'));
select pg_temp.rec('A1 exactly one audit row service.archived for the target',
  pg_temp.cnt($q$select count(*) from audit_events where action='service.archived' and entity_id='fa400000-0000-4000-8000-000000000001'$q$)=1
  and pg_temp.cnt('select count(*) from audit_events')=(select v::bigint+1 from snap where k='audit0'));
-- ===== RESTORE =====
do $$ declare row_ service_definitions%rowtype; v0 int; begin
  select version into v0 from service_definitions where id='fa400000-0000-4000-8000-000000000001';
  perform fn_admin_archive_definition('service','fa400000-0000-4000-8000-000000000001',null,false);
  select * into row_ from service_definitions where id='fa400000-0000-4000-8000-000000000001';
  perform pg_temp.rec('A2 restore clears archive columns, is_active true, version+1',
    row_.archived_at is null and row_.archived_by is null and row_.archive_reason is null and row_.is_active and row_.version=v0+1);
end $$;
select pg_temp.rec('A2 exactly one audit row service.restored',
  pg_temp.cnt($q$select count(*) from audit_events where action='service.restored' and entity_id='fa400000-0000-4000-8000-000000000001'$q$)=1);
-- task_type
do $$ begin
  perform fn_admin_archive_definition('task_type','fa500000-0000-4000-8000-000000000001','RA tt');
  perform pg_temp.rec('A3 task_type archived, decoy task type unchanged',
    (select archived_at is not null and is_active=false from task_types where id='fa500000-0000-4000-8000-000000000001')
    and pg_temp.fp('task_types','fa500000-0000-4000-8000-000000000002')=(select v from snap where k='tt_decoy'));
end $$;
-- ===== ARCHIVE: negatives, each leaves rows and audit count unchanged =====
insert into snap select 'audit1', pg_temp.cnt('select count(*) from audit_events')::text;
insert into snap select 'svc_target1', pg_temp.fp('service_definitions','fa400000-0000-4000-8000-000000000001');
select pg_temp.fails('A4 entity outside the eight tokens',$q$select fn_admin_archive_definition('staff_profiles','fa400000-0000-4000-8000-000000000001','x')$q$,'VALIDATION: entity%');
select pg_temp.fails('A4b a real table name is not a token',$q$select fn_admin_archive_definition('service_definitions','fa400000-0000-4000-8000-000000000001','x')$q$,'VALIDATION: entity%');
select pg_temp.fails('A4c quoted-identifier injection string refused',$q$select fn_admin_archive_definition('rooms; drop table rooms; --','fa400000-0000-4000-8000-000000000001','x')$q$,'VALIDATION: entity%');
select pg_temp.fails('A5 archive without reason',$q$select fn_admin_archive_definition('service','fa400000-0000-4000-8000-000000000001','  ')$q$,'VALIDATION: reason%');
select pg_temp.fails('A6 unknown id',$q$select fn_admin_archive_definition('service','fa400000-0000-4000-8000-0000000000ff','x')$q$,'NOT_FOUND%');
select pg_temp.fails('A7 foreign branch, same org, same credential (manager A1 on branch A2 row)',$q$select fn_admin_archive_definition('service','fa400000-0000-4000-8000-000000000003','x')$q$,'FORBIDDEN%');
select pg_temp.rec('A7 foreign-branch row unchanged', pg_temp.fp('service_definitions','fa400000-0000-4000-8000-000000000003')=(select v from snap where k='svc_foreign'));
select pg_temp.fails('A8 branch archive needs owner (manager refused)',$q$select fn_admin_archive_definition('branch','fa100000-0000-4000-8000-000000000001','x')$q$,'FORBIDDEN%');
select pg_temp.login('fa300000-0000-4000-8000-000000000003');
select pg_temp.fails('A9 finance role refused',$q$select fn_admin_archive_definition('service','fa400000-0000-4000-8000-000000000001','x')$q$,'FORBIDDEN%');
select pg_temp.login('fa300000-0000-4000-8000-000000000006');
select pg_temp.fails('A9b supervisor role refused',$q$select fn_admin_archive_definition('service','fa400000-0000-4000-8000-000000000001','x')$q$,'FORBIDDEN%');
select pg_temp.login('fa300000-0000-4000-8000-000000000004');
select pg_temp.fails('A10 other org owner refused on org A row',$q$select fn_admin_archive_definition('service','fa400000-0000-4000-8000-000000000001','x')$q$,'FORBIDDEN%');
select pg_temp.login('fa300000-0000-4000-8000-0000000000ee');
select pg_temp.fails('A11 authenticated user without staff profile refused',$q$select fn_admin_archive_definition('service','fa400000-0000-4000-8000-000000000001','x')$q$,'FORBIDDEN%');
reset role;
select pg_temp.rec('A4-A11 no write: target row and audit count unchanged',
  pg_temp.fp('service_definitions','fa400000-0000-4000-8000-000000000001')=(select v from snap where k='svc_target1')
  and pg_temp.cnt('select count(*) from audit_events')=(select v::bigint from snap where k='audit1'));
set role anon;
select pg_temp.fails('A12 anon cannot execute',$q$select fn_admin_archive_definition('service','fa400000-0000-4000-8000-000000000001','x')$q$,'%permission denied%');
reset role;

-- ===== PERMISSION DRAFT =====
insert into snap select 'draft_count0', pg_temp.cnt('select count(*) from staff_permission_drafts')::text;
insert into snap select 'access_count0', pg_temp.cnt('select count(*) from staff_page_access')::text;
set role authenticated;
select pg_temp.login('fa300000-0000-4000-8000-000000000003');
insert into snap select 'perms_target_before', fn_my_permissions()::text;
insert into snap select 'mode_before', fn_user_access_mode();
select pg_temp.login('fa300000-0000-4000-8000-000000000001');
do $$ declare r jsonb; d staff_permission_drafts%rowtype; begin
  r := fn_owner_save_permission_draft('{"staff_id":"fa200000-0000-4000-8000-000000000003","pages":{"/staff/reservations":{"view":true,"export":true}},"sensitive":[],"home_page":"/staff/reservations","expected_revision":0,"reason":"RA draft one"}');
  select * into d from staff_permission_drafts where staff_id='fa200000-0000-4000-8000-000000000003';
  perform pg_temp.rec('D1 owner saves draft: ok, active=false, revision 1, exact JSON, updated_by owner',
    r->>'ok'='true' and r->>'active'='false' and (r->>'revision')='1' and d.revision=1
    and d.page_grants='{"/staff/reservations":{"view":true,"export":true}}'::jsonb and d.sensitive_grants='[]'::jsonb
    and d.home_page='/staff/reservations' and d.updated_by='fa200000-0000-4000-8000-000000000001', r::text);
  r := fn_owner_save_permission_draft('{"staff_id":"fa200000-0000-4000-8000-000000000003","pages":{"/staff/reservations":{"view":true}},"sensitive":[],"expected_revision":1,"reason":"RA draft two"}');
  select * into d from staff_permission_drafts where staff_id='fa200000-0000-4000-8000-000000000003';
  perform pg_temp.rec('D2 second save with expected_revision 1 makes revision 2 and replaces the grants',
    (r->>'revision')='2' and d.revision=2 and d.page_grants='{"/staff/reservations":{"view":true}}'::jsonb and d.home_page is null, r::text);
end $$;
reset role;
select pg_temp.rec('D3 two audit rows permissions.individual_draft_saved, active false, reason carried',
  pg_temp.cnt($q$select count(*) from audit_events where action='permissions.individual_draft_saved' and entity_id='fa200000-0000-4000-8000-000000000003'$q$)=2, null);
select pg_temp.rec('D3b audit after-image of the last save holds revision 2 and its reason',
  (select count(*) from audit_events where action='permissions.individual_draft_saved' and entity_id='fa200000-0000-4000-8000-000000000003' and details::text like '%RA draft two%')>=1);
insert into snap select 'draft_after_pos', (select to_jsonb(d)::text from staff_permission_drafts d where staff_id='fa200000-0000-4000-8000-000000000003');
insert into snap select 'audit_after_pos', pg_temp.cnt('select count(*) from audit_events')::text;
set role authenticated;
select pg_temp.login('fa300000-0000-4000-8000-000000000001');
select pg_temp.fails('D4 stale revision',$q$select fn_owner_save_permission_draft('{"staff_id":"fa200000-0000-4000-8000-000000000003","pages":{},"sensitive":[],"expected_revision":1,"reason":"x"}')$q$,'CONFLICT%');
select pg_temp.fails('D5 target is an owner',$q$select fn_owner_save_permission_draft('{"staff_id":"fa200000-0000-4000-8000-000000000001","pages":{},"sensitive":[],"reason":"x"}')$q$,'FORBIDDEN%');
select pg_temp.fails('D6 foreign org target',$q$select fn_owner_save_permission_draft('{"staff_id":"fa200000-0000-4000-8000-000000000004","pages":{},"sensitive":[],"reason":"x"}')$q$,'NOT_FOUND%');
select pg_temp.fails('D7 inactive target',$q$select fn_owner_save_permission_draft('{"staff_id":"fa200000-0000-4000-8000-000000000005","pages":{},"sensitive":[],"reason":"x"}')$q$,'FORBIDDEN%');
select pg_temp.fails('D8 reason required',$q$select fn_owner_save_permission_draft('{"staff_id":"fa200000-0000-4000-8000-000000000003","pages":{},"sensitive":[],"expected_revision":2}')$q$,'VALIDATION: reason%');
select pg_temp.fails('D9 unknown page',$q$select fn_owner_save_permission_draft('{"staff_id":"fa200000-0000-4000-8000-000000000003","pages":{"/admin/not-real":{"view":true}},"sensitive":[],"expected_revision":2,"reason":"x"}')$q$,'VALIDATION: page%');
select pg_temp.fails('D10 add without view',$q$select fn_owner_save_permission_draft('{"staff_id":"fa200000-0000-4000-8000-000000000003","pages":{"/staff/reservations":{"view":false,"add":true}},"sensitive":[],"expected_revision":2,"reason":"x"}')$q$,'VALIDATION%');
select pg_temp.fails('D11 locked owner capability',$q$select fn_owner_save_permission_draft('{"staff_id":"fa200000-0000-4000-8000-000000000003","pages":{},"sensitive":["admin.permissions"],"expected_revision":2,"reason":"x"}')$q$,'VALIDATION%');
select pg_temp.login('fa300000-0000-4000-8000-000000000002');
select pg_temp.fails('D12 manager (non owner) refused',$q$select fn_owner_save_permission_draft('{"staff_id":"fa200000-0000-4000-8000-000000000003","pages":{},"sensitive":[],"expected_revision":2,"reason":"x"}')$q$,'FORBIDDEN%');
select pg_temp.login('fa300000-0000-4000-8000-000000000003');
select pg_temp.fails('D13 target cannot grant itself',$q$select fn_owner_save_permission_draft('{"staff_id":"fa200000-0000-4000-8000-000000000003","pages":{},"sensitive":[],"expected_revision":2,"reason":"x"}')$q$,'FORBIDDEN%');
select pg_temp.rec('D14 target effective permissions and access mode unchanged by the draft', fn_my_permissions()::text=(select v from snap where k='perms_target_before') and fn_user_access_mode()=(select v from snap where k='mode_before'));
reset role;
select pg_temp.rec('D15 negatives: draft row, audit count unchanged', (select to_jsonb(d)::text from staff_permission_drafts d where staff_id='fa200000-0000-4000-8000-000000000003')=(select v from snap where k='draft_after_pos')
  and pg_temp.cnt('select count(*) from audit_events')=(select v::bigint from snap where k='audit_after_pos'));
select pg_temp.rec('D16 only one draft row added; staff_page_access (active grants) unchanged', pg_temp.cnt('select count(*) from staff_permission_drafts')=(select v::bigint+1 from snap where k='draft_count0') and pg_temp.cnt('select count(*) from staff_page_access')=(select v::bigint from snap where k='access_count0'));
select pg_temp.rec('Z no outbound: outbox, journey_messages, channel keys all still zero', pg_temp.cnt('select count(*) from whatsapp_outbox')=0 and pg_temp.cnt('select count(*) from journey_messages')=0 and pg_temp.cnt('select count(*) from branch_whatsapp_channels where bridge_key_hash is not null')=0);
select name, ok, left(coalesce(detail,''),90) detail from test_results order by name;
select case when exists(select 1 from test_results where not ok) then 'FAILED' else 'ALL PASS ('||(select count(*) from test_results)||')' end as result;
do $$begin if exists(select 1 from test_results where not ok) then raise exception 'Archive/draft assertions failed';end if;end $$;
rollback;
