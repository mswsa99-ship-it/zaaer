-- CANDIDATE, local, UNRUN, UNADOPTED. Not a numbered migration. Needs 0110 applied (fn_issue_credit_note__impl exists).
-- Change: the page gate of fn_issue_credit_note goes from /staff/payments 'add' to 'delete', the same action as fn_cancel_invoice.
-- Basis: 0091 makes the credit note the e-invoiced form of cancelling an invoice (fn_cancel_invoice refuses e-invoiced invoices and points to it);
-- user-approved design of 2026-11-24 10:44:11 (approved "اعتمد" 11:05:20) point 3: deleting a financial voucher means a controlled cancellation.
-- Legacy accounts: fn_require_user_page returns true for them, so they are unchanged. The role list in the impl (owner, manager) is NOT touched.
do $$ begin
  if to_regprocedure('public.fn_issue_credit_note__impl(uuid,text)') is null then raise exception '0130c needs 0110 (fn_issue_credit_note__impl) first'; end if;
  if (select pg_get_functiondef('public.fn_issue_credit_note(uuid,text)'::regprocedure)) !~ '/staff/payments.*add' then raise exception '0130c: fn_issue_credit_note is not in the expected 0110 shape'; end if;
end $$;
create or replace function public.fn_issue_credit_note(p_invoice uuid, p_reason text) returns jsonb
language plpgsql volatile security definer set search_path = public as $f$
begin perform public.fn_require_user_page('/staff/payments', 'delete'); return public.fn_issue_credit_note__impl($1,$2); end $f$;
