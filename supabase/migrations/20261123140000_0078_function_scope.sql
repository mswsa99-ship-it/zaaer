-- ============================================================================================================
-- 0078 — Every function a staff member calls keeps to the hotel and the branch (plan item 2.4). Four parts.
--
-- 1. A row of one hotel cannot point to a row of another. fn_hotel_pointers runs after every insert, and every update
--    of a pointer or of the hotel, on the 84 tables that point to another hotel table (211 pointers: a branch, a
--    reservation, a guest profile, a room, a staff member …), and refuses the row when the row it points to belongs to
--    another hotel. Whatever a function writes — a reservation's guest profile, a voucher's reservation, a membership's
--    branch, a task's assignee — the database refuses a target of another hotel, checked by the function or not. It reads
--    the target as the owner (row rules do not hide it), leaves the existence of the target to the foreign key, and
--    changes no row. The tables' own foreign keys stay as they are.
-- 2. Seven internal helpers stop being callable by signed-in staff, as the app never calls them: they took a branch, a
--    room, a reservation or a voucher of any hotel and answered without asking whose it was (a branch's availability with
--    its room types, its public answers, a booking's entry checks, a room's later stays, whether a voucher is settled,
--    whether a staff member is a member, a branch's tax). The functions that use them run as their owner
--    and keep doing so; the server's own jobs (the secret key) keep their access.
-- 3. «أنهيت التنظيف» looks the task up in the caller's branches only: another branch's or hotel's task is not found and is
--    not locked while it is looked at.
-- 4. Closing a handoff ticket asks the hotel too: a ticket without a branch (a guest's, before a branch took it) was
--    closable by any hotel's staff with the capability; now only by its own hotel's.
-- ============================================================================================================

-- the row a row points to is of the row's own hotel (arguments: pointer column, target table, …)
create or replace function public.fn_hotel_pointers() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare r jsonb := to_jsonb(new); o jsonb; i int; v uuid; target_org uuid;
begin
  if new.organization_id is null then return null; end if;
  if tg_op = 'UPDATE' then o := to_jsonb(old); end if;
  for i in 0 .. tg_nargs / 2 - 1 loop
    v := (r ->> tg_argv[2 * i])::uuid;
    continue when v is null;
    continue when tg_op = 'UPDATE' and v = (o ->> tg_argv[2 * i])::uuid and new.organization_id = old.organization_id;
    execute format('select organization_id from public.%I where id = $1', tg_argv[2 * i + 1]) into target_org using v;
    if target_org is not null and target_org <> new.organization_id then
      raise exception 'HOTEL_MISMATCH: %.% points to another hotel''s %', tg_table_name, tg_argv[2 * i], tg_argv[2 * i + 1] using errcode = '23503';
    end if;
  end loop;
  return null;
end $$;
revoke execute on function public.fn_hotel_pointers() from public, anon, authenticated;

-- every table that points to another hotel table
create or replace trigger zz_hotel_pointers after insert or update of branch_id, keybox_id, reservation_id, organization_id on public.access_delivery_events
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'keybox_id', 'keyboxes', 'reservation_id', 'reservations');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, reservation_id, organization_id on public.access_release_requests
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'reservation_id', 'reservations');
create or replace trigger zz_hotel_pointers after insert or update of changed_by, organization_id on public.accounting_periods
  for each row execute function fn_hotel_pointers('changed_by', 'staff_profiles');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, conversation_id, staff_id, organization_id on public.ai_action_proposals
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'conversation_id', 'ai_ops_conversations', 'staff_id', 'staff_profiles');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, conversation_id, organization_id on public.ai_guardrail_events
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'conversation_id', 'conversations');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, staff_id, organization_id on public.ai_ops_conversations
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'staff_id', 'staff_profiles');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, conversation_id, organization_id on public.ai_ops_messages
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'conversation_id', 'ai_ops_conversations');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, conversation_id, organization_id on public.ai_tool_executions
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'conversation_id', 'conversations');
create or replace trigger zz_hotel_pointers after insert or update of resolved_by, organization_id on public.alert_events
  for each row execute function fn_hotel_pointers('resolved_by', 'staff_profiles');
create or replace trigger zz_hotel_pointers after insert or update of updated_by, organization_id on public.alert_rules
  for each row execute function fn_hotel_pointers('updated_by', 'staff_profiles');
create or replace trigger zz_hotel_pointers after insert or update of match_id, organization_id on public.bank_match_items
  for each row execute function fn_hotel_pointers('match_id', 'bank_matches');
create or replace trigger zz_hotel_pointers after insert or update of created_by, movement_id, released_by, organization_id on public.bank_matches
  for each row execute function fn_hotel_pointers('created_by', 'staff_profiles', 'movement_id', 'bank_movements', 'released_by', 'staff_profiles');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, cash_account_id, message_id, organization_id on public.bank_movements
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'cash_account_id', 'cash_accounts', 'message_id', 'bank_messages');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, organization_id on public.blocks
  for each row execute function fn_hotel_pointers('branch_id', 'branches');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, fallback_staff_id, responsible_staff_id, updated_by, organization_id on public.branch_journey_settings
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'fallback_staff_id', 'staff_profiles', 'responsible_staff_id', 'staff_profiles', 'updated_by', 'staff_profiles');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, organization_id on public.branch_media
  for each row execute function fn_hotel_pointers('branch_id', 'branches');
create or replace trigger zz_hotel_pointers after insert or update of approved_by, archived_by, block_id, branch_id, created_by, room_id, organization_id on public.branch_media_items
  for each row execute function fn_hotel_pointers('approved_by', 'staff_profiles', 'archived_by', 'staff_profiles', 'block_id', 'blocks', 'branch_id', 'branches', 'created_by', 'staff_profiles', 'room_id', 'rooms');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, staff_id, organization_id on public.branch_memberships
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'staff_id', 'staff_profiles');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, updated_by, organization_id on public.branch_payment_settings
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'updated_by', 'staff_profiles');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, updated_by, organization_id on public.branch_whatsapp_channels
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'updated_by', 'staff_profiles');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, organization_id on public.cash_accounts
  for each row execute function fn_hotel_pointers('branch_id', 'branches');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, inspected_by, reservation_id, room_id, superseded_by, organization_id on public.checkout_inspections
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'inspected_by', 'staff_profiles', 'reservation_id', 'reservations', 'room_id', 'rooms', 'superseded_by', 'staff_profiles');
create or replace trigger zz_hotel_pointers after insert or update of staff_id, organization_id on public.client_errors
  for each row execute function fn_hotel_pointers('staff_id', 'staff_profiles');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, keybox_id, room_id, organization_id on public.code_rotation_events
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'keybox_id', 'keyboxes', 'room_id', 'rooms');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, conversation_id, organization_id on public.conversation_messages
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'conversation_id', 'conversations');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, reservation_id, organization_id on public.conversations
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'reservation_id', 'reservations');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, requested_by, organization_id on public.data_purge_requests
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'requested_by', 'staff_profiles');
create or replace trigger zz_hotel_pointers after insert or update of account_id, branch_id, closing_id, source_id, organization_id on public.day_closing_lines
  for each row execute function fn_hotel_pointers('account_id', 'cash_accounts', 'branch_id', 'branches', 'closing_id', 'day_closings', 'source_id', 'booking_sources');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, closing_id, decided_by, requested_by, organization_id on public.day_closing_requests
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'closing_id', 'day_closings', 'decided_by', 'staff_profiles', 'requested_by', 'staff_profiles');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, created_by, submitted_by, updated_by, organization_id on public.day_closings
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'created_by', 'staff_profiles', 'submitted_by', 'staff_profiles', 'updated_by', 'staff_profiles');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, created_by, expense_id, organization_id on public.expense_attachments
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'created_by', 'staff_profiles', 'expense_id', 'expense_vouchers');
create or replace trigger zz_hotel_pointers after insert or update of created_by, organization_id on public.expense_categories
  for each row execute function fn_hotel_pointers('created_by', 'staff_profiles');
create or replace trigger zz_hotel_pointers after insert or update of account_id, branch_id, cancelled_by, category_id, created_by, organization_id on public.expense_vouchers
  for each row execute function fn_hotel_pointers('account_id', 'cash_accounts', 'branch_id', 'branches', 'cancelled_by', 'staff_profiles', 'category_id', 'expense_categories', 'created_by', 'staff_profiles');
create or replace trigger zz_hotel_pointers after insert or update of block_id, branch_id, floor_id, organization_id on public.facilities
  for each row execute function fn_hotel_pointers('block_id', 'blocks', 'branch_id', 'branches', 'floor_id', 'floors');
create or replace trigger zz_hotel_pointers after insert or update of account_id, branch_id, created_by, original_voucher_id, payment_transaction_id, payout_id, reservation_id, reversal_of, organization_id on public.financial_vouchers
  for each row execute function fn_hotel_pointers('account_id', 'cash_accounts', 'branch_id', 'branches', 'created_by', 'staff_profiles', 'original_voucher_id', 'financial_vouchers', 'payment_transaction_id', 'payment_transactions', 'payout_id', 'platform_payouts', 'reservation_id', 'reservations', 'reversal_of', 'financial_vouchers');
create or replace trigger zz_hotel_pointers after insert or update of block_id, branch_id, organization_id on public.floors
  for each row execute function fn_hotel_pointers('block_id', 'blocks', 'branch_id', 'branches');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, cash_account_id, expense_category_id, parent_id, source_id, organization_id on public.gl_accounts
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'cash_account_id', 'cash_accounts', 'expense_category_id', 'expense_categories', 'parent_id', 'gl_accounts', 'source_id', 'booking_sources');
create or replace trigger zz_hotel_pointers after insert or update of guest_profile_id, organization_id on public.guest_bans
  for each row execute function fn_hotel_pointers('guest_profile_id', 'guest_profiles');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, organization_id on public.guest_lookup_attempts
  for each row execute function fn_hotel_pointers('branch_id', 'branches');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, organization_id on public.guest_phone_challenges
  for each row execute function fn_hotel_pointers('branch_id', 'branches');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, organization_id on public.guest_phone_sessions
  for each row execute function fn_hotel_pointers('branch_id', 'branches');
create or replace trigger zz_hotel_pointers after insert or update of replied_by, organization_id on public.guest_reviews
  for each row execute function fn_hotel_pointers('replied_by', 'staff_profiles');
create or replace trigger zz_hotel_pointers after insert or update of assignee_id, branch_id, created_by, facility_id, reservation_id, room_id, task_type_id, organization_id on public.housekeeping_tasks
  for each row execute function fn_hotel_pointers('assignee_id', 'staff_profiles', 'branch_id', 'branches', 'created_by', 'staff_profiles', 'facility_id', 'facilities', 'reservation_id', 'reservations', 'room_id', 'rooms', 'task_type_id', 'task_types');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, conversation_id, reservation_id, organization_id on public.human_handoff_tickets
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'conversation_id', 'conversations', 'reservation_id', 'reservations');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, category_id, organization_id on public.inventory_periods
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'category_id', 'room_categories');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, reservation_id, updated_by, organization_id on public.invoices
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'reservation_id', 'reservations', 'updated_by', 'staff_profiles');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, created_by, reversal_of, organization_id on public.journal_entries
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'created_by', 'staff_profiles', 'reversal_of', 'journal_entries');
create or replace trigger zz_hotel_pointers after insert or update of account_id, branch_id, entry_id, organization_id on public.journal_lines
  for each row execute function fn_hotel_pointers('account_id', 'gl_accounts', 'branch_id', 'branches', 'entry_id', 'journal_entries');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, room_id, organization_id on public.keyboxes
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'room_id', 'rooms');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, organization_id on public.knowledge_entries
  for each row execute function fn_hotel_pointers('branch_id', 'branches');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, room_id, organization_id on public.maintenance_tickets
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'room_id', 'rooms');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, organization_id on public.notifications
  for each row execute function fn_hotel_pointers('branch_id', 'branches');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, reservation_id, organization_id on public.payment_transactions
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'reservation_id', 'reservations');
create or replace trigger zz_hotel_pointers after insert or update of account_id, branch_id, source_id, organization_id on public.platform_payouts
  for each row execute function fn_hotel_pointers('account_id', 'cash_accounts', 'branch_id', 'branches', 'source_id', 'booking_sources');
create or replace trigger zz_hotel_pointers after insert or update of account_id, branch_id, organization_id on public.pos_settlements
  for each row execute function fn_hotel_pointers('account_id', 'cash_accounts', 'branch_id', 'branches');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, product_id, updated_by, organization_id on public.product_branches
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'product_id', 'products', 'updated_by', 'staff_profiles');
create or replace trigger zz_hotel_pointers after insert or update of created_by, organization_id on public.product_categories
  for each row execute function fn_hotel_pointers('created_by', 'staff_profiles');
create or replace trigger zz_hotel_pointers after insert or update of order_id, product_id, organization_id on public.product_order_lines
  for each row execute function fn_hotel_pointers('order_id', 'product_orders', 'product_id', 'products');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, cancelled_by, created_by, paid_by, organization_id on public.product_orders
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'cancelled_by', 'staff_profiles', 'created_by', 'staff_profiles', 'paid_by', 'staff_profiles');
create or replace trigger zz_hotel_pointers after insert or update of category_id, created_by, organization_id on public.products
  for each row execute function fn_hotel_pointers('category_id', 'product_categories', 'created_by', 'staff_profiles');
create or replace trigger zz_hotel_pointers after insert or update of archived_by, branch_id, organization_id on public.property_policies
  for each row execute function fn_hotel_pointers('archived_by', 'staff_profiles', 'branch_id', 'branches');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, category_id, updated_by, organization_id on public.rate_calendar
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'category_id', 'room_categories', 'updated_by', 'staff_profiles');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, reservation_id, organization_id on public.registration_sessions
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'reservation_id', 'reservations');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, category_id, organization_id on public.release_rules
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'category_id', 'room_categories');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, category_id, organization_id on public.released_slots
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'category_id', 'room_categories');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, reservation_id, room_id, organization_id on public.reservation_allocations
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'reservation_id', 'reservations', 'room_id', 'rooms');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, invoice_id, reservation_id, service_definition_id, organization_id on public.reservation_charges
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'invoice_id', 'invoices', 'reservation_id', 'reservations', 'service_definition_id', 'service_definitions');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, guest_profile_id, reservation_id, organization_id on public.reservation_guests
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'guest_profile_id', 'guest_profiles', 'reservation_id', 'reservations');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, created_by, removed_by, reservation_id, organization_id on public.reservation_nights
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'created_by', 'staff_profiles', 'removed_by', 'staff_profiles', 'reservation_id', 'reservations');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, checked_in_by, checked_out_by, deposit_waiver_by, room_category_id, room_id, shomoos_accepted_by, source_id, organization_id on public.reservations
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'checked_in_by', 'staff_profiles', 'checked_out_by', 'staff_profiles', 'deposit_waiver_by', 'staff_profiles', 'room_category_id', 'room_categories', 'room_id', 'rooms', 'shomoos_accepted_by', 'staff_profiles', 'source_id', 'booking_sources');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, created_by, objection_by, reservation_id, reviewed_by, organization_id on public.review_items
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'created_by', 'staff_profiles', 'objection_by', 'staff_profiles', 'reservation_id', 'reservations', 'reviewed_by', 'staff_profiles');
create or replace trigger zz_hotel_pointers after insert or update of updated_by, organization_id on public.role_permissions
  for each row execute function fn_hotel_pointers('updated_by', 'staff_profiles');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, organization_id on public.room_categories
  for each row execute function fn_hotel_pointers('branch_id', 'branches');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, room_id, updated_by, organization_id on public.room_licenses
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'room_id', 'rooms', 'updated_by', 'staff_profiles');
create or replace trigger zz_hotel_pointers after insert or update of block_id, branch_id, category_id, floor_id, organization_id on public.rooms
  for each row execute function fn_hotel_pointers('block_id', 'blocks', 'branch_id', 'branches', 'category_id', 'room_categories', 'floor_id', 'floors');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, task_type_id, organization_id on public.service_definitions
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'task_type_id', 'task_types');
create or replace trigger zz_hotel_pointers after insert or update of staff_id, organization_id on public.staff_saved_views
  for each row execute function fn_hotel_pointers('staff_id', 'staff_profiles');
create or replace trigger zz_hotel_pointers after insert or update of guest_id, reservation_id, organization_id on public.stay_acknowledgements
  for each row execute function fn_hotel_pointers('guest_id', 'reservation_guests', 'reservation_id', 'reservations');
create or replace trigger zz_hotel_pointers after insert or update of decided_by, organization_id on public.stay_extension_requests
  for each row execute function fn_hotel_pointers('decided_by', 'staff_profiles');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, created_by, reservation_id, organization_id on public.stay_payment_exceptions
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'created_by', 'staff_profiles', 'reservation_id', 'reservations');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, organization_id on public.task_types
  for each row execute function fn_hotel_pointers('branch_id', 'branches');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, knowledge_entry_id, organization_id on public.unanswered_questions
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'knowledge_entry_id', 'knowledge_entries');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, organization_id on public.whatsapp_inbound_messages
  for each row execute function fn_hotel_pointers('branch_id', 'branches');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, organization_id on public.whatsapp_outbox
  for each row execute function fn_hotel_pointers('branch_id', 'branches');

-- internal helpers: no longer callable by signed-in staff (the app never calls them; the server's jobs keep them)
revoke execute on function public.fn_apply_tax(uuid, bigint, boolean) from authenticated;
revoke execute on function public.fn_evaluate_access(uuid, boolean) from authenticated;
revoke execute on function public.fn_get_public_availability(uuid, date) from authenticated;
revoke execute on function public.fn_is_member(uuid, uuid) from authenticated;
revoke execute on function public.fn_public_knowledge(uuid) from authenticated;
revoke execute on function public.fn_room_overstay_blocks(uuid, date, date, uuid) from authenticated;
revoke execute on function public.fn_voucher_settled(uuid) from authenticated;

-- «أنهيت التنظيف»: the task is looked up in the caller's branches only
create or replace function public.fn_staff_complete_cleaning(p_task uuid) returns jsonb
language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare v int;
begin
  select version into v from housekeeping_tasks where id = p_task and branch_id in (select fn_user_branch_ids()) for update;
  if v is null then raise exception 'TASK_NOT_FOUND'; end if;
  return fn_hk_complete_task(p_task, null, v);
end $$;

-- closing a handoff ticket: the caller's hotel, then the caller's branches or no branch
create or replace function public.fn_staff_resolve_ticket(p_ticket uuid) returns jsonb
language plpgsql security definer set search_path to 'public', 'extensions' as $$
begin
  perform fn_require_cap('maintenance.resolve');
  update human_handoff_tickets set status = 'resolved', resolved_by = fn_staff_id(), resolved_at = now()
   where id = p_ticket and organization_id = fn_user_org_id() and (branch_id is null or branch_id in (select fn_user_branch_ids()));
  return jsonb_build_object('ok', found);
end $$;
