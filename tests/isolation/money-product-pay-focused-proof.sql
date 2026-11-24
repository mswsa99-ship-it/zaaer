-- Class B money-products lane: fn_staff_pay_product_order(p jsonb).
-- Disposable database only, one transaction, everything rolls back. Synthetic identifiers, no credentials, no network.
-- Before EACH call: no enabled keyed web_bridge channel, zero whatsapp_outbox rows. After EACH call: still zero outbox rows,
-- no conversation_messages inserted. The fixture seeds 9 synthetic pending outbox rows; this proof deletes them inside its
-- own rolled-back transaction (no worker runs here) so the baseline is zero, and records that it did so.
\set ON_ERROR_STOP on
begin;
set local app.identity_key='money-products-local-synthetic-key';
\ir money-products-prep.sql
do $$
declare t record; own uuid; foreign_own uuid; rid uuid; pid uuid; items jsonb; p jsonb; b jsonb; a jsonb; rb jsonb; ra jsonb; r jsonb; err text; orgs text[];
        act record; lbl text; changes text[]; o product_orders%rowtype; v financial_vouchers%rowtype; au record; sid uuid; n int; can boolean; oid uuid; ver int; amt bigint; k int := 0; tk record; cnt_before int;
begin
 orgs := array(select id::text from organizations);
 select count(*) into n from iso.target; perform pg_temp.mpchk('targets/4', n=4, n::text);
 for t in select * from iso.target order by key loop
  k := k + 1;
  select auth_user into own from iso.actor where role='owner' and hotel=t.hotel;
  select auth_user into foreign_own from iso.actor where role='owner' and hotel<>t.hotel order by key limit 1;
  select f.res_in into rid from mp_fx f where f.key=t.key;
  select f.pid into pid from mp_fx f where f.key=t.key;
  select staff.id into sid from staff_profiles staff where staff.auth_user_id=own;
  items := jsonb_build_array(jsonb_build_object('product_id', pid, 'quantity', 4));
  -- setup (not under test): an open order for this stay, made through the staff function by the owner, also guarded
  perform pg_temp.mpguard(t.key||'/setup order');
  perform iso.set_claims(own); set local role authenticated; r := fn_staff_create_product_order(rid, items); reset role;
  perform pg_temp.mpafter(t.key||'/setup order');
  select * into o from product_orders where reservation_id=rid and status='pending_payment' order by created_at desc limit 1;
  oid := o.id; ver := o.version; amt := o.total_halalas;
  perform pg_temp.mpchk(t.key||'/setup: open order with a positive total', oid is not null and amt > 0 and o.organization_id=t.org, to_jsonb(o)::text);
  p := jsonb_build_object('order_id', oid, 'method', 'cash', 'idempotency_key', 'mpay-'||t.key, 'expected_version', ver);
  -- validation / state failures: labelled, not denial credit, whole-public no-write
  for lbl, p in select * from (values
      ('missing idempotency key', p - 'idempotency_key'),
      ('method not allowed at the hotel', p || '{"method":"card_online"}'::jsonb),
      ('malformed order id', p || '{"order_id":"nope"}'::jsonb),
      ('unknown order id', p || '{"order_id":"00000000-0000-0000-0000-00000000dead"}'::jsonb),
      ('stale expected version', p || jsonb_build_object('expected_version', ver + 5))) v(l,j) loop
   perform pg_temp.mpguard(t.key||'/validation '||lbl);
   perform iso.set_claims(own); b:=iso.snap(); err:=null; set local role authenticated;
   begin perform fn_staff_pay_product_order(p); exception when others then err:=sqlerrm; end; reset role; a:=iso.snap();
   perform pg_temp.mpchk(t.key||'/'||lbl||' (not a denial)', err is not null and (err like 'VALIDATION%' or err like 'NOT_FOUND%' or err like 'VERSION%' or err like 'STALE%' or err like 'CONFLICT%') and a=b, err);
   perform pg_temp.mpafter(t.key||'/validation '||lbl);
  end loop;
  p := jsonb_build_object('order_id', oid, 'method', 'cash', 'idempotency_key', 'mpay-'||t.key, 'expected_version', ver);
  -- foreign-hotel owner
  perform pg_temp.mpguard(t.key||'/foreign owner');
  perform iso.set_claims(foreign_own); b:=iso.snap(); err:=null; set local role authenticated;
  begin perform fn_staff_pay_product_order(p); exception when others then err:=sqlerrm; end; reset role; a:=iso.snap();
  perform pg_temp.mpchk(t.key||'/foreign owner refused, whole-public no-write', err like 'NOT_FOUND%' and a=b, err);
  perform pg_temp.mpafter(t.key||'/foreign owner');
  -- anon
  perform pg_temp.mpguard(t.key||'/anon');
  perform iso.set_claims(null); b:=iso.snap(); err:=null; set local role anon;
  begin perform fn_staff_pay_product_order(p); exception when others then err:=sqlerrm; end; reset role; a:=iso.snap();
  perform pg_temp.mpchk(t.key||'/anon refused', err like 'permission denied%' and a=b, err);
  perform pg_temp.mpafter(t.key||'/anon');
  -- same-hotel actors: other branches, or roles without the capability
  for act in select * from iso.actor x where x.hotel=t.hotel and x.role<>'owner' and x.role<>'guest' order by x.key loop
   perform iso.set_claims(act.auth_user); set local role authenticated; can := fn_can('voucher.receipt'); reset role;
   continue when act.branch is not distinct from replace(t.key, t.hotel||'|', '') and can;
   perform pg_temp.mpguard(t.key||'/'||act.key);
   b:=iso.snap(); err:=null; set local role authenticated;
   begin perform fn_staff_pay_product_order(p); exception when others then err:=sqlerrm; end; reset role; a:=iso.snap();
   perform pg_temp.mpchk(t.key||'/'||act.key||' refused (cap='||can||')', (err like 'FORBIDDEN%' or err like 'PAGE_%' or err like 'permission denied%') and a=b, err);
   perform pg_temp.mpafter(t.key||'/'||act.key);
  end loop;
  -- authorized control: owner pays in cash at the hotel
  perform pg_temp.mpguard(t.key||'/owner control');
  perform iso.set_claims(own); rb:=iso.row_snaps(orgs); b:=iso.snap(); set local role authenticated;
  r := fn_staff_pay_product_order(p);
  reset role; ra:=iso.row_snaps(orgs); a:=iso.snap();
  perform pg_temp.mpafter(t.key||'/owner control');
  select array_agg(x.tbl||'|'||x.kind order by x.tbl, x.kind) into changes from iso.row_changes(rb, ra) x;
  perform pg_temp.mpchk(t.key||'/exact touched rows (voucher, two journal lines + entry, charge, order update, delivery task + first-use task type, audit x2, notification, sequences, reservation balance, alert)',
     changes = array['alert_events|upd','audit_events|ins','audit_events|ins','document_sequences|upd','document_sequences|upd','financial_vouchers|ins','housekeeping_tasks|ins','journal_entries|ins','journal_lines|ins','journal_lines|ins','notifications|ins','product_orders|upd','reservation_charges|ins','reservations|upd','task_types|ins'], changes::text);
  perform pg_temp.mpchk(t.key||'/no table outside own org changed', not exists(select 1 from iso.row_changes(rb, ra) x where x.org<>t.org::text));
  perform pg_temp.mpchk(t.key||'/result', (r->>'ok')::boolean and (r->>'duplicate')::boolean is false and r->>'voucher_number' is not null, r::text);
  select * into o from product_orders where id=oid;
  perform pg_temp.mpchk(t.key||'/order is paid with voucher, task and version+1', o.status='paid' and o.voucher_id is not null and o.task_id is not null and o.paid_by=sid and o.version=ver+1, to_jsonb(o)::text);
  select * into v from financial_vouchers where id=o.voucher_id;
  perform pg_temp.mpchk(t.key||'/literal receipt voucher', v.kind='receipt' and v.status='approved' and v.amount_halalas=amt and v.method='cash' and v.reservation_id=rid and v.organization_id=t.org and v.branch_id=t.branch_id and v.product_order_id=oid and v.idempotency_key='mpay-'||t.key, to_jsonb(v)::text);
  select * into au from audit_events e where e.entity_id=oid and e.action='product_order.paid';
  perform pg_temp.mpchk(t.key||'/audit identity', au.organization_id=t.org and au.branch_id=t.branch_id and au.actor_id=sid and (au.details->'after'->>'amount_halalas')::bigint=amt, au.details::text);
  perform pg_temp.mpchk(t.key||'/charges sum to the order total', (select coalesce(sum(total_halalas),0) from reservation_charges where product_order_id=oid)=amt);
  -- replay with the same key: returns the same result, writes nothing, no second voucher
  perform pg_temp.mpguard(t.key||'/replay');
  select count(*) into cnt_before from financial_vouchers where reservation_id=rid;
  rb:=iso.row_snaps(orgs); b:=iso.snap(); set local role authenticated; r := fn_staff_pay_product_order(p); reset role; a:=iso.snap();
  perform pg_temp.mpchk(t.key||'/replay is a duplicate and writes nothing', (r->>'duplicate')::boolean and a=b and (select count(*) from financial_vouchers where reservation_id=rid)=cnt_before, r::text);
  perform pg_temp.mpafter(t.key||'/replay');
  -- a different key on a paid order is refused
  perform pg_temp.mpguard(t.key||'/paid order, new key');
  b:=iso.snap(); err:=null; set local role authenticated;
  begin perform fn_staff_pay_product_order(p || '{"idempotency_key":"other-key"}'); exception when others then err:=sqlerrm; end; reset role; a:=iso.snap();
  perform pg_temp.mpchk(t.key||'/paid order with another key refused (state, not denial)', err like 'VALIDATION: order_status%' and a=b, err);
  perform pg_temp.mpafter(t.key||'/paid order, new key');
 end loop;
end $$;
select name, ok::text as ok, coalesce(detail,'') as detail from mp_assert order by ok, name;
do $$ begin if exists(select 1 from mp_assert where not ok) then raise exception 'FAIL count %', (select count(*) from mp_assert where not ok); end if;
 raise notice 'assertions=%', (select count(*) from mp_assert); end $$;
rollback;
