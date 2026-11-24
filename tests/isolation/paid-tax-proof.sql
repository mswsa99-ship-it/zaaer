begin;
select fn_audit(t.org,t.branch_id,null,'voucher.cancelled','financial_voucher',o.voucher_id,jsonb_build_object('reason','unrelated decoy')) from iso.target t join iso.created q on q.org=t.org and q.branch=t.branch_id and q.tbl='product_orders' and q.purpose='paidordertax' join product_orders o on o.id=q.id::uuid;
select fn_audit(t.org,t.branch_id,null,'product_order.cancelled','product_order',q.id::uuid,jsonb_build_object('reason','unrelated decoy')) from iso.target t join iso.created q on q.org=t.org and q.branch=t.branch_id and q.tbl='product_orders' and q.purpose='paidordertax';
create temp table tax_notify_before as select id,md5(to_jsonb(n)::text) h from notifications n;
create temp table tax_audit_before as select id,md5(to_jsonb(a)::text) h from audit_events a;
do $$ declare t record; a record; b jsonb; sig text := 'fn_staff_cancel_product_order(p_order uuid, p_reason text)#paidordertax'; begin
 for t in select * from iso.target order by key loop
   select * into a from iso.actor where role='owner' and hotel=t.hotel;
   perform iso.set_claims(a.auth_user); set local role authenticated;
   b:=iso.snap(); perform iso.rpc_probe('tax-control|'||t.key,sig,'control',t.key,true,b); reset role;
 end loop;
 for a in select * from iso.actor where role='manager' or role='owner' order by key loop
   for t in select * from iso.target order by key loop
     continue when a.role='owner' and a.hotel=t.hotel;
     perform iso.set_claims(a.auth_user); set local role authenticated;
     b:=iso.snap(); perform iso.rpc_probe('tax-actor|'||a.key||'|'||t.key,sig,a.key,t.key,false,b); reset role;
   end loop;
 end loop;
end $$;
select probe_id,outcome,errclass,sqlstate,sqlerrm,detail from iso.probe_result where probe_id like 'tax-%' order by probe_id;
do $$ begin
 if (select count(*) from iso.probe_result where probe_id like 'tax-control|%' and outcome='success' and detail like '%effect=asserted-ok%' and detail like '%nontarget=proved-rowlevel%')<>4 then raise exception 'TAX own control contract failed'; end if;
 if (select count(*) from iso.probe_result where probe_id like 'tax-actor|%' and outcome='success' and detail like '%effect=asserted-ok%' and detail like '%nontarget=proved-rowlevel%')<>4 then raise exception 'TAX own manager contract failed'; end if;
 if (select count(*) from iso.probe_result where probe_id like 'tax-actor|%' and outcome='denied' and errclass='permission' and sqlstate='42501')<>4 then raise exception 'TAX same hotel foreign branch denial count'; end if;
 if (select count(*) from iso.probe_result where probe_id like 'tax-actor|%' and outcome='denied' and errclass='unattributed' and sqlstate='P0001' and sqlerrm='NOT_FOUND')<>12 then raise exception 'TAX crosshotel raw NOT_FOUND count'; end if;
 if (select count(*) from iso.probe_result where probe_id like 'tax-%')<>24 then raise exception 'TAX total probe count'; end if;
 if exists(select 1 from tax_notify_before b full join notifications n using(id) where b.h is distinct from md5(to_jsonb(n)::text)) then raise exception 'TAX notifications changed';end if;
 if exists(select 1 from tax_audit_before b full join audit_events a using(id) where b.h is distinct from md5(to_jsonb(a)::text)) then raise exception 'TAX preexisting audits changed';end if;
end $$;
-- Independent literal-amount reversal proof, separate rollback for each target.
do $$ declare t record; a record; oid uuid; positive jsonb; neg jsonb; begin
 for t in select * from iso.target order by key loop
  begin
   select id::uuid into oid from iso.created where purpose='paidordertax' and tbl='product_orders' and org=t.org and branch=t.branch_id;
   select jsonb_object_agg(kind,total_halalas) into positive from reservation_charges where product_order_id=oid and total_halalas>0;
   select * into a from iso.actor where role='owner' and hotel=t.hotel;
   perform iso.set_claims(a.auth_user);set local role authenticated;
   perform fn_staff_cancel_product_order(oid,'iso-tax-literal-proof');reset role;
   select jsonb_object_agg(kind,-total_halalas) into neg from reservation_charges where product_order_id=oid and total_halalas<0;
   if positive is distinct from neg or (select count(*) from jsonb_object_keys(positive))<>2 then raise exception 'TAX literal reversal mismatch %: % vs %',t.key,positive,neg;end if;
   raise exception 'ROLLBACK_TAX_LITERAL';
  exception when others then
   reset role;
   if sqlerrm<>'ROLLBACK_TAX_LITERAL' then raise;end if;
  end;
 end loop;
end $$;
rollback;
