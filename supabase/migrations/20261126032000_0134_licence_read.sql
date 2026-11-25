-- LOCAL CANDIDATE v2, UNADOPTED. Companion to the licence-edit candidate: who READS the licence number.
-- Basis: user's native reply 06:12:33 (whoever holds room-edit permission may edit the licence) and the per-page model.
-- Existing reads are PRESERVED unchanged (0110 wrapper: rooms View, then the 0075 role list owner/manager/supervisor).
-- ADDED: an individual non-owner account whose role is not on that list, but who holds /admin/rooms EDIT, may read it (needed to edit it).
create or replace function fn_room_licenses(p_branch uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if fn_staff_id() is not null and fn_current_role() <> 'owner' and fn_user_access_mode() = 'individual'
     and not fn_has_role('owner', 'manager', 'supervisor') then
    perform fn_require_user_page('/admin/rooms', 'edit');
    perform fn_require_branch(p_branch);
    return coalesce((
      select jsonb_agg(jsonb_build_object('room_id', l.room_id, 'license_number', l.license_number, 'updated_at', l.updated_at)
                       order by r.room_number)
        from room_licenses l join rooms r on r.id = l.room_id
       where l.branch_id = p_branch and l.license_number is not null), '[]'::jsonb);
  end if;
  perform public.fn_require_user_page('/admin/rooms', 'view');
  return public.fn_room_licenses__impl(p_branch);
end $$;
revoke all on function fn_room_licenses(uuid) from public, anon;
grant execute on function fn_room_licenses(uuid) to authenticated;
