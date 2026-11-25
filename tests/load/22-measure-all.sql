-- Run every measurement cell for a round (contexts x variants).
--   psql -d $DB -v round=before -f tests/load/22-measure-all.sql
\set ON_ERROR_STOP on
select load_run_cell(:'round', c.context, v.key)
from load_contexts c cross join load_variants v
order by c.context, v.key;
