-- Class B money-products lane: fn_staff_create_product_order(p_reservation uuid, p_items jsonb).
-- Disposable database only, one transaction, everything rolls back. Synthetic identifiers, no credentials, no network.
-- Before EACH call: no enabled keyed web_bridge channel, zero whatsapp_outbox rows. After EACH call: still zero outbox rows,
-- no conversation_messages inserted. The fixture seeds 9 synthetic pending outbox rows; this proof deletes them inside its
-- own rolled-back transaction (no worker runs here) so the baseline is zero, and records that it did so.
\set ON_ERROR_STOP on
begin;
set local app.identity_key='money-products-local-synthetic-key';
\ir money-products-prep.sql
do $$
declare t record; own uuid; foreign_own uuid; rid uuid; pid uuid; p jsonb; b jsonb; a jsonb; rb jsonb; ra jsonb; r jsonb; err text; orgs text[];
        act record; lbl text; changes text[]; o product_orders%rowtype; l record; au record; sid uuid; n int; can boolean; seq_b int;
begin
 orgs := array(select id::text from organizations);
 select count(*) into n from iso.target; perform pg_temp.mpchk('targets/4', n=4, n::text);
 for t in select * from iso.target order by key loop
  select auth_user into own from iso.actor where role='owner' and hotel=t.hotel;
  select auth_user into foreign_own from iso.actor where role='owner' and hotel<>t.hotel order by key limit 1;
  select f.res_in into rid from mp_fx f where f.key=t.key;
  select f.pid into pid from mp_fx f where f.key=t.key;
  perform pg_temp.mpchk(t.key||'/fixture checked-in reservation and product', rid is not null and pid is not null, rid::text||'/'||pid::text);
  select staff.id into sid from staff_profiles staff where staff.auth_user_id=own;
  p := jsonb_build_array(jsonb_build_object('product_id', pid, 'quantity', 3));
  -- validation failures: labelled as validation, not denial credit, nothing written
  for lbl, p in select * from (values ('empty items','[]'::jsonb), ('quantity 0', jsonb_build_array(jsonb_build_object('product_id',pid,'quantity',0))),
      ('unknown product', jsonb_build_array(jsonb_build_object('product_id','00000000-0000-0000-0000-00000000dead','quantity',1))),
      ('non-array', '{"a":1}'::jsonb)) v(l,j) loop
   perform pg_temp.mpguard(t.key||'/validation '||lbl);
   perform iso.set_claims(own); b:=iso.snap(); err:=null; set local role authenticated;
   begin perform fn_staff_create_product_order(rid, p); exception when others then err:=sqlerrm; end; reset role; a:=iso.snap();
   perform pg_temp.mpchk(t.key||'/validation '||lbl||' (not a denial)', err like 'VALIDATION%' and a=b, err);
   perform pg_temp.mpafter(t.key||'/validation '||lbl);
  end loop;
  p := jsonb_build_array(jsonb_build_object('product_id', pid, 'quantity', 3));
  -- foreign-hotel owner
  perform pg_temp.mpguard(t.key||'/foreign owner');
  perform iso.set_claims(foreign_own); b:=iso.snap(); err:=null; set local role authenticated;
  begin perform fn_staff_create_product_order(rid, p); exception when others then err:=sqlerrm; end; reset role; a:=iso.snap();
  perform pg_temp.mpchk(t.key||'/foreign owner refused, whole-public no-write', err like 'RESERVATION_NOT_FOUND%' and a=b, err);
  perform pg_temp.mpafter(t.key||'/foreign owner');
  -- anon
  perform pg_temp.mpguard(t.key||'/anon');
  perform iso.set_claims(null); b:=iso.snap(); err:=null; set local role anon;
  begin perform fn_staff_create_product_order(rid, p); exception when others then err:=sqlerrm; end; reset role; a:=iso.snap();
  perform pg_temp.mpchk(t.key||'/anon refused', err like 'permission denied%' and a=b, err);
  perform pg_temp.mpafter(t.key||'/anon');
  -- same-hotel actors in OTHER branches and roles without the capability
  for act in select * from iso.actor x where x.hotel=t.hotel and x.role<>'owner' and x.role<>'guest' order by x.key loop
   perform iso.set_claims(act.auth_user); set local role authenticated; can := fn_can('voucher.receipt'); reset role;
   if act.branch is not distinct from replace(t.key, t.hotel||'|', '') and can then continue; end if; -- same-branch capable roles are covered by the positive run below
   perform pg_temp.mpguard(t.key||'/'||act.key);
   b:=iso.snap(); err:=null; set local role authenticated;
   begin perform fn_staff_create_product_order(rid, p); exception when others then err:=sqlerrm; end; reset role; a:=iso.snap();
   perform pg_temp.mpchk(t.key||'/'||act.key||' refused (cap='||can||')', (err like 'FORBIDDEN%' or err like 'PAGE_%' or err like 'permission denied%') and a=b, err);
   perform pg_temp.mpafter(t.key||'/'||act.key);
  end loop;
  -- authorized control: owner
  perform pg_temp.mpguard(t.key||'/owner control');
  perform iso.set_claims(own); rb:=iso.row_snaps(orgs); b:=iso.snap(); set local role authenticated;
  r := fn_staff_create_product_order(rid, p);
  reset role; ra:=iso.row_snaps(orgs); a:=iso.snap();
  perform pg_temp.mpafter(t.key||'/owner control');
  select array_agg(x.tbl||'|'||x.kind order by x.tbl, x.kind) into changes from iso.row_changes(rb, ra) x;
  perform pg_temp.mpchk(t.key||'/exact touched rows: one order, one line, one audit, one alert, one document-number sequence (insert or update), nothing else',
     cardinality(changes)=5 and changes @> array['product_orders|ins','product_order_lines|ins','audit_events|ins','alert_events|ins']
     and (changes @> array['document_sequences|ins'] or changes @> array['document_sequences|upd']), changes::text);
  perform pg_temp.mpchk(t.key||'/no table outside own org changed', not exists(select 1 from iso.row_changes(rb, ra) x where x.org<>t.org::text));
  select * into o from product_orders where reservation_id=rid and source='staff' order by created_at desc limit 1;
  perform pg_temp.mpchk(t.key||'/literal order', o.organization_id=t.org and o.branch_id=t.branch_id and o.status='pending_payment' and o.created_by=sid, to_jsonb(o)::text);
  select * into l from product_order_lines where order_id=o.id;
  perform pg_temp.mpchk(t.key||'/literal line', l.product_id=pid and l.quantity=3 and l.unit_price_halalas=1 and l.organization_id=t.org, to_jsonb(l)::text);
  perform pg_temp.mpchk(t.key||'/result carries the order', r::text like '%'||o.number||'%', r::text);
  select * into au from audit_events e where e.entity_id=o.id and e.action='product_order.created';
  perform pg_temp.mpchk(t.key||'/audit identity', au.organization_id=t.org and au.branch_id=t.branch_id and au.actor_id=sid, au.details::text);
  -- repeat adds to the same open order (not a new one): quantity 6, one order
  rb:=iso.row_snaps(orgs); set local role authenticated; r := fn_staff_create_product_order(rid, p); reset role; ra:=iso.row_snaps(orgs);
  perform pg_temp.mpafter(t.key||'/repeat');
  select count(*) into n from product_orders where reservation_id=rid and source='staff';
  select * into l from product_order_lines where order_id=o.id;
  perform pg_temp.mpchk(t.key||'/repeat merges into the open order', n=1 and l.quantity=6, n||'/'||l.quantity);
 end loop;
end $$;
select name, ok::text as ok, coalesce(detail,'') as detail from mp_assert order by ok, name;
do $$ begin if exists(select 1 from mp_assert where not ok) then raise exception 'FAIL count %', (select count(*) from mp_assert where not ok); end if;
 raise notice 'assertions=% failed=0', (select count(*) from mp_assert); end $$;
rollback;
