-- Bounded local refundother cold/warm proof; all business/fixture state rolls back.
\set ON_ERROR_STOP on
begin;
set local app.identity_key='refund-local-synthetic-key';
do $$begin if exists(select 1 from branch_whatsapp_channels where enabled and mode='web_bridge' and bridge_key_hash is not null) then raise exception 'Outbound-capable channel state refused';end if;end $$;
\ir rpc-fixtures-refundother.sql
create temp table rfo_assert(name text,ok boolean);
create function pg_temp.rfochk(n text,b boolean) returns void language sql as $$insert into rfo_assert values(n,coalesce(b,false))$$;
select fn_audit(c.org,c.branch,null,'voucher.refund_created','voucher',c.id::uuid,jsonb_build_object('reason','unrelated-refund-decoy')) from iso.created c where c.tbl='reservations' and c.purpose='refundother';
create temp table rfo_before_audit as select id,md5(to_jsonb(a)::text) h from audit_events a;
do $$declare t record;own uuid;rid uuid;p jsonb;r jsonb;v jsonb;b jsonb;a jsonb;rb jsonb;ra jsonb;changes text[];touches text[];q text;warm boolean;err text;gs uuid;begin
 for t in select * from iso.target order by key loop
  select auth_user into own from iso.actor where role='owner' and hotel=t.hotel;
  select c.id::uuid into rid from iso.created c where c.tbl='reservations' and c.purpose='refundother' and c.branch=t.branch_id;
  perform iso.set_claims(own);
  p:=jsonb_build_object('kind','refund','reservation_id',rid,'amount_halalas',1,'method','ota_deferred','reason','rfo-proof','idempotency_key','rfo-'||t.key);
  b:=iso.snap();err:=null;set local role authenticated;
  begin perform fn_refund(p);exception when others then err:=sqlerrm;end;
  reset role;a:=iso.snap();perform pg_temp.rfochk(t.key||'/missingmethodreason',err like 'REFUND_METHOD_DIFFERS%' and a=b);
  p:=p||jsonb_build_object('method_reason','rfo-othermethod');
  -- Same business payload must fail for a foreign owner, with whole-public no-write.
  perform iso.set_claims((select auth_user from iso.actor where role='owner' and hotel<>t.hotel order by key limit 1));
  b:=iso.snap();err:=null;set local role authenticated;
  begin perform fn_refund(p);exception when others then err:=sqlerrm;end;
  reset role;a:=iso.snap();perform pg_temp.rfochk(t.key||'/foreignowner',err like 'FORBIDDEN%' and a=b);
  perform iso.set_claims(own);
  warm:=exists(select 1 from gl_accounts where organization_id=t.org and source_id=(select source_id from reservations where id=rid));
  b:=iso.snap();rb:=iso.row_snaps(array(select id::text from organizations));
  set local role authenticated;r:=fn_refund(p);reset role;
  a:=iso.snap();ra:=iso.row_snaps(array(select id::text from organizations));
  select array_agg(tbl||'|'||pk order by tbl,pk) into changes from iso.row_changes(rb,ra);
  select iso.touch_set(iso.render_call(replace(touch_sql,'rfo-{salt}','rfo-'||t.key),t.key,'rfo-proof')) into touches from iso.rpc_adapter where signature='fn_refund(p jsonb)#othermethod';
  if not warm then select id into gs from gl_accounts where organization_id=t.org and source_id=(select source_id from reservations where id=rid);touches:=touches||('gl_accounts|'||gs);end if;
  perform pg_temp.rfochk(t.key||'/exact touch '||case when warm then 'warm' else 'cold' end,changes @> touches and touches @> changes and cardinality(changes)=case when warm then 9 else 10 end);
  select to_jsonb(f) into v from financial_vouchers f where f.id=(r->>'voucher_id')::uuid;
  perform pg_temp.rfochk(t.key||'/literalvoucher',v->>'method'='ota_deferred' and v->>'amount_halalas'='1' and v->>'status'='approved' and v->>'account_id' is null);
  perform pg_temp.rfochk(t.key||'/reviewidentity',exists(select 1 from review_items where entity_id=(r->>'voucher_id')::uuid and kind='refund_other_method' and reason='rfo-othermethod' and details->>'method'='ota_deferred' and details->>'amount_halalas'='1'));
  b:=iso.snap();set local role authenticated;r:=fn_refund(p);reset role;a:=iso.snap();perform pg_temp.rfochk(t.key||'/repeatidempotent',r->>'duplicate'='true' and a=b);
  b:=iso.snap();err:=null;set local role authenticated;
  begin perform fn_refund(p||jsonb_build_object('amount_halalas',2));exception when others then err:=sqlerrm;end;
  reset role;a:=iso.snap();perform pg_temp.rfochk(t.key||'/idempotencyconflict',err like 'IDEMPOTENCY_CONFLICT%' and a=b);
 end loop;
end $$;
select * from rfo_assert order by name;
select count(*) assertions,count(*) filter(where not ok) failed from rfo_assert;
do $$begin if exists(select 1 from rfo_assert where not ok) then raise exception 'Refundotherproof failed';end if;
if exists(select 1 from rfo_before_audit b left join audit_events a using(id) where b.h is distinct from md5(to_jsonb(a)::text)) then raise exception 'Refundexisting auditchange';end if;end $$;
rollback;
