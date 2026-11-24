-- Per-variant summary for one round: samples, p50, p95, max, criterion.
--   psql -d $DB -v round=before -f tests/load/23-measure-summary.sql
\set ON_ERROR_STOP on
select round, fn, variant, count(*) as samples,
       round(percentile_cont(0.50) within group (order by ms)::numeric, 1) as p50_ms,
       round(percentile_cont(0.95) within group (order by ms)::numeric, 1) as p95_ms,
       round(max(ms), 1) as max_ms,
       case when percentile_cont(0.95) within group (order by ms) < 500 then 'PASS' else 'FAIL' end as criterion_p95_under_500ms
from load_results
where round = :'round'
group by round, fn, variant
order by fn, variant;
