-- PT: the historical 0073 purge must not remove another hotel's branchless rows.
\set ON_ERROR_STOP on
begin;
create temp table purge_scope_results(name text,ok boolean);
insert into organizations(id,name_ar) values('83000000-0000-0000-0000-000000000001','Purge own test'),('83000000-0000-0000-0000-000000000002','Purge other test');
insert into branches(id,organization_id,name_ar) values('83000000-0000-0000-0000-000000000011','83000000-0000-0000-0000-000000000001','Own'),('83000000-0000-0000-0000-000000000012','83000000-0000-0000-0000-000000000002','Other');
insert into conversations(organization_id) select id from organizations where id in ('83000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000002');
insert into guest_lookup_attempts(organization_id,external_ref,ok) select id,'PT83',false from organizations where id in ('83000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000002');
insert into guest_phone_challenges(organization_id,phone,code_hash) select id,'0508300001','test-hash' from organizations where id in ('83000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000002');
insert into guest_phone_sessions(organization_id,phone,method) select id,'0508300001','whatsapp_sender' from organizations where id in ('83000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000002');
insert into ai_tool_executions(organization_id,tool_name,result_status) select id,'PT83','ok' from organizations where id in ('83000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000002');
insert into ai_guardrail_events(organization_id,stage,rule) select id,'PT83','test' from organizations where id in ('83000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000002');
insert into whatsapp_inbound_messages(wa_message_id,organization_id) select 'PT83-'||id,id from organizations where id in ('83000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000002');
select fn_purge_run('83000000-0000-0000-0000-000000000001',null,current_date,current_date,array['conversations','logs']);
do $$ declare t text; own_n int; other_n int;begin
foreach t in array array['conversations','guest_lookup_attempts','guest_phone_challenges','guest_phone_sessions','ai_tool_executions','ai_guardrail_events','whatsapp_inbound_messages'] loop
execute format('select count(*) from public.%I where organization_id=$1',t) into own_n using '83000000-0000-0000-0000-000000000001'::uuid;
execute format('select count(*) from public.%I where organization_id=$1',t) into other_n using '83000000-0000-0000-0000-000000000002'::uuid;
insert into purge_scope_results values('PT83 '||t||' own removed, other preserved',own_n=0 and other_n=1);
end loop;end $$;
select case when ok then 'PASS' else 'FAIL' end as result,name from purge_scope_results;
do $$ begin if exists(select 1 from purge_scope_results where ok is not true) then raise exception 'PURGE TENANT ISOLATION FAILED';end if;end $$;
rollback;
