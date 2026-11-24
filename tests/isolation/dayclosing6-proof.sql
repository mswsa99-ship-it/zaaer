\set ON_ERROR_STOP on
begin;
set local app.identity_key='guestreview6-synthetic-only';
do $$begin
 if exists(select 1 from public.whatsapp_outbox) then raise exception 'requires empty disposable outbox';end if;
 if exists(select 1 from public.branch_whatsapp_channels where enabled or bridge_key_hash is not null) then raise exception 'requires no enabled/keyed channels';end if;
end $$;
create temp table sg_results(name text,ok boolean not null);
create temp table sg_fx(n int,org uuid,b uuid,s uuid,u uuid,r uuid,g uuid,c uuid,oc uuid,review uuid,alert uuid,cat uuid);
insert into organizations(id,name_ar,guest_slug) values('e2460000-0000-0000-0000-000000000001','SG A','dc6-a'),('e2460000-0000-0000-0000-000000000002','SG B','dc6-b');
do $$ declare n int;o uuid;b uuid;s uuid;u uuid;r uuid;g uuid;c uuid;oc uuid;ri uuid;al uuid;cat uuid;rm uuid; begin
 for n in 1..4 loop
 o:=('e2460000-0000-0000-0000-'||lpad((case when n<=2 then 1 else 2 end)::text,12,'0'))::uuid;
 b:=('e2461000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid;s:=('e2462000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid;u:=('e2463000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid;
 insert into branches(id,organization_id,name_ar) values(b,o,'SG branch '||n);
 insert into staff_profiles(id,auth_user_id,organization_id,full_name,email,role) values(s,u,o,'SG Manager','dc6-'||n||'@invalid.test','manager');
 insert into branch_memberships(staff_id,branch_id) values(s,b);
 insert into room_categories(organization_id,branch_id,name_ar,base_price_halalas) values(o,b,'SG Category',10000) returning id into cat;
 insert into rooms(organization_id,branch_id,category_id,room_number) values(o,b,cat,'SGB-'||n) returning id into rm;
 insert into reservations(organization_id,branch_id,room_id,check_in,check_out,status,actual_check_in) values(o,b,rm,current_date-2,current_date,'checked_in',now()-interval '2 days') returning id into r;
 insert into guest_profiles(organization_id,full_name,phone) values(o,'SG Guest '||n,'+96655191000'||n) returning id into g;
 insert into reservation_guests(reservation_id,guest_profile_id,is_primary,full_name,phone) values(r,g,true,'SG Guest '||n,'+96655191000'||n);
 insert into conversations(organization_id,branch_id,channel) values(o,b,'screen') returning id into c;
 insert into ai_ops_conversations(organization_id,branch_id,staff_id) values(o,b,s) returning id into oc;
 insert into review_items(organization_id,branch_id,kind,entity_type,entity_id,summary) values(o,b,'dc6','reservation',r,'SG Review') returning id into ri;
 insert into alert_events(organization_id,branch_id,event,ref_key,title) values(o,b,'guest_handoff','dc6-'||n,'SG Alert') returning id into al;
 insert into inventory_periods(organization_id,branch_id,category_id,date,total_units) values(o,b,cat,current_date+20,5);
 insert into release_rules(organization_id,branch_id,category_id,enabled,initial_public_release,release_increment) values(o,b,cat,true,1,1);
 insert into sg_fx values(n,o,b,s,u,r,g,c,oc,ri,al,cat);
 end loop;
end $$;
-- Separate owner, no external configuration or sender channels.
insert into staff_profiles(id,auth_user_id,organization_id,full_name,email,role) values
 ('e2462000-0000-0000-0000-000000000011','e2463000-0000-0000-0000-000000000011','e2460000-0000-0000-0000-000000000001','SG Owner A','dc6-owner-a@invalid.test','owner'),
 ('e2462000-0000-0000-0000-000000000012','e2463000-0000-0000-0000-000000000012','e2460000-0000-0000-0000-000000000002','SG Owner B','dc6-owner-b@invalid.test','owner');
create function pg_temp.sg_snap() returns jsonb language plpgsql as $$declare t record;j jsonb;v jsonb:='{}';begin
 for t in select relname from pg_class where relnamespace='public'::regnamespace and relkind='r' order by relname loop
 execute format('select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),''[]'') from public.%I x',t.relname) into j; v:=v||jsonb_build_object(t.relname,j);end loop;return v;end $$;
create function pg_temp.sg_try(q text,uid uuid,slug text default null) returns jsonb language plpgsql as $$declare j jsonb;begin
 if exists(select 1 from whatsapp_outbox) or exists(select 1 from branch_whatsapp_channels where enabled and bridge_key_hash is not null) then raise exception 'unsafe pre-call queue/channel';end if;perform set_config('request.jwt.claim.sub',coalesce(uid::text,''),true);perform set_config('request.jwt.claims',case when uid is null then '{"role":"anon"}' else jsonb_build_object('sub',uid,'role','authenticated')::text end,true);
 perform set_config('request.headers',case when slug is null then '{}' else jsonb_build_object('x-hotel-slug',slug)::text end,true);
 if uid is null then set local role anon;else set local role authenticated;end if;
 begin execute q into j;j:=jsonb_build_object('ok',true,'result',j);exception when others then j:=jsonb_build_object('ok',false,'error',sqlerrm,'state',sqlstate);end;reset role;
 if exists(select 1 from whatsapp_outbox) or exists(select 1 from branch_whatsapp_channels where enabled and bridge_key_hash is not null) then raise exception 'unsafe post-call queue/channel';end if;perform set_config('request.jwt.claim.sub','',true);perform set_config('request.jwt.claims','{}',true);return j;end $$;
create function pg_temp.sg_check(n text,b boolean) returns void language plpgsql as $$begin insert into sg_results values(n,coalesce(b,false));if b is not true then raise exception 'SG CHECK FAILED: %',n;end if;end $$;
create function pg_temp.sg_tables(before_j jsonb,allowed text[]) returns boolean language plpgsql as $$declare t text;old jsonb;new jsonb;b uuid:=current_setting('dc.target_branch')::uuid;begin
 if exists(select 1 from jsonb_each(pg_temp.sg_snap()) e where e.value is distinct from before_j->e.key and not(e.key=any(allowed))) then return false;end if;
 foreach t in array allowed loop
 for old in select value from jsonb_array_elements(before_j->t) loop
 select value into new from jsonb_array_elements(pg_temp.sg_snap()->t) where value->>'id'=old->>'id';
 if new is distinct from old and coalesce(old->>'branch_id','')<>b::text then return false;end if;
 end loop;
 for new in select value from jsonb_array_elements(pg_temp.sg_snap()->t) loop
 if not exists(select 1 from jsonb_array_elements(before_j->t) x where x->>'id'=new->>'id') and coalesce(new->>'branch_id','')<>b::text then return false;end if;
 end loop;end loop;return true;end $$;
-- Exact foreign and wrong-branch calls use the SAME staff credential as the positive.
create function pg_temp.sg_deny(q text,uid uuid,label text) returns void language plpgsql as $$declare b jsonb;j jsonb;begin b:=pg_temp.sg_snap();j:=pg_temp.sg_try(q,uid);perform pg_temp.sg_check(label,not(j->>'ok')::boolean and pg_temp.sg_snap()=b);end $$;
create temp table sg_baseline as select pg_temp.sg_snap() j;
create function pg_temp.sg_delta(b jsonb,t text,adds int,updates int,dels int) returns boolean language plpgsql as $$declare a jsonb;na int;nu int;nd int;begin
 a:=pg_temp.sg_snap()->t;
 with old as(select coalesce(x->>'id',x->>'token',x->>'branch_id') k,x from jsonb_array_elements(b->t)x),new as(select coalesce(x->>'id',x->>'token',x->>'branch_id') k,x from jsonb_array_elements(a)x)
 select count(*) filter(where old.k is null),count(*) filter(where old.k is not null and new.k is not null and old.x<>new.x),count(*) filter(where new.k is null) into na,nu,nd from old full join new using(k);
 if (na,nu,nd)<>(adds,updates,dels) then raise notice 'DELTA % actual %/%/% expected %/%/%',t,na,nu,nd,adds,updates,dels;end if;return (na,nu,nd)=(adds,updates,dels);end $$;
-- No paid vouchers: zero ledger, explicit nonzero terminal discrepancy, cash difference zero. Branch creation seeds synthetic cash accounts.
-- This bounds the first six-signature proof to cash-neutral submission/amendment; GL cash variants are not claimed.
create temp table dc_fx(n int,cid uuid,req uuid,fig jsonb);
insert into day_closings(organization_id,branch_id,business_date) select org,b,current_date-1 from sg_fx;
insert into dc_fx(n,cid) select f.n,c.id from sg_fx f join day_closings c on c.branch_id=f.b;
create function pg_temp.dc_audit(b jsonb,org uuid,br uuid,staff uuid,cid uuid,act text) returns boolean language sql as $$
select count(*)=1 and bool_and(a.organization_id=org and a.branch_id=br and a.actor_id=staff and a.entity_id=cid and a.entity_type='day_closing' and a.action=act and case act when 'day_closing.created' then a.details->'after'->>'business_date'=(current_date-2)::text when 'day_closing.submitted' then a.details->'after'->>'business_date'=(current_date-1)::text and jsonb_array_length(a.details->'after'->'lines')=3 when 'day_closing.amended' then a.details->>'reason'='DC literal amend' and jsonb_array_length(a.details->'before'->'lines')=3 and jsonb_array_length(a.details->'after'->'lines')=3 when 'day_closing.edit_requested' then a.details->>'reason' in ('DC reopen reason','second reason') and a.details->'after'->>'request_id' is not null when 'day_closing.edit_approved' then a.details->>'reason'='DC approval' when 'day_closing.edit_rejected' then a.details->>'reason'='DC rejection' else false end)
from audit_events a where not exists(select 1 from jsonb_array_elements(b->'audit_events') old where old->>'id'=a.id::text) $$;
create function pg_temp.dc_lines(cid uuid,pos bigint) returns boolean language sql as $$
select count(*)=3 and bool_and(system_halalas=0 and account_id in(select id from cash_accounts ca where ca.branch_id=day_closing_lines.branch_id) and source_id is null and case line_key when 'cash' then entered_halalas=0 and difference_halalas=0 when 'pos' then entered_halalas=pos and difference_halalas=pos and reason='synthetic terminal discrepancy' when 'bank_transfer' then entered_halalas=0 and difference_halalas=0 else false end) from day_closing_lines where closing_id=cid $$;
do $$declare f record;d record;x record;m record;dm record;xm record;b jsonb;j jsonb;payload jsonb;tok text;v int;begin
 for f in select * from sg_fx order by n loop
 select * into m from dc_fx where n=f.n;perform set_config('dc.target_branch',f.b::text,true);
 select * into d from sg_fx where n=case when f.n%2=1 then f.n+1 else f.n-1 end;
 select * into dm from dc_fx where n=d.n;
 select * into x from sg_fx where n=case when f.n<=2 then f.n+2 else f.n-2 end;
 select * into xm from dc_fx where n=x.n;
 payload:=jsonb_build_object('branch_id',f.b,'business_date',current_date-1,'version',1,'note','DC literal note','lines','[{"key":"cash","entered_halalas":0},{"key":"pos","entered_halalas":250,"reason":"synthetic terminal discrepancy"},{"key":"bank_transfer","entered_halalas":0}]'::jsonb);
 perform pg_temp.sg_deny(format('select fn_day_closing_save(%L::jsonb)',payload||jsonb_build_object('branch_id',d.b)),f.u,'save wrong branch '||f.n);
 perform pg_temp.sg_deny(format('select fn_day_closing_save(%L::jsonb)',payload||jsonb_build_object('branch_id',x.b)),f.u,'save foreign hotel '||f.n);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_day_closing_save(%L::jsonb)',payload),f.u);
 perform pg_temp.sg_check('save update exact '||f.n,j->'result'->>'id'=m.cid::text and j->'result'->>'version'='2' and exists(select 1 from day_closings where id=m.cid and note='DC literal note' and updated_by=f.s) and pg_temp.dc_lines(m.cid,250) and pg_temp.sg_delta(b,'day_closings',0,1,0) and pg_temp.sg_delta(b,'day_closing_lines',3,0,0) and pg_temp.sg_tables(b,array['day_closings','day_closing_lines']));
 perform pg_temp.sg_deny(format('select fn_day_closing_review(%L)',dm.cid),f.u,'review wrong branch '||f.n);
 perform pg_temp.sg_deny(format('select fn_day_closing_review(%L)',xm.cid),f.u,'review foreign hotel '||f.n);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_day_closing_review(%L)',m.cid),f.u);tok:=j->'result'->>'hash';
 perform pg_temp.sg_check('review exact '||f.n,j->'result'->'missing'='[]' and j->'result'->'unexplained'='[]' and j->'result'->>'version'='2' and tok is not null and exists(select 1 from day_closings where id=m.cid and review_token=tok and review_hash is not null and version=2) and pg_temp.dc_lines(m.cid,250) and (select bool_and((z->>'system_halalas')::bigint=0) from jsonb_array_elements(j->'result'->'figures'->'boxes')z) and pg_temp.sg_delta(b,'day_closings',0,1,0) and pg_temp.sg_tables(b,array['day_closings','day_closing_lines']));
 perform pg_temp.sg_deny(format('select fn_day_closing_submit(%L,2,%L)',dm.cid,tok),f.u,'submit wrong branch '||f.n);
 perform pg_temp.sg_deny(format('select fn_day_closing_submit(%L,2,%L)',xm.cid,tok),f.u,'submit foreign hotel '||f.n);
 perform pg_temp.sg_deny(format('select fn_day_closing_submit(%L,2,''bad'')',m.cid),f.u,'submit stale review '||f.n);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_day_closing_submit(%L,2,%L)',m.cid,tok),f.u);
 perform pg_temp.sg_check('submit exact '||f.n,j->'result'->>'version'='3' and exists(select 1 from day_closings where id=m.cid and status='submitted' and submitted_by=f.s and review_token is null and submitted_at=now() and edit_until>now() and version=3) and pg_temp.dc_lines(m.cid,250) and pg_temp.sg_delta(b,'day_closings',0,1,0) and pg_temp.sg_delta(b,'audit_events',1,0,0) and pg_temp.dc_audit(b,f.org,f.b,f.s,m.cid,'day_closing.submitted') and pg_temp.sg_tables(b,array['day_closings','day_closing_lines','audit_events']));
 payload:=jsonb_build_object('id',m.cid,'version',3,'reason','DC literal amend','lines','[{"key":"pos","entered_halalas":300,"reason":"synthetic terminal discrepancy"}]'::jsonb);
 perform pg_temp.sg_deny(format('select fn_day_closing_amend(%L::jsonb)',payload||jsonb_build_object('id',dm.cid)),f.u,'amend wrong branch '||f.n);
 perform pg_temp.sg_deny(format('select fn_day_closing_amend(%L::jsonb)',payload||jsonb_build_object('id',xm.cid)),f.u,'amend foreign hotel '||f.n);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_day_closing_amend(%L::jsonb)',payload),f.u);
 perform pg_temp.sg_check('amend exact '||f.n,j->'result'->>'version'='4' and pg_temp.dc_lines(m.cid,300) and pg_temp.sg_delta(b,'day_closings',0,1,0) and pg_temp.sg_delta(b,'day_closing_lines',0,1,0) and pg_temp.sg_delta(b,'review_items',1,0,0) and exists(select 1 from review_items where entity_id=m.cid and kind='day_closing_amended' and reason='DC literal amend' and created_by=f.s) and pg_temp.sg_delta(b,'audit_events',1,0,0) and pg_temp.dc_audit(b,f.org,f.b,f.s,m.cid,'day_closing.amended') and pg_temp.sg_tables(b,array['day_closings','day_closing_lines','review_items','audit_events']));
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_day_closing_amend(%L::jsonb)',payload||'{"version":4}'),f.u);
 perform pg_temp.sg_check('amend unchanged no write '||f.n,j->'result'->>'unchanged'='true' and pg_temp.sg_snap()=b);
 -- Closed edit window is a directly seeded local prerequisite, not an unqualified clock wait.
 update day_closings set edit_until=now()-interval '1 minute' where id=m.cid;
 update dc_fx set fig=(select figures from day_closings where id=m.cid) where n=f.n;
 end loop;end $$;
-- Request/decision positives use real locked closing/request fixtures, not invalid-state denial substitutes.
do $$declare f record;m record;d record;x record;dm record;xm record;b jsonb;j jsonb;rid uuid;u uuid;s uuid;begin
 for f in select * from sg_fx order by n loop
 select * into m from dc_fx where n=f.n;perform set_config('dc.target_branch',f.b::text,true);
 select * into d from sg_fx where n=case when f.n%2=1 then f.n+1 else f.n-1 end;
 select * into dm from dc_fx where n=d.n;
 select * into x from sg_fx where n=case when f.n<=2 then f.n+2 else f.n-2 end;
 select * into xm from dc_fx where n=x.n;
 perform pg_temp.sg_deny(format('select fn_day_closing_request_edit(%L,''test'')',dm.cid),f.u,'request wrong branch '||f.n);
 perform pg_temp.sg_deny(format('select fn_day_closing_request_edit(%L,''test'')',xm.cid),f.u,'request foreign hotel '||f.n);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_day_closing_request_edit(%L,''DC reopen reason'')',m.cid),f.u);rid:=(j->'result'->>'request_id')::uuid;
 perform pg_temp.sg_check('request exact '||f.n,(j->>'ok')::boolean and exists(select 1 from day_closing_requests where id=rid and closing_id=m.cid and branch_id=f.b and organization_id=f.org and status='pending' and reason='DC reopen reason' and requested_by=f.s) and pg_temp.sg_delta(b,'day_closing_requests',1,0,0) and pg_temp.sg_delta(b,'audit_events',1,0,0) and pg_temp.dc_audit(b,f.org,f.b,f.s,m.cid,'day_closing.edit_requested') and pg_temp.sg_tables(b,array['day_closing_requests','audit_events']));
 update dc_fx set req=rid where n=f.n;
 perform pg_temp.sg_deny(format('select fn_day_closing_request_edit(%L,''duplicate'')',m.cid),f.u,'request duplicate validation '||f.n);
 perform pg_temp.sg_deny(format('select fn_day_closing_decide(%L,true,''self'')',rid),f.u,'decision self prohibited '||f.n);
 end loop;
 for f in select * from sg_fx order by n loop
 select * into m from dc_fx where n=f.n;perform set_config('dc.target_branch',f.b::text,true);
 select * into dm from dc_fx where n=case when f.n%2=1 then f.n+1 else f.n-1 end;
 select * into xm from dc_fx where n=case when f.n<=2 then f.n+2 else f.n-2 end;
 perform pg_temp.sg_deny(format('select fn_day_closing_decide(%L,true,''test'')',dm.req),f.u,'decide wrong branch '||f.n);
 perform pg_temp.sg_deny(format('select fn_day_closing_decide(%L,true,''test'')',xm.req),f.u,'decide foreign hotel '||f.n);
 select auth_user_id,id into u,s from staff_profiles where organization_id=f.org and role='owner';
 perform pg_temp.sg_deny(format('select fn_day_closing_decide(%L,true,''test'')',xm.req),u,'decide same owner foreign hotel '||f.n);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_day_closing_decide(%L,true,''DC approval'')',m.req),u);
 perform pg_temp.sg_check('decide approve exact '||f.n,j->'result'->>'status'='approved' and exists(select 1 from day_closing_requests where id=m.req and status='approved' and decided_by=s and decision_note='DC approval' and decided_at=now()) and exists(select 1 from day_closings where id=m.cid and version=5 and edit_until=now()+make_interval(mins=>(select day_close_edit_minutes from branches where id=f.b))) and pg_temp.sg_delta(b,'day_closing_requests',0,1,0) and pg_temp.sg_delta(b,'day_closings',0,1,0) and pg_temp.sg_delta(b,'audit_events',1,0,0) and pg_temp.dc_audit(b,f.org,f.b,s,m.cid,'day_closing.edit_approved') and pg_temp.sg_tables(b,array['day_closing_requests','day_closings','audit_events']));
 -- Second valid locked request proves rejection has no closing mutation.
 update day_closings set edit_until=now()-interval '1 minute' where id=m.cid;
 j:=pg_temp.sg_try(format('select fn_day_closing_request_edit(%L,''second reason'')',m.cid),f.u);rid:=(j->'result'->>'request_id')::uuid;
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_day_closing_decide(%L,false,''DC rejection'')',rid),u);
 perform pg_temp.sg_check('decide reject exact '||f.n,j->'result'->>'status'='rejected' and exists(select 1 from day_closing_requests where id=rid and status='rejected' and decided_by=s and decision_note='DC rejection') and pg_temp.sg_delta(b,'day_closing_requests',0,1,0) and pg_temp.sg_delta(b,'audit_events',1,0,0) and pg_temp.dc_audit(b,f.org,f.b,s,m.cid,'day_closing.edit_rejected') and pg_temp.sg_tables(b,array['day_closing_requests','audit_events']));
 end loop;
end $$;
-- New-day save path, and no-page denial across all six exact signatures.
do $$declare f record;m record;b jsonb;j jsonb;cid uuid;begin
 for f in select * from sg_fx order by n loop
 select * into m from dc_fx where n=f.n;perform set_config('dc.target_branch',f.b::text,true);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_day_closing_save(%L::jsonb)',jsonb_build_object('branch_id',f.b,'business_date',current_date-2,'note','DC new draft','lines','[{"key":"cash","entered_halalas":0},{"key":"pos","entered_halalas":0},{"key":"bank_transfer","entered_halalas":0}]'::jsonb)),f.u);cid:=(j->'result'->>'id')::uuid;
 perform pg_temp.sg_check('save create exact '||f.n,j->'result'->>'version'='1' and exists(select 1 from day_closings where id=cid and status='draft' and created_by=f.s and updated_by=f.s and business_date=current_date-2 and note='DC new draft') and pg_temp.sg_delta(b,'day_closings',1,0,0) and pg_temp.sg_delta(b,'day_closing_lines',3,0,0) and pg_temp.sg_delta(b,'audit_events',1,0,0) and pg_temp.dc_audit(b,f.org,f.b,f.s,cid,'day_closing.created') and pg_temp.sg_tables(b,array['day_closings','day_closing_lines','audit_events']));
 insert into staff_page_access(staff_id,organization_id,enabled,page_grants) values(f.s,f.org,true,'{}');
 perform pg_temp.sg_deny(format('select fn_day_closing_save(%L::jsonb)',jsonb_build_object('branch_id',f.b,'business_date',current_date-3)),f.u,'save no page '||f.n);
 perform pg_temp.sg_deny(format('select fn_day_closing_review(%L)',cid),f.u,'review no page '||f.n);
 perform pg_temp.sg_deny(format('select fn_day_closing_submit(%L,1,''x'')',cid),f.u,'submit no page '||f.n);
 perform pg_temp.sg_deny(format('select fn_day_closing_amend(%L::jsonb)',jsonb_build_object('id',m.cid,'version',5,'reason','test')),f.u,'amend no page '||f.n);
 perform pg_temp.sg_deny(format('select fn_day_closing_request_edit(%L,''test'')',m.cid),f.u,'request no page '||f.n);
 perform pg_temp.sg_deny(format('select fn_day_closing_decide(%L,true,''test'')',m.req),f.u,'decide no page '||f.n);
 delete from staff_page_access where staff_id=f.s;
 end loop;end $$;
select name,ok from sg_results order by name;
select count(*) as passed_checks,bool_and(ok) as all_ok from sg_results;
set constraints all immediate;
rollback;
