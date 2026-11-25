-- LOCAL CANDIDATE v2 (knowledge body rebound to the v7 live text: search_path public,extensions and the legacy cap gate kept; one added gate). UNADOPTED. Archive/restore of cash accounts, knowledge entries and branch media follows the page EDIT (approved item 1, original user reply 2026-11-25 06:19:08 to the 06:14:40 list; header is provenance only).
-- Bodies are generated from the live text (0062, 0010, 0056; 0124 does not touch these three); one gate replaced or added in each.
create or replace function fn_admin_archive_cash_account(p_id uuid, p_archive boolean, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a cash_accounts%rowtype; before jsonb; used int;
begin
  perform fn_require_cap('cash_accounts');
  -- 0124 pattern: archive and restore need the page's EDIT exactly (add-only is no longer enough); legacy and owner unchanged by fn_can_write
  if not fn_can_write('cash_accounts', 'edit') then raise exception 'FORBIDDEN: cash_accounts write' using errcode = '42501'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'VALIDATION: reason'; end if;
  select * into a from cash_accounts where id = p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(a.branch_id);
  before := to_jsonb(a);
  select count(*) into used from financial_vouchers where account_id = a.id;
  if p_archive then
    if a.archived_at is not null then return jsonb_build_object('ok', true, 'unchanged', true); end if;
    update cash_accounts set archived_at = now(), archived_by = fn_staff_id(), archive_reason = p_reason, is_default = false,
                             version = version + 1, updated_at = now() where id = a.id returning * into a;
  else
    if a.archived_at is null then return jsonb_build_object('ok', true, 'unchanged', true); end if;
    perform pg_advisory_xact_lock(hashtext('cash_account:' || a.branch_id::text || ':' || a.kind));
    if exists (select 1 from cash_accounts where branch_id = a.branch_id and kind = a.kind and archived_at is null) then raise exception 'ACCOUNT_EXISTS'; end if;
    if exists (select 1 from cash_accounts where branch_id = a.branch_id and lower(name) = lower(a.name) and archived_at is null and id <> a.id) then raise exception 'DUPLICATE_NAME'; end if;
    if a.account_prefix is not null and exists (select 1 from cash_accounts where organization_id = a.organization_id and account_prefix = a.account_prefix
                                                and account_suffix = a.account_suffix and archived_at is null and id <> a.id) then
      raise exception 'DUPLICATE_ACCOUNT_RULE';
    end if;
    update cash_accounts set archived_at = null, archived_by = null, archive_reason = null, is_default = true, version = version + 1, updated_at = now()
     where id = a.id returning * into a;
  end if;
  perform fn_audit_change(a.branch_id, case when p_archive then 'cash_account.archived' else 'cash_account.restored' end, 'cash_account', a.id, before, to_jsonb(a), p_reason);
  return jsonb_build_object('ok', true, 'used_by_vouchers', used,
    'default_missing', not exists (select 1 from cash_accounts where branch_id = a.branch_id and kind = a.kind and is_default and archived_at is null));
end $$;
revoke all on function fn_admin_archive_cash_account(uuid, boolean, text) from public, anon;
grant execute on function fn_admin_archive_cash_account(uuid, boolean, text) to authenticated;

create or replace function public.fn_admin_archive_knowledge(p_id uuid, p_reason text, p_archive boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare k knowledge_entries%rowtype;
begin
  perform fn_require_cap('knowledge');
  -- user item 1 (reply 2026-11-25 06:19:08, provenance only): archive and restore need the knowledge page's EDIT; legacy and owner unchanged by fn_can_write
  if not fn_can_write('knowledge', 'edit') then raise exception 'FORBIDDEN: knowledge write' using errcode = '42501'; end if;
  select * into k from knowledge_entries where id = p_id and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if k.branch_id is not null then perform fn_require_branch(k.branch_id); end if;
  if p_archive then
    if coalesce(trim(p_reason),'') = '' then raise exception 'VALIDATION: reason'; end if;
    update knowledge_entries set archived_at = now(), archived_by = fn_staff_id(), archive_reason = p_reason, is_active = false, version = version + 1, updated_at = now() where id = k.id;
  else
    update knowledge_entries set archived_at = null, archived_by = null, archive_reason = null, is_active = true, version = version + 1, updated_at = now() where id = k.id;
  end if;
  perform fn_audit(k.organization_id, k.branch_id, fn_staff_id(), case when p_archive then 'knowledge.archived' else 'knowledge.restored' end, 'knowledge_entry', k.id, jsonb_build_object('reason', p_reason, 'before', jsonb_build_object('archived_at', k.archived_at)));
  return jsonb_build_object('ok', true);
end $function$;
revoke all on function fn_admin_archive_knowledge(uuid, text, boolean) from public, anon;
grant execute on function fn_admin_archive_knowledge(uuid, text, boolean) to authenticated;

create or replace function fn_admin_archive_media_item(p_id uuid, p_reason text, p_archive boolean default true) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m branch_media_items%rowtype;
begin
  -- media objects have two owning pages: gallery items live in the branch editor (/admin/branches), unit check-in/check-out photos live on /admin/journey.
  -- individual non-owner accounts follow EDIT on the page that owns THAT object (no cross-page widening); legacy and owner keep cap branch.settings.
  select * into m from branch_media_items where id = p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if fn_staff_id() is not null and fn_current_role() <> 'owner' and fn_user_access_mode() = 'individual' then
    perform fn_require_user_page(case when m.purpose = 'gallery' then '/admin/branches' else '/admin/journey' end, 'edit');
  else
    perform fn_require_cap('branch.settings');
  end if;
  perform fn_require_branch(m.branch_id);
  if p_archive then
    if coalesce(trim(p_reason), '') = '' then raise exception 'VALIDATION: reason'; end if;
    update branch_media_items set archived_at = now(), archived_by = fn_staff_id(), archive_reason = trim(p_reason) where id = m.id;
  else
    update branch_media_items set archived_at = null, archived_by = null, archive_reason = null where id = m.id;
  end if;
  perform fn_audit_change(m.branch_id, case when p_archive then 'branch.media_archived' else 'branch.media_restored' end, 'branch_media_item', m.id,
    null, jsonb_build_object('kind', m.kind, 'caption', m.caption), nullif(trim(coalesce(p_reason, '')), ''));
  return jsonb_build_object('ok', true);
end $$;
revoke all on function fn_admin_archive_media_item(uuid, text, boolean) from public, anon;
grant execute on function fn_admin_archive_media_item(uuid, text, boolean) to authenticated;

