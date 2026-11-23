-- ============================================================================================================
-- 0077 — Row rules by hotel, then by branch (plan item 2.3). Since 0076 every row says its hotel; here every rule a
-- signed-in staff member reads or writes a hotel's or a branch's table through asks first that the row is of the
-- staff member's own hotel (organization_id = fn_user_org_id(), asked once per statement), and then what it asked
-- before (the branch, the role, the matrix). 91 rules gain that condition. Left as they are: the hotels' registry
-- (a staff member reads their own hotel only), the staff list (their hotel's staff, and their own profile), the
-- rules that refuse everything, and the four that show a visitor the public catalogue (active branches, active
-- booking sources, public room types, public house rules) until the guest's pages know their hotel (item 2.6). The
-- log asks the branch as well: a supervisor of one branch reads that branch's entries and the hotel's own, not another
-- branch's (the owner and the manager are members of every branch they run). Two of
-- those four also let a signed-in staff member read every hotel's active sources and public room types: they now
-- apply to visitors only — staff read their own hotel's through their own rules. No row changes.
-- ============================================================================================================

alter policy "staff_delivery_select" on public.access_delivery_events using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (EXISTS ( SELECT 1
   FROM reservations r
  WHERE ((r.id = access_delivery_events.reservation_id) AND (r.branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids))))));
alter policy "staff_access_select" on public.access_release_requests using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (EXISTS ( SELECT 1
   FROM reservations r
  WHERE ((r.id = access_release_requests.reservation_id) AND (r.branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids))))));
alter policy "accounting_periods_read" on public.accounting_periods using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((organization_id = fn_user_org_id()) AND fn_can('accounts.view'::text)));
alter policy "own_proposals_select" on public.ai_action_proposals using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (staff_id = fn_staff_id()));
alter policy "staff_ai_guard_select" on public.ai_guardrail_events using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and fn_has_role(VARIADIC ARRAY['owner'::role_code, 'manager'::role_code]));
alter policy "own_conv_insert" on public.ai_ops_conversations with check ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((staff_id = fn_staff_id()) AND (branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)) AND (organization_id = fn_user_org_id())));
alter policy "own_conv_select" on public.ai_ops_conversations using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (staff_id = fn_staff_id()));
alter policy "own_conv_update" on public.ai_ops_conversations using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (staff_id = fn_staff_id())) with check ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (staff_id = fn_staff_id()));
alter policy "own_msg_insert" on public.ai_ops_messages with check ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (conversation_id IN ( SELECT ai_ops_conversations.id
   FROM ai_ops_conversations
  WHERE (ai_ops_conversations.staff_id = fn_staff_id()))));
alter policy "own_msg_select" on public.ai_ops_messages using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (conversation_id IN ( SELECT ai_ops_conversations.id
   FROM ai_ops_conversations
  WHERE (ai_ops_conversations.staff_id = fn_staff_id()))));
alter policy "staff_ai_settings_select" on public.ai_settings using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((organization_id = fn_user_org_id()) AND fn_has_role(VARIADIC ARRAY['owner'::role_code, 'manager'::role_code])));
alter policy "staff_ai_tools_select" on public.ai_tool_executions using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and fn_has_role(VARIADIC ARRAY['owner'::role_code, 'manager'::role_code]));
alter policy "staff_ai_usage_select" on public.ai_usage_daily using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((organization_id = fn_user_org_id()) AND fn_has_role(VARIADIC ARRAY['owner'::role_code, 'manager'::role_code])));
alter policy "alert_events_read" on public.alert_events using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)) AND fn_has_role(VARIADIC ARRAY['owner'::role_code, 'manager'::role_code, 'supervisor'::role_code])));
alter policy "alert_rules_read" on public.alert_rules using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (organization_id = fn_user_org_id()));
alter policy "mgmt_audit_read" on public.audit_events using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (fn_can('audit.log'::text) AND (organization_id = fn_user_org_id()) AND ((category <> 'security'::text) OR fn_can('security'::text))) AND ((branch_id IS NULL) OR (branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids))));
alter policy "bank_match_items_read" on public.bank_match_items using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((organization_id = fn_user_org_id()) AND (match_id IN ( SELECT bank_matches.id
   FROM bank_matches))));
alter policy "bank_matches_read" on public.bank_matches using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((organization_id = fn_user_org_id()) AND (movement_id IN ( SELECT bank_movements.id
   FROM bank_movements))));
alter policy "bank_messages_read" on public.bank_messages using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((organization_id = fn_user_org_id()) AND fn_can('bank.manage'::text) AND ((movement_id IS NULL) OR (movement_id IN ( SELECT bank_movements.id
   FROM bank_movements)))));
alter policy "bank_movements_read" on public.bank_movements using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((organization_id = fn_user_org_id()) AND (fn_can('bank.view'::text) OR fn_can('bank.manage'::text)) AND ((branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)) OR ((branch_id IS NULL) AND fn_can('bank.manage'::text)))));
alter policy "bank_parse_rules_read" on public.bank_parse_rules using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((organization_id = fn_user_org_id()) AND (fn_can('bank.view'::text) OR fn_can('bank.manage'::text))));
alter policy "staff_blocks_select" on public.blocks using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)));
alter policy "staff_sources_all" on public.booking_sources using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((organization_id = fn_user_org_id()) AND fn_can('definitions'::text))) with check ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((organization_id = fn_user_org_id()) AND fn_can('definitions'::text)));
alter policy "staff_sources_read" on public.booking_sources using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (organization_id = fn_user_org_id()));
alter policy "journey_settings_read" on public.branch_journey_settings using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)));
alter policy "staff_memberships_select" on public.branch_memberships using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (EXISTS ( SELECT 1
   FROM staff_profiles sp
  WHERE ((sp.id = branch_memberships.staff_id) AND (sp.organization_id = fn_user_org_id())))));
alter policy "staff_read_branches" on public.branches using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (organization_id = fn_user_org_id()));
alter policy "money_staff_cash_accounts_read" on public.cash_accounts using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)) AND fn_sees_money()));
alter policy "inspections_read" on public.checkout_inspections using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)) AND fn_has_role(VARIADIC ARRAY['owner'::role_code, 'manager'::role_code, 'supervisor'::role_code, 'finance'::role_code, 'housekeeping'::role_code])));
alter policy "mgmt_client_errors_read" on public.client_errors using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((organization_id = fn_user_org_id()) AND fn_has_role(VARIADIC ARRAY['owner'::role_code, 'manager'::role_code])));
alter policy "staff_rotation_select" on public.code_rotation_events using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (fn_has_role(VARIADIC ARRAY['owner'::role_code, 'manager'::role_code, 'supervisor'::role_code]) AND (EXISTS ( SELECT 1
   FROM rooms r
  WHERE ((r.id = code_rotation_events.room_id) AND (r.branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)))))));
alter policy "staff_msg_insert" on public.conversation_messages with check ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (fn_can('conversation.take'::text) AND (sender = 'supervisor'::text) AND (EXISTS ( SELECT 1
   FROM conversations c
  WHERE ((c.id = conversation_messages.conversation_id) AND ((c.branch_id IS NULL) OR (c.branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids))))))));
alter policy "staff_msg_select" on public.conversation_messages using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (fn_has_role(VARIADIC ARRAY['owner'::role_code, 'manager'::role_code, 'supervisor'::role_code]) AND (EXISTS ( SELECT 1
   FROM conversations c
  WHERE ((c.id = conversation_messages.conversation_id) AND ((c.branch_id IS NULL) OR (c.branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids))))))));
alter policy "staff_conv_select" on public.conversations using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (fn_has_role(VARIADIC ARRAY['owner'::role_code, 'manager'::role_code, 'supervisor'::role_code]) AND ((branch_id IS NULL) OR (branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)))));
alter policy "staff_conv_update" on public.conversations using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (fn_can('conversation.take'::text) AND ((branch_id IS NULL) OR (branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids))))) with check ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and true);
alter policy "day_closing_lines_read" on public.day_closing_lines using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (closing_id IN ( SELECT day_closings.id
   FROM day_closings)));
alter policy "day_closing_requests_read" on public.day_closing_requests using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)) AND (fn_can('day.close'::text) OR fn_can('day.close.approve'::text))));
alter policy "day_closings_read" on public.day_closings using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)) AND (fn_can('day.close'::text) OR fn_can('day.close.approve'::text))));
alter policy "expense_categories_read" on public.expense_categories using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (organization_id = fn_user_org_id()));
alter policy "expense_vouchers_read" on public.expense_vouchers using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)) AND (fn_can('expense.create'::text) OR fn_can('expense.cancel'::text) OR fn_can('ledger.view'::text))));
alter policy "staff_facilities_select" on public.facilities using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)));
alter policy "staff_vouchers_select" on public.financial_vouchers using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)) AND fn_sees_money()));
alter policy "staff_floors_select" on public.floors using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)));
alter policy "gl_accounts_read" on public.gl_accounts using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((organization_id = fn_user_org_id()) AND fn_can('accounts.view'::text) AND ((branch_id IS NULL) OR (branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)))));
alter policy "staff_guests_select" on public.guest_profiles using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and fn_has_role(VARIADIC ARRAY['owner'::role_code, 'manager'::role_code, 'supervisor'::role_code]));
alter policy "guest_reviews_read" on public.guest_reviews using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)));
alter policy "staff_hk_select" on public.housekeeping_tasks using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)));
alter policy "staff_handoff_select" on public.human_handoff_tickets using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (fn_has_role(VARIADIC ARRAY['owner'::role_code, 'manager'::role_code, 'supervisor'::role_code]) AND ((branch_id IS NULL) OR (branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)))));
alter policy "mgr_integration_select" on public.integration_events using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((organization_id = fn_user_org_id()) AND fn_has_role(VARIADIC ARRAY['owner'::role_code, 'manager'::role_code])));
alter policy "mgr_inv_write" on public.inventory_periods using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)) AND fn_has_role(VARIADIC ARRAY['owner'::role_code, 'manager'::role_code]))) with check ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)) AND fn_has_role(VARIADIC ARRAY['owner'::role_code, 'manager'::role_code])));
alter policy "staff_inv_select" on public.inventory_periods using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)));
alter policy "staff_invoices_select" on public.invoices using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)) AND fn_sees_money()));
alter policy "journal_entries_read" on public.journal_entries using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((organization_id = fn_user_org_id()) AND fn_can('accounts.view'::text) AND ((branch_id IS NULL) OR (branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)))));
alter policy "journal_lines_read" on public.journal_lines using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (entry_id IN ( SELECT journal_entries.id
   FROM journal_entries)));
alter policy "journey_messages_read" on public.journey_messages using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)));
alter policy "staff_keyboxes_select" on public.keyboxes using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (fn_has_role(VARIADIC ARRAY['owner'::role_code, 'manager'::role_code, 'supervisor'::role_code]) AND (branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids))));
alter policy "staff_read_knowledge" on public.knowledge_entries using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((organization_id = fn_user_org_id()) AND ((branch_id IS NULL) OR (branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)))));
alter policy "staff_maint_select" on public.maintenance_tickets using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)));
alter policy "staff_notif_select" on public.notifications using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)) OR (branch_id IS NULL)));
alter policy "staff_notif_update" on public.notifications using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids))) with check ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)));
alter policy "staff_payments_select" on public.payment_transactions using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (fn_has_role(VARIADIC ARRAY['owner'::role_code, 'manager'::role_code, 'supervisor'::role_code, 'finance'::role_code]) AND (EXISTS ( SELECT 1
   FROM reservations r
  WHERE ((r.id = payment_transactions.reservation_id) AND (r.branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)))))));
alter policy "money_platform_payouts_read" on public.platform_payouts using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)) AND fn_can('platform.payouts'::text)));
alter policy "money_staff_pos_settlements_read" on public.pos_settlements using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)) AND fn_sees_money()));
alter policy "product_branches_read" on public.product_branches using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (organization_id = fn_user_org_id()));
alter policy "product_categories_read" on public.product_categories using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (organization_id = fn_user_org_id()));
alter policy "product_order_lines_read" on public.product_order_lines using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((organization_id = fn_user_org_id()) AND (order_id IN ( SELECT product_orders.id
   FROM product_orders))));
alter policy "product_orders_read" on public.product_orders using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((organization_id = fn_user_org_id()) AND (branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)) AND fn_sees_money()));
alter policy "products_read" on public.products using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (organization_id = fn_user_org_id()));
alter policy "mgr_write_policies" on public.property_policies using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)) AND fn_can('policies'::text))) with check ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)) AND fn_can('policies'::text)));
alter policy "staff_read_policies" on public.property_policies using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)));
alter policy "rates_read" on public.rate_calendar using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)) AND fn_can('rates'::text)));
alter policy "staff_regsession_select" on public.registration_sessions using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (fn_has_role(VARIADIC ARRAY['owner'::role_code, 'manager'::role_code, 'supervisor'::role_code]) AND (EXISTS ( SELECT 1
   FROM reservations r
  WHERE ((r.id = registration_sessions.reservation_id) AND (r.branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)))))));
alter policy "mgr_rules_write" on public.release_rules using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)) AND fn_has_role(VARIADIC ARRAY['owner'::role_code, 'manager'::role_code]))) with check ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)) AND fn_has_role(VARIADIC ARRAY['owner'::role_code, 'manager'::role_code])));
alter policy "staff_rules_select" on public.release_rules using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)));
alter policy "staff_slots_select" on public.released_slots using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)));
alter policy "staff_alloc_select" on public.reservation_allocations using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)));
alter policy "staff_charges_select" on public.reservation_charges using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)) AND fn_sees_money()));
alter policy "staff_resguests_select" on public.reservation_guests using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (fn_has_role(VARIADIC ARRAY['owner'::role_code, 'manager'::role_code, 'supervisor'::role_code, 'finance'::role_code]) AND (EXISTS ( SELECT 1
   FROM reservations r
  WHERE ((r.id = reservation_guests.reservation_id) AND (r.branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)))))));
alter policy "nights_read" on public.reservation_nights using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)) AND fn_sees_money()));
alter policy "staff_res_select" on public.reservations using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)));
alter policy "review_items_owner_read" on public.review_items using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((organization_id = fn_user_org_id()) AND fn_can('review.list'::text)));
alter policy "owner_reads_permissions" on public.role_permissions using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((organization_id = fn_user_org_id()) AND fn_has_role(VARIADIC ARRAY['owner'::role_code])));
alter policy "staff_cat_select" on public.room_categories using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)));
alter policy "staff_rooms_select" on public.rooms using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)));
alter policy "staff_services_select" on public.service_definitions using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)));
alter policy "own_saved_views_select" on public.staff_saved_views using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (staff_id = fn_staff_id()));
alter policy "extension_requests_read" on public.stay_extension_requests using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)) AND fn_sees_money()));
alter policy "payment_exceptions_read" on public.stay_payment_exceptions using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)) AND fn_sees_money()));
alter policy "staff_sys_select" on public.system_settings using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (organization_id = fn_user_org_id()));
alter policy "staff_tasktypes_select" on public.task_types using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and (branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)));
alter policy "staff_read_unanswered" on public.unanswered_questions using ((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) and ((organization_id = fn_user_org_id()) AND ((branch_id IS NULL) OR (branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)))));

-- the public catalogue is for visitors; staff read their own hotel's through their own rules
alter policy "anon_read_sources" on public.booking_sources to anon;
alter policy "anon_read_public_cats" on public.room_categories to anon;
