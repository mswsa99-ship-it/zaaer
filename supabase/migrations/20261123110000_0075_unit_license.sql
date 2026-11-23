-- ============================================================================================================
-- 0075 — The unit's licence number (owner, 23 Nov 2026; plan item 1.8): a field in the unit's data that the owner,
-- the manager and the supervisor read, and no one else — not the guest, not the finance desk, not housekeeping.
--
-- It lives in a table of its own that no role reads directly, written and read only through the two functions
-- below, so no function that already returns a unit's row (the units board, the guest pages, the tasks, the reports,
-- the log of a unit's changes) can ever carry it:
--   fn_room_licenses(branch)                the owner, the manager and the supervisor of that branch: each unit's
--                                           licence number in the branch.
--   fn_admin_set_room_license(room, number) the same three roles, when the matrix also lets them edit the units
--                                           («definitions»): sets, changes or clears it. The change is in the log as
--                                           «room.license_set», with the number's last four characters only.
-- A number is Latin letters, digits, «-» and «/», 1 to 40 characters; Arabic-Indic digits are read as Latin and
-- letters are kept in capitals; an empty number clears it. No row of any other table is changed.
-- ============================================================================================================

create table if not exists room_licenses (
  room_id uuid primary key references rooms(id),
  organization_id uuid not null references organizations(id),
  branch_id uuid not null references branches(id),
  license_number text check (license_number is null or (char_length(license_number) between 1 and 40 and license_number ~ '^[A-Z0-9][A-Z0-9/-]*$')),
  updated_by uuid references staff_profiles(id),
  updated_at timestamptz not null default now()
);
create index if not exists room_licenses_branch_idx on room_licenses(branch_id);
alter table room_licenses enable row level security;
-- no policy and no grant: the table is read and written only through the functions below
revoke all on table room_licenses from public, anon, authenticated;

create or replace function fn_room_licenses(p_branch uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not fn_has_role('owner', 'manager', 'supervisor') then raise exception 'FORBIDDEN: licence' using errcode = '42501'; end if;
  perform fn_require_branch(p_branch);
  return coalesce((
    select jsonb_agg(jsonb_build_object('room_id', l.room_id, 'license_number', l.license_number, 'updated_at', l.updated_at)
                     order by r.room_number)
      from room_licenses l join rooms r on r.id = l.room_id
     where l.branch_id = p_branch and l.license_number is not null), '[]'::jsonb);
end $$;
revoke all on function fn_room_licenses(uuid) from public, anon;
grant execute on function fn_room_licenses(uuid) to authenticated;

create or replace function fn_admin_set_room_license(p_room uuid, p_number text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r rooms%rowtype; v text; old text;
begin
  if not fn_has_role('owner', 'manager', 'supervisor') then raise exception 'FORBIDDEN: licence' using errcode = '42501'; end if;
  perform fn_require_cap('definitions');
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

-- the log reads the change in Arabic (src/lib/auditLabels.ts carries the same line; tests/unit/audit_labels.test.ts AB10 diffs them)
create or replace function fn_audit_unit_label(p_action text) returns text
language sql immutable set search_path = public as $$
  select case p_action
      when 'room.license_set' then 'تعديل رقم ترخيص الوحدة'
      else null
    end;
$$;
revoke all on function fn_audit_unit_label(text) from public, anon;
grant execute on function fn_audit_unit_label(text) to authenticated, service_role;

-- fn_audit_action_label asks it after the account events (0074's way: one line added to the definition in force, once)
do $$
declare fn oid; def text; n int;
        old_p constant text := $a$    fn_audit_account_label(p_action),$a$;
        new_p constant text := $b$    fn_audit_account_label(p_action),
    fn_audit_unit_label(p_action),$b$;
begin
  select p.oid into fn from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'fn_audit_action_label';
  def := pg_get_functiondef(fn);
  if position('fn_audit_unit_label(p_action)' in def) > 0 then return; end if;
  n := (length(def) - length(replace(def, old_p, ''))) / length(old_p);
  if n <> 1 then raise exception '0075: the account line of fn_audit_action_label was found % times, not once', n; end if;
  execute replace(def, old_p, new_p);
end $$;
