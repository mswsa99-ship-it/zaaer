-- DIAGNOSTIC ONLY. Asserts current inconsistency, not a passing security contract.
-- Disposable local PG16, base fixtures+engine, migrations0121. No Auth or policy changes. Rolls back.
\set ON_ERROR_STOP on
begin;
do $$begin if exists(select 1 from branch_whatsapp_channels where enabled and mode='web_bridge' and bridge_key_hash is not null) then raise exception 'Enabled keyed bridge refused';end if;end $$;
create temp table audit_diag(mode text, can_read boolean, full_read boolean, table_grant boolean,column_grant boolean,rpc_masked boolean,direct_marker boolean,no_write boolean);
grant all on audit_diag to authenticated;
do $$declare a record;t record;sid uuid;aid uuid;rpc jsonb;direct jsonb;before_snap jsonb;mode text;begin
 select * into a from iso.actor where key='supervisor|hotel-a|branch-1';
 select * into t from iso.target where key='hotel-a|branch-1';
 select id into sid from staff_profiles where auth_user_id=a.auth_user;
 if a.auth_user is null or sid is null then raise exception 'Missing synthetic actor';end if;
 insert into audit_events(organization_id,branch_id,action,entity_type,entity_id,details,category,actor_id) values(t.org,t.branch_id,'iso.audit_limited_marker','isolation_probe',gen_random_uuid(),'{"limited_hidden_marker":"bounded-local-only"}','business',sid) returning id into aid;
 for mode in select unnest(array['legacy','individual-audit-and-reservation','individual-audit-only']) loop
 delete from staff_page_access where staff_id=sid;
 if mode<>'legacy' then
 insert into staff_page_access(staff_id,organization_id,enabled,page_grants,sensitive_grants) values(sid,t.org,true,
 case when mode='individual-audit-only' then '{"/admin/audit-logs":{"view":true}}'::jsonb else '{"/admin/audit-logs":{"view":true},"/staff/reservations":{"view":true}}'::jsonb end,'[]');
 end if;
 perform iso.set_claims(a.auth_user);before_snap:=iso.snap();set local role authenticated;
 rpc:=fn_audit_list(jsonb_build_object('action','iso.audit_limited_marker'));
 select details into direct from audit_events where id=aid;
 insert into audit_diag values(mode,fn_can('audit.log'),fn_cap_full('audit.log'),has_table_privilege('authenticated','public.audit_events','select'),has_column_privilege('authenticated','public.audit_events','details','select'),
 exists(select 1 from jsonb_array_elements(rpc->'rows') r where r->>'id'=aid::text and r->'details'='null'::jsonb),direct->>'limited_hidden_marker'='bounded-local-only',iso.snap()=before_snap);
 reset role;
 end loop;
end $$;
select * from audit_diag order by mode;
do $$begin
 if (select count(*) from audit_diag)<>3 or exists(select 1 from audit_diag where not can_read or full_read or not table_grant or not column_grant or not rpc_masked or not no_write) then raise exception 'Diagnostic prerequisites inconsistent';end if;
 if (select count(*) from audit_diag where direct_marker is true)<>2 then raise exception 'Expected legacy and both-page direct leak';end if;
 if not exists(select 1 from audit_diag where mode='individual-audit-only' and direct_marker is null) then raise exception 'Expected reservations-page RLS denial';end if;
end $$;
rollback;
