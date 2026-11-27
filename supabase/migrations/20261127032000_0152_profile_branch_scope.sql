-- 0152: a booking can only reuse a guest profile the caller is allowed to see (branch grant), by explicit id or by phone.
-- Otherwise a new profile is made (nothing is merged or changed on existing records). Patched from the live definition.
CREATE OR REPLACE FUNCTION public.fn_staff_create_reservation_unit(p jsonb, p_group_ref text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_branch uuid := (p->>'branch_id')::uuid; v_cat uuid := (p->>'category_id')::uuid; v_room uuid := (p->>'room_id')::uuid;
        ci date := (p->>'check_in')::date; co date := (p->>'check_out')::date; src booking_sources%rowtype; q jsonb; r reservations%rowtype; b branches%rowtype;
        gp guest_profiles%rowtype; v_phone text := nullif(trim(p->>'guest_phone'),''); v_name text := trim(p->>'guest_name'); v_status reservation_status; ext text := nullif(trim(p->>'external_ref'),'');
        v_adults int := coalesce((p->>'adults')::int, 1); v_comp int := coalesce((p->>'companions')::int, 0); cap int;
        v_details jsonb := coalesce(p->'companions_details', '[]'::jsonb); d jsonb; v_arr time; v_dep time;
        v_disc bigint := coalesce(nullif(p->>'discount_halalas', '')::bigint, 0); v_ovr bigint := nullif(p->>'nightly_rate_halalas', '')::bigint;
        v_profile uuid := nullif(p->>'guest_profile_id', '')::uuid; v_new_profile boolean := coalesce((p->>'new_profile')::boolean, false);
        v_collects boolean; v_booked date; platform boolean; f jsonb; vch jsonb; v_con text;
begin
  perform fn_require_cap('res.create');
  perform fn_require_branch(v_branch);
  select * into b from branches where id = v_branch;
  if ci is null or co is null or co <= ci then raise exception 'VALIDATION: dates'; end if;
  if coalesce(v_name,'') = '' then raise exception 'VALIDATION: guest_name'; end if;
  perform fn_check_person_name(v_name);                                     -- 0047: letters only
  v_phone := fn_check_phone(v_phone, v_profile is null);                   -- 0047: required and well formed (a chosen profile lends its own)
  if jsonb_typeof(v_details) <> 'array' then raise exception 'VALIDATION: companions_details'; end if;
  -- companions: the detailed list wins over a bare count (never fewer rows than people declared)
  if jsonb_array_length(v_details) > v_comp then v_comp := jsonb_array_length(v_details); end if;
  if v_adults < 1 or v_comp < 0 then raise exception 'VALIDATION: guests'; end if;
  for d in select * from jsonb_array_elements(v_details) loop
    if coalesce(trim(d->>'full_name'),'') = '' then raise exception 'VALIDATION: companion_name'; end if;
    perform fn_check_person_name(trim(d->>'full_name'));
    perform fn_check_phone(nullif(trim(d->>'phone'),''), false);
  end loop;
  begin
    v_arr := coalesce(nullif(p->>'arrival_time','')::time, b.check_in_time);
    v_dep := coalesce(nullif(p->>'departure_time','')::time, b.check_out_time);
  exception when others then raise exception 'VALIDATION: times'; end;
  select * into src from booking_sources where id = (p->>'source_id')::uuid and organization_id = fn_user_org_id() and is_active;
  if not found then raise exception 'VALIDATION: source'; end if;
  if src.external_reference_required and ext is null then raise exception 'VALIDATION: external_ref_required'; end if;
  -- decision 4: a platform's booking says who collects and when it was booked there
  platform := src.kind = 'external';
  if platform then
    if (p->>'platform_collects') is null then raise exception 'VALIDATION: platform_collects'; end if;
    v_collects := (p->>'platform_collects')::boolean;
    begin v_booked := nullif(p->>'platform_booked_on', '')::date; exception when others then raise exception 'VALIDATION: platform_booked_on'; end;
    if v_booked is null or v_booked > fn_branch_today(v_branch) or v_booked < ci - 730 then raise exception 'VALIDATION: platform_booked_on'; end if;
  end if;
  -- decision 69: one platform number per booking or group (the units of a group share it)
  if ext is not null and exists (select 1 from reservations x where x.organization_id = fn_user_org_id() and x.source_id = src.id and x.external_ref = ext
                                   and coalesce(x.group_ref, x.id::text) <> coalesce(p_group_ref, '-')) then
    raise exception 'DUPLICATE_EXTERNAL_REF';
  end if;
  select max_capacity into cap from room_categories where id = v_cat and branch_id = v_branch and archived_at is null;
  if cap is null then raise exception 'BRANCH_MISMATCH: category'; end if;
  if v_adults + v_comp > cap then raise exception 'CAPACITY_EXCEEDED'; end if;

  -- the stay's nights from the calendar (or the weekly / monthly price), the platform row for a platform booking
  q := fn_quote_stay(jsonb_build_object('branch_id', v_branch, 'category_id', v_cat, 'check_in', ci, 'check_out', co, 'source_id', src.id,
                                        'nightly_rate_halalas', v_ovr, 'discount_halalas', v_disc));
  -- a manual nightly price under what the stay would cost is a discount by another name: the owner's or a manager's
  if v_ovr is not null and (q->>'rent_gross')::bigint < (q->>'computed_rent')::bigint and not fn_has_role('owner','manager') then
    raise exception 'FORBIDDEN: rate below the quoted price requires manager';
  end if;
  if v_disc > 0 and coalesce(trim(p->>'discount_reason'), '') = '' then raise exception 'VALIDATION: discount_reason'; end if;
  perform fn_check_discount(v_cat, v_branch, (q->>'nights')::int, (q->>'rent_gross')::bigint, 0, v_disc, false);
  v_status := case when coalesce((p->>'confirm')::boolean, true) then 'confirmed' else 'pending_verification' end;

  -- the guest profile: the one chosen, else the one with this phone, else a new one (never matched by name alone, never merged)
  if v_profile is not null then
    select * into gp from guest_profiles where id = v_profile and organization_id = fn_user_org_id() and fn_profile_visible(id);   -- 0152: only a profile this staff member may see
    if not found then raise exception 'VALIDATION: guest_profile'; end if;
    if v_phone is null then v_phone := fn_check_phone(gp.phone, true); end if;   -- 0047: the profile's phone, itself valid
  elsif not v_new_profile and v_phone is not null then
    select * into gp from guest_profiles where organization_id = fn_user_org_id() and fn_profile_visible(id)   -- 0152: never link to a profile of a branch the caller cannot see
       and (phone = v_phone or (fn_normalize_phone(v_phone) is not null and fn_normalize_phone(phone) = fn_normalize_phone(v_phone)))
     order by created_at limit 1;
  end if;
  if gp.id is null then
    insert into guest_profiles(organization_id, full_name, phone, nationality) values (fn_user_org_id(), v_name, v_phone, p->>'nationality') returning * into gp;
  end if;

  insert into reservations(organization_id, branch_id, external_ref, source_id, status, booking_type, company_name, visit_purpose, check_in, check_out, adults, companions,
                           room_category_id, nightly_rate_halalas, price_basis, notes, created_by, identity_status, payment_status, expected_arrival_time, expected_departure_time, group_ref,
                           platform_booked_on, platform_collects)
  values (fn_user_org_id(), v_branch, ext, src.id, v_status, coalesce(p->>'booking_type','individual'), p->>'company_name', p->>'visit_purpose', ci, co, v_adults, v_comp,
          v_cat, (q->>'nightly_rate')::bigint, q->>'basis', p->>'notes', fn_staff_id(), 'not_started', 'pending', v_arr, v_dep, p_group_ref,
          case when platform then v_booked end, case when platform then v_collects end) returning * into r;

  insert into reservation_guests(reservation_id, guest_profile_id, is_primary, full_name, phone, nationality) values (r.id, gp.id, true, v_name, v_phone, p->>'nationality');
  -- companions: identity stays 'not_started' until the document is matched at arrival (G-identity)
  for d in select * from jsonb_array_elements(v_details) loop
    insert into reservation_guests(reservation_id, is_primary, full_name, relationship, nationality, phone)
    values (r.id, false, trim(d->>'full_name'), nullif(trim(d->>'relationship'),''), nullif(trim(d->>'nationality'),''), fn_check_phone(nullif(trim(d->>'phone'),''), false));
  end loop;

  perform fn_book_nights(r.id, q->'runs', 'إيجار');
  if v_disc > 0 then
    perform fn_add_charge(r.id, 'discount', trim(p->>'discount_reason'), 1, v_disc, true, trim(p->>'discount_reason'));
  end if;
  if v_room is not null then
    if not fn_room_available(v_room, ci, co) then raise exception 'ROOM_NOT_AVAILABLE'; end if;
    perform fn_allocate(r.id, v_room, ci, co, 'create');
  end if;
  f := fn_recompute_reservation_finance(r.id);
  -- decision 4: the platform collected the stay → its receipt «آجل عبر المنصات», matched later against the platform's deposit
  if platform and v_collects and (f->>'total')::bigint > 0 then
    vch := fn_create_voucher(jsonb_build_object('kind', 'receipt', 'reservation_id', r.id, 'amount_halalas', (f->>'total')::bigint, 'method', 'ota_deferred',
                                                'reference', ext, 'note', 'قبضته المنصة عند الحجز', 'idempotency_key', 'platform-collect:' || r.id));
  end if;
  perform fn_audit_change(r.branch_id, 'reservation.created', 'reservation', r.id, null,
    jsonb_build_object('internal_ref', r.internal_ref, 'source', src.code, 'external_ref', ext, 'check_in', ci, 'check_out', co, 'room_id', v_room, 'quote', q,
                       'arrival_time', v_arr, 'departure_time', v_dep, 'companions', v_comp, 'group_ref', p_group_ref, 'guest_profile_id', gp.id,
                       'platform_booked_on', r.platform_booked_on, 'platform_collects', r.platform_collects, 'platform_voucher', vch->>'number'));
  return jsonb_build_object('ok', true, 'id', r.id, 'internal_ref', r.internal_ref, 'quote', q, 'group_ref', p_group_ref, 'guest_profile_id', gp.id,
                            'platform_voucher', vch->>'number');
exception when unique_violation or exclusion_violation then
  get stacked diagnostics v_con = constraint_name;
  if v_con in ('uniq_reservation_source_ref', 'excl_reservation_source_ref') then raise exception 'DUPLICATE_EXTERNAL_REF'; end if;
  raise;
end $function$;
