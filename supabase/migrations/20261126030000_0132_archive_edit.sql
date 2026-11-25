-- LOCAL CANDIDATE, UNADOPTED, UNRUN. Archive/restore of the 8 definition entities follows the entity page's EDIT permission for individual non-owner accounts.
-- Provenance only (authority is the user original, not this comment): user reply «اعتمد» 2026-11-25 06:09:21-22 (wamid ending QUM2MDdGNjZFNjVBNjJCRDY5OEEzNzBCRTQzNzZBRTUA), a reply to the 06:08:53 proposal. Verified from the observation DB.
-- Body = the 0043 text of fn_admin_archive_definition (the live body: no later migration, including the composed 0110 and 0129, redefines or wraps it; verified by grep) with ONE line replaced.
-- Needs the 0129 helpers fn_require_definition_page / fn_definition_entity_page (apply after 0129). Legacy and owner: those helpers fall through to fn_require_cap('definitions'), exactly the old line.
-- Branch: page /admin/branches edit AND the unchanged owner-only line (fn_require_role('owner')): an individual non-owner with the branch Edit grant is still refused.
-- Individual non-owner with an unknown entity: refused 42501 before the VALIDATION: entity check (fail closed); legacy unchanged.
CREATE OR REPLACE FUNCTION public.fn_admin_archive_definition(p_entity text, p_id uuid, p_reason text, p_archive boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_branch uuid; v_table text; before jsonb; after jsonb; open_count int := 0;
begin
  perform fn_require_definition_page(fn_definition_entity_page(p_entity), 'edit');   -- CANDIDATE: archive AND restore = entity page Edit (user reply 2026-11-25 06:09:21-22, see line 2); hard delete stays Delete; branch keeps the owner-only line below
  if p_archive and coalesce(trim(p_reason),'') = '' then raise exception 'VALIDATION: reason'; end if;
  v_table := case p_entity when 'branch' then 'branches' when 'block' then 'blocks' when 'floor' then 'floors' when 'room_category' then 'room_categories'
                           when 'room' then 'rooms' when 'facility' then 'facilities' when 'task_type' then 'task_types' when 'service' then 'service_definitions' end;
  if v_table is null then raise exception 'VALIDATION: entity'; end if;
  execute format('select %s, to_jsonb(t) from %I t where id = $1 for update', case when p_entity = 'branch' then 'id' else 'branch_id' end, v_table) into v_branch, before using p_id;
  if before is null then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(v_branch);
  if p_entity = 'branch' then perform fn_require_role('owner'); end if;

  if p_archive then
    -- open commitments block archiving (G17)
    if p_entity = 'room' then
      if fn_room_guest_in_house(p_id) then raise exception 'ROOM_HAS_GUEST: a guest is in house'; end if;
      select count(*) into open_count from reservation_allocations a join reservations r on r.id = a.reservation_id
        where a.room_id = p_id and a.status = 'active' and r.status in ('confirmed','checked_in','pending_verification') and a.to_date > fn_branch_today(v_branch);
    elsif p_entity = 'facility' then
      select count(*) into open_count from housekeeping_tasks where facility_id = p_id and status in ('pending','in_progress');
    elsif p_entity = 'task_type' then
      select count(*) into open_count from housekeeping_tasks where task_type_id = p_id and status in ('pending','in_progress');
    elsif p_entity in ('block','floor') then
      execute format('select count(*) from rooms where %I = $1 and archived_at is null', case p_entity when 'block' then 'block_id' else 'floor_id' end) into open_count using p_id;
    elsif p_entity = 'room_category' then
      -- the type's row is locked above; a booking on it waits for this (trg_reservation_category_guard), so the count is final
      select count(*) into open_count from rooms where category_id = p_id and archived_at is null;
      open_count := open_count + (select count(*) from reservations where room_category_id = p_id and status in ('confirmed','checked_in','pending_verification')
                                                                    and check_out > fn_branch_today(v_branch));
    elsif p_entity = 'branch' then
      select count(*) into open_count from reservations where branch_id = p_id and status in ('confirmed','checked_in','pending_verification') and check_out > fn_branch_today(p_id);
      if (select count(*) from branches where organization_id = fn_user_org_id() and archived_at is null and is_active) <= 1 then raise exception 'LAST_ACTIVE_BRANCH'; end if;
    end if;
    if open_count > 0 then raise exception 'HAS_OPEN_COMMITMENTS: %', open_count; end if;
    execute format('update %I set archived_at = now(), archived_by = $2, archive_reason = $3, is_active = false, version = version + 1, updated_at = now() where id = $1 returning to_jsonb(%I)', v_table, v_table)
      into after using p_id, fn_staff_id(), p_reason;
    if p_entity = 'room' then update rooms set status = 'out_of_service' where id = p_id; end if;
  else
    execute format('update %I set archived_at = null, archived_by = null, archive_reason = null, is_active = true, version = version + 1, updated_at = now() where id = $1 returning to_jsonb(%I)', v_table, v_table)
      into after using p_id;
    if p_entity = 'room' then update rooms set status = 'available' where id = p_id and status = 'out_of_service'; end if;
  end if;
  perform fn_audit_change(v_branch, p_entity || case when p_archive then '.archived' else '.restored' end, p_entity, p_id, before, after, p_reason);
  return jsonb_build_object('ok', true);
end $function$;
