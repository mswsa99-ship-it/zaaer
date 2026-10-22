-- Schema fingerprint: compare two databases built from the same migrations (e.g. local reference vs a hosted
-- environment). Prints one hash per object kind; drill down with the per-object query below when one differs.
with objs as (
  select 'function' as kind, p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as name,
         md5(p.prosrc || '|' || coalesce(array_to_string(p.proconfig, ','), '') || '|' || p.prosecdef::text) as fp
  from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname !~ '^t_'
    and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  union all
  select 'column', c.table_name || '.' || c.column_name, md5(c.data_type || '|' || c.is_nullable || '|' || coalesce(c.udt_name, ''))
  from information_schema.columns c join pg_class k on k.relname = c.table_name and k.relnamespace = 'public'::regnamespace
  where c.table_schema = 'public' and k.relkind in ('r', 'v', 'p')
  union all
  select 'policy', tablename || '.' || policyname, md5(cmd || '|' || array_to_string(roles, ','))
  from pg_policies where schemaname = 'public'
  union all
  select 'constraint', conrelid::regclass::text || '.' || conname, md5(contype::text) from pg_constraint where connamespace = 'public'::regnamespace and conrelid <> 0
  union all
  select 'index', i.indexrelid::regclass::text, md5(i.indisunique::text) from pg_index i join pg_class c on c.oid = i.indrelid where c.relnamespace = 'public'::regnamespace
  union all
  select 'enum', t.typname || '.' || e.enumlabel, md5(e.enumsortorder::text) from pg_enum e join pg_type t on t.oid = e.enumtypid where t.typnamespace = 'public'::regnamespace
)
select kind, count(*) as objects, md5(string_agg(name || '=' || fp, ',' order by name)) as hash from objs group by kind order by kind;
