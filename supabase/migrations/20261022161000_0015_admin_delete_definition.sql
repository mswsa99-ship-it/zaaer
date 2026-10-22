/*
# 0015 — Re-assert fn_admin_delete_definition (staging bootstrap)

Staging was first created from a verified snapshot of 0001–0014 through a tool that refuses any
statement containing a delete, so this single function was left out there; the deploy pipeline
applies this migration to staging like any other. On every database built from the migrations it
is a no-op: same body and settings as 0007b + 0012, grants untouched.
*/

-- Hard delete ONLY for definitions with zero dependencies; otherwise tells the caller to archive (G16)
create or replace function fn_admin_delete_definition(p_entity text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare deps jsonb; v_branch uuid; v_table text; before jsonb;
begin
  perform fn_require_role('owner','manager');
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
  execute format('delete from %I where id = $1', v_table) using p_id;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function fn_admin_delete_definition(text, uuid) to authenticated;
