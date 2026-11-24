-- Synthetic local PG16 only, rollback. Legacy and enabled individual output consistency.
\set ON_ERROR_STOP on
begin;
do $$begin if exists(select 1 from branch_whatsapp_channels where enabled and mode='web_bridge' and bridge_key_hash is not null) then raise exception 'Enabled keyed bridge refused';end if;end $$;
create temp table ac(name text,ok boolean);
grant all on ac to authenticated,anon;
create function pg_temp.ck(n text,b boolean) returns void language sql as $$insert into ac values(n,coalesce(b,false))$$;
do $$declare a record;t record;sid uuid;eid uuid:=gen_random_uuid();aid uuid;rpc jsonb;b jsonb;v text;err text;st text;mode text;n int;begin
 select * into t from iso.target where key='hotel-a|branch-1';
 insert into audit_events(organization_id,branch_id,action,entity_type,entity_id,details,category) values(t.org,t.branch_id,'iso.audit_column_marker','isolation_probe',eid,'{"hidden_marker":"bounded-details"}','business') returning id into aid;
 for mode in select unnest(array['legacy','individual']) loop
 for a in select * from iso.actor where hotel='hotel-a' and role in('owner','manager','supervisor') and (branch='branch-1' or role='owner') order by key loop
 select id into sid from staff_profiles where auth_user_id=a.auth_user;
 delete from staff_page_access where staff_id=sid;
 if mode='individual' then insert into staff_page_access(staff_id,organization_id,enabled,page_grants,sensitive_grants) values(sid,t.org,true,'{"/admin/audit-logs":{"view":true},"/staff/reservations":{"view":true}}','[]');end if;
 perform iso.set_claims(a.auth_user);b:=iso.snap();set local role authenticated;
 rpc:=fn_audit_list(jsonb_build_object('action','iso.audit_column_marker'));
 perform pg_temp.ck(mode||'/'||a.key||'/RPC exact row and full-or-limited details',(select count(*)=1 and bool_and(r->>'id'=aid::text and case when a.role='supervisor' then r->'details'='null'::jsonb else r->'details'->>'hidden_marker'='bounded-details' end) from jsonb_array_elements(rpc->'rows') r));
 select count(*) into n from (select action,created_at,actor_id from audit_events where entity_id=eid order by created_at desc limit 50) x;
 perform pg_temp.ck(mode||'/'||a.key||'/direct timeline remains readable',n=1);
 err:=null;st:=null;begin execute 'select details::text from audit_events where entity_id=$1' into v using eid;exception when others then err:=sqlerrm;st:=sqlstate;end;
 perform pg_temp.ck(mode||'/'||a.key||'/direct details column permission denied',st='42501' and err like 'permission denied%');
 err:=null;st:=null;begin execute 'select row_to_json(e)::text from audit_events e where entity_id=$1' into v using eid;exception when others then err:=sqlerrm;st:=sqlstate;end;
 perform pg_temp.ck(mode||'/'||a.key||'/whole-row details bypass denied',st='42501' and err like 'permission denied%');
 perform pg_temp.ck(mode||'/'||a.key||'/no-write',iso.snap()=b);
 reset role;
 end loop;
 end loop;
 perform iso.set_claims((select auth_user from iso.actor where key='supervisor|hotel-b|branch-1'));b:=iso.snap();set local role authenticated;
 select count(*) into n from audit_events where entity_id=eid;
 perform pg_temp.ck('foreignhotel/directtimeline empty',n=0);reset role;
 perform iso.set_claims(null);set local role anon;err:=null;st:=null;begin execute 'select action from audit_events limit 1' into v;exception when others then err:=sqlerrm;st:=sqlstate;end;
 perform pg_temp.ck('anon/no direct audit column grant',st='42501');reset role;
 perform pg_temp.ck('noauthenticatedtableSELECT',not has_table_privilege('authenticated','public.audit_events','select'));
 perform pg_temp.ck('nosensitivecolumngrant',not has_column_privilege('authenticated','public.audit_events','details','select'));
end $$;
select count(*) assertions,count(*) filter(where not ok) failures from ac;
select * from ac where not ok;
do $$begin if exists(select 1 from ac where not ok) then raise exception 'Audit direct column proof failed';end if;end $$;
rollback;
