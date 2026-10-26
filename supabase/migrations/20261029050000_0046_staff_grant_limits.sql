-- =====================================================================
-- 0046 — No one grants what they do not hold (decision 44, completed after the Phase 7 review).
--        The owner may tick «دعوة موظف وتعديله» for any role. Until now that let a supervisor invite a second address
--        of their own as manager, or make housekeeping a manager, and a manager take away someone's branch the manager
--        does not run. From now on, for everyone but the owner:
--          * a role is given (invitation or edit) only if every cell that role holds in the matrix, the giver holds
--            too — and a cell held without its condition only by a giver who holds it without its condition;
--          * a person is edited, stopped or started only if their present role passes the same test;
--          * a branch is taken from a person, as one is given, only by someone in that branch;
--          * an address that already has a profile in the organisation is not invited again.
--        The owner is unchanged. Changes no data.
-- =====================================================================

-- whether the matrix lets p_role do p_code in p_org (the owner always; the locked row never for anyone else)
create or replace function fn_role_allows(p_org uuid, p_role role_code, p_code text) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when p_role = 'owner' then exists (select 1 from fn_permission_catalog() c where c.code = p_code)
    when exists (select 1 from fn_permission_catalog() c where c.code = p_code and c.locked) then false
    else coalesce(
      (select rp.allowed from role_permissions rp where rp.organization_id = p_org and rp.role = p_role and rp.capability = p_code),
      (select p_role = any(c.default_roles) from fn_permission_catalog() c where c.code = p_code),
      false)
  end;
$$;
revoke all on function fn_role_allows(uuid, role_code, text) from public, anon, authenticated;

-- whether the signed-in person may give (or act on) p_role: the owner always; anyone else only a role within their own cells
create or replace function fn_role_within_mine(p_role role_code) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when fn_current_role() is null then false
    when fn_current_role() = 'owner' then true
    when p_role = 'owner' then false
    else not exists (
      select 1 from fn_permission_catalog() c
       where fn_role_allows(fn_user_org_id(), p_role, c.code)
         and (not fn_can(c.code)
              or ((c.full_roles is null or p_role = any(c.full_roles)) and not fn_cap_full(c.code))))
  end;
$$;
revoke all on function fn_role_within_mine(role_code) from public, anon, authenticated;

create or replace function public.fn_staff_invite(p_email text, p_full_name text, p_role role_code, p_branch_ids uuid[])
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare sp staff_profiles%rowtype; b uuid;
begin
  perform fn_require_cap('staff.manage');
  if p_role = 'guest' then raise exception 'INVALID_ROLE'; end if;
  if p_role = 'owner' and not fn_has_role('owner') then raise exception 'FORBIDDEN: only the owner changes an owner' using errcode = '42501'; end if;
  if not fn_role_within_mine(p_role) then raise exception 'FORBIDDEN: a role beyond your own' using errcode = '42501'; end if;
  if coalesce(trim(p_email), '') = '' or coalesce(trim(p_full_name), '') = '' then raise exception 'VALIDATION: email_and_name'; end if;
  if exists (select 1 from staff_profiles where organization_id = fn_user_org_id() and lower(email) = lower(trim(p_email))) then
    raise exception 'DUPLICATE_EMAIL';
  end if;
  insert into staff_profiles(organization_id, full_name, email, role, is_active) values (fn_user_org_id(), trim(p_full_name), lower(trim(p_email)), p_role, true) returning * into sp;
  foreach b in array coalesce(p_branch_ids, '{}') loop
    perform fn_require_branch(b);
    insert into branch_memberships(staff_id, branch_id) values (sp.id, b)
      on conflict (staff_id, branch_id) do update set removed_at = null, removed_by = null;
  end loop;
  perform fn_audit(sp.organization_id, null, fn_staff_id(), 'staff_invited', 'staff_profile', sp.id,
                   jsonb_build_object('role', p_role, 'branch_ids', to_jsonb(coalesce(p_branch_ids, '{}'))));
  return jsonb_build_object('ok', true, 'staff_id', sp.id);
end $function$;

create or replace function public.fn_admin_update_staff(p jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare sp staff_profiles%rowtype; me uuid := fn_staff_id(); v_reason text := nullif(trim(coalesce(p->>'reason', '')), '');
        v_name text; v_phone text; v_role role_code; v_branches uuid[]; before_b uuid[]; after_b uuid[]; b uuid; changed text[] := '{}';
        before_j jsonb; after_j jsonb; owners int;
begin
  perform fn_require_cap('staff.manage');
  if v_reason is null then raise exception 'VALIDATION: reason'; end if;
  select * into sp from staff_profiles where id = (p->>'staff_id')::uuid and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND: staff'; end if;
  if (sp.role = 'owner' or coalesce(p->>'role', '') = 'owner') and not fn_has_role('owner') then raise exception 'FORBIDDEN: only the owner changes an owner' using errcode = '42501'; end if;
  if p ? 'email' and lower(trim(p->>'email')) is distinct from sp.email then raise exception 'EMAIL_NOT_EDITABLE'; end if;

  v_name := case when p ? 'full_name' then nullif(trim(p->>'full_name'), '') else sp.full_name end;
  if v_name is null then raise exception 'VALIDATION: full_name'; end if;
  v_phone := case when p ? 'phone' then nullif(regexp_replace(coalesce(p->>'phone', ''), '[^0-9+]', '', 'g'), '') else sp.phone end;
  v_role := case when p ? 'role' then (p->>'role')::role_code else sp.role end;
  if v_role = 'guest' then raise exception 'INVALID_ROLE'; end if;
  select coalesce(array_agg(m.branch_id order by m.created_at), '{}') into before_b from branch_memberships m where m.staff_id = sp.id and m.removed_at is null;
  v_branches := case when p ? 'branch_ids' then coalesce((select array_agg(distinct x::uuid) from jsonb_array_elements_text(p->'branch_ids') x), '{}') else before_b end;

  if sp.id = me and (v_role is distinct from sp.role or not (v_branches <@ before_b and before_b <@ v_branches)) then
    raise exception 'SELF_ROLE_OR_BRANCHES';                                            -- no one changes their own role or branches
  end if;
  -- no one acts on a role beyond their own, or gives one (0046)
  if sp.id <> me and (not fn_role_within_mine(sp.role) or not fn_role_within_mine(v_role)) then
    raise exception 'FORBIDDEN: a role beyond your own' using errcode = '42501';
  end if;
  if sp.role = 'owner' and v_role <> 'owner' then
    select count(*) into owners from staff_profiles where organization_id = sp.organization_id and role = 'owner' and is_active and id <> sp.id;
    if owners = 0 then raise exception 'LAST_OWNER: cannot remove or demote the last active owner'; end if;
  end if;
  foreach b in array v_branches loop perform fn_require_branch(b); end loop;
  -- a branch is taken away, as it is given, only by someone in it (0046)
  foreach b in array before_b loop
    if not (b = any(v_branches)) then perform fn_require_branch(b); end if;
  end loop;

  if v_name is distinct from sp.full_name then changed := array_append(changed, 'full_name'); end if;
  if v_phone is distinct from sp.phone then changed := array_append(changed, 'phone'); end if;
  if v_role is distinct from sp.role then changed := array_append(changed, 'role'); end if;
  if not (v_branches <@ before_b and before_b <@ v_branches) then changed := array_append(changed, 'branches'); end if;
  if coalesce(array_length(changed, 1), 0) = 0 then return jsonb_build_object('ok', true, 'unchanged', true); end if;

  perform set_config('app.staff_edit', '1', true);
  update staff_profiles set full_name = v_name, phone = v_phone, role = v_role, updated_at = now() where id = sp.id;
  -- memberships: retire what is gone, re-open or add what is new (effective from the person's next operation)
  update branch_memberships set removed_at = now(), removed_by = me where staff_id = sp.id and removed_at is null and not (branch_id = any(v_branches));
  foreach b in array v_branches loop
    insert into branch_memberships(staff_id, branch_id) values (sp.id, b)
      on conflict (staff_id, branch_id) do update set removed_at = null, removed_by = null;
  end loop;
  select coalesce(array_agg(m.branch_id order by m.created_at), '{}') into after_b from branch_memberships m where m.staff_id = sp.id and m.removed_at is null;
  perform set_config('app.staff_edit', '', true);

  before_j := jsonb_build_object('full_name', sp.full_name, 'phone', case when sp.phone is null then null else '••••' || right(sp.phone, 4) end, 'role', sp.role, 'branch_ids', to_jsonb(before_b));
  after_j  := jsonb_build_object('full_name', v_name, 'phone', case when v_phone is null then null else '••••' || right(v_phone, 4) end, 'role', v_role, 'branch_ids', to_jsonb(after_b));
  perform fn_audit(sp.organization_id, null, me, case when 'role' = any(changed) then 'staff.role_changed' else 'staff.updated' end, 'staff_profile', sp.id,
                   jsonb_build_object('changed', to_jsonb(changed), 'before', before_j, 'after', after_j, 'reason', v_reason));
  return jsonb_build_object('ok', true, 'changed', to_jsonb(changed));
end $function$;

create or replace function public.fn_admin_set_staff_active(p_staff uuid, p_active boolean, p_reason text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare sp staff_profiles%rowtype; n int := 0;
begin
  perform fn_require_cap('staff.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'VALIDATION: reason'; end if;
  select * into sp from staff_profiles where id = p_staff and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND: staff'; end if;
  if sp.id = fn_staff_id() then raise exception 'SELF_NOT_ALLOWED'; end if;
  if sp.role = 'owner' and not fn_has_role('owner') then raise exception 'FORBIDDEN: only the owner changes an owner' using errcode = '42501'; end if;
  if not fn_role_within_mine(sp.role) then raise exception 'FORBIDDEN: a role beyond your own' using errcode = '42501'; end if;
  if sp.is_active = coalesce(p_active, sp.is_active) then return jsonb_build_object('ok', true, 'unchanged', true); end if;
  perform set_config('app.staff_reason', trim(p_reason), true);
  update staff_profiles set is_active = p_active, updated_at = now(), sessions_ended_at = case when p_active then sessions_ended_at else now() end where id = sp.id;
  perform set_config('app.staff_reason', '', true);
  if not p_active then n := fn_end_sessions(sp.auth_user_id); end if;
  return jsonb_build_object('ok', true, 'is_active', p_active, 'sessions_ended', n);
end $function$;
