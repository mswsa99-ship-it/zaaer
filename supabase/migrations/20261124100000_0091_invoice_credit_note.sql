-- =====================================================================
-- 0084 (proposed number; the integrator renumbers) — plan 4.9 (M9 «إلغاء الفاتورة»).
--
--  The acceptance: a mandatory reason and a review item for every cancellation, and with e-invoicing a credit note
--  instead of a cancellation. fn_cancel_invoice (0036) already requires the owner or a manager, a non-empty reason,
--  writes the review item and audits; this migration adds the e-invoicing half:
--    * invoices.e_invoice_ref marks an invoice reported to the e-invoicing authority (null: not reported);
--    * an e-invoiced invoice is never cancelled — fn_cancel_invoice refuses with E_INVOICED_USE_CREDIT_NOTE;
--    * fn_issue_credit_note(p_invoice, p_reason) issues a credit note against it: same stay and amounts, its own
--      number, doc_kind 'credit_note' naming the original, one credit note per invoice, a mandatory reason, the
--      review item and the audit. The original stays 'issued' (the authority has it); the credit note offsets it.
-- =====================================================================

alter table invoices add column if not exists doc_kind text not null default 'invoice';
alter table invoices add column if not exists credit_note_of uuid references invoices(id);
alter table invoices add column if not exists e_invoice_ref text;
-- the credit note is a fourth origin
alter table invoices drop constraint if exists invoices_origin_chk;
alter table invoices add constraint invoices_origin_chk check (origin in ('manual', 'checkout', 'deposit_settled', 'credit_note'));
do $$ begin
  alter table invoices add constraint invoices_doc_kind_valid check (doc_kind in ('invoice', 'credit_note'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table invoices add constraint invoices_credit_note_shape check (
    (doc_kind = 'credit_note' and credit_note_of is not null and credit_note_of <> id)
    or (doc_kind = 'invoice' and credit_note_of is null));
exception when duplicate_object then null; end $$;
create unique index if not exists uniq_invoices_credit_note_of on invoices(credit_note_of) where credit_note_of is not null;

-- the credit note points at an invoice of the same hotel (0078's pointer guard gains the new column)
drop trigger if exists zz_hotel_pointers on public.invoices;
create trigger zz_hotel_pointers after insert or update of branch_id, reservation_id, updated_by, credit_note_of, organization_id on public.invoices
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'reservation_id', 'reservations', 'updated_by', 'staff_profiles', 'credit_note_of', 'invoices');

-- cancelling: identical to 0036, plus the e-invoicing guard — an invoice the authority has is never cancelled
create or replace function fn_cancel_invoice(p_invoice uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare inv invoices%rowtype; r reservations%rowtype;
begin
  perform fn_require_role('owner', 'manager');
  if coalesce(trim(p_reason), '') = '' then raise exception 'VALIDATION: reason'; end if;
  select * into inv from invoices where id = p_invoice;
  if not found then raise exception 'NOT_FOUND'; end if;
  select * into r from reservations where id = inv.reservation_id for update;
  perform fn_require_branch(inv.branch_id);
  select * into inv from invoices where id = inv.id for update;
  if inv.status <> 'issued' then raise exception 'INVOICE_STATUS_INVALID'; end if;
  if inv.doc_kind <> 'invoice' then raise exception 'INVOICE_STATUS_INVALID'; end if;
  if inv.e_invoice_ref is not null then raise exception 'E_INVOICED_USE_CREDIT_NOTE'; end if;
  update invoices set status = 'cancelled', cancelled_at = now(), cancelled_by = fn_staff_id(), cancel_reason = p_reason where id = inv.id;
  perform fn_sync_invoice_markers(r.id);
  perform fn_add_review_item(inv.branch_id, 'invoice_cancelled', 'invoice', inv.id, r.id, 'إلغاء الفاتورة ' || inv.number, p_reason,
    jsonb_build_object('number', inv.number, 'total_halalas', inv.total_halalas));
  perform fn_audit_change(inv.branch_id, 'invoice.cancelled', 'invoice', inv.id, jsonb_build_object('status', 'issued'), jsonb_build_object('status', 'cancelled'), p_reason);
  return jsonb_build_object('ok', true);
end $$;
revoke all on function fn_cancel_invoice(uuid, text) from public, anon;
grant execute on function fn_cancel_invoice(uuid, text) to authenticated;

-- the credit note: the only way back from an e-invoiced invoice. The owner or a manager, a mandatory reason, one per
-- invoice, the same amounts (it offsets the original in full), the review item and the audit
create or replace function fn_issue_credit_note(p_invoice uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare inv invoices%rowtype; r reservations%rowtype; cn invoices%rowtype;
begin
  perform fn_require_role('owner', 'manager');
  if coalesce(trim(p_reason), '') = '' then raise exception 'VALIDATION: reason'; end if;
  select * into inv from invoices where id = p_invoice;
  if not found then raise exception 'NOT_FOUND'; end if;
  select * into r from reservations where id = inv.reservation_id for update;
  perform fn_require_branch(inv.branch_id);
  select * into inv from invoices where id = inv.id for update;
  if inv.doc_kind <> 'invoice' or inv.status <> 'issued' then raise exception 'INVOICE_STATUS_INVALID'; end if;
  if inv.e_invoice_ref is null then raise exception 'NOT_E_INVOICED'; end if;
  if exists (select 1 from invoices x where x.credit_note_of = inv.id) then raise exception 'CREDIT_NOTE_EXISTS'; end if;
  insert into invoices(organization_id, branch_id, reservation_id, number, period_from, period_to, scope, origin, bill_to, snapshot,
                       subtotal_halalas, tax_halalas, total_halalas, issued_by, updated_by, doc_kind, credit_note_of, e_invoice_ref)
  values (inv.organization_id, inv.branch_id, inv.reservation_id, fn_next_document_number(inv.organization_id, 'invoice', 'INV'),
          inv.period_from, inv.period_to, inv.scope, 'credit_note', inv.bill_to, inv.snapshot,
          inv.subtotal_halalas, inv.tax_halalas, inv.total_halalas, fn_staff_id(), fn_staff_id(), 'credit_note', inv.id, inv.e_invoice_ref)
  returning * into cn;
  perform fn_add_review_item(inv.branch_id, 'invoice_credit_note', 'invoice', cn.id, r.id,
    'إشعار دائن للفاتورة ' || inv.number, p_reason,
    jsonb_build_object('number', inv.number, 'credit_note_number', cn.number, 'total_halalas', cn.total_halalas));
  perform fn_audit_change(inv.branch_id, 'invoice.credit_note', 'invoice', cn.id,
    jsonb_build_object('number', inv.number, 'e_invoice_ref', inv.e_invoice_ref),
    jsonb_build_object('credit_note_number', cn.number, 'total_halalas', cn.total_halalas), p_reason);
  return jsonb_build_object('ok', true, 'id', cn.id, 'number', cn.number, 'total_halalas', cn.total_halalas);
end $$;
revoke all on function fn_issue_credit_note(uuid, text) from public, anon;
grant execute on function fn_issue_credit_note(uuid, text) to authenticated;
