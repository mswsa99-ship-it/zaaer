-- =====================================================================
-- Load evidence (item 2.10): EXPLAIN (ANALYZE, BUFFERS) of every measured
-- function under the first measurement context, for the report's plan
-- section. Runs after the measurement rounds, in the same database.
-- =====================================================================
\set ON_ERROR_STOP on

select set_config('request.jwt.claim.sub',
  (select auth_uid::text from load_contexts where context = 'ctx1'), false);
select set_config('request.jwt.claims',
  (select json_build_object('sub', auth_uid)::text from load_contexts where context = 'ctx1'), false);

\pset footer off
\echo ===== fn_ops_daily_summary (occupancy summary, today)
explain (analyze, buffers)
select fn_ops_daily_summary((select branch_id from load_contexts where context = 'ctx1'), current_date);

\echo ===== fn_reservation_calendar (occupancy calendar, 29 days)
explain (analyze, buffers)
select fn_reservation_calendar((select branch_id from load_contexts where context = 'ctx1'), current_date - 7, current_date + 21);

\echo ===== fn_ops_units_board (units board)
explain (analyze, buffers)
select fn_ops_units_board((select branch_id from load_contexts where context = 'ctx1'));

\echo ===== fn_reservation_list (default page)
explain (analyze, buffers)
select fn_reservation_list((select branch_id from load_contexts where context = 'ctx1'), '{}'::jsonb, 50, 0);

\echo ===== fn_reservation_list (date range, sorted)
explain (analyze, buffers)
select fn_reservation_list((select branch_id from load_contexts where context = 'ctx1'),
  jsonb_build_object('check_in_from', (current_date - 30)::text, 'check_in_to', (current_date + 30)::text, 'sort', 'check_in_asc'), 50, 0);

\echo ===== fn_reservation_list (in-house today, the arrival screen)
explain (analyze, buffers)
select fn_reservation_list((select branch_id from load_contexts where context = 'ctx1'),
  jsonb_build_object('stay_on', current_date::text), 50, 0);

\echo ===== fn_platform_check_list (platform arrivals, today)
explain (analyze, buffers)
select fn_platform_check_list((select branch_id from load_contexts where context = 'ctx1'), current_date);

\echo ===== fn_reports_finance (last 30 days)
explain (analyze, buffers)
select fn_reports_finance((select branch_id from load_contexts where context = 'ctx1'), current_date - 29, current_date, '{}'::jsonb);

\echo ===== fn_reports_finance (full year)
explain (analyze, buffers)
select fn_reports_finance((select branch_id from load_contexts where context = 'ctx1'), current_date - 364, current_date, '{}'::jsonb);

\echo ===== fn_account_ledger (last 30 days)
explain (analyze, buffers)
select fn_account_ledger((select account_id from load_contexts where context = 'ctx1'), current_date - 29, current_date);
