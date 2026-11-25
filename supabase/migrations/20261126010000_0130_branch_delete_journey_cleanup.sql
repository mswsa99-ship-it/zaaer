-- LOCAL CANDIDATE, UNADOPTED, UNRUN. Not a numbered migration. Apply on a clone after the full migration set (it redefines the 0110 inner function).
-- Defect (executor-measured, PG16+PG17): owner delete of a fresh empty branch raises 23503, FK branch_journey_settings_branch_id_fkey (NO ACTION). 0070's
-- after-insert trigger gives every branch a settings row; fn_definition_dependencies does not count it; fn_admin_delete_definition never removes it.
-- Repair: the function removes that branch's own settings row, in the branch-delete path only, AFTER owner/branch/tenant checks, the dependency check and the audit write
-- (same place as its existing cleanup of the seeded system task type). No FK change, no trigger, no policy change, no new dependency semantics: a branch with real dependencies still returns HAS_DEPENDENCIES and keeps its config.
-- Body is the 0015 text (still the live body, now under the 0110 name __impl) plus ONE line. Wrapper, grants and search_path unchanged (create or replace keeps ACL).
create or replace function public.fn_admin_delete_definition__impl(p_entity text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare deps jsonb; v_branch uuid; v_table text; before jsonb;
begin
  perform fn_require_role_ind('owner','manager');
  v_table := case p_entity when 'branch' then 'branches' when 'block' then 'blocks' when 'floor' then 'floors' when 'room_category' then 'room_categories'
                           when 'room' then 'rooms' when 'facility' then 'facilities' when 'task_type' then 'task_types' when 'service' then 'service_definitions' end;
  if v_table is null then raise exception 'VALIDATION: entity'; end if;
  execute format('select %s, to_jsonb(t) from %I t where id = $1 for update', case when p_entity = 'branch' then 'id' else 'branch_id' end, v_table) into v_branch, before using p_id;
  if before is null then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(v_branch);
  if p_entity = 'branch' then perform fn_require_role('owner'); end if;
  deps := fn_definition_dependencies(p_entity, p_id);
  if fn_dependency_total(deps) > 0 then
    return jsonb_build_object('ok', false, 'error', 'HAS_DEPENDENCIES', 'dependencies', deps);
  end if;
  if p_entity = 'task_type' and (before->>'code') is not null then return jsonb_build_object('ok', false, 'error', 'SYSTEM_DEFINITION'); end if;
  -- audit first: the audit row must survive the entity
  perform fn_audit_change(v_branch, p_entity || '.deleted', p_entity, p_id, before, null);
  if p_entity = 'branch' then delete from task_types where branch_id = p_id and code is not null; end if;   -- the auto-seeded system type is not user data
  if p_entity = 'branch' then delete from branch_journey_settings where branch_id = p_id; end if;          -- REPAIR: the branch's own auto-created guest-journey config (0070 trigger)
  execute format('delete from %I where id = $1', v_table) using p_id;
  return jsonb_build_object('ok', true);
end $$;
