#!/usr/bin/env bash
# Restore drill: a fresh database at production's migrations, the backup restored into it, then every table's rows
# and fingerprint compared with the ones read from production when the backup was taken.
# Usage: drill.sh <repo> <backup dir> [db name]
set -euo pipefail
REPO="$1"; B="$2"; DB="${3:-zaaer_restore_drill}"
cd "$REPO"
source tests/sql/bootstrap.sh
bootstrap_db "$DB" >/dev/null
for f in supabase/migrations/*.sql; do
  v=$(basename "$f" | cut -d_ -f1)
  if grep -qx "$v" supabase/production-applied.txt; then psql -d "$DB" -v ON_ERROR_STOP=1 -q -f "$f" >/dev/null 2>&1 || { echo "migration failed: $f"; exit 1; }; fi
done
# the migration history as a hosted project keeps it
python3 -I - "$B/tables/schema_migrations.json" > "$B/history.sql" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1], encoding="utf-8"))
print("create schema if not exists supabase_migrations;")
print("create table if not exists supabase_migrations.schema_migrations (version text primary key, statements text[], name text);")
for r in rows:
    print(f"insert into supabase_migrations.schema_migrations(version, name) values ('{r['version']}', '{r['name']}');")
PY
psql -d "$DB" -v ON_ERROR_STOP=1 -q -f "$B/history.sql" >/dev/null
echo "seeded rows before the restore: $(psql -d "$DB" -At -c "select sum((xpath('/row/c/text()', query_to_xml(format('select count(*) as c from public.%I', c.relname), false, true, '')))[1]::text::int) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r'")"
psql -d "$DB" --single-transaction -v ON_ERROR_STOP=1 -q -f "$B/zaaer-db-2026-11-01-1036.sql" >/dev/null
PGTZ=UTC psql -d "$DB" -At -F '|' -c "select c.relname, (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from public.%I', c.relname), false, true, '')))[1]::text::int,
  (xpath('/row/m/text()', query_to_xml(format('select coalesce(md5(string_agg(to_jsonb(t)::text, ''|'' order by to_jsonb(t)::text)), ''empty'') as m from public.%I t', c.relname), false, true, '')))[1]::text
  from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r' order by 1" > "$B/restored.txt"
python3 -I - "$B/source_manifest.json" "$B/restored.txt" <<'PY'
import json, sys
src = {t["t"]: (t["rows"], t["md5"]) for t in json.load(open(sys.argv[1], encoding="utf-8"))["tables"]}
got = {}
for line in open(sys.argv[2], encoding="utf-8"):
    name, rows, md5 = line.rstrip("\n").split("|")
    got[name] = (int(rows), md5)
bad = [t for t in sorted(set(src) | set(got)) if src.get(t) != got.get(t)]
for t in bad:
    print(f"DIFF {t}: production={src.get(t)} restored={got.get(t)}")
print(f"tables compared: {len(src)}; rows: {sum(r for r, _ in src.values())}; identical: {len(src) - len(bad)}; different: {len(bad)}")
sys.exit(1 if bad else 0)
PY
