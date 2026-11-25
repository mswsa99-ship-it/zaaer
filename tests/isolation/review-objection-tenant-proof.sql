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

create function pg_temp.sg_delta(b jsonb,t text,adds int,updates int,dels int) returns boolean language plpgsql as $$declare a jsonb;na int;nu int;nd int;begin
 a:=pg_temp.sg_snap()->t;
 with old as(select coalesce(x->>'id',x->>'token',x->>'branch_id') k,x from jsonb_array_elements(b->t)x),new as(select coalesce(x->>'id',x->>'token',x->>'branch_id') k,x from jsonb_array_elements(a)x)
 select count(*) filter(where old.k is null),count(*) filter(where old.k is not null and new.k is not null and old.x<>new.x),count(*) filter(where new.k is null) into na,nu,nd from old full join new using(k);
 if (na,nu,nd)<>(adds,updates,dels) then raise notice 'DELTA % actual %/%/% expected %/%/%',t,na,nu,nd,adds,updates,dels;end if;return (na,nu,nd)=(adds,updates,dels);end $$;

-- Foreign already-objected review must not produce a notification for its branch when owner A supplies its ID.
update review_items set objection_note='prior foreign objection',objection_at=now() where id=(select review from sg_fx where n=3);
create temp table rv_before as select id from notifications;
create temp table foreign_before as select pg_temp.sg_snap() j;
do $$declare j jsonb;foreign_id uuid;owner_a uuid;cnt int;begin
 select review into foreign_id from sg_fx where n=3;
 owner_a:='e2193000-0000-0000-0000-000000000011';
 j:=pg_temp.sg_try(format('select fn_review_mark(%L::jsonb)',jsonb_build_object('ids',jsonb_build_array(foreign_id),'outcome','objection','note','caller A unrelated note')),owner_a);
 select count(*) into cnt from notifications where id not in(select id from rv_before) and organization_id='e2190000-0000-0000-0000-000000000002';
 raise notice 'Reviewforeigncallresult=%, foreignnotifications=%',j,cnt;
 if cnt<>0 then raise exception 'CROSS_TENANT_REVIEW_NOTIFICATION';end if;
 if (select count(*) from jsonb_array_elements(pg_temp.sg_snap()->'review_items') e where e->>'organization_id'='e2190000-0000-0000-0000-000000000002' and not exists(select 1 from jsonb_array_elements((select fb.j->'review_items' from foreign_before fb)) old where old=e))<>0 then raise exception 'Foreign review content changed';end if;
end $$;
do $$declare j jsonb;own_id uuid;b jsonb;begin
 select review into own_id from sg_fx where n=1;
 b:=pg_temp.sg_snap();
 j:=pg_temp.sg_try(format('select fn_review_mark(%L::jsonb)',jsonb_build_object('ids',jsonb_build_array(own_id),'outcome','objection','note','own owner objection')), 'e2193000-0000-0000-0000-000000000011');
 if not(j->>'ok')::boolean or j->'result'->>'objected'<>'1' then raise exception 'Own objection positive failed';end if;
 if not exists(select 1 from notifications where organization_id='e2190000-0000-0000-0000-000000000001' and body='own owner objection') then raise exception 'Own notification literal missing';end if;
 if not exists(select 1 from review_items where id=own_id and objection_note='own owner objection' and objection_by='e2192000-0000-0000-0000-000000000011') then raise exception 'Own review literal mismatch';end if;
 if not pg_temp.sg_delta(b,'review_items',0,1,0) or not pg_temp.sg_delta(b,'notifications',1,0,0) or not pg_temp.sg_delta(b,'audit_events',1,0,0) then raise exception 'Own exact effects failed';end if;
 if not exists(select 1 from audit_events where organization_id='e2190000-0000-0000-0000-000000000001' and action='review.objection' and actor_id='e2192000-0000-0000-0000-000000000011' and details->'after'->>'count'='1') then raise exception 'Own audit identity failed';end if;
 if not pg_temp.sg_tables(b,array['review_items','notifications','audit_events']) then raise exception 'Unrelated table changed';end if;
end $$;
rollback;
