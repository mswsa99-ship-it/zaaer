-- LOCAL SYNTHETIC seam proof, not an e-invoice authority integration or acceptance certificate.
-- Run only on a disposable local migrated test database. All fixtures and changes roll back.
-- 0091's reported-state prerequisite is a non-NULL e_invoice_ref. No production function is mocked.
\set ON_ERROR_STOP on
begin;
create schema einvproof;
create function einvproof.id(n int) returns uuid language sql immutable as $$ select ('e1910000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid $$;
create table einvproof.state(k text primary key,v uuid);
grant usage on schema einvproof to authenticated;
grant select,insert on einvproof.state to authenticated;
grant execute on function einvproof.id(int) to authenticated;
insert into organizations(id,name_ar) values(einvproof.id(1),'Synthetic invoice A'),(einvproof.id(2),'Synthetic invoice B');
insert into branches(id,organization_id,name_ar) values(einvproof.id(11),einvproof.id(1),'Invoice A1'),(einvproof.id(12),einvproof.id(1),'Invoice A2'),(einvproof.id(21),einvproof.id(2),'Invoice B1');
insert into staff_profiles(id,auth_user_id,organization_id,full_name,email,role) values
 (einvproof.id(101),einvproof.id(201),einvproof.id(1),'Invoice owner','invoice-owner@invalid.test','owner'),
 (einvproof.id(102),einvproof.id(202),einvproof.id(1),'Invoice manager','invoice-manager@invalid.test','manager'),
 (einvproof.id(103),einvproof.id(203),einvproof.id(2),'Other owner','invoice-other@invalid.test','owner');
insert into branch_memberships(staff_id,branch_id) values(einvproof.id(102),einvproof.id(12));
select set_config('request.jwt.claim.sub',einvproof.id(201)::text,true);
set local role authenticated;
do $$ declare cat uuid; src uuid; r uuid; inv uuid; j jsonb; begin
 cat := (fn_admin_upsert_room_category(jsonb_build_object('branch_id',einvproof.id(11),'name_ar','Synthetic invoice category','base_capacity',2,'max_capacity',3,'base_price_halalas',12000))->>'id')::uuid;
 src := (fn_admin_upsert_source('{"name":"Synthetic invoice direct","kind":"direct"}'::jsonb)->>'id')::uuid;
 r := (fn_staff_create_reservation(jsonb_build_object('branch_id',einvproof.id(11),'category_id',cat,'check_in',fn_branch_today(einvproof.id(11))+400,'check_out',fn_branch_today(einvproof.id(11))+402,'guest_name','Synthetic Invoice Guest','guest_phone','0551987654','source_id',src))->>'id')::uuid;
 inv := (fn_staff_issue_invoice(jsonb_build_object('reservation_id',r))->>'id')::uuid;
 insert into einvproof.state values('reservation',r),('invoice',inv);
end $$;
reset role;
-- Only synthetic state injection: simulate the persisted result of external reporting. No outbound call exists here.
update invoices set e_invoice_ref='SYNTHETIC-LOCAL-NOT-REPORTED' where id=(select v from einvproof.state where k='invoice');
do $$ declare inv invoices%rowtype; begin
 select * into inv from invoices where id=(select v from einvproof.state where k='invoice');
 assert inv.doc_kind='invoice' and inv.status='issued' and inv.total_halalas>0, 'real issued positive invoice';
 assert inv.e_invoice_ref='SYNTHETIC-LOCAL-NOT-REPORTED', 'explicit synthetic seam';
end $$;
set local role authenticated;
-- Foreign branch/hotel denials use real roles. Following assertions check credit-note/review/audit absence.
do $$ declare actor uuid; begin
 foreach actor in array array[einvproof.id(202),einvproof.id(203)] loop
  perform set_config('request.jwt.claim.sub',actor::text,true);
  begin
   perform fn_issue_credit_note((select v from einvproof.state where k='invoice'),'Synthetic forbidden attempt');
   raise exception 'PROOF_UNEXPECTED_SUCCESS';
  exception when others then
   assert sqlstate='42501' and sqlerrm like 'FORBIDDEN%', 'real branch/hotel permission denial';
  end;
 end loop;
end $$;
reset role;
do $$ begin
 assert not exists(select 1 from invoices where credit_note_of=(select v from einvproof.state where k='invoice')), 'foreign attempts create no credit note';
 assert not exists(select 1 from review_items where organization_id=einvproof.id(1) and kind='invoice_credit_note'), 'foreign attempts create no credit review';
 assert not exists(select 1 from audit_events where organization_id=einvproof.id(1) and action='invoice.credit_note'), 'foreign attempts create no credit audit';
end $$;
select set_config('request.jwt.claim.sub',einvproof.id(201)::text,true);
set local role authenticated;
do $$ declare j jsonb; begin
 begin perform fn_cancel_invoice((select v from einvproof.state where k='invoice'),'Synthetic cancel'); raise exception 'PROOF_UNEXPECTED_SUCCESS';
 exception when others then assert sqlerrm='E_INVOICED_USE_CREDIT_NOTE', 'reported original cannot be cancelled'; end;
 begin perform fn_issue_credit_note((select v from einvproof.state where k='invoice'),''); raise exception 'PROOF_UNEXPECTED_SUCCESS';
 exception when others then assert sqlerrm like 'VALIDATION: reason%', 'reason required'; end;
 j:=fn_issue_credit_note((select v from einvproof.state where k='invoice'),'Synthetic local credit');
 assert (j->>'ok')::boolean is true, 'real credit RPC succeeds';
 insert into einvproof.state values('credit',(j->>'id')::uuid);
 begin perform fn_issue_credit_note((select v from einvproof.state where k='invoice'),'Duplicate'); raise exception 'PROOF_UNEXPECTED_SUCCESS';
 exception when others then assert sqlerrm='CREDIT_NOTE_EXISTS', 'unique credit guard'; end;
end $$;
reset role;
do $$ declare inv invoices%rowtype; cn invoices%rowtype; begin
 select * into inv from invoices where id=(select v from einvproof.state where k='invoice');
 select * into cn from invoices where id=(select v from einvproof.state where k='credit');
 assert inv.status='issued' and inv.doc_kind='invoice', 'original remains issued';
 assert cn.doc_kind='credit_note' and cn.origin='credit_note' and cn.status='issued' and cn.credit_note_of=inv.id, 'credit shape and exact parent';
 assert cn.reservation_id=inv.reservation_id and cn.branch_id=inv.branch_id and cn.organization_id=inv.organization_id, 'credit same stay/branch/hotel';
 assert (cn.subtotal_halalas,cn.tax_halalas,cn.total_halalas)=(inv.subtotal_halalas,inv.tax_halalas,inv.total_halalas), 'exact original amounts';
 assert cn.snapshot=inv.snapshot and cn.bill_to=inv.bill_to and cn.e_invoice_ref=inv.e_invoice_ref, 'exact snapshot and reporting marker';
 assert cn.number<>inv.number and (select count(*) from invoices where credit_note_of=inv.id)=1, 'distinct number exactly one credit';
 assert (select count(*) from review_items where kind='invoice_credit_note' and entity_id=cn.id and reservation_id=inv.reservation_id)=1, 'one exact review';
 assert (select count(*) from audit_events where action='invoice.credit_note' and entity_id=cn.id)=1, 'one exact audit';
end $$;
select 'LOCAL SYNTHETIC SEAM PROOF COMPLETED, NOT AUTHORITY REPORTING' as result;
rollback;
