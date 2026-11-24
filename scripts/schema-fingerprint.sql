-- Schema fingerprint: compare two databases built from the same migrations — the local reference (tests/sql/bootstrap.sh
-- plus supabase/migrations, or a restored copy brought to the same migrations) and the hosted project, after every
-- migration applied there. One hash per object kind; when a kind differs, run the drill-down at the end for that kind
-- on both sides and compare the lines.
--
-- What differs by environment, not by migration (normalised here):
--   * PostgreSQL 17 (hosted) adds the MAINTAIN table privilege; the local reference runs 16. Left out of the grants.
--   * A column default prints extensions.gen_random_bytes(…) where "extensions" is not on the session's search_path.
--     The prefix is left out.
--   * fn_admin_delete_definition (0015) was applied by hand from the SQL Editor, which re-indented it (STAGING.md §1):
--     its body is compared without whitespace.
--   * Everything pasted into the SQL Editor from a Windows machine arrives with CRLF line ends (the owner's paste of
--     0022, 0031, 0034, 0039 and 0041, 26 Oct 2026): every body is compared with carriage returns removed.
--   * Test helpers t_* exist only in the test database.
-- 25 Oct 2026 this caught 0033's skipped column grant on the hosted project (fixed by 0035).
with fn as (
  select p.oid, p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as name, p.proacl, p.proowner
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace and p.proname !~ '^t_'
    and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
), objs as (
  select 'function' as kind, f.name,
         md5(case when p.proname = 'fn_admin_delete_definition' then regexp_replace(p.prosrc, '\s+', '', 'g') else replace(p.prosrc, E'\r', '') end
             || '|' || coalesce(array_to_string(p.proconfig, ','), '') || '|' || p.prosecdef::text || '|' || p.provolatile::text) as fp
  from fn f join pg_proc p on p.oid = f.oid
  union all
  select 'column', c.relname || '.' || a.attname, format_type(a.atttypid, a.atttypmod) || '|' || a.attnotnull::text
  from pg_attribute a join pg_class c on c.oid = a.attrelid
  where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'v', 'p') and a.attnum > 0 and not a.attisdropped
  union all
  select 'default', c.relname || '.' || a.attname, replace(pg_get_expr(ad.adbin, ad.adrelid), 'extensions.', '')
  from pg_attrdef ad join pg_class c on c.oid = ad.adrelid join pg_attribute a on a.attrelid = ad.adrelid and a.attnum = ad.adnum
  where c.relnamespace = 'public'::regnamespace
  union all
  select 'constraint', conrelid::regclass::text || '.' || conname, pg_get_constraintdef(oid)
  from pg_constraint where connamespace = 'public'::regnamespace and conrelid <> 0
  union all
  select 'index', i.indexrelid::regclass::text, pg_get_indexdef(i.indexrelid)
  from pg_index i join pg_class c on c.oid = i.indrelid where c.relnamespace = 'public'::regnamespace
  union all
  select 'policy', tablename || '.' || policyname,
         coalesce(qual, '') || '|' || coalesce(with_check, '') || '|' || permissive || '|' || cmd || '|' || array_to_string(roles, ',')
  from pg_policies where schemaname = 'public'
  union all
  select 'trigger', t.tgrelid::regclass::text || '.' || t.tgname, pg_get_triggerdef(t.oid)
  from pg_trigger t join pg_class c on c.oid = t.tgrelid where c.relnamespace = 'public'::regnamespace and not t.tgisinternal
  union all
  select 'view', c.relname, pg_get_viewdef(c.oid) from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'v'
  union all
  select 'enum', t.typname, string_agg(e.enumlabel, ',' order by e.enumsortorder)
  from pg_type t join pg_enum e on e.enumtypid = t.oid where t.typnamespace = 'public'::regnamespace group by t.typname
  union all
  select 'rls', c.relname, c.relrowsecurity::text || '|' || c.relforcerowsecurity::text
  from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
  union all
  select 'grant:table', c.relname,
         coalesce((select string_agg(case when a.grantee = 0 then 'public' else pg_get_userbyid(a.grantee) end || ':' || a.privilege_type, ',' order by 1)
                   from aclexplode(coalesce(c.relacl, acldefault((case c.relkind when 'S' then 's' else 'r' end)::"char", c.relowner))) a
                   where (a.grantee = 0 or pg_get_userbyid(a.grantee) in ('anon', 'authenticated', 'service_role')) and a.privilege_type <> 'MAINTAIN'), '')
  from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'v', 'p', 'S', 'm')
    and not exists (select 1 from pg_depend d where d.objid = c.oid and d.deptype = 'e')
  union all
  select 'grant:column', c.relname || '.' || att.attname,
         coalesce((select string_agg(case when a.grantee = 0 then 'public' else pg_get_userbyid(a.grantee) end || ':' || a.privilege_type, ',' order by 1)
                   from aclexplode(att.attacl) a where a.grantee = 0 or pg_get_userbyid(a.grantee) in ('anon', 'authenticated', 'service_role')), '')
  from pg_attribute att join pg_class c on c.oid = att.attrelid
  where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'v', 'p') and att.attnum > 0 and not att.attisdropped
  union all
  select 'grant:function', f.name,
         coalesce((select string_agg(case when a.grantee = 0 then 'public' else pg_get_userbyid(a.grantee) end || ':' || a.privilege_type, ',' order by 1)
                   from aclexplode(coalesce(f.proacl, acldefault('f'::"char", f.proowner))) a
                   where a.grantee = 0 or pg_get_userbyid(a.grantee) in ('anon', 'authenticated', 'service_role')), '')
  from fn f
)
select kind, count(*) as objects, md5(string_agg(name || '=' || fp, E'\n' order by name collate "C")) as hash
from objs group by kind order by kind;

-- Drill-down for one kind (replace the final select above with this, and set the kind):
--   select name, md5(fp) from objs where kind = 'grant:column' order by name collate "C";
