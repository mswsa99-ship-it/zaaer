-- =====================================================================
-- 0047 — Data that enters right (correction batch 1: B1, B3, B13; the owner's notes 1, 4 and 14, decisions 2 and 6).
--   * A person's name is letters only (Arabic or Latin, with spaces, hyphen, apostrophe, dot); the main guest's
--     phone is required at booking; every phone is a Saudi mobile (05 + 8 digits, also written +9665…/9665…/5…)
--     or an international number (+ or 00, 8–15 digits); Arabic-Indic digits are read as digits.
--   * A national ID is 10 digits starting 1; an iqama 10 digits starting 2.
--   * No guest — main or companion — younger than 15 on the day of entry, from the office or the guest's own link.
--   * No two key boxes of one branch take the same code (a code in a box still counts until it is changed); the
--     refusal does not say which unit has it.
--   Changes no data: rows already stored keep their values; the rules apply to every write from now on.
-- =====================================================================

-- Arabic-Indic and Persian digits as 0–9; null stays null
create or replace function fn_latin_digits(p text) returns text
language sql immutable set search_path = public as $$
  select translate(p, '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹', '01234567890123456789');
$$;
revoke all on function fn_latin_digits(text) from public, anon, authenticated;

-- a person's name: letters (Arabic or Latin), spaces, hyphen, apostrophe, dot; at least two letters
create or replace function fn_check_person_name(p text) returns void
language plpgsql immutable set search_path = public as $$
begin
  if p is null or btrim(p) = '' then return; end if;
  if p !~ '^[A-Za-z\u00C0-\u00D6\u00D8-\u00F6\u00F8-\u024F\u0621-\u063A\u0640-\u0652\u0670-\u06D3 ''’.-]+$'
     or length(regexp_replace(p, '[^A-Za-z\u00C0-\u00D6\u00D8-\u00F6\u00F8-\u024F\u0621-\u063A\u0641-\u064A\u0671-\u06D3]', '', 'g')) < 2 then
    raise exception 'VALIDATION: name_letters_only';
  end if;
end $$;
revoke all on function fn_check_person_name(text) from public, anon, authenticated;

-- a phone as it is kept: 05XXXXXXXX for a Saudi mobile, +<digits> for any other country; null when empty and not required
create or replace function fn_check_phone(p text, p_required boolean) returns text
language plpgsql immutable set search_path = public as $$
declare d text;
begin
  d := regexp_replace(fn_latin_digits(coalesce(p, '')), '[\s()-]', '', 'g');
  if d = '' then
    if p_required then raise exception 'VALIDATION: phone_required'; end if;
    return null;
  end if;
  if d ~ '^\+' then d := '00' || substr(d, 2); end if;
  if d !~ '^\d+$' then raise exception 'VALIDATION: phone_format'; end if;
  if d ~ '^05\d{8}$' then null;
  elsif d ~ '^5\d{8}$' then d := '0' || d;
  elsif d ~ '^(00)?9665\d{8}$' then d := '0' || right(d, 9);
  elsif d ~ '^00[1-9]\d{7,14}$' and d !~ '^00966' then d := '+' || substr(d, 3);
  else raise exception 'VALIDATION: phone_format';
  end if;
  return d;
end $$;
revoke all on function fn_check_phone(text, boolean) from public, anon, authenticated;

-- no one younger than 15 on the day the data is entered
create or replace function fn_check_min_age(p_birth date, p_today date) returns void
language plpgsql immutable set search_path = public as $$
begin
  if p_birth is not null and p_birth > (p_today - interval '15 years')::date then raise exception 'VALIDATION: minimum_age_15'; end if;
end $$;
revoke all on function fn_check_min_age(date, date) from public, anon, authenticated;

create or replace function fn_check_identity(p_type identity_type, p_number text)
returns void language plpgsql immutable set search_path = public as $$
begin
  if p_type = 'national_id' and p_number !~ '^1\d{9}$' then raise exception 'VALIDATION: identity_number_format'; end if;   -- 0047: 1… for a citizen
  if p_type = 'iqama' and p_number !~ '^2\d{9}$' then raise exception 'VALIDATION: identity_number_format'; end if;         -- 0047: 2… for a resident
  if p_type = 'gcc_id' and p_number !~ '^[A-Za-z0-9]{6,15}$' then raise exception 'VALIDATION: identity_number_format'; end if;
  if p_type = 'passport' and p_number !~ '^[A-Za-z0-9]{5,12}$' then raise exception 'VALIDATION: identity_number_format'; end if;
end $$;

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
    select * into gp from guest_profiles where id = v_profile and organization_id = fn_user_org_id();
    if not found then raise exception 'VALIDATION: guest_profile'; end if;
    if v_phone is null then v_phone := fn_check_phone(gp.phone, true); end if;   -- 0047: the profile's phone, itself valid
  elsif not v_new_profile and v_phone is not null then
    select * into gp from guest_profiles where organization_id = fn_user_org_id()
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

CREATE OR REPLACE FUNCTION public.fn_staff_enter_guest(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare r reservations%rowtype; g reservation_guests%rowtype; v_guest uuid := nullif(p->>'guest_id', '')::uuid;
        v_name text := trim(coalesce(p->>'full_name', '')); v_type identity_type; v_number text := regexp_replace(fn_latin_digits(coalesce(p->>'identity_number', '')), '\s', '', 'g');
        v_nat text := trim(coalesce(p->>'nationality', '')); v_birth date; v_phone text := fn_check_phone(nullif(trim(coalesce(p->>'phone', '')), ''), false);
        v_rel text := nullif(trim(coalesce(p->>'relationship', '')), ''); v_issue text := nullif(trim(coalesce(p->>'identity_issue_number', '')), '');
        v_reason text := nullif(trim(coalesce(p->>'reason', '')), ''); fp text; before jsonb; correcting boolean := false; cnt int; new_id uuid; st guest_verification_status;
begin
  perform fn_require_cap('guest.enter');
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.status in ('cancelled', 'rejected', 'closed', 'checked_out', 'no_show') then raise exception 'RESERVATION_NOT_EDITABLE'; end if;
  if coalesce((p->>'document_matched')::boolean, false) is not true then raise exception 'VALIDATION: document_matched'; end if;
  if array_length(regexp_split_to_array(v_name, '\s+'), 1) < 3 then raise exception 'VALIDATION: full_name_three_parts'; end if;
  perform fn_check_person_name(v_name);
  begin v_type := (p->>'identity_type')::identity_type; exception when others then raise exception 'VALIDATION: identity_type'; end;
  if v_type is null then raise exception 'VALIDATION: identity_type'; end if;
  if v_guest is not null then
    select * into g from reservation_guests where id = v_guest and reservation_id = r.id for update;
    if not found then raise exception 'GUEST_NOT_FOUND'; end if;
    correcting := g.data_submitted;
  end if;
  if v_number = '' then
    -- keep the number on file: only for a correction of the same kind of document
    if not correcting or g.identity_number_encrypted is null or v_type is distinct from g.identity_type then raise exception 'VALIDATION: identity_number_format'; end if;
    fp := g.identity_fingerprint;
  else
    perform fn_check_identity(v_type, v_number);
    fp := fn_identity_fingerprint(v_type, v_number);
  end if;
  if v_nat = '' then raise exception 'VALIDATION: nationality'; end if;
  begin v_birth := (p->>'birth_date')::date; exception when others then raise exception 'VALIDATION: birth_date'; end;
  if v_birth is null or v_birth > fn_branch_today(r.branch_id) or v_birth < fn_branch_today(r.branch_id) - interval '120 years' then raise exception 'VALIDATION: birth_date_range'; end if;
  perform fn_check_min_age(v_birth, fn_branch_today(r.branch_id));        -- 0047: no one under 15, main guest or companion
  if correcting and v_reason is null then raise exception 'VALIDATION: reason'; end if;
  if exists (select 1 from reservation_guests x where x.reservation_id = r.id and x.identity_fingerprint = fp and x.id is distinct from v_guest) then
    raise exception 'DUPLICATE_GUEST';
  end if;

  if v_guest is not null then
    before := fn_guest_masked(g.id);
    if g.is_primary and v_phone is null then v_phone := g.phone; end if;
    update reservation_guests set full_name = v_name, identity_type = v_type,
      identity_number_encrypted = case when v_number = '' then identity_number_encrypted else pgp_sym_encrypt(v_number, fn_secret('identity_key')) end,
      identity_number_last4 = case when v_number = '' then identity_number_last4 else right(v_number, 4) end,
      identity_issue_number = v_issue, identity_fingerprint = fp, nationality = v_nat, birth_date = v_birth, phone = coalesce(v_phone, phone),
      relationship = case when is_primary then 'self' else coalesce(v_rel, relationship, 'other') end,
      data_submitted = true, verification_status = 'verified', entry_path = 'office', entered_by = fn_staff_id(), entered_at = now(),
      verified_by = fn_staff_id(), verified_at = now()
    where id = g.id;
    new_id := g.id;
  else
    select count(*) into cnt from reservation_guests where reservation_id = r.id;
    if cnt >= r.adults + r.companions then raise exception 'GUEST_LIMIT_REACHED'; end if;
    insert into reservation_guests(reservation_id, is_primary, full_name, identity_type, identity_number_encrypted, identity_number_last4, identity_issue_number,
      nationality, birth_date, phone, relationship, data_submitted, verification_status, identity_fingerprint, entry_path, entered_by, entered_at, verified_by, verified_at)
    values (r.id, false, v_name, v_type, pgp_sym_encrypt(v_number, fn_secret('identity_key')), right(v_number, 4), v_issue, v_nat, v_birth, v_phone,
            coalesce(v_rel, 'other'), true, 'verified', fp, 'office', fn_staff_id(), now(), fn_staff_id(), now())
    returning id into new_id;
  end if;
  perform fn_link_guest_profile(new_id);
  st := fn_rollup_identity(r.id);
  perform fn_audit_change(r.branch_id, case when correcting then 'guest.corrected' else 'guest.entered_from_document' end, 'reservation', r.id,
                          before, fn_guest_masked(new_id), v_reason);
  if correcting then
    perform fn_add_review_item(r.branch_id, 'guest_corrected', 'reservation_guest', new_id, r.id, 'تصحيح بيانات نزيل في ' || r.internal_ref, v_reason,
      jsonb_build_object('before', before, 'after', fn_guest_masked(new_id)));
  end if;
  return jsonb_build_object('ok', true, 'guest_id', new_id, 'identity_status', st);
end $function$;

create or replace function fn_guest_submit(p_token text, p_guest_id uuid, p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  rid uuid := fn_token_reservation(p_token);
  r reservations%rowtype;
  g reservation_guests%rowtype;
  v_name text := trim(coalesce(p_payload->>'full_name',''));
  v_type identity_type;
  v_number text := regexp_replace(fn_latin_digits(coalesce(p_payload->>'identity_number','')), '\s', '', 'g');
  v_nat text := trim(coalesce(p_payload->>'nationality',''));
  v_birth date;
  v_phone text := fn_check_phone(nullif(trim(coalesce(p_payload->>'phone','')), ''), false);
  v_rel text := coalesce(p_payload->>'relationship','other');
  v_issue text := nullif(trim(coalesce(p_payload->>'identity_issue_number','')), '');
  v_ack text := nullif(trim(coalesce(p_payload->>'ack_hash', '')), '');
  fp text; total_required int; current_count int; new_id uuid; st guest_verification_status; before_st guest_verification_status;
begin
  select * into r from reservations where id = rid for update;
  if r.status in ('cancelled','rejected','closed','checked_out','no_show') then raise exception 'RESERVATION_NOT_EDITABLE'; end if;
  before_st := r.identity_status;

  -- validation (server-side, authoritative)
  if array_length(regexp_split_to_array(v_name, '\s+'), 1) < 3 then raise exception 'VALIDATION: full_name_three_parts'; end if;
  perform fn_check_person_name(v_name);
  begin v_type := (p_payload->>'identity_type')::identity_type; exception when others then raise exception 'VALIDATION: identity_type'; end;
  perform fn_check_identity(v_type, v_number);
  if v_nat = '' then raise exception 'VALIDATION: nationality'; end if;
  begin v_birth := (p_payload->>'birth_date')::date; exception when others then raise exception 'VALIDATION: birth_date'; end;
  if v_birth is null or v_birth > fn_branch_today(r.branch_id) or v_birth < fn_branch_today(r.branch_id) - interval '120 years' then raise exception 'VALIDATION: birth_date_range'; end if;
  perform fn_check_min_age(v_birth, fn_branch_today(r.branch_id));
  if coalesce(p_payload->>'consent','false') <> 'true' then raise exception 'VALIDATION: consent_required'; end if;
  fp := fn_identity_fingerprint(v_type, v_number);

  if p_guest_id is not null then
    select * into g from reservation_guests where id = p_guest_id and reservation_id = rid for update;
    if not found then raise exception 'GUEST_NOT_FOUND'; end if;
    if g.verification_status = 'verified' then raise exception 'GUEST_ALREADY_VERIFIED'; end if;
    if g.is_primary and v_phone is null then v_phone := g.phone; end if;
    if g.is_primary and v_phone is null then raise exception 'VALIDATION: phone_required_primary'; end if;
    -- decision 19: the main guest accepts the stay summary when registering (once is enough)
    if g.is_primary and v_ack is null and not exists (select 1 from stay_acknowledgements where reservation_id = rid) then
      raise exception 'VALIDATION: acknowledgement_required';
    end if;
    if exists (select 1 from reservation_guests x where x.reservation_id = rid and x.id <> g.id and x.identity_fingerprint = fp) then raise exception 'DUPLICATE_GUEST'; end if;
    -- the summary the guest read carries their name as it was: it is recorded before their data changes it
    if g.is_primary and v_ack is not null then perform fn_record_ack(rid, g.id, 'electronic', v_ack, null); end if;
    update reservation_guests set
      full_name = v_name, identity_type = v_type,
      identity_number_encrypted = pgp_sym_encrypt(v_number, fn_secret('identity_key')),
      identity_number_last4 = right(v_number, 4), identity_issue_number = v_issue, identity_fingerprint = fp,
      nationality = v_nat, birth_date = v_birth, phone = coalesce(v_phone, phone),
      relationship = case when g.is_primary then 'self' else v_rel end,
      data_submitted = true, verification_status = 'data_submitted',
      entry_path = 'guest', entered_by = null, entered_at = now(), verified_by = null, verified_at = null
    where id = g.id;
    new_id := g.id;
  else
    total_required := r.adults + r.companions;
    select count(*) into current_count from reservation_guests where reservation_id = rid;
    if current_count >= total_required then raise exception 'GUEST_LIMIT_REACHED'; end if;
    -- duplicate companion guard (the same document in the same stay)
    if exists (select 1 from reservation_guests x where x.reservation_id = rid and x.identity_fingerprint = fp) then raise exception 'DUPLICATE_GUEST'; end if;
    insert into reservation_guests (reservation_id, is_primary, full_name, identity_type, identity_number_encrypted, identity_number_last4,
      identity_issue_number, nationality, birth_date, phone, relationship, data_submitted, verification_status, identity_fingerprint, entry_path, entered_at)
    values (rid, false, v_name, v_type, pgp_sym_encrypt(v_number, fn_secret('identity_key')), right(v_number,4),
      v_issue, v_nat, v_birth, v_phone, v_rel, true, 'data_submitted', fp, 'guest', now())
    returning id into new_id;
  end if;

  st := fn_rollup_identity(rid);
  if st = 'pending_supervisor' and before_st is distinct from 'pending_supervisor' then
    insert into notifications(branch_id, audience, title, body, link)
    values (r.branch_id, 'supervisor', 'بيانات نزلاء مكتملة بانتظار المطابقة', 'الحجز ' || r.internal_ref, '/staff/reservations/' || r.id);
  end if;

  perform fn_audit(r.organization_id, r.branch_id, null, 'guest_data_submitted', 'reservation_guest', new_id, jsonb_build_object('reservation_id', rid));
  return jsonb_build_object('ok', true, 'guest_id', new_id);
end $$;

CREATE OR REPLACE FUNCTION public.fn_staff_rotate_keybox_code(p_room uuid, p_new_code text, p_field_tested boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare kb keyboxes%rowtype; rm rooms%rowtype; st room_status; v_in_house boolean; v_tested boolean := coalesce(p_field_tested, false);
        v_before jsonb; v_version int;
begin
  perform fn_require_cap('keybox.code');
  select * into rm from rooms where id = p_room;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  perform fn_require_branch(rm.branch_id);
  v_in_house := fn_room_guest_in_house(p_room);
  if v_in_house and not fn_has_role('owner','manager','supervisor') then
    raise exception 'GUEST_IN_HOUSE' using errcode = '42501';
  end if;
  p_new_code := fn_latin_digits(p_new_code);
  if p_new_code is null or p_new_code !~ '^\d{4,8}$' then raise exception 'VALIDATION: code_must_be_4_to_8_digits'; end if;
  -- 0047: no two boxes of one branch open with the same code; one writer per branch at a time, so two saves cannot both pass
  perform pg_advisory_xact_lock(hashtext('keybox_code:' || rm.branch_id::text));
  if exists (select 1 from keyboxes k where k.branch_id = rm.branch_id and k.room_id <> p_room and k.code_encrypted is not null
               and pgp_sym_decrypt(k.code_encrypted, fn_secret('keybox_key')) = p_new_code) then
    raise exception 'CODE_IN_USE';
  end if;

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
end $function$;
