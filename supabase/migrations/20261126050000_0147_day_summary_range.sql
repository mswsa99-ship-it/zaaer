-- 0147 Day summary over a period (UX: «ملخص اليوم للموظفين» takes one day OR from-to, inclusive of both ends, as agreed).
-- Read only, additive: a NEW function; fn_staff_day_summary (one day) is untouched. Same guards as the one-day function:
-- money role, branch membership, the page grant on /staff/day-summary, and the same scope (owner/manager/finance see everyone,
-- every other role sees only the vouchers it created). The period is bounded by the branch's own days: the start of p_from to
-- the end of p_to in the branch timezone. No cap on the number of days (the result is grouped by employee, kind and method).
create or replace function public.fn_staff_day_summary_range(p_branch uuid, p_from date, p_to date)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare tz text; ds timestamptz; de timestamptz; everyone boolean; v jsonb;
begin
  perform fn_require_money();
  perform fn_require_branch(p_branch);
  perform fn_require_user_page('/staff/day-summary', 'view');
  if p_from is null or p_to is null then raise exception 'VALIDATION: business_date'; end if;
  if p_from > p_to then raise exception 'VALIDATION: date_range'; end if;
  everyone := fn_has_role('owner','manager','finance');
  tz := coalesce((select timezone from branches where id = p_branch), 'Asia/Riyadh');
  ds := p_from::timestamp at time zone tz;
  de := (p_to + 1)::timestamp at time zone tz;
  select coalesce(jsonb_agg(jsonb_build_object('staff_id', t.staff_id, 'staff_name', t.staff_name, 'kind', t.kind, 'method', t.method,
                                              'count', t.n, 'total', t.total) order by t.staff_name, t.kind, t.method), '[]'::jsonb) into v
  from (select v2.created_by as staff_id, coalesce(s.full_name, '—') as staff_name, v2.kind, case when v2.kind = 'deposit_apply' then null else v2.method::text end as method,
               count(*) as n, sum(v2.amount_halalas) as total
        from financial_vouchers v2 left join staff_profiles s on s.id = v2.created_by
        where v2.branch_id = p_branch and v2.status = 'approved' and v2.occurred_at >= ds and v2.occurred_at < de
          and (everyone or v2.created_by = fn_staff_id())
        group by 1, 2, 3, 4) t;
  return jsonb_build_object('date', p_from, 'from', p_from, 'to', p_to, 'everyone', everyone, 'rows', v);
end $function$;
revoke all on function public.fn_staff_day_summary_range(uuid, date, date) from public, anon;
grant execute on function public.fn_staff_day_summary_range(uuid, date, date) to authenticated;
