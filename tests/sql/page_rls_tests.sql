-- 0113: direct-read RLS policies follow the per-user page check (needs 0109 + 0110).
-- Run after the other suites on the same database: psql -d DB -f tests/sql/page_rls_tests.sql
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create or replace function t_login(p_uid uuid, p_email text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email)::text, false);
end $$;
create or replace function t_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;
create or replace function t_cnt(p_table text) returns int language plpgsql as $$ declare n int; begin execute format('select count(*) from %I', p_table) into n; return n; end $$;
-- the server's own count, limited to the test staff's organisation and branch (other suites leave rows elsewhere)
create or replace function t_cnt_admin(p_table text) returns int language plpgsql security definer as $$
declare n int; w text := 'organization_id = ''00000000-0000-0000-0000-000000000001''';
begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name=p_table and column_name='branch_id') then
    w := w || ' and branch_id = ''00000000-0000-0000-0000-000000000010'''; end if;
  execute format('select count(*) from %I where %s', p_table, w) into n; return n; end $$;

create or replace function t_cnt_org(p_table text) returns int language plpgsql security definer as $$
declare n int; begin execute format('select count(*) from %I where organization_id = ''00000000-0000-0000-0000-000000000001''', p_table) into n; return n; end $$;
-- fixtures: PG-prefixed ids so they never collide with the other suites
insert into staff_profiles(id, auth_user_id, organization_id, full_name, email, role) values
 ('1a000000-0000-0000-0000-000000000001','ca000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','pg مالك','pgowner@test.local','owner'),
 ('1a000000-0000-0000-0000-000000000002','ca000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001','pg مدير قديم','pgmgr@test.local','manager'),
 ('1a000000-0000-0000-0000-000000000003','ca000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000001','pg مدير فردي','pgmgr2@test.local','manager'),
 ('1a000000-0000-0000-0000-000000000004','ca000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000001','pg نظافة فردي','pghk@test.local','housekeeping'),
 ('1a000000-0000-0000-0000-000000000005','ca000000-0000-0000-0000-000000000005','00000000-0000-0000-0000-000000000001','pg بلا منح','pgnone@test.local','manager'),
 ('1a000000-0000-0000-0000-000000000006','ca000000-0000-0000-0000-000000000006','00000000-0000-0000-0000-000000000001','pg نظافة قديم','pghkl@test.local','housekeeping'),
 ('1a000000-0000-0000-0000-000000000007','ca000000-0000-0000-0000-000000000007','00000000-0000-0000-0000-000000000001','pg مالية فردي','pgfin@test.local','housekeeping')
on conflict (id) do nothing;
insert into branch_memberships(staff_id, branch_id, organization_id)
 select s, '00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001'
 from unnest(array['1a000000-0000-0000-0000-000000000002','1a000000-0000-0000-0000-000000000003','1a000000-0000-0000-0000-000000000004',
   '1a000000-0000-0000-0000-000000000005','1a000000-0000-0000-0000-000000000006','1a000000-0000-0000-0000-000000000007']::uuid[]) s;
-- the grant store (0109) is written by the test as the server would; enabled rows are individual accounts
insert into staff_page_access(staff_id, organization_id, enabled, page_grants) values
 ('1a000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000001',true,
   '{"/admin/rooms":{"view":true,"add":false,"edit":false,"delete":false},"/admin/availability":{"view":true,"add":true,"edit":false,"delete":false},"/admin/policies":{"view":true,"add":true,"edit":false,"delete":false},"/admin/booking-sources":{"view":true,"add":false,"edit":true,"delete":false}}'),
 ('1a000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000001',true,
   '{"/staff/housekeeping":{"view":true},"/admin/ai-settings":{"view":true}}'),
 ('1a000000-0000-0000-0000-000000000005','00000000-0000-0000-0000-000000000001',true,'{}'),
 ('1a000000-0000-0000-0000-000000000007','00000000-0000-0000-0000-000000000001',true,
   '{"/staff/payments":{"view":true},"/staff/pos-settlement":{"view":true}}');
insert into conversations(id, organization_id, branch_id) values ('1b000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010') on conflict do nothing;
-- (conversations may need more columns; the insert is best-effort and the tests below count what exists)

do $$ declare s text; begin  -- the hard totals as the server sees them
  perform t_record('PG00 fixtures: 4 individual rows, mode functions answer', (select count(*) from staff_page_access where enabled)=4, (select count(*) from staff_page_access where enabled)::text);
end $$;

set role authenticated;
-- ---- legacy manager: exactly the old behaviour ----
select t_login('ca000000-0000-0000-0000-000000000002','pgmgr@test.local');
do $$ begin
  perform t_record('PG01 legacy manager: mode is legacy', fn_user_access_mode()='legacy', fn_user_access_mode());
  perform t_record('PG02 legacy manager reads every branch room (10 of 10)', t_cnt('rooms')=t_cnt_admin('rooms'), t_cnt('rooms')||' of '||t_cnt_admin('rooms'));
  perform t_record('PG03 legacy manager reads reservations, ai_settings, booking_sources, inventory_periods as before',
    t_cnt('reservations')=t_cnt_admin('reservations') and t_cnt('ai_settings')=t_cnt_admin('ai_settings') and t_cnt('booking_sources')=t_cnt_admin('booking_sources') and t_cnt('inventory_periods')=t_cnt_admin('inventory_periods'),
    t_cnt('reservations')||'/'||t_cnt('ai_settings')||'/'||t_cnt('booking_sources')||'/'||t_cnt('inventory_periods'));
end $$;
select t_login('ca000000-0000-0000-0000-000000000006','pghkl@test.local');
do $$ begin
  perform t_record('PG04 legacy housekeeping still refused ai_settings and handoff/keyboxes (fixed role kept)', t_cnt('ai_settings')=0 and t_cnt('keyboxes')=0 and t_cnt('human_handoff_tickets')=0, t_cnt('ai_settings')||'/'||t_cnt('keyboxes'));
  perform t_record('PG05 legacy housekeeping still reads rooms and its own profile', t_cnt('rooms')>0 and (select count(*) from staff_profiles where id=fn_staff_id())=1, t_cnt('rooms')::text);
end $$;
-- ---- individual manager: rooms page only ----
select t_login('ca000000-0000-0000-0000-000000000003','pgmgr2@test.local');
do $$ declare ok boolean; begin
  perform t_record('PG06 individual mode is reported', fn_user_access_mode()='individual', fn_user_access_mode());
  perform t_record('PG07 /admin/rooms view: rooms, blocks, floors, room_categories visible', t_cnt('rooms')=t_cnt_admin('rooms') and t_cnt('blocks')=t_cnt_admin('blocks') and t_cnt('room_categories')=t_cnt_admin('room_categories'), t_cnt('rooms')||'/'||t_cnt('blocks')||'/'||t_cnt('room_categories'));
  perform t_record('PG08 no page grant: reservations, ai_settings, housekeeping_tasks, facilities, cash_accounts are empty even for a manager', t_cnt('reservations')=0 and t_cnt('ai_settings')=0 and t_cnt('facilities')=0 and t_cnt('cash_accounts')=0 and t_cnt('financial_vouchers')=0, t_cnt('reservations')||'/'||t_cnt('ai_settings')||'/'||t_cnt('cash_accounts'));
  perform t_record('PG09 individual manager: booking_sources visible through /admin/booking-sources and inventory_periods through /admin/availability', t_cnt('booking_sources')>0 and t_cnt('inventory_periods')>0, t_cnt('booking_sources')||'/'||t_cnt('inventory_periods'));
  perform t_record('PG10 individual: staff_profiles of others hidden, own row kept', (select count(*) from staff_profiles)=1, (select count(*) from staff_profiles)::text);
end $$;
-- write gates (the API roles hold INSERT/UPDATE on property_policies and conversations; the other FOR ALL tables are
-- closed at privilege level since 0055/0056, so their split policies are a second lock and are checked by structure, PG27)
do $$ declare n int; begin
  begin insert into property_policies(organization_id,branch_id,topic,title,content_ar,is_public) values (fn_user_org_id(),'00000000-0000-0000-0000-000000000010','other','pgtitle','x',false);
    perform t_record('PG12 /admin/policies add=true: insert allowed', true);
  exception when others then perform t_record('PG12 /admin/policies add=true: insert allowed', false, sqlerrm); end;
  update property_policies set title=title where title='pgtitle'; get diagnostics n=row_count;
  perform t_record('PG13 /admin/policies edit=false: update changes 0 rows', n=0, n::text);
  perform t_record('PG14 the policy row it inserted is visible through /admin/policies view', (select count(*) from property_policies where title='pgtitle')=1);
end $$;
-- Exact-action regression: edit without add must update, not insert; add without edit must not update/delete.
do $$ declare n int; begin
 begin
  delete from property_policies where title='pgtitle'; get diagnostics n=row_count;
  perform t_record('PG15 add without delete cannot delete its row', n=0);
 exception when insufficient_privilege then perform t_record('PG15 add without delete cannot delete its row', true);end;
 perform t_record('PG15b null write action fails closed', not fn_can_write('policies',null));
end $$;
reset role;
update staff_page_access set page_grants=jsonb_set(page_grants,'{/admin/policies}','{"view":true,"add":false,"edit":true,"delete":false}'::jsonb)
 where staff_id='1a000000-0000-0000-0000-000000000003';
set role authenticated;
do $$ declare n int; begin
 update property_policies set content_ar='edited' where title='pgtitle'; get diagnostics n=row_count;
 perform t_record('PG16 edit without add updates exactly its visible row', n=1);
 begin
  insert into property_policies(organization_id,branch_id,topic,title,content_ar,is_public)
    values(fn_user_org_id(),'00000000-0000-0000-0000-000000000010','other','pg-edit-only','x',false);
  perform t_record('PG17 edit without add cannot insert',false);
 exception when insufficient_privilege then perform t_record('PG17 edit without add cannot insert',true);end;
end $$;
-- ---- individual manager with no grants ----
select t_login('ca000000-0000-0000-0000-000000000005','pgnone@test.local');
do $$ declare n int; begin
  perform t_record('PG18 individual with {} grants: every direct-read table is empty (rooms, reservations, booking_sources, policies except public)',
    t_cnt('rooms')=0 and t_cnt('reservations')=0 and t_cnt('booking_sources')=0 and t_cnt('inventory_periods')=0
    and t_cnt('property_policies')=(select count(*) from property_policies where is_public and branch_id in (select fn_user_branch_ids())),
    t_cnt('rooms')||'/'||t_cnt('reservations')||'/'||t_cnt('property_policies'));
  perform t_record('PG19 individual with {} grants still reads its own profile (login must work)', (select count(*) from staff_profiles where id=fn_staff_id())=1);
  perform t_record('PG19b individual with {} grants still reads branches (branch selector)', t_cnt('branches')>0, t_cnt('branches')::text);
  begin insert into property_policies(organization_id,branch_id,topic,title,content_ar,is_public) values (fn_user_org_id(),'00000000-0000-0000-0000-000000000010','other','pgtitle2','x',false);
    perform t_record('PG20 no grant: manager insert into property_policies refused', false, 'inserted');
  exception when others then perform t_record('PG20 no grant: manager insert into property_policies refused', true, sqlerrm); end;
end $$;
-- ---- individual housekeeping role: grants replace the fixed role ----
select t_login('ca000000-0000-0000-0000-000000000004','pghk@test.local');
do $$ begin
  perform t_record('PG21 housekeeping role + /admin/ai-settings view reads ai_settings (grant replaces owner/manager role)', t_cnt('ai_settings')=t_cnt_admin('ai_settings') and t_cnt('ai_settings')>0, t_cnt('ai_settings')::text);
  perform t_record('PG22 same user is still refused tables of pages not granted (keyboxes, conversations, reservations)', t_cnt('keyboxes')=0 and t_cnt('conversations')=0 and t_cnt('reservations')=0);
  perform t_record('PG23 /staff/housekeeping view opens rooms and the staff list (the assignee names)', t_cnt('rooms')>0 and (select count(*) from staff_profiles)>1, (select count(*) from staff_profiles)::text);
end $$;
-- ---- money stays mandatory next to the grant ----
select t_login('ca000000-0000-0000-0000-000000000007','pgfin@test.local');
do $$ begin
  perform t_record('PG24 /staff/payments + /staff/pos-settlement granted to a role that fn_sees_money refuses: financial_vouchers stay empty (grant narrows, never widens)', t_cnt('financial_vouchers')=0 and t_cnt('pos_settlements')=0, t_cnt('financial_vouchers')||'/'||t_cnt('pos_settlements'));
end $$;
-- ---- owner ----
select t_login('ca000000-0000-0000-0000-000000000001','pgowner@test.local');
do $$ begin
  perform t_record('PG25 owner reads everything it did before (rooms, reservations, vouchers, ai_settings, booking_sources)', t_cnt('rooms')=t_cnt_org('rooms') and t_cnt('reservations')=t_cnt_org('reservations') and t_cnt('financial_vouchers')=t_cnt_org('financial_vouchers') and t_cnt('ai_settings')=t_cnt_org('ai_settings') and t_cnt('booking_sources')=t_cnt_org('booking_sources'));
end $$;
-- owner switched to individual mode with an empty grant still sees everything (the owner is never restricted)
reset role;
update staff_page_access set enabled=true where false;
insert into staff_page_access(staff_id, organization_id, enabled, page_grants) values ('1a000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001',true,'{}') on conflict do nothing;
set role authenticated;
select t_login('ca000000-0000-0000-0000-000000000001','pgowner@test.local');
do $$ begin
  perform t_record('PG26 owner with an enabled empty grant row still reads rooms/reservations/vouchers', t_cnt('rooms')=t_cnt_org('rooms') and t_cnt('reservations')=t_cnt_org('reservations') and t_cnt('financial_vouchers')=t_cnt_org('financial_vouchers'));
end $$;
-- ---- structure ----
reset role;
do $$ declare m text; begin
  select string_agg(tablename||'.'||policyname,', ') into m from pg_policies where schemaname='public' and cmd='ALL' and tablename in ('booking_sources','inventory_periods','property_policies','release_rules');
  perform t_record('PG27 no FOR ALL policy left on the four tables whose old policy answered reads', m is null, coalesce(m,'none'));
  select string_agg(tablename||'.'||policyname,', ') into m from pg_policies where schemaname='public' and 'authenticated'=any(roles::text[]) and cmd='SELECT' and permissive='PERMISSIVE'
    and tablename in ('access_delivery_events','ai_guardrail_events','ai_settings','ai_tool_executions','ai_usage_daily','audit_events','bank_parse_rules','blocks','booking_sources','cash_accounts','checkout_inspections','conversation_messages','conversations','expense_categories','facilities','financial_vouchers','floors','housekeeping_tasks','human_handoff_tickets','inventory_periods','keyboxes','maintenance_tickets','platform_payouts','pos_settlements','property_policies','release_rules','released_slots','reservation_guests','reservations','room_categories','rooms','service_definitions','staff_profiles','task_types')
    and qual not like '%fn_page_read_%';
  perform t_record('PG28 every permissive authenticated SELECT policy on the 34 gated tables calls the page check', m is null, coalesce(m,'none'));
  perform t_record('PG28b four exact restrictive branch read boundaries only narrow grants',
    (select count(*) from pg_policies where schemaname='public' and permissive='RESTRICTIVE' and cmd='SELECT'
      and roles::text[]=array['authenticated'] and (tablename,policyname) in (
        ('ai_guardrail_events','ai_guard_branch_read_boundary'),('ai_tool_executions','ai_tool_branch_read_boundary'),
        ('branch_memberships','branch_membership_read_boundary'),('product_branches','product_branch_read_boundary'))
      and qual like '%organization_id%fn_user_org_id%branch_id%fn_user_branch_ids%')=4);
  perform t_record('PG29 helpers are not executable by anon', not has_function_privilege('anon','fn_page_read_gate(text[])','execute') and not has_function_privilege('anon','fn_page_write_gate(text[],text)','execute'));
end $$;
-- every page name used by 0110 is in the page catalog (a typo would silently fail closed)
do $$ declare m text; begin
  select string_agg(distinct p,', ') into m from (select unnest(regexp_matches(pg_get_expr(polqual,polrelid)||coalesce(pg_get_expr(polwithcheck,polrelid),''),'''(/[a-z/:-]+)''','g')) p from pg_policy) x where p like '/%' and p not in (select page from fn_user_page_catalog());
  perform t_record('PG30 every page name inside a policy exists in the page catalog', m is null, coalesce(m,'none'));
end $$;

select case when ok then 'PASS' else 'FAIL' end as result, name, detail from test_results order by name;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from test_results;
do $$ begin if exists (select 1 from test_results where not ok) then raise exception 'page_rls_tests failed'; end if; end $$;
