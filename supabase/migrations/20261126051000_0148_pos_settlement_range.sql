-- 0148 POS settlement overview over a period (read only, additive). The settlement itself stays ONE day:
-- fn_pos_settle and fn_pos_settlement_preview are untouched. This function lists the branch days from p_from to p_to
-- (both included) that have something to show for ONE bank account: a day with POS vouchers, or a day with a saved settlement
-- (a saved settlement without vouchers is listed too). A day with neither has nothing to settle and is not listed, so the result
-- is sparse and its size follows the activity, not the number of days asked. A day with vouchers but no settlement IS listed
-- (settlement = null), so an unsettled day is never hidden.
-- One grouped query, no per-day voucher payload. Totals follow fn_pos_day_total exactly: approved vouchers on method 'pos' for this
-- account, deposit_apply excluded, receipt/deposit add and every other kind subtracts; the day is the branch's own day (branch timezone).
-- Same checks as fn_pos_settlement_preview: capability pos.settle, branch membership, the account is that branch's bank account.
-- No cap on the number of days asked.
create or replace function public.fn_pos_settlement_range(p_branch uuid, p_account uuid, p_from date, p_to date)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare a cash_accounts%rowtype; tz text; t0 timestamptz; t1 timestamptz; v jsonb;
begin
  perform fn_require_cap('pos.settle');
  perform fn_require_branch(p_branch);
  if p_from is null or p_to is null then raise exception 'VALIDATION: business_date'; end if;
  if p_from > p_to then raise exception 'VALIDATION: date_range'; end if;
  select * into a from cash_accounts where id = p_account and branch_id = p_branch and kind = 'bank_account';
  if not found then raise exception 'BRANCH_MISMATCH: account'; end if;
  tz := coalesce((select timezone from branches where id = p_branch), 'Asia/Riyadh');
  t0 := p_from::timestamp at time zone tz;
  t1 := (p_to + 1)::timestamp at time zone tz;
  select coalesce(jsonb_agg(jsonb_build_object(
           'business_date', x.day,
           'system_total_halalas', x.total,
           'voucher_count', x.n,
           'settlement', case when s.id is null then null else jsonb_build_object('status', s.status, 'terminal_total_halalas', s.terminal_total_halalas,
                                                                                  'difference_halalas', s.difference_halalas, 'version', s.version) end)
         order by x.day), '[]'::jsonb) into v
  from (
    select d.day, coalesce(g.total, 0) as total, coalesce(g.n, 0) as n
    from (
      select (fv.occurred_at at time zone tz)::date as day,
             sum(case when fv.kind in ('receipt', 'deposit') then fv.amount_halalas else -fv.amount_halalas end) as total, count(*) as n
      from financial_vouchers fv
      where fv.branch_id = p_branch and fv.account_id = p_account and fv.method = 'pos' and fv.status = 'approved'
        and fv.kind <> 'deposit_apply' and fv.occurred_at >= t0 and fv.occurred_at < t1
      group by 1
    ) g
    full join (select business_date as day from pos_settlements where account_id = p_account and business_date between p_from and p_to) ss on ss.day = g.day
    cross join lateral (select coalesce(g.day, ss.day) as day) d
  ) x
  left join pos_settlements s on s.account_id = p_account and s.business_date = x.day;
  return jsonb_build_object('from', p_from, 'to', p_to, 'days', v);
end $function$;
revoke all on function public.fn_pos_settlement_range(uuid, uuid, date, date) from public, anon;
grant execute on function public.fn_pos_settlement_range(uuid, uuid, date, date) to authenticated;
