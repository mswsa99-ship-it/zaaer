-- 0148 POS settlement overview over a period (read only, additive). The settlement itself stays ONE day:
-- fn_pos_settle and fn_pos_settlement_preview are untouched. This function only lists, for each branch day from p_from to p_to
-- (both included), what the system recorded for ONE bank account and whether that day has a saved settlement.
-- Same checks as fn_pos_settlement_preview: capability pos.settle, branch membership, the account belongs to the branch and is a bank account.
-- No cap on the number of days. A day is the branch's own day (branch timezone), as in fn_pos_day_total.
create or replace function public.fn_pos_settlement_range(p_branch uuid, p_account uuid, p_from date, p_to date)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare a cash_accounts%rowtype; v jsonb;
begin
  perform fn_require_cap('pos.settle');
  perform fn_require_branch(p_branch);
  if p_from is null or p_to is null then raise exception 'VALIDATION: business_date'; end if;
  if p_from > p_to then raise exception 'VALIDATION: date_range'; end if;
  select * into a from cash_accounts where id = p_account and branch_id = p_branch and kind = 'bank_account';
  if not found then raise exception 'BRANCH_MISMATCH: account'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'business_date', d.day,
           'system_total_halalas', (t.j->>'system_total_halalas')::bigint,
           'voucher_count', (t.j->>'voucher_count')::int,
           'settlement', case when s.id is null then null else jsonb_build_object('status', s.status, 'terminal_total_halalas', s.terminal_total_halalas,
                                                                                  'difference_halalas', s.difference_halalas, 'version', s.version) end)
         order by d.day), '[]'::jsonb) into v
  from generate_series(p_from, p_to, interval '1 day') g(day0)
  cross join lateral (select g.day0::date as day) d
  cross join lateral (select fn_pos_day_total(p_branch, p_account, d.day) as j) t
  left join pos_settlements s on s.account_id = p_account and s.business_date = d.day;
  return jsonb_build_object('from', p_from, 'to', p_to, 'days', v);
end $function$;
revoke all on function public.fn_pos_settlement_range(uuid, uuid, date, date) from public, anon;
grant execute on function public.fn_pos_settlement_range(uuid, uuid, date, date) to authenticated;
