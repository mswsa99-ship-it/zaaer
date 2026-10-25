-- =====================================================================
-- 0033 — the stay cycle (Phase 3): decisions 1, 3, 5, 6, 7, 8, 10, 12, 59, and the transition and race rules of
-- 45, 46, 49 and 50.
--   1. Check-in is its own step («تسجيل الوصول»), separate from delivering the key-box code. Its conditions are
--      the same in every branch, with no override: a confirmed stay whose arrival day has come, every guest
--      registered and matched, Shomoos registered with every guest and accepted, an allocated unit that is clean
--      and free, the first night paid in full, and the branch's deposit taken (or the reason it was not). The
--      arrival screen records the rent receipt and the deposit receipt as two separate vouchers, in the same
--      operation. A unit without a key box takes its ordinary key at reception; a unit with one gets its code as
--      a separate step, only after the arrival is registered.
--   2. Night by night (decision 3): every night after the first is due by the branch's check-out time on its own
--      day, with one hour's grace. A night unpaid past that is overdue: the stay page and the daily follow-up
--      show it, and extending or adding a service waits until it is paid or a reason is recorded. Discounts are
--      spread over the nights; services and fees are due when added.
--   3. Shomoos (decision 6): the reference, the confirmation that every guest and companion is registered, and
--      the confirmation that Shomoos accepted — who and when for each. A change in the number of guests after
--      the registration asks for it again.
--   4. Check-out (decision 8) only with nothing owed, for anyone. Paying, applying the deposit with a reason, or
--      the owner's or a manager's price settlement with a reason are the ways to zero it.
--   5. The check-out inspection (decision 5) by the supervisor or housekeeping: sound, or notes with a suggested
--      deduction. A stay's deposit is refunded only after check-out and an inspection; the supervisor may now
--      refund it, and apply it. A damage charge carries its reason, comes off the deposit, and the rest is a
--      separate refund voucher. A daily summary per employee of what each received and paid back, by method.
--   6. Corrections (decision 10), by the owner or a manager with a reason: undo a check-in within 30 minutes,
--      reopen a departed stay within 2 hours, undo a cancellation within 1 hour. Each one waits in the owner's
--      review list. Late check-out is a priced service that moves the departure time to a set hour.
--   7. «مغلق» by itself (decision 59): departed, nothing owed either way, the deposit settled, every line
--      invoiced. A later change that breaks one of these takes it back to «غادر». The list «غادر ولم يُغلق». The
--      daily summary still counts a departure closed at once among the day's departures.
--   8. Readiness (decision 7): a unit without a key box is ready when clean; one with a box also needs a new,
--      tested code. A manual cleanliness change is free and recorded (decision 12, with the tests of 50).
--   9. Resources with commitments (decision 49): a unit with a guest in house is not deactivated, and a unit type
--      with open stays is not archived; booking and archiving are serialised on the type's row.
-- This file only adds and updates; it never removes data (it is applied through the SQL tools, which refuse that).
-- The foreign keys of the three new tables, with what a purge needs, are in 0034 (pasted in the SQL editor).
-- =====================================================================
select set_config('app.source', 'migration', true);

-- ---------------------------------------------------------------- 1. columns
alter table reservations add column if not exists checked_in_by uuid references staff_profiles(id);
alter table reservations add column if not exists checked_out_by uuid references staff_profiles(id);
alter table reservations add column if not exists closed_at timestamptz;
alter table reservations add column if not exists deposit_waiver_reason text;
alter table reservations add column if not exists deposit_waiver_by uuid references staff_profiles(id);
alter table reservations add column if not exists deposit_waiver_at timestamptz;
alter table reservations add column if not exists shomoos_guest_count int;
alter table reservations add column if not exists shomoos_accepted_at timestamptz;
alter table reservations add column if not exists shomoos_accepted_by uuid references staff_profiles(id);
alter table reservations add column if not exists late_checkout_until time;
alter table reservations add column if not exists status_before_cancel text;

-- the money column gate (0009) lists the readable columns explicitly: the new ones carry no money
do $$ begin
  if exists (select 1 from information_schema.column_privileges where table_name = 'reservations' and grantee = 'authenticated' and column_name = 'status')
     and not exists (select 1 from information_schema.role_table_grants where table_name = 'reservations' and grantee = 'authenticated' and privilege_type = 'SELECT') then
    grant select (checked_in_by, checked_out_by, closed_at, deposit_waiver_reason, deposit_waiver_by, deposit_waiver_at, shomoos_guest_count,
                  shomoos_accepted_at, shomoos_accepted_by, late_checkout_until, status_before_cancel) on reservations to authenticated;
  end if;
end $$;

-- what a charge is for, when it is not plain rent or a plain service: a damage, or a late check-out
alter table reservation_charges add column if not exists purpose text;
alter table reservation_charges add column if not exists idempotency_key text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'reservation_charges_purpose_chk') then
    alter table reservation_charges add constraint reservation_charges_purpose_chk check (purpose is null or purpose in ('damage', 'late_checkout'));
  end if;
end $$;
create unique index if not exists uniq_charge_idempotency on reservation_charges(reservation_id, idempotency_key) where idempotency_key is not null;

-- a late check-out service moves the departure to this hour (decision 10)
alter table service_definitions add column if not exists late_checkout_until time;

-- ---------------------------------------------------------------- 2. the check-out inspection, overdue reasons, the owner's review list
create table if not exists checkout_inspections (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  branch_id uuid not null references branches(id),
  reservation_id uuid not null,   -- its foreign key, with what a purge needs, is added by 0034 (pasted in the SQL editor)
  room_id uuid references rooms(id),
  result text not null check (result in ('ok', 'notes')),
  notes text,
  suggested_deduction_halalas bigint not null default 0 check (suggested_deduction_halalas >= 0),
  status text not null default 'active' check (status in ('active', 'superseded')),
  inspected_by uuid references staff_profiles(id),
  inspected_at timestamptz not null default now(),
  superseded_at timestamptz,
  superseded_by uuid references staff_profiles(id),
  constraint inspection_notes_chk check (result = 'ok' or coalesce(trim(notes), '') <> '')
);
create index if not exists idx_inspections_reservation on checkout_inspections(reservation_id, status);
alter table checkout_inspections enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'checkout_inspections' and policyname = 'inspections_read') then
    create policy "inspections_read" on checkout_inspections for select to authenticated
      using (branch_id in (select fn_user_branch_ids()) and fn_has_role('owner', 'manager', 'supervisor', 'finance', 'housekeeping'));
  end if;
end $$;
revoke insert, update on checkout_inspections from anon, authenticated;

create table if not exists stay_payment_exceptions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  branch_id uuid not null references branches(id),
  reservation_id uuid not null,   -- foreign key in 0034
  through_night date not null,
  shortfall_halalas bigint not null,
  reason text not null check (trim(reason) <> ''),
  created_by uuid references staff_profiles(id),
  created_at timestamptz not null default now()
);
create index if not exists idx_payment_exceptions_reservation on stay_payment_exceptions(reservation_id, through_night);
alter table stay_payment_exceptions enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'stay_payment_exceptions' and policyname = 'payment_exceptions_read') then
    create policy "payment_exceptions_read" on stay_payment_exceptions for select to authenticated
      using (branch_id in (select fn_user_branch_ids()) and fn_has_role('owner', 'manager', 'supervisor', 'finance'));
  end if;
end $$;
revoke insert, update on stay_payment_exceptions from anon, authenticated;

-- «بحاجة لمراجعة وتدقيق»: what the owner should look at; Phase 4 shows the list and the marking
create table if not exists review_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  branch_id uuid references branches(id),
  kind text not null,
  entity_type text not null,
  entity_id uuid not null,
  reservation_id uuid,            -- foreign key in 0034
  summary text not null,
  reason text,
  details jsonb not null default '{}'::jsonb,
  created_by uuid references staff_profiles(id),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references staff_profiles(id),
  review_note text
);
create index if not exists idx_review_items_open on review_items(organization_id, created_at desc) where reviewed_at is null;
alter table review_items enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'review_items' and policyname = 'review_items_owner_read') then
    create policy "review_items_owner_read" on review_items for select to authenticated
      using (organization_id = fn_user_org_id() and fn_has_role('owner'));
  end if;
end $$;
revoke insert, update on review_items from anon, authenticated;

create or replace function fn_add_review_item(p_branch uuid, p_kind text, p_entity_type text, p_entity_id uuid, p_reservation uuid,
                                              p_summary text, p_reason text, p_details jsonb default '{}'::jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  insert into review_items(organization_id, branch_id, kind, entity_type, entity_id, reservation_id, summary, reason, details, created_by)
  values ((select organization_id from branches where id = p_branch), p_branch, p_kind, p_entity_type, p_entity_id, p_reservation, p_summary, p_reason,
          coalesce(p_details, '{}'::jsonb), fn_staff_id())
  returning id into v;
  return v;
end $$;
revoke all on function fn_add_review_item(uuid, text, text, uuid, uuid, text, text, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------- 3. helpers
create or replace function fn_sar_text(p bigint) returns text
language sql immutable set search_path = public as $$
  select to_char(coalesce(p, 0) / 100.0, 'FM999999990.00') || ' ر.س';
$$;
revoke all on function fn_sar_text(bigint) from public, anon, authenticated;

-- the branch's wall-clock time (business dates and hours are the branch's, whatever the session time zone)
create or replace function fn_branch_local_now(p_branch uuid) returns timestamp
language sql stable set search_path = public as $$
  select now() at time zone coalesce((select timezone from branches where id = p_branch), 'Asia/Riyadh');
$$;
revoke all on function fn_branch_local_now(uuid) from public, anon, authenticated;

-- what is due once k nights are due. Services, fees and added amounts are due when added (p_extras); the rest of
-- the stay (its nights with their tax, less any discount) is due night by night, in proportion to the nights' prices.
-- With every night due it is exactly the total.
create or replace function fn_due_share(p_total bigint, p_extras bigint, p_all_nights bigint, p_k_nights bigint) returns bigint
language sql immutable set search_path = public as $$
  select greatest(0, case when p_all_nights <= 0 then p_total
                          else round((p_total - p_extras)::numeric * p_k_nights / p_all_nights)::bigint + p_extras end);
$$;
revoke all on function fn_due_share(bigint, bigint, bigint, bigint) from public, anon, authenticated;

-- ---------------------------------------------------------------- 4. night by night (decision 3)
-- The first night is due before arrival. Every later night is due at the branch's check-out time on its own day;
-- an hour after that (the grace for extending or leaving) it is overdue. Each night counts with its tax.
create or replace function fn_stay_due_internal(p_reservation uuid, p_at timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r reservations%rowtype; tz text; cot time; dep_req bigint; loc timestamp; f jsonb; total bigint; collected bigint; extras bigint;
        nights date[] := '{}'; cum bigint[] := array[0::bigint]; x record; n int; rn bigint; i int;
        k_due int := 0; k_over int := 0; covered int := 0; due_now bigint; over_amt bigint := 0; is_over boolean := false;
        over_since timestamptz; over_through date; next_night date; next_dl timestamptz;
begin
  select * into r from reservations where id = p_reservation;
  if not found then return null; end if;
  select coalesce(b.timezone, 'Asia/Riyadh'), coalesce(b.check_out_time, time '12:00'), b.default_deposit_halalas
    into tz, cot, dep_req from branches b where b.id = r.branch_id;
  loc := p_at at time zone tz;
  f := fn_reservation_finance_internal(r.id);
  total := (f->>'total')::bigint;
  collected := (f->>'net_collected')::bigint;
  extras := (f->>'addons')::bigint + (f->>'penalties')::bigint + greatest((f->>'adjustments')::bigint, 0);
  for x in select nt.night, (t.net_halalas + t.tax_halalas) as gross
           from reservation_nights nt cross join lateral fn_reservation_tax(r.id, nt.price_halalas, true) t
           where nt.reservation_id = r.id and nt.status = 'active' order by nt.night loop
    nights := nights || x.night;
    cum := cum || (cum[array_length(cum, 1)] + x.gross);
  end loop;
  n := coalesce(array_length(nights, 1), 0);
  rn := cum[n + 1];
  if n > 0 then
    k_due := 1;
    for i in 2..n loop exit when loc < (nights[i] + cot); k_due := i; end loop;
    if r.status = 'checked_in' then
      k_over := 1;
      for i in 2..n loop exit when loc < (nights[i] + cot + interval '1 hour'); k_over := i; end loop;
    end if;
    for i in 1..n loop exit when fn_due_share(total, extras, rn, cum[i + 1]) > collected; covered := i; end loop;
  end if;
  due_now := fn_due_share(total, extras, rn, cum[k_due + 1]);
  if k_over > covered then
    is_over := true;
    over_amt := greatest(fn_due_share(total, extras, rn, cum[k_over + 1]) - collected, 0);
    over_through := nights[k_over];
    over_since := case when covered = 0 then coalesce(r.actual_check_in, p_at) else (nights[covered + 1] + cot + interval '1 hour') at time zone tz end;
  end if;
  if covered < n then
    next_night := nights[covered + 1];
    next_dl := case when covered = 0 then null else (nights[covered + 1] + cot) at time zone tz end;
  end if;
  return jsonb_build_object(
    'nights', n, 'nights_due', k_due, 'nights_covered', covered, 'total', total, 'collected', collected,
    'first_night', fn_due_share(total, extras, rn, cum[least(n, 1) + 1]),
    'due_now', due_now, 'shortfall_now', greatest(due_now - collected, 0),
    'overdue', is_over, 'overdue_amount', over_amt, 'overdue_since', over_since, 'overdue_through', over_through,
    'next_unpaid_night', next_night, 'next_deadline', next_dl, 'deadline_time', to_char(cot, 'HH24:MI'),
    'balance_due', (f->>'balance_due')::bigint, 'deposit_required', dep_req, 'deposit_balance', (f->>'deposit_balance')::bigint);
end $$;
revoke all on function fn_stay_due_internal(uuid, timestamptz) from public, anon, authenticated;

-- an overdue night blocks extending and services until it is paid, or a reason covering it is recorded
create or replace function fn_overdue_blocked(p_reservation uuid) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare d jsonb;
begin
  d := fn_stay_due_internal(p_reservation);
  if d is null or not coalesce((d->>'overdue')::boolean, false) then return false; end if;
  return not exists (select 1 from stay_payment_exceptions e where e.reservation_id = p_reservation and e.through_night >= (d->>'overdue_through')::date);
end $$;
revoke all on function fn_overdue_blocked(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------- 5. readiness (decision 7)
-- A unit without a key box is ready when clean and out of maintenance; with a box it also needs an active, tested code.
create or replace function fn_recompute_room_ready(p_room uuid) returns room_status
language plpgsql security definer set search_path = public as $$
declare rm rooms%rowtype; kb keyboxes%rowtype; open_maint int; st room_status;
begin
  select * into rm from rooms where id = p_room for update;
  if not rm.is_active or rm.archived_at is not null then update rooms set status = 'out_of_service' where id = p_room; return 'out_of_service'; end if;
  if rm.status in ('occupied','reserved','blocked') then return rm.status; end if;
  select count(*) into open_maint from maintenance_tickets where room_id = p_room and status <> 'resolved';
  select * into kb from keyboxes where room_id = p_room limit 1;
  if open_maint > 0 then st := 'maintenance';
  elsif rm.cleanliness <> 'clean' then st := 'cleaning';
  elsif kb.id is not null and (kb.code_status <> 'active' or not kb.field_tested) then st := 'cleaning';   -- clean, but the box's code is not ready (H06)
  else st := 'ready'; end if;
  update rooms set status = st where id = p_room;
  return st;
end $$;
revoke all on function fn_recompute_room_ready(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------- 6. check-in (decisions 1, 2, 3, 6)
-- the conditions that are not money: the same in every branch, no override
create or replace function fn_checkin_core_blockers(p_reservation uuid) returns text[]
language plpgsql stable security definer set search_path = public as $$
declare r reservations%rowtype; rm rooms%rowtype; v text[] := '{}'; today date; gc int; sc int; vc int;
begin
  select * into r from reservations where id = p_reservation;
  if not found then return array['الحجز غير موجود']; end if;
  if r.status = 'checked_in' then return array['سُجِّل وصول هذا الحجز مسبقًا']; end if;
  today := fn_branch_today(r.branch_id);
  if r.status <> 'confirmed' then v := array_append(v, 'الحجز غير مؤكد'); end if;
  if coalesce(r.security_hold, false) then v := array_append(v, 'يوجد حظر أمني على الحجز'); end if;
  if today < r.check_in then v := array_append(v, 'لم يحن تاريخ الوصول (' || r.check_in || ')');
  elsif today >= r.check_out then v := array_append(v, 'انتهت فترة الإقامة'); end if;
  select count(*), count(*) filter (where data_submitted), count(*) filter (where verification_status = 'verified')
    into gc, sc, vc from reservation_guests where reservation_id = r.id;
  if gc = 0 then v := array_append(v, 'لم تُسجَّل بيانات النزلاء');
  elsif sc < gc then v := array_append(v, 'بيانات أحد النزلاء ناقصة');
  elsif gc < r.adults + r.companions then v := array_append(v, 'عدد النزلاء المسجلين أقل من عدد الحجز'); end if;
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
revoke all on function fn_checkin_core_blockers(uuid) from public, anon, authenticated;

-- the money conditions, with what the arrival screen is about to record
create or replace function fn_checkin_money_blockers(p_reservation uuid, p_add_collected bigint default 0, p_add_deposit bigint default 0,
                                                     p_deposit_reason text default null) returns text[]
language plpgsql stable security definer set search_path = public as $$
declare d jsonb; v text[] := '{}'; need bigint; have bigint;
begin
  d := fn_stay_due_internal(p_reservation);
  if d is null then return v; end if;
  need := (d->>'first_night')::bigint - (d->>'collected')::bigint - coalesce(p_add_collected, 0);
  if need > 0 then v := array_append(v, 'الليلة الأولى غير مدفوعة كاملة: المتبقي ' || fn_sar_text(need)); end if;
  have := (d->>'deposit_balance')::bigint + coalesce(p_add_deposit, 0);
  if have < (d->>'deposit_required')::bigint and coalesce(trim(p_deposit_reason), '') = '' then
    v := array_append(v, 'التأمين لم يُستلم كاملًا: المطلوب ' || fn_sar_text((d->>'deposit_required')::bigint));
  end if;
  return v;
end $$;
revoke all on function fn_checkin_money_blockers(uuid, bigint, bigint, text) from public, anon, authenticated;

-- «تسجيل الوصول»: the conditions, then the rent and the deposit entries, then the arrival — all or nothing
create or replace function fn_staff_check_in(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; reasons text[]; add_rent bigint := 0; add_dep bigint := 0; reason text := nullif(trim(coalesce(p->>'deposit_reason', '')), '');
        d jsonb; dep_short bigint; has_kb boolean; v_rent jsonb; v_dep jsonb; released int;
begin
  perform fn_require_role('owner', 'manager', 'supervisor');
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.status = 'checked_in' then
    return jsonb_build_object('ok', true, 'duplicate', true, 'status', r.status);     -- R13: one transition, one arrival time
  end if;
  if p ? 'expected_version' then perform fn_check_version(r.version, (p->>'expected_version')::int); end if;
  if jsonb_typeof(p->'rent') = 'object' then add_rent := fn_parse_halalas(p->'rent'->>'amount_halalas'); end if;
  if jsonb_typeof(p->'deposit') = 'object' then add_dep := fn_parse_halalas(p->'deposit'->>'amount_halalas'); end if;
  reasons := fn_checkin_core_blockers(r.id) || fn_checkin_money_blockers(r.id, add_rent, add_dep, reason);
  if coalesce(array_length(reasons, 1), 0) > 0 then
    return jsonb_build_object('ok', false, 'reasons', to_jsonb(reasons));
  end if;
  -- the two entries of the arrival screen, each its own voucher (decision 3)
  if add_rent > 0 then v_rent := fn_create_voucher((p->'rent') || jsonb_build_object('reservation_id', r.id, 'kind', 'receipt')); end if;
  if add_dep > 0 then v_dep := fn_create_voucher((p->'deposit') || jsonb_build_object('reservation_id', r.id, 'kind', 'deposit')); end if;
  d := fn_stay_due_internal(r.id);
  if (d->>'collected')::bigint < (d->>'first_night')::bigint then raise exception 'VALIDATION: first_night_unpaid'; end if;
  dep_short := greatest((d->>'deposit_required')::bigint - (d->>'deposit_balance')::bigint, 0);
  if dep_short > 0 and reason is null then raise exception 'VALIDATION: deposit_reason'; end if;
  has_kb := exists (select 1 from keyboxes where room_id = r.room_id);
  update reservations set status = 'checked_in', actual_check_in = now(), checked_in_by = fn_staff_id(),
         checkin_approved_by = fn_staff_id(), checkin_approved_at = now(),
         access_status = case when has_kb then 'approved' else 'key_handed' end::access_status, keybox_delivered = false,
         deposit_waiver_reason = case when dep_short > 0 then reason end,
         deposit_waiver_by = case when dep_short > 0 then fn_staff_id() end,
         deposit_waiver_at = case when dep_short > 0 then now() end,
         version = version + 1, updated_at = now()
   where id = r.id;
  update rooms set status = 'occupied', updated_at = now() where id = r.room_id;
  update access_release_requests set status = 'approved', approved_by = fn_staff_id(), approved_at = now(), evaluated_at = now()
   where reservation_id = r.id and status in ('locked', 'eligibility_review');
  released := fn_release_next_slot(r.branch_id, r.room_category_id, r.check_in);
  perform fn_audit_change(r.branch_id, 'reservation.checked_in', 'reservation', r.id,
    jsonb_build_object('status', r.status, 'access_status', r.access_status),
    jsonb_build_object('status', 'checked_in', 'room_id', r.room_id, 'key_box', has_kb, 'rent_voucher', v_rent->>'number',
                       'deposit_voucher', v_dep->>'number', 'deposit_short_halalas', nullif(dep_short, 0)),
    case when dep_short > 0 then reason end);
  return jsonb_build_object('ok', true, 'duplicate', false, 'has_keybox', has_kb, 'released_count', released,
                            'rent_voucher', v_rent->>'number', 'deposit_voucher', v_dep->>'number', 'finance', fn_reservation_finance_internal(r.id));
end $$;
grant execute on function fn_staff_check_in(jsonb) to authenticated;

-- the former «اعتماد الدخول» is the arrival now, with the same conditions (no other way in)
create or replace function fn_staff_approve_checkin(p_reservation uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  return fn_staff_check_in(jsonb_build_object('reservation_id', p_reservation));
end $$;
grant execute on function fn_staff_approve_checkin(uuid) to authenticated;

-- ---------------------------------------------------------------- 7. Shomoos (decision 6)
create or replace function fn_staff_shomoos(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; act text := p->>'action'; ref text := nullif(trim(coalesce(p->>'reference', '')), ''); cnt int; before jsonb;
begin
  perform fn_require_role('owner', 'manager', 'supervisor');
  if act is null or act not in ('register', 'accept') then raise exception 'VALIDATION: action'; end if;
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.status not in ('pending_verification', 'confirmed', 'checked_in') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  cnt := r.adults + r.companions;
  before := jsonb_build_object('reference', r.gov_registration_ref, 'guest_count', r.shomoos_guest_count, 'accepted', r.shomoos_accepted_at is not null);
  if act = 'register' then
    if r.identity_status <> 'verified' then raise exception 'IDENTITY_NOT_VERIFIED'; end if;
    if ref is null then raise exception 'VALIDATION: shomoos_reference'; end if;
    if length(ref) < 3 or length(ref) > 60 then raise exception 'VALIDATION: shomoos_reference'; end if;
    if coalesce((p->>'all_guests')::boolean, false) is not true then raise exception 'VALIDATION: shomoos_all_guests'; end if;
    if coalesce(r.government_registration, false) and r.gov_registration_ref = ref and r.shomoos_guest_count = cnt then
      return jsonb_build_object('ok', true, 'unchanged', true);
    end if;
    -- a new or corrected registration waits for Shomoos's acceptance again
    update reservations set government_registration = true, gov_registration_ref = ref, gov_registration_by = fn_staff_id(), gov_registration_at = now(),
           shomoos_guest_count = cnt, shomoos_accepted_at = null, shomoos_accepted_by = null, version = version + 1, updated_at = now()
     where id = r.id;
    perform fn_audit_change(r.branch_id, 'reservation.shomoos_registered', 'reservation', r.id, before,
      jsonb_build_object('reference', ref, 'guest_count', cnt, 'accepted', false));
  else
    if not coalesce(r.government_registration, false) or r.gov_registration_ref is null then raise exception 'VALIDATION: shomoos_not_registered'; end if;
    if r.shomoos_guest_count is distinct from cnt then raise exception 'VALIDATION: shomoos_guest_count'; end if;
    if r.shomoos_accepted_at is not null then return jsonb_build_object('ok', true, 'unchanged', true); end if;
    update reservations set shomoos_accepted_at = now(), shomoos_accepted_by = fn_staff_id(), version = version + 1, updated_at = now() where id = r.id;
    perform fn_audit_change(r.branch_id, 'reservation.shomoos_accepted', 'reservation', r.id, before,
      jsonb_build_object('reference', r.gov_registration_ref, 'guest_count', cnt, 'accepted', true));
  end if;
  return jsonb_build_object('ok', true, 'unchanged', false);
end $$;
grant execute on function fn_staff_shomoos(jsonb) to authenticated;

-- the former one-step confirmation: the registration now needs its explicit «every guest is registered»
create or replace function fn_staff_confirm_gov_registration(p_reservation uuid, p_reference text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  return fn_staff_shomoos(jsonb_build_object('reservation_id', p_reservation, 'action', 'register', 'reference', p_reference, 'all_guests', false));
end $$;
grant execute on function fn_staff_confirm_gov_registration(uuid, text) to authenticated;

-- ---------------------------------------------------------------- 8. the key-box code, after the arrival (decision 1)
create or replace function fn_code_blockers(p_reservation uuid) returns text[]
language plpgsql stable security definer set search_path = public as $$
declare r reservations%rowtype; kb keyboxes%rowtype; v text[] := '{}'; loc timestamp; dep time;
begin
  select * into r from reservations where id = p_reservation;
  if not found then return array['الحجز غير موجود']; end if;
  if r.status <> 'checked_in' then return array['لم يُسجَّل الوصول بعد']; end if;
  if coalesce(r.security_hold, false) then v := array_append(v, 'يوجد حظر أمني على الحجز'); end if;
  loc := fn_branch_local_now(r.branch_id);
  dep := coalesce(r.late_checkout_until, (select check_out_time from branches where id = r.branch_id), time '12:00');
  if loc > (r.check_out + dep) then v := array_append(v, 'انتهى موعد المغادرة'); end if;
  if r.room_id is null then return array_append(v, 'لم تُخصَّص وحدة'); end if;
  select * into kb from keyboxes where room_id = r.room_id limit 1;
  if not found then v := array_append(v, 'الوحدة بلا صندوق مفتاح؛ يُسلَّم مفتاحها يدويًا');
  elsif kb.code_encrypted is null then v := array_append(v, 'لم يُعيَّن رمز الصندوق');
  elsif kb.code_status <> 'active' then v := array_append(v, 'رمز الصندوق يحتاج إلى تغيير');
  elsif not kb.field_tested then v := array_append(v, 'لم يُجرَّب رمز الصندوق على الصندوق');
  elsif kb.last_reservation_id is not null and kb.last_reservation_id <> r.id then v := array_append(v, 'الرمز الحالي سُلِّم لحجز آخر ويجب تغييره');
  end if;
  return v;
end $$;
revoke all on function fn_code_blockers(uuid) from public, anon, authenticated;

-- what still stands before the code: before the arrival, the arrival's own conditions; after it, the code's
create or replace function fn_evaluate_access(p_reservation uuid, p_skip_supervisor boolean default false)
returns table(allowed boolean, reasons text[])
language plpgsql stable security definer set search_path = public as $$
declare r reservations%rowtype; v text[];
begin
  select * into r from reservations where id = p_reservation;
  if not found then return query select false, array['الحجز غير موجود']::text[]; return; end if;
  if r.status = 'checked_in' then
    v := fn_code_blockers(r.id);
  elsif r.status in ('draft', 'pending_verification', 'confirmed') then
    v := array_append(fn_checkin_core_blockers(r.id) || fn_checkin_money_blockers(r.id, 0, 0, null), 'يُسجَّل الوصول في الاستقبال ثم يُسلَّم الرمز');
  else
    v := array['الإقامة غير قائمة'];
  end if;
  return query select coalesce(array_length(v, 1), 0) = 0, v;
end $$;
revoke all on function fn_evaluate_access(uuid, boolean) from public, anon;
grant execute on function fn_evaluate_access(uuid, boolean) to authenticated;

-- «تسليم الرمز»: only after the arrival, only for a unit with a key box, with the code ready for this guest
create or replace function fn_staff_deliver_access_code(p_reservation uuid, p_channel text default 'screen') returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r reservations%rowtype; kb keyboxes%rowtype; v text[]; v_code text;
begin
  perform fn_require_role('owner', 'manager', 'supervisor');
  if p_channel is null or p_channel not in ('screen', 'whatsapp', 'supervisor') then raise exception 'VALIDATION: channel'; end if;
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.access_status in ('delivered', 'acknowledged') then
    return jsonb_build_object('ok', false, 'reasons', jsonb_build_array('تم تسليم الرمز مسبقًا لهذا الحجز'));
  end if;
  v := fn_code_blockers(r.id);
  if coalesce(array_length(v, 1), 0) > 0 then return jsonb_build_object('ok', false, 'reasons', to_jsonb(v)); end if;
  select * into kb from keyboxes where room_id = r.room_id limit 1 for update;
  update reservations set access_status = 'delivered', keybox_delivered = true, version = version + 1, updated_at = now() where id = r.id;
  update keyboxes set last_reservation_id = r.id, last_delivered_at = now() where id = kb.id;
  update access_release_requests set status = 'delivered', delivered_at = now() where reservation_id = r.id and status = 'approved';
  insert into access_delivery_events(reservation_id, keybox_id, channel, delivered_by) values (r.id, kb.id, p_channel, fn_staff_id());
  perform fn_audit_change(r.branch_id, 'deliver_access_code', 'reservation', r.id, jsonb_build_object('access_status', r.access_status),
    jsonb_build_object('access_status', 'delivered', 'channel', p_channel, 'code_version', kb.code_version));
  if p_channel = 'supervisor' then
    v_code := pgp_sym_decrypt(kb.code_encrypted, fn_secret('keybox_key'));
    return jsonb_build_object('ok', true, 'code', v_code);
  end if;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function fn_staff_deliver_access_code(uuid, text) to authenticated;

-- ---------------------------------------------------------------- 9. «مغلق» by itself (decision 59)
create or replace function fn_closure_missing(p_reservation uuid) returns text[]
language plpgsql stable security definer set search_path = public as $$
declare f jsonb; v text[] := '{}'; n int;
begin
  f := fn_reservation_finance_internal(p_reservation);
  if (f->>'balance_due')::bigint > 0 then v := array_append(v, 'مبلغ مستحق ' || fn_sar_text((f->>'balance_due')::bigint)); end if;
  if (f->>'credit')::bigint > 0 then v := array_append(v, 'رصيد للضيف لم يُرد ' || fn_sar_text((f->>'credit')::bigint)); end if;
  if (f->>'deposit_balance')::bigint <> 0 then v := array_append(v, 'تأمين لم يُسوَّ ' || fn_sar_text((f->>'deposit_balance')::bigint)); end if;
  select count(*) into n from reservation_charges where reservation_id = p_reservation and invoice_id is null and total_halalas <> 0;
  if n > 0 then v := array_append(v, n || ' بند بلا فاتورة'); end if;
  return v;
end $$;
revoke all on function fn_closure_missing(uuid) from public, anon, authenticated;

create or replace function fn_sync_closed(p_reservation uuid) returns text
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; missing text[]; n int;
begin
  select * into r from reservations where id = p_reservation;
  if not found then return null; end if;
  if r.status not in ('checked_out', 'closed') then return r.status::text; end if;
  missing := fn_closure_missing(r.id);
  n := coalesce(array_length(missing, 1), 0);
  if r.status = 'checked_out' and n = 0 then
    update reservations set status = 'closed', closed_at = now(), version = version + 1, updated_at = now() where id = r.id;
    perform fn_audit_change(r.branch_id, 'reservation.closed', 'reservation', r.id, jsonb_build_object('status', 'checked_out'), jsonb_build_object('status', 'closed'));
    return 'closed';
  elsif r.status = 'closed' and n > 0 then
    update reservations set status = 'checked_out', closed_at = null, version = version + 1, updated_at = now() where id = r.id;
    perform fn_audit_change(r.branch_id, 'reservation.unclosed', 'reservation', r.id, jsonb_build_object('status', 'closed'),
      jsonb_build_object('status', 'checked_out', 'missing', to_jsonb(missing)));
    return 'checked_out';
  end if;
  return r.status::text;
end $$;
revoke all on function fn_sync_closed(uuid) from public, anon, authenticated;

-- every voucher and charge change re-checks the closing, whichever function made it
create or replace function fn_trg_sync_closed() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform fn_sync_closed(new.reservation_id);
  return null;
end $$;
revoke all on function fn_trg_sync_closed() from public, anon, authenticated;
create or replace trigger trg_vouchers_sync_closed after insert or update of status on financial_vouchers
  for each row execute function fn_trg_sync_closed();
create or replace trigger trg_charges_sync_closed after insert or update of invoice_id, total_halalas on reservation_charges
  for each row execute function fn_trg_sync_closed();

-- ---------------------------------------------------------------- 10. check-out (decision 8)
create or replace function fn_staff_check_out(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; f jsonb; tt uuid; existing_task uuid; has_kb boolean; st text;
begin
  perform fn_require_role('owner', 'manager', 'supervisor');
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.status in ('checked_out', 'closed') then return jsonb_build_object('ok', true, 'duplicate', true, 'status', r.status); end if;   -- R14
  if r.status <> 'checked_in' then raise exception 'NOT_CHECKED_IN'; end if;
  if p ? 'expected_version' then perform fn_check_version(r.version, (p->>'expected_version')::int); end if;
  f := fn_recompute_reservation_finance(r.id);
  -- nothing owed, for anyone: no override (decision 8)
  if (f->>'balance_due')::bigint > 0 then
    return jsonb_build_object('ok', false, 'balance_due', (f->>'balance_due')::bigint, 'reasons', jsonb_build_array(
      'على الحجز مبلغ مستحق ' || fn_sar_text((f->>'balance_due')::bigint)
      || '. يُصفَّر بسند قبض، أو بالخصم من التأمين بسبب، أو بتسوية سعر من المالك أو المدير بسبب.'));
  end if;
  update reservations set status = 'checked_out', actual_check_out = now(), checked_out_by = fn_staff_id(), version = version + 1, updated_at = now() where id = r.id;
  perform fn_release_allocations(r.id, 'close');
  if r.room_id is not null then
    update rooms set status = 'cleaning', cleanliness = 'dirty', updated_at = now() where id = r.room_id;
    tt := fn_room_cleaning_type(r.branch_id);
    select id into existing_task from housekeeping_tasks where room_id = r.room_id and reservation_id = r.id and status in ('pending', 'in_progress') limit 1;
    if existing_task is null then
      insert into housekeeping_tasks(organization_id, branch_id, room_id, task_type_id, task_type_name_snapshot, reservation_id, priority, description, created_by)
      values (r.organization_id, r.branch_id, r.room_id, tt, 'تنظيف الوحدة وتعقيمها', r.id, 'high', 'تنظيف بعد المغادرة', fn_staff_id());
    end if;
    has_kb := exists (select 1 from keyboxes where room_id = r.room_id);
    update keyboxes set code_status = 'needs_change', field_tested = false where room_id = r.room_id;
    insert into notifications(branch_id, audience, title, body, link)
    values (r.branch_id, 'supervisor', case when has_kb then 'مغادرة — تنظيف وتغيير رمز مطلوب' else 'مغادرة — تنظيف مطلوب' end,
            'غرفة ' || (select room_number from rooms where id = r.room_id), '/staff/housekeeping');
  end if;
  perform fn_audit_change(r.branch_id, 'reservation.checked_out', 'reservation', r.id, jsonb_build_object('status', 'checked_in'),
    jsonb_build_object('status', 'checked_out', 'deposit_balance_halalas', (f->>'deposit_balance')::bigint, 'credit_halalas', (f->>'credit')::bigint));
  st := fn_sync_closed(r.id);
  return jsonb_build_object('ok', true, 'duplicate', false, 'status', st, 'deposit_to_settle_halalas', (f->>'deposit_balance')::bigint,
                            'credit_halalas', (f->>'credit')::bigint, 'missing', to_jsonb(fn_closure_missing(r.id)));
end $$;
grant execute on function fn_staff_check_out(jsonb) to authenticated;

-- the former check-out: same rules; the managers' override is gone (decision 8), a reason given to it changes nothing
create or replace function fn_staff_checkout(p_reservation uuid, p_override_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  return fn_staff_check_out(jsonb_build_object('reservation_id', p_reservation));
end $$;
grant execute on function fn_staff_checkout(uuid, text) to authenticated;

-- ---------------------------------------------------------------- 11. inspection, damages, deposit (decision 5)
create or replace function fn_staff_record_inspection(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; res text := p->>'result'; v_notes text := nullif(trim(coalesce(p->>'notes', '')), ''); sug bigint := 0; iid uuid;
begin
  perform fn_require_role('owner', 'manager', 'supervisor', 'housekeeping');
  if res is null or res not in ('ok', 'notes') then raise exception 'VALIDATION: inspection_result'; end if;
  if res = 'notes' and v_notes is null then raise exception 'VALIDATION: inspection_notes'; end if;
  if res = 'notes' and coalesce(p->>'suggested_deduction_halalas', '') not in ('', '0') then sug := fn_parse_halalas(p->>'suggested_deduction_halalas'); end if;
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  -- the inspection is of the departure: after check-out, or on the departure day (or later) of a guest still in
  if not (r.status = 'checked_out' or (r.status = 'checked_in' and fn_branch_today(r.branch_id) >= r.check_out)) then
    raise exception 'VALIDATION: inspection_not_due';
  end if;
  update checkout_inspections set status = 'superseded', superseded_at = now(), superseded_by = fn_staff_id() where reservation_id = r.id and status = 'active';
  insert into checkout_inspections(organization_id, branch_id, reservation_id, room_id, result, notes, suggested_deduction_halalas, inspected_by)
  values (r.organization_id, r.branch_id, r.id, r.room_id, res, v_notes, sug, fn_staff_id()) returning id into iid;
  if res = 'notes' then
    insert into notifications(branch_id, audience, title, body, link)
    values (r.branch_id, 'supervisor', 'ملاحظات في فحص المغادرة',
            'الحجز ' || r.internal_ref || coalesce(' — خصم مقترح ' || fn_sar_text(nullif(sug, 0)), ''), '/staff/reservations/' || r.id);
  end if;
  perform fn_audit_change(r.branch_id, 'reservation.inspected', 'reservation', r.id, null,
    jsonb_build_object('result', res, 'suggested_deduction_halalas', sug, 'room_id', r.room_id));
  return jsonb_build_object('ok', true, 'id', iid);
end $$;
grant execute on function fn_staff_record_inspection(jsonb) to authenticated;

-- refunds: never above what is available, even under concurrency (G12/F05/F06/X02); a refund leaves through an account too.
-- Decision 5: the supervisor may also refund a deposit and apply it; a stay's deposit goes back only after check-out and
-- a check-out inspection. The stay's own money is refunded by the owner, a manager or finance.
create or replace function fn_refund(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; v financial_vouchers%rowtype; kind text := p->>'kind'; amt bigint; key text := p->>'idempotency_key';
        h text; existing financial_vouchers%rowtype; f jsonb; available bigint; prefix text; m text; ref text; acc uuid;
begin
  if kind is null or kind not in ('refund', 'deposit_refund', 'deposit_apply') then raise exception 'VALIDATION: kind'; end if;
  if kind = 'refund' then perform fn_require_role('owner', 'manager', 'finance');
  else perform fn_require_role('owner', 'manager', 'supervisor', 'finance'); end if;
  amt := fn_parse_halalas(p->>'amount_halalas');
  if coalesce(trim(p->>'reason'), '') = '' then raise exception 'VALIDATION: reason'; end if;
  if coalesce(trim(key), '') = '' then raise exception 'VALIDATION: idempotency_key'; end if;
  -- applying the deposit to the stay moves money between two balances of the same guest: no method, no account
  m := case when kind = 'deposit_apply' then 'cash' else p->>'method' end;
  if m is null then raise exception 'VALIDATION: method'; end if;
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;      -- concurrent refunds are serialised here
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  h := md5(r.id::text || kind || amt::text || coalesce(p->>'method', '') || coalesce(p->>'reference', '') || coalesce(p->>'account_id', ''));
  select * into existing from financial_vouchers where organization_id = r.organization_id and idempotency_key = key;
  if found then
    if existing.content_hash <> h then raise exception 'IDEMPOTENCY_CONFLICT: same key, different content'; end if;
    if existing.status = 'cancelled' then raise exception 'IDEMPOTENCY_CANCELLED: voucher % was cancelled; use a new key', existing.number; end if;
    return jsonb_build_object('ok', true, 'duplicate', true, 'voucher_id', existing.id, 'number', existing.number, 'finance', fn_reservation_finance_internal(r.id));
  end if;
  if kind = 'deposit_refund' and (r.actual_check_in is not null or r.status in ('checked_in', 'checked_out', 'closed')) then
    if r.status not in ('checked_out', 'closed') then raise exception 'VALIDATION: deposit_refund_before_checkout'; end if;
    if not exists (select 1 from checkout_inspections i where i.reservation_id = r.id and i.status = 'active') then
      raise exception 'INSPECTION_REQUIRED: record the check-out inspection first';
    end if;
  end if;
  if kind <> 'deposit_apply' then
    if not fn_payment_method_active(m) then raise exception 'VALIDATION: method_retired'; end if;
    if kind = 'deposit_refund' and m = 'ota_deferred' then raise exception 'VALIDATION: deposit_method'; end if;
    ref := fn_check_payment_reference(m, p->>'reference');
    acc := fn_voucher_account(r.branch_id, m, (p->>'account_id')::uuid);
  end if;
  f := fn_reservation_finance_internal(r.id);
  available := case kind when 'refund' then (f->>'received')::bigint - (f->>'refunded')::bigint else (f->>'deposit_balance')::bigint end;
  if amt > available then raise exception 'REFUND_EXCEEDS_AVAILABLE: available % halalas', available; end if;
  if kind = 'deposit_apply' and amt > (f->>'balance_due')::bigint then raise exception 'REFUND_EXCEEDS_AVAILABLE: nothing due'; end if;
  prefix := case kind when 'refund' then 'RFD' when 'deposit_refund' then 'DRF' else 'DAP' end;
  insert into financial_vouchers(organization_id, branch_id, reservation_id, number, kind, amount_halalas, method, account_id, status, reference, note, reason, original_voucher_id, idempotency_key, content_hash, occurred_at, created_by)
  values (r.organization_id, r.branch_id, r.id, fn_next_document_number(r.organization_id, 'voucher', prefix), kind, amt, m::payment_method, acc,
          'approved', ref, p->>'note', p->>'reason', (p->>'original_voucher_id')::uuid, key, h, now(), fn_staff_id()) returning * into v;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_audit_change(r.branch_id, 'voucher.' || kind || '_created', 'voucher', v.id, null,
    jsonb_build_object('number', v.number, 'amount_halalas', amt, 'method', case when kind = 'deposit_apply' then null else m end, 'account_id', acc, 'reservation_id', r.id, 'available_before', available), p->>'reason');
  return jsonb_build_object('ok', true, 'duplicate', false, 'voucher_id', v.id, 'number', v.number, 'finance', fn_reservation_finance_internal(r.id));
end $$;
grant execute on function fn_refund(jsonb) to authenticated;

-- «رسم ضرر»: a charge with its reason, taken from the deposit as far as it goes; the rest of the deposit is refunded on
-- its own voucher (after the inspection)
create or replace function fn_staff_add_damage(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; amt bigint; key text := nullif(trim(coalesce(p->>'idempotency_key', '')), ''); descr text := nullif(trim(coalesce(p->>'description', '')), '');
        reason text := nullif(trim(coalesce(p->>'reason', '')), ''); cid uuid; f jsonb; apply_amt bigint := 0; v jsonb; existing uuid;
begin
  perform fn_require_role('owner', 'manager', 'supervisor');
  amt := fn_parse_halalas(p->>'amount_halalas');
  if reason is null then raise exception 'VALIDATION: reason'; end if;
  if key is null then raise exception 'VALIDATION: idempotency_key'; end if;
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  select id into existing from reservation_charges where reservation_id = r.id and idempotency_key = key;
  if existing is not null then
    return jsonb_build_object('ok', true, 'duplicate', true, 'charge_id', existing, 'finance', fn_reservation_finance_internal(r.id));
  end if;
  if r.status not in ('checked_in', 'checked_out', 'closed') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  cid := fn_add_charge(r.id, 'penalty', 'رسم ضرر — ' || coalesce(descr, reason), 1, amt, false, reason);
  update reservation_charges set purpose = 'damage', idempotency_key = key where id = cid;
  if coalesce((p->>'apply_deposit')::boolean, true) then
    f := fn_reservation_finance_internal(r.id);
    apply_amt := least(amt, (f->>'deposit_balance')::bigint, (f->>'balance_due')::bigint);
    if apply_amt > 0 then
      v := fn_refund(jsonb_build_object('reservation_id', r.id, 'kind', 'deposit_apply', 'amount_halalas', apply_amt,
                                        'reason', 'رسم ضرر: ' || reason, 'idempotency_key', key || ':apply'));
    end if;
  end if;
  update reservations set version = version + 1, updated_at = now() where id = r.id;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_audit_change(r.branch_id, 'reservation.damage_charged', 'reservation', r.id, null,
    jsonb_build_object('amount_halalas', amt, 'description', descr, 'from_deposit_halalas', apply_amt, 'voucher', v->>'number'), reason);
  return jsonb_build_object('ok', true, 'duplicate', false, 'charge_id', cid, 'from_deposit_halalas', apply_amt, 'finance', fn_reservation_finance_internal(r.id));
end $$;
grant execute on function fn_staff_add_damage(jsonb) to authenticated;

-- ---------------------------------------------------------------- 12. overdue nights: the reason that lets the stay go on
create or replace function fn_staff_payment_exception(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; d jsonb; reason text := nullif(trim(coalesce(p->>'reason', '')), '');
begin
  perform fn_require_role('owner', 'manager', 'supervisor');
  if reason is null then raise exception 'VALIDATION: reason'; end if;
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  d := fn_stay_due_internal(r.id);
  if not coalesce((d->>'overdue')::boolean, false) then raise exception 'VALIDATION: not_overdue'; end if;
  insert into stay_payment_exceptions(organization_id, branch_id, reservation_id, through_night, shortfall_halalas, reason, created_by)
  values (r.organization_id, r.branch_id, r.id, (d->>'overdue_through')::date, (d->>'overdue_amount')::bigint, reason, fn_staff_id());
  perform fn_audit_change(r.branch_id, 'reservation.payment_exception', 'reservation', r.id, null,
    jsonb_build_object('through_night', d->>'overdue_through', 'overdue_halalas', (d->>'overdue_amount')::bigint), reason);
  return jsonb_build_object('ok', true, 'through_night', d->>'overdue_through');
end $$;
grant execute on function fn_staff_payment_exception(jsonb) to authenticated;

-- extending: identical to 0030, except that a stay with an overdue night is extended only after paying or a reason
create or replace function fn_staff_amend_stay(p_reservation uuid, p_new_check_out date, p_pricing_mode text, p_reason text, p_expected_version int default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; a reservation_allocations%rowtype; delta int; before jsonb; runs jsonb; platform boolean; last_price bigint; refund bigint;
begin
  perform fn_require_role('owner','manager','supervisor');
  if coalesce(trim(p_reason),'') = '' then raise exception 'VALIDATION: reason'; end if;
  if p_pricing_mode not in ('keep_rate','reprice') then raise exception 'VALIDATION: pricing_mode'; end if;
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  perform fn_check_version_strict(r.version, p_expected_version);
  if r.status not in ('confirmed','checked_in','pending_verification') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  if p_new_check_out <= r.check_in then raise exception 'VALIDATION: dates'; end if;
  if r.status = 'checked_in' and p_new_check_out <= fn_branch_today(r.branch_id) and p_new_check_out < r.check_out then raise exception 'VALIDATION: checkout_in_past'; end if;
  delta := p_new_check_out - r.check_out;
  if delta = 0 then return jsonb_build_object('ok', true, 'unchanged', true); end if;
  -- decision 3: a night unpaid past its deadline stops the extension until it is paid or a reason is recorded
  if delta > 0 and r.status = 'checked_in' and fn_overdue_blocked(r.id) then
    raise exception 'PAYMENT_OVERDUE: a night is unpaid past its deadline';
  end if;
  -- leaving a weekly or monthly stay early is settled by the owner or a manager (decision 15)
  if delta < 0 and r.price_basis in ('weekly', 'monthly') and not fn_has_role('owner','manager') then
    raise exception 'FORBIDDEN: shortening a weekly or monthly stay requires manager';
  end if;
  before := jsonb_build_object('check_out', r.check_out, 'total_halalas', r.total_halalas);
  perform fn_ensure_nights(r.id);

  -- allocation: extend the current active allocation (exclusion constraint guards the added period)
  select * into a from reservation_allocations where reservation_id = r.id and status = 'active' order by to_date desc limit 1 for update;
  if found then
    if a.to_date <> r.check_out then raise exception 'ALLOCATION_MISMATCH: active allocation does not end at check_out'; end if;
    if a.to_date = r.check_out then
      if p_new_check_out <= a.from_date then raise exception 'VALIDATION: dates'; end if;
      begin
        update reservation_allocations set to_date = p_new_check_out where id = a.id;
      exception when exclusion_violation then
        raise exception 'ALLOCATION_CONFLICT: room is allocated during the added period' using errcode = '23P01';
      end;
    end if;
  end if;

  if delta > 0 then
    -- keep_rate: the added nights at the stay's last night's price; reprice: the calendar's prices for those nights
    -- (an extension is never re-priced as a weekly or monthly stay — that price is fixed when the stay is made)
    if p_pricing_mode = 'keep_rate' then
      select price_halalas into last_price from reservation_nights where reservation_id = r.id and status = 'active' order by night desc limit 1;
      runs := jsonb_build_array(jsonb_build_object('from', r.check_out, 'to', p_new_check_out, 'nights', delta,
                                                   'price', coalesce(last_price, r.nightly_rate_halalas), 'basis', 'kept'));
    else
      platform := exists (select 1 from booking_sources s where s.id = r.source_id and s.kind <> 'direct');
      runs := fn_stay_runs(r.room_category_id, r.check_out, p_new_check_out, platform, null, false);
    end if;
    perform fn_book_nights(r.id, runs, 'تمديد', p_reason);
  else
    -- the refund is exactly the removed nights' prices; the nights keep their rows, marked removed
    select coalesce(sum(price_halalas), 0) into refund from reservation_nights
    where reservation_id = r.id and status = 'active' and night >= p_new_check_out and night < r.check_out;
    update reservation_nights set status = 'removed', removed_at = now(), removed_by = fn_staff_id(), removed_reason = p_reason
    where reservation_id = r.id and status = 'active' and night >= p_new_check_out and night < r.check_out;
    perform fn_add_charge(r.id, 'adjustment', 'تقصير الإقامة ' || abs(delta) || ' ليلة', 1, -refund, true, p_reason, null, p_new_check_out, r.check_out);
  end if;
  update reservations set check_out = p_new_check_out,
         nightly_rate_halalas = coalesce((select round(avg(price_halalas))::bigint from reservation_nights where reservation_id = r.id and status = 'active'), nightly_rate_halalas),
         version = version + 1, updated_at = now()
  where id = r.id;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_audit_change(r.branch_id, 'reservation.departure_changed', 'reservation', r.id, before,
    jsonb_build_object('check_out', p_new_check_out, 'total_halalas', (select total_halalas from reservations where id = r.id), 'delta_nights', delta,
                       'pricing_mode', p_pricing_mode, 'nights', case when delta > 0 then runs else jsonb_build_object('refunded_halalas', refund) end), p_reason);
  return jsonb_build_object('ok', true, 'delta_nights', delta, 'finance', fn_reservation_finance_internal(r.id));
end $$;
grant execute on function fn_staff_amend_stay(uuid, date, text, text, int) to authenticated;

-- services: identical to 0009, except the overdue rule (decision 3) and the late check-out service (decision 10)
create or replace function fn_staff_add_service(p_reservation uuid, p_service uuid, p_quantity numeric default 1, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; s service_definitions%rowtype; qty numeric; price bigint; cid uuid;
begin
  perform fn_require_role('owner','manager','supervisor');
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.status in ('cancelled','rejected','closed','no_show') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  select * into s from service_definitions where id = p_service and branch_id = r.branch_id and archived_at is null and is_active;
  if not found then raise exception 'SERVICE_NOT_AVAILABLE'; end if;
  if r.status = 'checked_in' and fn_overdue_blocked(r.id) then
    raise exception 'PAYMENT_OVERDUE: a night is unpaid past its deadline';
  end if;
  if s.late_checkout_until is not null and r.status not in ('pending_verification', 'confirmed', 'checked_in') then
    raise exception 'RESERVATION_STATUS_INVALID';
  end if;
  qty := case s.billing_unit when 'night' then (r.check_out - r.check_in) when 'person' then (r.adults + r.companions) when 'quantity' then coalesce(p_quantity,1) else 1 end;
  if qty <= 0 then raise exception 'VALIDATION: quantity'; end if;
  price := case when s.is_free then 0 else s.price_halalas end;
  -- snapshot name/price/tax at the time of adding (G27)
  cid := fn_add_charge(r.id, 'addon', s.name_ar || case when p_note is not null then ' — ' || p_note else '' end, qty, price, s.taxable, null, s.id,
                       case when s.billing_unit = 'night' then r.check_in end, case when s.billing_unit = 'night' then r.check_out end);
  if s.late_checkout_until is not null then
    update reservation_charges set purpose = 'late_checkout' where id = cid;
    update reservations set late_checkout_until = greatest(coalesce(late_checkout_until, s.late_checkout_until), s.late_checkout_until) where id = r.id;
  end if;
  update reservations set version = version + 1 where id = r.id;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_audit_change(r.branch_id, 'reservation.service_added', 'reservation', r.id, null,
    jsonb_build_object('service_id', s.id, 'name', s.name_ar, 'quantity', qty, 'unit_price', price, 'late_checkout_until', to_char(s.late_checkout_until, 'HH24:MI')));
  return jsonb_build_object('ok', true, 'finance', fn_reservation_finance_internal(r.id), 'late_checkout_until', to_char(s.late_checkout_until, 'HH24:MI'));
end $$;
grant execute on function fn_staff_add_service(uuid, uuid, numeric, text) to authenticated;

-- service definitions: identical to 0009, plus the late check-out hour (after the branch's check-out time; once per stay)
create or replace function fn_admin_upsert_service(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s service_definitions%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; v_tt uuid := (p->>'task_type_id')::uuid; before jsonb;
        v_late time; v_unit text;
begin
  perform fn_require_role('owner','manager');
  if coalesce(trim(p->>'name_ar'),'') = '' then raise exception 'VALIDATION: name_ar'; end if;
  if (p ? 'price_halalas') and (p->>'price_halalas')::bigint < 0 then raise exception 'VALIDATION: amount'; end if;
  begin v_late := nullif(trim(coalesce(p->>'late_checkout_until', '')), '')::time; exception when others then raise exception 'VALIDATION: late_checkout_until'; end;
  if v_id is not null then
    select * into s from service_definitions where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    v_branch := s.branch_id;
    if not (p ? 'task_type_id') then v_tt := s.task_type_id; end if;
    if not (p ? 'late_checkout_until') then v_late := s.late_checkout_until; end if;
  end if;
  perform fn_require_branch(v_branch);
  if v_tt is not null and not exists (select 1 from task_types where id = v_tt and branch_id = v_branch) then raise exception 'BRANCH_MISMATCH: task_type'; end if;
  v_unit := coalesce(p->>'billing_unit', s.billing_unit, 'once');
  if v_late is not null then
    if v_late <= coalesce((select check_out_time from branches where id = v_branch), time '12:00') then raise exception 'VALIDATION: late_checkout_until'; end if;
    if v_unit <> 'once' then raise exception 'VALIDATION: late_checkout_unit'; end if;
  end if;
  if v_id is null then
    insert into service_definitions(organization_id, branch_id, name_ar, name_en, description, billing_unit, price_halalas, is_free, taxable, task_type_id, late_checkout_until)
    values (fn_user_org_id(), v_branch, trim(p->>'name_ar'), p->>'name_en', p->>'description', v_unit,
            coalesce((p->>'price_halalas')::bigint,0), coalesce((p->>'is_free')::boolean,false), coalesce((p->>'taxable')::boolean,true), v_tt, v_late) returning * into s;
    perform fn_audit_change(s.branch_id, 'service.created', 'service', s.id, null, to_jsonb(s));
  else
    perform fn_check_version_strict(s.version, (p->>'version')::int);
    before := to_jsonb(s);
    -- catalogue edits never touch historical reservation_charges (snapshots) — G27
    update service_definitions set name_ar = trim(p->>'name_ar'), name_en = coalesce(p->>'name_en', name_en), description = coalesce(p->>'description', description),
      billing_unit = v_unit, price_halalas = coalesce((p->>'price_halalas')::bigint, price_halalas),
      is_free = coalesce((p->>'is_free')::boolean, is_free), taxable = coalesce((p->>'taxable')::boolean, taxable), task_type_id = v_tt,
      is_active = coalesce((p->>'is_active')::boolean, is_active), late_checkout_until = v_late, version = version + 1, updated_at = now()
    where id = s.id returning * into s;
    perform fn_audit_change(s.branch_id, 'service.updated', 'service', s.id, before, to_jsonb(s));
  end if;
  return jsonb_build_object('ok', true, 'id', s.id, 'version', s.version);
exception when unique_violation then raise exception 'DUPLICATE_NAME';
end $$;
grant execute on function fn_admin_upsert_service(jsonb) to authenticated;

-- ---------------------------------------------------------------- 13. corrections with time windows (decisions 10, 46)
create or replace function fn_staff_undo_check_in(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; reason text := nullif(trim(coalesce(p->>'reason', '')), ''); shown boolean;
begin
  perform fn_require_role('owner', 'manager');
  if reason is null then raise exception 'VALIDATION: reason'; end if;
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.status <> 'checked_in' then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  if r.actual_check_in is null or now() - r.actual_check_in > interval '30 minutes' then
    raise exception 'CORRECTION_WINDOW_PASSED: an arrival is undone within 30 minutes';
  end if;
  if p ? 'expected_version' then perform fn_check_version(r.version, (p->>'expected_version')::int); end if;
  shown := r.access_status in ('delivered', 'acknowledged');
  update reservations set status = 'confirmed', actual_check_in = null, checked_in_by = null, checkin_approved_by = null, checkin_approved_at = null,
         access_status = 'locked', keybox_delivered = false, version = version + 1, updated_at = now()
   where id = r.id;
  if r.room_id is not null then
    update rooms set status = 'reserved', updated_at = now() where id = r.room_id and status = 'occupied';
    -- a code already given out is no longer the guest's to keep: it must change before anyone gets it
    if shown then update keyboxes set code_status = 'needs_change', field_tested = false where room_id = r.room_id and last_reservation_id = r.id; end if;
  end if;
  perform fn_add_review_item(r.branch_id, 'check_in_undone', 'reservation', r.id, r.id, 'تراجع عن تسجيل وصول ' || r.internal_ref, reason,
    jsonb_build_object('checked_in_at', r.actual_check_in, 'code_was_given', shown));
  perform fn_audit_change(r.branch_id, 'reservation.check_in_undone', 'reservation', r.id,
    jsonb_build_object('status', 'checked_in', 'actual_check_in', r.actual_check_in), jsonb_build_object('status', 'confirmed', 'code_needs_change', shown), reason);
  return jsonb_build_object('ok', true, 'code_needs_change', shown);
end $$;
grant execute on function fn_staff_undo_check_in(jsonb) to authenticated;

create or replace function fn_staff_reopen_stay(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; reason text := nullif(trim(coalesce(p->>'reason', '')), ''); rm rooms%rowtype; kb keyboxes%rowtype;
        has_kb boolean := false; keep_code boolean := false; v_access access_status;
begin
  perform fn_require_role('owner', 'manager');
  if reason is null then raise exception 'VALIDATION: reason'; end if;
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.status not in ('checked_out', 'closed') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  if r.actual_check_out is null or now() - r.actual_check_out > interval '2 hours' then
    raise exception 'CORRECTION_WINDOW_PASSED: a departure is reopened within 2 hours';
  end if;
  if p ? 'expected_version' then perform fn_check_version(r.version, (p->>'expected_version')::int); end if;
  if r.room_id is not null then
    select * into rm from rooms where id = r.room_id for update;
    if not rm.is_active or rm.archived_at is not null or rm.status in ('blocked', 'out_of_service') then raise exception 'ROOM_NOT_AVAILABLE'; end if;
    if exists (select 1 from reservations o where o.room_id = rm.id and o.status = 'checked_in' and o.id <> r.id) then
      raise exception 'ALLOCATION_CONFLICT: another guest is in the unit' using errcode = '23P01';
    end if;
  end if;
  -- the allocations this departure closed come back; if the unit was booked for someone else meanwhile, it is a conflict
  begin
    update reservation_allocations set status = 'active', closed_at = null
     where reservation_id = r.id and status = 'closed' and closed_at = r.actual_check_out;
  exception when exclusion_violation then
    raise exception 'ALLOCATION_CONFLICT: the unit is booked for someone else in this stay''s period' using errcode = '23P01';
  end;
  if r.room_id is not null then
    update rooms set status = 'occupied', updated_at = now() where id = r.room_id;
    -- the departure's cleaning is no longer due
    update housekeeping_tasks set status = 'cancelled', cancelled_at = now(), cancel_reason = 'أُعيد فتح الإقامة: ' || reason, version = version + 1, updated_at = now()
     where reservation_id = r.id and room_id = r.room_id and status in ('pending', 'in_progress') and description = 'تنظيف بعد المغادرة';
    update rooms set cleanliness = 'dirty' where id = r.room_id and cleanliness = 'in_progress';
    select * into kb from keyboxes where room_id = r.room_id limit 1 for update;
    has_kb := found;
    if has_kb and kb.code_status = 'needs_change' and kb.last_reservation_id = r.id then
      -- the guest's code was not changed since: it stays theirs
      update keyboxes set code_status = 'active', field_tested = true where id = kb.id;
      keep_code := true;
    end if;
  end if;
  v_access := case when not has_kb then 'key_handed' when keep_code then r.access_status else 'approved' end;
  update reservations set status = 'checked_in', actual_check_out = null, checked_out_by = null, closed_at = null,
         access_status = v_access, keybox_delivered = case when keep_code then keybox_delivered else false end,
         version = version + 1, updated_at = now()
   where id = r.id;
  update checkout_inspections set status = 'superseded', superseded_at = now(), superseded_by = fn_staff_id() where reservation_id = r.id and status = 'active';
  perform fn_recompute_reservation_finance(r.id);
  perform fn_add_review_item(r.branch_id, 'stay_reopened', 'reservation', r.id, r.id, 'إعادة فتح إقامة ' || r.internal_ref, reason,
    jsonb_build_object('checked_out_at', r.actual_check_out, 'was_closed', r.status = 'closed', 'code_kept', keep_code));
  perform fn_audit_change(r.branch_id, 'reservation.stay_reopened', 'reservation', r.id,
    jsonb_build_object('status', r.status, 'actual_check_out', r.actual_check_out), jsonb_build_object('status', 'checked_in', 'access_status', v_access), reason);
  return jsonb_build_object('ok', true, 'access_status', v_access);
end $$;
grant execute on function fn_staff_reopen_stay(jsonb) to authenticated;

-- cancellation: identical to 0007c, and it remembers the status it cancelled (for the correction within the hour)
create or replace function fn_staff_cancel_reservation(p_reservation uuid, p_reason text, p_source text default 'staff', p_external_event_id text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; ev integration_events%rowtype;
begin
  perform fn_require_role('owner','manager','supervisor');
  if coalesce(trim(p_reason),'') = '' then raise exception 'VALIDATION: reason'; end if;
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if p_external_event_id is not null then
    insert into integration_events(organization_id, source, external_event_id, kind, reference, state)
    values (r.organization_id, coalesce(p_source,'ota'), p_external_event_id, 'reservation.cancelled', r.external_ref, 'received')
    on conflict (organization_id, source, external_event_id) do nothing;
    select * into ev from integration_events where organization_id = r.organization_id and source = coalesce(p_source,'ota') and external_event_id = p_external_event_id;
    if ev.state = 'processed' then
      update integration_events set attempts = attempts + 1 where id = ev.id;
      return jsonb_build_object('ok', true, 'duplicate', true, 'status', r.status);
    end if;
  end if;
  if r.status in ('cancelled','rejected','no_show') then return jsonb_build_object('ok', true, 'duplicate', true, 'status', r.status); end if;
  if r.status in ('checked_in','checked_out','closed') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  perform fn_release_allocations(r.id, 'cancel');
  update reservations set status = 'cancelled', status_before_cancel = r.status::text, cancelled_at = now(), cancel_reason = p_reason, cancel_source = p_source,
         access_status = 'locked', version = version + 1, updated_at = now() where id = r.id;
  if ev.id is not null then update integration_events set state = 'processed', processed_at = now(), result = jsonb_build_object('reservation_id', r.id) where id = ev.id; end if;
  perform fn_audit_change(r.branch_id, 'reservation.cancelled', 'reservation', r.id, jsonb_build_object('status', r.status), jsonb_build_object('status', 'cancelled', 'source', p_source, 'external_event_id', p_external_event_id), p_reason);
  return jsonb_build_object('ok', true, 'duplicate', false, 'status', 'cancelled', 'refund_required_separately', (select (fn_reservation_finance_internal(r.id)->>'net_collected')::bigint > 0 or (fn_reservation_finance_internal(r.id)->>'deposit_balance')::bigint > 0));
end $$;
grant execute on function fn_staff_cancel_reservation(uuid, text, text, text) to authenticated;

create or replace function fn_staff_undo_cancel(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; reason text := nullif(trim(coalesce(p->>'reason', '')), ''); a record; back reservation_status; today date; n int := 0;
begin
  perform fn_require_role('owner', 'manager');
  if reason is null then raise exception 'VALIDATION: reason'; end if;
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.status <> 'cancelled' then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  if r.cancelled_at is null or now() - r.cancelled_at > interval '1 hour' then
    raise exception 'CORRECTION_WINDOW_PASSED: a cancellation is undone within 1 hour';
  end if;
  if p ? 'expected_version' then perform fn_check_version(r.version, (p->>'expected_version')::int); end if;
  today := fn_branch_today(r.branch_id);
  if r.check_out <= today then raise exception 'VALIDATION: stay_ended'; end if;
  if exists (select 1 from room_categories c where c.id = r.room_category_id and c.archived_at is not null) then raise exception 'CATEGORY_ARCHIVED: this unit type is archived'; end if;
  back := case when r.status_before_cancel in ('pending_verification', 'confirmed') then r.status_before_cancel::reservation_status else 'confirmed'::reservation_status end;
  -- the allocations this cancellation released come back; a unit booked for someone else meanwhile is a conflict
  for a in select * from reservation_allocations where reservation_id = r.id and status = 'cancelled' and closed_at = r.cancelled_at order by from_date loop
    perform 1 from rooms where id = a.room_id and is_active and archived_at is null and status not in ('blocked', 'out_of_service', 'maintenance') for update;
    if not found then raise exception 'ROOM_NOT_AVAILABLE'; end if;
    begin
      update reservation_allocations set status = 'active', closed_at = null where id = a.id;
    exception when exclusion_violation then
      raise exception 'ALLOCATION_CONFLICT: the unit was booked for someone else after the cancellation' using errcode = '23P01';
    end;
    if a.from_date <= today and today < a.to_date then
      update rooms set status = 'reserved' where id = a.room_id and status in ('available', 'ready', 'cleaning');
    end if;
    n := n + 1;
  end loop;
  update reservations set status = back, cancelled_at = null, cancel_reason = null, cancel_source = null, status_before_cancel = null,
         version = version + 1, updated_at = now()
   where id = r.id;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_add_review_item(r.branch_id, 'cancel_undone', 'reservation', r.id, r.id, 'تراجع عن إلغاء ' || r.internal_ref, reason,
    jsonb_build_object('cancelled_at', r.cancelled_at, 'cancel_reason', r.cancel_reason, 'allocations_restored', n));
  perform fn_audit_change(r.branch_id, 'reservation.cancel_undone', 'reservation', r.id,
    jsonb_build_object('status', 'cancelled', 'cancel_reason', r.cancel_reason), jsonb_build_object('status', back, 'allocations_restored', n), reason);
  return jsonb_build_object('ok', true, 'status', back);
end $$;
grant execute on function fn_staff_undo_cancel(jsonb) to authenticated;

-- ---------------------------------------------------------------- 14. switching the unit of a guest in house (decision 1)
-- identical to 0019, except: the new unit's code is delivered as its own step (nothing marks it the guest's before
-- that), and a unit without a key box takes its key at reception
create or replace function fn_staff_switch_room(p_reservation uuid, p_room uuid, p_effective date, p_reason text, p_expected_version int default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r reservations%rowtype; old reservation_allocations%rowtype; eff date; old_room uuid; new_rm rooms%rowtype; new_kb boolean;
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
  new_kb := exists (select 1 from keyboxes where room_id = p_room);
  if r.status = 'checked_in' then
    update rooms set status = 'occupied' where id = p_room;
    update reservations set access_status = case when new_kb then 'approved' else 'key_handed' end::access_status, keybox_delivered = false where id = r.id;
  end if;
  update reservations set version = version + 1, updated_at = now() where id = r.id;
  perform fn_audit_change(r.branch_id, 'reservation.room_switched', 'reservation', r.id, jsonb_build_object('room_id', old_room), jsonb_build_object('room_id', p_room, 'effective', eff), p_reason);
  return jsonb_build_object('ok', true, 'from_room', old_room, 'to_room', p_room, 'effective', eff,
                            'entry_code_review_required', r.status = 'checked_in', 'code_delivery_required', r.status = 'checked_in' and new_kb);
end $$;
grant execute on function fn_staff_switch_room(uuid, uuid, date, text, int) to authenticated;

-- ---------------------------------------------------------------- 15. resources with commitments (decision 49)
-- a unit with a guest in house is never deactivated; otherwise identical to 0009
create or replace function fn_admin_upsert_room(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r rooms%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid;
        v_block uuid := (p->>'block_id')::uuid; v_floor uuid := (p->>'floor_id')::uuid; v_cat uuid := (p->>'category_id')::uuid; before jsonb; future_count int;
begin
  perform fn_require_role('owner','manager');
  if v_id is not null then
    select * into r from rooms where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    v_branch := r.branch_id;
    v_block := coalesce(v_block, r.block_id); v_floor := coalesce(v_floor, r.floor_id); v_cat := coalesce(v_cat, r.category_id);
  end if;
  perform fn_require_branch(v_branch);
  if coalesce(trim(p->>'room_number'),'') = '' and v_id is null then raise exception 'VALIDATION: room_number'; end if;
  -- cross-relation consistency: every parent must belong to the same branch (A02)
  if v_cat is null or not exists (select 1 from room_categories where id = v_cat and branch_id = v_branch) then raise exception 'BRANCH_MISMATCH: category'; end if;
  if v_block is not null and not exists (select 1 from blocks where id = v_block and branch_id = v_branch) then raise exception 'BRANCH_MISMATCH: block'; end if;
  if v_floor is not null and not exists (select 1 from floors where id = v_floor and branch_id = v_branch and (v_block is null or block_id = v_block)) then raise exception 'BRANCH_MISMATCH: floor'; end if;

  if v_id is null then
    insert into rooms(organization_id, branch_id, category_id, block_id, floor_id, room_number, floor, status, notes, is_active)
    values (fn_user_org_id(), v_branch, v_cat, v_block, v_floor, trim(p->>'room_number'), coalesce((p->>'floor')::int,1), 'available', p->>'notes', coalesce((p->>'is_active')::boolean, true))
    returning * into r;
    perform fn_audit_change(r.branch_id, 'room.created', 'room', r.id, null, to_jsonb(r));
  else
    perform fn_check_version_strict(r.version, (p->>'version')::int);
    before := to_jsonb(r);
    -- deactivating a room with a guest in house, or future/active commitments, is blocked until they are resolved (A09 / G17)
    if (p->>'is_active')::boolean is false and r.is_active then
      if fn_room_guest_in_house(r.id) then raise exception 'ROOM_HAS_GUEST: a guest is in house'; end if;
      select count(*) into future_count from reservation_allocations a join reservations rs on rs.id = a.reservation_id
        where a.room_id = r.id and a.status = 'active' and rs.status in ('confirmed','checked_in','pending_verification') and a.to_date > fn_branch_today(r.branch_id);
      if future_count > 0 then
        raise exception 'HAS_FUTURE_COMMITMENTS: % allocation(s)', future_count;
      end if;
    end if;
    update rooms set room_number = coalesce(nullif(trim(p->>'room_number'),''), room_number), category_id = v_cat, block_id = v_block, floor_id = v_floor,
      floor = coalesce((p->>'floor')::int, floor), notes = coalesce(p->>'notes', notes), is_active = coalesce((p->>'is_active')::boolean, is_active),
      status = case when coalesce((p->>'is_active')::boolean, is_active) = false then 'out_of_service'
                    when coalesce((p->>'is_active')::boolean, is_active) and status = 'out_of_service' then 'available' else status end,
      version = version + 1, updated_at = now()
    where id = r.id returning * into r;
    perform fn_audit_change(r.branch_id, 'room.updated', 'room', r.id, before, to_jsonb(r));
  end if;
  return jsonb_build_object('ok', true, 'id', r.id, 'version', r.version);
exception when unique_violation then raise exception 'DUPLICATE_ROOM_NUMBER';
end $$;
grant execute on function fn_admin_upsert_room(jsonb) to authenticated;

-- archiving: identical to 0007b, plus a unit with a guest in house, and a type with open stays (even without a unit yet)
create or replace function fn_admin_archive_definition(p_entity text, p_id uuid, p_reason text, p_archive boolean default true) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_branch uuid; v_table text; before jsonb; after jsonb; open_count int := 0;
begin
  perform fn_require_role('owner','manager');
  if p_archive and coalesce(trim(p_reason),'') = '' then raise exception 'VALIDATION: reason'; end if;
  v_table := case p_entity when 'branch' then 'branches' when 'block' then 'blocks' when 'floor' then 'floors' when 'room_category' then 'room_categories'
                           when 'room' then 'rooms' when 'facility' then 'facilities' when 'task_type' then 'task_types' when 'service' then 'service_definitions' end;
  if v_table is null then raise exception 'VALIDATION: entity'; end if;
  execute format('select %s, to_jsonb(t) from %I t where id = $1 for update', case when p_entity = 'branch' then 'id' else 'branch_id' end, v_table) into v_branch, before using p_id;
  if before is null then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(v_branch);
  if p_entity = 'branch' then perform fn_require_role('owner'); end if;

  if p_archive then
    -- open commitments block archiving (G17)
    if p_entity = 'room' then
      if fn_room_guest_in_house(p_id) then raise exception 'ROOM_HAS_GUEST: a guest is in house'; end if;
      select count(*) into open_count from reservation_allocations a join reservations r on r.id = a.reservation_id
        where a.room_id = p_id and a.status = 'active' and r.status in ('confirmed','checked_in','pending_verification') and a.to_date > fn_branch_today(v_branch);
    elsif p_entity = 'facility' then
      select count(*) into open_count from housekeeping_tasks where facility_id = p_id and status in ('pending','in_progress');
    elsif p_entity = 'task_type' then
      select count(*) into open_count from housekeeping_tasks where task_type_id = p_id and status in ('pending','in_progress');
    elsif p_entity in ('block','floor') then
      execute format('select count(*) from rooms where %I = $1 and archived_at is null', case p_entity when 'block' then 'block_id' else 'floor_id' end) into open_count using p_id;
    elsif p_entity = 'room_category' then
      -- the type's row is locked above; a booking on it waits for this (trg_reservation_category_guard), so the count is final
      select count(*) into open_count from rooms where category_id = p_id and archived_at is null;
      open_count := open_count + (select count(*) from reservations where room_category_id = p_id and status in ('confirmed','checked_in','pending_verification')
                                                                    and check_out > fn_branch_today(v_branch));
    elsif p_entity = 'branch' then
      select count(*) into open_count from reservations where branch_id = p_id and status in ('confirmed','checked_in','pending_verification') and check_out > fn_branch_today(p_id);
      if (select count(*) from branches where organization_id = fn_user_org_id() and archived_at is null and is_active) <= 1 then raise exception 'LAST_ACTIVE_BRANCH'; end if;
    end if;
    if open_count > 0 then raise exception 'HAS_OPEN_COMMITMENTS: %', open_count; end if;
    execute format('update %I set archived_at = now(), archived_by = $2, archive_reason = $3, is_active = false, version = version + 1, updated_at = now() where id = $1 returning to_jsonb(%I)', v_table, v_table)
      into after using p_id, fn_staff_id(), p_reason;
    if p_entity = 'room' then update rooms set status = 'out_of_service' where id = p_id; end if;
  else
    execute format('update %I set archived_at = null, archived_by = null, archive_reason = null, is_active = true, version = version + 1, updated_at = now() where id = $1 returning to_jsonb(%I)', v_table, v_table)
      into after using p_id;
    if p_entity = 'room' then update rooms set status = 'available' where id = p_id and status = 'out_of_service'; end if;
  end if;
  perform fn_audit_change(v_branch, p_entity || case when p_archive then '.archived' else '.restored' end, p_entity, p_id, before, after, p_reason);
  return jsonb_build_object('ok', true);
end $$;
grant execute on function fn_admin_archive_definition(text, uuid, text, boolean) to authenticated;

-- a booking holds its type's row while it is written: archiving the type waits for it, or the booking is refused
create or replace function fn_guard_reservation_category() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.room_category_id is not null and new.status in ('draft', 'pending_verification', 'confirmed', 'checked_in') then
    perform 1 from room_categories where id = new.room_category_id and archived_at is null for share;
    if not found then raise exception 'CATEGORY_ARCHIVED: this unit type is archived'; end if;
  end if;
  return new;
end $$;
revoke all on function fn_guard_reservation_category() from public, anon, authenticated;
create or replace trigger trg_reservation_category_guard before insert or update of room_category_id on reservations
  for each row execute function fn_guard_reservation_category();

-- ---------------------------------------------------------------- 16. manual cleanliness, free (decision 12)
-- The change no longer waits for an open cleaning task: it is recorded with who and when, and the task keeps its own
-- state (completing it later still works). A deliberate deviation from G18, by the owner's decision.
create or replace function fn_hk_set_cleanliness(p_room uuid, p_state text, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare rm rooms%rowtype; st room_status;
begin
  perform fn_require_role('owner','manager','supervisor','housekeeping');
  if p_state is null or p_state not in ('clean','dirty') then raise exception 'VALIDATION: cleanliness'; end if;
  select * into rm from rooms where id = p_room for update;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  perform fn_require_branch(rm.branch_id);
  update rooms set cleanliness = p_state, updated_at = now() where id = p_room;
  st := fn_recompute_room_ready(p_room);
  perform fn_audit_change(rm.branch_id, 'room.cleanliness_changed', 'room', p_room, jsonb_build_object('cleanliness', rm.cleanliness),
    jsonb_build_object('cleanliness', p_state, 'open_cleaning_task', exists (select 1 from housekeeping_tasks h join task_types t on t.id = h.task_type_id
                                                                            where h.room_id = p_room and h.status in ('pending','in_progress') and t.code = 'room_cleaning')), p_reason);
  return jsonb_build_object('ok', true, 'room_status', (select status from rooms where id = p_room));
end $$;
grant execute on function fn_hk_set_cleanliness(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------- 17. the stay page, the daily follow-up, the per-employee day
create or replace function fn_stay_status(p_reservation uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r reservations%rowtype; br branches%rowtype; money boolean; mgr boolean; kb keyboxes%rowtype; has_kb boolean := false; d jsonb; dep time; loc timestamp;
        insp record; exc record; missing text[]; stayed boolean; refund_blocker text; checkin jsonb; code jsonb;
begin
  select * into r from reservations where id = p_reservation;
  if not found or not fn_has_role('owner', 'manager', 'supervisor', 'finance', 'housekeeping')
     or not (r.branch_id in (select fn_user_branch_ids())) then return null; end if;
  money := fn_has_role('owner', 'manager', 'supervisor', 'finance');
  mgr := fn_has_role('owner', 'manager');
  select * into br from branches where id = r.branch_id;
  if r.room_id is not null then select * into kb from keyboxes where room_id = r.room_id limit 1; has_kb := found; end if;
  dep := coalesce(r.late_checkout_until, br.check_out_time, time '12:00');
  loc := fn_branch_local_now(r.branch_id);
  if money then d := fn_stay_due_internal(r.id); end if;
  select i.result, i.notes, i.suggested_deduction_halalas, i.inspected_at, s.full_name as by_name into insp
    from checkout_inspections i left join staff_profiles s on s.id = i.inspected_by
   where i.reservation_id = r.id and i.status = 'active' order by i.inspected_at desc limit 1;
  select e.reason, e.through_night, e.created_at, s.full_name as by_name into exc
    from stay_payment_exceptions e left join staff_profiles s on s.id = e.created_by
   where e.reservation_id = r.id order by e.created_at desc limit 1;
  if r.status in ('checked_out', 'closed') then missing := fn_closure_missing(r.id); end if;
  stayed := r.actual_check_in is not null or r.status in ('checked_in', 'checked_out', 'closed');
  refund_blocker := case when not stayed then null
                         when r.status not in ('checked_out', 'closed') then 'يُرد التأمين بعد تسجيل المغادرة'
                         when insp.result is null then 'سجّل فحص المغادرة أولًا'
                         else null end;
  if r.status in ('draft', 'pending_verification', 'confirmed') then
    checkin := jsonb_build_object('blockers', to_jsonb(fn_checkin_core_blockers(r.id)));
    if money then
      checkin := checkin || jsonb_build_object('money_blockers', to_jsonb(fn_checkin_money_blockers(r.id, 0, 0, null)),
        'first_night', (d->>'first_night')::bigint, 'collected', (d->>'collected')::bigint,
        'first_night_short', greatest((d->>'first_night')::bigint - (d->>'collected')::bigint, 0),
        'deposit_required', (d->>'deposit_required')::bigint, 'deposit_balance', (d->>'deposit_balance')::bigint,
        'deposit_short', greatest((d->>'deposit_required')::bigint - (d->>'deposit_balance')::bigint, 0));
    end if;
  end if;
  if r.status = 'checked_in' then
    code := jsonb_build_object('blockers', to_jsonb(fn_code_blockers(r.id)), 'delivered', r.access_status in ('delivered', 'acknowledged'));
  end if;
  return jsonb_build_object(
    'status', r.status, 'version', r.version, 'access_status', r.access_status,
    'room_number', (select room_number from rooms where id = r.room_id), 'has_keybox', has_kb,
    'keybox_state', case when not has_kb then 'none' when kb.code_encrypted is null then 'unset' when kb.code_status <> 'active' then 'needs_change'
                         when not kb.field_tested then 'untested' else 'ready' end,
    'departure_time', to_char(dep, 'HH24:MI'), 'late_checkout_until', to_char(r.late_checkout_until, 'HH24:MI'),
    'late_departure', r.status = 'checked_in' and loc > (r.check_out + dep),
    'checked_in_at', r.actual_check_in, 'checked_in_by', (select full_name from staff_profiles where id = r.checked_in_by),
    'checked_out_at', r.actual_check_out, 'checked_out_by', (select full_name from staff_profiles where id = r.checked_out_by),
    'checkin', checkin, 'code', code,
    'due', case when money then d end,
    'overdue_blocked', case when money and r.status = 'checked_in' then fn_overdue_blocked(r.id) end,
    'payment_exception', case when money and exc.reason is not null then jsonb_build_object('reason', exc.reason, 'through_night', exc.through_night, 'by', exc.by_name, 'at', exc.created_at) end,
    'deposit_waiver', case when money and r.deposit_waiver_reason is not null then jsonb_build_object('reason', r.deposit_waiver_reason, 'at', r.deposit_waiver_at,
                                                                                                  'by', (select full_name from staff_profiles where id = r.deposit_waiver_by)) end,
    'shomoos', jsonb_build_object('registered', coalesce(r.government_registration, false) and r.gov_registration_ref is not null,
                                  'reference', case when money then r.gov_registration_ref end, 'registered_at', r.gov_registration_at,
                                  'registered_by', (select full_name from staff_profiles where id = r.gov_registration_by),
                                  'guest_count', r.shomoos_guest_count, 'guests_now', r.adults + r.companions,
                                  'accepted_at', r.shomoos_accepted_at, 'accepted_by', (select full_name from staff_profiles where id = r.shomoos_accepted_by)),
    'inspection', case when insp.result is not null then jsonb_build_object('result', insp.result, 'notes', insp.notes,
                                                                            'suggested', case when money then insp.suggested_deduction_halalas end,
                                                                            'by', insp.by_name, 'at', insp.inspected_at) end,
    'inspection_due', r.status = 'checked_out' or (r.status = 'checked_in' and loc::date >= r.check_out),
    'deposit_refund_blocker', case when money then refund_blocker end,
    'corrections', jsonb_build_object(
        'allowed', mgr,
        'undo_check_in_until', case when r.status = 'checked_in' and r.actual_check_in > now() - interval '30 minutes' then r.actual_check_in + interval '30 minutes' end,
        'reopen_until', case when r.status in ('checked_out', 'closed') and r.actual_check_out > now() - interval '2 hours' then r.actual_check_out + interval '2 hours' end,
        'undo_cancel_until', case when r.status = 'cancelled' and r.cancelled_at > now() - interval '1 hour' then r.cancelled_at + interval '1 hour' end),
    'closure', case when r.status in ('checked_out', 'closed') then jsonb_build_object('closed', r.status = 'closed', 'closed_at', r.closed_at,
                                                                                       'missing', case when money then to_jsonb(missing) else '[]'::jsonb end) end);
end $$;
grant execute on function fn_stay_status(uuid) to authenticated;

-- the supervisor's daily follow-up: overdue nights, departures not yet closed, guests past their departure time
create or replace function fn_stay_followups(p_branch uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare loc timestamp; cot time; v_over jsonb; v_open jsonb; v_late jsonb;
begin
  perform fn_require_role('owner', 'manager', 'supervisor', 'finance');
  perform fn_require_branch(p_branch);
  loc := fn_branch_local_now(p_branch);
  cot := coalesce((select check_out_time from branches where id = p_branch), time '12:00');
  select coalesce(jsonb_agg(x order by x->>'overdue_since'), '[]'::jsonb) into v_over from (
    select jsonb_build_object('id', r.id, 'internal_ref', r.internal_ref, 'room_number', (select room_number from rooms where id = r.room_id),
             'guest', (select full_name from reservation_guests g where g.reservation_id = r.id and g.is_primary limit 1),
             'overdue_amount', (dd.d->>'overdue_amount')::bigint, 'overdue_since', dd.d->>'overdue_since', 'check_out', r.check_out,
             'excused', not fn_overdue_blocked(r.id)) as x
    from reservations r cross join lateral (select fn_stay_due_internal(r.id) as d) dd
    where r.branch_id = p_branch and r.status = 'checked_in' and coalesce((dd.d->>'overdue')::boolean, false)) s;
  select coalesce(jsonb_agg(x order by x->>'checked_out_at'), '[]'::jsonb) into v_open from (
    select jsonb_build_object('id', r.id, 'internal_ref', r.internal_ref, 'room_number', (select room_number from rooms where id = r.room_id),
             'guest', (select full_name from reservation_guests g where g.reservation_id = r.id and g.is_primary limit 1),
             'checked_out_at', r.actual_check_out, 'missing', to_jsonb(fn_closure_missing(r.id)),
             'inspected', exists (select 1 from checkout_inspections i where i.reservation_id = r.id and i.status = 'active'),
             'deposit_balance', r.deposit_balance_halalas) as x
    from reservations r where r.branch_id = p_branch and r.status = 'checked_out') s;
  select coalesce(jsonb_agg(x order by x->>'check_out'), '[]'::jsonb) into v_late from (
    select jsonb_build_object('id', r.id, 'internal_ref', r.internal_ref, 'room_number', (select room_number from rooms where id = r.room_id),
             'guest', (select full_name from reservation_guests g where g.reservation_id = r.id and g.is_primary limit 1),
             'check_out', r.check_out, 'departure_time', to_char(coalesce(r.late_checkout_until, cot), 'HH24:MI')) as x
    from reservations r where r.branch_id = p_branch and r.status = 'checked_in' and loc > (r.check_out + coalesce(r.late_checkout_until, cot))) s;
  return jsonb_build_object('generated_at', now(), 'overdue', v_over, 'departed_open', v_open, 'late_departures', v_late);
end $$;
grant execute on function fn_stay_followups(uuid) to authenticated;

-- what each employee received and paid back on one day of the branch, by method (decision 5); a supervisor sees their own
create or replace function fn_staff_day_summary(p_branch uuid, p_date date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare tz text; ds timestamptz; de timestamptz; everyone boolean; v jsonb;
begin
  perform fn_require_role('owner', 'manager', 'supervisor', 'finance');
  perform fn_require_branch(p_branch);
  if p_date is null then raise exception 'VALIDATION: business_date'; end if;
  everyone := fn_has_role('owner', 'manager', 'finance');
  tz := coalesce((select timezone from branches where id = p_branch), 'Asia/Riyadh');
  ds := p_date::timestamp at time zone tz;
  de := (p_date + 1)::timestamp at time zone tz;
  select coalesce(jsonb_agg(jsonb_build_object('staff_id', t.staff_id, 'staff_name', t.staff_name, 'kind', t.kind, 'method', t.method,
                                              'count', t.n, 'total', t.total) order by t.staff_name, t.kind, t.method), '[]'::jsonb) into v
  from (select v2.created_by as staff_id, coalesce(s.full_name, '—') as staff_name, v2.kind, case when v2.kind = 'deposit_apply' then null else v2.method::text end as method,
               count(*) as n, sum(v2.amount_halalas) as total
        from financial_vouchers v2 left join staff_profiles s on s.id = v2.created_by
        where v2.branch_id = p_branch and v2.status = 'approved' and v2.occurred_at >= ds and v2.occurred_at < de
          and (everyone or v2.created_by = fn_staff_id())
        group by 1, 2, 3, 4) t;
  return jsonb_build_object('date', p_date, 'everyone', everyone, 'rows', v);
end $$;
grant execute on function fn_staff_day_summary(uuid, date) to authenticated;

-- ---------------------------------------------------------------- 18. the guest's page
-- identical to 0005, plus whether the unit has a key box and whether the first night is paid
create or replace function fn_guest_session(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  rid uuid := fn_token_reservation(p_token);
  r reservations%rowtype;
  ev record;
  d jsonb;
begin
  select * into r from reservations where id = rid;
  select * into ev from fn_evaluate_access(rid, false);
  d := fn_stay_due_internal(rid);
  return jsonb_build_object(
    'reservation', jsonb_build_object(
      'id', r.id, 'internal_ref', r.internal_ref, 'external_ref', r.external_ref, 'status', r.status,
      'check_in', r.check_in, 'check_out', r.check_out, 'adults', r.adults, 'companions', r.companions,
      'payment_status', r.payment_status, 'identity_status', r.identity_status,
      'government_registration', r.government_registration, 'access_status', r.access_status,
      'total_halalas', r.total_halalas, 'paid_halalas', r.paid_halalas,
      'has_keybox', exists (select 1 from keyboxes k where k.room_id = r.room_id),
      'first_night_paid', coalesce((d->>'collected')::bigint >= (d->>'first_night')::bigint, false),
      'branch_name', (select name_ar from branches where id = r.branch_id),
      'room_number', (select room_number from rooms where id = r.room_id),
      'category_name', (select name_ar from room_categories where id = r.room_category_id)),
    'guests', coalesce((select jsonb_agg(jsonb_build_object(
        'id', g.id, 'is_primary', g.is_primary, 'full_name', g.full_name, 'identity_type', g.identity_type,
        'identity_number_last4', g.identity_number_last4, 'nationality', g.nationality, 'birth_date', g.birth_date,
        'relationship', g.relationship, 'verification_status', g.verification_status, 'data_submitted', g.data_submitted)
        order by g.is_primary desc, g.created_at)
      from reservation_guests g where g.reservation_id = rid), '[]'::jsonb),
    'access', jsonb_build_object('allowed', ev.allowed, 'reasons', ev.reasons),
    'expires_at', (select expires_at from registration_sessions where token = p_token));
end $$;
grant execute on function fn_guest_session(text) to anon, authenticated;

-- «وصلت»: the guest tells reception they are here; the arrival itself is registered by reception
create or replace function fn_guest_submit_checkin(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare rid uuid := fn_token_reservation(p_token); r reservations%rowtype;
begin
  select * into r from reservations where id = rid for update;
  if r.access_status = 'locked' then
    update reservations set access_status = 'eligibility_review', updated_at = now() where id = rid;
    insert into access_release_requests(reservation_id, status) values (rid, 'eligibility_review');
    insert into notifications(branch_id, audience, title, body, link)
    values (r.branch_id, 'supervisor', 'وصل النزيل', 'الحجز ' || r.internal_ref || ' — سجّل وصوله', '/staff/reservations/' || r.id);
    perform fn_audit(r.organization_id, r.branch_id, null, 'guest_checkin_request', 'reservation', rid, '{}'::jsonb);
  end if;
  return jsonb_build_object('ok', true, 'access_status', (select access_status from reservations where id = rid));
end $$;
grant execute on function fn_guest_submit_checkin(text) to anon, authenticated;

-- the daily summary: identical to 0019, except that a departure already «مغلق» (settled at once) still counts as done today
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
      'done', (select count(*) from reservations where branch_id = p_branch and check_out = p_date and status in ('checked_out', 'closed')),
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
revoke all on function fn_ops_daily_summary_at(uuid, date) from public, anon, authenticated;

-- ---------------------------------------------------------------- 19. the data as it stands
-- units without a key box: clean and out of maintenance is ready (decision 7)
do $$ declare x record; begin
  for x in select rm.id from rooms rm where rm.status = 'cleaning' and rm.cleanliness = 'clean' and not exists (select 1 from keyboxes k where k.room_id = rm.id) loop
    perform fn_recompute_room_ready(x.id);
  end loop;
end $$;
-- departures already settled are closed (decision 59)
do $$ declare x record; begin
  for x in select id from reservations where status = 'checked_out' loop perform fn_sync_closed(x.id); end loop;
end $$;
