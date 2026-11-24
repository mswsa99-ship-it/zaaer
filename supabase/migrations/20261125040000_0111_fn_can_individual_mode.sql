-- 0111 fn_can in individual mode (RPC/edge worker). Needs 0109 (staff_page_access, fn_user_access_mode, fn_user_page_can).
-- Legacy accounts and the owner: fn_can answers exactly what it answered before (the old body, renamed). Individual
-- accounts: the old answer must still be true (role matrix, locked codes, never widened) AND the code must be mapped
-- to a page action in permission_page_map AND the page grants allow view + that action AND, for a sensitive code, the
-- code is in the person's sensitive_grants. A code with no map row is DENIED in individual mode (fail closed).
-- fn_cap_full is untouched: it calls fn_can (so the new rules apply) and keeps the full_roles limit by base role, so
-- page.edit never means "full" and the discount / voucher / task limits stay exactly as they were.
do $$ begin
  if to_regprocedure('public.fn_user_access_mode()') is null or to_regprocedure('public.fn_user_page_can(text,text)') is null then
    raise exception '0111 needs the 0109 page-guard foundation first';
  end if;
end $$;

create table if not exists public.permission_page_map (
  code text primary key,
  page text not null,
  action text not null check (action in ('view','add','edit','delete','export')),
  sensitive boolean not null default false,
  -- a code that covers both creating and changing rows: fn_can accepts add OR edit on the page (coarse gate). The
  -- endpoint / RLS write policy must still ask the exact action (insert = add, update = edit, delete = delete).
  any_write boolean not null default false
);
alter table public.permission_page_map enable row level security;
revoke all on public.permission_page_map from public, anon, authenticated;
-- No rows are seeded here: the code -> (page, action, sensitive) table is the permissions worker's proposal and is not
-- owner-approved yet. Until it is filled, an individual account is denied every fn_can code. Individual mode is disabled.

-- NOT a rename: policies, constraints and views bind fn_can by object id, so renaming it would keep them on the old
-- body (no individual rules) and make them call a function their role cannot execute. fn_can keeps its identity and
-- grants and is replaced in place; the old body lives on, unchanged, as fn_can_role_matrix, which only fn_can (a
-- security definer function, running as the owner) calls.
create or replace function public.fn_can_role_matrix(p_code text) returns boolean
language sql stable security definer set search_path = public as $$
  with me as (select fn_current_role() as r, fn_user_org_id() as org)
  select case
    when (select r from me) is null then false
    when (select r from me) = 'owner' then exists (select 1 from fn_permission_catalog() c where c.code = p_code)
    when exists (select 1 from fn_permission_catalog() c where c.code = p_code and c.locked) then false
    else coalesce(
      (select rp.allowed from role_permissions rp, me where rp.organization_id = me.org and rp.role = me.r and rp.capability = p_code),
      (select me.r = any(c.default_roles) from fn_permission_catalog() c, me where c.code = p_code),
      false)
  end;
$$;
revoke all on function public.fn_can_role_matrix(text) from public, anon, authenticated;

create or replace function public.fn_can(p_code text) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when not fn_can_role_matrix(p_code) then false
    when fn_current_role() = 'owner' or fn_user_access_mode() <> 'individual' then true
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
grant execute on function public.fn_can(text) to authenticated;   -- unchanged from 0043; anon never had it

-- For certification before activation: catalog codes that have no map row (they would be denied to individual accounts).
create function public.fn_permission_map_unmapped() returns setof text
language sql stable security definer set search_path = public as $$
  select c.code from fn_permission_catalog() c where not c.locked and not exists (select 1 from permission_page_map m where m.code = c.code) order by c.code
$$;
revoke all on function public.fn_permission_map_unmapped() from public, anon, authenticated;

-- A map row must name a real route and a real catalog code.
create function public.fn_permission_map_check() returns trigger language plpgsql set search_path=public as $$
begin
  if not exists (select 1 from fn_user_page_catalog() c where c.page = new.page) then raise exception 'permission_page_map: unknown page %', new.page; end if;
  if not exists (select 1 from fn_permission_catalog() c where c.code = new.code) then raise exception 'permission_page_map: unknown code %', new.code; end if;
  return new;
end $$;
create trigger permission_page_map_check before insert or update on public.permission_page_map for each row execute function public.fn_permission_map_check();

-- Exact-action gate for write policies and write endpoints (insert = add, update = edit, delete = delete).
-- Two independent checks: the base role matrix must allow the code (never widened) AND, in individual mode, the page
-- grant must allow exactly p_action. Not a general bypass: it answers only for the caller, only for add/edit/delete,
-- only for codes the map marks any_write (others: use fn_can), and never returns true where fn_can_role_matrix is false.
-- Legacy accounts and the owner: same answer as fn_can (the role matrix alone).
create or replace function public.fn_can_write(p_code text, p_action text) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when p_action is null or p_action not in ('add','edit','delete') then false
    when not fn_can_role_matrix(p_code) then false
    when fn_current_role() = 'owner' or fn_user_access_mode() <> 'individual' then true
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
revoke all on function public.fn_can_write(text, text) from public, anon;
grant execute on function public.fn_can_write(text, text) to authenticated;

revoke all on function public.fn_permission_map_check() from public, anon, authenticated;
