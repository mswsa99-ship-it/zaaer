/*
# 0012 — Hosted Supabase compatibility (found while preparing the staging environment)

On a hosted Supabase project, pgcrypto / uuid-ossp are installed in schema `extensions`, not
`public`. Every SECURITY DEFINER function in this project pins `search_path = public` (correct:
it stops search-path hijacking), which also hides `extensions` — so pgp_sym_encrypt/decrypt
(identity numbers, keybox codes) fail with "function does not exist" on the real platform while
passing on a plain local Postgres. tests/sql/run.sh now mirrors the hosted layout, which is how
this was caught.

Fix: every function in `public` pinned to exactly `search_path=public` gets
`search_path = public, extensions`. Two SECURITY DEFINER helpers from 0002 (fn_user_org_id,
fn_is_staff) had no pinned search_path at all — a search-path hijacking risk the new platform test
PL01 caught — and get the same setting. The `extensions` schema is owned by the platform and not
writable by the API roles, so this keeps the hijacking protection. Functions created by later
migrations must declare `set search_path = public, extensions` themselves when they call an
extension function — tests/sql/platform_tests.sql fails otherwise.
*/
do $$
declare f record; n int := 0;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public'
      and (
        (p.proconfig is not null and 'search_path=public' = any(p.proconfig))
        -- SECURITY DEFINER without any pinned search_path
        or (p.prosecdef and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%'))
      )
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')   -- skip functions owned by extensions
  loop
    execute format('alter function %s set search_path = public, extensions', f.sig);
    n := n + 1;
  end loop;
  raise notice '0012: search_path extended on % functions', n;
end $$;
