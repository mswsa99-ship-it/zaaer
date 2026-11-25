-- Bounded canonical proof, existing minimal local iso targets only. No trigger disable.
\set ON_ERROR_STOP on
begin;
do $$ begin if exists(select 1 from pg_trigger where tgrelid='product_branches'::regclass and not tgisinternal and tgenabled<>'O') then raise exception 'Product slot trigger disabled';end if;end $$;
-- Vacate synthetic victim slots only. This is explicit state preparation, not an API delete proof.
\if :{?slot_existing}
update product_branches pb set available=false from iso.created c where c.tbl='products' and c.purpose='victim' and c.id=pb.product_id::text;
\else
delete from product_branches pb using iso.created c where c.tbl='products' and c.purpose='victim' and c.id=pb.product_id::text;
\endif
select fn_audit(t.org,t.branch_id,null,'product.availability_changed','product',c.id::uuid,jsonb_build_object('before',jsonb_build_object('available',true),'after',jsonb_build_object('available',false),'reason','unrelated-slot-decoy')) from iso.target t join iso.created c on c.org=t.org and c.tbl='products' and c.purpose='victim';
create temp table slot_audits as select id,md5(to_jsonb(a)::text) h from audit_events a;
do $$ declare t record;a record;b jsonb;sig text:='fn_admin_set_product_branch(p_product uuid, p_branch uuid, p_available boolean)';begin
 for t in select * from iso.target order by key loop
  select * into a from iso.actor where role='owner' and hotel=t.hotel;
  perform iso.set_claims(a.auth_user);set local role authenticated;b:=iso.snap();
  perform iso.rpc_probe('slot-control|'||t.key,sig,'control',t.key,true,b);reset role;
 end loop;
 for a in select * from iso.actor where role in ('owner','manager') order by key loop
  for t in select * from iso.target order by key loop
   continue when a.role='owner' and a.hotel=t.hotel;
   perform iso.set_claims(a.auth_user);set local role authenticated;b:=iso.snap();
   perform iso.rpc_probe('slot-actor|'||a.key||'|'||t.key,sig,a.key,t.key,false,b);reset role;
  end loop;
 end loop;
end $$;
select probe_id,outcome,errclass,sqlstate,sqlerrm,detail from iso.probe_result where probe_id like 'slot-%' order by probe_id;
do $$ begin
 if (select count(*) from iso.probe_result where probe_id like 'slot-%' and outcome='success' and detail like '%effect=asserted-ok%' and detail like '%nontarget=proved-rowlevel%')<>8 then raise exception 'Slot8exact controls';end if;
 if (select count(*) from iso.probe_result where probe_id like 'slot-%' and outcome='denied' and errclass='permission' and sqlstate='42501')<>4 then raise exception 'Slot4branch denial';end if;
 if (select count(*) from iso.probe_result where probe_id like 'slot-%' and outcome='denied' and errclass='unattributed' and sqlstate='P0001' and sqlerrm='NOT_FOUND')<>12 then raise exception 'Slot12raw foreign product errors';end if;
 if (select count(*) from iso.probe_result where probe_id like 'slot-%')<>24 then raise exception 'Slot24probes';end if;
 if exists(select 1 from slot_audits b full join audit_events a using(id) where b.h is distinct from md5(to_jsonb(a)::text)) then raise exception 'Slot existing audits changed';end if;
end $$;
rollback;
