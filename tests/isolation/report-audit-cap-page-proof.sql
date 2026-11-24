-- Qualify transitive page gates in fn_require_cap/fn_can. No redundant wrappers or migration.
\set ON_ERROR_STOP on
begin;
create temp table cp(name text,ok boolean not null);
do $$declare a record;t record;sid uuid;page text;op text;has_view boolean;b jsonb;r jsonb;e text;st text;begin
 select * into a from iso.actor where key='supervisor|hotel-a|branch-1';select * into t from iso.target where key='hotel-a|branch-1';select id into sid from staff_profiles where auth_user_id=a.auth_user;
 for op,page in select * from(values('audit','/admin/audit-logs'),('discount','/admin/reports'))v(op,page) loop
 foreach has_view in array array[false,true] loop
 delete from staff_page_access where staff_id=sid;
 insert into staff_page_access(staff_id,organization_id,enabled,page_grants,sensitive_grants) values(sid,t.org,true,jsonb_build_object(page,jsonb_build_object('view',has_view)),'[]');
 perform iso.set_claims(a.auth_user);b:=iso.snap();e:=null;st:=null;set local role authenticated;
 begin
 if op='audit' then r:=fn_audit_list(jsonb_build_object('branch_id',t.branch_id));
 elsif op='discount' then r:=fn_reports_discounts(t.branch_id,current_date-1,current_date,'{}');
 else r:=fn_reports_finance(t.branch_id,current_date-1,current_date,'{}');end if;
 exception when others then e:=sqlerrm;st:=sqlstate;end;reset role;
 insert into cp values(op||'/view='||has_view,coalesce(case when has_view then e is null and r is not null else st='42501' and e like 'FORBIDDEN%' end,false) and iso.snap()=b);
 end loop;end loop;
end $$;
select * from cp;
do $$begin if (select count(*) from cp)<>4 or exists(select 1 from cp where not ok) then raise exception 'Transitive report page contract failed';end if;end $$;
rollback;
