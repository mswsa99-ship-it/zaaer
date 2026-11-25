-- UNRUN executable test. Run on migrations + expense_category_candidate_UNRUN.sql (psql -f, from repo root). Self-contained synthetic tenant, rolled back.
-- Page choice /staff/expenses is an ASSUMPTION (not a user ruling). Denial credit = SQLSTATE 42501 with a passing control in the same fixture and zero effect.
-- Run it twice: on migrations only (baseline: every individual non-owner is denied, so X2/X3/X11-control cells are EXPECTED RED there; X5-X9 invariance cells must be identical) and with the candidate.
\set ON_ERROR_STOP on
begin;
insert into organizations(id,name_ar) values('fa000000-0000-4000-8000-000000000001','EC tenant A'),('fa000000-0000-4000-8000-000000000002','EC tenant B');
insert into staff_profiles(id,auth_user_id,organization_id,full_name,email,role) values
('fa100000-0000-4000-8000-000000000001','fa200000-0000-4000-8000-000000000001','fa000000-0000-4000-8000-000000000001','Owner','ec-owner@example.test','owner'),
('fa100000-0000-4000-8000-000000000002','fa200000-0000-4000-8000-000000000002','fa000000-0000-4000-8000-000000000001','Ind view only','ec-i1@example.test','manager'),
('fa100000-0000-4000-8000-000000000003','fa200000-0000-4000-8000-000000000003','fa000000-0000-4000-8000-000000000001','Ind view+add','ec-i2@example.test','manager'),
('fa100000-0000-4000-8000-000000000004','fa200000-0000-4000-8000-000000000004','fa000000-0000-4000-8000-000000000001','Ind view+edit','ec-i3@example.test','manager'),
('fa100000-0000-4000-8000-000000000005','fa200000-0000-4000-8000-000000000005','fa000000-0000-4000-8000-000000000001','Ind bank page only','ec-i4@example.test','manager'),
('fa100000-0000-4000-8000-000000000006','fa200000-0000-4000-8000-000000000006','fa000000-0000-4000-8000-000000000001','Ind add+edit no view','ec-i5@example.test','manager'),
('fa100000-0000-4000-8000-000000000007','fa200000-0000-4000-8000-000000000007','fa000000-0000-4000-8000-000000000001','Ind delete+export only','ec-i6@example.test','manager'),
('fa100000-0000-4000-8000-000000000008','fa200000-0000-4000-8000-000000000008','fa000000-0000-4000-8000-000000000001','Legacy manager','ec-m@example.test','manager'),
('fa100000-0000-4000-8000-000000000009','fa200000-0000-4000-8000-000000000009','fa000000-0000-4000-8000-000000000001','Legacy supervisor','ec-s@example.test','supervisor'),
('fa100000-0000-4000-8000-00000000000a','fa200000-0000-4000-8000-00000000000a','fa000000-0000-4000-8000-000000000001','Ind disabled row (legacy)','ec-i7@example.test','manager'),
('fa100000-0000-4000-8000-00000000000b','fa200000-0000-4000-8000-00000000000b','fa000000-0000-4000-8000-000000000002','Other tenant owner','ec-o@example.test','owner');
insert into staff_page_access(staff_id,organization_id,enabled,page_grants) values
('fa100000-0000-4000-8000-000000000002','fa000000-0000-4000-8000-000000000001',true,'{"/staff/expenses":{"view":true}}'),
('fa100000-0000-4000-8000-000000000003','fa000000-0000-4000-8000-000000000001',true,'{"/staff/expenses":{"view":true,"add":true}}'),
('fa100000-0000-4000-8000-000000000004','fa000000-0000-4000-8000-000000000001',true,'{"/staff/expenses":{"view":true,"edit":true}}'),
('fa100000-0000-4000-8000-000000000005','fa000000-0000-4000-8000-000000000001',true,'{"/staff/bank":{"view":true,"add":true,"edit":true}}'),
('fa100000-0000-4000-8000-000000000006','fa000000-0000-4000-8000-000000000001',true,'{"/staff/expenses":{"add":true,"edit":true}}'),
('fa100000-0000-4000-8000-000000000007','fa000000-0000-4000-8000-000000000001',true,'{"/staff/expenses":{"view":true,"delete":true,"export":true}}'),
('fa100000-0000-4000-8000-00000000000a','fa000000-0000-4000-8000-000000000001',false,'{}');
insert into expense_categories(id,organization_id,name,sort_order) values
('fa300000-0000-4000-8000-000000000001','fa000000-0000-4000-8000-000000000001','EC-seed',5),
('fa300000-0000-4000-8000-000000000002','fa000000-0000-4000-8000-000000000002','EC-other-tenant',5);
create temp table res(name text primary key, ok boolean not null, detail text);
grant all on res to authenticated;
create function pg_temp.login(uid text) returns void language sql as $$select set_config('request.jwt.claim.sub',uid,false)::text::void$$;
-- attempt(uid, payload): 'ok' when accepted, else the SQLSTATE
create function pg_temp.att(uid text, pl jsonb) returns text language plpgsql as $$
begin perform pg_temp.login(uid); perform fn_admin_upsert_expense_category(pl); return 'ok';
exception when others then return sqlstate; end $$;
grant execute on function pg_temp.att(text,jsonb) to authenticated;
create function pg_temp.ver() returns int language sql security definer as $$select version from expense_categories where id='fa300000-0000-4000-8000-000000000001'$$;
create function pg_temp.cnt() returns int language sql security definer as $$select count(*)::int from expense_categories where organization_id='fa000000-0000-4000-8000-000000000001'$$;
grant execute on function pg_temp.ver(), pg_temp.cnt() to authenticated;
create function pg_temp.u(n int) returns text language sql as $$select 'fa200000-0000-4000-8000-00000000000'||to_hex(n)$$;
set role authenticated;
do $$ declare r text; c0 int; v0 int; seed text := 'fa300000-0000-4000-8000-000000000001'; begin
  c0 := pg_temp.cnt(); v0 := pg_temp.ver();
  -- X1 view only: both denied, zero effect
  r := pg_temp.att(pg_temp.u(2), '{"name":"X1-new"}'); insert into res values('X1a view-only create denied 42501, zero effect', r='42501' and pg_temp.cnt()=c0, r);
  r := pg_temp.att(pg_temp.u(2), jsonb_build_object('id',seed,'name','X1-ren','version',v0)); insert into res values('X1b view-only update denied 42501, zero effect', r='42501' and pg_temp.ver()=v0, r);
  -- X2 view+add: create ok (this is also the control for X1a), update denied
  r := pg_temp.att(pg_temp.u(3), jsonb_build_object('id',seed,'name','X2-ren','version',v0)); insert into res values('X2a add-only update denied 42501, zero effect', r='42501' and pg_temp.ver()=v0, r);
  r := pg_temp.att(pg_temp.u(3), '{"name":"X2-new"}'); insert into res values('X2b add-only create accepted (control)', r='ok' and pg_temp.cnt()=c0+1, r);
  c0 := pg_temp.cnt();
  -- X3 view+edit: update ok (control for X1b), create denied
  r := pg_temp.att(pg_temp.u(4), '{"name":"X3-new"}'); insert into res values('X3a edit-only create denied 42501, zero effect', r='42501' and pg_temp.cnt()=c0, r);
  r := pg_temp.att(pg_temp.u(4), jsonb_build_object('id',seed,'name','X3-ren','version',v0,'is_active',false)); insert into res values('X3b edit-only update accepted incl is_active (control)', r='ok' and pg_temp.ver()=v0+1, r);
  v0 := pg_temp.ver();
  -- X4 grants on another page do not open expenses categories
  r := pg_temp.att(pg_temp.u(5), '{"name":"X4-new"}'); insert into res values('X4a bank-page add denied 42501', r='42501' and pg_temp.cnt()=c0, r);
  r := pg_temp.att(pg_temp.u(5), jsonb_build_object('id',seed,'name','X4-ren','version',v0)); insert into res values('X4b bank-page edit denied 42501', r='42501' and pg_temp.ver()=v0, r);
  -- X5 add/edit without view
  r := pg_temp.att(pg_temp.u(6), '{"name":"X5-new"}'); insert into res values('X5a no-view create denied 42501', r='42501' and pg_temp.cnt()=c0, r);
  r := pg_temp.att(pg_temp.u(6), jsonb_build_object('id',seed,'name','X5-ren','version',v0)); insert into res values('X5b no-view update denied 42501', r='42501' and pg_temp.ver()=v0, r);
  -- X9 delete/export do not map to create or update
  r := pg_temp.att(pg_temp.u(7), '{"name":"X9-new"}'); insert into res values('X9a delete+export create denied 42501', r='42501' and pg_temp.cnt()=c0, r);
  r := pg_temp.att(pg_temp.u(7), jsonb_build_object('id',seed,'name','X9-ren','version',v0)); insert into res values('X9b delete+export update denied 42501', r='42501' and pg_temp.ver()=v0, r);
  -- invariance (identical on baseline and candidate): owner, legacy manager, legacy supervisor, disabled-row account
  r := pg_temp.att(pg_temp.u(1), '{"name":"X8-owner-new"}'); insert into res values('X8a owner create accepted', r='ok', r);
  r := pg_temp.att(pg_temp.u(8), '{"name":"X6-mgr-new"}'); insert into res values('X6a legacy manager create == fn_can(definitions)', (r='ok') = (select fn_can('definitions')), r);
  c0 := pg_temp.cnt(); r := pg_temp.att(pg_temp.u(9), '{"name":"X7-sup-new"}'); insert into res values('X7a legacy supervisor create refused 42501 by cap definitions (catalog default roles owner,manager), zero effect', r='42501' and pg_temp.cnt()=c0, r);
  r := pg_temp.att(pg_temp.u(10), '{"name":"X6-disabled-new"}'); insert into res values('X6b enabled=false account create == fn_can(definitions) (legacy baseline)', (r='ok') = (select fn_can('definitions')), r);
  -- X10 not credited: another tenant id is not a denial, recorded as a fact only
  r := pg_temp.att(pg_temp.u(4), '{"id":"fa300000-0000-4000-8000-000000000002","name":"X10","version":1}');
  insert into res values('X10 (NO CREDIT) individual edit of other-tenant id: result recorded', r<>'ok', r);
  -- empty-string id keeps baseline behaviour (uuid cast error, 22P02) for an allowed caller
  r := pg_temp.att(pg_temp.u(1), '{"id":"","name":"X12-empty"}'); insert into res values('X12 owner empty-string id: baseline cast error 22P02 preserved', r='22P02', r);
end $$;
reset role;
table res;
do $$ begin if exists(select 1 from res where not ok) then raise exception 'EXPENSE CATEGORY TESTS: % cells RED (expected on baseline: X2b X3b)', (select count(*) from res where not ok); end if; end $$;
rollback;
