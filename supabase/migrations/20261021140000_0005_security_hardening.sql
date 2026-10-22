/*
# 0005 — Security Hardening & Server-Side Business Rules

This migration moves every sensitive decision to the database (SECURITY DEFINER
RPCs with explicit role checks), fixes the defects found in the audit, and adds
the tables the AI engine needs.

Summary of changes
  1. Fix fn_get_public_availability (runtime crash: ambiguous column) and make it
     honour inventory, blocked units, public cap and the sequential release rule.
  2. Real overlap protection (EXCLUDE constraint on daterange) instead of a unique
     index on exact dates.
  3. Role helpers + role-aware RLS. Column-level revokes on encrypted columns.
  4. Guest flow via short-lived tokens (RPC only, no anon table access):
     fn_guest_lookup, fn_guest_session, fn_guest_submit, fn_guest_access_code.
  5. Staff RPCs: approve identity, confirm payment (idempotent), gov registration,
     assign room, approve check-in, deliver code, checkout, cleaning, keybox
     rotation, maintenance, manual release.
  6. Keybox / identity encryption keys are read from DB settings
     (app.keybox_key / app.identity_key) — never from the client, never in seeds.
  7. AI engine tables: ai_settings, ai_usage_daily, ai_tool_executions,
     ai_guardrail_events, human_handoff_tickets, guest_lookup_attempts.
  8. Revoke anon/authenticated EXECUTE on privileged functions.
*/

create extension if not exists btree_gist;

-- =====================================================================
-- 1. SECRETS (server-side only)
--    Set once per environment, e.g.:
--    alter database postgres set app.keybox_key   = '<random-32-bytes>';
--    alter database postgres set app.identity_key = '<random-32-bytes>';
-- =====================================================================
create or replace function fn_secret(p_name text) returns text
language plpgsql stable security definer set search_path = public as $$
declare v text;
begin
  v := current_setting('app.' || p_name, true);
  if v is null or v = '' then
    raise exception 'SECRET_NOT_CONFIGURED: app.%', p_name using errcode = 'P0001';
  end if;
  return v;
end $$;
revoke all on function fn_secret(text) from public, anon, authenticated;

-- =====================================================================
-- 2. ROLE HELPERS
-- =====================================================================
create or replace function fn_staff_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from staff_profiles where auth_user_id = auth.uid() and is_active limit 1;
$$;

create or replace function fn_current_role() returns role_code
language sql stable security definer set search_path = public as $$
  select role from staff_profiles where auth_user_id = auth.uid() and is_active limit 1;
$$;

create or replace function fn_has_role(variadic p_roles role_code[]) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(fn_current_role() = any(p_roles), false);
$$;

-- Branches the current staff may act on (owner: all org branches; others: memberships)
create or replace function fn_user_branch_ids() returns setof uuid
language sql stable security definer set search_path = public as $$
  select b.id from branches b
  where b.organization_id = fn_user_org_id()
    and (fn_has_role('owner') or exists (
      select 1 from branch_memberships m where m.branch_id = b.id and m.staff_id = fn_staff_id()));
$$;

create or replace function fn_require_role(variadic p_roles role_code[]) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not fn_has_role(variadic p_roles) then
    raise exception 'FORBIDDEN: requires one of %', p_roles using errcode = '42501';
  end if;
end $$;

create or replace function fn_require_branch(p_branch uuid) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from fn_user_branch_ids() b where b = p_branch) then
    raise exception 'FORBIDDEN: branch not permitted' using errcode = '42501';
  end if;
end $$;

-- =====================================================================
-- 3. SCHEMA ADDITIONS
-- =====================================================================
alter table reservations add column if not exists security_hold boolean not null default false;
alter table reservations add column if not exists security_hold_reason text;
alter table reservations add column if not exists gov_registration_ref text;
alter table reservations add column if not exists gov_registration_by uuid;
alter table reservations add column if not exists gov_registration_at timestamptz;
alter table reservations add column if not exists updated_at timestamptz default now();

alter table keyboxes add column if not exists last_delivered_at timestamptz;

alter table conversations add column if not exists branch_id uuid references branches(id) on delete cascade;
alter table conversations add column if not exists guest_token text;
alter table conversations add column if not exists client_fingerprint text;
alter table conversations add column if not exists last_message_at timestamptz default now();
alter table conversations add column if not exists handed_off_at timestamptz;
alter table conversations add column if not exists handoff_reason text;

alter table conversation_messages add column if not exists meta jsonb;

create table if not exists code_rotation_events (
  id uuid primary key default gen_random_uuid(),
  keybox_id uuid not null references keyboxes(id) on delete cascade,
  room_id uuid not null references rooms(id) on delete cascade,
  from_version int,
  to_version int not null,
  rotated_by uuid,
  field_tested boolean not null default false,
  created_at timestamptz default now()
);

create table if not exists human_handoff_tickets (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid references organizations(id) on delete cascade,
  branch_id uuid references branches(id) on delete cascade,
  reservation_id uuid references reservations(id) on delete set null,
  conversation_id uuid references conversations(id) on delete set null,
  kind text not null check (kind in ('unmatched_reservation','assistance','escalation','ai_guardrail','ai_fallback')),
  external_ref text,
  source_name text,
  details jsonb,
  status text not null default 'open' check (status in ('open','in_progress','resolved')),
  resolved_by uuid,
  resolved_at timestamptz,
  created_at timestamptz default now()
);
create index if not exists idx_handoff_branch_status on human_handoff_tickets(branch_id, status);

create table if not exists guest_lookup_attempts (
  id uuid primary key default gen_random_uuid(),
  external_ref text not null,
  client_fingerprint text,
  ok boolean not null,
  created_at timestamptz default now()
);
create index if not exists idx_lookup_attempts_ref on guest_lookup_attempts(external_ref, created_at);

-- AI engine ------------------------------------------------------------
create table if not exists ai_settings (
  organization_id uuid primary key references organizations(id) on delete cascade,
  enabled boolean not null default false,
  provider text not null default 'gemini' check (provider in ('gemini','none')),
  model text not null default 'gemini-2.5-flash',
  temperature numeric(3,2) not null default 0.2 check (temperature between 0 and 1),
  max_output_tokens int not null default 400 check (max_output_tokens between 50 and 2000),
  timeout_ms int not null default 12000 check (timeout_ms between 2000 and 60000),
  daily_request_limit int not null default 2000,
  daily_token_budget int not null default 500000,
  per_session_message_limit int not null default 40,
  strict_scope boolean not null default true,
  extra_instructions text,
  updated_by uuid,
  updated_at timestamptz default now()
);

create table if not exists ai_usage_daily (
  organization_id uuid not null references organizations(id) on delete cascade,
  day date not null default current_date,
  requests int not null default 0,
  tokens_in bigint not null default 0,
  tokens_out bigint not null default 0,
  fallbacks int not null default 0,
  guardrail_blocks int not null default 0,
  primary key (organization_id, day)
);

create table if not exists ai_tool_executions (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid references conversations(id) on delete cascade,
  tool_name text not null,
  args_redacted jsonb,
  result_status text not null,          -- ok | denied | error
  latency_ms int,
  created_at timestamptz default now()
);

create table if not exists ai_guardrail_events (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid references conversations(id) on delete cascade,
  stage text not null,                  -- input | tool | output | budget
  rule text not null,
  detail text,
  created_at timestamptz default now()
);

create table if not exists system_settings (
  organization_id uuid primary key references organizations(id) on delete cascade,
  demo_mode boolean not null default true,
  updated_at timestamptz default now()
);
insert into system_settings (organization_id, demo_mode)
values ('00000000-0000-0000-0000-000000000001', true) on conflict do nothing;
insert into ai_settings (organization_id) values ('00000000-0000-0000-0000-000000000001') on conflict do nothing;

-- =====================================================================
-- 4. REAL OVERLAP PROTECTION
-- =====================================================================
drop index if exists uniq_reservation_room_overlap;
alter table reservations drop constraint if exists reservations_no_overlap;
alter table reservations add constraint reservations_no_overlap
  exclude using gist (
    room_id with =,
    daterange(check_in, check_out, '[)') with &&
  ) where (room_id is not null and status in ('confirmed','checked_in'));

alter table reservations drop constraint if exists reservations_dates_valid;
alter table reservations add constraint reservations_dates_valid check (check_out > check_in);

create unique index if not exists uniq_reservation_source_ref
  on reservations (organization_id, source_id, external_ref) where external_ref is not null;

-- =====================================================================
-- 5. AVAILABILITY (fixed) & SEQUENTIAL RELEASE
-- =====================================================================
drop function if exists fn_get_public_availability(uuid, date);
create or replace function fn_get_public_availability(p_branch uuid, p_date date)
returns table(category_id uuid, category_name text, base_price_halalas bigint, base_capacity int, max_capacity int,
              available_to_show int, total_available int)
language sql stable security definer set search_path = public as $$
  with occ as (
    select r.room_category_id as cat, count(*)::int as n
    from reservations r
    where r.branch_id = p_branch
      and r.status in ('confirmed','checked_in')
      and p_date >= r.check_in and p_date < r.check_out
    group by r.room_category_id
  )
  select rc.id, rc.name_ar, rc.base_price_halalas, rc.base_capacity, rc.max_capacity,
    greatest(0, least(
      -- display cap: when the sequential rule is enabled the released counter governs,
      -- otherwise the static "publicly visible" number set by management governs
      case when coalesce(rr.enabled,false)
           then coalesce(rs.released_count, rr.initial_public_release)
           else coalesce(ip.publicly_visible_units, 0) end,
      -- never above actual free stock
      coalesce(ip.total_units,0) - coalesce(ip.blocked_units,0) - coalesce(o.n,0)
    ))::int as available_to_show,
    greatest(0, coalesce(ip.total_units,0) - coalesce(ip.blocked_units,0) - coalesce(o.n,0))::int as total_available
  from room_categories rc
  left join inventory_periods ip on ip.category_id = rc.id and ip.branch_id = p_branch and ip.date = p_date
  left join release_rules rr on rr.category_id = rc.id and rr.branch_id = p_branch
  left join released_slots rs on rs.category_id = rc.id and rs.branch_id = p_branch and rs.date = p_date
  left join occ o on o.cat = rc.id
  where rc.branch_id = p_branch and rc.is_active and rc.is_public
  order by rc.sort_order;
$$;
grant execute on function fn_get_public_availability(uuid, date) to anon, authenticated;

-- Internal (not exposed): release next slot, capped by real stock.
drop function if exists fn_release_next_slot(uuid, uuid, date);
create or replace function fn_release_next_slot(p_branch uuid, p_category uuid, p_date date)
returns int
language plpgsql security definer set search_path = public as $$
declare
  rr release_rules%rowtype;
  current_released int;
  stock int;
  new_count int;
begin
  select * into rr from release_rules where branch_id = p_branch and category_id = p_category for update;
  if not found or not rr.enabled then return null; end if;

  select coalesce(released_count, 0) into current_released
  from released_slots where branch_id = p_branch and category_id = p_category and date = p_date for update;
  current_released := coalesce(current_released, rr.initial_public_release);

  select greatest(0, coalesce(ip.total_units,0) - coalesce(ip.blocked_units,0)) into stock
  from inventory_periods ip where ip.branch_id = p_branch and ip.category_id = p_category and ip.date = p_date;
  stock := coalesce(stock, 0);

  new_count := least(current_released + rr.release_increment, stock);

  insert into released_slots (branch_id, category_id, date, released_count, updated_at)
  values (p_branch, p_category, p_date, new_count, now())
  on conflict (branch_id, category_id, date)
  do update set released_count = excluded.released_count, updated_at = now();
  return new_count;
end $$;
revoke all on function fn_release_next_slot(uuid, uuid, date) from public, anon, authenticated;

-- Manual release by manager/owner with documented reason
create or replace function fn_staff_release_next_slot(p_branch uuid, p_category uuid, p_date date, p_reason text)
returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform fn_require_role('owner','manager');
  perform fn_require_branch(p_branch);
  if coalesce(trim(p_reason),'') = '' then raise exception 'REASON_REQUIRED'; end if;
  n := fn_release_next_slot(p_branch, p_category, p_date);
  perform fn_audit(fn_user_org_id(), p_branch, fn_staff_id(), 'manual_release_slot', 'release_rule', p_category,
                   jsonb_build_object('date', p_date, 'reason', p_reason, 'released', n));
  return n;
end $$;
grant execute on function fn_staff_release_next_slot(uuid, uuid, date, text) to authenticated;

-- =====================================================================
-- 6. ACCESS GATE (server computed, with date window & security hold)
-- =====================================================================
drop function if exists fn_evaluate_access(uuid);
create or replace function fn_evaluate_access(p_reservation uuid, p_skip_supervisor boolean default false)
returns table(allowed boolean, reasons text[])
language plpgsql stable security definer set search_path = public as $$
declare
  r reservations%rowtype;
  rm rooms%rowtype;
  kb keyboxes%rowtype;
  v_reasons text[] := '{}';
  guest_count int;
  submitted_count int;
  verified_count int;
begin
  select * into r from reservations where id = p_reservation;
  if not found then
    return query select false, array['الحجز غير موجود']::text[]; return;
  end if;

  if r.status not in ('confirmed','checked_in') then v_reasons := array_append(v_reasons, 'الحجز غير مؤكد'); end if;
  if r.security_hold then v_reasons := array_append(v_reasons, 'يوجد حظر أمني على الحجز'); end if;
  if current_date < r.check_in or current_date >= r.check_out then v_reasons := array_append(v_reasons, 'التاريخ الحالي خارج فترة الإقامة'); end if;

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
-- Staff only; guests get the token-scoped version below.
revoke all on function fn_evaluate_access(uuid, boolean) from public, anon;
grant execute on function fn_evaluate_access(uuid, boolean) to authenticated;

-- =====================================================================
-- 7. GUEST FLOW (token-scoped RPCs; anon has NO table access)
-- =====================================================================
create or replace function fn_guest_lookup(p_external_ref text, p_phone_last4 text, p_source_id uuid default null, p_fingerprint text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r reservations%rowtype;
  pg reservation_guests%rowtype;
  v_ref text := upper(trim(p_external_ref));
  v_token text;
  attempts int;
  v_match boolean := false;
begin
  if v_ref = '' or p_phone_last4 !~ '^\d{4}$' then
    return jsonb_build_object('status','invalid');
  end if;

  -- brute-force throttle: 5 failed attempts / 15 min per reference
  select count(*) into attempts from guest_lookup_attempts
   where external_ref = v_ref and not ok and created_at > now() - interval '15 minutes';
  if attempts >= 5 then
    return jsonb_build_object('status','throttled');
  end if;

  select * into r from reservations
   where upper(external_ref) = v_ref and (p_source_id is null or source_id = p_source_id)
     and status not in ('cancelled','rejected','closed')
   limit 1;

  if not found then
    insert into guest_lookup_attempts(external_ref, client_fingerprint, ok) values (v_ref, p_fingerprint, false);
    insert into human_handoff_tickets(organization_id, branch_id, kind, external_ref, source_name, details)
    select o.id, null, 'unmatched_reservation', v_ref, (select name from booking_sources where id = p_source_id),
           jsonb_build_object('phone_last4_given', true)
    from organizations o limit 1;
    return jsonb_build_object('status','unmatched');
  end if;

  select * into pg from reservation_guests where reservation_id = r.id and is_primary limit 1;
  if found and pg.phone is not null and right(regexp_replace(pg.phone,'\D','','g'),4) = p_phone_last4 then
    v_match := true;
  elsif found and pg.guest_profile_id is not null then
    select right(regexp_replace(phone,'\D','','g'),4) = p_phone_last4 into v_match from guest_profiles where id = pg.guest_profile_id;
  end if;

  insert into guest_lookup_attempts(external_ref, client_fingerprint, ok) values (v_ref, p_fingerprint, coalesce(v_match,false));
  if not coalesce(v_match,false) then
    return jsonb_build_object('status','mismatch');
  end if;

  insert into registration_sessions(reservation_id, expires_at) values (r.id, now() + interval '24 hours')
  returning token into v_token;
  perform fn_audit(r.organization_id, r.branch_id, null, 'guest_verified_lookup', 'reservation', r.id, jsonb_build_object('channel','web'));
  return jsonb_build_object('status','ok','token', v_token);
end $$;
grant execute on function fn_guest_lookup(text, text, uuid, text) to anon, authenticated;

-- Resolve a token to a reservation id (internal)
create or replace function fn_token_reservation(p_token text) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare v uuid;
begin
  select reservation_id into v from registration_sessions
   where token = p_token and expires_at > now() limit 1;
  if v is null then raise exception 'TOKEN_INVALID' using errcode = 'P0002'; end if;
  return v;
end $$;
revoke all on function fn_token_reservation(text) from public, anon, authenticated;

create or replace function fn_guest_session(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  rid uuid := fn_token_reservation(p_token);
  r reservations%rowtype;
  ev record;
begin
  select * into r from reservations where id = rid;
  select * into ev from fn_evaluate_access(rid, false);
  return jsonb_build_object(
    'reservation', jsonb_build_object(
      'id', r.id, 'internal_ref', r.internal_ref, 'external_ref', r.external_ref, 'status', r.status,
      'check_in', r.check_in, 'check_out', r.check_out, 'adults', r.adults, 'companions', r.companions,
      'payment_status', r.payment_status, 'identity_status', r.identity_status,
      'government_registration', r.government_registration, 'access_status', r.access_status,
      'total_halalas', r.total_halalas, 'paid_halalas', r.paid_halalas,
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

-- Submit / complete a guest record. Identity number encrypted server-side; only last4 kept in clear.
create or replace function fn_guest_submit(p_token text, p_guest_id uuid, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
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
  if v_birth > current_date or v_birth < current_date - interval '120 years' then raise exception 'VALIDATION: birth_date_range'; end if;
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
grant execute on function fn_guest_submit(text, uuid, jsonb) to anon, authenticated;

-- Guest confirms arrival → check-in request to supervisor
create or replace function fn_guest_submit_checkin(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare rid uuid := fn_token_reservation(p_token); r reservations%rowtype;
begin
  select * into r from reservations where id = rid for update;
  if r.access_status = 'locked' then
    update reservations set access_status = 'eligibility_review', updated_at = now() where id = rid;
    insert into access_release_requests(reservation_id, status) values (rid, 'eligibility_review');
    insert into notifications(branch_id, audience, title, body, link)
    values (r.branch_id, 'supervisor', 'طلب اعتماد دخول', 'وصل نزيل الحجز ' || r.internal_ref, '/staff/reservations/' || r.id);
    perform fn_audit(r.organization_id, r.branch_id, null, 'guest_checkin_request', 'reservation', rid, '{}'::jsonb);
  end if;
  return jsonb_build_object('ok', true, 'access_status', (select access_status from reservations where id = rid));
end $$;
grant execute on function fn_guest_submit_checkin(text) to anon, authenticated;

-- The ONLY path a guest can see a keybox code. Code never leaves the server otherwise.
create or replace function fn_guest_access_code(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  rid uuid := fn_token_reservation(p_token);
  r reservations%rowtype; kb keyboxes%rowtype; ev record; v_code text;
begin
  select * into r from reservations where id = rid;
  select * into ev from fn_evaluate_access(rid, false);
  if r.access_status not in ('delivered','acknowledged') or not ev.allowed then
    return jsonb_build_object('allowed', false, 'reasons', coalesce(ev.reasons, array['لم يتم تسليم الرمز بعد']));
  end if;
  select * into kb from keyboxes where room_id = r.room_id limit 1;
  if kb.last_reservation_id is distinct from r.id then
    return jsonb_build_object('allowed', false, 'reasons', array['الرمز غير مخصص لهذا الحجز']);
  end if;
  v_code := pgp_sym_decrypt(kb.code_encrypted, fn_secret('keybox_key'));
  update reservations set access_status = 'acknowledged', updated_at = now() where id = rid and access_status = 'delivered';
  update access_delivery_events set acknowledged = true where reservation_id = rid and acknowledged = false;
  perform fn_audit(r.organization_id, r.branch_id, null, 'guest_viewed_code', 'reservation', rid, jsonb_build_object('room_id', r.room_id, 'code_version', kb.code_version));
  return jsonb_build_object('allowed', true, 'code', v_code, 'room_number', (select room_number from rooms where id = r.room_id));
end $$;
grant execute on function fn_guest_access_code(text) to anon, authenticated;

-- =====================================================================
-- 8. STAFF RPCs
-- =====================================================================
create or replace function fn_staff_approve_identity(p_guest_id uuid, p_approve boolean, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g reservation_guests%rowtype; r reservations%rowtype; all_ok boolean;
begin
  perform fn_require_role('owner','manager','supervisor');
  select * into g from reservation_guests where id = p_guest_id for update;
  if not found then raise exception 'GUEST_NOT_FOUND'; end if;
  select * into r from reservations where id = g.reservation_id for update;
  perform fn_require_branch(r.branch_id);
  if not g.data_submitted then raise exception 'GUEST_DATA_NOT_SUBMITTED'; end if;
  if not p_approve and coalesce(trim(p_reason),'') = '' then raise exception 'REASON_REQUIRED'; end if;

  update reservation_guests set verification_status = case when p_approve then 'verified' else 'rejected' end::guest_verification_status where id = g.id;

  if p_approve then
    select bool_and(verification_status = 'verified') and count(*) >= (r.adults + r.companions) into all_ok from reservation_guests where reservation_id = r.id;
    update reservations set identity_status = case when all_ok then 'verified' else 'pending_supervisor' end::guest_verification_status, updated_at = now() where id = r.id;
  else
    update reservations set identity_status = 'rejected', updated_at = now() where id = r.id;
  end if;
  perform fn_audit(r.organization_id, r.branch_id, fn_staff_id(), case when p_approve then 'approve_identity' else 'reject_identity' end,
                   'reservation_guest', g.id, jsonb_build_object('reservation_id', r.id, 'reason', p_reason));
  return jsonb_build_object('ok', true, 'identity_status', (select identity_status from reservations where id = r.id));
end $$;
grant execute on function fn_staff_approve_identity(uuid, boolean, text) to authenticated;

-- Idempotent manual payment confirmation (POS / platform verified by staff)
create or replace function fn_staff_confirm_payment(p_reservation uuid, p_method payment_method, p_amount_halalas bigint,
  p_reference text, p_idempotency_key text, p_provider text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; existing payment_transactions%rowtype; paid bigint; new_status payment_status;
begin
  perform fn_require_role('owner','manager','supervisor','finance');
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if p_amount_halalas <= 0 then raise exception 'VALIDATION: amount'; end if;
  if coalesce(trim(p_reference),'') = '' then raise exception 'VALIDATION: reference_required'; end if;
  if coalesce(trim(p_idempotency_key),'') = '' then raise exception 'VALIDATION: idempotency_key'; end if;

  select * into existing from payment_transactions where idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object('ok', true, 'duplicate', true, 'transaction_id', existing.id);
  end if;

  insert into payment_transactions(reservation_id, method, amount_halalas, status, provider, provider_ref, pos_ref, verified_by, verified_at, idempotency_key)
  values (r.id, p_method, p_amount_halalas, 'paid', p_provider, case when p_method <> 'pos' then p_reference end,
          case when p_method = 'pos' then p_reference end, fn_staff_id(), now(), p_idempotency_key);

  select coalesce(sum(amount_halalas),0) into paid from payment_transactions where reservation_id = r.id and status = 'paid';
  new_status := case when paid >= r.total_halalas then 'paid' when paid > 0 then 'partially_paid' else 'pending' end;
  update reservations set paid_halalas = paid, payment_status = new_status, updated_at = now() where id = r.id;
  perform fn_audit(r.organization_id, r.branch_id, fn_staff_id(), 'confirm_payment', 'reservation', r.id,
                   jsonb_build_object('method', p_method, 'amount_halalas', p_amount_halalas, 'reference', p_reference));
  return jsonb_build_object('ok', true, 'duplicate', false, 'payment_status', new_status, 'paid_halalas', paid);
end $$;
grant execute on function fn_staff_confirm_payment(uuid, payment_method, bigint, text, text, text) to authenticated;

create or replace function fn_staff_confirm_gov_registration(p_reservation uuid, p_reference text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype;
begin
  perform fn_require_role('owner','manager','supervisor');
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.identity_status <> 'verified' then raise exception 'IDENTITY_NOT_VERIFIED'; end if;
  if coalesce(trim(p_reference),'') = '' then raise exception 'VALIDATION: reference_required'; end if;
  update reservations set government_registration = true, gov_registration_ref = p_reference, gov_registration_by = fn_staff_id(), gov_registration_at = now(), updated_at = now() where id = r.id;
  perform fn_audit(r.organization_id, r.branch_id, fn_staff_id(), 'confirm_gov_registration', 'reservation', r.id, jsonb_build_object('reference', p_reference));
  return jsonb_build_object('ok', true);
end $$;
grant execute on function fn_staff_confirm_gov_registration(uuid, text) to authenticated;

create or replace function fn_staff_assign_room(p_reservation uuid, p_room uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; rm rooms%rowtype;
begin
  perform fn_require_role('owner','manager','supervisor');
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  select * into rm from rooms where id = p_room for update;
  if not found or rm.branch_id <> r.branch_id then raise exception 'ROOM_NOT_FOUND'; end if;
  if rm.category_id <> r.room_category_id then raise exception 'ROOM_CATEGORY_MISMATCH'; end if;
  if rm.status not in ('available','ready') then raise exception 'ROOM_NOT_AVAILABLE'; end if;
  if r.status not in ('confirmed','pending_verification') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  -- exclusion constraint will raise if overlapping
  update reservations set room_id = p_room, updated_at = now() where id = r.id;
  update rooms set status = 'reserved' where id = p_room;
  perform fn_audit(r.organization_id, r.branch_id, fn_staff_id(), 'assign_room', 'reservation', r.id, jsonb_build_object('room_id', p_room));
  return jsonb_build_object('ok', true);
end $$;
grant execute on function fn_staff_assign_room(uuid, uuid) to authenticated;

create or replace function fn_staff_approve_checkin(p_reservation uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; ev record;
begin
  perform fn_require_role('owner','manager','supervisor');
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  select * into ev from fn_evaluate_access(r.id, true);
  if not ev.allowed then
    return jsonb_build_object('ok', false, 'reasons', ev.reasons);
  end if;
  update reservations set access_status = 'approved', checkin_approved_by = fn_staff_id(), checkin_approved_at = now(), updated_at = now() where id = r.id;
  update access_release_requests set status = 'approved', approved_by = fn_staff_id(), approved_at = now(), evaluated_at = now()
    where reservation_id = r.id and status in ('locked','eligibility_review');
  if not found then
    insert into access_release_requests(reservation_id, status, approved_by, approved_at, evaluated_at) values (r.id, 'approved', fn_staff_id(), now(), now());
  end if;
  perform fn_audit(r.organization_id, r.branch_id, fn_staff_id(), 'approve_checkin', 'reservation', r.id, '{}'::jsonb);
  return jsonb_build_object('ok', true);
end $$;
grant execute on function fn_staff_approve_checkin(uuid) to authenticated;

-- Deliver: marks delivered, occupies room, binds keybox to reservation, releases next slot.
-- Returns the code ONLY for channel = 'supervisor' (hand delivery by an authorised supervisor).
create or replace function fn_staff_deliver_access_code(p_reservation uuid, p_channel text default 'screen') returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; kb keyboxes%rowtype; ev record; v_code text; released int;
begin
  perform fn_require_role('owner','manager','supervisor');
  if p_channel not in ('screen','whatsapp','supervisor') then raise exception 'VALIDATION: channel'; end if;
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.access_status in ('delivered','acknowledged') then
    return jsonb_build_object('ok', false, 'reasons', array['تم تسليم الرمز مسبقًا لهذا الحجز']);
  end if;
  select * into ev from fn_evaluate_access(r.id, false);
  if not ev.allowed then return jsonb_build_object('ok', false, 'reasons', ev.reasons); end if;

  select * into kb from keyboxes where room_id = r.room_id limit 1 for update;

  update reservations set access_status = 'delivered', keybox_delivered = true, status = 'checked_in',
         actual_check_in = coalesce(actual_check_in, now()), updated_at = now() where id = r.id;
  update rooms set status = 'occupied' where id = r.room_id;
  update keyboxes set last_reservation_id = r.id, last_delivered_at = now() where id = kb.id;
  update access_release_requests set status = 'delivered', delivered_at = now() where reservation_id = r.id and status = 'approved';
  insert into access_delivery_events(reservation_id, keybox_id, channel, delivered_by) values (r.id, kb.id, p_channel, fn_staff_id());

  released := fn_release_next_slot(r.branch_id, r.room_category_id, r.check_in);

  perform fn_audit(r.organization_id, r.branch_id, fn_staff_id(), 'deliver_access_code', 'reservation', r.id,
                   jsonb_build_object('channel', p_channel, 'code_version', kb.code_version, 'released_count', released));

  if p_channel = 'supervisor' then
    v_code := pgp_sym_decrypt(kb.code_encrypted, fn_secret('keybox_key'));
    return jsonb_build_object('ok', true, 'code', v_code, 'released_count', released);
  end if;
  return jsonb_build_object('ok', true, 'released_count', released);
end $$;
grant execute on function fn_staff_deliver_access_code(uuid, text) to authenticated;

-- Reset a bad delivery (e.g. WhatsApp failure) so it can be re-delivered via another channel
create or replace function fn_staff_mark_delivery_failed(p_reservation uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype;
begin
  perform fn_require_role('owner','manager','supervisor');
  select * into r from reservations where id = p_reservation for update;
  perform fn_require_branch(r.branch_id);
  if r.access_status <> 'delivered' then raise exception 'NOT_IN_DELIVERED_STATE'; end if;
  update reservations set access_status = 'delivery_pending', updated_at = now() where id = r.id;
  perform fn_audit(r.organization_id, r.branch_id, fn_staff_id(), 'delivery_failed', 'reservation', r.id, jsonb_build_object('reason', p_reason));
  return jsonb_build_object('ok', true);
end $$;
grant execute on function fn_staff_mark_delivery_failed(uuid, text) to authenticated;

create or replace function fn_staff_checkout(p_reservation uuid, p_override_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; remaining bigint;
begin
  perform fn_require_role('owner','manager','supervisor');
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.status <> 'checked_in' then raise exception 'NOT_CHECKED_IN'; end if;
  remaining := r.total_halalas - r.paid_halalas;
  if remaining > 0 then
    if coalesce(trim(p_override_reason),'') = '' or not fn_has_role('owner','manager') then
      return jsonb_build_object('ok', false, 'reasons', array['يوجد مبلغ متبقٍ ' || (remaining/100.0)::text || ' ر.س — يلزم السداد أو تجاوز بصلاحية مدير مع سبب']);
    end if;
  end if;
  update reservations set status = 'checked_out', actual_check_out = now(), updated_at = now() where id = r.id;
  if r.room_id is not null then
    update rooms set status = 'cleaning' where id = r.room_id;
    insert into cleaning_tasks(room_id, branch_id, reservation_id, status) values (r.room_id, r.branch_id, r.id, 'pending');
    update keyboxes set code_status = 'needs_change', field_tested = false where room_id = r.room_id;
    insert into notifications(branch_id, audience, title, body, link)
    values (r.branch_id, 'supervisor', 'مغادرة — تنظيف وتغيير رمز مطلوب', 'غرفة ' || (select room_number from rooms where id = r.room_id), '/staff/housekeeping');
  end if;
  perform fn_audit(r.organization_id, r.branch_id, fn_staff_id(), 'checkout', 'reservation', r.id,
                   jsonb_build_object('remaining_halalas', remaining, 'override_reason', p_override_reason));
  return jsonb_build_object('ok', true);
end $$;
grant execute on function fn_staff_checkout(uuid, text) to authenticated;

-- Room readiness is recomputed, never set directly from the client
create or replace function fn_recompute_room_ready(p_room uuid) returns room_status
language plpgsql security definer set search_path = public as $$
declare rm rooms%rowtype; kb keyboxes%rowtype; pending_clean int; open_maint int;
begin
  select * into rm from rooms where id = p_room for update;
  if rm.status in ('occupied','reserved','blocked','out_of_service') then return rm.status; end if;
  select count(*) into pending_clean from cleaning_tasks where room_id = p_room and status <> 'done';
  select count(*) into open_maint from maintenance_tickets where room_id = p_room and status <> 'resolved';
  select * into kb from keyboxes where room_id = p_room limit 1;
  if open_maint > 0 then update rooms set status = 'maintenance' where id = p_room; return 'maintenance'; end if;
  if pending_clean > 0 then update rooms set status = 'cleaning' where id = p_room; return 'cleaning'; end if;
  if kb.id is null or kb.code_status <> 'active' or not kb.field_tested then
    update rooms set status = 'cleaning' where id = p_room; return 'cleaning';
  end if;
  update rooms set status = 'ready' where id = p_room;
  return 'ready';
end $$;
revoke all on function fn_recompute_room_ready(uuid) from public, anon, authenticated;

create or replace function fn_staff_complete_cleaning(p_task uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t cleaning_tasks%rowtype; st room_status;
begin
  perform fn_require_role('owner','manager','supervisor','housekeeping');
  select * into t from cleaning_tasks where id = p_task for update;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;
  perform fn_require_branch(t.branch_id);
  update cleaning_tasks set status = 'done', completed_at = now(), assigned_to = coalesce(assigned_to, fn_staff_id()) where id = t.id;
  st := fn_recompute_room_ready(t.room_id);
  perform fn_audit(fn_user_org_id(), t.branch_id, fn_staff_id(), 'cleaning_completed', 'room', t.room_id, jsonb_build_object('task_id', t.id, 'room_status', st));
  return jsonb_build_object('ok', true, 'room_status', st);
end $$;
grant execute on function fn_staff_complete_cleaning(uuid) to authenticated;

-- Rotate keybox code: supervisor/manager/owner only (housekeeping & finance excluded by spec)
create or replace function fn_staff_rotate_keybox_code(p_room uuid, p_new_code text, p_field_tested boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare kb keyboxes%rowtype; rm rooms%rowtype; st room_status; old_code text;
begin
  perform fn_require_role('owner','manager','supervisor');
  select * into rm from rooms where id = p_room;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  perform fn_require_branch(rm.branch_id);
  if p_new_code !~ '^\d{4,8}$' then raise exception 'VALIDATION: code_must_be_4_to_8_digits'; end if;
  select * into kb from keyboxes where room_id = p_room limit 1 for update;
  if not found then
    insert into keyboxes(room_id, branch_id, code_encrypted, code_version, code_status, last_changed_at, last_changed_by, field_tested, requires_rotation)
    values (p_room, rm.branch_id, pgp_sym_encrypt(p_new_code, fn_secret('keybox_key')), 1, 'active', now(), fn_staff_id(), p_field_tested, true)
    returning * into kb;
    insert into code_rotation_events(keybox_id, room_id, from_version, to_version, rotated_by, field_tested) values (kb.id, p_room, null, 1, fn_staff_id(), p_field_tested);
  else
    if kb.code_encrypted is not null then
      old_code := pgp_sym_decrypt(kb.code_encrypted, fn_secret('keybox_key'));
      if old_code = p_new_code then raise exception 'CODE_MUST_DIFFER_FROM_PREVIOUS'; end if;
    end if;
    update keyboxes set code_encrypted = pgp_sym_encrypt(p_new_code, fn_secret('keybox_key')), code_version = kb.code_version + 1,
      code_status = 'active', last_changed_at = now(), last_changed_by = fn_staff_id(), field_tested = p_field_tested, last_reservation_id = null
    where id = kb.id;
    insert into code_rotation_events(keybox_id, room_id, from_version, to_version, rotated_by, field_tested) values (kb.id, p_room, kb.code_version, kb.code_version + 1, fn_staff_id(), p_field_tested);
  end if;
  st := fn_recompute_room_ready(p_room);
  perform fn_audit(fn_user_org_id(), rm.branch_id, fn_staff_id(), 'rotate_keybox_code', 'room', p_room, jsonb_build_object('field_tested', p_field_tested, 'room_status', st));
  return jsonb_build_object('ok', true, 'room_status', st, 'code_version', (select code_version from keyboxes where room_id = p_room));
end $$;
grant execute on function fn_staff_rotate_keybox_code(uuid, text, boolean) to authenticated;

create or replace function fn_staff_mark_keybox_tested(p_room uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare rm rooms%rowtype; st room_status;
begin
  perform fn_require_role('owner','manager','supervisor');
  select * into rm from rooms where id = p_room; perform fn_require_branch(rm.branch_id);
  update keyboxes set field_tested = true where room_id = p_room and code_status = 'active';
  st := fn_recompute_room_ready(p_room);
  perform fn_audit(fn_user_org_id(), rm.branch_id, fn_staff_id(), 'keybox_field_tested', 'room', p_room, jsonb_build_object('room_status', st));
  return jsonb_build_object('ok', true, 'room_status', st);
end $$;
grant execute on function fn_staff_mark_keybox_tested(uuid) to authenticated;

create or replace function fn_staff_create_maintenance(p_room uuid, p_title text, p_description text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare rm rooms%rowtype; tid uuid;
begin
  perform fn_require_role('owner','manager','supervisor','housekeeping');
  select * into rm from rooms where id = p_room for update; if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  perform fn_require_branch(rm.branch_id);
  if coalesce(trim(p_title),'') = '' then raise exception 'VALIDATION: title'; end if;
  insert into maintenance_tickets(room_id, branch_id, title, description, status, created_by) values (p_room, rm.branch_id, p_title, p_description, 'open', fn_staff_id()) returning id into tid;
  if rm.status not in ('occupied') then update rooms set status = 'maintenance' where id = p_room; end if;
  perform fn_audit(fn_user_org_id(), rm.branch_id, fn_staff_id(), 'maintenance_opened', 'room', p_room, jsonb_build_object('ticket_id', tid));
  return jsonb_build_object('ok', true, 'ticket_id', tid);
end $$;
grant execute on function fn_staff_create_maintenance(uuid, text, text) to authenticated;

create or replace function fn_staff_resolve_maintenance(p_ticket uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t maintenance_tickets%rowtype; st room_status;
begin
  perform fn_require_role('owner','manager','supervisor');
  select * into t from maintenance_tickets where id = p_ticket for update; if not found then raise exception 'TICKET_NOT_FOUND'; end if;
  perform fn_require_branch(t.branch_id);
  update maintenance_tickets set status = 'resolved' where id = t.id;
  st := fn_recompute_room_ready(t.room_id);
  perform fn_audit(fn_user_org_id(), t.branch_id, fn_staff_id(), 'maintenance_resolved', 'room', t.room_id, jsonb_build_object('ticket_id', t.id, 'room_status', st));
  return jsonb_build_object('ok', true, 'room_status', st);
end $$;
grant execute on function fn_staff_resolve_maintenance(uuid) to authenticated;

create or replace function fn_staff_resolve_ticket(p_ticket uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform fn_require_role('owner','manager','supervisor');
  update human_handoff_tickets set status = 'resolved', resolved_by = fn_staff_id(), resolved_at = now()
   where id = p_ticket and (branch_id is null or branch_id in (select fn_user_branch_ids()));
  return jsonb_build_object('ok', found);
end $$;
grant execute on function fn_staff_resolve_ticket(uuid) to authenticated;

-- Staff onboarding (fixes the "anyone becomes owner" hole):
--   * pending profile created by an owner with an email → claimed on first login
--   * demo bootstrap: only when demo_mode and the org has no active staff at all
create or replace function fn_claim_staff_profile(p_full_name text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_email text := lower(coalesce(auth.jwt()->>'email','')); sp staff_profiles%rowtype; demo boolean;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHENTICATED'; end if;
  select * into sp from staff_profiles where auth_user_id = auth.uid() limit 1;
  if found then return jsonb_build_object('ok', true, 'role', sp.role, 'claimed', false); end if;

  select * into sp from staff_profiles where lower(email) = v_email and auth_user_id is null and is_active limit 1;
  if found then
    update staff_profiles set auth_user_id = auth.uid(), full_name = coalesce(nullif(trim(p_full_name),''), full_name) where id = sp.id;
    return jsonb_build_object('ok', true, 'role', sp.role, 'claimed', true);
  end if;

  select demo_mode into demo from system_settings where organization_id = '00000000-0000-0000-0000-000000000001';
  if coalesce(demo,false) and not exists (select 1 from staff_profiles where organization_id = '00000000-0000-0000-0000-000000000001' and auth_user_id is not null and is_active) then
    insert into staff_profiles(auth_user_id, organization_id, full_name, email, role, is_active)
    values (auth.uid(), '00000000-0000-0000-0000-000000000001', coalesce(nullif(trim(p_full_name),''), v_email), v_email, 'owner', true) returning * into sp;
    insert into branch_memberships(staff_id, branch_id) select sp.id, id from branches where organization_id = sp.organization_id;
    perform fn_audit(sp.organization_id, null, sp.id, 'demo_owner_bootstrap', 'staff_profile', sp.id, '{}'::jsonb);
    return jsonb_build_object('ok', true, 'role', 'owner', 'claimed', true, 'bootstrap', true);
  end if;
  return jsonb_build_object('ok', false, 'error', 'NO_INVITATION');
end $$;
grant execute on function fn_claim_staff_profile(text) to authenticated;

create or replace function fn_staff_invite(p_email text, p_full_name text, p_role role_code, p_branch_ids uuid[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare sp staff_profiles%rowtype; b uuid;
begin
  perform fn_require_role('owner');
  if p_role = 'guest' then raise exception 'INVALID_ROLE'; end if;
  insert into staff_profiles(organization_id, full_name, email, role, is_active) values (fn_user_org_id(), p_full_name, lower(trim(p_email)), p_role, true) returning * into sp;
  foreach b in array coalesce(p_branch_ids, '{}') loop
    perform fn_require_branch(b);
    insert into branch_memberships(staff_id, branch_id) values (sp.id, b) on conflict do nothing;
  end loop;
  perform fn_audit(sp.organization_id, null, fn_staff_id(), 'staff_invited', 'staff_profile', sp.id, jsonb_build_object('role', p_role));
  return jsonb_build_object('ok', true, 'staff_id', sp.id);
end $$;
grant execute on function fn_staff_invite(text, text, role_code, uuid[]) to authenticated;

-- AI settings (owner only writes; key is NEVER stored here — it lives in the Edge Function secret GEMINI_API_KEY)
create or replace function fn_admin_update_ai_settings(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform fn_require_role('owner');
  insert into ai_settings(organization_id) values (fn_user_org_id()) on conflict do nothing;
  update ai_settings set
    enabled = coalesce((p->>'enabled')::boolean, enabled),
    provider = coalesce(p->>'provider', provider),
    model = coalesce(nullif(trim(p->>'model'),''), model),
    temperature = coalesce((p->>'temperature')::numeric, temperature),
    max_output_tokens = coalesce((p->>'max_output_tokens')::int, max_output_tokens),
    timeout_ms = coalesce((p->>'timeout_ms')::int, timeout_ms),
    daily_request_limit = coalesce((p->>'daily_request_limit')::int, daily_request_limit),
    daily_token_budget = coalesce((p->>'daily_token_budget')::int, daily_token_budget),
    per_session_message_limit = coalesce((p->>'per_session_message_limit')::int, per_session_message_limit),
    strict_scope = coalesce((p->>'strict_scope')::boolean, strict_scope),
    extra_instructions = coalesce(p->>'extra_instructions', extra_instructions),
    updated_by = fn_staff_id(), updated_at = now()
  where organization_id = fn_user_org_id();
  perform fn_audit(fn_user_org_id(), null, fn_staff_id(), 'ai_settings_updated', 'ai_settings', fn_user_org_id(), p - 'extra_instructions');
  return jsonb_build_object('ok', true);
end $$;
grant execute on function fn_admin_update_ai_settings(jsonb) to authenticated;

-- =====================================================================
-- 9. RLS TIGHTENING
-- =====================================================================
-- Column-level: ciphertext never readable by API roles (only SECURITY DEFINER fns).
-- Table-level SELECT is revoked and re-granted per column (a column REVOKE alone
-- does not override a table-level GRANT in PostgreSQL).
revoke select on keyboxes from anon, authenticated;
grant select (id, room_id, branch_id, code_version, code_status, last_changed_at, last_changed_by, field_tested,
              last_reservation_id, requires_rotation, created_at, last_delivered_at) on keyboxes to authenticated;
revoke all on reservation_guests from anon, authenticated;
grant select (id, reservation_id, guest_profile_id, is_primary, full_name, identity_type, identity_number_last4,
              identity_issue_number, nationality, birth_date, phone, phone_verified, relationship, verification_status,
              data_submitted, created_at) on reservation_guests to authenticated;
-- Internal-only tables
revoke all on guest_lookup_attempts from anon, authenticated;
revoke all on registration_sessions from anon;
revoke insert, update, delete on registration_sessions from authenticated;

-- reservations: all staff in their branches may read; direct writes only owner/manager (ops go through RPCs)
drop policy if exists "staff_res_all" on reservations;
create policy "staff_res_select" on reservations for select to authenticated
  using (branch_id in (select fn_user_branch_ids()));
create policy "mgr_res_write" on reservations for insert to authenticated
  with check (branch_id in (select fn_user_branch_ids()) and fn_has_role('owner','manager'));
create policy "mgr_res_update" on reservations for update to authenticated
  using (branch_id in (select fn_user_branch_ids()) and fn_has_role('owner','manager'))
  with check (branch_id in (select fn_user_branch_ids()) and fn_has_role('owner','manager'));

-- reservation_guests: housekeeping must not see identity data; writes only via RPC
drop policy if exists "staff_resguests_all" on reservation_guests;
create policy "staff_resguests_select" on reservation_guests for select to authenticated
  using (fn_has_role('owner','manager','supervisor','finance') and exists (
    select 1 from reservations r where r.id = reservation_guests.reservation_id and r.branch_id in (select fn_user_branch_ids())));

drop policy if exists "staff_guests_all" on guest_profiles;
create policy "staff_guests_select" on guest_profiles for select to authenticated using (fn_has_role('owner','manager','supervisor'));
create policy "mgr_guests_write" on guest_profiles for all to authenticated using (fn_has_role('owner','manager')) with check (fn_has_role('owner','manager'));

-- payments: finance/mgmt/supervisor read; writes via RPC only
drop policy if exists "staff_payments_all" on payment_transactions;
create policy "staff_payments_select" on payment_transactions for select to authenticated
  using (fn_has_role('owner','manager','supervisor','finance') and exists (
    select 1 from reservations r where r.id = payment_transactions.reservation_id and r.branch_id in (select fn_user_branch_ids())));

-- keyboxes: finance/housekeeping excluded; writes via RPC only
drop policy if exists "staff_keyboxes_all" on keyboxes;
create policy "staff_keyboxes_select" on keyboxes for select to authenticated
  using (fn_has_role('owner','manager','supervisor') and branch_id in (select fn_user_branch_ids()));

-- access tables: read-only for staff
drop policy if exists "staff_access_all" on access_release_requests;
create policy "staff_access_select" on access_release_requests for select to authenticated
  using (exists (select 1 from reservations r where r.id = access_release_requests.reservation_id and r.branch_id in (select fn_user_branch_ids())));
drop policy if exists "staff_delivery_all" on access_delivery_events;
create policy "staff_delivery_select" on access_delivery_events for select to authenticated
  using (exists (select 1 from reservations r where r.id = access_delivery_events.reservation_id and r.branch_id in (select fn_user_branch_ids())));

-- rooms / categories / inventory / rules: read all staff in branch, write owner/manager
drop policy if exists "staff_rooms_all" on rooms;
create policy "staff_rooms_select" on rooms for select to authenticated using (branch_id in (select fn_user_branch_ids()));
create policy "mgr_rooms_write" on rooms for all to authenticated
  using (branch_id in (select fn_user_branch_ids()) and fn_has_role('owner','manager'))
  with check (branch_id in (select fn_user_branch_ids()) and fn_has_role('owner','manager'));
drop policy if exists "anon_read_rooms" on rooms;

drop policy if exists "staff_cat_all" on room_categories;
create policy "staff_cat_select" on room_categories for select to authenticated using (branch_id in (select fn_user_branch_ids()));
create policy "mgr_cat_write" on room_categories for all to authenticated
  using (branch_id in (select fn_user_branch_ids()) and fn_has_role('owner','manager'))
  with check (branch_id in (select fn_user_branch_ids()) and fn_has_role('owner','manager'));

drop policy if exists "staff_inv_all" on inventory_periods;
create policy "staff_inv_select" on inventory_periods for select to authenticated using (branch_id in (select fn_user_branch_ids()));
create policy "mgr_inv_write" on inventory_periods for all to authenticated
  using (branch_id in (select fn_user_branch_ids()) and fn_has_role('owner','manager'))
  with check (branch_id in (select fn_user_branch_ids()) and fn_has_role('owner','manager'));

drop policy if exists "staff_rules_all" on release_rules;
create policy "staff_rules_select" on release_rules for select to authenticated using (branch_id in (select fn_user_branch_ids()));
create policy "mgr_rules_write" on release_rules for all to authenticated
  using (branch_id in (select fn_user_branch_ids()) and fn_has_role('owner','manager'))
  with check (branch_id in (select fn_user_branch_ids()) and fn_has_role('owner','manager'));

drop policy if exists "staff_slots_all" on released_slots;
create policy "staff_slots_select" on released_slots for select to authenticated using (branch_id in (select fn_user_branch_ids()));

-- branches: read own; write owner only
drop policy if exists "staff_write_branches" on branches;
create policy "owner_write_branches" on branches for all to authenticated
  using (organization_id = fn_user_org_id() and fn_has_role('owner')) with check (organization_id = fn_user_org_id() and fn_has_role('owner'));

-- staff profiles: self-insert path removed (use fn_claim_staff_profile / fn_staff_invite)
drop policy if exists "staff_insert_profiles" on staff_profiles;
drop policy if exists "staff_update_profiles" on staff_profiles;
create policy "owner_update_profiles" on staff_profiles for update to authenticated
  using (organization_id = fn_user_org_id() and fn_has_role('owner')) with check (organization_id = fn_user_org_id() and fn_has_role('owner'));
drop policy if exists "staff_memberships" on branch_memberships;
create policy "staff_memberships_select" on branch_memberships for select to authenticated
  using (exists (select 1 from staff_profiles sp where sp.id = branch_memberships.staff_id and sp.organization_id = fn_user_org_id()));
create policy "owner_memberships_write" on branch_memberships for all to authenticated
  using (fn_has_role('owner')) with check (fn_has_role('owner'));

-- cleaning / maintenance: read in branch; writes via RPC
drop policy if exists "staff_cleaning_all" on cleaning_tasks;
create policy "staff_cleaning_select" on cleaning_tasks for select to authenticated using (branch_id in (select fn_user_branch_ids()));
drop policy if exists "staff_maint_all" on maintenance_tickets;
create policy "staff_maint_select" on maintenance_tickets for select to authenticated using (branch_id in (select fn_user_branch_ids()));

-- audit: read owner/manager; NO direct insert (fn_audit only)
drop policy if exists "staff_audit_insert" on audit_events;
drop policy if exists "staff_audit_read" on audit_events;
create policy "mgmt_audit_read" on audit_events for select to authenticated
  using (fn_has_role('owner','manager','supervisor') and (organization_id = fn_user_org_id()));

-- notifications: read in branch, mark read
drop policy if exists "staff_notif_all" on notifications;
create policy "staff_notif_select" on notifications for select to authenticated using (branch_id in (select fn_user_branch_ids()) or branch_id is null);
create policy "staff_notif_update" on notifications for update to authenticated using (branch_id in (select fn_user_branch_ids())) with check (branch_id in (select fn_user_branch_ids()));

-- conversations: NO anon access (edge function uses service role). Staff read in branch.
drop policy if exists "anon_conv_all" on conversations;
drop policy if exists "anon_msg_all" on conversation_messages;
create policy "staff_conv_select" on conversations for select to authenticated
  using (fn_has_role('owner','manager','supervisor') and (branch_id is null or branch_id in (select fn_user_branch_ids())));
create policy "staff_conv_update" on conversations for update to authenticated
  using (fn_has_role('owner','manager','supervisor') and (branch_id is null or branch_id in (select fn_user_branch_ids())))
  with check (true);
create policy "staff_msg_select" on conversation_messages for select to authenticated
  using (fn_has_role('owner','manager','supervisor') and exists (
    select 1 from conversations c where c.id = conversation_messages.conversation_id and (c.branch_id is null or c.branch_id in (select fn_user_branch_ids()))));
create policy "staff_msg_insert" on conversation_messages for insert to authenticated
  with check (fn_has_role('owner','manager','supervisor') and sender = 'supervisor' and exists (
    select 1 from conversations c where c.id = conversation_messages.conversation_id and (c.branch_id is null or c.branch_id in (select fn_user_branch_ids()))));

-- registration sessions: NO anon table access (token RPCs only)
drop policy if exists "anon_regsession_read" on registration_sessions;
drop policy if exists "anon_regsession_insert" on registration_sessions;
drop policy if exists "anon_regsession_update" on registration_sessions;
create policy "staff_regsession_select" on registration_sessions for select to authenticated
  using (fn_has_role('owner','manager','supervisor'));

-- new tables
alter table human_handoff_tickets enable row level security;
create policy "staff_handoff_select" on human_handoff_tickets for select to authenticated
  using (fn_has_role('owner','manager','supervisor') and (branch_id is null or branch_id in (select fn_user_branch_ids())));
alter table guest_lookup_attempts enable row level security;
alter table code_rotation_events enable row level security;
create policy "staff_rotation_select" on code_rotation_events for select to authenticated
  using (fn_has_role('owner','manager','supervisor') and exists (select 1 from rooms r where r.id = code_rotation_events.room_id and r.branch_id in (select fn_user_branch_ids())));
alter table ai_settings enable row level security;
create policy "staff_ai_settings_select" on ai_settings for select to authenticated using (organization_id = fn_user_org_id() and fn_has_role('owner','manager'));
alter table ai_usage_daily enable row level security;
create policy "staff_ai_usage_select" on ai_usage_daily for select to authenticated using (organization_id = fn_user_org_id() and fn_has_role('owner','manager'));
alter table ai_tool_executions enable row level security;
create policy "staff_ai_tools_select" on ai_tool_executions for select to authenticated using (fn_has_role('owner','manager'));
alter table ai_guardrail_events enable row level security;
create policy "staff_ai_guard_select" on ai_guardrail_events for select to authenticated using (fn_has_role('owner','manager'));
alter table system_settings enable row level security;
create policy "staff_sys_select" on system_settings for select to authenticated using (organization_id = fn_user_org_id());

-- public read for the guest "new booking" screen (no reservation data)
drop policy if exists "anon_read_branches_public" on branches;
create policy "anon_read_branches_public" on branches for select to anon using (is_active);

-- =====================================================================
-- 10. REVOKE PRIVILEGED FUNCTIONS FROM API ROLES
-- =====================================================================
revoke all on function fn_audit(uuid, uuid, uuid, text, text, uuid, jsonb) from public, anon, authenticated;
drop function if exists fn_verify_booking_ownership(uuid, text);

-- Seed hygiene: the 0004 seed used literal keys; re-encrypt demo data with the configured secrets
-- (runs only when secrets are configured; otherwise leaves rows for the ops team to rotate).
do $$
declare kk text; ik text;
begin
  begin kk := fn_secret('keybox_key'); ik := fn_secret('identity_key'); exception when others then return; end;
  update keyboxes set code_encrypted = pgp_sym_encrypt(pgp_sym_decrypt(code_encrypted, 'demo-keybox-key-v1'), kk)
   where code_encrypted is not null and pgp_sym_decrypt(code_encrypted, 'demo-keybox-key-v1') is not null;
  update reservation_guests set identity_number_encrypted = pgp_sym_encrypt(pgp_sym_decrypt(identity_number_encrypted, 'demo-id-key-v1'), ik)
   where identity_number_encrypted is not null;
exception when others then
  -- already re-encrypted or different key: ignore
  null;
end $$;

-- Demo scenario 1 keybox must be bound to nothing yet; scenario 4 (checked-in, room 104) bound to its reservation
update keyboxes kb set last_reservation_id = '00000000-0000-0000-0000-000000000203'
  from rooms r where r.id = kb.room_id and r.room_number = '104';
