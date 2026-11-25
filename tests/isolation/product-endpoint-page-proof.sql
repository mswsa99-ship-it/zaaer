\set ON_ERROR_STOP on
begin;
update product_orders set reservation_id=(select id from reservations where branch_id='a2000000-0000-0000-0000-000000000001' limit 1) where id=(select id from product_orders where branch_id='a2000000-0000-0000-0000-000000000001' order by id limit 1);
update product_orders set reservation_id=(select id from reservations where branch_id='a2000000-0000-0000-0000-000000000002' limit 1) where id=(select id from product_orders where branch_id='a2000000-0000-0000-0000-000000000002' order by id limit 1);
create temp table out(role text, mode text, fn text, res text);
grant all on out to public;
do $$
declare expected_cats jsonb; expected_products jsonb; before_hash text; after_hash text; a record; g record; sid uuid; org uuid; r jsonb; res text; br uuid; fbr uuid;
begin
 select branch_id into br from iso.target where key='hotel-a|branch-1';
 select branch_id into fbr from iso.target where key='hotel-b|branch-1';
 for a in select * from iso.actor where hotel='hotel-a' and (branch='branch-1' or branch is null) and role<>'guest' order by role loop
  select s.id, s.organization_id into sid, org from staff_profiles s where s.auth_user_id=a.auth_user;
  for g in select * from (values ('legacy',null::jsonb),('ind-none','{}'::jsonb),('ind-products','{"/admin/products":{"view":true}}'::jsonb),('ind-orders','{"/staff/orders":{"view":true}}'::jsonb),('ind-orders+payments','{"/staff/orders":{"view":true},"/staff/payments":{"view":true,"add":true}}'::jsonb),('ind-payments-only','{"/staff/payments":{"view":true,"add":true}}'::jsonb),('ind-orders+reports','{"/staff/orders":{"view":true},"/admin/reports":{"view":true}}'::jsonb)) v(name,pg) loop
    delete from staff_page_access where staff_id=sid;
    if g.pg is not null then insert into staff_page_access(staff_id,organization_id,enabled,page_grants) values (sid,org,true,g.pg); end if;
    select coalesce(jsonb_agg(id order by id),'[]'::jsonb) into expected_cats from product_categories where organization_id=org;
    select coalesce(jsonb_agg(id order by id),'[]'::jsonb) into expected_products from products where organization_id=org;
    select md5(string_agg(to_jsonb(q)::text,'' order by to_jsonb(q)::text)) into before_hash from product_orders q;
    perform iso.set_claims(a.auth_user); set local role authenticated;
    begin r := fn_admin_products(); if (select coalesce(jsonb_agg(e->'id' order by e->>'id'),'[]'::jsonb) from jsonb_array_elements(r->'categories') e) is distinct from expected_cats or
      (select coalesce(jsonb_agg(e->'id' order by e->>'id'),'[]'::jsonb) from jsonb_array_elements(r->'products') e) is distinct from expected_products then raise exception 'PRODUCT IDENTITY MISMATCH';end if;
    res := 'ok cats='||jsonb_array_length(r->'categories'); exception when others then res := left(sqlerrm,48); end;
    insert into out values (a.role,g.name,'admin_products',res);
    begin r := fn_staff_product_orders(br,null,30); res := 'ok n='||jsonb_array_length(r)||' otherbranch='||(select count(*) from jsonb_array_elements(r) e where e->>'branch_id'<>br::text); exception when others then res := left(sqlerrm,48); end;
    insert into out values (a.role,g.name,'orders own-branch',res);
    begin r := fn_staff_product_orders(fbr,null,30); res := 'ok n='||jsonb_array_length(r); exception when others then res := left(sqlerrm,48); end;
    insert into out values (a.role,g.name,'orders foreign-hotel',res);
    reset role;
    select md5(string_agg(to_jsonb(q)::text,'' order by to_jsonb(q)::text)) into after_hash from product_orders q;
    if before_hash is distinct from after_hash then raise exception 'READ MUTATED ORDERS';end if;
  end loop;
 end loop;
end $$;
select fn, mode, string_agg(role||': '||res, ' | ' order by role) from out group by 1,2 order by 1,2;
create temp table expected as select *,case
 when role='owner' then fn<>'orders foreign-hotel'
 when fn='orders foreign-hotel' then false
 when fn='admin_products' then (mode='legacy' and role='manager') or mode='ind-products'
 when fn='orders own-branch' then (mode='legacy' and role in ('manager','supervisor','finance')) or (mode in ('ind-orders+payments','ind-orders+reports') and role in ('manager','supervisor','finance'))
 else false end allow from out;
select count(*) assertions,count(*) filter(where allow is distinct from (res like 'ok %')) failures from expected;
select * from expected where allow is distinct from (res like 'ok %');
do $$begin if exists(select 1 from expected where allow is distinct from (res like 'ok %')) then raise exception 'Endpoint pagegate contractfailed';end if;
if exists(select 1 from expected where fn='orders own-branch' and allow and (res like 'ok n=0%' or res not like '%otherbranch=0')) then raise exception 'No discriminating order positive';end if;end $$;
rollback;
