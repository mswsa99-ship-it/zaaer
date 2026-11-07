"""Build the restore script from the per-table exports.
Usage: python3 -I build_restore.py <backup dir>   (reads <dir>/tables/*.json and <dir>/source_manifest.json,
writes <dir>/zaaer-db-2026-11-07-0312.sql)"""
import json
import re
import sys
from pathlib import Path

base = Path(sys.argv[1])
manifest = json.loads((base / "source_manifest.json").read_text(encoding="utf-8"))
tables = [t["t"] for t in manifest["tables"]]
history = json.loads((base / "tables" / "schema_migrations.json").read_text(encoding="utf-8"))
versions = [h["version"] for h in history]
TAG = "$zbk$"

out = []
out.append("""-- =====================================================================================================
-- Zaaer — backup of the application data (schema public) of Supabase project ojcxkyyyhbbkqannemex
-- Taken 2026-11-07 03:12 UTC, after 0058, before the Phase 4a migration 0059. At that time the project had
-- 60 entries in supabase_migrations.schema_migrations (the last 20261103020000, 0058).
--
-- What it holds: every row of the 72 tables of schema public (2927 rows). Not included, because they live outside
-- these tables and no migration touches them: sign-in accounts (auth), Vault keys, edge-function secrets.
-- Encrypted columns (key-box codes, identity numbers) come back exactly as they were and can be read only in the
-- same project, whose Vault holds their keys.
--
-- RESTORE — emergency only. It REPLACES every row of those 72 tables with the rows below.
--   1. The target database must be at the same migrations (the 60 listed below). The script checks this first and
--      stops without changing anything if the history differs.
--   2. Run the whole file once: Supabase SQL Editor ← paste ← Run, or
--      psql -v ON_ERROR_STOP=1 -f <this file> "<connection string>"   (the file opens and commits its own transaction)
--   One transaction: either everything is restored or nothing changes.
--   3. Check: the row counts and fingerprints in MANIFEST.md (query at the end of this file).
-- =====================================================================================================
begin;

do $check$
declare expected text[] := array[""" + ",".join(f"'{v}'" for v in versions) + """];
        actual text[];
begin
  if to_regclass('supabase_migrations.schema_migrations') is null then
    raise exception 'RESTORE STOPPED: supabase_migrations.schema_migrations is missing; the target is not a Supabase project at the backup''s migrations';
  end if;
  select coalesce(array_agg(version::text order by version), '{}') into actual from supabase_migrations.schema_migrations;
  if actual is distinct from expected then
    raise exception 'RESTORE STOPPED: the target''s migration history differs from the backup''s (% entries there, % in the backup). Restore into a database at the same migrations.',
      cardinality(actual), cardinality(expected);
  end if;
end $check$;

-- restored rows are written as they were: foreign keys and triggers are not re-run for them
set local session_replication_role = replica;

-- a generated column (e.g. reservations.guest_verified) is computed again, never written
create function pg_temp.zrestore(p_table text, p_rows json) returns void language plpgsql as $f$
declare cols text;
begin
  select string_agg(quote_ident(column_name), ', ' order by ordinal_position) into cols
    from information_schema.columns where table_schema = 'public' and table_name = p_table and is_generated = 'NEVER';
  execute format('insert into public.%I (%s) select %s from json_populate_recordset(null::public.%I, $1)', p_table, cols, cols, p_table) using p_rows;
end $f$;
""")
out.append("truncate table " + ", ".join(f"public.{t}" for t in tables) + ";\n")

rows_total = 0
for t in tables:
    p = base / "tables" / f"{t}.json"
    if not p.exists():
        out.append(f"-- {t}: no rows\n")
        continue
    # numbers keep their text exactly (numeric scale, e.g. 1.00 inside jsonb), never re-formatted through float
    data = json.loads(p.read_text(encoding="utf-8"), parse_float=lambda x: "@@ZNUM" + x + "@@")
    if not data:
        out.append(f"-- {t}: no rows\n")
        continue
    payload = re.sub(r'"@@ZNUM([-+0-9.eE]+)@@"', r"\1", json.dumps(data, ensure_ascii=False, separators=(",", ":")))
    if TAG in payload:
        raise SystemExit(f"{t}: the dollar-quote tag occurs in the data")
    rows_total += len(data)
    out.append(f"-- {t}: {len(data)} rows\n")
    out.append(f"select pg_temp.zrestore('{t}', {TAG}{payload}{TAG}::json);\n")

out.append("""
commit;

-- Check after a restore (compare with MANIFEST.md): rows and fingerprint of every table
-- set timezone = 'UTC';
-- select c.relname, (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from public.%I', c.relname), false, true, '')))[1]::text::int as rows,
--        (xpath('/row/m/text()', query_to_xml(format('select coalesce(md5(string_agg(to_jsonb(t)::text, ''|'' order by to_jsonb(t)::text)), ''empty'') as m from public.%I t', c.relname), false, true, '')))[1]::text as md5
--   from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r' order by 1;
""")
(base / "zaaer-db-2026-11-07-0312.sql").write_text("".join(out), encoding="utf-8")
print(f"restore script written: {len(tables)} tables, {rows_total} rows")
