-- =====================================================================
-- Platform tests (PL01–PL04): properties a hosted Supabase project needs that a plain
-- local Postgres would not catch. Runs on the DB built by tests/sql/run.sh, which mirrors
-- the hosted layout (pgcrypto / uuid-ossp in schema "extensions").
-- =====================================================================
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);

-- PL01: every SECURITY DEFINER function pins its search_path (no search-path hijacking)
insert into test_results
select 'PL01 every SECURITY DEFINER function in public pins search_path', count(*) = 0,
       coalesce(string_agg(p.proname, ', '), '')
from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
where ns.nspname = 'public' and p.prosecdef
  and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')
  and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e');

-- PL02: a function that calls an extension function can see the extensions schema
insert into test_results
select 'PL02 functions calling pgcrypto/uuid-ossp have "extensions" on their search_path', count(*) = 0,
       coalesce(string_agg(p.proname, ', '), '')
from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
where ns.nspname = 'public'
  and p.prosrc ~ '(pgp_sym_(en|de)crypt|gen_random_bytes|digest\(|hmac\(|crypt\(|gen_salt\(|uuid_generate_v)'
  and exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')
  and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%extensions%')
  and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e');

-- PL03: the extensions really live outside public here (otherwise PL02 would prove nothing)
insert into test_results
select 'PL03 test database mirrors the hosted layout (pgcrypto in schema extensions)',
       exists (select 1 from pg_extension e join pg_namespace n on n.oid = e.extnamespace where e.extname = 'pgcrypto' and n.nspname = 'extensions'),
       (select n.nspname from pg_extension e join pg_namespace n on n.oid = e.extnamespace where e.extname = 'pgcrypto');

-- PL04: an identity number round-trips through the definer functions' encryption path
do $$ declare ok boolean; begin
  begin
    perform set_config('search_path', 'public', true);   -- what a definer function sees
    execute 'select extensions.pgp_sym_decrypt(extensions.pgp_sym_encrypt(''1000000000'', ''k''), ''k'') = ''1000000000''' into ok;
    insert into test_results values ('PL04 encryption functions resolve from the extensions schema', ok, null);
  exception when others then
    insert into test_results values ('PL04 encryption functions resolve from the extensions schema', false, sqlerrm);
  end;
end $$;

select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),110) as detail from test_results order by ok, name;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from test_results where not ok) then raise exception 'PLATFORM TESTS FAILED'; end if;
end $$;
