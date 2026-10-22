-- Per-table row count + content hash (rows ordered by their text form): compares two environments' data.
-- One statement (works through SQL consoles that run a single query): xml helper evaluates each count/hash.
-- timestamptz values print in the session time zone, so both sides must use the same one: run
-- `set timezone = 'UTC';` first where the console allows it (hosted consoles default to UTC).
select c.relname as tbl,
       (xpath('/row/n/text()', query_to_xml(format('select count(*) as n from public.%I', c.relname), false, true, '')))[1]::text::bigint as n,
       (xpath('/row/h/text()', query_to_xml(format('select md5(coalesce(string_agg(x::text, ''|'' order by x::text), '''')) as h from public.%I x', c.relname), false, true, '')))[1]::text as hash
from pg_class c
where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
order by 1;
