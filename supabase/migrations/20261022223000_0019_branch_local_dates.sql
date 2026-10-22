/*
# 0019 — Business dates are the branch's dates, whatever the session time zone

A hosted Supabase database runs its sessions in UTC. Four functions still took "today" or a timestamp's day from
the session (current_date, timestamptz::date), so between 00:00 and 03:00 in Riyadh they worked on yesterday:

  fn_ops_daily_summary_at  received_today / refunded_today / completed_today counted the UTC day (a receipt taken at
                           00:30 fell into yesterday's summary) — the operations briefing and dashboard read it
  fn_evaluate_access       a guest arriving after midnight on the check-in date was "outside the stay period"
  fn_staff_switch_room     a switch effective today did not close the old allocation of a resident after midnight
  fn_guest_submit          a birth date of today (a newborn companion) was rejected after midnight

Everywhere else the code already used fn_branch_today() (branches.timezone, default Asia/Riyadh) or converted
timestamps with AT TIME ZONE; these four now do the same. Bodies are otherwise unchanged (copied from their latest
definitions: 0005, 0005, 0009, 0007c), with the search_path every function has had since 0012.
PL09 keeps the session-zone forms out of public functions from now on; tests/sql/local_date_tests.sql checks these
paths in a UTC session, like the hosted database's. CREATE OR REPLACE keeps every function's privileges as they are (no grants here).
*/

create or replace function fn_ops_daily_summary_at(p_branch uuid, p_date date) returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select case when p_branch in (select fn_user_branch_ids()) then jsonb_build_object(
    'date', p_date,
    'units', jsonb_build_object(
      'active', (select count(*) from rooms where branch_id = p_branch and is_active and archived_at is null),
      'occupied', (select count(*) from rooms where branch_id = p_branch and status = 'occupied'),
      'reserved', (select count(*) from rooms where branch_id = p_branch and status = 'reserved'),
      'ready', (select count(*) from rooms where branch_id = p_branch and status = 'ready'),
      'dirty', (select count(*) from rooms where branch_id = p_branch and is_active and cleanliness <> 'clean'),
      'maintenance', (select count(*) from rooms where branch_id = p_branch and status = 'maintenance'),
      'out_of_service', (select count(*) from rooms where branch_id = p_branch and (status = 'out_of_service' or not is_active))),
    'occupancy_pct', (select case when count(*) filter (where is_active and archived_at is null) = 0 then 0
                        else round(100.0 * count(*) filter (where status = 'occupied') / count(*) filter (where is_active and archived_at is null), 1) end from rooms where branch_id = p_branch),
    'arrivals', jsonb_build_object(
      'expected', (select count(*) from reservations where branch_id = p_branch and check_in = p_date and status in ('confirmed','pending_verification')),
      'arrived', (select count(*) from reservations where branch_id = p_branch and check_in = p_date and status = 'checked_in'),
      'pending_identity', (select count(*) from reservations where branch_id = p_branch and check_in <= p_date and check_out > p_date and status in ('confirmed','pending_verification') and identity_status <> 'verified'),
      'unpaid', (select count(*) from reservations where branch_id = p_branch and check_in = p_date and status in ('confirmed','pending_verification') and balance_due_halalas > 0),
      'overdue', (select count(*) from reservations where branch_id = p_branch and check_in < p_date and status in ('confirmed','pending_verification'))),
    'departures', jsonb_build_object(
      'expected', (select count(*) from reservations where branch_id = p_branch and check_out = p_date and status = 'checked_in'),
      'done', (select count(*) from reservations where branch_id = p_branch and check_out = p_date and status = 'checked_out'),
      'overstay', (select count(*) from reservations where branch_id = p_branch and check_out < p_date and status = 'checked_in'),
      'with_balance', (select count(*) from reservations where branch_id = p_branch and check_out = p_date and status = 'checked_in' and balance_due_halalas > 0)),
    'housekeeping', jsonb_build_object(
      'open', (select count(*) from housekeeping_tasks where branch_id = p_branch and status = 'pending'),
      'in_progress', (select count(*) from housekeeping_tasks where branch_id = p_branch and status = 'in_progress'),
      'completed_today', (select count(*) from housekeeping_tasks where branch_id = p_branch and status = 'completed' and completed_at >= d.day_start and completed_at < d.day_end),
      'unassigned', (select count(*) from housekeeping_tasks where branch_id = p_branch and status = 'pending' and assignee_id is null)),
    'finance', jsonb_build_object(
      'received_today', (select coalesce(sum(amount_halalas),0) from financial_vouchers where branch_id = p_branch and kind = 'receipt' and status = 'approved' and occurred_at >= d.day_start and occurred_at < d.day_end),
      'refunded_today', (select coalesce(sum(amount_halalas),0) from financial_vouchers where branch_id = p_branch and kind = 'refund' and status = 'approved' and occurred_at >= d.day_start and occurred_at < d.day_end),
      'deposits_held', (select coalesce(sum(deposit_balance_halalas),0) from reservations where branch_id = p_branch and status in ('confirmed','checked_in','checked_out')),
      'outstanding_in_house', (select coalesce(sum(balance_due_halalas),0) from reservations where branch_id = p_branch and status = 'checked_in'),
      'deposit_to_settle_after_checkout', (select coalesce(sum(deposit_balance_halalas),0) from reservations where branch_id = p_branch and status = 'checked_out' and deposit_balance_halalas > 0)),
    'tickets_open', (select count(*) from human_handoff_tickets where branch_id = p_branch and status = 'open'),
    'generated_at', now()
  ) else null end
  -- the branch's calendar day as an instant range: index-friendly, and right whatever the session time zone is
  from (select p_date::timestamp at time zone z.tz as day_start, (p_date + 1)::timestamp at time zone z.tz as day_end
        from (select coalesce((select timezone from branches where id = p_branch), 'Asia/Riyadh') as tz) z) d;
$$;

create or replace function fn_evaluate_access(p_reservation uuid, p_skip_supervisor boolean default false)
returns table(allowed boolean, reasons text[])
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  r reservations%rowtype;
  rm rooms%rowtype;
  kb keyboxes%rowtype;
  v_reasons text[] := '{}';
  guest_count int;
  submitted_count int;
  verified_count int;
  v_today date;
begin
  select * into r from reservations where id = p_reservation;
  if not found then
    return query select false, array['الحجز غير موجود']::text[]; return;
  end if;

  if r.status not in ('confirmed','checked_in') then v_reasons := array_append(v_reasons, 'الحجز غير مؤكد'); end if;
  if r.security_hold then v_reasons := array_append(v_reasons, 'يوجد حظر أمني على الحجز'); end if;
  v_today := fn_branch_today(r.branch_id);   -- the property's date, not the session's (UTC on the hosted database)
  if v_today < r.check_in or v_today >= r.check_out then v_reasons := array_append(v_reasons, 'التاريخ الحالي خارج فترة الإقامة'); end if;

  select count(*), count(*) filter (where data_submitted), count(*) filter (where verification_status = 'verified')
    into guest_count, submitted_count, verified_count
  from reservation_guests where reservation_id = p_reservation;

  if guest_count = 0 then v_reasons := array_append(v_reasons, 'لم يتم تسجيل بيانات النزلاء');
  elsif submitted_count < guest_count then v_reasons := array_append(v_reasons, 'بيانات أحد النزلاء ناقصة');
  elsif guest_count < (r.adults + r.companions) then v_reasons := array_append(v_reasons, 'عدد النزلاء المسجلين أقل من المطلوب');
  end if;

  if r.identity_status <> 'verified' or verified_count < guest_count then
    v_reasons := array_append(v_reasons, 'لم يتم اعتماد مطابقة الهوية لجميع النزلاء');
  end if;

  if r.payment_status <> 'paid' then v_reasons := array_append(v_reasons, 'لم يتم استيفاء السداد المطلوب'); end if;
  if not r.government_registration then v_reasons := array_append(v_reasons, 'لم يتم تأكيد التسجيل النظامي'); end if;

  if r.room_id is null then
    v_reasons := array_append(v_reasons, 'لم يتم تخصيص غرفة');
  else
    select * into rm from rooms where id = r.room_id;
    if rm.status not in ('ready','reserved','occupied') or (rm.status = 'occupied' and r.status <> 'checked_in') then
      v_reasons := array_append(v_reasons, 'الغرفة غير جاهزة');
    end if;
    select * into kb from keyboxes where room_id = r.room_id limit 1;
    if not found then v_reasons := array_append(v_reasons, 'لا يوجد صندوق مفتاح للغرفة');
    elsif kb.code_encrypted is null then v_reasons := array_append(v_reasons, 'لم يتم تعيين رمز الصندوق');
    elsif kb.code_status <> 'active' then v_reasons := array_append(v_reasons, 'رمز الصندوق يحتاج إلى تغيير');
    elsif not kb.field_tested then v_reasons := array_append(v_reasons, 'لم يتم اختبار رمز الصندوق ميدانيًا');
    elsif kb.last_reservation_id is not null and kb.last_reservation_id <> r.id and r.status <> 'checked_in' then
      v_reasons := array_append(v_reasons, 'الرمز الحالي سبق تسليمه لحجز آخر ويجب تغييره');
    end if;
  end if;

  if not p_skip_supervisor and r.access_status not in ('approved','delivery_pending','delivered','acknowledged') then
    v_reasons := array_append(v_reasons, 'لم يعتمد المشرف الدخول النهائي');
  end if;

  return query select (coalesce(array_length(v_reasons,1),0) = 0), v_reasons;
end $$;

create or replace function fn_staff_switch_room(p_reservation uuid, p_room uuid, p_effective date, p_reason text, p_expected_version int default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r reservations%rowtype; old reservation_allocations%rowtype; eff date; old_room uuid; new_rm rooms%rowtype;
begin
  perform fn_require_role('owner','manager','supervisor');
  if coalesce(trim(p_reason),'') = '' then raise exception 'VALIDATION: reason'; end if;
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  perform fn_check_version_strict(r.version, p_expected_version);
  if r.status not in ('confirmed','checked_in','pending_verification') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  eff := coalesce(p_effective, greatest(fn_branch_today(r.branch_id), r.check_in));
  if eff < r.check_in or eff >= r.check_out then raise exception 'VALIDATION: effective_date'; end if;
  if r.status = 'checked_in' and eff > fn_branch_today(r.branch_id) then raise exception 'VALIDATION: effective_date'; end if;   -- a resident moves now, not in the future
  select * into new_rm from rooms where id = p_room;
  if not found or new_rm.branch_id <> r.branch_id then raise exception 'ROOM_NOT_FOUND'; end if;            -- R06
  if r.room_id = p_room then raise exception 'SAME_ROOM'; end if;
  if r.status = 'checked_in' and new_rm.cleanliness <> 'clean' then raise exception 'ROOM_NOT_CLEAN'; end if;
  if r.adults + r.companions > (select max_capacity from room_categories where id = new_rm.category_id) then raise exception 'CAPACITY_EXCEEDED'; end if;

  -- lock rooms in a fixed order to avoid deadlocks when two switches cross
  perform 1 from rooms where id in (p_room, r.room_id) order by id for update;

  select * into old from reservation_allocations where reservation_id = r.id and status = 'active' and daterange(from_date, to_date, '[)') @> eff for update;
  if found then
    if old.room_id = p_room then raise exception 'SAME_ROOM'; end if;
    old_room := old.room_id;
    if old.from_date = eff then
      update reservation_allocations set status = 'cancelled', closed_at = now(), reason = coalesce(reason,'') || ' | switched' where id = old.id;
    else
      update reservation_allocations set to_date = eff, status = case when eff <= fn_branch_today(r.branch_id) and r.status = 'checked_in' then 'closed' else 'active' end,
             closed_at = case when eff <= fn_branch_today(r.branch_id) and r.status = 'checked_in' then now() end where id = old.id;
    end if;
    if r.status = 'checked_in' then
      update rooms set status = 'cleaning', cleanliness = 'dirty' where id = old_room;
      insert into housekeeping_tasks(organization_id, branch_id, room_id, task_type_id, task_type_name_snapshot, reservation_id, priority, description, created_by)
      select r.organization_id, r.branch_id, old_room, t.id, t.name, r.id, 'high', 'تبديل وحدة', fn_staff_id() from task_types t where t.id = fn_room_cleaning_type(r.branch_id);
      update keyboxes set code_status = 'needs_change', field_tested = false where room_id = old_room;
    else
      update rooms set status = 'available' where id = old_room and status = 'reserved';
    end if;
  end if;

  -- category may differ on switch (upgrade/downgrade): price difference is a separate explicit adjustment
  update reservations set room_category_id = new_rm.category_id where id = r.id and r.room_category_id <> new_rm.category_id;
  perform fn_allocate(r.id, p_room, eff, r.check_out, 'switch: ' || p_reason);
  if r.status = 'checked_in' then
    update rooms set status = 'occupied' where id = p_room;
    update keyboxes set last_reservation_id = r.id where room_id = p_room;
  end if;
  update reservations set version = version + 1, updated_at = now() where id = r.id;
  perform fn_audit_change(r.branch_id, 'reservation.room_switched', 'reservation', r.id, jsonb_build_object('room_id', old_room), jsonb_build_object('room_id', p_room, 'effective', eff), p_reason);
  return jsonb_build_object('ok', true, 'from_room', old_room, 'to_room', p_room, 'effective', eff,
                            'entry_code_review_required', r.status = 'checked_in');
end $$;

create or replace function fn_guest_submit(p_token text, p_guest_id uuid, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  rid uuid := fn_token_reservation(p_token);
  r reservations%rowtype;
  g reservation_guests%rowtype;
  v_name text := trim(coalesce(p_payload->>'full_name',''));
  v_type identity_type;
  v_number text := regexp_replace(coalesce(p_payload->>'identity_number',''), '\s', '', 'g');
  v_nat text := trim(coalesce(p_payload->>'nationality',''));
  v_birth date;
  v_phone text := nullif(regexp_replace(coalesce(p_payload->>'phone',''), '[^0-9+]', '', 'g'), '');
  v_rel text := coalesce(p_payload->>'relationship','other');
  v_issue text := nullif(trim(coalesce(p_payload->>'identity_issue_number','')), '');
  total_required int;
  current_count int;
  new_id uuid;
begin
  select * into r from reservations where id = rid for update;
  if r.status in ('cancelled','rejected','closed','checked_out') then raise exception 'RESERVATION_NOT_EDITABLE'; end if;

  -- validation (server-side, authoritative)
  if array_length(regexp_split_to_array(v_name, '\s+'), 1) < 3 then raise exception 'VALIDATION: full_name_three_parts'; end if;
  begin v_type := (p_payload->>'identity_type')::identity_type; exception when others then raise exception 'VALIDATION: identity_type'; end;
  if v_type in ('national_id','iqama') and v_number !~ '^[12]\d{9}$' then raise exception 'VALIDATION: identity_number_format'; end if;
  if v_type = 'gcc_id' and v_number !~ '^[A-Za-z0-9]{6,15}$' then raise exception 'VALIDATION: identity_number_format'; end if;
  if v_type = 'passport' and v_number !~ '^[A-Za-z0-9]{5,12}$' then raise exception 'VALIDATION: identity_number_format'; end if;
  if v_nat = '' then raise exception 'VALIDATION: nationality'; end if;
  begin v_birth := (p_payload->>'birth_date')::date; exception when others then raise exception 'VALIDATION: birth_date'; end;
  if v_birth > fn_branch_today(r.branch_id) or v_birth < fn_branch_today(r.branch_id) - interval '120 years' then raise exception 'VALIDATION: birth_date_range'; end if;
  if coalesce(p_payload->>'consent','false') <> 'true' then raise exception 'VALIDATION: consent_required'; end if;

  if p_guest_id is not null then
    select * into g from reservation_guests where id = p_guest_id and reservation_id = rid for update;
    if not found then raise exception 'GUEST_NOT_FOUND'; end if;
    if g.verification_status = 'verified' then raise exception 'GUEST_ALREADY_VERIFIED'; end if;
    if g.is_primary and v_phone is null then v_phone := g.phone; end if;
    if g.is_primary and v_phone is null then raise exception 'VALIDATION: phone_required_primary'; end if;
    update reservation_guests set
      full_name = v_name, identity_type = v_type,
      identity_number_encrypted = pgp_sym_encrypt(v_number, fn_secret('identity_key')),
      identity_number_last4 = right(v_number, 4), identity_issue_number = v_issue,
      nationality = v_nat, birth_date = v_birth, phone = coalesce(v_phone, phone),
      relationship = case when g.is_primary then 'self' else v_rel end,
      data_submitted = true, verification_status = 'data_submitted'
    where id = g.id;
    new_id := g.id;
  else
    total_required := r.adults + r.companions;
    select count(*) into current_count from reservation_guests where reservation_id = rid;
    if current_count >= total_required then raise exception 'GUEST_LIMIT_REACHED'; end if;
    -- duplicate companion guard (same document in same reservation)
    if exists (select 1 from reservation_guests x where x.reservation_id = rid and x.identity_type = v_type and x.identity_number_last4 = right(v_number,4)
               and pgp_sym_decrypt(x.identity_number_encrypted, fn_secret('identity_key')) = v_number) then
      raise exception 'DUPLICATE_GUEST';
    end if;
    insert into reservation_guests (reservation_id, is_primary, full_name, identity_type, identity_number_encrypted, identity_number_last4,
      identity_issue_number, nationality, birth_date, phone, relationship, data_submitted, verification_status)
    values (rid, false, v_name, v_type, pgp_sym_encrypt(v_number, fn_secret('identity_key')), right(v_number,4),
      v_issue, v_nat, v_birth, v_phone, v_rel, true, 'data_submitted')
    returning id into new_id;
  end if;

  -- roll up reservation identity status
  if (select bool_and(data_submitted) from reservation_guests where reservation_id = rid)
     and (select count(*) from reservation_guests where reservation_id = rid) >= (r.adults + r.companions) then
    update reservations set identity_status = 'pending_supervisor', updated_at = now() where id = rid and identity_status in ('not_started','data_submitted');
    insert into notifications(branch_id, audience, title, body, link)
    values (r.branch_id, 'supervisor', 'بيانات نزلاء مكتملة بانتظار المطابقة', 'الحجز ' || r.internal_ref, '/staff/reservations/' || r.id);
  else
    update reservations set identity_status = 'data_submitted', updated_at = now() where id = rid and identity_status = 'not_started';
  end if;

  perform fn_audit(r.organization_id, r.branch_id, null, 'guest_data_submitted', 'reservation_guest', new_id, jsonb_build_object('reservation_id', rid));
  return jsonb_build_object('ok', true, 'guest_id', new_id);
end $$;
