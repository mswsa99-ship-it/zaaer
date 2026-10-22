/*
# 0011 — Reservation creation parity with Zaaer (review item A07)

Zaaer's "create reservation" captures more than one unit per booking, the expected arrival /
departure times, and the companions' details. This migration adds the same capabilities
without weakening any invariant:

  * one reservation row per unit (allocation, finance, status and audit stay per unit — the
    exclusion constraint and the ledger keep working unchanged); units of the same booking share
    a `group_ref` and are created atomically: if one unit cannot be allocated, none is created;
  * `expected_arrival_time` / `expected_departure_time` (default: the branch's check-in/out times);
  * companions as `reservation_guests` rows (not just a count) — their identity verification keeps
    its own lifecycle, exactly as for guests registered later from the guest portal.

fn_staff_create_reservation(p) keeps its contract: the previous payload still works (one unit).
New optional keys: `arrival_time`, `departure_time` ("HH:MM"), `companions_details` [{full_name,
relationship, nationality, phone}], `units` [{category_id, room_id, adults, companions,
companions_details, nightly_rate_halalas}] — when `units` has 2+ entries the reply carries
`ids[]`, `internal_refs[]` and `group_ref`.
*/

alter table reservations add column if not exists expected_arrival_time time;
alter table reservations add column if not exists expected_departure_time time;
alter table reservations add column if not exists group_ref text;
create index if not exists idx_reservations_group on reservations(group_ref) where group_ref is not null;

-- the money column gate (0009) lists the readable columns explicitly: expose the new ones
do $$ begin
  if exists (select 1 from information_schema.column_privileges where table_name = 'reservations' and grantee = 'authenticated' and column_name = 'status')
     and not exists (select 1 from information_schema.role_table_grants where table_name = 'reservations' and grantee = 'authenticated' and privilege_type = 'SELECT') then
    grant select (expected_arrival_time, expected_departure_time, group_ref) on reservations to authenticated;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- one unit (internal)
-- ---------------------------------------------------------------------------
create or replace function fn_staff_create_reservation_unit(p jsonb, p_group_ref text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_branch uuid := (p->>'branch_id')::uuid; v_cat uuid := (p->>'category_id')::uuid; v_room uuid := (p->>'room_id')::uuid;
        ci date := (p->>'check_in')::date; co date := (p->>'check_out')::date; src booking_sources%rowtype; q jsonb; r reservations%rowtype; b branches%rowtype;
        gp guest_profiles%rowtype; v_phone text := nullif(trim(p->>'guest_phone'),''); v_name text := trim(p->>'guest_name'); v_status reservation_status; ext text := nullif(trim(p->>'external_ref'),'');
        v_adults int := coalesce((p->>'adults')::int, 1); v_comp int := coalesce((p->>'companions')::int, 0); cap int;
        v_details jsonb := coalesce(p->'companions_details', '[]'::jsonb); d jsonb; v_arr time; v_dep time;
begin
  perform fn_require_role('owner','manager','supervisor');
  perform fn_require_branch(v_branch);
  select * into b from branches where id = v_branch;
  if ci is null or co is null or co <= ci then raise exception 'VALIDATION: dates'; end if;
  if coalesce(v_name,'') = '' then raise exception 'VALIDATION: guest_name'; end if;
  if jsonb_typeof(v_details) <> 'array' then raise exception 'VALIDATION: companions_details'; end if;
  -- companions: the detailed list wins over a bare count (never fewer rows than people declared)
  if jsonb_array_length(v_details) > v_comp then v_comp := jsonb_array_length(v_details); end if;
  if v_adults < 1 or v_comp < 0 then raise exception 'VALIDATION: guests'; end if;
  for d in select * from jsonb_array_elements(v_details) loop
    if coalesce(trim(d->>'full_name'),'') = '' then raise exception 'VALIDATION: companion_name'; end if;
  end loop;
  begin
    v_arr := coalesce(nullif(p->>'arrival_time','')::time, b.check_in_time);
    v_dep := coalesce(nullif(p->>'departure_time','')::time, b.check_out_time);
  exception when others then raise exception 'VALIDATION: times'; end;
  select * into src from booking_sources where id = (p->>'source_id')::uuid and organization_id = fn_user_org_id() and is_active;
  if not found then raise exception 'VALIDATION: source'; end if;
  if src.external_reference_required and ext is null then raise exception 'VALIDATION: external_ref_required'; end if;
  select max_capacity into cap from room_categories where id = v_cat and branch_id = v_branch and archived_at is null;
  if cap is null then raise exception 'BRANCH_MISMATCH: category'; end if;
  if v_adults + v_comp > cap then raise exception 'CAPACITY_EXCEEDED'; end if;
  if (p->>'discount_halalas')::bigint > 0 and not fn_has_role('owner','manager') then raise exception 'FORBIDDEN: discount requires manager'; end if;
  if (p->>'nightly_rate_halalas') is not null and (p->>'nightly_rate_halalas')::bigint < (select base_price_halalas from room_categories where id = v_cat) and not fn_has_role('owner','manager') then
    raise exception 'FORBIDDEN: rate below base price requires manager';
  end if;

  q := fn_staff_quote(v_branch, v_cat, ci, co, (p->>'nightly_rate_halalas')::bigint, coalesce((p->>'discount_halalas')::bigint, 0));
  v_status := case when coalesce((p->>'confirm')::boolean, true) then 'confirmed' else 'pending_verification' end;

  -- guest profile: reuse by phone within org, never merge by name only
  if v_phone is not null then select * into gp from guest_profiles where organization_id = fn_user_org_id() and phone = v_phone limit 1; end if;
  if gp.id is null then
    insert into guest_profiles(organization_id, full_name, phone, nationality) values (fn_user_org_id(), v_name, v_phone, p->>'nationality') returning * into gp;
  end if;

  insert into reservations(organization_id, branch_id, external_ref, source_id, status, booking_type, company_name, visit_purpose, check_in, check_out, adults, companions,
                           room_category_id, nightly_rate_halalas, notes, created_by, identity_status, payment_status, expected_arrival_time, expected_departure_time, group_ref)
  values (fn_user_org_id(), v_branch, ext, src.id, v_status, coalesce(p->>'booking_type','individual'), p->>'company_name', p->>'visit_purpose', ci, co, v_adults, v_comp,
          v_cat, (q->>'nightly_rate')::bigint, p->>'notes', fn_staff_id(), 'not_started', 'pending', v_arr, v_dep, p_group_ref) returning * into r;

  insert into reservation_guests(reservation_id, guest_profile_id, is_primary, full_name, phone, nationality) values (r.id, gp.id, true, v_name, v_phone, p->>'nationality');
  -- companions: identity stays 'not_started' until the document is matched at arrival (G-identity)
  for d in select * from jsonb_array_elements(v_details) loop
    insert into reservation_guests(reservation_id, is_primary, full_name, relationship, nationality, phone)
    values (r.id, false, trim(d->>'full_name'), nullif(trim(d->>'relationship'),''), nullif(trim(d->>'nationality'),''), nullif(trim(d->>'phone'),''));
  end loop;

  perform fn_add_charge(r.id, 'rent', 'إيجار ' || (q->>'nights') || ' ليلة × ' || ((q->>'nightly_rate')::bigint/100.0) || ' ر.س', (q->>'nights')::numeric, (q->>'nightly_rate')::bigint, true, null);
  if coalesce((p->>'discount_halalas')::bigint, 0) > 0 then
    perform fn_add_charge(r.id, 'discount', coalesce(nullif(p->>'discount_reason',''), 'خصم'), 1, (p->>'discount_halalas')::bigint, true, p->>'discount_reason');
  end if;
  if v_room is not null then
    if not fn_room_available(v_room, ci, co) then raise exception 'ROOM_NOT_AVAILABLE'; end if;
    perform fn_allocate(r.id, v_room, ci, co, 'create');
  end if;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_audit_change(r.branch_id, 'reservation.created', 'reservation', r.id, null,
    jsonb_build_object('internal_ref', r.internal_ref, 'source', src.code, 'external_ref', ext, 'check_in', ci, 'check_out', co, 'room_id', v_room, 'quote', q,
                       'arrival_time', v_arr, 'departure_time', v_dep, 'companions', v_comp, 'group_ref', p_group_ref));
  return jsonb_build_object('ok', true, 'id', r.id, 'internal_ref', r.internal_ref, 'quote', q, 'group_ref', p_group_ref);
exception when unique_violation then
  raise exception 'DUPLICATE_EXTERNAL_REF';
end $$;
revoke all on function fn_staff_create_reservation_unit(jsonb, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- public entry point: one unit (unchanged contract) or several units atomically
-- ---------------------------------------------------------------------------
create or replace function fn_staff_create_reservation(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare units jsonb := p->'units'; u jsonb; res jsonb; first jsonb; ids jsonb := '[]'::jsonb; refs jsonb := '[]'::jsonb; g text; n int;
begin
  perform fn_require_role('owner','manager','supervisor');
  if units is null or jsonb_typeof(units) <> 'array' or jsonb_array_length(units) = 0 then
    return fn_staff_create_reservation_unit(p, null);
  end if;
  n := jsonb_array_length(units);
  if n > 20 then raise exception 'VALIDATION: too many units'; end if;
  if n > 1 then g := 'G-' || upper(substr(md5(gen_random_uuid()::text), 1, 8)); end if;
  for u in select * from jsonb_array_elements(units) loop
    -- unit keys override the booking-level keys (guest, dates, source, notes stay shared)
    res := fn_staff_create_reservation_unit((p - 'units') || u, g);
    if first is null then first := res; end if;
    ids := ids || to_jsonb(res->>'id'); refs := refs || to_jsonb(res->>'internal_ref');
  end loop;
  return first || jsonb_build_object('ids', ids, 'internal_refs', refs, 'group_ref', g, 'units', n);
end $$;
grant execute on function fn_staff_create_reservation(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- group siblings (for the detail page): same booking, other units — scoped by branch access
-- ---------------------------------------------------------------------------
create or replace function fn_reservation_group(p_reservation uuid)
returns table (id uuid, internal_ref text, status reservation_status, room_number text, category_name text, check_in date, check_out date, adults int, companions int)
language sql stable security definer set search_path = public as $$
  select s.id, s.internal_ref, s.status, rm.room_number, rc.name_ar, s.check_in, s.check_out, s.adults, s.companions
  from reservations r
  join reservations s on s.group_ref = r.group_ref and s.organization_id = r.organization_id
  left join rooms rm on rm.id = s.room_id
  left join room_categories rc on rc.id = s.room_category_id
  where r.id = p_reservation and r.group_ref is not null and r.branch_id in (select fn_user_branch_ids())
  order by s.internal_ref;
$$;
revoke all on function fn_reservation_group(uuid) from public, anon;
grant execute on function fn_reservation_group(uuid) to authenticated;
