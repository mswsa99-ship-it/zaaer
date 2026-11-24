-- Test-only oracle (added after migration 0122 revoked table SELECT on audit_events from API roles).
-- Legacy tests inspect audit payloads (details, chain columns) that the API roles can no longer read directly.
-- This SECURITY DEFINER snapshot reader lets those assertions keep their meaning. It does not replace the actor
-- access checks: direct SELECT * / details denial for API roles is asserted in tests/isolation/audit-direct-column-proof.sql.
create or replace function t_audit_all() returns setof audit_events language sql stable security definer set search_path = public as $$ select * from public.audit_events $$;
grant execute on function t_audit_all() to anon, authenticated;
