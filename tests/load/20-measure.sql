-- =====================================================================
-- Load measurement (item 2.10): warmup + repeated timed calls of the main
-- read functions under real session contexts (staff JWT claims of the
-- hotel's owner, exactly as the app sets them per request).
--   psql -d $DB -v round=before -f tests/load/20-measure.sql
-- Results land in table load_results (kept in the test database only).
-- =====================================================================
\set ON_ERROR_STOP on
select set_config('load.round', :'round', false);

create table if not exists load_results(
  round text, context text, fn text, variant text, iter int, ms numeric,
  measured_at timestamptz default now());

-- measurement contexts: five branches in five different hotels, the owner
-- account of each hotel (sees money, every branch of the hotel)
create table if not exists load_contexts as
with picked as (
  select 1 as ctx, 1 as h, 7 as b union all select 2, 27, 7 union all select 3, 50, 7
)
select 'ctx'||ctx as context,
       md5('org:'||h)::uuid as org_id,
       md5('branch:'||h||':'||b)::uuid as branch_id,
       md5('acc:'||h||':'||b||':cash')::uuid as account_id,
       md5('auth:'||h||':owner')::uuid as auth_uid,
       md5('staff:'||h||':owner')::uuid as staff_id
from picked;

-- harness: run p_sql 2 times as warmup, then 15 measured times, under the
-- session context (JWT claims) of the context's staff account
create or replace function load_call(p_context text, p_fn text, p_variant text, p_auth uuid, p_sql text)
returns void language plpgsql as $harness$
declare
  i int;
  t0 timestamptz;
begin
  for i in 1..17 loop
    perform set_config('request.jwt.claim.sub', p_auth::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub', p_auth)::text, true);
    t0 := clock_timestamp();
    execute p_sql;
    -- first 2 calls are the warmup: executed but not recorded
    if i > 2 then
      insert into load_results(round, context, fn, variant, iter, ms)
      values (current_setting('load.round'), p_context, p_fn, p_variant, i - 2,
              extract(epoch from clock_timestamp() - t0) * 1000);
    end if;
  end loop;
end
$harness$;

do $$
declare
  c record;
begin
  for c in select * from load_contexts order by context loop
    -- occupancy
    perform load_call(c.context, 'fn_ops_daily_summary', 'today', c.auth_uid,
      format('select fn_ops_daily_summary(%L, current_date)', c.branch_id));
    perform load_call(c.context, 'fn_reservation_calendar', 'month_around_today', c.auth_uid,
      format('select fn_reservation_calendar(%L, current_date - 7, current_date + 21)', c.branch_id));
    perform load_call(c.context, 'fn_ops_units_board', 'branch', c.auth_uid,
      format('select fn_ops_units_board(%L)', c.branch_id));
    -- booking lists
    perform load_call(c.context, 'fn_reservation_list', 'default_page', c.auth_uid,
      format('select fn_reservation_list(%L, ''{}''::jsonb, 50, 0)', c.branch_id));
    perform load_call(c.context, 'fn_reservation_list', 'date_range_sorted', c.auth_uid,
      format('select fn_reservation_list(%L, jsonb_build_object(''check_in_from'', (current_date - 30)::text, ''check_in_to'', (current_date + 30)::text, ''sort'', ''check_in_asc''), 50, 0)', c.branch_id));
    -- arrival
    perform load_call(c.context, 'fn_reservation_list', 'in_house_today', c.auth_uid,
      format('select fn_reservation_list(%L, jsonb_build_object(''stay_on'', current_date::text), 50, 0)', c.branch_id));
    perform load_call(c.context, 'fn_platform_check_list', 'today', c.auth_uid,
      format('select fn_platform_check_list(%L, current_date)', c.branch_id));
    -- finance
    perform load_call(c.context, 'fn_reports_finance', 'last_30_days', c.auth_uid,
      format('select fn_reports_finance(%L, current_date - 29, current_date, ''{}''::jsonb)', c.branch_id));
    perform load_call(c.context, 'fn_reports_finance', 'full_year', c.auth_uid,
      format('select fn_reports_finance(%L, current_date - 364, current_date, ''{}''::jsonb)', c.branch_id));
    perform load_call(c.context, 'fn_account_ledger', 'last_30_days', c.auth_uid,
      format('select fn_account_ledger(%L, current_date - 29, current_date)', c.account_id));
  end loop;
end $$;

-- per-variant summary for this round
select round, fn, variant, count(*) as samples,
       round(percentile_cont(0.50) within group (order by ms)::numeric, 1) as p50_ms,
       round(percentile_cont(0.95) within group (order by ms)::numeric, 1) as p95_ms,
       round(max(ms), 1) as max_ms,
       case when percentile_cont(0.95) within group (order by ms) < 500 then 'PASS' else 'FAIL' end as criterion_p95_under_500ms
from load_results
where round = current_setting('load.round')
group by round, fn, variant
order by fn, variant;
