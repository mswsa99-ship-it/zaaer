-- Read-only inventory on a disposable local DB after all repository migrations.
-- Not a probe, no writes. Exact pg_proc signatures preserve overloads and SQL defaults.
select jsonb_build_object(
  'tables', (select jsonb_agg(tablename order by tablename) from pg_tables where schemaname='public'),
  'functions', (select jsonb_agg(jsonb_build_object(
    'name', p.proname,
    'signature', p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
    'trigger', p.prorettype='trigger'::regtype,
    'exposed', has_function_privilege('anon',p.oid,'execute') or has_function_privilege('authenticated',p.oid,'execute')
  ) order by p.proname, p.oid) from pg_proc p where p.pronamespace='public'::regnamespace
    and p.prokind='f' and not exists (select 1 from pg_depend d where d.objid=p.oid and d.deptype='e'))
);
