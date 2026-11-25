-- 0105: imported opening balances use the existing anomaly review + manager alert mechanism.
-- Preserve owner/capability/branch validation and the ordinary opening audit/review.

create or replace function fn_admin_set_account_opening(p_account uuid, p_halalas bigint, p_on date, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a cash_accounts%rowtype; v_balance bigint; v_reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  perform fn_require_cap('cash_accounts');
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
end $$;
revoke all on function fn_admin_set_account_opening(uuid, bigint, date, text) from public, anon;
grant execute on function fn_admin_set_account_opening(uuid, bigint, date, text) to authenticated;
