-- Reservation timeline uses only action, created_at, actor_id, with entity_id filter.
-- Rich details are served through existing SECURITY DEFINER RPC output contracts.
-- Row/branch/page/security RLS and legacy/individual full_roles decisions unchanged.
revoke select on table public.audit_events from anon, authenticated;
grant select (action, created_at, actor_id, entity_id) on public.audit_events to authenticated;
