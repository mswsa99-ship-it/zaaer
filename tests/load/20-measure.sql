-- =====================================================================
-- Load measurement setup (item 2.10): contexts, variants, harness. Safe to
-- re-run. Then either:
--   * run everything:      psql -v round=before -f tests/load/22-measure-all.sql
--   * run one cell:        psql -v round=before -v ctx=ctx1 -v key=list_default -f tests/load/21-measure-one.sql
--   * summary:             psql -v round=before -f tests/load/23-measure-summary.sql
-- Each cell commits on its own, so an interrupted sweep keeps finished cells.
-- =====================================================================
\set ON_ERROR_STOP on

create table if not exists load_results(
  round text, context text, fn text, variant text, iter int, ms numeric,
  measured_at timestamptz default now());

-- measurement contexts: three branches in three different hotels, the owner
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

-- the measured workload: the main read functions the app calls, with
-- production-shaped arguments. %branch% / %account% are filled per context.
create table if not exists load_variants as
select * from (values
  ('summary_today',  'fn_ops_daily_summary',   'today',              'select fn_ops_daily_summary(%branch%, current_date)'),
  ('calendar_month', 'fn_reservation_calendar','month_around_today', 'select fn_reservation_calendar(%branch%, current_date - 7, current_date + 21)'),
  ('units_board',    'fn_ops_units_board',     'branch',             'select fn_ops_units_board(%branch%)'),
  ('list_default',   'fn_reservation_list',    'default_page',       'select fn_reservation_list(%branch%, ''{}''::jsonb, 50, 0)'),
  ('list_dates',     'fn_reservation_list',    'date_range_sorted',  'select fn_reservation_list(%branch%, jsonb_build_object(''check_in_from'', (current_date - 30)::text, ''check_in_to'', (current_date + 30)::text, ''sort'', ''check_in_asc''), 50, 0)'),
  ('list_inhouse',   'fn_reservation_list',    'in_house_today',     'select fn_reservation_list(%branch%, jsonb_build_object(''stay_on'', current_date::text), 50, 0)'),
  ('platform_today', 'fn_platform_check_list', 'today',              'select fn_platform_check_list(%branch%, current_date)'),
  ('finance_30d',    'fn_reports_finance',     'last_30_days',       'select fn_reports_finance(%branch%, current_date - 29, current_date, ''{}''::jsonb)'),
  ('finance_year',   'fn_reports_finance',     'full_year',          'select fn_reports_finance(%branch%, current_date - 364, current_date, ''{}''::jsonb)'),
  ('ledger_30d',     'fn_account_ledger',      'last_30_days',       'select fn_account_ledger(%account%, current_date - 29, current_date)')
) as v(key, fn, variant, sql_template);

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

-- one measurement cell: context x variant, one transaction
create or replace function load_run_cell(p_round text, p_ctx text, p_key text)
returns void language plpgsql as $cell$
declare c record; v record;
begin
  perform set_config('load.round', p_round, true);
  select * into c from load_contexts where context = p_ctx;
  select * into v from load_variants where key = p_key;
  if not found then raise exception 'unknown cell % %', p_ctx, p_key; end if;
  perform load_call(c.context, v.fn, v.variant, c.auth_uid,
                    replace(replace(v.sql_template, '%branch%', quote_literal(c.branch_id)),
                            '%account%', quote_literal(c.account_id)));
end
$cell$;
