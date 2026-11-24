-- Local synthetic enabled individual rows only. No real account activation, map changes or role policy edits.
\set ON_ERROR_STOP on
begin;
create temp table ih(name text,ok boolean);
create temp table ih_codes as select pc.code,pc.locked,m.any_write from fn_permission_catalog() pc left join permission_page_map m using(code);
create temp table ih_legacy as select a.key,c.code,false allowed,false full_allowed from iso.actor a cross join fn_permission_catalog() c where a.role<>'guest';
grant all on ih,ih_legacy,ih_codes to authenticated;
do $$declare a record;c record;begin
 for a in select * from iso.actor where role<>'guest' loop
 perform iso.set_claims(a.auth_user);set local role authenticated;
 for c in select * from fn_permission_catalog() loop update ih_legacy set allowed=fn_can(c.code),full_allowed=fn_cap_full(c.code) where key=a.key and code=c.code;end loop;
 reset role;end loop;
end $$;
-- Independent selected grant model: mapped, known nonlocked code; all page actions explicitly granted, all sensitive names selected.
do $$declare a record;c record;sid uuid;org uuid;pages jsonb;caps jsonb;expect boolean;begin
 select jsonb_object_agg(page,'{"view":true,"add":true,"edit":true,"delete":true,"export":true}'::jsonb) into pages from (select distinct page from permission_page_map) p;
 select jsonb_agg(code) into caps from permission_page_map where sensitive;
 for a in select * from iso.actor where role not in('guest','owner') loop
 select id,organization_id into sid,org from staff_profiles where auth_user_id=a.auth_user;
 insert into staff_page_access(staff_id,organization_id,enabled,page_grants,sensitive_grants) values(sid,org,true,pages,coalesce(caps,'[]')) on conflict(staff_id) do update set enabled=true,page_grants=excluded.page_grants,sensitive_grants=excluded.sensitive_grants;
 perform iso.set_claims(a.auth_user);set local role authenticated;
 for c in select * from ih_codes loop
 expect:=not c.locked and c.any_write is not null;
 insert into ih values(a.key||'/'||c.code||'/all-selected',fn_can(c.code) is not distinct from expect);
 insert into ih values(a.key||'/'||c.code||'/exact-add',fn_can_write(c.code,'add') is not distinct from (expect and coalesce(c.any_write,false)));
 end loop;
 insert into ih values(a.key||'/unknown',not fn_can('nonexistent.code'));
 insert into ih values(a.key||'/invalid-action',not fn_can_write('reports.finance','view'));
 reset role;
 update staff_page_access set page_grants='{}',sensitive_grants='[]' where staff_id=sid;
 set local role authenticated;
 insert into ih select a.key||'/no-grant/'||code,not fn_can(code) from ih_codes where any_write is not null;
 reset role;
 delete from staff_page_access where staff_id=sid;
 end loop;
end $$;
-- Independent missing view/action/sensitive contrasts and exact any-write separation.
do $$declare a record;sid uuid;org uuid;g jsonb;begin
 for a in select * from iso.actor where role not in('guest','owner') loop
 select id,organization_id into sid,org from staff_profiles where auth_user_id=a.auth_user;
 insert into staff_page_access(staff_id,organization_id,enabled,page_grants,sensitive_grants) values(sid,org,true,'{"/admin/knowledge":{"view":true,"add":true,"edit":false}}','[]') on conflict(staff_id) do update set enabled=true,page_grants=excluded.page_grants,sensitive_grants=excluded.sensitive_grants;
 perform iso.set_claims(a.auth_user);set local role authenticated;
 insert into ih values(a.key||'/add-not-edit',fn_can_write('knowledge','add') and not fn_can_write('knowledge','edit') and not fn_can_write('knowledge','delete'));
 reset role;
 update staff_page_access set page_grants='{"/admin/knowledge":{"view":false,"add":true}}' where staff_id=sid;
 set local role authenticated;insert into ih values(a.key||'/requires-view',not fn_can('knowledge') and not fn_can_write('knowledge','add'));reset role;
 update staff_page_access set page_grants='{"/staff/payments":{"view":true,"add":true,"edit":true}}',sensitive_grants='[]' where staff_id=sid;
 set local role authenticated;insert into ih values(a.key||'/requires-sensitive',not fn_can('voucher.refund'));reset role;
 delete from staff_page_access where staff_id=sid;
 end loop;
end $$;
-- The legacy answer is unchanged after local test rows are removed.
do $$declare a record;c record;begin
 for a in select * from iso.actor where role<>'guest' loop
 perform iso.set_claims(a.auth_user);set local role authenticated;
 for c in select * from ih_legacy where key=a.key loop insert into ih values(a.key||'/legacy/'||c.code,fn_can(c.code)=c.allowed and fn_cap_full(c.code)=c.full_allowed);end loop;
 reset role;end loop;
end $$;
select count(*) assertions,count(*) filter(where not ok) failures from ih;
select * from ih where not ok limit 30;
do $$begin if exists(select 1 from ih where not ok) then raise exception 'Individual template helper contract failed';end if;end $$;
rollback;
