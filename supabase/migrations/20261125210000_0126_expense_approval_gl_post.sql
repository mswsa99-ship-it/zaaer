-- 0126 expense approval posts its journal entry.
-- Finding: fn_trg_gl_expense posted only on INSERT with status approved and reversed only on approved->cancelled.
-- A pending expense approved through fn_expense_approve (0096) moved the cash box and the ledger movement but wrote no
-- journal entry, so the general ledger diverged from the ledger, and a later cancel had nothing to reverse.
-- Repair (minimal): also post on the pending->approved UPDATE. Same fn_gl_post call, same date (the expense's own business
-- day, fn_branch_date of occurred_at), same accounts, same idempotency key as the insert path. Nothing else changes.
-- Visible behavior: approving a pending expense whose date falls in a locked month is now refused with PERIOD_LOCKED and the
-- whole approval rolls back (the expense stays pending). Before this migration that approval succeeded without a journal entry.
-- This restores the existing period guard (0065); it is not a new date policy. Posting date is NOT changed to approval day.
-- Applying it changes nothing in existing rows: expenses approved before this migration keep having no entry, and a count of
-- approved expenses without an entry can be taken before and after the release.
begin;
create or replace function public.fn_trg_gl_expense()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if (tg_op = 'INSERT' and new.status = 'approved') or (tg_op = 'UPDATE' and old.status = 'pending' and new.status = 'approved') then
    perform fn_gl_post(new.organization_id, new.branch_id, fn_branch_date(new.branch_id, new.occurred_at), 'expense', new.id, 'post',
                       new.number || ' — ' || new.description,
                       jsonb_build_array(jsonb_build_object('account_id', fn_gl_for_category(new.category_id), 'debit', new.amount_halalas),
                                         jsonb_build_object('account_id', fn_gl_for_cash(new.account_id), 'credit', new.amount_halalas)));
  elsif tg_op = 'UPDATE' and old.status = 'approved' and new.status = 'cancelled' then
    perform fn_gl_reverse('expense', new.id, fn_branch_today(new.branch_id), 'إلغاء ' || new.number);
  end if;
  return null;
end $function$;
commit;
