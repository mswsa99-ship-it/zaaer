-- Local only, production RPC fixtures; cold/warm optional rows qualified independently.
\set ON_ERROR_STOP on
begin;
set local app.identity_key='checkout-local-synthetic-key';
do $$begin if exists(select 1 from branch_whatsapp_channels where enabled and mode='web_bridge' and bridge_key_hash is not null) then raise exception 'Outbound-capable channel state refused';end if;end $$;
\ir rpc-fixtures-checkout.sql
\if :{?checkout_warm}
select fn_room_cleaning_type(branch_id) from iso.target;
select fn_alert_raise(branch_id,'message_failed','channel:'||branch_id||':'||fn_branch_today(branch_id),'synthetic warm channel state','local only','/staff/journey',null) from iso.target;
\endif
create temp table ck_assert(name text,ok boolean);
create function pg_temp.ck(n text,b boolean) returns void language sql as $$insert into ck_assert values(n,coalesce(b,false))$$;
select fn_audit(c.org,c.branch,null,'reservation.checked_out','reservation',c.id::uuid,jsonb_build_object('before',jsonb_build_object('status','decoy'),'after',jsonb_build_object('status','decoy'))) from iso.created c where c.tbl='reservations' and c.purpose='checkout';
create temp table ck_audit_before as select id,md5(to_jsonb(a)::text) h from audit_events a;
do $$declare t record;own uuid;sig text;q text;rb jsonb;ra jsonb;b jsonb;a jsonb;touch text[];changes text[];pre text[];r jsonb;rid uuid;begin
 for t in select * from iso.target order by key loop
  select auth_user into own from iso.actor where role='owner' and hotel=t.hotel;
  select c.id::uuid into rid from iso.created c where c.tbl='reservations' and c.purpose='checkout' and c.branch=t.branch_id;
  foreach sig in array array['fn_staff_check_out(p jsonb)#checkout','fn_staff_checkout(p_reservation uuid, p_override_reason text)#checkout'] loop
   begin
    perform iso.set_claims(own);
    select iso.render_call(call_sql,t.key,'checkout-proof') into q from iso.rpc_adapter where signature=sig;
    select iso.touch_set(iso.render_call(touch_sql,t.key,'checkout-proof')) into pre from iso.rpc_adapter where signature=sig;
    b:=iso.snap();rb:=iso.row_snaps(array(select id::text from organizations));
    set local role authenticated;execute q into r;reset role;
    a:=iso.snap();ra:=iso.row_snaps(array(select id::text from organizations));
    select array_agg(tbl||'|'||pk order by tbl,pk) into changes from iso.row_changes(rb,ra);
    select iso.touch_set(iso.render_call(touch_sql,t.key,'checkout-proof')) into touch from iso.rpc_adapter where signature=sig;
    raise notice 'checkout % % changedrows=% preexistingtouch=%',t.key,sig,cardinality(changes),cardinality(pre);
    -- Lazy task type and deduplicated channel alert are not changed when pre-existing.
    select array_agg(x) into touch from unnest(touch) x where not(x=any(pre) and (x like 'task_types|%' or x like 'alert_events|%'));
    perform pg_temp.ck(t.key||'/'||sig||'/exact',touch @> changes and changes @> touch);
    perform pg_temp.ck(t.key||'/'||sig||'/effect',iso.eval_bool((select iso.render_call(effect_sql,t.key,'checkout-proof') from iso.rpc_adapter where signature=sig)) and r->>'ok'='true');
    b:=iso.snap();set local role authenticated;execute q into r;reset role;a:=iso.snap();
    perform pg_temp.ck(t.key||'/'||sig||'/repeat',r->>'duplicate'='true' and b=a);
    -- Preserve assertion rows while rolling back the function's business effects.
    if exists(select 1 from ck_audit_before b left join audit_events aa using(id) where b.h is distinct from md5(to_jsonb(aa)::text)) then raise exception 'CHECKOUT_OLD_AUDIT_CHANGED';end if;
    if exists(select 1 from ck_assert where not ok) then raise exception 'CHECKOUT_ASSERT_FAIL';end if;
    raise exception 'CK_ROLLBACK';
   exception when others then reset role;if sqlerrm<>'CK_ROLLBACK' then raise;end if;end;
  end loop;
 end loop;
end $$;
-- Each savepoint passed, but its assertion rows were rolled back; reaching here is the assertion.
select 'CHECKOUT FOUR TARGETS TWO ENTRYPOINTS EXACT EFFECT+REPEAT COMPLETED' result;
rollback;
