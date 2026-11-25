-- 0128 (CANDIDATE, test-only, not approved for any environment): a guest-conversation reply is an ADD on /staff/inbox.
-- Before: staff_msg_insert required fn_can('conversation.take') (view + EDIT in individual mode) AND the page gate 'add',
-- so an individual account with view+add but not edit could not reply. After: in individual mode the capability leg is the
-- page VIEW grant (fn_page_read_grant, the same helper the select policies use), the add action is still enforced by
-- fn_page_write_gate(...,'add'). Unchanged: legacy/enabled=false accounts (fn_can role matrix), sender = 'supervisor', org and
-- branch checks, the conversation.take capability row (still /staff/inbox edit), fn_conversation_take, fn_staff_reviews,
-- fn_staff_review_reply and staff_conv_update (all stay edit).
drop policy if exists "staff_msg_insert" on conversation_messages;
create policy "staff_msg_insert" on conversation_messages for insert to authenticated
  with check (organization_id = (select fn_user_org_id())
    and (fn_can('conversation.take') or (select fn_page_read_grant(array['/staff/inbox'])))
    and sender = 'supervisor'
    and (select fn_page_write_gate(array['/staff/inbox'],'add'))
    and exists (select 1 from conversations c where c.id = conversation_messages.conversation_id and (c.branch_id is null or c.branch_id in (select fn_user_branch_ids()))));
