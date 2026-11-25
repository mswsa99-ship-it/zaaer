-- 0114: enforce membership boundaries on four branch-scoped direct reads.
-- Restrictive policies only narrow existing role/page gates. No write grants or hotel-scope changes.
begin;
create policy branch_membership_read_boundary on public.branch_memberships as restrictive for select to authenticated
  using (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()));
create policy product_branch_read_boundary on public.product_branches as restrictive for select to authenticated
  using (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()));
create policy ai_guard_branch_read_boundary on public.ai_guardrail_events as restrictive for select to authenticated
  using (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()));
create policy ai_tool_branch_read_boundary on public.ai_tool_executions as restrictive for select to authenticated
  using (organization_id = (select fn_user_org_id()) and branch_id in (select fn_user_branch_ids()));

-- Keep the hotel staff registry and established sensitive-field gates.
-- SECURITY DEFINER bypasses table RLS, so branch metadata needs an explicit membership filter here too.
create or replace function public.fn_admin_staff_list() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when (fn_can('staff.manage') or fn_can('staff.force_logout')) then coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', s.id, 'full_name', s.full_name, 'email', s.email, 'phone', case when fn_can('staff.manage') then s.phone end,
      'role', s.role, 'is_active', s.is_active, 'linked', s.auth_user_id is not null, 'created_at', s.created_at,
      'sessions_ended_at', s.sessions_ended_at, 'updated_at', s.updated_at,
      'branch_ids', coalesce((select jsonb_agg(m.branch_id order by m.created_at) from branch_memberships m
        where m.staff_id = s.id and m.removed_at is null and m.branch_id in (select fn_user_branch_ids())), '[]'::jsonb),
      'is_me', s.id = fn_staff_id()) order by s.is_active desc, s.full_name)
    from staff_profiles s where s.organization_id = fn_user_org_id()), '[]'::jsonb)
  else '[]'::jsonb end;
$$;
commit;
