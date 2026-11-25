begin;
create or replace function public.fn_can(p_code text) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when fn_current_role() = 'owner' or fn_user_access_mode() <> 'individual' then fn_can_role_matrix(p_code)
    when not exists(select 1 from fn_permission_catalog() c where c.code=p_code and not c.locked) then false
    else exists (
      select 1 from permission_page_map m
       where m.code = p_code
         and fn_user_page_can(m.page, 'view')
         and (fn_user_page_can(m.page, m.action)
              or (m.any_write and (fn_user_page_can(m.page, 'add') or fn_user_page_can(m.page, 'edit'))))
         and (not m.sensitive or exists (
               select 1 from staff_page_access a
                where a.staff_id = fn_staff_id() and a.organization_id = fn_user_org_id() and a.enabled
                  and jsonb_typeof(a.sensitive_grants) = 'array' and a.sensitive_grants ? p_code)))
  end
$$;

create or replace function public.fn_can_write(p_code text, p_action text) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when p_action is null or p_action not in ('add','edit','delete') then false
    when fn_current_role() = 'owner' or fn_user_access_mode() <> 'individual' then fn_can_role_matrix(p_code)
    when not exists(select 1 from fn_permission_catalog() c where c.code=p_code and not c.locked) then false
    else exists (
      select 1 from permission_page_map m
       where m.code = p_code and m.any_write
         and fn_user_page_can(m.page, 'view') and fn_user_page_can(m.page, p_action)
         and (not m.sensitive or exists (
               select 1 from staff_page_access a
                where a.staff_id = fn_staff_id() and a.organization_id = fn_user_org_id() and a.enabled
                  and jsonb_typeof(a.sensitive_grants) = 'array' and a.sensitive_grants ? p_code)))
  end
$$;

commit;
