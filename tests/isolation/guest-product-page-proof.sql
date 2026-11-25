\set ON_ERROR_STOP on
begin;
create temp table out(role text, mode text, tbl text, n int);
grant all on out to public;
do $$
declare a record; g record; sid uuid; org uuid; n int; t text; m text;
begin
 for a in select * from iso.actor where hotel='hotel-a' and (branch='branch-1' or branch is null) and role not in ('guest') order by role loop
  select s.id, s.organization_id into sid, org from staff_profiles s where s.auth_user_id=a.auth_user;
  for g in select * from (values ('legacy',null::jsonb),('ind-none','{}'::jsonb),('ind-guests','{"/admin/guests":{"view":true}}'::jsonb),('ind-products','{"/admin/products":{"view":true}}'::jsonb),('ind-orders','{"/staff/orders":{"view":true}}'::jsonb),('ind-wrong','{"/admin/reports":{"view":true}}'::jsonb)) v(name,pg) loop
    delete from staff_page_access where staff_id=sid;
    if g.pg is not null then insert into staff_page_access(staff_id,organization_id,enabled,page_grants) values (sid,org,true,g.pg); end if;
    perform iso.set_claims(a.auth_user); set local role authenticated;
    m := fn_user_access_mode();
    if (g.pg is null) = (m='individual') and a.role<>'owner' then raise exception 'mode mismatch % %', g.name, m; end if;
    foreach t in array array['guest_profiles','products','product_categories','product_order_lines','product_orders'] loop
      execute format('select count(*) from public.%I', t) into n;
      insert into out values (a.role, g.name, t, n);
    end loop;
    reset role;
  end loop;
 end loop;
end $$;
select tbl, mode, string_agg(role||'='||n, ' ' order by role) from out group by 1,2 order by 1,2;
select count(*) filter(where ((n>0) is distinct from case when role='owner' then true when tbl='guest_profiles' then role in ('manager','supervisor') and mode in ('legacy','ind-guests') else mode in ('legacy','ind-products') end)) failures from out where tbl in ('guest_profiles','products','product_categories');
do $$begin if exists(select 1 from out where tbl in ('guest_profiles','products','product_categories') and ((n>0) is distinct from case when role='owner' then true when tbl='guest_profiles' then role in ('manager','supervisor') and mode in ('legacy','ind-guests') else mode in ('legacy','ind-products') end)) then raise exception 'Guestproductpage contractfailed';end if;end $$;
rollback;
