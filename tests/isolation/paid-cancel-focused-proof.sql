-- Bounded canonical-engine proof. Requires four target fixtures, separate einv purpose and the #einv adapter.
-- No guest header/JWT reinterpretation. Each successful probe rolls back its business changes in the engine.
\set ON_ERROR_STOP on
begin;
-- Unrelated local notification and audit decoys detect overbroad effects and touched-row selectors.
insert into notifications(branch_id,audience,title,body,link)
 select branch_id,'supervisor','Synthetic unrelated notification','paid-cancel decoy','/staff/housekeeping' from iso.target;
select fn_audit(t.org,t.branch_id,null,'voucher.cancelled','financial_voucher',v.id::uuid,jsonb_build_object('proof_decoy','paid-cancel','reason','unrelated reason'))
 from iso.target t join iso.created v on v.org=t.org and v.branch=t.branch_id and v.tbl='financial_vouchers' and v.purpose='paidorder';
select fn_audit(t.org,t.branch_id,null,'product_order.cancelled','product_order',v.id::uuid,jsonb_build_object('proof_decoy','paid-cancel','reason','unrelated reason'))
 from iso.target t join iso.created v on v.org=t.org and v.branch=t.branch_id and v.tbl='product_orders' and v.purpose='paidorder';
create temporary table paid_notification_before as select md5(coalesce(string_agg(n::text,'' order by id),'')) h from notifications n;
create temporary table paid_audit_before as select md5(coalesce(string_agg(a::text,'' order by id),'')) h from audit_events a where details->>'proof_decoy'='paid-cancel';
do $$ declare t record; a record; actor text; own uuid; sig text:='fn_staff_cancel_product_order(p_order uuid, p_reason text)#paidorder'; begin
 assert (select count(*) from iso.created where tbl='product_orders' and purpose='paidorder')=4, 'four paid orders required';
 for t in select * from iso.target order by key loop
  select auth_user into own from iso.actor where role='owner' and hotel=t.hotel;
  perform iso.set_claims(own);set local role authenticated;
  perform iso.rpc_probe('paid-control|'||t.key,sig,'control',t.key,true,iso.snap());
  reset role;
 end loop;
 update iso.probe_result set outcome='control-ok' where probe_id like 'paid-control|%' and outcome='success';
 for t in select * from iso.target order by key loop
  for a in select * from iso.actor where
      (role='manager' and hotel=t.hotel) or (hotel<>t.hotel and (role='owner' or (role='manager' and branch='branch-1'))) order by key loop
   perform iso.set_claims(a.auth_user);set local role authenticated;
   perform iso.rpc_probe('paid-actor|'||a.key||'|'||t.key,sig,a.key,t.key,false,iso.snap());
   reset role;
  end loop;
 end loop;
end $$;
select probe_id,outcome,errclass,sqlstate,sqlerrm,rows_ret,side_effect,detail from iso.probe_result where probe_id like 'paid-%' order by probe_id;
do $$ begin
 assert (select count(*) from iso.probe_result where probe_id like 'paid-control|%' and outcome='control-ok' and rows_ret>0 and detail like '%nontarget=proved-rowlevel effect=asserted-ok%')=4, 'four exact valid owner controls';
 assert (select count(*) from iso.probe_result p join iso.target t on t.key=p.target_key where p.probe_id like 'paid-actor|%' and split_part(p.actor_key,'|',2)=t.hotel and split_part(p.actor_key,'|',3)=t.branch and p.outcome='success' and p.detail like '%nontarget=proved-rowlevel effect=asserted-ok%')=4, 'four own branch exact manager successes';
 assert (select count(*) from iso.probe_result p join iso.target t on t.key=p.target_key where p.probe_id like 'paid-actor|%' and split_part(p.actor_key,'|',2)=t.hotel and split_part(p.actor_key,'|',3)<>t.branch and p.outcome='denied' and p.errclass='permission' and p.sqlstate='42501' and p.side_effect=false)=4, 'same hotel other branch permission denied';
 -- Exact function source first filters by fn_user_org_id, then raises NOT_FOUND; retain generic unattributed class.
 assert (select count(*) from iso.probe_result p join iso.target t on t.key=p.target_key where p.probe_id like 'paid-actor|%' and split_part(p.actor_key,'|',2)<>t.hotel and p.outcome='denied' and p.errclass='unattributed' and p.sqlstate='P0001' and p.sqlerrm='NOT_FOUND' and p.side_effect=false)=8, 'cross-hotel source-qualified not-found, not generic permission credit';
 assert not exists(select 1 from product_orders where id in(select id::uuid from iso.created where tbl='product_orders' and purpose='paidorder') and status<>'paid'), 'successful cancellation probes rolled back';
 assert (select md5(coalesce(string_agg(n::text,'' order by id),'')) from notifications n)=(select h from paid_notification_before), 'ALL notifications unchanged, including decoys';
 assert (select md5(coalesce(string_agg(a::text,'' order by id),'')) from audit_events a where details->>'proof_decoy'='paid-cancel')=(select h from paid_audit_before), 'audit decoys untouched';
end $$;
rollback;
