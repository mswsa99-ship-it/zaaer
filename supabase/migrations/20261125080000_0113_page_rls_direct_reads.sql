-- 0110: direct-read RLS policies call the per-user page check (fn_user_page_can, 0109).
-- Design (one-app model, owner approval as relayed by the coordinating agent): the owner sees everything; each other user gets per-page levels
-- view/add/edit/delete/export; existing accounts keep legacy behaviour; individual grants fail closed.
--
-- The three helpers below take a PAGE LIST (every page that reads the table, directly, through a shared hook or as an
-- embedded join) and answer by the user's access mode (fn_user_access_mode):
--   legacy / none  -> gate = true, grant = false: the old policy condition decides exactly as before.
--   individual     -> gate = a view grant on at least one listed page; grant = the same, used where it REPLACES a fixed-role check.
-- Org and branch isolation are never replaced. Money and security capabilities (fn_sees_money, fn_can('platform.payouts'),
-- bank, audit, security category) stay as mandatory rules next to the grant: a page grant narrows them, never widens them.
-- Tables whose old policy was FOR ALL are split into insert/update/delete so the page-level action gate can apply
-- (a FOR ALL policy would also keep answering reads without the page grant). Unchanged on purpose: branches (the branch
-- selector of every screen reads it), the anon policies (guest flows), staff_profiles of the caller's own row.
create or replace function public.fn_page_read_gate(p_pages text[]) returns boolean
language sql stable security definer set search_path=public as $$
  select case fn_user_access_mode()
    when 'individual' then exists(select 1 from unnest(p_pages) p where fn_user_page_can(p,'view'))
    else true end
$$;
create or replace function public.fn_page_read_grant(p_pages text[]) returns boolean
language sql stable security definer set search_path=public as $$
  select fn_user_access_mode()='individual' and exists(select 1 from unnest(p_pages) p where fn_user_page_can(p,'view'))
$$;
create or replace function public.fn_page_write_gate(p_pages text[],p_action text) returns boolean
language sql stable security definer set search_path=public as $$
  select case fn_user_access_mode()
    when 'individual' then exists(select 1 from unnest(p_pages) p where fn_user_page_can(p,p_action))
    else true end
$$;
revoke all on function public.fn_page_read_gate(text[]),public.fn_page_read_grant(text[]),public.fn_page_write_gate(text[],text) from public,anon;
grant execute on function public.fn_page_read_gate(text[]),public.fn_page_read_grant(text[]),public.fn_page_write_gate(text[],text) to authenticated;

drop policy if exists "staff_blocks_select" on blocks;
create policy "staff_blocks_select" on blocks for select to authenticated
  using (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()) and (select fn_page_read_gate(array['/admin/facilities','/admin/rooms','/admin/structure'])));

drop policy if exists "staff_facilities_select" on facilities;
create policy "staff_facilities_select" on facilities for select to authenticated
  using (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()) and (select fn_page_read_gate(array['/admin/facilities','/admin/structure','/staff/housekeeping'])));

drop policy if exists "staff_floors_select" on floors;
create policy "staff_floors_select" on floors for select to authenticated
  using (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()) and (select fn_page_read_gate(array['/admin/facilities','/admin/rooms','/admin/structure'])));

drop policy if exists "staff_hk_select" on housekeeping_tasks;
create policy "staff_hk_select" on housekeeping_tasks for select to authenticated
  using (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()) and (select fn_page_read_gate(array['/admin/facilities','/admin/task-types','/staff/housekeeping'])));

drop policy if exists "staff_maint_select" on maintenance_tickets;
create policy "staff_maint_select" on maintenance_tickets for select to authenticated
  using (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()) and (select fn_page_read_gate(array['/staff/tickets'])));

drop policy if exists "staff_slots_select" on released_slots;
create policy "staff_slots_select" on released_slots for select to authenticated
  using (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()) and (select fn_page_read_gate(array['/admin/availability-rules'])));

drop policy if exists "staff_rules_select" on release_rules;
create policy "staff_rules_select" on release_rules for select to authenticated
  using (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()) and (select fn_page_read_gate(array['/admin/availability-rules'])));

drop policy if exists "staff_inv_select" on inventory_periods;
create policy "staff_inv_select" on inventory_periods for select to authenticated
  using (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()) and (select fn_page_read_gate(array['/admin/availability'])));

drop policy if exists "staff_res_select" on reservations;
create policy "staff_res_select" on reservations for select to authenticated
  using (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()) and (select fn_page_read_gate(array['/admin/dashboard','/admin/reports','/staff/reservations/:id','/staff/arrivals','/staff/identity-verification','/staff/payments','/staff/access-approvals','/staff/dashboard','/staff/rooms','/staff/orders'])));

drop policy if exists "staff_cat_select" on room_categories;
create policy "staff_cat_select" on room_categories for select to authenticated
  using (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()) and (select fn_page_read_gate(array['/admin/availability','/admin/availability-rules','/admin/room-categories','/admin/rooms','/staff/reservations/new'])));

drop policy if exists "staff_rooms_select" on rooms;
create policy "staff_rooms_select" on rooms for select to authenticated
  using (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()) and (select fn_page_read_gate(array['/admin/branches','/admin/dashboard','/admin/room-categories','/admin/rooms','/admin/structure','/staff/housekeeping','/staff/tickets'])));

drop policy if exists "staff_services_select" on service_definitions;
create policy "staff_services_select" on service_definitions for select to authenticated
  using (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()) and (select fn_page_read_gate(array['/admin/services','/staff/reservations/:id','/staff/orders'])));

drop policy if exists "staff_tasktypes_select" on task_types;
create policy "staff_tasktypes_select" on task_types for select to authenticated
  using (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()) and (select fn_page_read_gate(array['/admin/services','/admin/task-types','/staff/housekeeping'])));

drop policy if exists "staff_sources_read" on booking_sources;
create policy "staff_sources_read" on booking_sources for select to authenticated
  using (organization_id = (select fn_user_org_id()) and (select fn_page_read_gate(array['/admin/booking-sources','/admin/platform-payouts','/staff/reservations/:id','/staff/reservations/new','/admin/guests','/admin/guests/:id'])));

drop policy if exists "expense_categories_read" on expense_categories;
create policy "expense_categories_read" on expense_categories for select to authenticated
  using (organization_id = (select fn_user_org_id()) and (select fn_page_read_gate(array['/staff/bank','/staff/expenses'])));

drop policy if exists "staff_read_policies" on property_policies;
create policy "staff_read_policies" on property_policies for select to authenticated
  using (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()) and (is_public or (select fn_page_read_gate(array['/admin/policies']))));

drop policy if exists "staff_delivery_select" on access_delivery_events;
create policy "staff_delivery_select" on access_delivery_events for select to authenticated
  using (organization_id = (select fn_user_org_id()) and exists (select 1 from reservations r where r.id = access_delivery_events.reservation_id and r.branch_id in (select fn_user_branch_ids())) and (select fn_page_read_gate(array['/admin/dashboard'])));

drop policy if exists "staff_ai_guard_select" on ai_guardrail_events;
create policy "staff_ai_guard_select" on ai_guardrail_events for select to authenticated
  using (organization_id = (select fn_user_org_id()) and (((select fn_user_access_mode()) <> 'individual' and fn_has_role('owner','manager')) or (select fn_page_read_grant(array['/admin/ai-settings']))));

drop policy if exists "staff_ai_settings_select" on ai_settings;
create policy "staff_ai_settings_select" on ai_settings for select to authenticated
  using (organization_id = (select fn_user_org_id()) and (((select fn_user_access_mode()) <> 'individual' and fn_has_role('owner','manager')) or (select fn_page_read_grant(array['/admin/ai-settings','/admin/integrations']))));

drop policy if exists "staff_ai_tools_select" on ai_tool_executions;
create policy "staff_ai_tools_select" on ai_tool_executions for select to authenticated
  using (organization_id = (select fn_user_org_id()) and (((select fn_user_access_mode()) <> 'individual' and fn_has_role('owner','manager')) or (select fn_page_read_grant(array['/admin/ai-settings']))));

drop policy if exists "staff_ai_usage_select" on ai_usage_daily;
create policy "staff_ai_usage_select" on ai_usage_daily for select to authenticated
  using (organization_id = (select fn_user_org_id()) and (((select fn_user_access_mode()) <> 'individual' and fn_has_role('owner','manager')) or (select fn_page_read_grant(array['/admin/ai-settings','/admin/reports','/admin/dashboard']))));

drop policy if exists "inspections_read" on checkout_inspections;
create policy "inspections_read" on checkout_inspections for select to authenticated
  using (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()) and (((select fn_user_access_mode()) <> 'individual' and fn_has_role('owner','manager','supervisor','finance','housekeeping')) or (select fn_page_read_grant(array['/staff/housekeeping']))));

drop policy if exists "staff_conv_select" on conversations;
create policy "staff_conv_select" on conversations for select to authenticated
  using (organization_id = (select fn_user_org_id()) and (((select fn_user_access_mode()) <> 'individual' and fn_has_role('owner','manager','supervisor')) or (select fn_page_read_grant(array['/staff/inbox']))) and (branch_id is null or branch_id in (select fn_user_branch_ids())));

drop policy if exists "staff_msg_select" on conversation_messages;
create policy "staff_msg_select" on conversation_messages for select to authenticated
  using (organization_id = (select fn_user_org_id()) and (((select fn_user_access_mode()) <> 'individual' and fn_has_role('owner','manager','supervisor')) or (select fn_page_read_grant(array['/staff/inbox']))) and exists (select 1 from conversations c where c.id = conversation_messages.conversation_id and (c.branch_id is null or c.branch_id in (select fn_user_branch_ids()))));

drop policy if exists "staff_handoff_select" on human_handoff_tickets;
create policy "staff_handoff_select" on human_handoff_tickets for select to authenticated
  using (organization_id = (select fn_user_org_id()) and (((select fn_user_access_mode()) <> 'individual' and fn_has_role('owner','manager','supervisor')) or (select fn_page_read_grant(array['/admin/dashboard','/admin/reports','/staff/tickets']))) and (branch_id is null or branch_id in (select fn_user_branch_ids())));

drop policy if exists "staff_keyboxes_select" on keyboxes;
create policy "staff_keyboxes_select" on keyboxes for select to authenticated
  using (organization_id = (select fn_user_org_id()) and (((select fn_user_access_mode()) <> 'individual' and fn_has_role('owner','manager','supervisor')) or (select fn_page_read_grant(array['/staff/access-approvals']))) and branch_id in (select fn_user_branch_ids()));

drop policy if exists "staff_resguests_select" on reservation_guests;
create policy "staff_resguests_select" on reservation_guests for select to authenticated
  using (organization_id = (select fn_user_org_id()) and (((select fn_user_access_mode()) <> 'individual' and fn_has_role('owner','manager','supervisor','finance')) or (select fn_page_read_grant(array['/staff/identity-verification','/staff/reservations/:id','/staff/arrivals','/staff/payments','/staff/access-approvals','/staff/dashboard','/staff/rooms']))) and exists (select 1 from reservations r where r.id = reservation_guests.reservation_id and r.branch_id in (select fn_user_branch_ids())));

drop policy if exists "money_staff_cash_accounts_read" on cash_accounts;
create policy "money_staff_cash_accounts_read" on cash_accounts for select to authenticated
  using (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()) and fn_sees_money() and (select fn_page_read_gate(array['/admin/cash-accounts','/admin/platform-payouts','/admin/finance','/staff/expenses','/staff/ledger','/staff/pos-settlement','/staff/orders','/staff/reservations/:id'])));

drop policy if exists "staff_vouchers_select" on financial_vouchers;
create policy "staff_vouchers_select" on financial_vouchers for select to authenticated
  using (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()) and fn_sees_money() and (select fn_page_read_gate(array['/staff/payments'])));

drop policy if exists "money_staff_pos_settlements_read" on pos_settlements;
create policy "money_staff_pos_settlements_read" on pos_settlements for select to authenticated
  using (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()) and fn_sees_money() and (select fn_page_read_gate(array['/staff/pos-settlement'])));

drop policy if exists "money_platform_payouts_read" on platform_payouts;
create policy "money_platform_payouts_read" on platform_payouts for select to authenticated
  using (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()) and fn_can('platform.payouts') and (select fn_page_read_gate(array['/admin/platform-payouts'])));

drop policy if exists "bank_parse_rules_read" on bank_parse_rules;
create policy "bank_parse_rules_read" on bank_parse_rules for select to authenticated
  using (organization_id = (select fn_user_org_id()) and (fn_can('bank.view') or fn_can('bank.manage')) and (select fn_page_read_gate(array['/admin/bank-mail'])));

drop policy if exists "mgmt_audit_read" on audit_events;
create policy "mgmt_audit_read" on audit_events for select to authenticated
  using (organization_id = (select fn_user_org_id()) and fn_can('audit.log') and ((category <> 'security') or fn_can('security')) and (branch_id is null or branch_id in (select fn_user_branch_ids())) and (select fn_page_read_gate(array['/staff/reservations/:id'])));

drop policy if exists "staff_read_profiles" on staff_profiles;
create policy "staff_read_profiles" on staff_profiles for select to authenticated
  using (auth_user_id = auth.uid() or (organization_id = fn_user_org_id() and (select fn_page_read_gate(array['/staff/housekeeping']))));

drop policy if exists "staff_sources_all" on booking_sources;
create policy "staff_sources_all_ins" on booking_sources for insert to authenticated with check (organization_id = (select fn_user_org_id()) and fn_can('definitions') and (select fn_page_write_gate(array['/admin/booking-sources'],'add')));
create policy "staff_sources_all_upd" on booking_sources for update to authenticated using (organization_id = (select fn_user_org_id()) and fn_can('definitions') and (select fn_page_write_gate(array['/admin/booking-sources'],'edit'))) with check (organization_id = (select fn_user_org_id()) and fn_can('definitions') and (select fn_page_write_gate(array['/admin/booking-sources'],'edit')));
create policy "staff_sources_all_del" on booking_sources for delete to authenticated using (organization_id = (select fn_user_org_id()) and fn_can('definitions') and (select fn_page_write_gate(array['/admin/booking-sources'],'delete')));

drop policy if exists "mgr_write_policies" on property_policies;
create policy "mgr_write_policies_ins" on property_policies for insert to authenticated with check (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()) and fn_can_write('policies','add') and (select fn_page_write_gate(array['/admin/policies'],'add')));
create policy "mgr_write_policies_upd" on property_policies for update to authenticated using (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()) and fn_can_write('policies','edit') and (select fn_page_write_gate(array['/admin/policies'],'edit'))) with check (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()) and fn_can_write('policies','edit') and (select fn_page_write_gate(array['/admin/policies'],'edit')));
create policy "mgr_write_policies_del" on property_policies for delete to authenticated using (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()) and fn_can_write('policies','delete') and (select fn_page_write_gate(array['/admin/policies'],'delete')));

drop policy if exists "mgr_inv_write" on inventory_periods;
create policy "mgr_inv_write_ins" on inventory_periods for insert to authenticated with check (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()) and fn_has_role('owner','manager') and (select fn_page_write_gate(array['/admin/availability'],'add')));
create policy "mgr_inv_write_upd" on inventory_periods for update to authenticated using (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()) and fn_has_role('owner','manager') and (select fn_page_write_gate(array['/admin/availability'],'edit'))) with check (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()) and fn_has_role('owner','manager') and (select fn_page_write_gate(array['/admin/availability'],'edit')));
create policy "mgr_inv_write_del" on inventory_periods for delete to authenticated using (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()) and fn_has_role('owner','manager') and (select fn_page_write_gate(array['/admin/availability'],'delete')));

drop policy if exists "mgr_rules_write" on release_rules;
create policy "mgr_rules_write_ins" on release_rules for insert to authenticated with check (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()) and fn_has_role('owner','manager') and (select fn_page_write_gate(array['/admin/availability-rules'],'add')));
create policy "mgr_rules_write_upd" on release_rules for update to authenticated using (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()) and fn_has_role('owner','manager') and (select fn_page_write_gate(array['/admin/availability-rules'],'edit'))) with check (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()) and fn_has_role('owner','manager') and (select fn_page_write_gate(array['/admin/availability-rules'],'edit')));
create policy "mgr_rules_write_del" on release_rules for delete to authenticated using (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()) and fn_has_role('owner','manager') and (select fn_page_write_gate(array['/admin/availability-rules'],'delete')));

drop policy if exists "staff_conv_update" on conversations;
create policy "staff_conv_update" on conversations for update to authenticated
  using (organization_id = (select fn_user_org_id()) and fn_can('conversation.take') and (branch_id is null or branch_id in (select fn_user_branch_ids())) and (select fn_page_write_gate(array['/staff/inbox'],'edit')))
  with check (organization_id = (select fn_user_org_id()) and (select fn_page_write_gate(array['/staff/inbox'],'edit')));

drop policy if exists "staff_msg_insert" on conversation_messages;
create policy "staff_msg_insert" on conversation_messages for insert to authenticated
  with check (organization_id = (select fn_user_org_id()) and fn_can('conversation.take') and sender = 'supervisor' and (select fn_page_write_gate(array['/staff/inbox'],'add')) and exists (select 1 from conversations c where c.id = conversation_messages.conversation_id and (c.branch_id is null or c.branch_id in (select fn_user_branch_ids()))));
