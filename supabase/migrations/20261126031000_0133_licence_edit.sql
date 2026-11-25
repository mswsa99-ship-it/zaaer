-- LOCAL CANDIDATE, UNADOPTED, UNRUN. Room licence change by an individual non-owner account follows /admin/rooms EDIT. No separate sensitive grant.
-- Provenance only: user reply 2026-11-25 06:12:33 «اللي يملك صلاحيات تعديل الوحدات يقدر يعدله» (wamid ending QUMyOUUwNUNDQzk5QUJDM0QzNzg1NDk0NTJBN0NDQzMA), a reply to the 06:11:28 licence question. Verified from the observation DB.
-- Body = the 0075 text of fn_admin_set_room_license (no later migration redefines it; check) with the gate lines replaced. Needs fn_require_user_page/fn_user_access_mode (0129 era).
create or replace function fn_admin_set_room_license(p_room uuid, p_number text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r rooms%rowtype; v text; old text;
begin
  -- individual non-owner accounts: the licence follows the room page's EDIT permission (user 2026-11-25 06:12:33, original reply to the 06:11:28 question); legacy and owner keep the old role gate and cap
  if fn_staff_id() is not null and fn_current_role() <> 'owner' and fn_user_access_mode() = 'individual' then
    perform fn_require_user_page('/admin/rooms', 'edit');
  else
    if not fn_has_role('owner', 'manager', 'supervisor') then raise exception 'FORBIDDEN: licence' using errcode = '42501'; end if;
    perform fn_require_cap('definitions');
  end if;
  select * into r from rooms where id = p_room;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  -- the characters are checked as typed (ASCII letters only), then kept in capitals
  v := nullif(trim(fn_latin_digits(coalesce(p_number, ''))), '');
  if v is not null and (char_length(v) > 40 or v !~ '^[A-Za-z0-9][A-Za-z0-9/-]*$') then raise exception 'VALIDATION: room_license'; end if;
  v := upper(v);
  select l.license_number into old from room_licenses l where l.room_id = r.id for update;
  if old is not distinct from v then return jsonb_build_object('ok', true, 'unchanged', true, 'license_number', v); end if;
  insert into room_licenses(room_id, organization_id, branch_id, license_number, updated_by, updated_at)
  values (r.id, r.organization_id, r.branch_id, v, fn_staff_id(), now())
  on conflict (room_id) do update set license_number = excluded.license_number, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  -- the log keeps who changed it and when; the number itself only by its last four characters
  perform fn_audit_change(r.branch_id, 'room.license_set', 'room', r.id,
    jsonb_build_object('license_number', case when old is null then null else '…' || right(old, 4) end),
    jsonb_build_object('license_number', case when v is null then null else '…' || right(v, 4) end));
  return jsonb_build_object('ok', true, 'license_number', v);
end $$;
revoke all on function fn_admin_set_room_license(uuid, text) from public, anon;
grant execute on function fn_admin_set_room_license(uuid, text) to authenticated;
