-- Shared preamble for the class B money-products proofs. Included with \ir by each proof, after "begin;".
-- Needs ONLY base fixtures.sql (no rpc-fixtures*): it builds its own synthetic stays and 1-halala product through the
-- production RPCs as the hotel owner, inside the proof's transaction (rolled back by the proof). No network, no credentials.
-- Hard RAISE (not a recorded false) on any outbound precondition, before every call.
do $$ begin
 if exists(select 1 from branch_whatsapp_channels where enabled and mode='web_bridge' and bridge_key_hash is not null) then raise exception 'REFUSED: enabled keyed web_bridge channel exists'; end if;
end $$;
create temp table mp_assert(name text, ok boolean, detail text);
create function pg_temp.mpchk(n text, b boolean, d text default null) returns void language sql as $$insert into mp_assert values(n, coalesce(b,false), d)$$;
-- outbox baseline: every existing row must belong to the synthetic isolation organizations; only those exact ids are removed
create temp table mp_ob0 as select id, organization_id from whatsapp_outbox;
do $$ begin
 if exists(select 1 from mp_ob0 where organization_id is null or organization_id not in (select org from iso.target)) then raise exception 'REFUSED: outbox holds rows outside the synthetic isolation organizations'; end if;
 delete from whatsapp_outbox where id in (select id from mp_ob0);
 if (select count(*) from whatsapp_outbox) <> 0 then raise exception 'REFUSED: outbox not empty after scoped synthetic cleanup'; end if;
end $$;
select pg_temp.mpchk('fixture outbox baseline: '||(select count(*) from mp_ob0)||' pre-existing rows, all in synthetic isolation orgs, removed by exact id; now zero', (select count(*) from whatsapp_outbox)=0);
create function pg_temp.mpguard(lbl text) returns void language plpgsql as $$
begin
 if exists(select 1 from branch_whatsapp_channels where enabled and mode='web_bridge' and bridge_key_hash is not null) then raise exception 'PRECONDITION FAILED before %: enabled keyed web_bridge', lbl; end if;
 if (select count(*) from whatsapp_outbox) <> 0 then raise exception 'PRECONDITION FAILED before %: outbox not zero', lbl; end if;
 insert into mp_assert values (lbl||'/precondition: no enabled keyed web_bridge, zero outbox rows', true, null);
end $$;
-- synthetic stays and product, per target (production RPC paths; fn_staff_shomoos stores a reference only, no external call)
create temp table mp_fx(key text primary key, res_in uuid, res_conf uuid, pid uuid);
do $$
declare t record; own uuid; r jsonb; cat uuid; src uuid; k int := 0; rm uuid; gid uuid; res1 uuid; res2 uuid; pcat uuid; pid uuid; hotel_cat uuid; ph text;
begin
 for t in select * from iso.target order by key loop
  k := k + 1;
  select auth_user into own from iso.actor where role='owner' and hotel=t.hotel;
  select c.id into cat from room_categories c where c.organization_id=t.org and c.branch_id=t.branch_id order by c.id limit 1;
  perform iso.set_claims(own); set local role authenticated;
  select b.id into src from booking_sources b where b.organization_id=t.org and b.kind='direct' and b.is_active order by b.id limit 1;
  if src is null then src := (fn_admin_upsert_source(jsonb_build_object('name','MP source '||k,'kind','direct'))->>'id')::uuid; end if;
  r := fn_staff_create_reservation(jsonb_build_object('source_id',src,'branch_id',t.branch_id,'category_id',cat,'check_in',current_date::text,'check_out',(current_date+2)::text,
        'guest_phone','05520'||lpad(k::text,5,'4'),'guest_name','Mpstay '||repeat(chr(96+k),4)));
  res1 := (r->>'id')::uuid;
  rm := (fn_admin_upsert_room(jsonb_build_object('branch_id',t.branch_id,'category_id',cat,'room_number','8'||lpad(k::text,2,'0')))->>'id')::uuid;
  perform fn_create_voucher(jsonb_build_object('reservation_id',res1,'kind','receipt','received_confirmed',true,'amount_halalas',21000+k*7,'method','cash','idempotency_key','mpprep-'||k));
  r := fn_staff_assign_room(res1, rm);
  select g.id into gid from reservation_guests g where g.reservation_id=res1 and g.is_primary limit 1;
  r := fn_staff_enter_guest(jsonb_build_object('reservation_id',res1,'guest_id',gid,'full_name','Mpstay '||repeat(chr(96+k),4)||' Alharbi','identity_type','national_id','identity_number','10000099'||lpad(k::text,2,'0'),'nationality','SA','birth_date','1990-01-01','document_matched',true));
  r := fn_staff_approve_identity(gid, true);
  r := fn_staff_shomoos(jsonb_build_object('reservation_id',res1,'action','register','reference','MPREF'||k,'all_guests',true));
  r := fn_staff_shomoos(jsonb_build_object('reservation_id',res1,'action','accept'));
  r := fn_staff_check_in(jsonb_build_object('reservation_id',res1));
  if (r->>'ok')::boolean is not true and r->>'duplicate' is null then raise exception 'MP FIXTURE CHECKIN BLOCKED: %', r; end if;
  r := fn_staff_create_reservation(jsonb_build_object('source_id',src,'branch_id',t.branch_id,'category_id',cat,'check_in',current_date::text,'check_out',(current_date+3)::text,
        'guest_phone','05521'||lpad(k::text,5,'3'),'guest_name','Mpconf '||repeat(chr(96+k),4)));
  res2 := (r->>'id')::uuid;
  -- one 1-halala product per organization (first target of the hotel makes it), offered in this branch
  select p.id into pid from products p where p.organization_id=t.org and p.name='MP synthetic item';
  if pid is null then
   r := fn_admin_upsert_product_category(jsonb_build_object('name','MP synthetic')); pcat := (r->>'id')::uuid;
   r := fn_admin_upsert_product(jsonb_build_object('name','MP synthetic item','price_halalas',1,'category_id',pcat,'taxable',true)); pid := (r->>'id')::uuid;
  end if;
  perform fn_admin_set_product_branch(pid, t.branch_id, true);
  reset role;
  insert into mp_fx values (t.key, res1, res2, pid);
 end loop;
 reset role;
end $$;
select pg_temp.mpchk('prep: four synthetic checked-in stays, four confirmed stays, one 1-halala product per hotel', (select count(*) from mp_fx)=4 and (select count(distinct pid) from mp_fx)=2
  and (select count(*) from mp_fx f join reservations x on x.id=f.res_in where x.status='checked_in' and x.room_id is not null)=4);
do $$ begin if (select count(*) from whatsapp_outbox) <> 0 then raise exception 'REFUSED: fixture prep queued outbound rows'; end if; end $$;
create temp table mp_cm as select count(*) n from conversation_messages;
create function pg_temp.mpafter(lbl text) returns void language plpgsql as $$
begin
 if (select count(*) from whatsapp_outbox) <> 0 then raise exception 'QUEUE INSERT after %: outbox not zero', lbl; end if;
 if (select count(*) from conversation_messages) <> (select n from mp_cm) then raise exception 'conversation_messages insert after %', lbl; end if;
 insert into mp_assert values (lbl||'/no queue insert: outbox still zero, no conversation_messages insert', true, null);
end $$;
