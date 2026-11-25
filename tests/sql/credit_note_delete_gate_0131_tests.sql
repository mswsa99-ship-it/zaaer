-- UNRUN local test source for credit_note_delete_gate_CANDIDATE.sql. Synthetic data only, rolled back. Needs all migrations applied first.
-- Covers the GATE layer: with the candidate, an individual manager with payments 'add' only is denied BEFORE the impl runs; 'delete' reaches the impl.
-- A nonexistent invoice id is used on purpose: a denial must be an attributed 42501 page error, and a granted caller must get NOT_FOUND from the impl
-- (valid control, not a denial). Side effects (review item, audit, credit note rows) are asserted unchanged.
-- NOT covered here (fixture not grounded standalone): reason/review/audit of a real credit note and cross-hotel invoice effects. tests/sql/phase4_controls_tests.sql
-- section 4.9 already covers those for legacy accounts and must still pass unchanged after the candidate.
\set ON_ERROR_STOP on
begin;
insert into organizations(id,name_ar) values('fd400000-0000-4000-8000-000000000001','CN tenant A'),('fd400000-0000-4000-8000-000000000002','CN tenant B');
insert into staff_profiles(id,auth_user_id,organization_id,full_name,email,role) values
('fd500000-0000-4000-8000-000000000001','fd600000-0000-4000-8000-000000000001','fd400000-0000-4000-8000-000000000001','Owner','cn-owner@example.test','owner'),
('fd500000-0000-4000-8000-000000000002','fd600000-0000-4000-8000-000000000002','fd400000-0000-4000-8000-000000000001','Ind mgr add only','cn-add@example.test','manager'),
('fd500000-0000-4000-8000-000000000003','fd600000-0000-4000-8000-000000000003','fd400000-0000-4000-8000-000000000001','Ind mgr delete','cn-del@example.test','manager'),
('fd500000-0000-4000-8000-000000000004','fd600000-0000-4000-8000-000000000004','fd400000-0000-4000-8000-000000000001','Ind mgr view only','cn-view@example.test','manager'),
('fd500000-0000-4000-8000-000000000005','fd600000-0000-4000-8000-000000000005','fd400000-0000-4000-8000-000000000001','Legacy manager','cn-leg@example.test','manager'),
('fd500000-0000-4000-8000-000000000006','fd600000-0000-4000-8000-000000000006','fd400000-0000-4000-8000-000000000001','Legacy supervisor','cn-sup@example.test','supervisor'),
('fd500000-0000-4000-8000-000000000007','fd600000-0000-4000-8000-000000000007','fd400000-0000-4000-8000-000000000001','Ind supervisor delete','cn-supdel@example.test','supervisor'),
('fd500000-0000-4000-8000-000000000008','fd600000-0000-4000-8000-000000000008','fd400000-0000-4000-8000-000000000001','Ind mgr delete wrong page','cn-wrong@example.test','manager');
insert into staff_page_access(staff_id,organization_id,enabled,page_grants,sensitive_grants) values
('fd500000-0000-4000-8000-000000000002','fd400000-0000-4000-8000-000000000001',true,'{"/staff/payments":{"view":true,"add":true}}','[]'),
('fd500000-0000-4000-8000-000000000003','fd400000-0000-4000-8000-000000000001',true,'{"/staff/payments":{"view":true,"delete":true}}','[]'),
('fd500000-0000-4000-8000-000000000004','fd400000-0000-4000-8000-000000000001',true,'{"/staff/payments":{"view":true}}','[]'),
('fd500000-0000-4000-8000-000000000007','fd400000-0000-4000-8000-000000000001',true,'{"/staff/payments":{"view":true,"delete":true}}','[]'),
('fd500000-0000-4000-8000-000000000008','fd400000-0000-4000-8000-000000000001',true,'{"/staff/reservations":{"view":true,"delete":true}}','[]');
create temp table res(name text primary key, ok boolean not null, detail text);
grant all on res to authenticated;
create function pg_temp.login(uid text) returns void language sql as $$select set_config('request.jwt.claim.sub',uid,false)::text::void$$;
-- returns the SQLSTATE and message of the call
create function pg_temp.call(uid text, out st text, out msg text) language plpgsql as $$
begin
  perform pg_temp.login(uid);
  begin perform fn_issue_credit_note('fd700000-0000-4000-8000-0000000000aa'::uuid, 'gate test'); st := 'ok'; msg := '';
  exception when others then st := sqlstate; msg := sqlerrm; end;
end $$;
select count(*) as review_before from review_items \gset
select count(*) as audit_before from audit_events \gset
select count(*) as inv_before from invoices \gset
set role authenticated;
-- individual manager, payments add only: DENIED by the page gate (attributed 42501), not by NOT_FOUND
insert into res select 'T1 individual manager with add only is denied by the delete gate', st='42501' and msg like 'FORBIDDEN: page /staff/payments action delete%', st||' '||msg from pg_temp.call('fd600000-0000-4000-8000-000000000002');
-- view only and wrong page: denied
insert into res select 'T2 individual manager with view only is denied', st='42501' and msg like 'FORBIDDEN: page /staff/payments action delete%', st||' '||msg from pg_temp.call('fd600000-0000-4000-8000-000000000004');
insert into res select 'T3 delete granted on another page is denied', st='42501' and msg like 'FORBIDDEN: page /staff/payments action delete%', st||' '||msg from pg_temp.call('fd600000-0000-4000-8000-000000000008');
-- delete granted, manager role: passes the gate and the role list, reaches the impl (NOT_FOUND = valid control, not a denial)
insert into res select 'T4 individual manager with delete reaches the impl', msg like 'NOT_FOUND%', st||' '||msg from pg_temp.call('fd600000-0000-4000-8000-000000000003');
-- delete granted but supervisor role: still stopped by the unchanged role list (ceiling not lifted)
insert into res select 'T5 individual supervisor with delete is still stopped by the role list', st='42501' and msg like 'FORBIDDEN%' and msg not like 'FORBIDDEN: page%', st||' '||msg from pg_temp.call('fd600000-0000-4000-8000-000000000007');
-- legacy accounts unchanged: manager reaches the impl, supervisor is refused by the role list
insert into res select 'T6 legacy manager reaches the impl', msg like 'NOT_FOUND%', st||' '||msg from pg_temp.call('fd600000-0000-4000-8000-000000000005');
insert into res select 'T7 legacy supervisor refused by the role list', st='42501' and msg like 'FORBIDDEN%' and msg not like 'FORBIDDEN: page%', st||' '||msg from pg_temp.call('fd600000-0000-4000-8000-000000000006');
reset role;
-- zero side effects from every call above
insert into res select 'T8 no review item, audit event or invoice was written', (select count(*) from review_items)=:review_before and (select count(*) from audit_events)=:audit_before and (select count(*) from invoices)=:inv_before, null;
-- the direct impl is not callable by the API role (existing 0110 property, kept)
set role authenticated;
insert into res select 'T9 the impl is not executable by authenticated', not has_function_privilege('authenticated','public.fn_issue_credit_note__impl(uuid,text)','execute'), null;
reset role;
select case when ok then 'PASS' else 'FAIL' end as result, name, detail from res order by name;
select 'TOTAL', count(*) filter (where ok) as passed, count(*) as total from res;
do $$ begin if exists (select 1 from res where not ok) then raise exception 'CREDIT NOTE GATE TESTS FAILED'; end if; end $$;
rollback;
