-- 0124 exact write-action guards for eight existing bank / cash / knowledge entry points.
-- Each function keeps its fn_require_cap(code) check and every later role / branch / version / business check unchanged,
-- and gains ONE extra line right after the capability check: fn_can_write(code, action) -> 42501 when false.
-- Owner and legacy accounts: fn_can_write falls to fn_can_role_matrix, same answer as fn_require_cap, so no behaviour change.
-- Individual accounts: needs page view + the exact add/edit grant (+ sensitive grant where mapped).
-- Edit actions: bank assign/match/reparse/unmatch, cash opening, resolve unanswered. Upserts: add when p.id absent, edit when present
-- (a supplied id never falls back to create; the unchanged implementation still answers NOT_FOUND). No map/flag/page change.
begin;

CREATE OR REPLACE FUNCTION public.fn_admin_resolve_unanswered(p_id uuid, p_status text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare u unanswered_questions%rowtype;
begin
  perform fn_require_cap('knowledge');
  if not fn_can_write('knowledge', 'edit') then raise exception 'FORBIDDEN: knowledge write' using errcode = '42501'; end if;
  if p_status not in ('open','ignored') then raise exception 'VALIDATION: status'; end if;
  select * into u from unanswered_questions where id = p_id and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if u.branch_id is not null then perform fn_require_branch(u.branch_id); end if;
  update unanswered_questions set status = p_status, resolved_by = case when p_status = 'open' then null else fn_staff_id() end,
    resolved_at = case when p_status = 'open' then null else now() end, resolve_note = p_note where id = u.id;
  perform fn_audit(u.organization_id, u.branch_id, fn_staff_id(), 'unanswered.' || p_status, 'unanswered_question', u.id, jsonb_build_object('before', u.status, 'after', p_status, 'reason', p_note));
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_admin_set_account_opening(p_account uuid, p_halalas bigint, p_on date, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a cash_accounts%rowtype; v_balance bigint; v_reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  perform fn_require_cap('cash_accounts');
  if not fn_can_write('cash_accounts', 'edit') then raise exception 'FORBIDDEN: cash_accounts write' using errcode = '42501'; end if;
  if fn_current_role() <> 'owner' then raise exception 'FORBIDDEN: owner_only' using errcode = '42501'; end if;
  select * into a from cash_accounts where id = p_account and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(a.branch_id);
  if p_halalas is null or abs(p_halalas) > 100000000000 then raise exception 'VALIDATION: amount'; end if;
  if p_on is null or p_on > fn_branch_today(a.branch_id) then raise exception 'VALIDATION: opening_on'; end if;
  if v_reason is null or char_length(v_reason) > 500 then raise exception 'VALIDATION: reason'; end if;
  update cash_accounts set opening_balance_halalas = p_halalas, opening_on = p_on, version = version + 1, updated_at = now() where id = a.id;
  perform fn_audit_change(a.branch_id, 'cash_account.opening_set', 'cash_account', a.id,
                          jsonb_build_object('opening_balance_halalas', a.opening_balance_halalas, 'opening_on', a.opening_on),
                          jsonb_build_object('opening_balance_halalas', p_halalas, 'opening_on', p_on), v_reason);
  perform fn_add_review_item(a.branch_id, 'account_opening_set', 'cash_account', a.id, null, 'تحديد الرصيد الافتتاحي لـ' || a.name, v_reason,
                             jsonb_build_object('before', a.opening_balance_halalas, 'after', p_halalas, 'opening_on', p_on));
  -- Include the opening date and posted movements, using the same balance as the cash floor.
  -- The account row lock above serializes repeated opening changes for this box.
  if a.kind = 'cash_box' then
    v_balance := fn_cash_account_balance(a.id);
    if v_balance < 0 then
      perform fn_phase4_flag(a.branch_id, 'negative_cash_box', 'cash_account', a.id, null,
        'الصندوق ' || a.name || ' نزل تحت الصفر: ' || fn_sar_text(v_balance), v_reason,
        jsonb_build_object('account_id', a.id, 'balance_halalas', v_balance,
                           'opening_balance_halalas', p_halalas, 'opening_on', p_on, 'by_opening_set', true));
    end if;
  end if;
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_admin_upsert_bank_rule(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r bank_parse_rules%rowtype; before jsonb; kw text := btrim(coalesce(p->>'keyword', ''));
begin
  perform fn_require_cap('bank.manage');
  if not fn_can_write('bank.manage', case when (p->>'id') is null then 'add' else 'edit' end) then raise exception 'FORBIDDEN: bank.manage write' using errcode = '42501'; end if;
  if char_length(kw) not between 2 and 60 then raise exception 'VALIDATION: keyword'; end if;
  if coalesce(p->>'kind', '') not in ('deposit', 'transfer_in', 'pos_settlement', 'other_in', 'transfer_out', 'withdrawal', 'fee', 'pos_fee', 'purchase', 'other_out') then raise exception 'VALIDATION: kind'; end if;
  if coalesce(p->>'priority', '') !~ '^[0-9]{1,4}$' then raise exception 'VALIDATION: priority'; end if;
  if (p->>'id') is null then
    if exists (select 1 from bank_parse_rules where organization_id = fn_user_org_id() and lower(keyword) = lower(kw)) then raise exception 'DUPLICATE_NAME'; end if;
    insert into bank_parse_rules(organization_id, keyword, kind, direction, priority)
    values (fn_user_org_id(), kw, p->>'kind', case when p->>'kind' in ('deposit', 'transfer_in', 'pos_settlement', 'other_in') then 'in' else 'out' end, (p->>'priority')::int)
    returning * into r;
    perform fn_audit_change(null, 'bank_rule.created', 'bank_rule', r.id, null, to_jsonb(r));
  else
    select * into r from bank_parse_rules where id = (p->>'id')::uuid and organization_id = fn_user_org_id() for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    perform fn_check_version_strict(r.version, (p->>'version')::int);
    if exists (select 1 from bank_parse_rules where organization_id = r.organization_id and lower(keyword) = lower(kw) and id <> r.id) then raise exception 'DUPLICATE_NAME'; end if;
    before := to_jsonb(r);
    update bank_parse_rules set keyword = kw, kind = p->>'kind', direction = case when p->>'kind' in ('deposit', 'transfer_in', 'pos_settlement', 'other_in') then 'in' else 'out' end,
           priority = (p->>'priority')::int, is_active = coalesce((p->>'is_active')::boolean, is_active), version = version + 1, updated_at = now()
     where id = r.id returning * into r;
    perform fn_audit_change(null, 'bank_rule.updated', 'bank_rule', r.id, before, to_jsonb(r));
  end if;
  return jsonb_build_object('ok', true, 'id', r.id, 'version', r.version);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_admin_upsert_cash_account(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a cash_accounts%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; before jsonb;
        v_kind text := p->>'kind'; v_name text := trim(coalesce(p->>'name', ''));
        v_last4 text := nullif(trim(coalesce(p->>'account_last4', '')), ''); v_bank text := nullif(trim(coalesce(p->>'bank_name', '')), '');
        v_prefix text := nullif(trim(fn_latin_digits(coalesce(p->>'account_prefix', ''))), ''); v_suffix text := nullif(trim(fn_latin_digits(coalesce(p->>'account_suffix', ''))), '');
        v_org uuid;
begin
  perform fn_require_cap('cash_accounts');
  if not fn_can_write('cash_accounts', case when v_id is null then 'add' else 'edit' end) then raise exception 'FORBIDDEN: cash_accounts write' using errcode = '42501'; end if;
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
end $function$;

CREATE OR REPLACE FUNCTION public.fn_bank_assign_account(p_movement uuid, p_account uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v bank_movements%rowtype; a cash_accounts%rowtype; v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  perform fn_require_cap('bank.manage');
  if not fn_can_write('bank.manage', 'edit') then raise exception 'FORBIDDEN: bank.manage write' using errcode = '42501'; end if;
  select * into v from bank_movements where id = p_movement and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v.cash_account_id is not null then raise exception 'VALIDATION: movement_assigned'; end if;
  if v_reason is null or char_length(v_reason) > 300 then raise exception 'VALIDATION: reason'; end if;
  select * into a from cash_accounts where id = p_account and organization_id = v.organization_id and kind = 'bank_account' and archived_at is null;
  if not found then raise exception 'VALIDATION: account'; end if;
  perform fn_require_branch(a.branch_id);
  update bank_movements set cash_account_id = a.id, branch_id = a.branch_id where id = v.id;
  perform fn_audit_change(a.branch_id, 'bank_movement.assigned', 'bank_movement', v.id, null, jsonb_build_object('account', a.name, 'amount_halalas', v.amount_halalas), v_reason);
  return jsonb_build_object('ok', true, 'branch_id', a.branch_id);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_bank_match(p_movement uuid, p_targets jsonb, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v bank_movements%rowtype; t jsonb; r record; net bigint := 0; diff bigint; n int := 0; first_no text;
        v_reason text := nullif(btrim(coalesce(p_reason, '')), ''); acc uuid; m uuid := gen_random_uuid(); d date;
begin
  perform fn_require_cap('bank.manage');
  if not fn_can_write('bank.manage', 'edit') then raise exception 'FORBIDDEN: bank.manage write' using errcode = '42501'; end if;
  select * into v from bank_movements where id = p_movement and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v.status <> 'pending' then raise exception 'VALIDATION: movement_used'; end if;
  if v.cash_account_id is null then raise exception 'VALIDATION: movement_unassigned'; end if;
  perform fn_require_branch(v.branch_id);
  if p_targets is null or jsonb_typeof(p_targets) <> 'array' or jsonb_array_length(p_targets) not between 1 and 200 then raise exception 'VALIDATION: targets'; end if;
  if exists (select 1 from jsonb_array_elements(p_targets) e where jsonb_typeof(e) <> 'object' or coalesce(e->>'type', '') not in ('voucher', 'expense', 'platform_payout')) then
    raise exception 'VALIDATION: target_type';
  end if;
  if exists (select 1 from jsonb_array_elements(p_targets) e where coalesce(e->>'id', '') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') then
    raise exception 'VALIDATION: target';
  end if;
  if v_reason is not null and char_length(v_reason) > 300 then raise exception 'VALIDATION: reason'; end if;
  insert into bank_matches(id, organization_id, movement_id, kind, reason, created_by) values (m, v.organization_id, v.id, 'link', v_reason, fn_staff_id());
  -- every record in one order (type, id), so two matches never wait on each other
  for r in select distinct e->>'type' as type, (e->>'id')::uuid as id from jsonb_array_elements(p_targets) e order by 1, 2 loop
    -- the record is held while it is matched: a cancellation waits, then sees the match (and lets it go)
    if r.type = 'voucher' then perform 1 from financial_vouchers where id = r.id for share;
    elsif r.type = 'expense' then perform 1 from expense_vouchers where id = r.id for share;
    else perform 1 from platform_payouts where id = r.id for share;
    end if;
    perform pg_advisory_xact_lock(hashtext('bank_target:' || r.type || ':' || r.id::text));
    t := fn_bank_target(v.id, r.type, r.id);
    if t is null then raise exception 'VALIDATION: target'; end if;
    if exists (select 1 from bank_match_items where active and target_type = r.type and target_id = r.id) then raise exception 'VALIDATION: target_used'; end if;
    insert into bank_match_items(organization_id, match_id, target_type, target_id, amount_halalas)
    values (v.organization_id, m, r.type, r.id, (t->>'signed_halalas')::bigint);
    net := net + (t->>'signed_halalas')::bigint; n := n + 1; first_no := coalesce(first_no, t->>'number');
  end loop;
  if net <= 0 then raise exception 'VALIDATION: target_total'; end if;
  diff := v.amount_halalas - net;
  if diff <> 0 and v_reason is null then raise exception 'VALIDATION: difference_reason'; end if;
  update bank_matches set difference_halalas = diff where id = m;
  update bank_movements set status = 'matched' where id = v.id;
  if diff <> 0 then
    acc := fn_gl_for_cash(v.cash_account_id); d := fn_bank_entry_date(v.id);
    -- the bank moved diff more (+) or less (−) than the records booked: the bank account takes the difference
    perform fn_gl_post(v.organization_id, v.branch_id, d, 'bank_movement', v.id, 'diff:' || m::text,
                       'فرق مطابقة ' || first_no || case when n > 1 then ' وسجلات أخرى' else '' end || ': ' || v_reason,
                       case when (v.direction = 'in') = (diff > 0) then
                         jsonb_build_array(jsonb_build_object('account_id', acc, 'debit', abs(diff)), jsonb_build_object('account_id', fn_gl_system(v.organization_id, 'other_income'), 'credit', abs(diff)))
                       else
                         jsonb_build_array(jsonb_build_object('account_id', fn_gl_system(v.organization_id, 'bank_fees'), 'debit', abs(diff)), jsonb_build_object('account_id', acc, 'credit', abs(diff))) end);
  end if;
  perform fn_audit_change(v.branch_id, 'bank_movement.matched', 'bank_movement', v.id, null,
                          jsonb_build_object('first', first_no, 'records', n, 'amount_halalas', v.amount_halalas, 'difference_halalas', diff), v_reason);
  return jsonb_build_object('ok', true, 'match_id', m, 'records', n, 'difference_halalas', diff);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_bank_reparse(p_message uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare m bank_messages%rowtype; r jsonb;
begin
  perform fn_require_cap('bank.manage');
  if not fn_can_write('bank.manage', 'edit') then raise exception 'FORBIDDEN: bank.manage write' using errcode = '42501'; end if;
  select * into m from bank_messages where id = p_message and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if m.status not in ('unparsed', 'rejected') then raise exception 'VALIDATION: message_status'; end if;
  r := fn_bank_process(m.id);
  perform fn_audit_change(null, 'bank_message.reparsed', 'bank_message', m.id, jsonb_build_object('status', m.status), r);
  return jsonb_build_object('ok', true) || r;
end $function$;

CREATE OR REPLACE FUNCTION public.fn_bank_unmatch(p_movement uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v bank_movements%rowtype; m bank_matches%rowtype; v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  perform fn_require_cap('bank.manage');
  if not fn_can_write('bank.manage', 'edit') then raise exception 'FORBIDDEN: bank.manage write' using errcode = '42501'; end if;
  select * into v from bank_movements where id = p_movement and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v.branch_id is not null then perform fn_require_branch(v.branch_id); end if;
  if v_reason is null or char_length(v_reason) > 300 then raise exception 'VALIDATION: reason'; end if;
  select * into m from bank_matches where movement_id = v.id and active;
  if not found then raise exception 'VALIDATION: movement_not_matched'; end if;
  -- an expense made from the movement is undone by cancelling that expense (with its reason), which releases it
  if m.kind = 'convert' and exists (select 1 from bank_match_items where match_id = m.id and target_type = 'expense') then raise exception 'VALIDATION: cancel_the_expense'; end if;
  perform fn_bank_release(m.id, v_reason);
  perform fn_audit_change(v.branch_id, 'bank_movement.unmatched', 'bank_movement', v.id, jsonb_build_object('kind', m.kind, 'difference_halalas', m.difference_halalas), null, v_reason);
  return jsonb_build_object('ok', true);
end $function$;

commit;
