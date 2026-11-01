-- 0058 — Phase 3b of the 31 October review: the guest's pages, as the owner decided them (1 November 2026).
--
-- GUEST-05 (recommended): a passport or GCC ID holder writes the name as in the document (two parts at least; three for a
--   Saudi ID or a residence permit), and a wrong number is told the rule of its own document.
-- GUEST-07 (recommended): children under 15 are not registered with a document: their ages are asked, they count in
--   the booking's people, they are shown to the supervisor, and they leave the registration target. The main guest
--   gives them on the registration page; the desk can correct them on the booking.

-- ---------------------------------------------------------------------------------------------- GUEST-05 names
create or replace function fn_check_name_parts(p_name text, p_type text) returns void
language plpgsql immutable set search_path = public as $$
begin
  declare short boolean := p_type in ('passport', 'gcc_id');
  begin
    if array_length(regexp_split_to_array(trim(coalesce(p_name, '')), '\s+'), 1) < (case when short then 2 else 3 end) then
      if short then raise exception 'VALIDATION: full_name_two_parts'; else raise exception 'VALIDATION: full_name_three_parts'; end if;
    end if;
  end;
end $$;
revoke all on function fn_check_name_parts(text, text) from public, anon, authenticated;

create or replace function fn_check_identity(p_type identity_type, p_number text)
returns void language plpgsql immutable set search_path = public as $$
begin
  if p_type = 'national_id' and p_number !~ '^1\d{9}$' then raise exception 'VALIDATION: identity_number_format'; end if;   -- 0047: 1… for a citizen
  if p_type = 'iqama' and p_number !~ '^2\d{9}$' then raise exception 'VALIDATION: identity_number_format'; end if;         -- 0047: 2… for a resident
  -- 0058 (GUEST-05): a passport or a GCC ID is told its own rule, not the Saudi one
  if p_type = 'gcc_id' and p_number !~ '^[A-Za-z0-9]{6,15}$' then raise exception 'VALIDATION: identity_number_format_gcc'; end if;
  if p_type = 'passport' and p_number !~ '^[A-Za-z0-9]{5,12}$' then raise exception 'VALIDATION: identity_number_format_passport'; end if;
end $$;

-- ---------------------------------------------------------------------------------------------- GUEST-07 children
alter table reservations add column if not exists children_ages int[] not null default '{}';
do $c$ begin
  if not exists (select 1 from pg_constraint where conname = 'reservations_children_ages_valid') then
    alter table reservations add constraint reservations_children_ages_valid
      check (cardinality(children_ages) <= 20 and 0 <= all(children_ages) and 14 >= all(children_ages));
  end if;
end $c$;
grant select (children_ages) on public.reservations to authenticated;

-- the people the booking registers with a document: everyone but the children under 15 (never fewer than the adults)
create or replace function fn_registration_target(p_reservation uuid) returns int
language sql stable security definer set search_path = public as $$
  select greatest(r.adults, r.adults + r.companions - cardinality(r.children_ages)) from reservations r where r.id = p_reservation;
$$;
revoke all on function fn_registration_target(uuid) from public, anon, authenticated;

-- one place sets the ages: checked, the companions follow (children are companions), the identity rolled up again
create or replace function fn_set_children_internal(p_reservation uuid, p_ages jsonb, p_staff uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; v int[]; x jsonb; n int; before int[];
begin
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  if r.status in ('cancelled', 'rejected', 'closed', 'checked_out', 'no_show') then raise exception 'RESERVATION_NOT_EDITABLE'; end if;
  if p_ages is null or jsonb_typeof(p_ages) <> 'array' or jsonb_array_length(p_ages) > 20 then raise exception 'VALIDATION: children'; end if;
  v := '{}';
  for x in select value from jsonb_array_elements(p_ages) loop
    if jsonb_typeof(x) <> 'number' and (jsonb_typeof(x) <> 'string' or fn_latin_digits(x #>> '{}') !~ '^[0-9]{1,2}$') then raise exception 'VALIDATION: child_age'; end if;
    n := fn_latin_digits(x #>> '{}')::numeric::int;
    if n < 0 or n > 14 then raise exception 'VALIDATION: child_age'; end if;
    v := array_append(v, n);
  end loop;
  -- a child takes a companion's place (the companions grow when there are more children than companions booked);
  -- the documents already registered must still fit what is left to register
  before := r.children_ages;
  update reservations set children_ages = v,
         companions = greatest(companions, cardinality(v)), updated_at = now()
  where id = r.id;
  if (select count(*) from reservation_guests where reservation_id = r.id) > fn_registration_target(r.id) then
    raise exception 'VALIDATION: children_registered';
  end if;
  perform fn_rollup_identity(r.id);
  perform fn_audit(r.organization_id, r.branch_id, p_staff, 'reservation.children_set', 'reservation', r.id,
    jsonb_build_object('before', to_jsonb(before), 'after', to_jsonb(v), 'reason', p_reason));
  return jsonb_build_object('ok', true, 'children_ages', to_jsonb(v), 'target', fn_registration_target(r.id));
end $$;
revoke all on function fn_set_children_internal(uuid, jsonb, uuid, text) from public, anon, authenticated;

create or replace function fn_guest_set_children(p_token text, p_ages jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare rid uuid := fn_token_reservation(p_token); r jsonb;
begin
  r := fn_set_children_internal(rid, p_ages, null, null);
  -- the supervisor sees the children on the booking, and is told
  insert into notifications(branch_id, audience, title, body, link)
  select branch_id, 'supervisor', 'أطفال دون 15 سنة في الحجز', 'الحجز ' || internal_ref || ': ' || cardinality(children_ages) || ' — الأعمار: ' || array_to_string(children_ages, '، '), '/staff/reservations/' || id
  from reservations where id = rid and cardinality(children_ages) > 0;
  return r;
end $$;
revoke all on function fn_guest_set_children(text, jsonb) from public;
grant execute on function fn_guest_set_children(text, jsonb) to anon, authenticated;

create or replace function fn_staff_set_children(p_reservation uuid, p_ages jsonb, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b uuid;
begin
  perform fn_require_cap('guest.enter');
  select branch_id into b from reservations where id = p_reservation;
  perform fn_require_branch(b);
  if coalesce(trim(p_reason), '') = '' then raise exception 'VALIDATION: reason'; end if;
  return fn_set_children_internal(p_reservation, p_ages, fn_staff_id(), trim(p_reason));
end $$;
revoke all on function fn_staff_set_children(uuid, jsonb, text) from public, anon;
grant execute on function fn_staff_set_children(uuid, jsonb, text) to authenticated;

-- what the guest's registration page needs beyond the session: the children and the people to register
create or replace function fn_guest_children(p_token text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('children_ages', to_jsonb(r.children_ages), 'target', fn_registration_target(r.id))
  from reservations r where r.id = fn_token_reservation(p_token);
$$;
revoke all on function fn_guest_children(text) from public;
grant execute on function fn_guest_children(text) to anon, authenticated;

create or replace function fn_rollup_identity(p_reservation uuid)
returns guest_verification_status language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; n int; s int; v int; rj int; req int; st guest_verification_status;
begin
  select * into r from reservations where id = p_reservation;
  select count(*), count(*) filter (where data_submitted), count(*) filter (where verification_status = 'verified'),
         count(*) filter (where verification_status = 'rejected')
    into n, s, v, rj from reservation_guests where reservation_id = p_reservation;
  req := fn_registration_target(p_reservation);                 -- 0058 (GUEST-07)
  st := case when v >= req and v = n and n > 0 then 'verified'
             when rj > 0 then 'rejected'
             when s >= req and s = n and n > 0 then 'pending_supervisor'
             when s > 0 then 'data_submitted'
             else 'not_started' end;
  if st is distinct from r.identity_status then
    update reservations set identity_status = st, updated_at = now() where id = p_reservation;
  end if;
  return st;
end $$;

create or replace function fn_checkin_core_blockers(p_reservation uuid)
returns text[] language plpgsql stable security definer set search_path = public as $$
declare r reservations%rowtype; rm rooms%rowtype; v text[] := '{}'; today date; gc int; sc int; vc int;
begin
  select * into r from reservations where id = p_reservation;
  if not found then return array['الحجز غير موجود']; end if;
  if r.status = 'checked_in' then return array['سُجِّل وصول هذا الحجز مسبقًا']; end if;
  today := fn_branch_today(r.branch_id);
  if r.status <> 'confirmed' then v := array_append(v, 'الحجز غير مؤكد'); end if;
  if coalesce(r.security_hold, false) then v := array_append(v, 'يوجد حظر أمني على الحجز'); end if;
  if jsonb_array_length(fn_reservation_ban_matches(r.id)) > 0 then v := array_append(v, 'الضيف محظور من الإدارة'); end if;
  if today < r.check_in then v := array_append(v, 'لم يحن تاريخ الوصول (' || r.check_in || ')');
  elsif today >= r.check_out then v := array_append(v, 'انتهت فترة الإقامة'); end if;
  select count(*), count(*) filter (where data_submitted), count(*) filter (where verification_status = 'verified')
    into gc, sc, vc from reservation_guests where reservation_id = r.id;
  if gc = 0 then v := array_append(v, 'لم تُسجَّل بيانات النزلاء');
  elsif sc < gc then v := array_append(v, 'بيانات أحد النزلاء ناقصة');
  elsif gc < fn_registration_target(r.id) then                       -- 0058 (GUEST-07): children under 15 are counted, not registered
    v := array_append(v, 'عدد النزلاء المسجلين أقل من عدد الحجز'); end if;
  if r.identity_status <> 'verified' or vc < gc then v := array_append(v, 'لم تُعتمد مطابقة الهوية لجميع النزلاء'); end if;
  -- Shomoos: the reference with every guest registered, then Shomoos's acceptance (decision 6, no exception)
  if not coalesce(r.government_registration, false) or coalesce(trim(r.gov_registration_ref), '') = '' then
    v := array_append(v, 'لم يُسجَّل النزلاء في شموس');
  elsif r.shomoos_guest_count is distinct from (r.adults + r.companions) then
    v := array_append(v, 'تغيّر عدد النزلاء بعد تسجيل شموس؛ حدِّث التسجيل');
  elsif r.shomoos_accepted_at is null then
    v := array_append(v, 'لم يُؤكَّد قبول شموس للتسجيل');
  end if;
  if r.room_id is null then
    v := array_append(v, 'لم تُخصَّص وحدة');
  else
    select * into rm from rooms where id = r.room_id;
    if not rm.is_active or rm.archived_at is not null then v := array_append(v, 'الوحدة موقوفة عن العمل');
    elsif rm.status in ('maintenance', 'blocked', 'out_of_service')
       or exists (select 1 from maintenance_tickets m where m.room_id = rm.id and m.status <> 'resolved') then v := array_append(v, 'الوحدة تحت الصيانة');
    elsif rm.cleanliness <> 'clean' then v := array_append(v, 'الوحدة غير نظيفة');
    end if;
    if exists (select 1 from reservations o where o.room_id = rm.id and o.status = 'checked_in' and o.id <> r.id) then
      v := array_append(v, 'في الوحدة نزيل لم تُسجَّل مغادرته');
    end if;
    if not exists (select 1 from reservation_allocations a where a.reservation_id = r.id and a.room_id = rm.id and a.status = 'active'
                   and a.from_date <= today and today < a.to_date)
       and exists (select 1 from reservation_allocations a where a.room_id = rm.id and a.status = 'active' and a.reservation_id <> r.id
                   and daterange(a.from_date, a.to_date, '[)') && daterange(today, greatest(r.check_out, today + 1), '[)')) then
      v := array_append(v, 'الوحدة محجوزة لحجز آخر في هذه الفترة');
    end if;
  end if;
  return v;
end $$;

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
  perform fn_check_name_parts(v_name, p_payload->>'identity_type');         -- 0058 (GUEST-05): two parts for a passport or a GCC ID
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
    total_required := fn_registration_target(r.id);                   -- 0058 (GUEST-07): children under 15 are not registered
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
  perform fn_check_name_parts(v_name, p->>'identity_type');                 -- 0058 (GUEST-05): two parts for a passport or a GCC ID
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
    if cnt >= fn_registration_target(r.id) then raise exception 'GUEST_LIMIT_REACHED'; end if;   -- 0058: children under 15 are not registered
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
