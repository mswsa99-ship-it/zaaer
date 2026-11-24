\set ON_ERROR_STOP on
begin;
set local app.identity_key='markchecked19-synthetic-only';
do $$begin
 if exists(select 1 from public.whatsapp_outbox) then raise exception 'requires empty disposable outbox';end if;
 if exists(select 1 from public.branch_whatsapp_channels where enabled or bridge_key_hash is not null) then raise exception 'requires no enabled/keyed channels';end if;
end $$;
create temp table sg_results(name text,ok boolean not null);
create temp table sg_fx(n int,org uuid,b uuid,s uuid,u uuid,r uuid,g uuid,c uuid,oc uuid,review uuid,alert uuid,cat uuid);
insert into organizations(id,name_ar,guest_slug) values('e2330000-0000-0000-0000-000000000001','SG A','mc19-a'),('e2330000-0000-0000-0000-000000000002','SG B','mc19-b');
do $$ declare n int;o uuid;b uuid;s uuid;u uuid;r uuid;g uuid;c uuid;oc uuid;ri uuid;al uuid;cat uuid; begin
 for n in 1..4 loop
 o:=('e2330000-0000-0000-0000-'||lpad((case when n<=2 then 1 else 2 end)::text,12,'0'))::uuid;
 b:=('e2331000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid;s:=('e2332000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid;u:=('e2333000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid;
 insert into branches(id,organization_id,name_ar) values(b,o,'SG branch '||n);
 insert into staff_profiles(id,auth_user_id,organization_id,full_name,email,role) values(s,u,o,'SG Manager','mc19-'||n||'@invalid.test','manager');
 insert into branch_memberships(staff_id,branch_id) values(s,b);
 insert into room_categories(organization_id,branch_id,name_ar,base_price_halalas) values(o,b,'SG Category',10000) returning id into cat;
 insert into reservations(organization_id,branch_id,check_in,check_out,status,actual_check_in) values(o,b,current_date-2,current_date,'checked_in',now()-interval '2 days') returning id into r;
 insert into guest_profiles(organization_id,full_name,phone) values(o,'SG Guest '||n,'+96655191000'||n) returning id into g;
 insert into reservation_guests(reservation_id,guest_profile_id,is_primary,full_name,phone) values(r,g,true,'SG Guest '||n,'+96655191000'||n);
 insert into conversations(organization_id,branch_id,channel) values(o,b,'screen') returning id into c;
 insert into ai_ops_conversations(organization_id,branch_id,staff_id) values(o,b,s) returning id into oc;
 insert into review_items(organization_id,branch_id,kind,entity_type,entity_id,summary) values(o,b,'mc19','reservation',r,'SG Review') returning id into ri;
 insert into alert_events(organization_id,branch_id,event,ref_key,title) values(o,b,'guest_handoff','mc19-'||n,'SG Alert') returning id into al;
 insert into inventory_periods(organization_id,branch_id,category_id,date,total_units) values(o,b,cat,current_date+20,5);
 insert into release_rules(organization_id,branch_id,category_id,enabled,initial_public_release,release_increment) values(o,b,cat,true,1,1);
 insert into sg_fx values(n,o,b,s,u,r,g,c,oc,ri,al,cat);
 end loop;
end $$;
-- Separate owner, no external configuration or sender channels.
insert into staff_profiles(id,auth_user_id,organization_id,full_name,email,role) values
 ('e2332000-0000-0000-0000-000000000011','e2333000-0000-0000-0000-000000000011','e2330000-0000-0000-0000-000000000001','SG Owner A','mc19-owner-a@invalid.test','owner'),
 ('e2332000-0000-0000-0000-000000000012','e2333000-0000-0000-0000-000000000012','e2330000-0000-0000-0000-000000000002','SG Owner B','mc19-owner-b@invalid.test','owner');
create function pg_temp.sg_snap() returns jsonb language plpgsql as $$declare t record;j jsonb;v jsonb:='{}';begin
 for t in select relname from pg_class where relnamespace='public'::regnamespace and relkind='r' order by relname loop
 execute format('select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),''[]'') from public.%I x',t.relname) into j; v:=v||jsonb_build_object(t.relname,j);end loop;return v;end $$;
create function pg_temp.sg_try(q text,uid uuid,slug text default null) returns jsonb language plpgsql as $$declare j jsonb;begin
 perform set_config('request.jwt.claim.sub',coalesce(uid::text,''),true);perform set_config('request.jwt.claims',case when uid is null then '{"role":"anon"}' else jsonb_build_object('sub',uid,'role','authenticated')::text end,true);
 perform set_config('request.headers',case when slug is null then '{}' else jsonb_build_object('x-hotel-slug',slug)::text end,true);
 if uid is null then set local role anon;else set local role authenticated;end if;
 begin execute q into j;j:=jsonb_build_object('ok',true,'result',j);exception when others then j:=jsonb_build_object('ok',false,'error',sqlerrm,'state',sqlstate);end;reset role;
 perform set_config('request.jwt.claim.sub','',true);perform set_config('request.jwt.claims','{}',true);return j;end $$;
create function pg_temp.sg_check(n text,b boolean) returns void language plpgsql as $$begin insert into sg_results values(n,coalesce(b,false));if b is not true then raise exception 'SG CHECK FAILED: %',n;end if;end $$;
create function pg_temp.sg_tables(before_j jsonb,allowed text[]) returns boolean language sql as $$select not exists(select 1 from jsonb_each(pg_temp.sg_snap()) e where e.value is distinct from before_j->e.key and not(e.key=any(allowed)))$$;
-- Exact foreign and wrong-branch calls use the SAME staff credential as the positive.
create function pg_temp.sg_deny(q text,uid uuid,label text) returns void language plpgsql as $$declare b jsonb;j jsonb;begin b:=pg_temp.sg_snap();j:=pg_temp.sg_try(q,uid);perform pg_temp.sg_check(label,not(j->>'ok')::boolean and pg_temp.sg_snap()=b);end $$;
create temp table sg_baseline as select pg_temp.sg_snap() j;
create function pg_temp.sg_delta(b jsonb,t text,adds int,updates int,dels int) returns boolean language plpgsql as $$declare a jsonb;na int;nu int;nd int;begin
 a:=pg_temp.sg_snap()->t;
 with old as(select coalesce(x->>'id',x->>'token',x->>'branch_id') k,x from jsonb_array_elements(b->t)x),new as(select coalesce(x->>'id',x->>'token',x->>'branch_id') k,x from jsonb_array_elements(a)x)
 select count(*) filter(where old.k is null),count(*) filter(where old.k is not null and new.k is not null and old.x<>new.x),count(*) filter(where new.k is null) into na,nu,nd from old full join new using(k);
 if (na,nu,nd)<>(adds,updates,dels) then raise notice 'DELTA % actual %/%/% expected %/%/%',t,na,nu,nd,adds,updates,dels;end if;return (na,nu,nd)=(adds,updates,dels);end $$;
-- All group targets stay in one branch; the other hotel deliberately shares the group text.
create temp table mc_fx(n int,src uuid,peer uuid,direct uuid);
do $$declare f record;src uuid;peer uuid;direct uuid;begin
 for f in select * from sg_fx order by n loop
 insert into booking_sources(organization_id,name,kind,code) values(f.org,'MC External '||f.n,'external','MCEXT'||f.n) returning id into src;
 update reservations set source_id=src,external_ref='MC-EXTERNAL-'||f.n,group_ref='MC-GROUP-'||case when f.n%2=1 then 1 else 2 end where id=f.r;
 insert into reservations(organization_id,branch_id,source_id,external_ref,check_in,check_out,group_ref) values(f.org,f.b,src,'MC-PEER-'||f.n,current_date,current_date+1,'MC-GROUP-'||case when f.n%2=1 then 1 else 2 end) returning id into peer;
 insert into reservations(organization_id,branch_id,check_in,check_out) values(f.org,f.b,current_date,current_date+1) returning id into direct;
 insert into mc_fx values(f.n,src,peer,direct);
 end loop;
end $$;
-- Require exact unchanged content of every reservation outside target pair, and of every target field except intended three.
create function pg_temp.mc_rows(b jsonb,ids uuid[]) returns boolean language sql as $$
 select not exists(select 1 from reservations r join jsonb_array_elements(b->'reservations') old on old->>'id'=r.id::text
 where case when r.id=any(ids) then to_jsonb(r)-array['platform_verified_at','platform_verified_by','updated_at']<>old-array['platform_verified_at','platform_verified_by','updated_at'] else to_jsonb(r)<>old end)
$$;
create function pg_temp.mc_audit(b jsonb,f_org uuid,f_b uuid,staff uuid,rid uuid,act text,cnt int,ref text) returns boolean language sql as $$
 select count(*)=1 and bool_and(a.organization_id=f_org and a.branch_id=f_b and a.actor_id=staff and a.entity_type='reservation' and a.entity_id=rid and a.action=act and a.details=jsonb_build_object('after',jsonb_build_object('units',cnt,'external_ref',ref)))
 from audit_events a where not exists(select 1 from jsonb_array_elements(b->'audit_events') old where old->>'id'=a.id::text)
$$;
do $$declare f record;m record;d record;x record;b jsonb;j jsonb;uid uuid;sid uuid;mode text;begin
 for f in select * from sg_fx order by n loop
 select * into m from mc_fx where n=f.n;
 select * into d from sg_fx where n=case when f.n%2=1 then f.n+1 else f.n-1 end;
 select * into x from sg_fx where n=case when f.n<=2 then f.n+2 else f.n-2 end;
 -- Same actual positive credential targets wrong-branch and foreign-hotel reservations.
 perform pg_temp.sg_deny(format('select fn_platform_mark_checked(%L::jsonb)',jsonb_build_object('reservation_id',d.r)),f.u,'mark wrong branch '||f.n);
 perform pg_temp.sg_deny(format('select fn_platform_mark_checked(%L::jsonb)',jsonb_build_object('reservation_id',x.r)),f.u,'mark foreign hotel '||f.n);
 perform pg_temp.sg_deny(format('select fn_platform_mark_checked(%L::jsonb)',jsonb_build_object('reservation_id',m.direct)),f.u,'mark direct source validation '||f.n);
 perform pg_temp.sg_deny(format('select fn_platform_mark_checked(%L::jsonb)',jsonb_build_object('reservation_id',f.r)),null,'mark anonymous '||f.n);
 -- Legacy manager, individual full-page manager and true owner all get independent mark/unmark positives.
 foreach mode in array array['legacy','individual','owner'] loop
 uid:=f.u;sid:=f.s;
 if mode='individual' then insert into staff_page_access(staff_id,organization_id,enabled,page_grants) values(f.s,f.org,true,'{"/staff/platforms":{"view":true,"edit":true}}');end if;
 if mode='owner' then select auth_user_id,id into uid,sid from staff_profiles where organization_id=f.org and role='owner';end if;
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_platform_mark_checked(%L::jsonb)',jsonb_build_object('reservation_id',f.r)),uid);
 perform pg_temp.sg_check('mark exact '||mode||' '||f.n,j->'result'='{"ok":true,"units":2}' and (select count(*) from reservations where id in(f.r,m.peer) and platform_verified_by=sid and platform_verified_at=now())=2 and pg_temp.sg_delta(b,'reservations',0,2,0) and pg_temp.sg_delta(b,'audit_events',1,0,0) and pg_temp.sg_tables(b,array['reservations','audit_events']) and pg_temp.mc_rows(b,array[f.r,m.peer]) and pg_temp.mc_audit(b,f.org,f.b,sid,f.r,'reservation.platform_checked',2,'MC-EXTERNAL-'||f.n));
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_platform_mark_checked(%L::jsonb)',jsonb_build_object('reservation_id',f.r,'checked',false)),uid);
 perform pg_temp.sg_check('unmark exact '||mode||' '||f.n,j->'result'='{"ok":true,"units":2}' and (select count(*) from reservations where id in(f.r,m.peer) and platform_verified_by is null and platform_verified_at is null)=2 and pg_temp.sg_delta(b,'reservations',0,2,0) and pg_temp.sg_delta(b,'audit_events',1,0,0) and pg_temp.sg_tables(b,array['reservations','audit_events']) and pg_temp.mc_rows(b,array[f.r,m.peer]) and pg_temp.mc_audit(b,f.org,f.b,sid,f.r,'reservation.platform_unchecked',2,'MC-EXTERNAL-'||f.n));
 if mode='individual' then delete from staff_page_access where staff_id=f.s;end if;
 end loop;
 insert into staff_page_access(staff_id,organization_id,enabled,page_grants) values(f.s,f.org,true,'{"/staff/platforms":{"view":true}}');
 perform pg_temp.sg_deny(format('select fn_platform_mark_checked(%L::jsonb)',jsonb_build_object('reservation_id',f.r)),f.u,'mark view only denied '||f.n);
 update staff_page_access set page_grants='{}' where staff_id=f.s;
 perform pg_temp.sg_deny(format('select fn_platform_mark_checked(%L::jsonb)',jsonb_build_object('reservation_id',f.r)),f.u,'mark no page denied '||f.n);
 delete from staff_page_access where staff_id=f.s;
 update staff_profiles set role='finance' where id=f.s;
 perform pg_temp.sg_deny(format('select fn_platform_mark_checked(%L::jsonb)',jsonb_build_object('reservation_id',f.r)),f.u,'mark wrong role denied '||f.n);
 update staff_profiles set role='manager' where id=f.s;
 end loop;
end $$;
select name,ok from sg_results order by name;
select count(*) as passed_checks,bool_and(ok) as all_ok from sg_results;
rollback;
