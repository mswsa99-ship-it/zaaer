-- =====================================================================
-- 0026 — Traceable audit events (decision 39, control G22)
--
--  * Every audit row now carries:
--      correlation_id  one value for all rows written by the same operation: the caller's x-correlation-id
--                      header when it is well formed (the app sends one per request and shows it with any
--                      error, decision 60), else the transaction id — one RPC call = one transaction.
--      source          where the operation came from: app.source (set inside the database by a trusted
--                      caller such as the operations assistant), else the x-client-source header, else
--                      'screen' for a person and 'system' for unattended work. Attribution only, never
--                      used for authorisation.
--      actor_type      staff | guest | user | system.
--      result          'success' (a failed operation rolls back with its rows; functions may record a
--                      refusal explicitly as 'rejected').
--      category        'security' for staff, membership and purge events (owner only), else 'business'.
--  * The values are filled by a BEFORE INSERT trigger, so the existing audit calls need no change and a new
--    call cannot forget them.
--  * Role and activation changes of a staff member are audited by a trigger, whatever path made them.
--  * Branch memberships change only through audited functions (invite now; the owner's staff editor,
--    decision 35): the direct-write policy is closed. Reading them is unchanged.
--  * Security events are readable by the owner only. Audit rows have no update policy for anyone.
--  * Written without the words the SQL tool refuses (see docs): constraints are added only when missing,
--    triggers use CREATE OR REPLACE, and the policies are changed with ALTER POLICY.
-- =====================================================================

alter table audit_events add column if not exists correlation_id text;
alter table audit_events add column if not exists source text;
alter table audit_events add column if not exists actor_type text;
alter table audit_events add column if not exists result text not null default 'success';
alter table audit_events add column if not exists category text not null default 'business';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'audit_result_valid') then
    alter table audit_events add constraint audit_result_valid check (result in ('success','rejected'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'audit_category_valid') then
    alter table audit_events add constraint audit_category_valid check (category in ('business','security'));
  end if;
end $$;
create index if not exists idx_audit_correlation on audit_events(correlation_id);
create index if not exists idx_audit_org_time on audit_events(organization_id, created_at desc);

-- A request header as PostgREST exposes it (lower-case names); null outside an API request.
create or replace function fn_request_header(p_name text) returns text
language sql stable set search_path = public as $$
  select nullif(coalesce(nullif(current_setting('request.headers', true), ''), '{}')::jsonb ->> lower(p_name), '')
$$;
revoke all on function fn_request_header(text) from public, anon, authenticated;

create or replace function fn_audit_enrich() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_corr text; v_src text; v_role text;
begin
  v_corr := fn_request_header('x-correlation-id');
  if v_corr is not null and v_corr !~ '^[A-Za-z0-9_-]{6,64}$' then v_corr := null; end if;
  new.correlation_id := coalesce(new.correlation_id, v_corr, 'tx-' || txid_current()::text);

  v_src := coalesce(nullif(current_setting('app.source', true), ''), fn_request_header('x-client-source'));
  if v_src is not null and v_src !~ '^[a-z][a-z_-]{1,31}$' then v_src := null; end if;

  v_role := coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb ->> 'role';
  new.actor_id := coalesce(new.actor_id, fn_staff_id());
  new.actor_type := coalesce(new.actor_type,
    case when new.actor_id is not null then 'staff'
         when v_role = 'anon' then 'guest'
         when auth.uid() is not null then 'user'
         else 'system' end);
  new.source := coalesce(new.source, v_src, case when new.actor_type = 'system' then 'system' else 'screen' end);
  if new.action ~ '^(staff|membership|security|data_purge)' then new.category := 'security'; end if;
  new.result := coalesce(new.result, 'success');
  return new;
end $$;
revoke all on function fn_audit_enrich() from public, anon, authenticated;
create or replace trigger trg_audit_enrich before insert on audit_events for each row execute function fn_audit_enrich();

-- Staff changes: role and activation, whatever path made them. The name is recorded as "changed" only.
create or replace function fn_audit_staff_change() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.role is distinct from new.role or old.is_active is distinct from new.is_active or old.full_name is distinct from new.full_name then
    insert into audit_events(organization_id, branch_id, actor_id, action, entity_type, entity_id, details)
    values (new.organization_id, null, fn_staff_id(),
            case when old.is_active is distinct from new.is_active then case when new.is_active then 'staff.activated' else 'staff.deactivated' end
                 when old.role is distinct from new.role then 'staff.role_changed'
                 else 'staff.updated' end,
            'staff_profile', new.id,
            jsonb_strip_nulls(jsonb_build_object(
              'before', jsonb_build_object('role', old.role, 'is_active', old.is_active),
              'after',  jsonb_build_object('role', new.role, 'is_active', new.is_active),
              'name_changed', case when old.full_name is distinct from new.full_name then true end)));
  end if;
  return new;
end $$;
revoke all on function fn_audit_staff_change() from public, anon, authenticated;
create or replace trigger trg_audit_staff_change after update on staff_profiles for each row execute function fn_audit_staff_change();

-- Invite: the memberships it creates are part of its audit row.
create or replace function fn_staff_invite(p_email text, p_full_name text, p_role role_code, p_branch_ids uuid[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare sp staff_profiles%rowtype; b uuid;
begin
  perform fn_require_role('owner');
  if p_role = 'guest' then raise exception 'INVALID_ROLE'; end if;
  insert into staff_profiles(organization_id, full_name, email, role, is_active) values (fn_user_org_id(), p_full_name, lower(trim(p_email)), p_role, true) returning * into sp;
  foreach b in array coalesce(p_branch_ids, '{}') loop
    perform fn_require_branch(b);
    insert into branch_memberships(staff_id, branch_id) values (sp.id, b) on conflict do nothing;
  end loop;
  perform fn_audit(sp.organization_id, null, fn_staff_id(), 'staff_invited', 'staff_profile', sp.id,
                   jsonb_build_object('role', p_role, 'branch_ids', to_jsonb(coalesce(p_branch_ids, '{}'))));
  return jsonb_build_object('ok', true, 'staff_id', sp.id);
end $$;
grant execute on function fn_staff_invite(text, text, role_code, uuid[]) to authenticated;

-- Memberships: readable as before; written only by the audited functions above (SECURITY DEFINER).
alter policy "owner_memberships_write" on branch_memberships using (false) with check (false);

-- Security events: owner only. Business events: owner, manager, supervisor (as before).
alter policy "mgmt_audit_read" on audit_events
  using (fn_has_role('owner','manager','supervisor') and organization_id = fn_user_org_id()
         and (category <> 'security' or fn_has_role('owner')));

-- Older rows: classify, and give each a correlation of its own (the trigger only runs for new rows).
update audit_events set category = 'security' where category = 'business' and action ~ '^(staff|membership|security|data_purge)';
update audit_events set correlation_id = 'legacy-' || id::text where correlation_id is null;
update audit_events set actor_type = case when actor_id is not null then 'staff' else 'system' end where actor_type is null;
update audit_events set source = 'legacy' where source is null;
