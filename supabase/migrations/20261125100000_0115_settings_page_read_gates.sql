-- Local source-backed individual view gates. No notification policy change.
begin;
alter function public.fn_finance_controls_get() rename to fn_finance_controls_get__impl;
revoke all on function public.fn_finance_controls_get__impl() from public, anon, authenticated;
grant execute on function public.fn_finance_controls_get__impl() to service_role;
create function public.fn_finance_controls_get() returns jsonb language plpgsql security definer set search_path = public
as $$begin perform public.fn_require_user_page('/admin/finance-controls', 'view'); return public.fn_finance_controls_get__impl(); end$$;
revoke all on function public.fn_finance_controls_get() from public, anon;
grant execute on function public.fn_finance_controls_get() to authenticated, service_role;

drop policy staff_reads_own_hotel_controls on public.finance_control_settings;
create policy staff_reads_own_hotel_controls on public.finance_control_settings for select to authenticated
  using (organization_id = (select fn_user_org_id()) and (select fn_page_read_gate(array['/admin/finance-controls'])));
drop policy alert_rules_read on public.alert_rules;
create policy alert_rules_read on public.alert_rules for select to authenticated
  using (organization_id = (select fn_user_org_id()) and (select fn_page_read_gate(array['/admin/journey'])));
drop policy staff_sys_select on public.system_settings;
create policy staff_sys_select on public.system_settings for select to authenticated
  using (organization_id = (select fn_user_org_id()) and (select fn_page_read_gate(array['/admin/finance-controls'])));

create or replace function fn_admin_alert_rules() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  -- Endpoint-specific mapping, not a global branch.settings capability grant.
  if fn_user_access_mode()='individual' then
    perform fn_require_user_page('/admin/journey','view');
  else
    perform fn_require_cap('branch.settings');
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('event', r.event, 'label', fn_alert_event_label(r.event), 'enabled', r.enabled, 'recipients', to_jsonb(r.recipients),
                                                       'channel', r.channel, 'delay_minutes', r.delay_minutes, 'escalate_after_minutes', r.escalate_after_minutes,
                                                       'escalate_to', r.escalate_to, 'version', r.version)
                                    order by array_position(array['guest_departed', 'deposit_overdue', 'review_low', 'extension_requested', 'extension_unpaid',
                                                                  'product_order', 'guest_handoff', 'message_failed'], r.event))
                     from alert_rules r where r.organization_id = fn_user_org_id()), '[]'::jsonb);
end $$;
revoke all on function fn_admin_alert_rules() from public, anon;
grant execute on function fn_admin_alert_rules() to authenticated;


commit;
