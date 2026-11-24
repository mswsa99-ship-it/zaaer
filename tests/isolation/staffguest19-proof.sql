\set ON_ERROR_STOP on
begin;
set local app.identity_key='staffguest19-synthetic-only';
do $$begin
 if exists(select 1 from public.whatsapp_outbox) then raise exception 'requires empty disposable outbox';end if;
 if exists(select 1 from public.branch_whatsapp_channels where enabled or bridge_key_hash is not null) then raise exception 'requires no enabled/keyed channels';end if;
end $$;
create temp table sg_results(name text,ok boolean not null);
create temp table sg_fx(n int,org uuid,b uuid,s uuid,u uuid,r uuid,g uuid,c uuid,oc uuid,review uuid,alert uuid,cat uuid);
insert into organizations(id,name_ar,guest_slug) values('e2190000-0000-0000-0000-000000000001','SG A','sg19-a'),('e2190000-0000-0000-0000-000000000002','SG B','sg19-b');
do $$ declare n int;o uuid;b uuid;s uuid;u uuid;r uuid;g uuid;c uuid;oc uuid;ri uuid;al uuid;cat uuid; begin
 for n in 1..4 loop
 o:=('e2190000-0000-0000-0000-'||lpad((case when n<=2 then 1 else 2 end)::text,12,'0'))::uuid;
 b:=('e2191000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid;s:=('e2192000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid;u:=('e2193000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid;
 insert into branches(id,organization_id,name_ar) values(b,o,'SG branch '||n);
 insert into staff_profiles(id,auth_user_id,organization_id,full_name,email,role) values(s,u,o,'SG Manager','sg19-'||n||'@invalid.test','manager');
 insert into branch_memberships(staff_id,branch_id) values(s,b);
 insert into room_categories(organization_id,branch_id,name_ar,base_price_halalas) values(o,b,'SG Category',10000) returning id into cat;
 insert into reservations(organization_id,branch_id,check_in,check_out,status,actual_check_in) values(o,b,current_date-2,current_date,'checked_in',now()-interval '2 days') returning id into r;
 insert into guest_profiles(organization_id,full_name,phone) values(o,'SG Guest '||n,'+96655191000'||n) returning id into g;
 insert into reservation_guests(reservation_id,guest_profile_id,is_primary,full_name,phone) values(r,g,true,'SG Guest '||n,'+96655191000'||n);
 insert into conversations(organization_id,branch_id,channel) values(o,b,'screen') returning id into c;
 insert into ai_ops_conversations(organization_id,branch_id,staff_id) values(o,b,s) returning id into oc;
 insert into review_items(organization_id,branch_id,kind,entity_type,entity_id,summary) values(o,b,'sg19','reservation',r,'SG Review') returning id into ri;
 insert into alert_events(organization_id,branch_id,event,ref_key,title) values(o,b,'guest_handoff','sg19-'||n,'SG Alert') returning id into al;
 insert into inventory_periods(organization_id,branch_id,category_id,date,total_units) values(o,b,cat,current_date+20,5);
 insert into release_rules(organization_id,branch_id,category_id,enabled,initial_public_release,release_increment) values(o,b,cat,true,1,1);
 insert into sg_fx values(n,o,b,s,u,r,g,c,oc,ri,al,cat);
 end loop;
end $$;
-- Separate owner, no external configuration or sender channels.
insert into staff_profiles(id,auth_user_id,organization_id,full_name,email,role) values
 ('e2192000-0000-0000-0000-000000000011','e2193000-0000-0000-0000-000000000011','e2190000-0000-0000-0000-000000000001','SG Owner A','sg19-owner-a@invalid.test','owner'),
 ('e2192000-0000-0000-0000-000000000012','e2193000-0000-0000-0000-000000000012','e2190000-0000-0000-0000-000000000002','SG Owner B','sg19-owner-b@invalid.test','owner');
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
do $$declare f record;d record;b jsonb;j jsonb;pid uuid;vid uuid;own uuid; begin
 for f in select * from sg_fx order by n loop
 select * into d from sg_fx where n=case when f.n%2=1 then f.n+1 else f.n-1 end;
 -- AI propose has an explicit own-conversation credential, not a staff-owner fallback.
 perform pg_temp.sg_deny(format('select fn_ai_ops_propose(%L,''create_task'',''{}'',''safe proposal'')',d.oc),f.u,'propose foreign conversation '||f.n);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_ai_ops_propose(%L,''create_task'',''{"synthetic":true}'',''safe proposal'')',f.oc),f.u);pid:=(j->'result'->>'proposal_id')::uuid;
 perform pg_temp.sg_check('propose exact '||f.n,(j->>'ok')::boolean and exists(select 1 from ai_action_proposals where id=pid and staff_id=f.s and conversation_id=f.oc and branch_id=f.b and status='proposed' and action='create_task' and args='{"synthetic":true}') and pg_temp.sg_delta(b,'ai_action_proposals',1,0,0) and pg_temp.sg_tables(b,array['ai_action_proposals']));
 perform pg_temp.sg_deny(format('select fn_ai_ops_reject_proposal(%L,''reject'')',pid),d.u,'reject other staff '||f.n);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_ai_ops_reject_proposal(%L,''test refusal'')',pid),f.u);
 perform pg_temp.sg_check('reject exact '||f.n,(j->>'ok')::boolean and exists(select 1 from ai_action_proposals where id=pid and status='rejected' and decided_by=f.s and error='test refusal') and pg_temp.sg_delta(b,'ai_action_proposals',0,1,0) and pg_temp.sg_tables(b,array['ai_action_proposals']));
 perform pg_temp.sg_deny(format('select fn_ai_ops_reject_proposal(%L,''twice'')',pid),f.u,'reject repeated not found '||f.n);
 -- Saved views create/update/remove are caller-owned; same screen/name decoy in another staff account.
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try('select fn_saved_view_save(''{"screen":"reservations","name":"SG view","filters":{"status":"confirmed"}}'')',f.u);vid:=(j->'result'->>'id')::uuid;
 perform pg_temp.sg_check('saved create exact '||f.n,(j->>'ok')::boolean and exists(select 1 from staff_saved_views where id=vid and staff_id=f.s and filters='{"status":"confirmed"}') and pg_temp.sg_delta(b,'staff_saved_views',1,0,0) and pg_temp.sg_tables(b,array['staff_saved_views']));
 perform pg_temp.sg_deny(format('select fn_saved_view_save(%L::jsonb)',jsonb_build_object('id',vid,'screen','reservations','name','hijack')),d.u,'saved update foreign '||f.n);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_saved_view_save(%L::jsonb)',jsonb_build_object('id',vid,'screen','reservations','name','SG edited','filters',jsonb_build_object('status','checked_in'))),f.u);
 perform pg_temp.sg_check('saved update exact '||f.n,(j->>'ok')::boolean and exists(select 1 from staff_saved_views where id=vid and name='SG edited' and filters='{"status":"checked_in"}') and pg_temp.sg_delta(b,'staff_saved_views',0,1,0) and pg_temp.sg_tables(b,array['staff_saved_views']));
 perform pg_temp.sg_deny(format('select fn_saved_view_remove(%L)',vid),d.u,'saved remove foreign '||f.n);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_saved_view_remove(%L)',vid),f.u);
 perform pg_temp.sg_check('saved remove exact '||f.n,(j->>'ok')::boolean and exists(select 1 from staff_saved_views where id=vid and archived_at is not null and not is_default) and pg_temp.sg_delta(b,'staff_saved_views',0,1,0) and pg_temp.sg_tables(b,array['staff_saved_views']));
 perform pg_temp.sg_deny(format('select fn_saved_view_remove(%L)',vid),f.u,'saved repeated remove '||f.n);
 -- Audit only: does not send an email or change credentials.
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try('select fn_auth_event(''security.signed_in'',null)',f.u);
 perform pg_temp.sg_check('auth log exact '||f.n,(j->>'ok')::boolean and pg_temp.sg_delta(b,'audit_events',1,0,0) and exists(select 1 from audit_events where actor_id=f.s and entity_id=f.s and action='security.signed_in' and category='security') and pg_temp.sg_tables(b,array['audit_events']));
 perform pg_temp.sg_deny(format('select fn_auth_event(''security.password_link_sent'',%L)',d.s),f.u,'auth foreign target '||f.n);
 perform pg_temp.sg_deny('select fn_auth_event(''invalid'',null)',f.u,'auth invalid action '||f.n);
 -- Screen conversations never hit the WhatsApp contact-burst trigger branch or any sender.
 perform pg_temp.sg_deny(format('select fn_conversation_take(%L,true)',d.c),f.u,'conversation foreign branch '||f.n);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_conversation_take(%L,true)',f.c),f.u);
 perform pg_temp.sg_check('conversation take exact '||f.n,(j->>'ok')::boolean and exists(select 1 from conversations where id=f.c and status='handed_off' and human_active_until is null) and pg_temp.sg_delta(b,'conversations',0,1,0) and pg_temp.sg_delta(b,'audit_events',1,0,0) and pg_temp.sg_tables(b,array['conversations','audit_events']));
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_conversation_take(%L,false)',f.c),f.u);
 perform pg_temp.sg_check('conversation return exact '||f.n,(j->>'ok')::boolean and exists(select 1 from conversations where id=f.c and status='active' and handed_off_at is null) and pg_temp.sg_delta(b,'conversations',0,1,0) and pg_temp.sg_delta(b,'audit_events',1,0,0) and pg_temp.sg_tables(b,array['conversations','audit_events']));
 -- Page-wrapped alert resolution, with no message dispatch.
 perform pg_temp.sg_deny(format('select fn_staff_alert_resolve(%L,''test'')',d.alert),f.u,'alert foreign branch '||f.n);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_staff_alert_resolve(%L,''resolved locally'')',f.alert),f.u);
 perform pg_temp.sg_check('alert resolve exact '||f.n,(j->>'ok')::boolean and exists(select 1 from alert_events where id=f.alert and resolved_by=f.s and resolved_how='staff') and pg_temp.sg_delta(b,'alert_events',0,1,0) and pg_temp.sg_delta(b,'audit_events',1,0,0) and pg_temp.sg_tables(b,array['alert_events','audit_events']));
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_staff_alert_resolve(%L,''again'')',f.alert),f.u);
 perform pg_temp.sg_check('alert repeat no write '||f.n,j->'result'->>'already'='true' and pg_temp.sg_snap()=b);
 end loop;
end $$;
do $$declare f record;d record;b jsonb;j jsonb;bid uuid;iid uuid;h text;begin
 for f in select * from sg_fx order by n loop
 select * into d from sg_fx where n=case when f.n%2=1 then f.n+1 else f.n-1 end;
 perform pg_temp.sg_deny(format('select fn_guest_rate(%L::jsonb)',jsonb_build_object('profile_id',d.g,'rating',3)),f.u,'rate foreign branch '||f.n);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_guest_rate(%L::jsonb)',jsonb_build_object('profile_id',f.g,'rating',4,'note','synthetic note')),f.u);
 perform pg_temp.sg_check('rate exact '||f.n,(j->>'ok')::boolean and exists(select 1 from guest_profiles where id=f.g and rating=4 and rating_note='synthetic note' and rated_by=f.s) and pg_temp.sg_delta(b,'guest_profiles',0,1,0) and pg_temp.sg_delta(b,'audit_events',1,0,0) and pg_temp.sg_tables(b,array['guest_profiles','audit_events']));
 perform pg_temp.sg_deny(format('select fn_guest_rate(%L::jsonb)',jsonb_build_object('profile_id',f.g,'rating',6)),f.u,'rate invalid '||f.n);
 perform pg_temp.sg_deny(format('select fn_guest_ban(%L::jsonb)',jsonb_build_object('profile_id',d.g,'ban',true,'reason','test')),f.u,'ban foreign branch '||f.n);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_guest_ban(%L::jsonb)',jsonb_build_object('profile_id',f.g,'ban',true,'reason','synthetic ban')),f.u);bid:=(j->'result'->>'ban_id')::uuid;
 perform pg_temp.sg_check('ban exact '||f.n,(j->>'ok')::boolean and exists(select 1 from guest_bans where id=bid and guest_profile_id=f.g and created_by=f.s and reason='synthetic ban' and lifted_at is null) and pg_temp.sg_delta(b,'guest_bans',1,0,0) and pg_temp.sg_delta(b,'audit_events',1,0,0) and pg_temp.sg_delta(b,'review_items',1,0,0) and pg_temp.sg_tables(b,array['guest_bans','audit_events','review_items']));
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_guest_ban(%L::jsonb)',jsonb_build_object('profile_id',f.g,'ban',true,'reason','synthetic ban')),f.u);
 perform pg_temp.sg_check('ban duplicate no write '||f.n,j->'result'->>'duplicate'='true' and pg_temp.sg_snap()=b);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_guest_ban(%L::jsonb)',jsonb_build_object('profile_id',f.g,'ban',false,'reason','synthetic lift')),f.u);
 perform pg_temp.sg_check('lift exact '||f.n,(j->>'ok')::boolean and exists(select 1 from guest_bans where id=bid and lifted_by=f.s and lift_reason='synthetic lift') and pg_temp.sg_delta(b,'guest_bans',0,1,0) and pg_temp.sg_delta(b,'audit_events',1,0,0) and pg_temp.sg_delta(b,'review_items',1,0,0) and pg_temp.sg_tables(b,array['guest_bans','audit_events','review_items']));
 perform pg_temp.sg_deny(format('select fn_staff_record_inspection(%L::jsonb)',jsonb_build_object('reservation_id',d.r,'result','ok')),f.u,'inspection foreign branch '||f.n);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_staff_record_inspection(%L::jsonb)',jsonb_build_object('reservation_id',f.r,'result','ok')),f.u);iid:=(j->'result'->>'id')::uuid;
 perform pg_temp.sg_check('inspection exact '||f.n,(j->>'ok')::boolean and exists(select 1 from checkout_inspections where id=iid and reservation_id=f.r and status='active' and result='ok' and inspected_by=f.s and suggested_deduction_halalas=0) and pg_temp.sg_delta(b,'checkout_inspections',1,0,0) and pg_temp.sg_delta(b,'audit_events',1,0,0) and pg_temp.sg_tables(b,array['checkout_inspections','audit_events']));
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_staff_record_inspection(%L::jsonb)',jsonb_build_object('reservation_id',f.r,'result','ok')),f.u);
 perform pg_temp.sg_check('inspection supersede exact '||f.n,(j->>'ok')::boolean and exists(select 1 from checkout_inspections where id=iid and status='superseded' and superseded_by=f.s) and (select count(*) from checkout_inspections where reservation_id=f.r and status='active')=1 and pg_temp.sg_delta(b,'checkout_inspections',1,1,0) and pg_temp.sg_delta(b,'audit_events',1,0,0) and pg_temp.sg_tables(b,array['checkout_inspections','audit_events']));
 h:=fn_stay_summary_internal(f.r)->>'hash';
 perform pg_temp.sg_deny(format('select fn_staff_record_paper_ack(%L::jsonb)',jsonb_build_object('reservation_id',d.r,'text_hash',h)),f.u,'paper ack foreign branch '||f.n);
 perform pg_temp.sg_deny(format('select fn_staff_record_paper_ack(%L::jsonb)',jsonb_build_object('reservation_id',f.r,'text_hash','bad')),f.u,'paper ack invalid hash '||f.n);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_staff_record_paper_ack(%L::jsonb)',jsonb_build_object('reservation_id',f.r,'text_hash',h)),f.u);
 perform pg_temp.sg_check('paper ack exact '||f.n,j->'result'->>'duplicate'='false' and exists(select 1 from stay_acknowledgements where reservation_id=f.r and method='paper' and text_hash=h and recorded_by=f.s and text_snapshot=fn_stay_summary_internal(f.r)->>'text') and pg_temp.sg_delta(b,'stay_acknowledgements',1,0,0) and pg_temp.sg_delta(b,'audit_events',1,0,0) and pg_temp.sg_tables(b,array['stay_acknowledgements','audit_events']));
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_staff_record_paper_ack(%L::jsonb)',jsonb_build_object('reservation_id',f.r,'text_hash',h)),f.u);
 perform pg_temp.sg_check('paper ack duplicate no write '||f.n,j->'result'->>'duplicate'='true' and pg_temp.sg_snap()=b);
 end loop;end $$;
-- Explicit local positive-price ledger prerequisite; checked-in state makes sync-closed return immediately.
insert into reservation_nights(organization_id,branch_id,reservation_id,night,price_halalas,basis)
 select org,b,r,current_date-2,10000,'base' from sg_fx;
insert into reservation_charges(organization_id,branch_id,reservation_id,kind,description,total_halalas,service_from,service_to)
 select org,b,r,'rent','SG literal rent',10000,current_date-2,current_date-1 from sg_fx;
do $$declare f record;d record;b jsonb;j jsonb;begin
 for f in select * from sg_fx order by n loop
 select * into d from sg_fx where n=case when f.n%2=1 then f.n+1 else f.n-1 end;
 perform pg_temp.sg_check('overdue literal prerequisite '||f.n,(fn_stay_due_internal(f.r)->>'overdue')::boolean and (fn_stay_due_internal(f.r)->>'overdue_amount')::bigint=10000);
 perform pg_temp.sg_deny(format('select fn_staff_payment_exception(%L::jsonb)',jsonb_build_object('reservation_id',d.r,'reason','local test')),f.u,'payment exception foreign branch '||f.n);
 perform pg_temp.sg_deny(format('select fn_staff_payment_exception(%L::jsonb)',jsonb_build_object('reservation_id',f.r,'reason','')),f.u,'payment exception invalid reason '||f.n);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_staff_payment_exception(%L::jsonb)',jsonb_build_object('reservation_id',f.r,'reason','local exception')),f.u);
 perform pg_temp.sg_check('payment exception exact '||f.n,(j->>'ok')::boolean and exists(select 1 from stay_payment_exceptions where reservation_id=f.r and through_night=current_date-2 and shortfall_halalas=10000 and reason='local exception' and created_by=f.s) and pg_temp.sg_delta(b,'stay_payment_exceptions',1,0,0) and pg_temp.sg_delta(b,'audit_events',1,0,0) and pg_temp.sg_tables(b,array['stay_payment_exceptions','audit_events']));
 end loop;end $$;
-- Owner-required review pair and availability releases use the true owner identity of each hotel.
do $$declare f record;d record;b jsonb;j jsonb;u uuid;s uuid;begin
 for f in select * from sg_fx where n in (1,3) order by n loop
 select * into d from sg_fx where n=case f.n when 1 then 3 else 1 end;
 select auth_user_id,id into u,s from staff_profiles where organization_id=f.org and role='owner';
 perform pg_temp.sg_deny(format('select fn_review_mark(%L::jsonb)',jsonb_build_object('ids',jsonb_build_array(f.review))),f.u,'review nonowner '||f.n);
 -- A filtered foreign ID is documented as zero marked plus the caller's audit, not as denial/no-write.
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_review_mark(%L::jsonb)',jsonb_build_object('ids',jsonb_build_array(d.review))),u);
 perform pg_temp.sg_check('review foreign filtered '||f.n,j->'result'->>'marked'='0' and pg_temp.sg_delta(b,'audit_events',1,0,0) and pg_temp.sg_tables(b,array['audit_events']));
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_review_mark(%L::jsonb)',jsonb_build_object('ids',jsonb_build_array(f.review),'note','SG reviewed')),u);
 perform pg_temp.sg_check('review mark exact '||f.n,j->'result'->>'marked'='1' and exists(select 1 from review_items where id=f.review and reviewed_by=s and review_note='SG reviewed') and pg_temp.sg_delta(b,'review_items',0,1,0) and pg_temp.sg_delta(b,'audit_events',1,0,0) and pg_temp.sg_tables(b,array['review_items','audit_events']));
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_review_undo(%L::jsonb)',jsonb_build_object('ids',jsonb_build_array(d.review))),u);
 perform pg_temp.sg_check('review undo foreign filtered '||f.n,j->'result'->>'undone'='0' and pg_temp.sg_delta(b,'audit_events',1,0,0) and pg_temp.sg_tables(b,array['audit_events']));
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_review_undo(%L::jsonb)',jsonb_build_object('ids',jsonb_build_array(f.review))),u);
 perform pg_temp.sg_check('review undo exact '||f.n,j->'result'->>'undone'='1' and exists(select 1 from review_items where id=f.review and reviewed_by is null and reviewed_at is null and review_note is null) and pg_temp.sg_delta(b,'review_items',0,1,0) and pg_temp.sg_delta(b,'audit_events',1,0,0) and pg_temp.sg_tables(b,array['review_items','audit_events']));
 perform pg_temp.sg_deny(format('select fn_staff_release_next_slot(%L,%L,current_date+20,''local test'')',d.b,d.cat),u,'release foreign hotel '||f.n);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_staff_release_next_slot(%L,%L,current_date+20,''local test'')',f.b,f.cat),u);
 perform pg_temp.sg_check('release slot exact '||f.n,j->>'result'='2' and exists(select 1 from released_slots where branch_id=f.b and category_id=f.cat and date=current_date+20 and released_count=2) and pg_temp.sg_delta(b,'released_slots',1,0,0) and pg_temp.sg_delta(b,'audit_events',1,0,0) and pg_temp.sg_tables(b,array['released_slots','audit_events']));
 end loop;end $$;
-- Known synthetic hashes only. Never call code generation, delivery, mark-sent, or bridge functions.
insert into guest_phone_challenges(id,phone,code_hash,organization_id,branch_id,send_state)
 select ('e2194000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'96655191000'||n,
 encode(extensions.digest('e2194000-0000-0000-0000-'||lpad(n::text,12,'0')||':194219','sha256'),'hex'),org,b,'failed' from sg_fx;
do $$declare f record;d record;x record;b jsonb;j jsonb;ph text;slug text;tok text;cid uuid;begin
 for f in select * from sg_fx order by n loop
 select * into d from sg_fx where n=case when f.n%2=1 then f.n+1 else f.n-1 end;
 select * into x from sg_fx where n=case when f.n<=2 then f.n+2 else f.n-2 end;
 ph:='96655191000'||f.n;slug:=case when f.n<=2 then 'sg19-a' else 'sg19-b' end;cid:=('e2194000-0000-0000-0000-'||lpad(f.n::text,12,'0'))::uuid;
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_guest_phone_verify(%L,''194219'',null)',ph),null,case when f.n<=2 then 'sg19-b' else 'sg19-a' end);
 perform pg_temp.sg_check('phone verify wrong hotel no write '||f.n,j->'result'->>'status'='expired' and pg_temp.sg_snap()=b);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_guest_phone_verify(%L,''000000'',null)',ph),null,slug);
 perform pg_temp.sg_check('phone verify mismatch exact '||f.n,j->'result'->>'status'='mismatch' and exists(select 1 from guest_phone_challenges where id=cid and attempts=1 and verified_at is null) and pg_temp.sg_delta(b,'guest_phone_challenges',0,1,0) and pg_temp.sg_tables(b,array['guest_phone_challenges']));
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_guest_phone_verify(%L,''194219'',null)',ph),null,slug);tok:=j->'result'->>'token';
 perform pg_temp.sg_check('phone verify exact '||f.n,j->'result'->>'status'='ok' and exists(select 1 from guest_phone_sessions where token=tok and phone=ph and organization_id=f.org and method='whatsapp_code') and exists(select 1 from guest_phone_challenges where id=cid and verified_at is not null and attempts=1) and exists(select 1 from reservation_guests where reservation_id=f.r and phone_verified) and pg_temp.sg_delta(b,'guest_phone_sessions',1,0,0) and pg_temp.sg_delta(b,'guest_phone_challenges',0,1,0) and pg_temp.sg_delta(b,'reservation_guests',0,1,0) and pg_temp.sg_tables(b,array['guest_phone_sessions','guest_phone_challenges','reservation_guests']));
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_guest_phone_open(%L,%L)',tok,(select internal_ref from reservations where id=d.r)),null,slug);
 perform pg_temp.sg_check('phone open same bearer wrong phone '||f.n,not(j->>'ok')::boolean and pg_temp.sg_snap()=b);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_guest_phone_open(%L,%L)',tok,(select internal_ref from reservations where id=x.r)),null,slug);
 perform pg_temp.sg_check('phone open same bearer foreign hotel '||f.n,not(j->>'ok')::boolean and pg_temp.sg_snap()=b);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_guest_phone_open(%L,%L)',tok,(select internal_ref from reservations where id=f.r)),null,slug);
 perform pg_temp.sg_check('phone open exact '||f.n,j->'result'->>'status'='ok' and exists(select 1 from registration_sessions where token=j->'result'->>'token' and reservation_id=f.r and expires_at>now()) and pg_temp.sg_delta(b,'registration_sessions',1,0,0) and pg_temp.sg_delta(b,'audit_events',1,0,0) and pg_temp.sg_tables(b,array['registration_sessions','audit_events']));
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_guest_phone_verify_ref(%L,%L,''sg-device'')',ph,(select internal_ref from reservations where id=d.r)),null,slug);
 perform pg_temp.sg_check('phone ref wrong phone exact attempt '||f.n,j->'result'->>'status'='mismatch' and pg_temp.sg_delta(b,'guest_lookup_attempts',1,0,0) and pg_temp.sg_tables(b,array['guest_lookup_attempts']));
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_guest_phone_verify_ref(%L,%L,''sg-device'')',ph,(select internal_ref from reservations where id=x.r)),null,slug);
 perform pg_temp.sg_check('phone ref foreign hotel exact attempt '||f.n,j->'result'->>'status'='mismatch' and pg_temp.sg_delta(b,'guest_lookup_attempts',1,0,0) and pg_temp.sg_tables(b,array['guest_lookup_attempts']));
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_guest_phone_verify_ref(%L,%L,''sg-device'')',ph,(select internal_ref from reservations where id=f.r)),null,slug);tok:=j->'result'->>'token';
 perform pg_temp.sg_check('phone ref exact '||f.n,j->'result'->>'status'='ok' and exists(select 1 from guest_phone_sessions where token=tok and phone=ph and organization_id=f.org and method='booking_number') and pg_temp.sg_delta(b,'guest_lookup_attempts',1,0,0) and pg_temp.sg_delta(b,'guest_phone_sessions',1,0,0) and pg_temp.sg_tables(b,array['guest_lookup_attempts','guest_phone_sessions']));
 end loop;end $$;
-- Run monitor against deliberate literal ledger mismatch. No integration events/channel rows exist.
do $$declare f record;d record;b jsonb;j jsonb;u uuid;begin
 for f in select * from sg_fx where n in (1,3) order by n loop
 select * into d from sg_fx where n=case f.n when 1 then 3 else 1 end;
 select auth_user_id into u from staff_profiles where organization_id=f.org and role='owner';
 perform pg_temp.sg_deny(format('select fn_monitors_if_due(%L)',d.b),u,'monitors foreign hotel '||f.n);
 perform pg_temp.sg_deny(format('select fn_monitors_if_due(%L)',f.b),f.u,'monitors nonowner '||f.n);
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_monitors_if_due(%L)',f.b),u);
 perform pg_temp.sg_check('monitors exact mismatch '||f.n,j->'result'->>'ran'='true' and j->'result'->'found'='{"ledger_mismatch":1}' and exists(select 1 from review_items where entity_id=f.r and kind='monitor:ledger_mismatch' and branch_id=f.b) and pg_temp.sg_delta(b,'review_items',1,0,0) and pg_temp.sg_delta(b,'monitor_runs',1,0,0) and pg_temp.sg_tables(b,array['review_items','monitor_runs']));
 b:=pg_temp.sg_snap();j:=pg_temp.sg_try(format('select fn_monitors_if_due(%L)',f.b),u);
 perform pg_temp.sg_check('monitors recent no write '||f.n,j->'result'->>'ran'='false' and pg_temp.sg_snap()=b);
 end loop;end $$;
-- Same staff principal against explicit foreign hotel targets, then explicit page/capability denial.
do $$declare f record;x record;j jsonb;b jsonb;v uuid;pv uuid;begin
 for f in select * from sg_fx order by n loop
 select * into x from sg_fx where n=case when f.n<=2 then f.n+2 else f.n-2 end;
 perform pg_temp.sg_deny(format('select fn_ai_ops_propose(%L,''create_task'',''{}'',''test'')',x.oc),f.u,'propose foreign hotel '||f.n);
 insert into ai_action_proposals(organization_id,branch_id,conversation_id,staff_id,action,args,summary) values(x.org,x.b,x.oc,x.s,'create_task','{}','SG foreign fresh') returning id into pv;
 perform pg_temp.sg_deny(format('select fn_ai_ops_reject_proposal(%L,''test'')',pv),f.u,'reject same principal foreign hotel '||f.n);
 insert into staff_saved_views(organization_id,staff_id,screen,name) values(x.org,x.s,'reservations','SG foreign fresh') returning id into pv;
 perform pg_temp.sg_deny(format('select fn_saved_view_remove(%L)',pv),f.u,'remove same principal foreign hotel '||f.n);
 perform pg_temp.sg_deny(format('select fn_saved_view_save(%L::jsonb)',jsonb_build_object('id',pv,'screen','reservations','name','hijack')),f.u,'save same principal foreign hotel '||f.n);
 perform pg_temp.sg_deny(format('select fn_conversation_take(%L,true)',x.c),f.u,'take foreign hotel '||f.n);
 perform pg_temp.sg_deny(format('select fn_guest_rate(%L::jsonb)',jsonb_build_object('profile_id',x.g,'rating',3)),f.u,'rate foreign hotel '||f.n);
 perform pg_temp.sg_deny(format('select fn_guest_ban(%L::jsonb)',jsonb_build_object('profile_id',x.g,'ban',true,'reason','test')),f.u,'ban foreign hotel '||f.n);
 perform pg_temp.sg_deny(format('select fn_staff_record_inspection(%L::jsonb)',jsonb_build_object('reservation_id',x.r,'result','ok')),f.u,'inspection foreign hotel '||f.n);
 perform pg_temp.sg_deny(format('select fn_staff_payment_exception(%L::jsonb)',jsonb_build_object('reservation_id',x.r,'reason','test')),f.u,'exception foreign hotel '||f.n);
 perform pg_temp.sg_deny(format('select fn_staff_record_paper_ack(%L::jsonb)',jsonb_build_object('reservation_id',x.r,'text_hash',fn_stay_summary_internal(x.r)->>'hash')),f.u,'ack foreign hotel '||f.n);
 perform pg_temp.sg_deny(format('select fn_staff_alert_resolve(%L,''test'')',x.alert),f.u,'alert foreign hotel '||f.n);
 perform pg_temp.sg_deny(format('select fn_auth_event(''security.password_link_sent'',%L)',x.s),f.u,'auth foreign hotel '||f.n);
 -- Test-only fixture writes, outside measured RPC effects.
 insert into staff_page_access(staff_id,organization_id,enabled,page_grants) values(f.s,f.org,true,'{}');
 select id into v from ai_action_proposals where staff_id=f.s limit 1;
 perform pg_temp.sg_deny(format('select fn_ai_ops_reject_proposal(%L,''test'')',v),f.u,'reject page denied '||f.n);
 perform pg_temp.sg_deny(format('select fn_staff_alert_resolve(%L,''test'')',f.alert),f.u,'alert page denied '||f.n);
 perform pg_temp.sg_deny(format('select fn_staff_release_next_slot(%L,%L,current_date+20,''test'')',f.b,f.cat),f.u,'slot page denied '||f.n);
 perform pg_temp.sg_deny(format('select fn_guest_rate(%L::jsonb)',jsonb_build_object('profile_id',f.g,'rating',3)),f.u,'rate page denied '||f.n);
 perform pg_temp.sg_deny(format('select fn_guest_ban(%L::jsonb)',jsonb_build_object('profile_id',f.g,'ban',true,'reason','test')),f.u,'ban page denied '||f.n);
 perform pg_temp.sg_deny(format('select fn_staff_record_inspection(%L::jsonb)',jsonb_build_object('reservation_id',f.r,'result','ok')),f.u,'inspection page denied '||f.n);
 perform pg_temp.sg_deny(format('select fn_staff_payment_exception(%L::jsonb)',jsonb_build_object('reservation_id',f.r,'reason','test')),f.u,'exception page denied '||f.n);
 perform pg_temp.sg_deny(format('select fn_staff_record_paper_ack(%L::jsonb)',jsonb_build_object('reservation_id',f.r,'text_hash',fn_stay_summary_internal(f.r)->>'hash')),f.u,'ack page denied '||f.n);
 delete from staff_page_access where staff_id=f.s;
 end loop;end $$;
select name,ok from sg_results order by name;
select count(*) as passed_checks,bool_and(ok) as all_ok from sg_results;
rollback;
