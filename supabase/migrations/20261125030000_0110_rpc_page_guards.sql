-- 0110 RPC page guards (RPC/edge worker). Needs the 0109 foundation (fn_user_page_can / fn_require_user_page).
-- Every listed entry point keeps its old role / money / branch / org guard untouched and gains ONE extra check
-- in front of it: fn_require_user_page(<route>, <action>). Legacy accounts: the extra check is true on known routes,
-- so their behaviour is unchanged. Individual accounts: the grant must also allow it (fail closed). The old guard
-- is never replaced and never OR-ed with the new one.
-- Method: the original body is renamed to <name>__impl (execute revoked from everyone but the owner role of the
-- database) and a thin wrapper with the same signature, return type, volatility and search_path takes its place.
do $$ begin
  if to_regprocedure('public.fn_require_user_page(text,text)') is null then
    raise exception '0110 needs the 0109 page-guard foundation first';
  end if;
end $$;

create or replace function pg_temp.wrap_gate(p_fn text, p_page text, p_action text) returns void
language plpgsql as $f$
declare r pg_proc%rowtype; n int; v_args text; v_res text; v_call text; v_cfg text := 'public'; i int; v_body text; v_vol text;
begin
  select count(*) into n from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = p_fn;
  if n <> 1 then raise exception 'wrap_gate: % has % definitions in public (expected exactly 1)', p_fn, n; end if;
  select p.* into r from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = p_fn;
  if not r.prosecdef then raise exception 'wrap_gate: % is not security definer', p_fn; end if;
  if r.provariadic <> 0 or r.proargmodes is not null and exists (select 1 from unnest(r.proargmodes) m where m in ('o','b','v')) then
    raise exception 'wrap_gate: % has OUT/VARIADIC arguments', p_fn;
  end if;
  v_args := pg_get_function_arguments(r.oid);
  v_res := pg_get_function_result(r.oid);
  if r.proconfig is not null then
    select substring(c from 'search_path=(.*)$') into v_cfg from unnest(r.proconfig) c where c like 'search_path=%' limit 1;
    v_cfg := coalesce(v_cfg, 'public');
  end if;
  v_vol := case r.provolatile when 'i' then 'immutable' when 's' then 'stable' else 'volatile' end;
  v_call := '';
  for i in 1 .. r.pronargs loop v_call := v_call || case when i > 1 then ',' else '' end || '$' || i; end loop;
  execute format('alter function public.%I(%s) rename to %I', p_fn, pg_get_function_identity_arguments(r.oid), p_fn || '__impl');
  execute format('revoke all on function public.%I(%s) from public, anon, authenticated', p_fn || '__impl', pg_get_function_identity_arguments(r.oid));
  if v_res = 'void' then
    v_body := format('begin perform public.fn_require_user_page(%L, %L); perform public.%I(%s); end', p_page, p_action, p_fn || '__impl', v_call);
  elsif r.proretset then
    v_body := format('begin perform public.fn_require_user_page(%L, %L); return query select * from public.%I(%s); end', p_page, p_action, p_fn || '__impl', v_call);
  else
    v_body := format('begin perform public.fn_require_user_page(%L, %L); return public.%I(%s); end', p_page, p_action, p_fn || '__impl', v_call);
  end if;
  execute format('create function public.%I(%s) returns %s language plpgsql %s security definer set search_path = %s as %L',
                 p_fn, v_args, v_res, v_vol, v_cfg, v_body);
  execute format('revoke all on function public.%I(%s) from public, anon', p_fn, pg_get_function_identity_arguments(r.oid));
  execute format('grant execute on function public.%I(%s) to authenticated', p_fn, pg_get_function_identity_arguments(r.oid));
end $f$;

-- name, route, action. Routes are the 0109 catalog's; the screen that owns the operation decides the route.
select pg_temp.wrap_gate(x.fn, x.page, x.act) from (values
  ('fn_staff_release_next_slot',     '/admin/availability-rules', 'edit'),
  ('fn_admin_delete_definition',     '/admin/structure',          'delete'),
  ('fn_cancel_invoice',              '/staff/payments',           'delete'),
  ('fn_reservation_detail',          '/staff/reservations',   'view'),
  ('fn_reservation_list',            '/staff/reservations',       'view'),
  ('fn_lookup_trace',                '/admin/audit-logs',         'view'),
  ('fn_stay_status',                 '/staff/reservations',   'view'),
  ('fn_staff_day_summary',           '/staff/day-summary',        'view'),
  ('fn_review_list',                 '/admin/review',             'view'),
  ('fn_review_mark',                 '/admin/review',             'edit'),
  ('fn_review_undo',                 '/admin/review',             'edit'),
  ('fn_guest_profiles',              '/admin/guests',             'view'),
  ('fn_guest_profile',               '/admin/guests',         'view'),
  ('fn_platform_check_list',         '/staff/platforms',          'view'),
  ('fn_platform_mark_checked',       '/staff/platforms',          'edit'),
  ('fn_reports_late_entries',        '/admin/reports',            'view'),
  ('fn_reservation_group_summary',   '/staff/reservations',   'view'),
  ('fn_admin_update_organization',   '/admin/organization',       'edit'),
  ('fn_price_limits',                '/admin/rates',              'view'),
  ('fn_admin_set_inventory',         '/admin/availability',       'edit'),
  ('fn_admin_upsert_release_rule',   '/admin/availability-rules', 'edit'),
  ('fn_staff_journey_tick',          '/staff/journey',            'edit'),
  ('fn_staff_journey',               '/staff/journey',            'view'),
  ('fn_staff_alert_resolve',         '/staff/journey',            'edit'),
  ('fn_admin_alert_rule_save',       '/admin/journey',            'edit'),
  ('fn_admin_set_guest_site',        '/admin/organization',       'edit'),
  ('fn_admin_staff_auth_status',     '/admin/staff',              'view'),
  ('fn_admin_staff_invite_target',   '/admin/staff',              'edit'),
  ('fn_room_licenses',               '/admin/rooms',              'view'),
  ('fn_issue_credit_note',           '/staff/payments',           'add'),
  ('fn_finance_controls_set',        '/admin/finance-controls',   'edit'),
  ('fn_staff_create_free_stay',      '/staff/reservations',   'add'),
  ('fn_approve_discount',            '/staff/reservations',   'edit'),
  ('fn_backup_status',               '/admin/backups',            'view'),
  ('fn_reservation_finance',         '/staff/reservations',   'view'),
  ('fn_ops_units_board',             '/staff/dashboard',          'view'),
  ('fn_ops_daily_summary_at',        '/staff/dashboard',          'view'),
  ('fn_ai_ops_context',              '/staff/dashboard',          'view'),
  ('fn_ai_ops_find_reservation',     '/staff/dashboard',          'view'),
  ('fn_ai_ops_reject_proposal',      '/staff/dashboard',          'edit'),
  ('fn_reservation_nights',          '/staff/reservations',   'view'),
  ('fn_stay_followups',              '/staff/followups',          'view'),
  ('fn_stay_summary',                '/staff/reservations',   'view'),
  ('fn_reservation_flags',           '/staff/reservations',       'view'),
  ('fn_reservation_calendar',        '/staff/reservations',       'view'),
  ('fn_voucher_list',                '/admin/finance',            'view')
) as x(fn, page, act);

-- fn_ai_ops_execute_proposal: the old checks (own proposal, status, expiry, branch) stay in the original body.
-- Added in front: the route of the action the proposal would run, so a proposal cannot do what its owner's page
-- grants forbid. Unknown actions fall through to the original body, which rejects them.
alter function public.fn_ai_ops_execute_proposal(uuid) rename to fn_ai_ops_execute_proposal__impl;
revoke all on function public.fn_ai_ops_execute_proposal__impl(uuid) from public, anon, authenticated;
create function public.fn_ai_ops_execute_proposal(p_id uuid) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_action text; v_page text; v_act text;
begin
  perform public.fn_require_user_page('/staff/dashboard', 'edit');
  select action into v_action from ai_action_proposals where id = p_id;
  select m.page, m.act into v_page, v_act from (values
    ('create_task','/staff/housekeeping','add'), ('complete_task','/staff/housekeeping','edit'),
    ('assign_task','/staff/housekeeping','edit'), ('set_cleanliness','/staff/housekeeping','edit'),
    ('amend_stay','/staff/reservations','edit'), ('switch_room','/staff/reservations','edit'),
    ('cancel_reservation','/staff/reservations','delete'), ('no_show','/staff/reservations','edit'),
    ('add_service','/staff/reservations','edit'),
    ('create_receipt','/staff/payments','add'), ('create_deposit','/staff/payments','add'),
    ('create_invoice','/staff/payments','add')) as m(action, page, act) where m.action = v_action;
  if v_page is not null then perform public.fn_require_user_page(v_page, v_act); end if;
  return public.fn_ai_ops_execute_proposal__impl(p_id);
end $$;
revoke all on function public.fn_ai_ops_execute_proposal(uuid) from public, anon;
grant execute on function public.fn_ai_ops_execute_proposal(uuid) to authenticated;

-- Hotel exit. export / suspend / delete already require the active owner of that very hotel (fn_hotel_exit_owner).
-- Two gaps closed here: the table catalogue answered any signed-in user, and verify also let the user who requested the
-- archive in even after losing the owner role. Both now need an active owner of the hotel.
alter function public.fn_hotel_exit_tables() rename to fn_hotel_exit_tables__impl;
revoke all on function public.fn_hotel_exit_tables__impl() from public, anon, authenticated;
create function public.fn_hotel_exit_tables() returns table(table_name text, seq int, retained boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if fn_user_org_id() is null or fn_current_role() is distinct from 'owner' then
    raise exception 'FORBIDDEN: hotel owner required' using errcode = '42501';
  end if;
  return query select * from public.fn_hotel_exit_tables__impl();
end $$;
revoke all on function public.fn_hotel_exit_tables() from public, anon;
grant execute on function public.fn_hotel_exit_tables() to authenticated;

alter function public.fn_hotel_exit_verify(uuid) rename to fn_hotel_exit_verify__impl;
revoke all on function public.fn_hotel_exit_verify__impl(uuid) from public, anon, authenticated;
create function public.fn_hotel_exit_verify(p_archive uuid) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_org uuid;
begin
  select organization_id into v_org from hotel_exit_archives where id = p_archive;
  if v_org is null then raise exception 'NOT_FOUND'; end if;
  perform public.fn_hotel_exit_owner(v_org);   -- session alive + active owner of this hotel
  return public.fn_hotel_exit_verify__impl(p_archive);
end $$;
revoke all on function public.fn_hotel_exit_verify(uuid) from public, anon;
grant execute on function public.fn_hotel_exit_verify(uuid) to authenticated;

-- Export gate. The export menus are built on the browser from the same RPCs the screen reads, so the server cannot see
-- "export" in those calls. The screen calls this first; it needs the page's export level on top of its view level.
create or replace function public.fn_authorize_export(p_page text) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.fn_require_user_page(p_page, 'view');
  perform public.fn_require_user_page(p_page, 'export');
  if p_page not in ('/staff/reservations','/admin/finance','/admin/reports','/admin/audit-logs','/admin/roles','/admin/usage') then
    raise exception 'FORBIDDEN: no export on %', p_page using errcode = '42501';
  end if;
end $$;
revoke all on function public.fn_authorize_export(text) from public, anon;
grant execute on function public.fn_authorize_export(text) to authenticated;

-- Every route used above must be in the page registry: fn_user_page_can denies unknown routes even for legacy accounts,
-- so a stray route would lock current users out. Fail the migration instead.
do $$ declare v_bad text; begin
  select string_agg(p, ', ') into v_bad from unnest(array['/admin/audit-logs','/admin/availability','/admin/availability-rules','/admin/backups','/admin/finance','/admin/finance-controls','/admin/guests','/admin/journey','/admin/organization','/admin/rates','/admin/reports','/admin/review','/admin/roles','/admin/rooms','/admin/staff','/admin/structure','/admin/usage','/staff/dashboard','/staff/day-summary','/staff/followups','/staff/housekeeping','/staff/journey','/staff/payments','/staff/platforms','/staff/reservations']) p
   where not exists (select 1 from public.fn_user_page_catalog() c where c.page = p);
  if v_bad is not null then raise exception '0110: routes missing from the page registry: %', v_bad; end if;
end $$;
