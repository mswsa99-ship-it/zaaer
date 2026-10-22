/*
# 0016 — Pin search_path on the remaining helper functions (Supabase security advisor 0011)

Five small helpers (fn_normalize_ar, fn_check_version, fn_check_version_strict, fn_dependency_total,
fn_ai_ops_allowed_actions) are SECURITY INVOKER and only work on their arguments, so 0012 left them
without a pinned search_path. The hosted linter still flags them ("role mutable search_path"): a caller
could shadow a built-in they use by putting a schema of its own first on the path. Pinning costs nothing,
so every function in public now declares it, and platform test PL07 keeps it that way.
*/
do $$
declare f record; n int := 0;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('alter function %s set search_path = public, extensions', f.sig);
    n := n + 1;
  end loop;
  raise notice '0016: search_path pinned on % function(s)', n;
end $$;
