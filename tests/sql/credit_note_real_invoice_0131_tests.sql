-- LOCAL targeted test (executor-written, adapted from tests/sql/phase4_controls_tests.sql section 4.9 fixtures and tests/sql/security_tests.sql staff fixtures).
-- Real issued, e-invoiced invoices on seeded branch 010; individual and legacy callers; reason, review item, audit, cross-hotel, side effects. All in one transaction, rolled back.
\set ON_ERROR_STOP on
begin;
create temp table res(name text primary key, ok boolean not null, detail text);
grant all on res to public;
create temp table ids(k text primary key, v uuid);
grant all on ids to public;
-- security_tests.sql fixtures (second hotel, owner, owner2, supervisor)
insert into organizations(id, name_ar) values ('00000000-0000-0000-0000-000000000002','منشأة أخرى') on conflict do nothing;
insert into branches(id, organization_id, name_ar) values ('00000000-0000-0000-0000-000000000011','00000000-0000-0000-0000-000000000002','فرع آخر') on conflict do nothing;
insert into staff_profiles(id, auth_user_id, organization_id, full_name, email, role) values
 ('10000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','المالك','owner@test.local','owner'),
 ('10000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001','مشرف','sup@test.local','supervisor'),
 ('10000000-0000-0000-0000-000000000005','a0000000-0000-0000-0000-000000000005','00000000-0000-0000-0000-000000000002','مالك آخر','owner2@test.local','owner')
on conflict (id) do nothing;
-- new staff: individual managers (hotel 1: add only / delete), individual supervisor with delete, legacy manager, individual manager of hotel 2 with delete
insert into staff_profiles(id,auth_user_id,organization_id,full_name,email,role) values
 ('fe500000-0000-4000-8000-000000000002','fe600000-0000-4000-8000-000000000002','00000000-0000-0000-0000-000000000001','Ind mgr add only','rn-add@example.test','manager'),
 ('fe500000-0000-4000-8000-000000000003','fe600000-0000-4000-8000-000000000003','00000000-0000-0000-0000-000000000001','Ind mgr delete','rn-del@example.test','manager'),
 ('fe500000-0000-4000-8000-000000000005','fe600000-0000-4000-8000-000000000005','00000000-0000-0000-0000-000000000001','Legacy manager','rn-leg@example.test','manager'),
 ('fe500000-0000-4000-8000-000000000007','fe600000-0000-4000-8000-000000000007','00000000-0000-0000-0000-000000000001','Ind supervisor delete','rn-supdel@example.test','supervisor'),
 ('fe500000-0000-4000-8000-000000000009','fe600000-0000-4000-8000-000000000009','00000000-0000-0000-0000-000000000002','Hotel2 ind mgr delete','rn-h2@example.test','manager');
insert into branch_memberships(staff_id, branch_id) values
 ('fe500000-0000-4000-8000-000000000002','00000000-0000-0000-0000-000000000010'),
 ('fe500000-0000-4000-8000-000000000003','00000000-0000-0000-0000-000000000010'),
 ('fe500000-0000-4000-8000-000000000005','00000000-0000-0000-0000-000000000010'),
 ('fe500000-0000-4000-8000-000000000007','00000000-0000-0000-0000-000000000010'),
 ('fe500000-0000-4000-8000-000000000009','00000000-0000-0000-0000-000000000011') on conflict do nothing;
insert into staff_page_access(staff_id,organization_id,enabled,page_grants,sensitive_grants) values
 ('fe500000-0000-4000-8000-000000000002','00000000-0000-0000-0000-000000000001',true,'{"/staff/payments":{"view":true,"add":true}}','[]'),
 ('fe500000-0000-4000-8000-000000000003','00000000-0000-0000-0000-000000000001',true,'{"/staff/payments":{"view":true,"delete":true}}','[]'),
 ('fe500000-0000-4000-8000-000000000007','00000000-0000-0000-0000-000000000001',true,'{"/staff/payments":{"view":true,"delete":true}}','[]'),
 ('fe500000-0000-4000-8000-000000000009','00000000-0000-0000-0000-000000000002',true,'{"/staff/payments":{"view":true,"delete":true}}','[]');
create function pg_temp.login(uid text) returns void language sql as $$select set_config('request.jwt.claim.sub',uid,false)::text::void$$;
create function pg_temp.t_id(k text) returns uuid language sql security definer as $$ select v from ids where k=$1 $$;
create function pg_temp.today() returns date language sql security definer as $$ select fn_branch_today('00000000-0000-0000-0000-000000000010') $$;
grant execute on function pg_temp.today() to public;
-- fixtures (phase4 4.9 shape): two stays of branch 010 with issued invoices, both marked reported to the e-invoicing authority
select pg_temp.login('a0000000-0000-0000-0000-000000000001');
set role authenticated;
do $$ declare r jsonb; res uuid; inv jsonb; d date := pg_temp.today(); begin
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','name_ar','نوع إشعار دائن','base_capacity',2,'max_capacity',3,'base_price_halalas',10000));
  insert into ids values ('cat',(r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','category_id',pg_temp.t_id('cat'),'room_number','CN-1'));
  insert into ids values ('u1',(r->>'id')::uuid);
  r := fn_staff_create_reservation(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','category_id',pg_temp.t_id('cat'),'room_id',pg_temp.t_id('u1'),'check_in',d+500,'check_out',d+503,'guest_name','ضيف إشعار دائن','guest_phone','0500077111','source_id','00000000-0000-0000-0000-000000000021'));
  inv := fn_staff_issue_invoice(jsonb_build_object('reservation_id',(r->>'id')::uuid)); insert into ids values ('invA',(inv->>'id')::uuid);
  r := fn_staff_create_reservation(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','category_id',pg_temp.t_id('cat'),'room_id',pg_temp.t_id('u1'),'check_in',d+520,'check_out',d+522,'guest_name','ضيف إشعار دائن ثان','guest_phone','0500077222','source_id','00000000-0000-0000-0000-000000000021'));
  inv := fn_staff_issue_invoice(jsonb_build_object('reservation_id',(r->>'id')::uuid)); insert into ids values ('invB',(inv->>'id')::uuid);
end $$;
reset role;
update invoices set e_invoice_ref='EINV-CN-A' where id=pg_temp.t_id('invA');
update invoices set e_invoice_ref='EINV-CN-B' where id=pg_temp.t_id('invB');
create function pg_temp.call(uid text, inv uuid, reason text, out st text, out msg text, out cn uuid) language plpgsql as $$
declare j jsonb;
begin
  perform pg_temp.login(uid);
  begin j := fn_issue_credit_note(inv, reason); st:='ok'; msg:=''; cn:=(j->>'id')::uuid;
  exception when others then st:=sqlstate; msg:=sqlerrm; cn:=null; end;
end $$;
create function pg_temp.effects(inv uuid) returns text language sql security definer as $$
  select (select count(*) from invoices where credit_note_of=$1)||'/'||(select count(*) from review_items where kind='invoice_credit_note')||'/'||(select count(*) from audit_events where action='invoice.credit_note') $$;
select pg_temp.effects(pg_temp.t_id('invA')) as eff0 \gset
set role authenticated;
-- R1: individual manager with payments add only, REAL e-invoiced invoice: denied by the delete gate, nothing written
insert into res select 'R1 add-only individual manager denied on a real invoice, no credit note/review/audit', st='42501' and msg like 'FORBIDDEN: page /staff/payments action delete%' and pg_temp.effects(pg_temp.t_id('invA'))=:'eff0', st||' '||msg||' eff='||pg_temp.effects(pg_temp.t_id('invA')) from pg_temp.call('fe600000-0000-4000-8000-000000000002', pg_temp.t_id('invA'), 'add only attempt');
-- R2: delete-granted individual manager, empty reason: mandatory reason holds, nothing written
insert into res select 'R2 delete individual manager: empty reason refused, no effect', st='P0001' and msg like 'VALIDATION: reason%' and pg_temp.effects(pg_temp.t_id('invA'))=:'eff0', st||' '||msg from pg_temp.call('fe600000-0000-4000-8000-000000000003', pg_temp.t_id('invA'), '');
-- R3: individual supervisor with delete: role list still stops it, nothing written
insert into res select 'R3 individual supervisor with delete stopped by role list, no effect', st='42501' and msg like 'FORBIDDEN%' and msg not like 'FORBIDDEN: page%' and pg_temp.effects(pg_temp.t_id('invA'))=:'eff0', st||' '||msg from pg_temp.call('fe600000-0000-4000-8000-000000000007', pg_temp.t_id('invA'), 'supervisor attempt');
-- R4: other hotel's individual manager WITH delete on payments: passes the page gate in its own hotel, refused for our invoice, nothing written
insert into res select 'R4 other-hotel individual manager with delete cannot credit-note our invoice, no effect', st='42501' and pg_temp.effects(pg_temp.t_id('invA'))=:'eff0', st||' '||msg from pg_temp.call('fe600000-0000-4000-8000-000000000009', pg_temp.t_id('invA'), 'cross hotel attempt');
-- R5: POSITIVE: delete-granted individual manager issues the credit note with a reason
create temp table pos as select * from pg_temp.call('fe600000-0000-4000-8000-000000000003', pg_temp.t_id('invA'), 'إلغاء بعد التبليغ الإلكتروني (فردي)');
grant all on pos to public;
reset role;
insert into res select 'R5 delete individual manager issues the credit note (real invoice)', (select st from pos)='ok' and exists (select 1 from invoices c join invoices o on o.id=c.credit_note_of where c.id=(select cn from pos) and o.id=pg_temp.t_id('invA') and c.doc_kind='credit_note' and c.total_halalas=o.total_halalas and c.subtotal_halalas=o.subtotal_halalas and c.tax_halalas=o.tax_halalas and c.status='issued' and c.issued_by='fe500000-0000-4000-8000-000000000003'), (select st||' '||msg from pos);
insert into res select 'R6 review item carries the reason and audit event is attributed to the caller', exists (select 1 from review_items where kind='invoice_credit_note' and entity_id=(select cn from pos) and reason like '%فردي%') and exists (select 1 from audit_events where action='invoice.credit_note' and entity_id=(select cn from pos) and actor_id='fe500000-0000-4000-8000-000000000003'), null;
set role authenticated;
-- R7: a second credit note on the same invoice is refused (impl rule still reached by the granted caller)
insert into res select 'R7 second credit note on the same invoice refused', msg like 'CREDIT_NOTE_EXISTS%', st||' '||msg from pg_temp.call('fe600000-0000-4000-8000-000000000003', pg_temp.t_id('invA'), 'second');
-- R8: legacy manager (no page access row) still issues on the second invoice
create temp table pos2 as select * from pg_temp.call('fe600000-0000-4000-8000-000000000005', pg_temp.t_id('invB'), 'legacy manager credit note');
grant all on pos2 to public;
reset role;
insert into res select 'R8 legacy manager still issues a credit note on a real invoice', (select st from pos2)='ok' and exists (select 1 from invoices where id=(select cn from pos2) and doc_kind='credit_note' and credit_note_of=pg_temp.t_id('invB')), (select st||' '||msg from pos2);
select case when ok then 'PASS' else 'FAIL' end as result, name, left(detail,110) as detail from res order by name;
select 'TOTAL', count(*) filter (where ok) as passed, count(*) as total from res;
do $$ begin if exists (select 1 from res where not ok) then raise exception 'CREDIT NOTE REAL INVOICE TESTS FAILED'; end if; end $$;
rollback;
