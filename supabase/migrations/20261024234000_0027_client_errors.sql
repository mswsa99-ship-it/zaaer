-- =====================================================================
-- 0027 — Trace codes for failed operations (decision 60)
--
-- The app sends a short random code with every operation (x-correlation-id) and shows it next to the Arabic
-- message when the operation fails. A failed operation rolls back, so it leaves no audit row; the app records the
-- failure here instead: the code, the error code (never the message text), the operation name and who was
-- signed in. The owner or manager finds a code with fn_lookup_trace: the failure if it failed, or the audit rows
-- it wrote if it succeeded. No personal data is stored.
-- =====================================================================

create table if not exists client_errors (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  staff_id uuid references staff_profiles(id),
  trace_id text not null,
  error_code text not null,
  context text,
  created_at timestamptz not null default now()
);
create unique index if not exists uniq_client_errors_trace on client_errors(organization_id, trace_id);
create index if not exists idx_client_errors_time on client_errors(organization_id, created_at desc);
alter table client_errors enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'client_errors' and policyname = 'mgmt_client_errors_read') then
    create policy "mgmt_client_errors_read" on client_errors for select to authenticated
      using (organization_id = fn_user_org_id() and fn_has_role('owner','manager'));
  end if;
end $$;
revoke insert, update on client_errors from anon, authenticated;

-- Any signed-in staff member records a failure of their own; anything malformed is ignored.
create or replace function fn_log_client_error(p_trace text, p_code text, p_context text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_staff uuid := fn_staff_id(); v_org uuid := fn_user_org_id(); v_recent int;
begin
  if v_staff is null or v_org is null then return jsonb_build_object('ok', false); end if;
  if p_trace is null or p_trace !~ '^[A-Z0-9]{6,16}$' then return jsonb_build_object('ok', false); end if;
  if p_code is null or p_code !~ '^[A-Z][A-Z0-9_]{1,48}(: [a-z_0-9]{1,48})?$' then p_code := 'UNKNOWN'; end if;
  if p_context is not null and p_context !~ '^[a-z][a-z0-9_]{1,63}$' then p_context := null; end if;
  -- a misbehaving client cannot flood the table: at most 60 failures per staff member per minute
  select count(*) into v_recent from client_errors where staff_id = v_staff and created_at > now() - interval '1 minute';
  if v_recent >= 60 then return jsonb_build_object('ok', false, 'throttled', true); end if;
  insert into client_errors(organization_id, staff_id, trace_id, error_code, context)
  values (v_org, v_staff, p_trace, p_code, p_context)
  on conflict (organization_id, trace_id) do nothing;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function fn_log_client_error(text, text, text) from public, anon;
grant execute on function fn_log_client_error(text, text, text) to authenticated;

-- Support: what happened to a trace code (owner and manager). Security rows are shown to the owner only (0026).
create or replace function fn_lookup_trace(p_trace text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_org uuid := fn_user_org_id();
begin
  perform fn_require_role('owner','manager');
  if p_trace is null or p_trace !~ '^[A-Za-z0-9_-]{6,64}$' then raise exception 'VALIDATION: trace'; end if;
  return jsonb_build_object(
    'failure', (select (to_jsonb(e) - 'organization_id') || jsonb_build_object('staff_name', sp.full_name)
                  from client_errors e left join staff_profiles sp on sp.id = e.staff_id
                 where e.organization_id = v_org and e.trace_id = p_trace),
    'events', coalesce((select jsonb_agg(jsonb_build_object('action', a.action, 'entity_type', a.entity_type, 'entity_id', a.entity_id,
                                                            'actor_id', a.actor_id, 'actor_name', sp.full_name, 'source', a.source,
                                                            'result', a.result, 'created_at', a.created_at) order by a.created_at)
                         from audit_events a left join staff_profiles sp on sp.id = a.actor_id
                        where a.organization_id = v_org and a.correlation_id = p_trace
                          and (a.category <> 'security' or fn_has_role('owner'))), '[]'::jsonb));
end $$;
revoke all on function fn_lookup_trace(text) from public, anon;
grant execute on function fn_lookup_trace(text) to authenticated;
