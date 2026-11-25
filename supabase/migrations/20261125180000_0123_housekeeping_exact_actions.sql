-- Exact individual action gates only; preserve legacy, owner, branch, assignee and business rules.
CREATE OR REPLACE FUNCTION public.fn_hk_create_task(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare t housekeeping_tasks%rowtype; v_room uuid := (p->>'room_id')::uuid; v_fac uuid := (p->>'facility_id')::uuid; v_branch uuid; tt task_types%rowtype; v_assignee uuid := (p->>'assignee_id')::uuid;
        v_start timestamptz := coalesce((p->>'scheduled_start')::timestamptz, now()); v_end timestamptz := (p->>'scheduled_end')::timestamptz;
begin
  perform fn_require_cap('task.work');
  if not fn_can_write('task.work', 'add') then raise exception 'FORBIDDEN: task.work add' using errcode='42501';end if;
  if (v_room is null) = (v_fac is null) then raise exception 'VALIDATION: one_target'; end if;    -- H01
  if v_room is not null then select branch_id into v_branch from rooms where id = v_room and archived_at is null; end if;
  if v_fac  is not null then select branch_id into v_branch from facilities where id = v_fac and archived_at is null; end if;
  if v_branch is null then raise exception 'NOT_FOUND: target'; end if;
  perform fn_require_branch(v_branch);
  select * into tt from task_types where id = (p->>'task_type_id')::uuid and branch_id = v_branch and archived_at is null;
  if not found then raise exception 'BRANCH_MISMATCH: task_type'; end if;
  if (p->>'reservation_id') is not null and not exists (select 1 from reservations where id = (p->>'reservation_id')::uuid and branch_id = v_branch) then
    raise exception 'BRANCH_MISMATCH: reservation';
  end if;
  if v_assignee is not null and not fn_is_member(v_assignee, v_branch) then raise exception 'ASSIGNEE_NOT_IN_BRANCH'; end if;   -- H02
  if v_end is not null and v_end < v_start then raise exception 'VALIDATION: schedule'; end if;                                  -- decision 28
  insert into housekeeping_tasks(organization_id, branch_id, room_id, facility_id, task_type_id, task_type_name_snapshot, reservation_id, priority, assignee_id, scheduled_start, scheduled_end, description, created_by)
  values (fn_user_org_id(), v_branch, v_room, v_fac, tt.id, tt.name, (p->>'reservation_id')::uuid, coalesce(p->>'priority','medium'), v_assignee,
          v_start, v_end, p->>'description', fn_staff_id()) returning * into t;
  if v_room is not null and tt.code = 'room_cleaning' then update rooms set cleanliness = 'dirty' where id = v_room and cleanliness = 'clean'; perform fn_recompute_room_ready(v_room); end if;
  perform fn_audit_change(v_branch, 'task.created', 'housekeeping_task', t.id, null, to_jsonb(t));
  return jsonb_build_object('ok', true, 'id', t.id);
end $function$
;
CREATE OR REPLACE FUNCTION public.fn_hk_start_task(p_task uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare t housekeeping_tasks%rowtype;
begin
  perform fn_require_cap('task.work');
  if not fn_can_write('task.work', 'edit') then raise exception 'FORBIDDEN: task.work edit' using errcode='42501';end if;
  select * into t from housekeeping_tasks where id = p_task for update;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;
  perform fn_require_branch(t.branch_id);
  if t.status <> 'pending' then raise exception 'TASK_STATUS_INVALID'; end if;
  if fn_has_role('housekeeping') and t.assignee_id is not null and t.assignee_id <> fn_staff_id() then raise exception 'FORBIDDEN: not assignee'; end if;
  update housekeeping_tasks set status = 'in_progress', started_at = now(), assignee_id = coalesce(assignee_id, fn_staff_id()), version = version + 1, updated_at = now() where id = t.id;
  if t.room_id is not null and t.task_type_id in (select id from task_types where code = 'room_cleaning') then update rooms set cleanliness = 'in_progress' where id = t.room_id; end if;
  perform fn_audit_change(t.branch_id, 'task.started', 'housekeeping_task', t.id, null, null);
  return jsonb_build_object('ok', true);
end $function$
;
CREATE OR REPLACE FUNCTION public.fn_hk_complete_task(p_task uuid, p_note text DEFAULT NULL::text, p_expected_version integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare t housekeeping_tasks%rowtype; st room_status; is_cleaning boolean; occ text;
begin
  perform fn_require_cap('task.work');
  if not fn_can_write('task.work', 'edit') then raise exception 'FORBIDDEN: task.work edit' using errcode='42501';end if;
  select * into t from housekeeping_tasks where id = p_task for update;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;
  perform fn_require_branch(t.branch_id);
  perform fn_check_version_strict(t.version, p_expected_version);
  if t.status not in ('pending','in_progress') then raise exception 'TASK_STATUS_INVALID'; end if;
  if fn_has_role('housekeeping') and t.assignee_id is not null and t.assignee_id <> fn_staff_id() then raise exception 'FORBIDDEN: not assignee'; end if;
  update housekeeping_tasks set status = 'completed', completed_at = now(), completed_by = fn_staff_id(), assignee_id = coalesce(assignee_id, fn_staff_id()),
    result_note = p_note, version = version + 1, updated_at = now() where id = t.id;
  if t.room_id is not null then
    select (code = 'room_cleaning') into is_cleaning from task_types where id = t.task_type_id;
    if coalesce(is_cleaning, false) then
      update rooms set cleanliness = 'clean', updated_at = now() where id = t.room_id;
    end if;
    st := fn_recompute_room_ready(t.room_id);           -- occupied stays occupied
    select status::text into occ from rooms where id = t.room_id;
  end if;
  perform fn_audit_change(t.branch_id, 'task.completed', 'housekeeping_task', t.id, null, jsonb_build_object('room_status', st, 'note', p_note));
  return jsonb_build_object('ok', true, 'room_status', coalesce(occ, st::text));
end $function$
;
