-- UNADOPTED, UNRUN local candidate: expense categories, operation-aware. PAGE CHOICE IS AN ASSUMPTION, not a user ruling: /staff/expenses, because the
-- category list is edited from a modal on the Expenses page (Expenses.tsx) and its read policy already belongs to /staff/bank and /staff/expenses (0113:89-91).
-- Individual non-owner accounts: create = /staff/expenses add, update (rename, sort, is_active) = edit. Legacy and owner keep cap 'definitions'. Body otherwise 0064 text.
create or replace function public.fn_require_expense_category_page(p_action text) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if p_action not in ('add','edit') then raise exception 'FORBIDDEN: definitions' using errcode='42501'; end if;
  if fn_staff_id() is not null and fn_current_role() <> 'owner' and fn_user_access_mode() = 'individual' then
    perform fn_require_user_page('/staff/expenses', p_action);
  else
    perform fn_require_cap('definitions');
  end if;
end $$;
revoke all on function public.fn_require_expense_category_page(text) from public, anon;
grant execute on function public.fn_require_expense_category_page(text) to authenticated;
create or replace function fn_admin_upsert_expense_category(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c expense_categories%rowtype; v_name text := trim(coalesce(p->>'name', '')); before jsonb;
begin
  perform public.fn_require_expense_category_page(case when (p->>'id') is null then 'add' else 'edit' end);
  if v_name = '' or char_length(v_name) > 60 then raise exception 'VALIDATION: name'; end if;
  if (p ? 'sort_order') and coalesce(p->>'sort_order', '') !~ '^[0-9]{1,4}$' then raise exception 'VALIDATION: sort_order'; end if;
  if (p->>'id') is null then
    if exists (select 1 from expense_categories where organization_id = fn_user_org_id() and lower(name) = lower(v_name)) then raise exception 'DUPLICATE_NAME'; end if;
    insert into expense_categories(organization_id, name, sort_order, created_by)
    values (fn_user_org_id(), v_name, coalesce((p->>'sort_order')::int, (select coalesce(max(sort_order), 0) + 10 from expense_categories where organization_id = fn_user_org_id())), fn_staff_id())
    returning * into c;
    perform fn_audit_change(null, 'expense_category.created', 'expense_category', c.id, null, to_jsonb(c));
  else
    select * into c from expense_categories where id = (p->>'id')::uuid and organization_id = fn_user_org_id() for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    perform fn_check_version_strict(c.version, (p->>'version')::int);
    if exists (select 1 from expense_categories where organization_id = c.organization_id and lower(name) = lower(v_name) and id <> c.id) then raise exception 'DUPLICATE_NAME'; end if;
    before := to_jsonb(c);
    update expense_categories set name = v_name, sort_order = coalesce((p->>'sort_order')::int, sort_order),
                                  is_active = coalesce((p->>'is_active')::boolean, is_active), version = version + 1, updated_at = now()
     where id = c.id returning * into c;
    perform fn_audit_change(null, 'expense_category.updated', 'expense_category', c.id, before, to_jsonb(c));
  end if;
  return jsonb_build_object('ok', true, 'id', c.id, 'version', c.version);
end $$;
