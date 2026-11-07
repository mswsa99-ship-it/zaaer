-- 0062 — A1 of the accounting stage (plan «خطة تصحيح ملاحظات التجربة», stage م٣; rule «الفروع مفصولة تمامًا»):
--   · each branch has exactly one cash box and one bank account in use; a second one of the same kind is refused
--     (a closed account is archived with its reason, then its replacement is added; history keeps both);
--   · the bank account carries what identifies it in the bank's messages: the first and last digits of its number
--     (the owner's rule «يبدأ بـ… وينتهي بـ…», used by A6–A9 to attribute each bank movement to its branch) and its bank;
--     two branches cannot share the same start and end. The IBAN stays in one place, the branch's bank details (0056,
--     shown to guests for transfers), and the two must agree: the IBAN ends with the account's last digits, checked
--     whichever of the two is saved second;
--   · whatever path writes it (an RPC, an import, a future job), a voucher, a terminal settlement or a platform payout
--     on an account of another branch is refused by the database itself.

alter table cash_accounts add column if not exists account_prefix text;
alter table cash_accounts add column if not exists account_suffix text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'cash_account_prefix_valid') then
    alter table cash_accounts add constraint cash_account_prefix_valid check (account_prefix is null or account_prefix ~ '^[0-9]{2,6}$');
    alter table cash_accounts add constraint cash_account_suffix_valid check (account_suffix is null or account_suffix ~ '^[0-9]{2,6}$');
    alter table cash_accounts add constraint cash_account_bank_fields_only check (kind = 'bank_account' or (account_prefix is null and account_suffix is null));
  end if;
end $$;

-- one in use per kind per branch (archived ones stay for their vouchers)
create unique index if not exists uniq_cash_account_one_per_kind on cash_accounts(branch_id, kind) where archived_at is null;
-- the start and end of an account number point to one branch only
create unique index if not exists uniq_cash_account_number_rule on cash_accounts(organization_id, account_prefix, account_suffix)
  where archived_at is null and account_prefix is not null and account_suffix is not null;

-- the account of a voucher, a settlement or a payout belongs to the same branch, on every path
create or replace function fn_account_same_branch() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.account_id is not null and not exists (select 1 from cash_accounts where id = new.account_id and branch_id = new.branch_id) then
    raise exception 'BRANCH_MISMATCH: account';
  end if;
  return new;
end $$;
revoke all on function fn_account_same_branch() from public, anon, authenticated;
create or replace trigger trg_voucher_account_branch before insert or update of account_id, branch_id on financial_vouchers
  for each row execute function fn_account_same_branch();
create or replace trigger trg_pos_settlement_account_branch before insert or update of account_id, branch_id on pos_settlements
  for each row execute function fn_account_same_branch();
create or replace trigger trg_platform_payout_account_branch before insert or update of account_id, branch_id on platform_payouts
  for each row execute function fn_account_same_branch();

-- the owner (or whoever holds «الصناديق والحسابات») defines them: one per kind, always the branch's default
create or replace function fn_admin_upsert_cash_account(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a cash_accounts%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; before jsonb;
        v_kind text := p->>'kind'; v_name text := trim(coalesce(p->>'name', ''));
        v_last4 text := nullif(trim(coalesce(p->>'account_last4', '')), ''); v_bank text := nullif(trim(coalesce(p->>'bank_name', '')), '');
        v_prefix text := nullif(trim(fn_latin_digits(coalesce(p->>'account_prefix', ''))), ''); v_suffix text := nullif(trim(fn_latin_digits(coalesce(p->>'account_suffix', ''))), '');
        v_org uuid;
begin
  perform fn_require_cap('cash_accounts');
  if v_name = '' or length(v_name) > 60 then raise exception 'VALIDATION: name'; end if;
  if v_bank is not null and char_length(v_bank) > 80 then raise exception 'VALIDATION: bank_name'; end if;
  if v_last4 is not null and v_last4 !~ '^[0-9]{4}$' then raise exception 'VALIDATION: account_last4'; end if;
  if v_prefix is not null and v_prefix !~ '^[0-9]{2,6}$' then raise exception 'VALIDATION: account_prefix'; end if;
  if v_suffix is not null and v_suffix !~ '^[0-9]{2,6}$' then raise exception 'VALIDATION: account_suffix'; end if;
  if (v_prefix is null) <> (v_suffix is null) then raise exception 'VALIDATION: account_rule'; end if;
  if v_id is null then
    perform fn_require_branch(v_branch);
    if v_kind not in ('cash_box', 'bank_account') then raise exception 'VALIDATION: kind'; end if;
    if v_kind = 'cash_box' then v_last4 := null; v_bank := null; v_prefix := null; v_suffix := null; end if;
    perform pg_advisory_xact_lock(hashtext('cash_account:' || v_branch::text || ':' || v_kind));
    if exists (select 1 from cash_accounts where branch_id = v_branch and kind = v_kind and archived_at is null) then raise exception 'ACCOUNT_EXISTS'; end if;
    if exists (select 1 from cash_accounts where branch_id = v_branch and lower(name) = lower(v_name) and archived_at is null) then raise exception 'DUPLICATE_NAME'; end if;
    select organization_id into v_org from branches where id = v_branch;
    if v_prefix is not null and exists (select 1 from cash_accounts where organization_id = v_org and account_prefix = v_prefix and account_suffix = v_suffix and archived_at is null) then
      raise exception 'DUPLICATE_ACCOUNT_RULE';
    end if;
    if v_suffix is not null and exists (select 1 from branches where id = v_branch and bank_iban is not null and right(bank_iban, length(v_suffix)) <> v_suffix) then
      raise exception 'VALIDATION: iban_suffix';
    end if;
    insert into cash_accounts(organization_id, branch_id, kind, name, bank_name, account_last4, account_prefix, account_suffix, is_default, created_by)
    values (v_org, v_branch, v_kind, v_name, v_bank, coalesce(v_last4, case when v_suffix is not null and length(v_suffix) >= 4 then right(v_suffix, 4) end),
            v_prefix, v_suffix, true, fn_staff_id())
    returning * into a;
    perform fn_audit_change(a.branch_id, 'cash_account.created', 'cash_account', a.id, null, to_jsonb(a));
  else
    select * into a from cash_accounts where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    perform fn_require_branch(a.branch_id);
    perform fn_check_version_strict(a.version, (p->>'version')::int);
    if a.archived_at is not null then raise exception 'VALIDATION: account_archived'; end if;
    if exists (select 1 from cash_accounts where branch_id = a.branch_id and lower(name) = lower(v_name) and archived_at is null and id <> a.id) then raise exception 'DUPLICATE_NAME'; end if;
    if a.kind = 'bank_account' and v_prefix is not null and exists (select 1 from cash_accounts where organization_id = a.organization_id and account_prefix = v_prefix
                                                                      and account_suffix = v_suffix and archived_at is null and id <> a.id) then
      raise exception 'DUPLICATE_ACCOUNT_RULE';
    end if;
    before := to_jsonb(a);
    update cash_accounts set name = v_name,
      bank_name = case when kind = 'bank_account' then (case when p ? 'bank_name' then v_bank else bank_name end) end,
      account_last4 = case when kind = 'bank_account' then (case when p ? 'account_last4' then v_last4
                                                                 when p ? 'account_suffix' and v_suffix is not null and length(v_suffix) >= 4 then right(v_suffix, 4)
                                                                 else account_last4 end) end,
      account_prefix = case when kind = 'bank_account' then (case when p ? 'account_prefix' then v_prefix else account_prefix end) end,
      account_suffix = case when kind = 'bank_account' then (case when p ? 'account_suffix' then v_suffix else account_suffix end) end,
      is_default = true,
      is_active = coalesce((p->>'is_active')::boolean, is_active), version = version + 1, updated_at = now()
    where id = a.id returning * into a;
    -- the account's last digits agree with the IBAN in the branch's bank details
    if a.account_suffix is not null and exists (select 1 from branches where id = a.branch_id and bank_iban is not null and right(bank_iban, length(a.account_suffix)) <> a.account_suffix) then
      raise exception 'VALIDATION: iban_suffix';
    end if;
    perform fn_audit_change(a.branch_id, 'cash_account.updated', 'cash_account', a.id, before, to_jsonb(a));
  end if;
  return jsonb_build_object('ok', true, 'id', a.id, 'version', a.version);
end $$;
revoke all on function fn_admin_upsert_cash_account(jsonb) from public, anon;
grant execute on function fn_admin_upsert_cash_account(jsonb) to authenticated;

-- archive / restore: a restored account is the one in use again, so only when none of its kind is in use
create or replace function fn_admin_archive_cash_account(p_id uuid, p_archive boolean, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a cash_accounts%rowtype; before jsonb; used int;
begin
  perform fn_require_cap('cash_accounts');
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

-- the branch's bank details (0056) refuse an IBAN that does not end with the last digits of the branch's bank account
do $$
declare fn oid; def text; n int;
        old_p constant text := $a$    b.bank_iban := v;$a$;
        new_p constant text := $b$    if v is not null and exists (select 1 from cash_accounts where branch_id = b.id and kind = 'bank_account' and archived_at is null
                                    and account_suffix is not null and right(v, length(account_suffix)) <> account_suffix) then
      raise exception 'VALIDATION: iban_suffix';
    end if;
    b.bank_iban := v;$b$;
begin
  select p.oid into fn from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'fn_admin_set_branch_guide';
  if fn is null then raise exception '0062: fn_admin_set_branch_guide is missing'; end if;
  def := pg_get_functiondef(fn);
  n := (length(def) - length(replace(def, old_p, ''))) / length(old_p);
  if n <> 1 then raise exception '0062: the IBAN line of fn_admin_set_branch_guide was found % times, not once', n; end if;
  execute replace(def, old_p, new_p);
end $$;
