-- =====================================================================
-- Platform tests (PL01–PL08): properties a hosted Supabase project needs that a plain
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

-- PL05: environment bootstrap (0014) moves data encrypted with the public seed keys onto the configured
--       keys, and a second run changes nothing. Runs inside a rolled-back block: no state leaks into later suites.
do $$
declare kb uuid; g uuid; r1 jsonb; r2 jsonb; code_ok boolean; id_ok boolean; err text;
begin
  begin
    select id into kb from keyboxes order by id limit 1;
    select id into g from reservation_guests order by id limit 1;
    update keyboxes set code_encrypted = pgp_sym_encrypt('4321', 'demo-keybox-key-v1') where id = kb;
    update reservation_guests set identity_number_encrypted = pgp_sym_encrypt('1000000001', 'demo-id-key-v1') where id = g;
    r1 := fn_bootstrap_encryption_keys();
    select pgp_sym_decrypt(code_encrypted, fn_secret('keybox_key')) = '4321' into code_ok from keyboxes where id = kb;
    select pgp_sym_decrypt(identity_number_encrypted, fn_secret('identity_key')) = '1000000001' into id_ok from reservation_guests where id = g;
    r2 := fn_bootstrap_encryption_keys();
    raise exception 'PL05_ROLLBACK';
  exception when others then
    if sqlerrm <> 'PL05_ROLLBACK' then err := sqlerrm; end if;
  end;
  insert into test_results values ('PL05 bootstrap moves seed-key data onto the configured keys, and is idempotent',
    err is null and coalesce(code_ok, false) and coalesce(id_ok, false)
      and (r1->>'reencrypted_keybox_codes')::int >= 1 and (r1->>'reencrypted_identity_numbers')::int >= 1
      and (r2->>'reencrypted_keybox_codes')::int = 0 and (r2->>'reencrypted_identity_numbers')::int = 0,
    coalesce(err, 'first=' || coalesce(r1::text, 'null') || ' second=' || coalesce(r2::text, 'null')));
end $$;

-- PL07: every function in public pins its search_path, definer or not (hosted linter 0011)
insert into test_results
select 'PL07 every function in public pins search_path (no role-mutable search_path)', count(*) = 0,
       coalesce(string_agg(p.proname, ', '), '')
from pg_proc p
where p.pronamespace = 'public'::regnamespace and p.proname !~ '^t_'
  and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')
  and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e');

-- PL08: the AI settings point at a model a new API key can call (0017): no Gemini 1.x/2.x, as default or as value
insert into test_results
select 'PL08 ai_settings uses a current Gemini model (default and rows; 1.x/2.x are unavailable to new keys)',
       count(*) = 0 and (select column_default from information_schema.columns
                         where table_schema = 'public' and table_name = 'ai_settings' and column_name = 'model') !~ 'gemini-[12][.]',
       coalesce(string_agg(model, ', '), '')
from ai_settings where model ~ '^gemini-[12][.]';

-- PL06: no API role can run the bootstrap (it can create keys and rewrite encrypted columns)
insert into test_results
select 'PL06 fn_bootstrap_encryption_keys is not executable by anon / authenticated / service_role',
       not has_function_privilege('anon', 'fn_bootstrap_encryption_keys()', 'execute')
       and not has_function_privilege('authenticated', 'fn_bootstrap_encryption_keys()', 'execute')
       and not has_function_privilege('service_role', 'fn_bootstrap_encryption_keys()', 'execute'),
       null;

select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),110) as detail from test_results order by ok, name;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from test_results where not ok) then raise exception 'PLATFORM TESTS FAILED'; end if;
end $$;
