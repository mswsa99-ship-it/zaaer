\set ON_ERROR_STOP on
begin;
select fn_audit(c.org,c.branch,null,'task.assigned','housekeeping_task',c.id::uuid,jsonb_build_object('after',jsonb_build_object('assignee_id',null),'reason','unrelatedassign')) from iso.created c where c.tbl='housekeeping_tasks' and c.purpose='victim';
create temp table hk_before as select id,md5(to_jsonb(a)::text) h from audit_events a;
do $$declare t record;a record;b jsonb;sig text:='fn_hk_assign_task(p_task uuid, p_assignee uuid)';begin
 for t in select * from iso.target order by key loop
  select * into a from iso.actor where role='owner' and hotel=t.hotel;
  perform iso.set_claims(a.auth_user);set local role authenticated;b:=iso.snap();perform iso.rpc_probe('hka-control|'||t.key,sig,'control',t.key,true,b);reset role;
 end loop;
end $$;
do $$declare t record;a record;tid uuid;foreign_sid uuid;b jsonb;e text;begin
 for t in select * from iso.target order by key loop
  select * into a from iso.actor where role='owner' and hotel=t.hotel;
  select c.id::uuid into tid from iso.created c where c.tbl='housekeeping_tasks' and c.purpose='victim' and c.branch=t.branch_id;
  select p.id into foreign_sid from staff_profiles p join iso.actor aa on aa.auth_user=p.auth_user_id where aa.role='housekeeping' and aa.hotel<>t.hotel limit 1;
  perform iso.set_claims(a.auth_user);b:=iso.snap();e:=null;set local role authenticated;
  begin perform fn_hk_assign_task(tid,foreign_sid);exception when others then e:=sqlerrm;end;
  reset role;if e<>'ASSIGNEE_NOT_IN_BRANCH' or iso.snap()<>b then raise exception 'HK foreignassignee contract';end if;
  begin
  b:=iso.snap();set local role authenticated;perform fn_hk_assign_task(tid,null);reset role;
  if not exists(select 1 from housekeeping_tasks where id=tid and assignee_id is null and version=2) then raise exception 'HK nullassignee failed';end if;
  raise exception 'HK_NULL_ROLLBACK';
  exception when others then reset role;if sqlerrm<>'HK_NULL_ROLLBACK' then raise;end if;end;
 end loop;
end $$;
select probe_id,outcome,detail from iso.probe_result where probe_id like 'hka-%';
do $$begin
if (select count(*) from iso.probe_result where probe_id like 'hka-%' and outcome='success' and detail like '%effect=asserted-ok%' and detail like '%nontarget=proved-rowlevel%')<>4 then raise exception 'HKexact4';end if;
if exists(select 1 from hk_before b full join audit_events a using(id) where b.h is distinct from md5(to_jsonb(a)::text)) then raise exception 'HKpreviousaudit changed';end if;
end $$;
rollback;
