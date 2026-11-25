-- DIAGNOSTIC: existing reservation history contract, no acceptance credit.
\set ON_ERROR_STOP on
begin;
create temp table ar(mode text, audit_masked boolean, reservation_details boolean);
do $$declare a record;t record;r uuid;sid uuid;j jsonb;k jsonb;mode text;begin
 select * into a from iso.actor where key='supervisor|hotel-a|branch-1';select * into t from iso.target where key='hotel-a|branch-1';
 select id into sid from staff_profiles where auth_user_id=a.auth_user;
 select id into r from reservations where branch_id=t.branch_id order by id limit 1;
 if r is null then raise exception 'Missing reservation fixture';end if;
 insert into audit_events(organization_id,branch_id,actor_id,action,entity_type,entity_id,details) values(t.org,t.branch_id,sid,'iso.history_marker','reservation',r,'{"history_marker":"history-local-only"}');
 for mode in select unnest(array['legacy','individual']) loop
 delete from staff_page_access where staff_id=sid;
 if mode='individual' then insert into staff_page_access(staff_id,organization_id,enabled,page_grants,sensitive_grants) values(sid,t.org,true,'{"/admin/audit-logs":{"view":true},"/staff/reservations":{"view":true}}','[]');end if;
 perform iso.set_claims(a.auth_user);set local role authenticated;
 j:=fn_audit_list('{"action":"iso.history_marker"}');k:=fn_reservation_detail(r);reset role;
 insert into ar values(mode,exists(select 1 from jsonb_array_elements(j->'rows') x where x->'details'='null'::jsonb),exists(select 1 from jsonb_array_elements(k->'history') x where x->'details'->>'history_marker'='history-local-only'));
 end loop;
end $$;
select * from ar;
do $$begin if (select count(*) from ar)<>2 or exists(select 1 from ar where not audit_masked or not reservation_details) then raise exception 'History diagnostic expectation changed';end if;end $$;
rollback;
