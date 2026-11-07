-- 0059 — owner review Phase 4a (31 Oct review, owner's decisions): the money the owner reads.
--   OWNER-02  money the platforms still owe is not «collected»: receipts recorded «آجل عبر المنصة» (ota_deferred) or
--             «منصة الحجز» (booking_platform) are reported apart, as platform money, everywhere a figure says collected
--             (the reports' net, the per-staff table, the daily chart, the owner's «المحصّل اليوم»).
--   OWNER-04  «المحصّل اليوم» = cash, POS and transfer receipts of the day (the platform's apart), net of refunds; the
--             summary also returns the platform money of the day, so the two are reconciled on screen.
--   OWNER-03  the summary returns both occupancy figures: of the working units (the definition used everywhere) and of
--             every unit (the inactive ones counted), each named on screen.
--   OWNER-07  the collection rate is computed on what the period's stays owe: everything paid at the property for those
--             stays (whatever the voucher's date) ÷ their charges, capped at 100%, the raw figure kept to explain >100%.
--   OWNER-08  one period limit (366 days, «period_too_long»), and an end after today is read up to today.
--   OWNER-10  the daily series has every calendar day of the period, 0 on a day with no money.
-- Same signatures as before: replaced in place.

create or replace function fn_ops_daily_summary_core(p_branch uuid, p_date date) returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select case when p_branch in (select fn_user_branch_ids()) then jsonb_build_object(
    'date', p_date,
    'units', jsonb_build_object(
      'active', (select count(*) from rooms where branch_id = p_branch and is_active and archived_at is null),
      'all', (select count(*) from rooms where branch_id = p_branch and archived_at is null),
      'occupied', (select count(*) from rooms where branch_id = p_branch and status = 'occupied'),
      'reserved', (select count(*) from rooms where branch_id = p_branch and status = 'reserved'),
      'ready', (select count(*) from rooms where branch_id = p_branch and status = 'ready'),
      'dirty', (select count(*) from rooms where branch_id = p_branch and is_active and cleanliness <> 'clean'),
      'maintenance', (select count(*) from rooms where branch_id = p_branch and status = 'maintenance'),
      'out_of_service', (select count(*) from rooms where branch_id = p_branch and (status = 'out_of_service' or not is_active))),
    'occupancy_pct', (select case when count(*) filter (where is_active and archived_at is null) = 0 then 0
                        else round(100.0 * count(*) filter (where status = 'occupied') / count(*) filter (where is_active and archived_at is null), 1) end from rooms where branch_id = p_branch),
    -- OWNER-03: the same occupied units over every unit that is not archived (the inactive ones included)
    'occupancy_all_pct', (select case when count(*) filter (where archived_at is null) = 0 then 0
                        else round(100.0 * count(*) filter (where status = 'occupied') / count(*) filter (where archived_at is null), 1) end from rooms where branch_id = p_branch),
    'arrivals', jsonb_build_object(
      'expected', (select count(*) from reservations where branch_id = p_branch and check_in = p_date and status in ('confirmed','pending_verification')),
      'arrived', (select count(*) from reservations where branch_id = p_branch and check_in = p_date and status = 'checked_in'),
      'pending_identity', (select count(*) from reservations where branch_id = p_branch and check_in <= p_date and check_out > p_date and status in ('confirmed','pending_verification') and identity_status <> 'verified'),
      'unpaid', (select count(*) from reservations where branch_id = p_branch and check_in = p_date and status in ('confirmed','pending_verification') and balance_due_halalas > 0),
      'overdue', (select count(*) from reservations where branch_id = p_branch and check_in < p_date and status in ('confirmed','pending_verification'))),
    'departures', jsonb_build_object(
      'expected', (select count(*) from reservations where branch_id = p_branch and check_out = p_date and status = 'checked_in'),
      'done', (select count(*) from reservations where branch_id = p_branch and check_out = p_date and status in ('checked_out', 'closed')),
      'overstay', (select count(*) from reservations where branch_id = p_branch and check_out < p_date and status = 'checked_in'),
      'with_balance', (select count(*) from reservations where branch_id = p_branch and check_out = p_date and status = 'checked_in' and balance_due_halalas > 0)),
    'housekeeping', jsonb_build_object(
      'open', (select count(*) from housekeeping_tasks where branch_id = p_branch and status = 'pending'),
      'in_progress', (select count(*) from housekeeping_tasks where branch_id = p_branch and status = 'in_progress'),
      'completed_today', (select count(*) from housekeeping_tasks where branch_id = p_branch and status = 'completed' and completed_at >= d.day_start and completed_at < d.day_end),
      'unassigned', (select count(*) from housekeeping_tasks where branch_id = p_branch and status = 'pending' and assignee_id is null)),
    'finance', jsonb_build_object(
      -- OWNER-02 / OWNER-04: collected at the property (cash, POS, transfer); what a platform holds is reported apart
      'received_today', (select coalesce(sum(amount_halalas),0) from financial_vouchers where branch_id = p_branch and kind = 'receipt' and status = 'approved' and method::text not in ('ota_deferred','booking_platform') and occurred_at >= d.day_start and occurred_at < d.day_end),
      'refunded_today', (select coalesce(sum(amount_halalas),0) from financial_vouchers where branch_id = p_branch and kind = 'refund' and status = 'approved' and method::text not in ('ota_deferred','booking_platform') and occurred_at >= d.day_start and occurred_at < d.day_end),
      'platform_today', (select coalesce(sum(case when kind = 'refund' then -amount_halalas else amount_halalas end),0) from financial_vouchers where branch_id = p_branch and kind in ('receipt','refund') and status = 'approved' and method::text in ('ota_deferred','booking_platform') and occurred_at >= d.day_start and occurred_at < d.day_end),
      'deposits_held', (select coalesce(sum(deposit_balance_halalas),0) from reservations where branch_id = p_branch and status in ('confirmed','checked_in','checked_out')),
      'outstanding_in_house', (select coalesce(sum(balance_due_halalas),0) from reservations where branch_id = p_branch and status = 'checked_in'),
      'deposit_to_settle_after_checkout', (select coalesce(sum(deposit_balance_halalas),0) from reservations where branch_id = p_branch and status = 'checked_out' and deposit_balance_halalas > 0)),
    'tickets_open', (select count(*) from human_handoff_tickets where branch_id = p_branch and status = 'open'),
    'generated_at', now()
  ) else null end
  from (select p_date::timestamp at time zone z.tz as day_start, (p_date + 1)::timestamp at time zone z.tz as day_end
        from (select coalesce((select timezone from branches where id = p_branch), 'Asia/Riyadh') as tz) z) d;
$$;
revoke all on function fn_ops_daily_summary_core(uuid, date) from public, anon, authenticated;

create or replace function fn_reports_finance(p_branch uuid, p_from date, p_to date, p_filters jsonb)
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_from date; v_to date; tz text; f jsonb := coalesce(p_filters, '{}'::jsonb); v_staff uuid; v_method text; v_account text; v_acc uuid; v_acc_none boolean; v_source uuid; v_cat uuid;
        l record; c record; rs record; cl record; open_dep bigint; total_charged bigint; net bigint; v_filtered boolean; v_today date; v_raw numeric;
begin
  perform fn_require_cap_full('reports.finance');
  perform fn_require_branch(p_branch);
  select coalesce(timezone, 'Asia/Riyadh') into tz from branches where id = p_branch;
  v_today := fn_branch_today(p_branch);
  v_from := coalesce(p_from, v_today - 29);
  v_to   := coalesce(p_to, v_today);
  if v_to < v_from then raise exception 'VALIDATION: period'; end if;
  -- OWNER-08: one limit for the whole page; an end after today is read up to today (nothing has happened after it)
  if v_to - v_from > 366 then raise exception 'VALIDATION: period_too_long'; end if;
  v_to := least(v_to, v_today);
  if v_from > v_to then raise exception 'VALIDATION: period_future'; end if;
  v_staff := (f->>'staff_id')::uuid; v_method := nullif(f->>'method', ''); v_account := nullif(f->>'account_id', ''); v_source := (f->>'source_id')::uuid; v_cat := (f->>'category_id')::uuid;
  v_filtered := v_staff is not null or v_method is not null or v_account is not null or v_source is not null or v_cat is not null;
  v_acc_none := v_account = 'none'; v_acc := case when v_account is not null and v_account <> 'none' then v_account::uuid end;

  with fv as (
    select v.*, (v.method::text in ('ota_deferred','booking_platform')) as platform from financial_vouchers v
    where v.branch_id = p_branch and v.status = 'approved' and (v.occurred_at at time zone tz)::date between v_from and v_to
      and (v_staff is null or v.created_by = v_staff)
      and (v_method is null or v.method::text = v_method)
      and (v_account is null or (v_acc_none and v.account_id is null) or v.account_id = v_acc)
      and (v_source is null or exists (select 1 from reservations r where r.id = v.reservation_id and r.source_id = v_source))
      and (v_cat is null or exists (select 1 from reservations r where r.id = v.reservation_id and r.room_category_id = v_cat)))
  select coalesce(sum(amount_halalas) filter (where kind = 'receipt' and not platform), 0)::bigint as receipts,
         coalesce(sum(amount_halalas) filter (where kind = 'refund' and not platform), 0)::bigint  as refunds,
         coalesce(sum(amount_halalas) filter (where kind = 'receipt' and platform), 0)::bigint     as platform_receipts,
         coalesce(sum(amount_halalas) filter (where kind = 'refund' and platform), 0)::bigint      as platform_refunds,
         coalesce(sum(amount_halalas) filter (where kind = 'deposit'), 0)::bigint        as deposits_received,
         coalesce(sum(amount_halalas) filter (where kind = 'deposit_refund'), 0)::bigint as deposits_refunded,
         coalesce(sum(amount_halalas) filter (where kind = 'deposit_apply'), 0)::bigint  as deposits_applied,
         coalesce((select jsonb_agg(jsonb_build_object('method', method, 'amount_halalas', amount, 'platform', pl) order by amount desc, method)
                   from (select method::text as method, bool_or(platform) as pl, sum(amount_halalas)::bigint as amount from fv where kind = 'receipt' group by method) m), '[]'::jsonb) as by_method,
         -- OWNER-10: every calendar day of the period, 0 when nothing moved; the platform's money in its own series
         (select jsonb_agg(jsonb_build_object('day', g.day, 'receipts', coalesce(x.receipts, 0), 'refunds', coalesce(x.refunds, 0), 'platform', coalesce(x.platform, 0)) order by g.day)
            from (select gs::date as day from generate_series(v_from, v_to, interval '1 day') gs) g
            left join (select (occurred_at at time zone tz)::date as day,
                              coalesce(sum(amount_halalas) filter (where (kind = 'receipt' and not platform) or kind = 'deposit_apply'), 0)::bigint as receipts,
                              coalesce(sum(amount_halalas) filter (where kind = 'refund' and not platform), 0)::bigint as refunds,
                              coalesce(sum(case when kind = 'refund' then -amount_halalas else amount_halalas end) filter (where kind in ('receipt','refund') and platform), 0)::bigint as platform
                         from fv group by 1) x on x.day = g.day) as by_day,
         -- OWNER-02: a member of staff is credited with the money handled at the property only
         coalesce((select jsonb_agg(jsonb_build_object('staff_id', sid, 'staff', coalesce((select full_name from staff_profiles where id = sid), '—'), 'receipts', rc, 'refunds', rf, 'count', n) order by rc desc)
                   from (select created_by sid, coalesce(sum(amount_halalas) filter (where kind = 'receipt'), 0)::bigint rc, coalesce(sum(amount_halalas) filter (where kind = 'refund'), 0)::bigint rf, count(*) n
                         from fv where kind in ('receipt', 'refund') and not platform group by created_by) s), '[]'::jsonb) as by_staff,
         coalesce((select jsonb_agg(jsonb_build_object('account_id', acc, 'account', coalesce((select name from cash_accounts where id = acc), '—'), 'in_halalas', i, 'out_halalas', o) order by i desc)
                   from (select account_id acc, coalesce(sum(amount_halalas) filter (where kind in ('receipt','deposit')), 0)::bigint i, coalesce(sum(amount_halalas) filter (where kind in ('refund','deposit_refund')), 0)::bigint o
                         from fv where account_id is not null group by account_id) a), '[]'::jsonb) as by_account
    into l from fv;
  net := l.receipts - l.refunds + l.deposits_applied;

  select coalesce(sum(total_halalas) filter (where kind = 'rent'), 0)::bigint as rent,
         coalesce(sum(total_halalas) filter (where kind in ('addon','penalty','adjustment')), 0)::bigint as addons,
         coalesce(sum(total_halalas) filter (where kind = 'discount'), 0)::bigint as discounts,
         coalesce(sum(total_halalas) filter (where kind = 'tax'), 0)::bigint as tax
    into c
    from reservation_charges ch
    where ch.branch_id = p_branch and ch.reservation_id in (
      select r.id from reservations r where r.branch_id = p_branch and r.check_in <= v_to and r.check_out > v_from and r.status not in ('cancelled','rejected','no_show')
        and (v_source is null or r.source_id = v_source) and (v_cat is null or r.room_category_id = v_cat));
  total_charged := c.rent + c.addons + c.discounts + c.tax;

  -- OWNER-07: what the same stays have paid, whatever the voucher's date (the platform's apart)
  select coalesce(sum(case when v.kind = 'refund' then -v.amount_halalas else v.amount_halalas end) filter (where v.kind in ('receipt','refund','deposit_apply') and v.method::text not in ('ota_deferred','booking_platform')), 0)::bigint as paid,
         coalesce(sum(case when v.kind = 'refund' then -v.amount_halalas else v.amount_halalas end) filter (where v.kind in ('receipt','refund') and v.method::text in ('ota_deferred','booking_platform')), 0)::bigint as platform
    into cl
    from financial_vouchers v
    where v.branch_id = p_branch and v.status = 'approved' and v.reservation_id in (
      select r.id from reservations r where r.branch_id = p_branch and r.check_in <= v_to and r.check_out > v_from and r.status not in ('cancelled','rejected','no_show')
        and (v_source is null or r.source_id = v_source) and (v_cat is null or r.room_category_id = v_cat));
  v_raw := case when total_charged > 0 then round(cl.paid::numeric * 100 / total_charged, 1) end;

  select count(*)::bigint as cnt,
         coalesce(sum(greatest(check_out - check_in, 0)) filter (where status not in ('cancelled','rejected','no_show')), 0)::bigint as nights,
         count(*) filter (where status = 'cancelled') as cancelled,
         count(*) filter (where status = 'no_show') as no_show
    into rs
    from reservations r where r.branch_id = p_branch and r.check_in <= v_to and r.check_out > v_from
      and (v_source is null or r.source_id = v_source) and (v_cat is null or r.room_category_id = v_cat);

  select coalesce(sum(greatest(deposit_balance_halalas, 0)), 0)::bigint into open_dep from reservations where branch_id = p_branch;

  return jsonb_build_object(
    'period', jsonb_build_object('from', v_from, 'to', v_to, 'requested_to', coalesce(p_to, v_to)),
    'filters', jsonb_strip_nulls(jsonb_build_object('staff_id', v_staff, 'method', v_method, 'account_id', v_account, 'source_id', v_source, 'category_id', v_cat)),
    'filtered', v_filtered,
    'ledger', jsonb_build_object('receipts', l.receipts, 'refunds', l.refunds, 'net_collected', net,
                                 'platform_receipts', l.platform_receipts, 'platform_refunds', l.platform_refunds, 'platform_net', l.platform_receipts - l.platform_refunds,
                                 'deposits_received', l.deposits_received, 'deposits_refunded', l.deposits_refunded, 'deposits_applied', l.deposits_applied,
                                 'deposit_balance_open', open_dep),
    'charges', jsonb_build_object('total_charged', total_charged, 'rent', c.rent, 'addons', c.addons, 'discounts', c.discounts, 'tax', c.tax),
    'collection', case when total_charged > 0 and v_staff is null and v_method is null and v_account is null then
                    jsonb_build_object('due', total_charged, 'paid', cl.paid, 'platform', cl.platform, 'rate_pct', least(v_raw, 100), 'raw_pct', v_raw) end,
    'collection_rate_pct', case when total_charged > 0 and v_staff is null and v_method is null and v_account is null then least(v_raw, 100) end,
    'by_method', l.by_method, 'by_day', coalesce(l.by_day, '[]'::jsonb), 'by_staff', l.by_staff, 'by_account', l.by_account,
    'reservations', jsonb_build_object('count', rs.cnt, 'nights', rs.nights, 'cancelled', rs.cancelled, 'no_show', rs.no_show,
      'by_source', (select coalesce(jsonb_agg(jsonb_build_object('source_id', source_id, 'source', source, 'count', cnt, 'total_halalas', total) order by cnt desc, source), '[]'::jsonb)
                    from (select r.source_id, coalesce(bs.name, '—') as source, count(*)::bigint as cnt, coalesce(sum(r.total_halalas), 0)::bigint as total
                          from reservations r left join booking_sources bs on bs.id = r.source_id
                          where r.branch_id = p_branch and r.check_in <= v_to and r.check_out > v_from
                            and (v_source is null or r.source_id = v_source) and (v_cat is null or r.room_category_id = v_cat)
                          group by r.source_id, coalesce(bs.name, '—')) s)),
    'definitions', jsonb_build_object(
      'revenue', 'المحصّل في المنشأة = سندات قبض الإقامة نقدًا أو شبكة أو تحويلًا − الاستردادات + التأمين المستخدم لتغطية رسوم، بتاريخ السند. ما سُجّل «آجل عبر المنصة» يظهر منفصلًا حتى تحوّله المنصة. التأمين المقبوض ليس إيرادًا.',
      'platform', 'آجل عند المنصات = ما سُجّل للفترة بطريقة «آجل عبر المنصة»؛ المنصة تحصّله وتحوّله لاحقًا (تُطابق في «مطابقة المنصات»).',
      'collection_rate', 'نسبة التحصيل = ما دُفع في المنشأة لإقامات الفترة (أيًّا كان تاريخ السند) ÷ رسومها (إيجار + إضافات − خصومات + ضريبة)، بحد أقصى 100%؛ ما فوق 100% دفعٌ زائد يُرد أو يُسوّى. ما عند المنصات خارجها. لا تُحسب مع مرشح الموظف أو الطريقة أو الحساب.')
  );
end $function$;
