-- 0151 rollback: restores the two staff functions to their live definitions from before 0151 and drops the helper.
CREATE OR REPLACE FUNCTION public.fn_admin_invite_staff(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare sp staff_profiles%rowtype; b uuid; v_email text := lower(trim(coalesce(p->>'email', ''))); v_name text := trim(coalesce(p->>'full_name', ''));
        v_role role_code; v_branches uuid[]; v_phone_in text := nullif(trim(coalesce(p->>'phone', '')), ''); v_phone text;
begin
  perform fn_require_cap('staff.manage');
  begin v_role := (p->>'role')::role_code; exception when others then raise exception 'INVALID_ROLE'; end;
  if v_role is null or v_role = 'guest' then raise exception 'INVALID_ROLE'; end if;
  if v_role = 'owner' and not fn_has_role('owner') then raise exception 'FORBIDDEN: only the owner changes an owner' using errcode = '42501'; end if;
  if v_role = 'owner' then raise exception 'OWNER_SELF_SIGNUP_REQUIRED' using errcode='42501';end if;
  if not fn_role_within_mine(v_role) then raise exception 'FORBIDDEN: a role beyond your own' using errcode = '42501'; end if;
  if v_email = '' or v_name = '' then raise exception 'VALIDATION: email_and_name'; end if;
  if not fn_valid_email(v_email) then raise exception 'VALIDATION: email'; end if;
  if char_length(v_name) > 120 then raise exception 'VALIDATION: full_name'; end if;
  if v_phone_in is not null then
    v_phone := nullif(regexp_replace(fn_latin_digits(v_phone_in), '[^0-9+]', '', 'g'), '');
    if fn_normalize_phone(v_phone) is null then raise exception 'VALIDATION: phone'; end if;
  end if;
  select coalesce(array_agg(distinct x::uuid), '{}') into v_branches from jsonb_array_elements_text(coalesce(p->'branch_ids', '[]'::jsonb)) x;
  if v_role <> 'owner' and cardinality(v_branches) = 0 then raise exception 'VALIDATION: branch_required'; end if;
  if exists (select 1 from staff_profiles where organization_id = fn_user_org_id() and lower(email) = v_email) then
    raise exception 'DUPLICATE_EMAIL';
  end if;
  insert into staff_profiles(organization_id, full_name, email, phone, role, is_active) values (fn_user_org_id(), v_name, v_email, v_phone, v_role, true) returning * into sp;
  foreach b in array v_branches loop
    perform fn_require_branch(b);
    insert into branch_memberships(staff_id, branch_id) values (sp.id, b)
      on conflict (staff_id, branch_id) do update set removed_at = null, removed_by = null;
  end loop;
  perform fn_audit(sp.organization_id, null, fn_staff_id(), 'staff_invited', 'staff_profile', sp.id,
                   jsonb_build_object('role', v_role, 'branch_ids', to_jsonb(v_branches), 'phone', v_phone is not null));
  return jsonb_build_object('ok', true, 'staff_id', sp.id);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_admin_update_staff(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare sp staff_profiles%rowtype; me uuid := fn_staff_id(); v_reason text := nullif(trim(coalesce(p->>'reason', '')), '');
        v_name text; v_phone text; v_role role_code; v_branches uuid[]; before_b uuid[]; after_b uuid[]; b uuid; changed text[] := '{}';
        before_j jsonb; after_j jsonb; owners int; v_email text;
begin
  perform fn_require_cap('staff.manage');
  if v_reason is null then raise exception 'VALIDATION: reason'; end if;
  select * into sp from staff_profiles where id = (p->>'staff_id')::uuid and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND: staff'; end if;
  if (sp.role = 'owner' or coalesce(p->>'role', '') = 'owner') and not fn_has_role('owner') then raise exception 'FORBIDDEN: only the owner changes an owner' using errcode = '42501'; end if;
  v_email := sp.email;
  if p ? 'email' and lower(trim(coalesce(p->>'email', ''))) is distinct from sp.email then
    if sp.auth_user_id is not null then raise exception 'EMAIL_NOT_EDITABLE'; end if;
    v_email := lower(trim(coalesce(p->>'email', '')));
    if not fn_valid_email(v_email) then raise exception 'VALIDATION: email'; end if;
    if exists (select 1 from staff_profiles where organization_id = sp.organization_id and lower(email) = v_email and id <> sp.id) then raise exception 'DUPLICATE_EMAIL'; end if;
  end if;

  v_name := case when p ? 'full_name' then nullif(trim(p->>'full_name'), '') else sp.full_name end;
  if v_name is null or char_length(v_name) > 120 then raise exception 'VALIDATION: full_name'; end if;
  if p ? 'phone' then
    if nullif(trim(coalesce(p->>'phone', '')), '') is null then v_phone := null;
    else
      v_phone := nullif(regexp_replace(fn_latin_digits(p->>'phone'), '[^0-9+]', '', 'g'), '');
      if fn_normalize_phone(v_phone) is null then raise exception 'VALIDATION: phone'; end if;
    end if;
  else v_phone := sp.phone; end if;
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

  if v_email is distinct from sp.email then changed := array_append(changed, 'email'); end if;
  if v_name is distinct from sp.full_name then changed := array_append(changed, 'full_name'); end if;
  if v_phone is distinct from sp.phone then changed := array_append(changed, 'phone'); end if;
  if v_role is distinct from sp.role then changed := array_append(changed, 'role'); end if;
  if not (v_branches <@ before_b and before_b <@ v_branches) then changed := array_append(changed, 'branches'); end if;
  if coalesce(array_length(changed, 1), 0) = 0 then return jsonb_build_object('ok', true, 'unchanged', true); end if;

  perform set_config('app.staff_edit', '1', true);
  update staff_profiles set email = v_email, full_name = v_name, phone = v_phone, role = v_role, updated_at = now() where id = sp.id;
  -- memberships: retire what is gone, re-open or add what is new (effective from the person's next operation)
  update branch_memberships set removed_at = now(), removed_by = me where staff_id = sp.id and removed_at is null and not (branch_id = any(v_branches));
  foreach b in array v_branches loop
    insert into branch_memberships(staff_id, branch_id) values (sp.id, b)
      on conflict (staff_id, branch_id) do update set removed_at = null, removed_by = null;
  end loop;
  select coalesce(array_agg(m.branch_id order by m.created_at), '{}') into after_b from branch_memberships m where m.staff_id = sp.id and m.removed_at is null;
  perform set_config('app.staff_edit', '', true);

  before_j := jsonb_build_object('email', sp.email, 'full_name', sp.full_name, 'phone', case when sp.phone is null then null else '••••' || right(sp.phone, 4) end, 'role', sp.role, 'branch_ids', to_jsonb(before_b));
  after_j  := jsonb_build_object('email', v_email, 'full_name', v_name, 'phone', case when v_phone is null then null else '••••' || right(v_phone, 4) end, 'role', v_role, 'branch_ids', to_jsonb(after_b));
  perform fn_audit(sp.organization_id, null, me, case when 'role' = any(changed) then 'staff.role_changed' else 'staff.updated' end, 'staff_profile', sp.id,
                   jsonb_build_object('changed', to_jsonb(changed), 'before', before_j, 'after', after_j, 'reason', v_reason));
  return jsonb_build_object('ok', true, 'changed', to_jsonb(changed));
end $function$;

DROP FUNCTION IF EXISTS public.fn_person_name_key(text);
