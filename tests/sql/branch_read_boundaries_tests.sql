-- Standalone synthetic red/green regression after migrations. Transaction rolls back all fixtures.
\set ON_ERROR_STOP on
begin;
create temporary table branch_read_results(name text, ok boolean);
grant all on branch_read_results to authenticated;
create schema brtest;
create function brtest.id(n int) returns uuid language sql immutable as $$ select ('b1140000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid $$;
grant usage on schema brtest to authenticated;
grant execute on function brtest.id(int) to authenticated;
insert into organizations(id,name_ar) values (brtest.id(1),'Boundary A'),(brtest.id(2),'Boundary B');
insert into branches(id,organization_id,name_ar) values (brtest.id(11),brtest.id(1),'A1'),(brtest.id(12),brtest.id(1),'A2'),(brtest.id(21),brtest.id(2),'B1');
do $$ declare i int; r role_code; begin
 for i in 1..6 loop
  r := (array['owner','manager','supervisor','finance','housekeeping','manager'])[i]::role_code;
  insert into auth.users(id,email,email_confirmed_at) values(brtest.id(100+i),'boundary'||i||'@invalid.test',now());
  insert into staff_profiles(id,auth_user_id,organization_id,full_name,email,phone,role)
    values(brtest.id(200+i),brtest.id(100+i),brtest.id(1),'Boundary '||i,'boundary'||i||'@invalid.test','0500000000',r);
  if i>1 then insert into branch_memberships(staff_id,branch_id) values(brtest.id(200+i),brtest.id(case when i=6 then 12 else 11 end)); end if;
 end loop;
 insert into branch_memberships(staff_id,branch_id,removed_at) values(brtest.id(202),brtest.id(12),now());
end $$;
insert into staff_profiles(id,auth_user_id,organization_id,full_name,email,role) values(brtest.id(299),brtest.id(199),brtest.id(2),'Foreign','foreign@invalid.test','manager');
insert into branch_memberships(staff_id,branch_id) values(brtest.id(299),brtest.id(21));
insert into product_categories(id,organization_id,name) values(brtest.id(301),brtest.id(1),'Boundary A'),(brtest.id(302),brtest.id(2),'Boundary B');
insert into products(id,organization_id,category_id,name,price_halalas) values(brtest.id(311),brtest.id(1),brtest.id(301),'Boundary A',100),(brtest.id(312),brtest.id(2),brtest.id(302),'Boundary B',100);
do $$ declare b int; o int; c uuid; begin
 foreach b in array array[11,12,21] loop
  o:=case when b=21 then 2 else 1 end;
  insert into conversations(id,organization_id,branch_id) values(brtest.id(400+b),brtest.id(o),brtest.id(b)) returning id into c;
  insert into ai_guardrail_events(conversation_id,stage,rule) values(c,'input','boundary-proof');
  insert into ai_tool_executions(conversation_id,tool_name,result_status) values(c,'boundary-proof','ok');
  insert into product_branches(product_id,branch_id,organization_id,available) values(brtest.id(case when o=1 then 311 else 312 end),brtest.id(b),brtest.id(o),true);
 end loop;
end $$;
set local role authenticated;
do $$ declare i int; t text; n int; allowed int; js jsonb; begin
 for i in 1..5 loop
  perform set_config('request.jwt.claim.sub',brtest.id(100+i)::text,true);
  foreach t in array array['branch_memberships','product_branches','ai_guardrail_events','ai_tool_executions'] loop
   execute format('select count(*) from %I where branch_id=$1',t) into n using brtest.id(12);
   insert into branch_read_results values('role'||i||'/'||t||'/unassigned', n=case when i=1 then (case when t='branch_memberships' then 2 else 1 end) else 0 end);
   execute format('select count(*) from %I where branch_id=$1',t) into n using brtest.id(21);
   insert into branch_read_results values('role'||i||'/'||t||'/foreign-hotel',n=0);
   execute format('select count(*) from %I where branch_id=$1',t) into n using brtest.id(11);
   allowed:=case when t in ('ai_guardrail_events','ai_tool_executions') and i>2 then 0 else case when t='branch_memberships' then 4 else 1 end end;
   insert into branch_read_results values('role'||i||'/'||t||'/member-positive-or-existing-role-denial',n=allowed);
  end loop;
  js:=fn_admin_staff_list();
  if i<=2 then
   insert into branch_read_results values('role'||i||'/hotel-registry-kept',jsonb_array_length(js)=6);
   insert into branch_read_results values('role'||i||'/no-foreign-identity',not exists(select 1 from jsonb_array_elements(js) x where x->>'id'=brtest.id(299)::text));
   insert into branch_read_results values('role'||i||'/branch-metadata-scope',exists(select 1 from jsonb_array_elements(js) x where x->>'id'=brtest.id(206)::text and x->'branch_ids'=case when i=1 then jsonb_build_array(brtest.id(12)) else '[]'::jsonb end));
   insert into branch_read_results values('role'||i||'/removed-membership-not-returned',exists(select 1 from jsonb_array_elements(js) x where x->>'id'=brtest.id(202)::text and x->'branch_ids'=jsonb_build_array(brtest.id(11))));
   if i=2 then insert into branch_read_results values('manager/no-phones',not exists(select 1 from jsonb_array_elements(js) x where x->>'phone' is not null)); end if;
  else insert into branch_read_results values('role'||i||'/no-new-registry-grant',js='[]'::jsonb); end if;
 end loop;
end $$;
reset role;
-- Individual page grants retain the existing page gate, but cannot bypass branch membership.
insert into staff_page_access(staff_id,organization_id,enabled,page_grants) values(brtest.id(203),brtest.id(1),true,'{"/admin/ai-settings":{"view":true}}');
set local role authenticated;
select set_config('request.jwt.claim.sub',brtest.id(103)::text,true);
do $$ declare t text; n int; begin
 foreach t in array array['ai_guardrail_events','ai_tool_executions'] loop
  execute format('select count(*) from %I where branch_id=$1',t) into n using brtest.id(11);
  insert into branch_read_results values(t||'/page-grant-member-positive',n=1);
  execute format('select count(*) from %I where branch_id=$1',t) into n using brtest.id(12);
  insert into branch_read_results values(t||'/page-grant-unassigned-denied',n=0);
 end loop;
end $$;
reset role;
update staff_page_access set page_grants='{}' where staff_id=brtest.id(203);
set local role authenticated;
select set_config('request.jwt.claim.sub',brtest.id(103)::text,true);
do $$ begin
 insert into branch_read_results values('individual/no-page-grant-still-denied',
   (select count(*) from ai_guardrail_events)=0 and (select count(*) from ai_tool_executions)=0);
end $$;
reset role;
update staff_profiles set is_active=false where id=brtest.id(202);
set local role authenticated;
select set_config('request.jwt.claim.sub',brtest.id(102)::text,true);
do $$ begin
 insert into branch_read_results values('inactive/no-branch-access',
   (select count(*) from branch_memberships)=0 and (select count(*) from product_branches)=0
   and (select count(*) from ai_guardrail_events)=0 and (select count(*) from ai_tool_executions)=0);
 insert into branch_read_results values('inactive/no-staff-registry',fn_admin_staff_list()='[]'::jsonb);
end $$;
reset role;
select case when ok then 'PASS' else 'FAIL' end as result,name from branch_read_results order by name;
select count(*) as assertions,count(*) filter(where not ok) as failures from branch_read_results;
do $$ begin if exists(select 1 from branch_read_results where not ok) then raise exception 'branch-read regression failed'; end if; end $$;
rollback;
