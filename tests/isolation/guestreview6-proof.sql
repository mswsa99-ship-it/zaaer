\set ON_ERROR_STOP on
begin;
set local app.identity_key='guestreview6-synthetic-only';
do $$begin
 if exists(select 1 from public.whatsapp_outbox) then raise exception 'requires empty disposable outbox';end if;
 if exists(select 1 from public.branch_whatsapp_channels where enabled or bridge_key_hash is not null) then raise exception 'requires no enabled/keyed channels';end if;
end $$;
create temp table sg_results(name text,ok boolean not null);
create temp table sg_fx(n int,org uuid,b uuid,s uuid,u uuid,r uuid,g uuid,c uuid,oc uuid,review uuid,alert uuid,cat uuid);
insert into organizations(id,name_ar,guest_slug) values('e2260000-0000-0000-0000-000000000001','SG A','sgb6-a'),('e2260000-0000-0000-0000-000000000002','SG B','sgb6-b');
do $$ declare n int;o uuid;b uuid;s uuid;u uuid;r uuid;g uuid;c uuid;oc uuid;ri uuid;al uuid;cat uuid;rm uuid; begin
 for n in 1..4 loop
 o:=('e2260000-0000-0000-0000-'||lpad((case when n<=2 then 1 else 2 end)::text,12,'0'))::uuid;
 b:=('e2261000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid;s:=('e2262000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid;u:=('e2263000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid;
 insert into branches(id,organization_id,name_ar) values(b,o,'SG branch '||n);
 insert into staff_profiles(id,auth_user_id,organization_id,full_name,email,role) values(s,u,o,'SG Manager','sgb6-'||n||'@invalid.test','manager');
 insert into branch_memberships(staff_id,branch_id) values(s,b);
 insert into room_categories(organization_id,branch_id,name_ar,base_price_halalas) values(o,b,'SG Category',10000) returning id into cat;
 insert into rooms(organization_id,branch_id,category_id,room_number) values(o,b,cat,'SGB-'||n) returning id into rm;
 insert into reservations(organization_id,branch_id,room_id,check_in,check_out,status,actual_check_in) values(o,b,rm,current_date-2,current_date,'checked_in',now()-interval '2 days') returning id into r;
 insert into guest_profiles(organization_id,full_name,phone) values(o,'SG Guest '||n,'+96655191000'||n) returning id into g;
 insert into reservation_guests(reservation_id,guest_profile_id,is_primary,full_name,phone) values(r,g,true,'SG Guest '||n,'+96655191000'||n);
 insert into conversations(organization_id,branch_id,channel) values(o,b,'screen') returning id into c;
 insert into ai_ops_conversations(organization_id,branch_id,staff_id) values(o,b,s) returning id into oc;
 insert into review_items(organization_id,branch_id,kind,entity_type,entity_id,summary) values(o,b,'sgb6','reservation',r,'SG Review') returning id into ri;
 insert into alert_events(organization_id,branch_id,event,ref_key,title) values(o,b,'guest_handoff','sgb6-'||n,'SG Alert') returning id into al;
 insert into inventory_periods(organization_id,branch_id,category_id,date,total_units) values(o,b,cat,current_date+20,5);
 insert into release_rules(organization_id,branch_id,category_id,enabled,initial_public_release,release_increment) values(o,b,cat,true,1,1);
 insert into sg_fx values(n,o,b,s,u,r,g,c,oc,ri,al,cat);
 end loop;
end $$;
-- Separate owner, no external configuration or sender channels.
insert into staff_profiles(id,auth_user_id,organization_id,full_name,email,role) values
 ('e2262000-0000-0000-0000-000000000011','e2263000-0000-0000-0000-000000000011','e2260000-0000-0000-0000-000000000001','SG Owner A','sgb6-owner-a@invalid.test','owner'),
 ('e2262000-0000-0000-0000-000000000012','e2263000-0000-0000-0000-000000000012','e2260000-0000-0000-0000-000000000002','SG Owner B','sgb6-owner-b@invalid.test','owner');
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
create function pg_temp.sg_tables(before_j jsonb,allowed text[]) returns boolean language sql as $$select not exists(select 1 from jsonb_each(pg_temp.sg_snap()) e where e.value is distinct from before_j->e.key and not(e.key=any(allowed)))$$;
-- Exact foreign and wrong-branch calls use the SAME staff credential as the positive.
create function pg_temp.sg_deny(q text,uid uuid,label text) returns void language plpgsql as $$declare b jsonb;j jsonb;begin b:=pg_temp.sg_snap();j:=pg_temp.sg_try(q,uid);perform pg_temp.sg_check(label,not(j->>'ok')::boolean and pg_temp.sg_snap()=b);end $$;
create temp table sg_baseline as select pg_temp.sg_snap() j;
create function pg_temp.sg_delta(b jsonb,t text,adds int,updates int,dels int) returns boolean language plpgsql as $$declare a jsonb;na int;nu int;nd int;begin
 a:=pg_temp.sg_snap()->t;
 with old as(select coalesce(x->>'id',x->>'token',x->>'branch_id') k,x from jsonb_array_elements(b->t)x),new as(select coalesce(x->>'id',x->>'token',x->>'branch_id') k,x from jsonb_array_elements(a)x)
 select count(*) filter(where old.k is null),count(*) filter(where old.k is not null and new.k is not null and old.x<>new.x),count(*) filter(where new.k is null) into na,nu,nd from old full join new using(k);
 if (na,nu,nd)<>(adds,updates,dels) then raise notice 'DELTA % actual %/%/% expected %/%/%',t,na,nu,nd,adds,updates,dels;end if;return (na,nu,nd)=(adds,updates,dels);end $$;
-- Explicit safe skip configuration, not an outbound service credential.
insert into branch_journey_settings(branch_id,organization_id,journey_enabled,free_checkout_until) select b,org,false,'23:59:59'::time from sg_fx on conflict(branch_id) do update set journey_enabled=false,free_checkout_until='23:59:59';
update alert_rules set enabled=false where organization_id in(select org from sg_fx);
create temp table gb_fx(n int,regtok text,reviewtok text,reviewid uuid,guestid uuid,ticket uuid);
do $$declare f record;gr uuid;gu uuid;ti uuid;begin
 for f in select * from sg_fx loop
 update reservations set external_ref='SGB6-REF-'||f.n where id=f.r;
 insert into registration_sessions(reservation_id,token) values(f.r,'SGB6-REG-'||f.n);
 insert into guest_reviews(organization_id,branch_id,reservation_id,token_hash) values(f.org,f.b,f.r,encode(extensions.digest('SGB6-REVIEW-'||f.n,'sha256'),'hex')) returning id into gr;
 select id into gu from reservation_guests where reservation_id=f.r and is_primary;
 insert into human_handoff_tickets(organization_id,branch_id,reservation_id,kind) values(f.org,f.b,f.r,'unmatched_reservation') returning id into ti;
 insert into alert_events(organization_id,branch_id,event,ref_key,title,reservation_id) values(f.org,f.b,'review_low','review:'||gr,'SGB6 Review alert',f.r),(f.org,f.b,'guest_handoff','handoff:'||ti,'SGB6 Ticket alert',f.r);
 insert into gb_fx values(f.n,'SGB6-REG-'||f.n,'SGB6-REVIEW-'||f.n,gr,gu,ti);
 end loop;
end $$;
-- Low marks execute review alert evaluation; alert rules are explicitly disabled, therefore no dispatch path.
do $$declare f record;d record;x record;g record;dg record;xg record;b jsonb;j jsonb;slug text;other_slug text;payload jsonb;begin
 for f in select * from sg_fx order by n loop
 select * into g from gb_fx where n=f.n;
 select * into d from sg_fx where n=case when f.n%2=1 then f.n+1 else f.n-1 end;
 select * into dg from gb_fx where n=d.n;
 select * into x from sg_fx where n=case when f.n<=2 then f.n+2 else f.n-2 end;
 select * into xg from gb_fx where n=x.n;
 slug:=case when f.n<=2 then 'sgb6-a' else 'sgb6-b' end;other_slug:=case when f.n<=2 then 'sgb6-b' else 'sgb6-a' end;
 payload:='{"overall":4,"staff":5,"cleanliness":6,"comfort":7,"facilities":8,"value":9,"location":10,"comment":"Synthetic review"}';
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_public_submit_review(%L,%L::jsonb)',g.reviewtok,payload),null,other_slug);
 perform pg_temp.sg_check('review same bearer wrong hotel header '||f.n,not(j->>'ok')::boolean and pg_temp.sg_snap()=b);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_public_submit_review(%L,''{"overall":0}'')',g.reviewtok),null,slug);
 perform pg_temp.sg_check('review invalid marks no write '||f.n,not(j->>'ok')::boolean and pg_temp.sg_snap()=b);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_public_submit_review(%L,%L::jsonb)',g.reviewtok,payload),null,slug);
 perform pg_temp.sg_check('review submit exact '||f.n,(j->>'ok')::boolean and exists(select 1 from guest_reviews where id=g.reviewid and submitted_at is not null and overall=4 and staff=5 and cleanliness=6 and comfort=7 and facilities=8 and value=9 and location=10 and comment='Synthetic review' and version=2) and pg_temp.sg_delta(b,'guest_reviews',0,1,0) and pg_temp.sg_tables(b,array['guest_reviews']));
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_public_submit_review(%L,%L::jsonb)',g.reviewtok,payload),null,slug);
 perform pg_temp.sg_check('review replay no write '||f.n,not(j->>'ok')::boolean and pg_temp.sg_snap()=b);
 perform pg_temp.sg_deny(format('select fn_staff_review_reply(%L,''reply'',2)',dg.reviewid),f.u,'reply wrong branch '||f.n);
 perform pg_temp.sg_deny(format('select fn_staff_review_reply(%L,''reply'',2)',xg.reviewid),f.u,'reply foreign hotel '||f.n);
 perform pg_temp.sg_deny(format('select fn_staff_review_reply(%L,''reply'',1)',g.reviewid),f.u,'reply stale version '||f.n);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_staff_review_reply(%L,''Synthetic reply'',2)',g.reviewid),f.u);
 perform pg_temp.sg_check('reply exact safe skip '||f.n,(j->>'ok')::boolean and exists(select 1 from guest_reviews where id=g.reviewid and reply='Synthetic reply' and replied_by=f.s and version=3) and exists(select 1 from journey_messages where reservation_id=f.r and kind='review_reply' and status='skipped' and reason='journey_off' and ref_key=g.reviewid::text) and pg_temp.sg_delta(b,'guest_reviews',0,1,0) and pg_temp.sg_delta(b,'journey_messages',1,0,0) and pg_temp.sg_delta(b,'audit_events',1,0,0) and pg_temp.sg_delta(b,'alert_events',0,1,0) and exists(select 1 from alert_events where ref_key='review:'||g.reviewid and resolved_how='auto' and resolved_at is not null) and pg_temp.sg_tables(b,array['guest_reviews','journey_messages','audit_events','alert_events']));
 -- Ticket API returns ok:false for filtered explicit foreign targets, no silent target success.
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_staff_resolve_ticket(%L)',dg.ticket),f.u);
 perform pg_temp.sg_check('ticket wrong branch no write '||f.n,j->'result'->>'ok'='false' and pg_temp.sg_snap()=b);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_staff_resolve_ticket(%L)',xg.ticket),f.u);
 perform pg_temp.sg_check('ticket foreign hotel no write '||f.n,j->'result'->>'ok'='false' and pg_temp.sg_snap()=b);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_staff_resolve_ticket(%L)',g.ticket),f.u);
 perform pg_temp.sg_check('ticket exact resolve '||f.n,j->'result'->>'ok'='true' and exists(select 1 from human_handoff_tickets where id=g.ticket and status='resolved' and resolved_by=f.s and resolved_at is not null) and pg_temp.sg_delta(b,'human_handoff_tickets',0,1,0) and pg_temp.sg_delta(b,'alert_events',0,1,0) and exists(select 1 from alert_events where ref_key='handoff:'||g.ticket and resolved_how='auto' and resolved_at is not null) and pg_temp.sg_tables(b,array['human_handoff_tickets','alert_events']));
 end loop;end $$;
do $$declare f record;d record;x record;g record;dg record;xg record;b jsonb;j jsonb;slug text;other_slug text;payload jsonb;begin
 for f in select * from sg_fx order by n loop
 select * into g from gb_fx where n=f.n;
 select * into d from sg_fx where n=case when f.n%2=1 then f.n+1 else f.n-1 end;
 select * into dg from gb_fx where n=d.n;
 select * into x from sg_fx where n=case when f.n<=2 then f.n+2 else f.n-2 end;
 select * into xg from gb_fx where n=x.n;
 slug:=case when f.n<=2 then 'sgb6-a' else 'sgb6-b' end;other_slug:=case when f.n<=2 then 'sgb6-b' else 'sgb6-a' end;
 -- Explicit four-part booking credential; authenticated grant is intentional, anon is not granted.
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_guest_lookup(%L,%L,null,''sgb-device'')','SGB6-REF-'||f.n,'000'||f.n),null,slug);
 perform pg_temp.sg_check('lookup anon grant denied '||f.n,not(j->>'ok')::boolean and pg_temp.sg_snap()=b);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_guest_lookup(%L,''9999'',null,''sgb-device'')','SGB6-REF-'||f.n),f.u,slug);
 perform pg_temp.sg_check('lookup wrong phone exact '||f.n,j->'result'->>'status'='mismatch' and pg_temp.sg_delta(b,'guest_lookup_attempts',1,0,0) and pg_temp.sg_tables(b,array['guest_lookup_attempts']));
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_guest_lookup(%L,%L,null,''sgb-device'')','SGB6-REF-'||x.n,'000'||f.n),f.u,slug);
 perform pg_temp.sg_check('lookup foreign reference exact '||f.n,j->'result'->>'status'='unmatched' and exists(select 1 from human_handoff_tickets where organization_id=f.org and branch_id is null and external_ref='SGB6-REF-'||x.n and kind='unmatched_reservation') and pg_temp.sg_delta(b,'guest_lookup_attempts',1,0,0) and pg_temp.sg_delta(b,'human_handoff_tickets',1,0,0) and pg_temp.sg_tables(b,array['guest_lookup_attempts','human_handoff_tickets']));
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_guest_lookup(%L,%L,null,''sgb-device'')','SGB6-REF-'||f.n,'000'||f.n),f.u,slug);
 perform pg_temp.sg_check('lookup exact positive '||f.n,j->'result'->>'status'='ok' and exists(select 1 from registration_sessions where token=j->'result'->>'token' and reservation_id=f.r) and pg_temp.sg_delta(b,'guest_lookup_attempts',1,0,0) and pg_temp.sg_delta(b,'registration_sessions',1,0,0) and pg_temp.sg_delta(b,'audit_events',1,0,0) and pg_temp.sg_tables(b,array['guest_lookup_attempts','registration_sessions','audit_events']));
 payload:=jsonb_build_object('full_name','Synthetic Guest','identity_type','passport','identity_number','SGB000'||f.n,'nationality','SA','birth_date','1990-01-01','phone','055191000'||f.n,'consent',true,'ack_hash',fn_stay_summary_internal(f.r)->>'hash');
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_guest_submit(%L,%L,%L::jsonb)',g.regtok,dg.guestid,payload),null,slug);
 perform pg_temp.sg_check('submit same token wrong guest '||f.n,not(j->>'ok')::boolean and pg_temp.sg_snap()=b);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_guest_submit(%L,%L,%L::jsonb)',g.regtok,xg.guestid,payload),null,slug);
 perform pg_temp.sg_check('submit same token foreign guest '||f.n,not(j->>'ok')::boolean and pg_temp.sg_snap()=b);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_guest_submit(%L,%L,%L::jsonb)',g.regtok,g.guestid,payload),null,other_slug);
 perform pg_temp.sg_check('submit same token wrong hotel header '||f.n,not(j->>'ok')::boolean and pg_temp.sg_snap()=b);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_guest_submit(%L,%L,%L::jsonb)',g.regtok,g.guestid,payload),null,slug);
 perform pg_temp.sg_check('submit exact positive '||f.n,j->'result'->>'guest_id'=g.guestid::text and exists(select 1 from reservation_guests where id=g.guestid and full_name='Synthetic Guest' and identity_number_last4=right('SGB000'||f.n,4) and data_submitted and verification_status='data_submitted' and identity_number_encrypted is not null and identity_fingerprint=fn_identity_fingerprint('passport','SGB000'||f.n)) and exists(select 1 from reservations where id=f.r and identity_status='pending_supervisor') and exists(select 1 from stay_acknowledgements where reservation_id=f.r and method='electronic' and recorded_by is null and text_hash=payload->>'ack_hash') and pg_temp.sg_delta(b,'reservation_guests',0,1,0) and pg_temp.sg_delta(b,'reservations',0,1,0) and pg_temp.sg_delta(b,'stay_acknowledgements',1,0,0) and pg_temp.sg_delta(b,'notifications',1,0,0) and pg_temp.sg_delta(b,'audit_events',1,0,0) and pg_temp.sg_tables(b,array['reservation_guests','reservations','stay_acknowledgements','notifications','audit_events']));
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_guest_checkout_choose(%L,''on_time'',null,''page'')',g.regtok),null,other_slug);
 perform pg_temp.sg_check('checkout same token wrong hotel header '||f.n,not(j->>'ok')::boolean and pg_temp.sg_snap()=b);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_guest_checkout_choose(%L,''invalid'',null,''page'')',g.regtok),null,slug);
 perform pg_temp.sg_check('checkout invalid no write '||f.n,not(j->>'ok')::boolean and pg_temp.sg_snap()=b);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_guest_checkout_choose(%L,''on_time'',null,''page'')',g.regtok),null,slug);
 perform pg_temp.sg_check('checkout exact positive '||f.n,j->'result'->>'choice'='on_time' and j->'result'->>'open'='true' and exists(select 1 from reservations where id=f.r and checkout_choice='on_time' and checkout_choice_at is not null) and pg_temp.sg_delta(b,'reservations',0,1,0) and pg_temp.sg_delta(b,'audit_events',1,0,0) and pg_temp.sg_tables(b,array['reservations','audit_events']));
 end loop;end $$;
-- Explicit page-denied same objects; invalid versions do not stand in for tenant denial.
do $$declare f record;g record;b jsonb;j jsonb;begin
 for f in select * from sg_fx order by n loop
 select * into g from gb_fx where n=f.n;
 insert into staff_page_access(staff_id,organization_id,enabled,page_grants) values(f.s,f.org,true,'{}');
 perform pg_temp.sg_deny(format('select fn_staff_review_reply(%L,''page test'',3)',g.reviewid),f.u,'reply explicit page denied '||f.n);
 perform pg_temp.sg_deny(format('select fn_staff_resolve_ticket(%L)',g.ticket),f.u,'ticket explicit page denied '||f.n);
 delete from staff_page_access where staff_id=f.s;
 end loop;end $$;
select name,ok from sg_results order by name;
select count(*) as passed_checks,bool_and(ok) as all_ok from sg_results;
rollback;
