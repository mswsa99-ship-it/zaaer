-- 0125 history-detail permission: separate owner-granted before/after details for INDIVIDUAL-mode accounts only.
-- Contrast: individual without grant / individual with grant / legacy supervisor / legacy manager / owner / other tenant.
-- Local synthetic only. Direct SELECT * / details denial for API roles stays in tests/isolation/audit-direct-column-proof.sql.
\set ON_ERROR_STOP on
begin;
insert into organizations(id,name_ar) values('fd000000-0000-4000-8000-000000000001','History tenant A'),('fd000000-0000-4000-8000-000000000002','History tenant B');
insert into staff_profiles(id,auth_user_id,organization_id,full_name,email,role) values
('fd100000-0000-4000-8000-000000000001','fd200000-0000-4000-8000-000000000001','fd000000-0000-4000-8000-000000000001','Owner','h-owner@example.test','owner'),
('fd100000-0000-4000-8000-000000000002','fd200000-0000-4000-8000-000000000002','fd000000-0000-4000-8000-000000000001','Ind no grant','h-ind1@example.test','supervisor'),
('fd100000-0000-4000-8000-000000000003','fd200000-0000-4000-8000-000000000003','fd000000-0000-4000-8000-000000000001','Ind with grant','h-ind2@example.test','supervisor'),
('fd100000-0000-4000-8000-000000000004','fd200000-0000-4000-8000-000000000004','fd000000-0000-4000-8000-000000000001','Legacy supervisor','h-sup@example.test','supervisor'),
('fd100000-0000-4000-8000-000000000005','fd200000-0000-4000-8000-000000000005','fd000000-0000-4000-8000-000000000001','Legacy manager','h-mgr@example.test','manager'),
('fd100000-0000-4000-8000-000000000006','fd200000-0000-4000-8000-000000000006','fd000000-0000-4000-8000-000000000002','Other tenant owner','h-other@example.test','owner'),
('fd100000-0000-4000-8000-000000000007','fd200000-0000-4000-8000-000000000007','fd000000-0000-4000-8000-000000000001','Ind grant but no audit page','h-ind3@example.test','supervisor'),
('fd100000-0000-4000-8000-000000000008','fd200000-0000-4000-8000-000000000008','fd000000-0000-4000-8000-000000000001','Ind audit page only plus grant','h-ind4@example.test','supervisor');
insert into staff_page_access(staff_id,organization_id,enabled,page_grants,sensitive_grants) values
('fd100000-0000-4000-8000-000000000008','fd000000-0000-4000-8000-000000000001',true,'{"/admin/audit-logs":{"view":true}}','["history.details"]'),
('fd100000-0000-4000-8000-000000000002','fd000000-0000-4000-8000-000000000001',true,'{"/admin/audit-logs":{"view":true},"/staff/reservations":{"view":true}}','[]'),
('fd100000-0000-4000-8000-000000000003','fd000000-0000-4000-8000-000000000001',true,'{"/admin/audit-logs":{"view":true},"/staff/reservations":{"view":true}}','["history.details"]'),
('fd100000-0000-4000-8000-000000000007','fd000000-0000-4000-8000-000000000001',true,'{"/staff/reservations":{"view":true}}','["history.details"]');
insert into audit_events(organization_id,action,entity_type,entity_id,details) values
('fd000000-0000-4000-8000-000000000001','reservation.total_changed','reservation','fd300000-0000-4000-8000-000000000001','{"reason":"HD-REASON","before":{"total_halalas":111111},"after":{"total_halalas":222222}}');
create temp table res(name text primary key, ok boolean not null);
grant all on res to authenticated;
create function pg_temp.login(uid text) returns void language sql as $$select set_config('request.jwt.claim.sub',uid,false)::text::void$$;
-- helper: details visible / reason visible / row visible for the marker row via the permitted RPC
create function pg_temp.probe(uid text, out row_seen boolean, out details_seen boolean, out reason_seen boolean) language plpgsql as $$
declare r jsonb; x jsonb; begin
  perform pg_temp.login(uid);
  r := fn_audit_list('{"entity_id":"fd300000-0000-4000-8000-000000000001"}'::jsonb);
  select e into x from jsonb_array_elements(r->'rows') e where e->>'action' = 'reservation.total_changed' limit 1;
  row_seen := x is not null; details_seen := x->'details' is not null and x->'details' <> 'null'::jsonb and (x->'details'->'before') is not null;
  reason_seen := (x->>'reason') = 'HD-REASON';
end $$;
grant execute on function pg_temp.probe(text) to authenticated;
set role authenticated;
do $$ declare p record; begin
  select * into p from pg_temp.probe('fd200000-0000-4000-8000-000000000002');
  insert into res values('individual WITHOUT grant: row and reason visible, before/after hidden', p.row_seen and p.reason_seen and not p.details_seen);
  select * into p from pg_temp.probe('fd200000-0000-4000-8000-000000000003');
  insert into res values('individual WITH explicit grant: before/after visible', p.row_seen and p.details_seen);
  select * into p from pg_temp.probe('fd200000-0000-4000-8000-000000000008');
  insert into res values('individual with audit page ONLY plus grant: before/after visible (each surface keeps its own page)', p.row_seen and p.details_seen);
  select * into p from pg_temp.probe('fd200000-0000-4000-8000-000000000004');
  insert into res values('legacy supervisor unchanged: no details', p.row_seen and not p.details_seen);
  select * into p from pg_temp.probe('fd200000-0000-4000-8000-000000000005');
  insert into res values('legacy manager unchanged: details', p.row_seen and p.details_seen);
  select * into p from pg_temp.probe('fd200000-0000-4000-8000-000000000001');
  insert into res values('owner unchanged: details', p.row_seen and p.details_seen);
  select * into p from pg_temp.probe('fd200000-0000-4000-8000-000000000006');
  insert into res values('other tenant owner sees nothing of this row', not p.row_seen);
end $$;
-- grant without the audit page does not open the log (page guard preserved)
select pg_temp.login('fd200000-0000-4000-8000-000000000007');
do $$ begin begin perform fn_audit_list('{}'::jsonb); insert into res values('grant without audit page still denied', false);
  exception when others then insert into res values('grant without audit page still denied', sqlerrm like '%FORBIDDEN%' or sqlstate='42501'); end; end $$;
-- the grant is not a role bypass: it adds nothing to the capability catalog for legacy accounts
select pg_temp.login('fd200000-0000-4000-8000-000000000004');
insert into res values('legacy account: fn_can(history.details) not granted by role', not fn_can('history.details'));
select pg_temp.login('fd200000-0000-4000-8000-000000000003');
insert into res values('individual with grant (both pages): fn_can(history.details)', fn_can('history.details'));
select pg_temp.login('fd200000-0000-4000-8000-000000000002');
insert into res values('individual without grant: not fn_can(history.details)', not fn_can('history.details'));
-- direct table access stays denied (0122): the new RPC gate is not a substitute
do $$ begin begin perform details from audit_events limit 1; insert into res values('direct details SELECT still denied for individual', false);
  exception when insufficient_privilege then insert into res values('direct details SELECT still denied for individual', true); end; end $$;
reset role;
table res;
do $$ begin if exists(select 1 from res where not ok) then raise exception 'HISTORY DETAILS TESTS FAILED'; end if; end $$;
rollback;

-- ===== Part B: reservation history through the raw RPC fn_reservation_detail (0125). Uses a reservation of the shared test org.
-- Accounts: R1 individual, member of the reservation's branch, /staff/reservations view, NO grant; R2 same + grant; R3 grant but NOT a member of the
-- reservation's branch (branch guard); R4 grant, no /staff/reservations view (page guard); R5 grant, then removed; R6 grant but account inactive.
begin;
do $$ declare rid uuid; rb uuid; ro uuid; begin
  select id, branch_id, organization_id into rid, rb, ro from reservations where branch_id = '00000000-0000-0000-0000-000000000010' limit 1;
  if rid is null then raise exception 'HISTORY PART B: no reservation fixture'; end if;
  create temp table hb(rid uuid, rb uuid, ro uuid); insert into hb values (rid, rb, ro); grant all on hb to authenticated;
end $$;
insert into staff_profiles(id,auth_user_id,organization_id,full_name,email,role) select * from (values
 ('fc100000-0000-4000-8000-000000000001'::uuid,'fc200000-0000-4000-8000-000000000001'::uuid,(select ro from hb),'R1 no grant','hb1@example.test','supervisor'::role_code),
 ('fc100000-0000-4000-8000-000000000002','fc200000-0000-4000-8000-000000000002',(select ro from hb),'R2 grant','hb2@example.test','supervisor'),
 ('fc100000-0000-4000-8000-000000000003','fc200000-0000-4000-8000-000000000003',(select ro from hb),'R3 grant other branch','hb3@example.test','supervisor'),
 ('fc100000-0000-4000-8000-000000000004','fc200000-0000-4000-8000-000000000004',(select ro from hb),'R4 grant no reservations page','hb4@example.test','supervisor'),
 ('fc100000-0000-4000-8000-000000000005','fc200000-0000-4000-8000-000000000005',(select ro from hb),'R5 grant removed','hb5@example.test','supervisor'),
 ('fc100000-0000-4000-8000-000000000006','fc200000-0000-4000-8000-000000000006',(select ro from hb),'R6 grant inactive','hb6@example.test','supervisor')) v;
insert into branch_memberships(staff_id,branch_id,organization_id) select s.id, case when s.id = 'fc100000-0000-4000-8000-000000000003' then '00000000-0000-0000-0000-000000000012'::uuid else (select rb from hb) end, (select ro from hb)
  from staff_profiles s where s.id::text like 'fc100000-%';
insert into staff_page_access(staff_id,organization_id,enabled,page_grants,sensitive_grants)
  select s.id, (select ro from hb), true,
    case when s.id = 'fc100000-0000-4000-8000-000000000004' then '{"/admin/audit-logs":{"view":true}}'::jsonb else '{"/staff/reservations":{"view":true}}'::jsonb end,
    case when s.id = 'fc100000-0000-4000-8000-000000000001' then '[]'::jsonb else '["history.details"]'::jsonb end
  from staff_profiles s where s.id::text like 'fc100000-%';
insert into audit_events(organization_id,branch_id,action,entity_type,entity_id,details) select ro, rb, 'reservation.total_changed','reservation', rid,
  '{"reason":"HB-REASON","before":{"total_halalas":333},"after":{"total_halalas":444}}' from hb;
create function pg_temp.hist(uid text, out ok boolean, out has_hist boolean, out has_before boolean, out reason_seen boolean, out err text) language plpgsql as $$
declare d jsonb; h jsonb; begin
  perform set_config('request.jwt.claim.sub',uid,false);
  begin d := fn_reservation_detail((select rid from hb)); ok := true;
  exception when others then ok := false; err := sqlerrm; return; end;
  select e into h from jsonb_array_elements(coalesce(d->'history','[]'::jsonb)) e where e->>'action'='reservation.total_changed' limit 1;
  has_hist := h is not null; has_before := (h->'details'->'before') is not null or (h->'details'->'after') is not null; reason_seen := (h->'details'->>'reason') = 'HB-REASON';
end $$;
grant execute on function pg_temp.hist(text) to authenticated;
-- R5 / R6: grant removed and account inactive (done as the table owner, before switching role)
update staff_page_access set sensitive_grants = '[]' where staff_id = 'fc100000-0000-4000-8000-000000000005';
update staff_profiles set is_active = false where id = 'fc100000-0000-4000-8000-000000000006';
create temp table resb(name text primary key, ok boolean not null); grant all on resb to authenticated;
set role authenticated;
do $$ declare p record; begin
  select * into p from pg_temp.hist('fc200000-0000-4000-8000-000000000001');
  insert into resb values('B1 individual member WITHOUT grant: history row and reason present, before/after ABSENT in the raw RPC', p.ok and p.has_hist and p.reason_seen and not p.has_before);
  select * into p from pg_temp.hist('fc200000-0000-4000-8000-000000000002');
  insert into resb values('B2 individual member WITH grant: before/after present in the raw RPC', p.ok and p.has_hist and p.has_before and p.reason_seen);
  select * into p from pg_temp.hist('fc200000-0000-4000-8000-000000000003');
  insert into resb values('B3 grant but NOT a member of the reservation branch: no reservation at all (branch guard preserved)', coalesce(not p.ok, false) or coalesce(not p.has_hist, true));
  select * into p from pg_temp.hist('fc200000-0000-4000-8000-000000000004');
  insert into resb values('B4 grant but no /staff/reservations view: refused (reservation page guard preserved)', not p.ok);
  select * into p from pg_temp.hist('fc200000-0000-4000-8000-000000000005');
  insert into resb values('B5 grant REMOVED: before/after absent', p.ok and p.has_hist and not p.has_before);
  select * into p from pg_temp.hist('fc200000-0000-4000-8000-000000000006');
  insert into resb values('B6 inactive account: refused or no details', not p.ok or not p.has_before);
end $$;
reset role;
-- B7 / B8: the grant is honored only while the catalog row exists and is not locked (test-only wrapper, rolled back with the transaction)
alter function fn_permission_catalog() rename to fn_permission_catalog_orig_hd;
create function fn_permission_catalog() returns table(code text, label text, area text, sort integer, default_roles role_code[], full_roles role_code[], limit_note text, locked boolean)
  language sql stable set search_path to 'public' as $$ select o.code, o.label, o.area, o.sort, o.default_roles, o.full_roles, o.limit_note, (o.locked or o.code = 'history.details') from fn_permission_catalog_orig_hd() o $$;
grant execute on function fn_permission_catalog() to authenticated;
set role authenticated;
do $$ declare p record; begin
  select * into p from pg_temp.hist('fc200000-0000-4000-8000-000000000002');
  insert into resb values('B7 grant present but catalog row LOCKED: before/after absent', p.ok and p.has_hist and not p.has_before);
end $$;
reset role;
drop function fn_permission_catalog();
create function fn_permission_catalog() returns table(code text, label text, area text, sort integer, default_roles role_code[], full_roles role_code[], limit_note text, locked boolean)
  language sql stable set search_path to 'public' as $$ select o.* from fn_permission_catalog_orig_hd() o where o.code <> 'history.details' $$;
grant execute on function fn_permission_catalog() to authenticated;
set role authenticated;
do $$ declare p record; begin
  select * into p from pg_temp.hist('fc200000-0000-4000-8000-000000000002');
  insert into resb values('B8 grant present but code UNKNOWN to the catalog: before/after absent', p.ok and p.has_hist and not p.has_before);
end $$;
reset role;
table resb;
do $$ begin if exists(select 1 from resb where not ok) then raise exception 'HISTORY DETAILS PART B FAILED'; end if; end $$;
rollback;
