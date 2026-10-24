/*
# 0025 — «الرموز»: the key-box codes of the units on one screen, for the supervisor and housekeeping

The owner's rule: after a guest leaves a unit, its key-box code must be changed before anyone else gets it, and the
people who change it are the supervisor and the housekeeper who cleaned the unit.

  * A unit whose code must change (check-out, or the guest moved to another unit) shows red from that moment, with
    the time it has been waiting (keyboxes.needs_change_since, kept by a trigger so every path that marks a code
    "needs_change" is covered), until a new code is saved. The staff screens show it on every page (fn_keybox_alerts).
  * Housekeeping may now change a code, and see the current one (needed to open the box and set the new
    combination) — never for a unit with a guest in house. Owner, manager and supervisor keep full access.
    Every view and every change is in the audit trail, with before/after; the code itself never is.
  * Saving the same code as the current one is refused (CODE_MUST_DIFFER_FROM_PREVIOUS, unchanged — now for
    housekeeping too). A code is 4 to 8 digits.
  * Confirming the field test of a code that still has to change is refused instead of answering ok without effect.
  * Housekeeping still cannot read the keyboxes table itself (RLS unchanged): the screen reads fn_keybox_board.

The code release to a guest is unchanged: fn_evaluate_access already refuses while the code needs a change or has
not been tested on the box.
*/

-- ---------------------------------------------------------------------------------------------------------------
-- 1. Since when a code has been waiting for its change
-- ---------------------------------------------------------------------------------------------------------------
alter table keyboxes add column if not exists needs_change_since timestamptz;
grant select (needs_change_since) on keyboxes to authenticated;

-- codes already waiting: since the last departure from the unit (or the last change, or now)
update keyboxes k
   set needs_change_since = coalesce(greatest((select max(r.actual_check_out) from reservations r where r.room_id = k.room_id and r.status = 'checked_out'),
                                              k.last_changed_at), k.created_at, now())
 where k.code_status = 'needs_change' and k.needs_change_since is null;

create or replace function fn_keybox_track_change() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.code_status = 'needs_change' then
    if tg_op = 'UPDATE' and old.code_status is distinct from 'needs_change' then
      new.needs_change_since := now();
    else
      new.needs_change_since := coalesce(new.needs_change_since, now());
    end if;
  else
    new.needs_change_since := null;
  end if;
  return new;
end $$;
revoke all on function fn_keybox_track_change() from public, anon, authenticated;

create or replace trigger trg_keybox_track_change before insert or update on keyboxes
  for each row execute function fn_keybox_track_change();

-- ---------------------------------------------------------------------------------------------------------------
-- 2. A guest is in house in this unit (housekeeping never sees or changes such a unit's code)
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_room_guest_in_house(p_room uuid) returns boolean
language sql stable set search_path = public as $$
  select exists (select 1 from reservations where room_id = p_room and status = 'checked_in');
$$;
revoke all on function fn_room_guest_in_house(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 3. The screen: every active unit of the branch with the state of its code (never the code)
--    state: change (red: must be changed) · untested (amber: new code not yet tried on the box) · ok (green) ·
--           none (no key box registered for the unit yet)
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_keybox_board(p_branch uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare v_full boolean;
begin
  perform fn_require_role('owner','manager','supervisor','housekeeping');
  perform fn_require_branch(p_branch);
  v_full := fn_has_role('owner','manager','supervisor');
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'room_id', u.id, 'room_number', u.room_number, 'block', u.block_name, 'floor', u.floor_name,
             'room_status', u.status, 'cleanliness', u.cleanliness, 'guest_in_house', u.in_house,
             'state', u.state, 'has_code', u.has_code, 'code_version', u.code_version, 'field_tested', u.field_tested,
             'needs_change_since', u.needs_change_since, 'last_changed_at', u.last_changed_at, 'last_changed_by', u.changed_by,
             'can_change', v_full or not u.in_house,
             'can_view', u.has_code and (v_full or not u.in_house))
           order by u.room_number)
    from (
      select rm.id, rm.room_number, b.name as block_name, f.name as floor_name, rm.status, rm.cleanliness,
             fn_room_guest_in_house(rm.id) as in_house,
             case when kb.id is null then 'none'
                  when kb.code_status <> 'active' or kb.code_encrypted is null then 'change'
                  when not kb.field_tested then 'untested'
                  else 'ok' end as state,
             kb.code_encrypted is not null as has_code, kb.code_version, coalesce(kb.field_tested, false) as field_tested,
             kb.needs_change_since, kb.last_changed_at, s.full_name as changed_by
        from rooms rm
        left join keyboxes kb on kb.room_id = rm.id
        left join blocks b on b.id = rm.block_id
        left join floors f on f.id = rm.floor_id
        left join staff_profiles s on s.id = kb.last_changed_by
       where rm.branch_id = p_branch and rm.archived_at is null and rm.is_active
    ) u), '[]'::jsonb);
end $$;
revoke all on function fn_keybox_board(uuid) from public, anon;
grant execute on function fn_keybox_board(uuid) to authenticated;

-- The red alert on every staff page: units of the branch whose code must still be changed.
create or replace function fn_keybox_alerts(p_branch uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform fn_require_role('owner','manager','supervisor','housekeeping');
  perform fn_require_branch(p_branch);
  return (
    select jsonb_build_object('count', count(*), 'oldest_since', min(kb.needs_change_since),
             'rooms', coalesce(jsonb_agg(rm.room_number order by kb.needs_change_since nulls last, rm.room_number), '[]'::jsonb))
      from keyboxes kb join rooms rm on rm.id = kb.room_id
     where kb.branch_id = p_branch and rm.archived_at is null and rm.is_active
       and (kb.code_status <> 'active' or kb.code_encrypted is null));
end $$;
revoke all on function fn_keybox_alerts(uuid) from public, anon;
grant execute on function fn_keybox_alerts(uuid) to authenticated;

-- The current code, for the person who opens the box to set the new one. Audited (the version, never the code).
create or replace function fn_keybox_reveal(p_room uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare rm rooms%rowtype; kb keyboxes%rowtype; v_in_house boolean;
begin
  perform fn_require_role('owner','manager','supervisor','housekeeping');
  select * into rm from rooms where id = p_room and archived_at is null;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  perform fn_require_branch(rm.branch_id);
  v_in_house := fn_room_guest_in_house(p_room);
  if v_in_house and not fn_has_role('owner','manager','supervisor') then
    raise exception 'GUEST_IN_HOUSE' using errcode = '42501';
  end if;
  select * into kb from keyboxes where room_id = p_room limit 1;
  if not found or kb.code_encrypted is null then raise exception 'NO_KEYBOX_CODE'; end if;
  perform fn_audit_change(rm.branch_id, 'keybox.code_viewed', 'room', p_room, null,
    jsonb_build_object('code_version', kb.code_version, 'code_status', kb.code_status, 'guest_in_house', v_in_house), null);
  return jsonb_build_object('ok', true, 'code', pgp_sym_decrypt(kb.code_encrypted, fn_secret('keybox_key')), 'code_version', kb.code_version);
end $$;
revoke all on function fn_keybox_reveal(uuid) from public, anon;
grant execute on function fn_keybox_reveal(uuid) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 4. Changing a code: housekeeping too (not with a guest in house); the same code is refused
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_staff_rotate_keybox_code(p_room uuid, p_new_code text, p_field_tested boolean) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare kb keyboxes%rowtype; rm rooms%rowtype; st room_status; v_in_house boolean; v_tested boolean := coalesce(p_field_tested, false);
        v_before jsonb; v_version int;
begin
  perform fn_require_role('owner','manager','supervisor','housekeeping');
  select * into rm from rooms where id = p_room;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  perform fn_require_branch(rm.branch_id);
  v_in_house := fn_room_guest_in_house(p_room);
  if v_in_house and not fn_has_role('owner','manager','supervisor') then
    raise exception 'GUEST_IN_HOUSE' using errcode = '42501';
  end if;
  if p_new_code is null or p_new_code !~ '^\d{4,8}$' then raise exception 'VALIDATION: code_must_be_4_to_8_digits'; end if;

  select * into kb from keyboxes where room_id = p_room limit 1 for update;
  if not found then
    v_before := jsonb_build_object('code_status', 'none');
    insert into keyboxes(room_id, branch_id, code_encrypted, code_version, code_status, last_changed_at, last_changed_by, field_tested, requires_rotation)
    values (p_room, rm.branch_id, pgp_sym_encrypt(p_new_code, fn_secret('keybox_key')), 1, 'active', now(), fn_staff_id(), v_tested, true)
    returning * into kb;
    v_version := 1;
    insert into code_rotation_events(keybox_id, room_id, from_version, to_version, rotated_by, field_tested) values (kb.id, p_room, null, 1, fn_staff_id(), v_tested);
  else
    v_before := jsonb_build_object('code_version', kb.code_version, 'code_status', kb.code_status, 'field_tested', kb.field_tested,
                                   'needs_change_since', kb.needs_change_since);
    if kb.code_encrypted is not null and pgp_sym_decrypt(kb.code_encrypted, fn_secret('keybox_key')) = p_new_code then
      raise exception 'CODE_MUST_DIFFER_FROM_PREVIOUS';
    end if;
    v_version := kb.code_version + 1;
    update keyboxes set code_encrypted = pgp_sym_encrypt(p_new_code, fn_secret('keybox_key')), code_version = v_version,
      code_status = 'active', last_changed_at = now(), last_changed_by = fn_staff_id(), field_tested = v_tested, last_reservation_id = null
    where id = kb.id;
    insert into code_rotation_events(keybox_id, room_id, from_version, to_version, rotated_by, field_tested) values (kb.id, p_room, kb.code_version, v_version, fn_staff_id(), v_tested);
  end if;
  st := fn_recompute_room_ready(p_room);
  perform fn_audit_change(rm.branch_id, 'rotate_keybox_code', 'room', p_room, v_before,
    jsonb_build_object('code_version', v_version, 'code_status', 'active', 'field_tested', v_tested, 'room_status', st, 'guest_in_house', v_in_house), null);
  return jsonb_build_object('ok', true, 'room_status', st, 'code_version', v_version);
end $$;
grant execute on function fn_staff_rotate_keybox_code(uuid, text, boolean) to authenticated;

create or replace function fn_staff_mark_keybox_tested(p_room uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare rm rooms%rowtype; kb keyboxes%rowtype; st room_status; v_in_house boolean;
begin
  perform fn_require_role('owner','manager','supervisor','housekeeping');
  select * into rm from rooms where id = p_room;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  perform fn_require_branch(rm.branch_id);
  v_in_house := fn_room_guest_in_house(p_room);
  if v_in_house and not fn_has_role('owner','manager','supervisor') then
    raise exception 'GUEST_IN_HOUSE' using errcode = '42501';
  end if;
  select * into kb from keyboxes where room_id = p_room limit 1 for update;
  if not found or kb.code_encrypted is null then raise exception 'NO_KEYBOX_CODE'; end if;
  if kb.code_status <> 'active' then raise exception 'CODE_NEEDS_CHANGE'; end if;   -- the test is of the new code
  update keyboxes set field_tested = true where id = kb.id;
  st := fn_recompute_room_ready(p_room);
  perform fn_audit_change(rm.branch_id, 'keybox_field_tested', 'room', p_room, jsonb_build_object('field_tested', kb.field_tested),
    jsonb_build_object('field_tested', true, 'code_version', kb.code_version, 'room_status', st), null);
  return jsonb_build_object('ok', true, 'room_status', st);
end $$;
grant execute on function fn_staff_mark_keybox_tested(uuid) to authenticated;
