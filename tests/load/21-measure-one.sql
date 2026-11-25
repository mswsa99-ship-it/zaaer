-- Run one measurement cell (context x variant) and commit it.
--   psql -d $DB -v round=before -v ctx=ctx1 -v key=list_default -f tests/load/21-measure-one.sql
\set ON_ERROR_STOP on
select load_run_cell(:'round', :'ctx', :'key');
