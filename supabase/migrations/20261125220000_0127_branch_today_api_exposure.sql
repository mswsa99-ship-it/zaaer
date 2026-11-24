-- 0127 branch-local calendar lookup is no longer callable directly through the API.
-- fn_branch_today(uuid) returns the property calendar date of any branch id it is given and has no caller check, so a staff
-- account could read the date of a branch it does not belong to. The 56 SECURITY DEFINER functions that need it keep calling it
-- as the function owner; the only change is removing the direct API grant. Body, owner and the service_role grant are unchanged.
-- Fail-closed: the migration stops, changing nothing, unless the catalog matches what it was tested against. It checks the
-- state at the time it runs; it cannot stop a later, separately authorized grant.
begin;
do $m$
declare
  f oid; fowner oid; bad text; before_def text; after_def text;
begin
  f := to_regprocedure('public.fn_branch_today(uuid)')::oid;
  if f is null or (select count(*) from pg_proc where proname = 'fn_branch_today' and pronamespace = 'public'::regnamespace) <> 1 then
    raise exception '0127: fn_branch_today(uuid) must exist exactly once'; end if;
  select proowner, pg_get_functiondef(oid) into fowner, before_def from pg_proc where oid = f;
  -- every direct caller must be a SECURITY DEFINER function with the same owner, so internal calls keep working
  select string_agg(p.oid::regprocedure::text, ', ') into bad from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.oid <> f and p.prosrc like '%fn_branch_today%'
     and (not p.prosecdef or p.proowner <> fowner);
  if bad is not null then raise exception '0127: callers not security definer or owned differently: %', bad; end if;
  -- the only grantees may be the owner, authenticated, anon, service_role (PUBLIC is acl grantee 0)
  select string_agg(coalesce(r.rolname, 'PUBLIC'), ', ') into bad
    from aclexplode((select proacl from pg_proc where oid = f)) a left join pg_roles r on r.oid = a.grantee
   where a.privilege_type = 'EXECUTE' and a.grantee <> fowner and coalesce(r.rolname, 'PUBLIC') not in ('PUBLIC', 'anon', 'authenticated', 'service_role');
  if bad is not null then raise exception '0127: unexpected EXECUTE grantees: %', bad; end if;
  if not has_function_privilege('service_role', f, 'execute') then raise exception '0127: service_role must hold EXECUTE before'; end if;

  -- effective reach, not only direct ACL entries: no API role may sit in a role chain (with inheritance) that reaches the owner or service_role
  select string_agg(distinct g.rolname || ' -> ' || m.rolname, ', ') into bad
    from pg_roles m join pg_roles g on g.rolname in ('anon', 'authenticated')
   where m.oid in (fowner, (select oid from pg_roles where rolname = 'service_role')) and pg_has_role(g.oid, m.oid, 'usage');
  if bad is not null then raise exception '0127: an API role inherits owner or service_role: %', bad; end if;

  revoke execute on function public.fn_branch_today(uuid) from public, anon, authenticated;

  if has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute') then
    raise exception '0127: API roles still hold EXECUTE'; end if;
  if not has_function_privilege('service_role', f, 'execute') then raise exception '0127: service_role lost EXECUTE'; end if;
  if not has_function_privilege(fowner, f, 'execute') then raise exception '0127: owner lost EXECUTE'; end if;
  -- re-enumerate after the revoke: direct grantees only owner and service_role
  select string_agg(coalesce(r.rolname, 'PUBLIC'), ', ') into bad
    from aclexplode((select proacl from pg_proc where oid = f)) a left join pg_roles r on r.oid = a.grantee
   where a.privilege_type = 'EXECUTE' and a.grantee <> fowner and coalesce(r.rolname, 'PUBLIC') <> 'service_role';
  if bad is not null then raise exception '0127: grantees remain after revoke: %', bad; end if;
  -- effective EXECUTE after: every non-superuser role other than the owner and service_role must lack it (covers inherited access, e.g. a login role that INHERITs an API role)
  select string_agg(r.rolname, ', ') into bad from pg_roles r
   where not r.rolsuper and r.oid <> fowner and r.rolname <> 'service_role' and has_function_privilege(r.oid, f, 'execute');
  if bad is not null then raise exception '0127: roles still hold effective EXECUTE: %', bad; end if;
  select pg_get_functiondef(oid) into after_def from pg_proc where oid = f;
  if after_def is distinct from before_def or (select proowner from pg_proc where oid = f) <> fowner then
    raise exception '0127: function body or owner changed'; end if;
end
$m$;
commit;
