-- OBSERVATION ONLY: table/kind/count contracts are not target/content oracles. No adapter coverage credit.
-- LOCAL disposable PG16, synthetic only. Always rolls back. No protected function, no deliver_access_code, no keybox, no outbound channel.
-- Lane B check-in/housekeeping: fn_staff_enter_guest, fn_staff_approve_identity, fn_staff_shomoos, fn_staff_confirm_gov_registration,
-- fn_staff_approve_checkin, fn_hk_create_task, fn_hk_complete_task, fn_staff_complete_cleaning, fn_staff_mark_delivery_failed.
\set ON_ERROR_STOP on
begin;
set local app.identity_key='lane-local-synthetic-key';
do $$begin
 if exists(select 1 from branch_whatsapp_channels where enabled and mode='web_bridge' and bridge_key_hash is not null) then raise exception 'ENABLED KEYED BRIDGE PRESENT: refused'; end if;
 raise notice 'outbox baseline rows (inert seeded pending, no enabled keyed bridge): %',(select count(*) from whatsapp_outbox);
end $$;
create temp table lane_res(label text, ok boolean, err text, res jsonb, changes text[], outbound int);
grant all on lane_res to public;
create or replace function pg_temp.m(p_label text, p_auth uuid, p_sql text) returns void language plpgsql as $$
declare rb jsonb; ra jsonb; r jsonb; e text; ok boolean := true; ch text[]; ob int;
begin
  rb := iso.row_snaps(array(select id::text from organizations));
  perform iso.set_claims(p_auth); set local role authenticated;
  begin execute p_sql into r; exception when others then ok := false; e := sqlerrm; end;
  reset role;
  ra := iso.row_snaps(array(select id::text from organizations));
  select array_agg(tbl||':'||kind||':'||n order by tbl,kind) into ch from (select tbl,kind,count(*) n from iso.row_changes(rb,ra) group by 1,2) q;
  select count(*) into ob from iso.row_changes(rb,ra) where tbl in ('whatsapp_outbox','journey_messages','access_delivery_events','whatsapp_inbound_messages','integration_events','bank_messages');
  insert into lane_res values (p_label, ok, e, r, coalesce(ch,'{}'), ob);
end $$;
do $$
declare t record; own uuid; cat uuid; src uuid; r jsonb; k int := 0; rid uuid; rm uuid; gid uuid; hk uuid; tt uuid; tid uuid; sup uuid; fown uuid; frid uuid;
begin
  for t in select * from iso.target order by key loop
    k := k + 1;
    own := case when t.hotel='hotel-a' then 'a4000000-0000-0000-0000-0000000000a1' else 'a4000000-0000-0000-0000-0000000000b1' end::uuid;
    select c.id into cat from room_categories c where c.organization_id=t.org and c.branch_id=t.branch_id order by c.id limit 1;
    select b.id into src from booking_sources b where b.organization_id=t.org and b.kind='direct' and b.is_active order by b.id limit 1;
    perform iso.set_claims(own); set local role authenticated;
    if src is null then src := (fn_admin_upsert_source(jsonb_build_object('name','Lanesource '||chr(96+k),'kind','direct'))->>'id')::uuid; end if;
    r := fn_staff_create_reservation(jsonb_build_object('source_id',src,'branch_id',t.branch_id,'category_id',cat,'check_in',current_date::text,'check_out',(current_date+2)::text,'guest_phone','05518'||lpad(k::text,5,'9'),'guest_name','Lane '||repeat(chr(96+k),4)));
    rid := (r->>'id')::uuid;
    perform fn_create_voucher(jsonb_build_object('reservation_id',rid,'kind','receipt','received_confirmed',true,'amount_halalas',22000+k*7,'method','cash','idempotency_key','isolane-'||k));
    rm := (fn_admin_upsert_room(jsonb_build_object('branch_id',t.branch_id,'category_id',cat,'room_number','LNE'||k))->>'id')::uuid;
    r := fn_staff_assign_room(rid, rm);
    select g.id into gid from reservation_guests g where g.reservation_id=rid and g.is_primary limit 1;
    reset role;
    -- foreign-credential controls first (same owner credential of THIS hotel against the other hotel's reservation): refused, no write
    select c.id::uuid into frid from iso.created c where c.tbl='reservations' and c.org<>t.org limit 1;
    perform pg_temp.m(t.key||'|enter_guest|foreign', own, format($q$select fn_staff_enter_guest(jsonb_build_object('reservation_id',%L,'full_name','Foreign Person Name','identity_type','national_id','identity_number','1000070000','nationality','SA','birth_date','1990-01-01','document_matched',true))$q$, frid));
    perform pg_temp.m(t.key||'|enter_guest|own', own, format($q$select fn_staff_enter_guest(jsonb_build_object('reservation_id',%L,'guest_id',%L,'full_name','Lane %s Alharbi','identity_type','national_id','identity_number','10001900%s','nationality','SA','birth_date','1990-01-01','document_matched',true))$q$, rid, gid, repeat(chr(96+k),4), lpad(k::text,2,'0')));
    -- test-only seed on THIS synthetic guest: office entry already verified it; put it back to submitted+pending so approve_identity has a real transition
    update reservation_guests set verification_status='data_submitted', verified_by=null, verified_at=null where id=gid;
    perform fn_rollup_identity(rid);
    perform pg_temp.m(t.key||'|approve_identity|foreign-credential', (select auth_user from iso.actor where role='owner' and hotel<>t.hotel limit 1), format($q$select fn_staff_approve_identity(%L,true,null)$q$, gid));
    perform pg_temp.m(t.key||'|approve_identity|reject-no-reason', own, format($q$select fn_staff_approve_identity(%L,false,'')$q$, gid));
    perform pg_temp.m(t.key||'|approve_identity|own', own, format($q$select fn_staff_approve_identity(%L,true,null)$q$, gid));
    perform pg_temp.m(t.key||'|shomoos_accept|before-register', own, format($q$select fn_staff_shomoos(jsonb_build_object('reservation_id',%L,'action','accept'))$q$, rid));
    perform pg_temp.m(t.key||'|confirm_gov|own(all_guests=false hardcoded)', own, format($q$select fn_staff_confirm_gov_registration(%L,%L)$q$, rid, 'LANE'||k));
    perform pg_temp.m(t.key||'|shomoos_register|foreign-credential', (select auth_user from iso.actor where role='owner' and hotel<>t.hotel limit 1), format($q$select fn_staff_shomoos(jsonb_build_object('reservation_id',%L,'action','register','reference','LANEX','all_guests',true))$q$, rid));
    perform pg_temp.m(t.key||'|shomoos_register|own', own, format($q$select fn_staff_shomoos(jsonb_build_object('reservation_id',%L,'action','register','reference','LANE%s','all_guests',true))$q$, rid, k));
    perform pg_temp.m(t.key||'|shomoos_register|repeat', own, format($q$select fn_staff_shomoos(jsonb_build_object('reservation_id',%L,'action','register','reference','LANE%s','all_guests',true))$q$, rid, k));
    perform pg_temp.m(t.key||'|shomoos_accept|own', own, format($q$select fn_staff_shomoos(jsonb_build_object('reservation_id',%L,'action','accept'))$q$, rid));
    perform pg_temp.m(t.key||'|shomoos_accept|repeat', own, format($q$select fn_staff_shomoos(jsonb_build_object('reservation_id',%L,'action','accept'))$q$, rid));
    perform pg_temp.m(t.key||'|approve_checkin|foreign-credential', (select auth_user from iso.actor where role='owner' and hotel<>t.hotel limit 1), format($q$select fn_staff_approve_checkin(%L)$q$, rid));
    perform pg_temp.m(t.key||'|approve_checkin|own', own, format($q$select fn_staff_approve_checkin(%L)$q$, rid));
    perform pg_temp.m(t.key||'|approve_checkin|repeat', own, format($q$select fn_staff_approve_checkin(%L)$q$, rid));
    -- ---- housekeeping + delivery-failed (same synthetic stay/room)
    select a.auth_user into hk from iso.actor a where a.role='housekeeping' and a.hotel=t.hotel and a.branch=t.branch limit 1;
    select a.auth_user into sup from iso.actor a where a.role='housekeeping' and a.hotel<>t.hotel limit 1;
    select a.auth_user into fown from iso.actor a where a.role='owner' and a.hotel<>t.hotel limit 1;
    perform fn_room_cleaning_type(t.branch_id);
    select id into tt from task_types where branch_id=t.branch_id and code='room_cleaning' and archived_at is null limit 1;
    if tt is null then raise exception 'no room_cleaning task type for %', t.key; end if;
    declare hk_sid uuid; oth_sid uuid; t1 uuid; t2 uuid; t3 uuid; rr jsonb;
    begin
      select p.id into hk_sid from staff_profiles p where p.auth_user_id=hk;
      select p.id into oth_sid from staff_profiles p join iso.actor a on a.auth_user=p.auth_user_id where a.role='supervisor' and a.hotel=t.hotel and a.branch=t.branch limit 1;
      perform pg_temp.m(t.key||'|hk_create|foreign-credential', fown, format($q$select fn_hk_create_task(jsonb_build_object('room_id',%L,'task_type_id',%L))$q$, rm, tt));
      perform pg_temp.m(t.key||'|hk_create|foreign-assignee', (select auth_user from iso.actor where role='owner' and hotel=t.hotel), format($q$select fn_hk_create_task(jsonb_build_object('room_id',%L,'task_type_id',%L,'assignee_id',%L))$q$, rm, tt, (select p.id from staff_profiles p join iso.actor a on a.auth_user=p.auth_user_id where a.role='housekeeping' and a.hotel<>t.hotel limit 1)));
      perform pg_temp.m(t.key||'|hk_create|own-assigned-hk', (select auth_user from iso.actor where role='owner' and hotel=t.hotel), format($q$select fn_hk_create_task(jsonb_build_object('room_id',%L,'task_type_id',%L,'assignee_id',%L,'description','ISO lane t1'))$q$, rm, tt, hk_sid));
      select (res->>'id')::uuid into t1 from lane_res where label=t.key||'|hk_create|own-assigned-hk';
      perform pg_temp.m(t.key||'|hk_create|other-assigned', (select auth_user from iso.actor where role='owner' and hotel=t.hotel), format($q$select fn_hk_create_task(jsonb_build_object('room_id',%L,'task_type_id',%L,'assignee_id',%L,'description','ISO lane t2'))$q$, rm, tt, oth_sid));
      select (res->>'id')::uuid into t2 from lane_res where label=t.key||'|hk_create|other-assigned';
      perform pg_temp.m(t.key||'|hk_create|unassigned', (select auth_user from iso.actor where role='owner' and hotel=t.hotel), format($q$select fn_hk_create_task(jsonb_build_object('room_id',%L,'task_type_id',%L,'description','ISO lane t3'))$q$, rm, tt));
      select (res->>'id')::uuid into t3 from lane_res where label=t.key||'|hk_create|unassigned';
      perform pg_temp.m(t.key||'|hk_complete|foreign-credential', sup, format($q$select fn_hk_complete_task(%L,'x',1)$q$, t1));
      perform pg_temp.m(t.key||'|hk_complete|stale-version', hk, format($q$select fn_hk_complete_task(%L,'x',99)$q$, t1));
      perform pg_temp.m(t.key||'|hk_complete|not-assignee', hk, format($q$select fn_hk_complete_task(%L,'x',1)$q$, t2));
      perform pg_temp.m(t.key||'|hk_complete|own-assigned', hk, format($q$select fn_hk_complete_task(%L,'lane note',1)$q$, t1));
      perform pg_temp.m(t.key||'|hk_complete|repeat', hk, format($q$select fn_hk_complete_task(%L,'lane note',2)$q$, t1));
      perform pg_temp.m(t.key||'|complete_cleaning|foreign-credential', sup, format($q$select fn_staff_complete_cleaning(%L)$q$, t3));
      perform pg_temp.m(t.key||'|complete_cleaning|own-unassigned', hk, format($q$select fn_staff_complete_cleaning(%L)$q$, t3));
      perform pg_temp.m(t.key||'|complete_cleaning|repeat', hk, format($q$select fn_staff_complete_cleaning(%L)$q$, t3));
      perform pg_temp.m(t.key||'|delivery_failed|not-delivered', (select auth_user from iso.actor where role='owner' and hotel=t.hotel), format($q$select fn_staff_mark_delivery_failed(%L,'lane')$q$, rid));
      -- test-only seed on THIS synthetic stay: deliver_access_code is protected and never run, so the delivered state is set directly
      update reservations set access_status='delivered' where id=rid;
      perform pg_temp.m(t.key||'|delivery_failed|foreign-credential', fown, format($q$select fn_staff_mark_delivery_failed(%L,'lane')$q$, rid));
      perform pg_temp.m(t.key||'|delivery_failed|own', (select auth_user from iso.actor where role='owner' and hotel=t.hotel), format($q$select fn_staff_mark_delivery_failed(%L,'lane')$q$, rid));
      perform pg_temp.m(t.key||'|delivery_failed|repeat', (select auth_user from iso.actor where role='owner' and hotel=t.hotel), format($q$select fn_staff_mark_delivery_failed(%L,'lane')$q$, rid));
    end;
    insert into iso.created(tbl,id,org,branch,purpose) values ('reservations',rid::text,t.org,t.branch_id,'lane'),('rooms',rm::text,t.org,t.branch_id,'lane');
  end loop;
  perform iso.set_claims(null);
end $$;
create temp table expect(sfx text, ok boolean, err text, changes text[]);
insert into expect values
 ('enter_guest|foreign',false,'FORBIDDEN: branch not permitted','{}'),
 ('enter_guest|own',true,null,'{audit_events:ins:1,guest_profiles:upd:1,reservation_guests:upd:1,reservations:upd:1}'),
 ('approve_identity|foreign-credential',false,'FORBIDDEN: branch not permitted','{}'),
 ('approve_identity|reject-no-reason',false,'REASON_REQUIRED','{}'),
 ('approve_identity|own',true,null,'{audit_events:ins:1,reservation_guests:upd:1,reservations:upd:1}'),
 ('shomoos_accept|before-register',false,'VALIDATION: shomoos_not_registered','{}'),
 ('confirm_gov|own(all_guests=false hardcoded)',false,'VALIDATION: shomoos_all_guests','{}'),
 ('shomoos_register|foreign-credential',false,'FORBIDDEN: branch not permitted','{}'),
 ('shomoos_register|own',true,null,'{audit_events:ins:1,reservations:upd:1}'),
 ('shomoos_register|repeat',true,null,'{}'),
 ('shomoos_accept|own',true,null,'{audit_events:ins:1,reservations:upd:1}'),
 ('shomoos_accept|repeat',true,null,'{}'),
 ('approve_checkin|foreign-credential',false,'FORBIDDEN: branch not permitted','{}'),
 ('approve_checkin|own',true,null,'{audit_events:ins:1,reservations:upd:1,rooms:upd:1}'),
 ('approve_checkin|repeat',true,null,'{}'),
 ('hk_create|foreign-credential',false,'FORBIDDEN: branch not permitted','{}'),
 ('hk_create|foreign-assignee',false,'ASSIGNEE_NOT_IN_BRANCH','{}'),
 ('hk_create|own-assigned-hk',true,null,'{audit_events:ins:1,housekeeping_tasks:ins:1,rooms:upd:1}'),
 ('hk_create|other-assigned',true,null,'{audit_events:ins:1,housekeeping_tasks:ins:1}'),
 ('hk_create|unassigned',true,null,'{audit_events:ins:1,housekeeping_tasks:ins:1}'),
 ('hk_complete|foreign-credential',false,'FORBIDDEN: branch not permitted','{}'),
 ('hk_complete|stale-version',false,'VERSION_CONFLICT: record changed by another','{}'),
 ('hk_complete|not-assignee',false,'FORBIDDEN: not assignee','{}'),
 ('hk_complete|own-assigned',true,null,'{audit_events:ins:1,housekeeping_tasks:upd:1,rooms:upd:1}'),
 ('hk_complete|repeat',false,'TASK_STATUS_INVALID','{}'),
 ('complete_cleaning|foreign-credential',false,'TASK_NOT_FOUND','{}'),
 ('complete_cleaning|own-unassigned',true,null,'{audit_events:ins:1,housekeeping_tasks:upd:1}'),
 ('complete_cleaning|repeat',false,'TASK_STATUS_INVALID','{}'),
 ('delivery_failed|not-delivered',false,'NOT_IN_DELIVERED_STATE','{}'),
 ('delivery_failed|foreign-credential',false,'FORBIDDEN: branch not permitted','{}'),
 ('delivery_failed|own',true,null,'{audit_events:ins:1,reservations:upd:1}'),
 ('delivery_failed|repeat',false,'NOT_IN_DELIVERED_STATE','{}');
-- rows whose observed result differs from the source-derived expectation (suffix = label after "<hotel>|<branch>|")
create temp table bad as
 select l.label, l.ok, l.err, l.changes, l.outbound from lane_res l join expect e on l.label like '%|'||e.sfx
  where l.ok is distinct from e.ok or l.changes is distinct from e.changes or l.outbound<>0 or (e.err is not null and l.err is distinct from e.err and left(l.err,length(e.err)) is distinct from e.err);
create temp table unexpected as select l.label from lane_res l where not exists (select 1 from expect e where l.label like '%|'||e.sfx);
select (select count(*) from lane_res) probes, (select count(*) from bad) mismatches, (select count(*) from unexpected) unlisted, (select count(*) from lane_res where outbound<>0) outbound_effects, (select count(*) from lane_res where ok and cardinality(changes)>0) positive_effect_rows;
select * from bad;
select * from unexpected;
do $$begin if exists(select 1 from bad) or exists(select 1 from unexpected) or (select count(*) from lane_res)<>128 then raise exception 'Checkin/HK observation mismatch';end if;end $$;
rollback;
