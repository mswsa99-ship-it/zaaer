-- 0115-0118 individual page gates on direct reads and read RPCs, 0116 notifications, tenant boundary.
-- Run on a database through 0125 that has the seed rows (psql -d DB -f this file). Rolls back.
\set ON_ERROR_STOP off
begin;
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create or replace function xg_login(p_uid uuid, p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email)::text, false); end $$;
create or replace function xg_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail); $$;
create or replace function xg_cnt(p_table text) returns int language plpgsql as $$ declare n int; begin execute format('select count(*) from %I', p_table) into n; return n; end $$;
create or replace function xg_foreign(p_table text) returns int language plpgsql as $$ declare n int; begin execute format('select count(*) from %I where organization_id <> fn_user_org_id()', p_table) into n; return n; end $$;
create or replace function xg_org(p_table text) returns int language plpgsql security definer as $$ declare n int; begin execute format('select count(*) from %I where organization_id = ''00000000-0000-0000-0000-000000000001''', p_table) into n; return n; end $$;
create or replace function xg_denied(p_sql text) returns boolean language plpgsql as $$ begin execute p_sql; return false; exception when others then return sqlstate in ('42501','P0001') ; end $$;
create or replace function xg_upd_notif() returns int language plpgsql as $$ declare n int; begin update notifications set read_at = now(); get diagnostics n = row_count; return n; end $$;
create or replace function xg_decoy(p_table text) returns int language plpgsql security definer as $$ declare n int; begin execute format('select count(*) from %I where organization_id <> ''00000000-0000-0000-0000-000000000001''', p_table) into n; return n; end $$;
grant execute on function xg_upd_notif(), xg_decoy(text) to public;
grant execute on function xg_login(uuid,text), xg_record(text,boolean,text), xg_cnt(text), xg_foreign(text), xg_org(text), xg_denied(text) to public;
insert into staff_profiles(id, auth_user_id, organization_id, full_name, email, role) values
 ('1d000000-0000-0000-0000-000000000001','cd000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','ig legacy mgr','igmgr@test.local','manager'),
 ('1d000000-0000-0000-0000-000000000002','cd000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001','ig fin ctl','igfc@test.local','manager'),
 ('1d000000-0000-0000-0000-000000000003','cd000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000001','ig journey','igj@test.local','manager'),
 ('1d000000-0000-0000-0000-000000000004','cd000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000001','ig products+guests','igpg@test.local','manager'),
 ('1d000000-0000-0000-0000-000000000005','cd000000-0000-0000-0000-000000000005','00000000-0000-0000-0000-000000000001','ig no grants','ignone@test.local','manager');
insert into branch_memberships(staff_id, branch_id, organization_id)
 select s, '00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001'
 from unnest(array['1d000000-0000-0000-0000-000000000001','1d000000-0000-0000-0000-000000000002','1d000000-0000-0000-0000-000000000003','1d000000-0000-0000-0000-000000000004','1d000000-0000-0000-0000-000000000005']::uuid[]) s;
insert into staff_page_access(staff_id, organization_id, enabled, page_grants) values
 ('1d000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001',true,'{"/admin/finance-controls":{"view":true}}'),
 ('1d000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000001',true,'{"/admin/journey":{"view":true}}'),
 ('1d000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000001',true,'{"/admin/products":{"view":true},"/admin/guests":{"view":true},"/staff/orders":{"view":true}}'),
 ('1d000000-0000-0000-0000-000000000005','00000000-0000-0000-0000-000000000001',true,'{}');
insert into branches(id, organization_id, name_ar) values ('1a910000-0000-0000-0000-000000000011','00000000-0000-0000-0000-000000000001','ig other branch') on conflict do nothing;
insert into notifications(id, organization_id, branch_id, title) values
 ('1e000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010','ig own branch'),
 ('1e000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001','1a910000-0000-0000-0000-000000000011','ig other branch decoy');
insert into product_categories(id, organization_id, name) values ('1f000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','ig cat');
insert into products(id, organization_id, category_id, name, price_halalas) values ('1f000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001','1f000000-0000-0000-0000-000000000001','ig prod',100);
-- foreign-org decoys the suite owns (so the zero-foreign assertions never depend on what other suites left)
insert into organizations(id, name_ar) values ('1f900000-0000-0000-0000-000000000001','ig foreign org') on conflict do nothing;
insert into branches(id, organization_id, name_ar) values ('1f900000-0000-0000-0000-000000000011','1f900000-0000-0000-0000-000000000001','ig foreign branch') on conflict do nothing;
insert into notifications(id, organization_id, branch_id, title) values ('1f900000-0000-0000-0000-0000000000a1','1f900000-0000-0000-0000-000000000001','1f900000-0000-0000-0000-000000000011','ig foreign notification');
insert into product_categories(id, organization_id, name) values ('1f900000-0000-0000-0000-0000000000b1','1f900000-0000-0000-0000-000000000001','ig foreign cat');
insert into products(id, organization_id, category_id, name, price_halalas) values ('1f900000-0000-0000-0000-0000000000b2','1f900000-0000-0000-0000-000000000001','1f900000-0000-0000-0000-0000000000b1','ig foreign prod',100);
insert into guest_profiles(id, organization_id, full_name) values ('1f900000-0000-0000-0000-0000000000c1','1f900000-0000-0000-0000-000000000001','ig foreign guest');
select xg_record('IG00 fixtures: org has rows in every gated table', xg_org('finance_control_settings')>0 and xg_org('system_settings')>0 and xg_org('alert_rules')>0 and xg_org('products')>0 and xg_org('product_categories')>0 and xg_org('guest_profiles')>0, xg_org('finance_control_settings')||'/'||xg_org('system_settings')||'/'||xg_org('alert_rules')||'/'||xg_org('products')||'/'||xg_org('guest_profiles'));
select xg_record('IG00c foreign-org decoys exist in every gated table (so a zero foreign count is not an empty fixture)', xg_decoy('finance_control_settings')>0 and xg_decoy('system_settings')>0 and xg_decoy('alert_rules')>0 and xg_decoy('notifications')>0 and xg_decoy('products')>0 and xg_decoy('product_categories')>0 and xg_decoy('guest_profiles')>0, xg_decoy('finance_control_settings')||'/'||xg_decoy('system_settings')||'/'||xg_decoy('alert_rules')||'/'||xg_decoy('notifications')||'/'||xg_decoy('products')||'/'||xg_decoy('guest_profiles'));
select xg_record('IG00d same-org other-branch notification decoy exists', (select count(*) from notifications where organization_id='00000000-0000-0000-0000-000000000001' and branch_id is not null and branch_id<>'00000000-0000-0000-0000-000000000010')>0);
select xg_record('IG00b fixtures: org has branch notifications', (select count(*) from notifications where organization_id='00000000-0000-0000-0000-000000000001' and branch_id='00000000-0000-0000-0000-000000000010')>0);
set role authenticated;
-- legacy manager: unchanged behaviour, still own org only
select xg_login('cd000000-0000-0000-0000-000000000001','igmgr@test.local');
do $$ begin
 perform xg_record('IG01 legacy manager is legacy', fn_user_access_mode()='legacy');
 perform xg_record('IG02 legacy manager reads finance_control_settings, alert_rules, products, categories as before (own org count)', xg_cnt('finance_control_settings')=xg_org('finance_control_settings') and xg_cnt('alert_rules')=xg_org('alert_rules') and xg_cnt('products')=xg_org('products') and xg_cnt('product_categories')=xg_org('product_categories'), xg_cnt('finance_control_settings')||'/'||xg_cnt('alert_rules')||'/'||xg_cnt('products'));
 perform xg_record('IG03 legacy manager sees 0 foreign-org rows in all seven tables', xg_foreign('finance_control_settings')+xg_foreign('system_settings')+xg_foreign('alert_rules')+xg_foreign('notifications')+xg_foreign('products')+xg_foreign('product_categories')+xg_foreign('guest_profiles')=0);
 perform xg_record('IG04 legacy manager reads own-branch notifications, none from another branch of the same org', xg_cnt('notifications')>0 and (select count(*) from notifications where branch_id is not null and branch_id<>'00000000-0000-0000-0000-000000000010')=0, xg_cnt('notifications')::text);
 perform xg_record('IG04b legacy manager can still update own-branch notifications (positive control)', xg_upd_notif()>0);
end $$;
-- individual with finance-controls only
select xg_login('cd000000-0000-0000-0000-000000000002','igfc@test.local');
do $$ begin
 perform xg_record('IG05 individual mode reported', fn_user_access_mode()='individual');
 perform xg_record('IG06 finance-controls grant: finance_control_settings and system_settings readable (own org), nothing foreign', xg_cnt('finance_control_settings')=xg_org('finance_control_settings') and xg_cnt('system_settings')=xg_org('system_settings') and xg_foreign('finance_control_settings')+xg_foreign('system_settings')=0, xg_cnt('finance_control_settings')||'/'||xg_cnt('system_settings'));
 perform xg_record('IG07 finance-controls grant does NOT open alert_rules, products, categories, guests', xg_cnt('alert_rules')=0 and xg_cnt('products')=0 and xg_cnt('product_categories')=0 and xg_cnt('guest_profiles')=0);
 perform xg_record('IG08 fn_finance_controls_get allowed with the grant', not xg_denied('select fn_finance_controls_get()'));
 perform xg_record('IG09 fn_admin_alert_rules refused without /admin/journey', xg_denied('select fn_admin_alert_rules()'));
 perform xg_record('IG10 fn_admin_products and fn_staff_product_orders refused', xg_denied('select fn_admin_products()') and xg_denied('select fn_staff_product_orders(null::uuid,null::text,null::int)'));
end $$;
-- individual with journey only
select xg_login('cd000000-0000-0000-0000-000000000003','igj@test.local');
do $$ begin
 perform xg_record('IG11 journey grant: alert_rules readable (own org), finance_control_settings and system_settings not', xg_cnt('alert_rules')=xg_org('alert_rules') and xg_cnt('finance_control_settings')=0 and xg_cnt('system_settings')=0, xg_cnt('alert_rules')||'/'||xg_cnt('finance_control_settings'));
 perform xg_record('IG12 fn_admin_alert_rules allowed, fn_finance_controls_get refused', not xg_denied('select fn_admin_alert_rules()') and xg_denied('select fn_finance_controls_get()'));
end $$;
-- individual with products + guests + orders
select xg_login('cd000000-0000-0000-0000-000000000004','igpg@test.local');
do $$ begin
 perform xg_record('IG13 products grant: products and categories readable (own org), nothing foreign', xg_cnt('products')=xg_org('products') and xg_cnt('product_categories')=xg_org('product_categories') and xg_foreign('products')+xg_foreign('product_categories')=0, xg_cnt('products')||'/'||xg_cnt('product_categories'));
 perform xg_record('IG14 guests grant: guest_profiles readable for a manager role, own org only', xg_cnt('guest_profiles')>0 and xg_foreign('guest_profiles')=0, xg_cnt('guest_profiles')::text);
 perform xg_record('IG15 products grant does not open settings tables or alert_rules', xg_cnt('finance_control_settings')=0 and xg_cnt('system_settings')=0 and xg_cnt('alert_rules')=0);
 perform xg_record('IG16 fn_admin_products allowed with /admin/products', not xg_denied('select fn_admin_products()'));
end $$;
-- 0116 individual notifications closed (individual non-owner)
do $$ begin
 perform xg_record('IG17 individual non-owner reads 0 notifications (0116)', xg_cnt('notifications')=0, xg_cnt('notifications')::text);
 perform xg_record('IG18 individual non-owner cannot update a notification', xg_upd_notif()=0);
end $$;
-- no grants
select xg_login('cd000000-0000-0000-0000-000000000005','ignone@test.local');
do $$ begin
 perform xg_record('IG19 individual with {} grants: all seven gated tables are empty', xg_cnt('finance_control_settings')+xg_cnt('system_settings')+xg_cnt('alert_rules')+xg_cnt('notifications')+xg_cnt('products')+xg_cnt('product_categories')+xg_cnt('guest_profiles')=0);
 perform xg_record('IG20 individual with {} grants: gated RPCs refused', xg_denied('select fn_finance_controls_get()') and xg_denied('select fn_admin_alert_rules()') and xg_denied('select fn_admin_products()'));
end $$;
reset role;
select res, name, detail from (select case when ok then 'PASS' else 'FAIL' end as res, name, detail from test_results) q order by res desc, name;
select count(*) filter (where ok) as pass, count(*) filter (where not ok) as fail from test_results;
rollback;
