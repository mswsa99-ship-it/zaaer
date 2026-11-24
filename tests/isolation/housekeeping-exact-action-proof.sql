-- Exact add/edit discrimination with valid inert task fixtures. Local synthetic only, rollback.
\set ON_ERROR_STOP on
begin;
create temp table ha(name text,ok boolean);
grant all on ha to authenticated;
do $$declare a record;t record;sid uuid;rm uuid;tt uuid;tid uuid;newid uuid;op text;g text;r jsonb;b jsonb;err text;st text;can_allow boolean;before_task jsonb; effect_ok boolean;clean_ok boolean;begin
 if exists(select 1 from branch_whatsapp_channels where enabled and bridge_key_hash is not null) then raise exception 'Bridge refused';end if;
 select * into a from iso.actor where key='supervisor|hotel-a|branch-1';select * into t from iso.target where key='hotel-a|branch-1';select id into sid from staff_profiles where auth_user_id=a.auth_user;
 select id into rm from rooms where branch_id=t.branch_id and archived_at is null order by id limit 1;
 select id into tt from task_types where branch_id=t.branch_id and archived_at is null order by id limit 1;
 if rm is null or tt is null then raise exception 'Missing fixture';end if;
 for g in select unnest(array['add','edit','both','view','none']) loop
 delete from staff_page_access where staff_id=sid;
 insert into staff_page_access(staff_id,organization_id,enabled,page_grants,sensitive_grants) values(sid,t.org,true,jsonb_build_object('/staff/housekeeping',jsonb_build_object('view',g<>'none','add',g in('add','both'),'edit',g in('edit','both'))),'[]');
 for op in select unnest(array['create','start','complete']) loop
 begin
 insert into housekeeping_tasks(organization_id,branch_id,room_id,task_type_id,task_type_name_snapshot,description,created_by,assignee_id) values(t.org,t.branch_id,rm,tt,'Synthetic task','ha exact',sid,sid) returning id into tid;
 perform iso.set_claims(a.auth_user);b:=iso.snap();err:=null;st:=null;set local role authenticated;
 begin
 if op='create' then r:=fn_hk_create_task(jsonb_build_object('room_id',rm,'task_type_id',tt,'description','ha-created','assignee_id',sid));
 elsif op='start' then r:=fn_hk_start_task(tid);
 else r:=fn_hk_complete_task(tid,'ha-complete',1);end if;
 exception when others then err:=sqlerrm;st:=sqlstate;end;
 reset role;clean_ok:=iso.snap()=b;effect_ok:=false;can_allow:=case when op='create' then g in('add','both') else g in('edit','both') end;
 if can_allow then
 insert into ha values(g||'/'||op||'/success',err is null and r->>'ok'='true');
 if op='create' then select exists(select 1 from housekeeping_tasks where description='ha-created' and created_by=sid and organization_id=t.org and branch_id=t.branch_id) into effect_ok;
 elsif op='start' then select exists(select 1 from housekeeping_tasks where id=tid and status='in_progress' and assignee_id=sid and version=2) into effect_ok;
 else select exists(select 1 from housekeeping_tasks where id=tid and status='completed' and completed_by=sid and result_note='ha-complete' and version=2) into effect_ok;end if;
 else insert into ha values(g||'/'||op||'/42501-no-write',st='42501' and err like 'FORBIDDEN%' and iso.snap()=b);end if;
 raise exception 'HA_ROLLBACK';
 exception when others then reset role;if sqlerrm<>'HA_ROLLBACK' then raise;end if;end;
 -- Results inside subtransaction rollback too; retain an outer assertion of last execution.
 insert into ha values(g||'/'||op||'/permission-result',coalesce(case when can_allow then err is null and effect_ok else st='42501' and err like 'FORBIDDEN%' and clean_ok end,false));
 end loop;end loop;
end $$;
select * from ha;
do $$begin if (select count(*) from ha)<>15 or exists(select 1 from ha where ok is not true) then raise exception 'Exact housekeeping action failed';end if;end $$;
rollback;
