\set ON_ERROR_STOP on
begin;
create temp table admin_sigs(n text);
insert into admin_sigs values ('fn_admin_set_source_active');
insert into admin_sigs values ('fn_admin_set_source_commission');
insert into admin_sigs values ('fn_admin_set_room_license');
insert into admin_sigs values ('fn_admin_upsert_block');
insert into admin_sigs values ('fn_admin_upsert_floor');
insert into admin_sigs values ('fn_admin_upsert_facility');
insert into admin_sigs values ('fn_admin_upsert_task_type');
insert into admin_sigs values ('fn_admin_upsert_room_category');
insert into admin_sigs values ('fn_admin_upsert_service');
insert into admin_sigs values ('fn_admin_upsert_room');

-- Preserve all existing audits byte for byte.
create temp table admin_old_audits as select id,md5(to_jsonb(a)::text) h from audit_events a;
do $$declare s record;t record;a record;b jsonb;begin
 for s in select x.signature from iso.rpc_adapter x join admin_sigs z on split_part(x.signature,'(',1)=z.n loop
  for t in select * from iso.target order by key loop
   select * into a from iso.actor where role='owner' and hotel=t.hotel;
   perform iso.set_claims(a.auth_user);set local role authenticated;b:=iso.snap();
   perform iso.rpc_probe('admin10-control|'||s.signature||'|'||t.key,s.signature,'control',t.key,true,b);reset role;
   select * into a from iso.actor where role='owner' and hotel<>t.hotel;
   perform iso.set_claims(a.auth_user);set local role authenticated;b:=iso.snap();
   perform iso.rpc_probe('admin10-foreign|'||s.signature||'|'||t.key,s.signature,a.key,t.key,false,b);reset role;
  end loop;
 end loop;
 if exists(select 1 from admin_old_audits oldrow join audit_events nowrow using(id) where oldrow.h<>md5(to_jsonb(nowrow)::text)) then raise exception 'Existingauditschanged';end if;
end $$;
select probe_id,outcome,errclass,sqlstate,sqlerrm,detail from iso.probe_result where probe_id like 'admin10-%' order by probe_id;
do $$begin
 if (select count(*) from iso.probe_result where probe_id like 'admin10-%')<>80 then raise exception 'Expected80probes';end if;
 if exists(select 1 from iso.probe_result where probe_id like 'admin10-control%' and (outcome<>'success' or detail not like '%effect=asserted-ok%' or detail not like '%nontarget=proved-rowlevel%')) then raise exception 'Adminpositiveinvalid';end if;
 if exists(select 1 from iso.probe_result where probe_id like 'admin10-foreign%' and (outcome<>'denied' or not(sqlerrm like 'NOT_FOUND%' or sqlerrm like 'FORBIDDEN%'))) then raise exception 'Foreigndenialinvalid';end if;
end $$;
rollback;
