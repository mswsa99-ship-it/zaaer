-- Approved individual-mode failclosed boundary, no page maps yet. Local rollback.
\set ON_ERROR_STOP on
begin;
create temp table np(name text,ok boolean);
grant all on np to authenticated;
-- Synthetic branch-target and org-NULL decoys, standard pointer triggers retained.
insert into notifications(organization_id,branch_id,audience,title,body) select org,branch_id,'supervisor','notification access proof','synthetic' from iso.target;
create temp table notify_before as select id,md5(to_jsonb(n)::text) h from notifications n;
do $$declare a record;sid uuid;org uuid;g jsonb;n int;u int;expect_allow boolean;k text;begin
 for a in select * from iso.actor where role<>'guest' order by key loop
  select id,organization_id into sid,org from staff_profiles where auth_user_id=a.auth_user;
  foreach k in array array['legacy','individual-empty','individual-unrelated-allgrants'] loop
   delete from staff_page_access where staff_id=sid;
   if k<>'legacy' then
    g:=case when k='individual-empty' then '{}'::jsonb else '{"/admin/journey":{"view":true,"edit":true},"/admin/finance-controls":{"view":true,"edit":true}}'::jsonb end;
    insert into staff_page_access(staff_id,organization_id,enabled,page_grants) values(sid,org,true,g);
   end if;
   perform iso.set_claims(a.auth_user);set local role authenticated;
   expect_allow:=a.role='owner' or k='legacy';
   select count(*) into n from notifications;
   insert into np values(a.key||'/'||k||'/read',(n>0)=expect_allow);
   select count(*) into n from notifications where organization_id<>org;
   insert into np values(a.key||'/'||k||'/foreignzero',n=0);
   -- A real content-changing UPDATE, not SET read_at=read_at. Rolled back per actorstate.
   begin
    update notifications set read_at=clock_timestamp() where title='notification access proof';get diagnostics u=row_count;
    raise exception 'np-rollback-write';
   exception when raise_exception then
    if sqlerrm<>'np-rollback-write' then raise;end if;
   end;
   -- The nested rollback removes that assertion too; record outside it.
   insert into np values(a.key||'/'||k||'/update',(u>0)=expect_allow);
   reset role;
  end loop;
 end loop;
end $$;
select count(*) assertions,count(*) filter(where not ok) failures from np;
select * from np where not ok;
select (:strict=1 and exists(select 1 from np where not ok)) as fail \gset
\if :fail
 select 1/0;
\endif
rollback;
