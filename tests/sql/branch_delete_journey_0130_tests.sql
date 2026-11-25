-- UNRUN test source v3 (B4 as specified is the positive; baseline REDs on 23503 from branch_journey_settings, repair turns it green): owner branch delete WITH state change (fn_admin_delete_definition('branch', id)), migrations fixtures only. Rolled back.
-- Fixture identities as tests/sql/phase4_controls_tests.sql: owner a0..001 (owner@test.local) of the synthetic hotel, supervisor a0..002 (sup@test.local),
-- second hotel's owner a0..005 (owner2@test.local). Run after hotel_settings_tests.sql on the same database, with or without the v3c definitions candidate:
-- the owner and legacy results must be identical in both, which is the invariance check for the owner path.
-- Reading of the outcomes: ok=false/HAS_DEPENDENCIES is a RETURN VALUE, not a denial; denials count only as attributed 42501 with zero effect.
\set ON_ERROR_STOP off
begin;
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create temp table ids(k text primary key, v uuid);
grant all on ids to public;
create or replace function t_login(p_uid uuid, p_email text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email)::text, false);
end $$;
create or replace function t_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$ insert into test_results values (p_name, p_ok, p_detail); $$;
create or replace function t_id(p_k text) returns uuid language sql security definer as $$ select v from ids where k = p_k $$;
create or replace function t_fails(p_sql text, p_like text) returns text language plpgsql as $$
begin execute p_sql; return 'accepted'; exception when others then return case when sqlerrm like p_like then 'ok' else sqlstate || ' ' || sqlerrm end; end $$;
set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
reset role;
insert into staff_profiles(id,auth_user_id,organization_id,full_name,email,role) values ('fe500000-0000-4000-8000-0000000000b1','fe600000-0000-4000-8000-0000000000b1','00000000-0000-0000-0000-000000000001','Legacy manager','bd-mgr@example.test','manager');
create or replace function t_q(p_sql text) returns bigint language plpgsql security definer as $$ declare n bigint; begin execute p_sql into n; return n; end $$;
create or replace function t_cat(p_k text) returns bigint language sql security definer as $$ select count(*) from room_categories where id = (select v from ids where k = p_k) $$;
create or replace function t_state(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'accepted'; exception when others then return sqlstate || ' ' || sqlerrm; end $$;
set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
-- two fresh branches: one empty, one with a room (dependency)
do $$ declare r jsonb; begin
  r := fn_admin_upsert_branch(jsonb_build_object('name_ar','فرع حذف فارغ','name_en','BD Empty')); insert into ids values ('empty', (r->>'id')::uuid);
  r := fn_admin_upsert_branch(jsonb_build_object('name_ar','فرع حذف بوحدة','name_en','BD WithRoom')); insert into ids values ('busy', (r->>'id')::uuid);
  r := fn_admin_upsert_branch(jsonb_build_object('name_ar','فرع حذف ثان','name_en','BD Empty2')); insert into ids values ('empty2', (r->>'id')::uuid);
  r := fn_admin_upsert_branch(jsonb_build_object('name_ar','فرع حذف خامس','name_en','BD Empty5')); insert into ids values ('empty5', (r->>'id')::uuid);
end $$;
do $$ declare c jsonb; begin
  c := fn_admin_upsert_room_category(jsonb_build_object('branch_id', t_id('busy'), 'name_ar','نوع حذف','base_capacity',2,'max_capacity',3,'base_price_halalas',10000));
  insert into ids values ('busycat', (c->>'id')::uuid);
  perform fn_admin_upsert_room(jsonb_build_object('branch_id', t_id('busy'), 'category_id', t_id('busycat'), 'room_number','BD-1'));
end $$;
do $$ declare c jsonb; k text; begin
  foreach k in array array['cat2','cat3','cat4'] loop
    c := fn_admin_upsert_room_category(jsonb_build_object('branch_id', t_id('busy'), 'name_ar','نوع فارغ '||k,'base_capacity',2,'max_capacity',3,'base_price_halalas',10000));
    insert into ids values (k, (c->>'id')::uuid);
  end loop;
end $$;
reset role;
insert into branch_memberships(staff_id,branch_id) select 'fe500000-0000-4000-8000-0000000000b1', v from ids where k = 'empty2';
insert into staff_profiles(id,auth_user_id,organization_id,full_name,email,role) values
 ('fe500000-0000-4000-8000-0000000000d1','fe600000-0000-4000-8000-0000000000d1','00000000-0000-0000-0000-000000000001','Ind mgr branch delete','bd-im@example.test','manager'),
 ('fe500000-0000-4000-8000-0000000000d2','fe600000-0000-4000-8000-0000000000d2','00000000-0000-0000-0000-000000000001','Ind sup category delete','bd-is@example.test','supervisor'),
 ('fe500000-0000-4000-8000-0000000000d3','fe600000-0000-4000-8000-0000000000d3','00000000-0000-0000-0000-000000000001','Ind sup no grant','bd-is0@example.test','supervisor');
insert into staff_page_access(staff_id,organization_id,enabled,page_grants,sensitive_grants) values
 ('fe500000-0000-4000-8000-0000000000d1','00000000-0000-0000-0000-000000000001',true,'{"/admin/branches":{"view":true,"delete":true}}','[]'),
 ('fe500000-0000-4000-8000-0000000000d2','00000000-0000-0000-0000-000000000001',true,'{"/admin/room-categories":{"view":true,"delete":true}}','[]'),
 ('fe500000-0000-4000-8000-0000000000d3','00000000-0000-0000-0000-000000000001',true,'{"/staff/payments":{"view":true}}','[]');
insert into branch_memberships(staff_id,branch_id) select s, v from (values ('fe500000-0000-4000-8000-0000000000d1'::uuid),('fe500000-0000-4000-8000-0000000000d2'),('fe500000-0000-4000-8000-0000000000d3')) x(s), ids where k = 'busy';
insert into branch_memberships(staff_id,branch_id) select 'fe500000-0000-4000-8000-0000000000d1', v from ids where k = 'empty2';
insert into branch_memberships(staff_id,branch_id) select 'fe500000-0000-4000-8000-0000000000b1', v from ids where k = 'busy';
select count(*) as tt_before from task_types where branch_id = (select v from ids where k='empty') \gset
set role authenticated;
-- B1 legacy supervisor: refused by the role check, zero effect (attributed 42501)
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
select t_record('B1 supervisor cannot delete a branch (42501, nothing deleted)',
  t_state(format('select fn_admin_delete_definition(%L, %L)', 'branch', t_id('empty'))) like '42501 %'
  and t_q(format('select count(*) from branches where id = %L', t_id('empty'))) = 1);
-- B2 other hotel's owner: refused (attributed 42501), nothing deleted
select t_login('a0000000-0000-0000-0000-000000000005', 'owner2@test.local');
select t_record('B2 other hotel owner cannot delete our branch (42501, nothing deleted)',
  t_state(format('select fn_admin_delete_definition(%L, %L)', 'branch', t_id('empty'))) like '42501 %'
  and t_q(format('select count(*) from branches where id = %L', t_id('empty'))) = 1);
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
-- B3 owner, branch with a room: HAS_DEPENDENCIES returned, nothing deleted, no audit event
do $$ declare r jsonb; n_a int; begin
  n_a := t_q('select count(*) from audit_events where action = ''branch.deleted''');
  r := fn_admin_delete_definition('branch', t_id('busy'));
  perform t_record('B3 owner: a branch with a unit is not deleted (HAS_DEPENDENCIES returned, zero effect)',
    (r->>'ok')::boolean is false and r->>'error' = 'HAS_DEPENDENCIES' and t_q(format('select count(*) from branches where id = %L', t_id('busy'))) = 1
    and t_q('select count(*) from audit_events where action = ''branch.deleted''') = n_a);
end $$;
select t_record('B3c busy branch keeps its journey-settings row after HAS_DEPENDENCIES (cleanup runs only after the dependency check)', t_q(format('select count(*) from branch_journey_settings where branch_id = %L', t_id('busy'))) = 1);
-- B3b legacy MANAGER (not owner): owner-only line must refuse; zero effect. Positive-mutant for an owner-only gate that would let managers through.
select t_login('fe600000-0000-4000-8000-0000000000b1', 'bd-mgr@example.test');
do $$ declare m text; n_a int; begin
  n_a := t_q('select count(*) from audit_events where action = ''branch.deleted''');
  m := t_state(format('select fn_admin_delete_definition(%L, %L)', 'branch', t_id('empty2')));
  perform t_record('B3b manager (non-owner) cannot delete a branch (42501, nothing deleted, no audit)', m like '42501 %' and t_q(format('select count(*) from branches where id = %L', t_id('empty2'))) = 1 and t_q('select count(*) from audit_events where action = ''branch.deleted''') = n_a, m);
end $$;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
reset role;
update branch_journey_settings set checkout_instructions = 'BD custom', responsible_staff_id = '10000000-0000-0000-0000-000000000001' where branch_id = (select v from ids where k='empty');
select count(*)::int as sib_js_before from branch_journey_settings where branch_id <> (select v from ids where k='empty') \gset
set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
-- B4 owner, empty branch AS SPECIFIED (no fixture surgery). Trapped so later cases still run; the outcome is recorded as found.
do $$ declare r jsonb; m text; begin
  begin
    r := fn_admin_delete_definition('branch', t_id('empty')); m := r::text;
  exception when others then m := sqlstate || ' ' || sqlerrm; r := null; end;
  perform t_record('B4 owner: an empty fresh branch is deleted, audit survives, system task type gone',
    r is not null and (r->>'ok')::boolean is true and not t_q(format('select count(*) from branches where id = %L', t_id('empty'))) = 1
    and not exists (select 1 from task_types where branch_id = t_id('empty'))
    and t_q(format('select count(*) from audit_events where action = ''branch.deleted'' and entity_id = %L', t_id('empty'))) = 1
    and t_q(format('select count(*) from branch_journey_settings where branch_id = %L', t_id('empty'))) = 0, m);
end $$;
reset role;
create temp table sib as select count(*)::int n from task_types where branch_id = (select v from ids where k='busy'); grant all on sib to public;
set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
-- B4d only the deleted branch lost config: every other journey-settings row kept, other branches' task types kept
select t_record('B4d other branches keep their journey-settings rows and task types', t_q('select count(*) from branch_journey_settings where branch_id <> '''||t_id('empty')||'''') = :sib_js_before and (select count(*) from task_types where branch_id = t_id('busy')) = (select n from sib));
-- B5 owner again on the deleted id: NOT_FOUND (valid control), no second audit row
do $$ declare m text; n_a int; begin
  n_a := t_q('select count(*) from audit_events where action = ''branch.deleted''');
  m := t_fails(format('select fn_admin_delete_definition(%L, %L)', 'branch', t_id('empty')), 'NOT_FOUND%');
  perform t_record('B5 deleting it again is NOT_FOUND with no new audit row', m = 'ok' and t_q('select count(*) from audit_events where action = ''branch.deleted''') = n_a, m);
end $$;
-- B6 the other branches of the hotel are untouched
select t_record('B6 the busy branch and branch 010 still exist', t_q(format('select count(*) from branches where id = %L', t_id('busy'))) = 1 and exists (select 1 from branches where id = '00000000-0000-0000-0000-000000000010'));
-- ===== individual-mode and non-branch cases (catch an fn_require_role reversion of the 0129 role_ind line) =====
-- B7 individual MANAGER with the branches delete grant: passes the wrapper page gate and role_ind, owner-only line still refuses; zero effect
select t_login('fe600000-0000-4000-8000-0000000000d1', 'bd-im@example.test');
do $$ declare m text; n_a int; begin
  n_a := t_q('select count(*) from audit_events where action = ''branch.deleted''');
  m := t_state(format('select fn_admin_delete_definition(%L, %L)', 'branch', t_id('empty2')));
  perform t_record('B7 individual manager with branch delete grant is still refused by the owner-only line (42501 requires {owner}, nothing deleted)', m like '42501 FORBIDDEN: requires one of {owner}%' and t_q(format('select count(*) from branches where id = %L', t_id('empty2'))) = 1 and t_q('select count(*) from audit_events where action = ''branch.deleted''') = n_a, m);
end $$;
-- B8a individual supervisor WITHOUT the grant: the first gate (definition page) refuses, nothing deleted
select t_login('fe600000-0000-4000-8000-0000000000d3', 'bd-is0@example.test');
select t_record('B8a individual supervisor without the grant is refused at the page gate (42501 page /admin/room-categories action delete, category kept)',
  t_state(format('select fn_admin_delete_definition(%L, %L)', 'room_category', t_id('cat3'))) like '42501 FORBIDDEN: page /admin/room-categories action delete%' and t_cat('cat3') = 1);
-- B8 individual supervisor WITH the page grant deletes an empty category: only fn_require_role_ind (not fn_require_role) lets it through. Discriminates the 0129 reversion.
select t_login('fe600000-0000-4000-8000-0000000000d2', 'bd-is@example.test');
do $$ declare r jsonb; m text; begin
  begin r := fn_admin_delete_definition('room_category', t_id('cat2')); m := r::text; exception when others then r := null; m := sqlstate || ' ' || sqlerrm; end;
  perform t_record('B8 individual supervisor with the category delete grant deletes an empty category (role_ind line; audit row written)',
    r is not null and (r->>'ok')::boolean is true and t_cat('cat2') = 0 and t_q(format('select count(*) from audit_events where action = ''room_category.deleted'' and entity_id = %L', t_id('cat2'))) = 1, m);
end $$;
-- B8c legacy supervisor (no page access row) is refused, category kept
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
select t_record('B8c legacy supervisor cannot delete a category (42501, category kept)', t_state(format('select fn_admin_delete_definition(%L, %L)', 'room_category', t_id('cat4'))) like '42501 %' and t_cat('cat4') = 1);
-- B9 owner who ALSO has an individual page-access row (individual mode): still the owner, deletes an empty branch, nothing left behind
reset role;
insert into staff_page_access(staff_id,organization_id,enabled,page_grants,sensitive_grants) values ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001',true,'{"/staff/payments":{"view":true}}','[]');
set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
do $$ declare r jsonb; m text; begin
  begin r := fn_admin_delete_definition('branch', t_id('empty5')); m := r::text; exception when others then r := null; m := sqlstate || ' ' || sqlerrm; end;
  perform t_record('B9 individual-mode owner deletes an empty branch (ok, branch and its journey-settings row gone)',
    r is not null and (r->>'ok')::boolean is true and t_q(format('select count(*) from branches where id = %L', t_id('empty5'))) = 0 and t_q(format('select count(*) from branch_journey_settings where branch_id = %L', t_id('empty5'))) = 0, m);
end $$;
reset role;
select case when ok then 'PASS' else 'FAIL' end as result, name, detail from test_results order by name;
select 'TOTAL', count(*) filter (where ok) as passed, count(*) as total from test_results;
\set ON_ERROR_STOP on
do $$ declare n_fail int; n_all int; begin
  select count(*) filter (where not ok), count(*) into n_fail, n_all from test_results;
  if n_all <> 14 then raise exception 'EXPECTED 16 recorded cells, got %', n_all; end if;
  if n_fail > 0 then raise exception 'BRANCH DELETE TESTS FAILED: % of % cells', n_fail, n_all; end if;
end $$;
rollback;
