-- 0140: individual-mode default deny for direct reads of client_errors (local, unadopted).
-- The only application read path is fn_lookup_trace, guarded by /admin/audit-logs view (0110). Writes go through the
-- SECURITY DEFINER fn_log_client_error. Legacy role-mode users are unchanged (fn_page_read_gate is true for them).
-- integration_events is intentionally NOT changed here (decision held).
begin;
drop policy mgmt_client_errors_read on public.client_errors;
create policy mgmt_client_errors_read on public.client_errors for select to authenticated
  using (organization_id = (select fn_user_org_id()) and fn_has_role(variadic array['owner'::role_code,'manager'::role_code]) and (select fn_page_read_gate(array['/admin/audit-logs'])));
commit;
