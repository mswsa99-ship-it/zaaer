-- =====================================================================
-- 0020 — the guest's phone number is the key to their bookings.
--
-- Flow (guest screens /booking/lookup):
--   1. the guest types their phone
--   2. a 6-digit code is sent by WhatsApp (edge function guest-otp → fn_guest_phone_start, service role only:
--      the code never reaches a browser) and typed back (fn_guest_phone_verify)
--      — until WhatsApp is connected: one booking number of that phone proves ownership instead
--        (fn_guest_phone_verify_ref)
--   3. a short phone session lists every booking on that phone (fn_guest_phone_reservations)
--   4. opening one issues the usual per-booking guest token (fn_guest_phone_open → /booking/status/:token)
-- Nothing tells an unverified caller whether a phone has bookings. Codes are stored hashed, expire in
-- 10 minutes, allow 5 tries; starts are throttled per phone and per device.
-- =====================================================================

-- Saudi mobile in any common spelling → 9665XXXXXXXX; other international numbers → their digits (8–15)
create or replace function fn_normalize_phone(p text) returns text
language plpgsql immutable set search_path = public, extensions as $$
declare d text;
begin
  if p is null then return null; end if;
  d := translate(p, '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹', '01234567890123456789');
  d := regexp_replace(d, '\D', '', 'g');
  if d ~ '^00' then d := substr(d, 3); end if;
  if d ~ '^05\d{8}$' then return '966' || substr(d, 2); end if;
  if d ~ '^5\d{8}$' then return '966' || d; end if;
  if d ~ '^9665\d{8}$' then return d; end if;
  if d ~ '^966' then return null; end if;                 -- a Saudi number that is not a mobile
  if length(d) between 8 and 15 then return d; end if;
  return null;
end $$;

create table if not exists guest_phone_challenges (
  id uuid primary key default gen_random_uuid(),
  phone text not null,
  code_hash text not null,
  attempts int not null default 0,
  client_fingerprint text,
  expires_at timestamptz not null default (now() + interval '10 minutes'),
  verified_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists idx_phone_challenges on guest_phone_challenges(phone, created_at);
create index if not exists idx_phone_challenges_fp on guest_phone_challenges(client_fingerprint, created_at);

create table if not exists guest_phone_sessions (
  token text primary key default (upper(encode(gen_random_bytes(16), 'hex'))),
  phone text not null,
  method text not null check (method in ('whatsapp_code', 'booking_number')),
  expires_at timestamptz not null default (now() + interval '2 hours'),
  created_at timestamptz not null default now()
);

alter table guest_phone_challenges enable row level security;
alter table guest_phone_sessions enable row level security;
revoke all on guest_phone_challenges, guest_phone_sessions from anon, authenticated;

-- reservations whose primary guest (or its profile) has this phone; cancelled/rejected and long-past stays left out
create or replace function fn_phone_reservation_ids(p_phone text) returns setof uuid
language sql stable security definer set search_path = public, extensions as $$
  select distinct r.id
  from reservations r
  join reservation_guests g on g.reservation_id = r.id and g.is_primary
  left join guest_profiles gp on gp.id = g.guest_profile_id
  where p_phone is not null
    and (fn_normalize_phone(g.phone) = p_phone or fn_normalize_phone(gp.phone) = p_phone)
    and r.status not in ('rejected')
    and r.check_out >= fn_branch_today(r.branch_id) - 60
$$;
revoke all on function fn_phone_reservation_ids(text) from public, anon, authenticated;

-- 1. start (service role only — called by the guest-otp edge function, which sends the code by WhatsApp)
create or replace function fn_guest_phone_start(p_phone text, p_fingerprint text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_phone text := fn_normalize_phone(p_phone); v_code text; v_id uuid;
begin
  if v_phone is null then return jsonb_build_object('status', 'invalid'); end if;
  if (select count(*) from guest_phone_challenges where phone = v_phone and created_at > now() - interval '1 hour') >= 5
     or (p_fingerprint is not null and (select count(*) from guest_phone_challenges where client_fingerprint = p_fingerprint and created_at > now() - interval '1 hour') >= 20) then
    return jsonb_build_object('status', 'throttled');
  end if;
  -- no bookings → nothing is sent (no messages to strangers); the caller answers the guest the same way either way
  if not exists (select 1 from fn_phone_reservation_ids(v_phone)) then
    return jsonb_build_object('status', 'no_reservations', 'phone', v_phone);
  end if;
  v_code := lpad((('x' || encode(gen_random_bytes(4), 'hex'))::bit(32)::bigint % 1000000)::text, 6, '0');   -- CSPRNG, not random()
  insert into guest_phone_challenges(phone, code_hash, client_fingerprint)
  values (v_phone, 'pending', p_fingerprint) returning id into v_id;
  update guest_phone_challenges set code_hash = encode(digest(v_id::text || ':' || v_code, 'sha256'), 'hex') where id = v_id;
  return jsonb_build_object('status', 'ok', 'phone', v_phone, 'code', v_code, 'challenge_id', v_id);
end $$;
revoke all on function fn_guest_phone_start(text, text) from public, anon, authenticated;
grant execute on function fn_guest_phone_start(text, text) to service_role;

create or replace function fn_phone_session(p_phone text, p_method text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare v_token text;
begin
  insert into guest_phone_sessions(phone, method) values (p_phone, p_method) returning token into v_token;
  return v_token;
end $$;
revoke all on function fn_phone_session(text, text) from public, anon, authenticated;

-- 2a. the code from WhatsApp
create or replace function fn_guest_phone_verify(p_phone text, p_code text, p_fingerprint text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_phone text := fn_normalize_phone(p_phone); c guest_phone_challenges%rowtype;
        v_code text := regexp_replace(translate(coalesce(p_code, ''), '٠١٢٣٤٥٦٧٨٩', '0123456789'), '\D', '', 'g');
begin
  if v_phone is null or v_code !~ '^\d{6}$' then return jsonb_build_object('status', 'invalid'); end if;
  select * into c from guest_phone_challenges
   where phone = v_phone and verified_at is null and expires_at > now()
   order by created_at desc limit 1 for update;
  if not found then return jsonb_build_object('status', 'expired'); end if;
  if c.attempts >= 5 then return jsonb_build_object('status', 'throttled'); end if;
  if c.code_hash <> encode(digest(c.id::text || ':' || v_code, 'sha256'), 'hex') then
    update guest_phone_challenges set attempts = attempts + 1 where id = c.id;
    return jsonb_build_object('status', 'mismatch', 'attempts_left', 4 - c.attempts);
  end if;
  update guest_phone_challenges set verified_at = now() where id = c.id;
  update reservation_guests g set phone_verified = true
   where g.is_primary and g.reservation_id in (select fn_phone_reservation_ids(v_phone)) and fn_normalize_phone(g.phone) = v_phone;
  return jsonb_build_object('status', 'ok', 'token', fn_phone_session(v_phone, 'whatsapp_code'));
end $$;
grant execute on function fn_guest_phone_verify(text, text, text) to anon, authenticated;

-- 2b. until WhatsApp is connected: the phone plus the number of any one of its bookings
create or replace function fn_guest_phone_verify_ref(p_phone text, p_ref text, p_fingerprint text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_phone text := fn_normalize_phone(p_phone); v_ref text := upper(trim(coalesce(p_ref, ''))); v_ok boolean;
begin
  if v_phone is null or v_ref = '' then return jsonb_build_object('status', 'invalid'); end if;
  if (select count(*) from guest_lookup_attempts where external_ref = 'PHONE:' || v_phone and not ok and created_at > now() - interval '15 minutes') >= 5 then
    return jsonb_build_object('status', 'throttled');
  end if;
  select exists (select 1 from reservations r where r.id in (select fn_phone_reservation_ids(v_phone))
                  and (upper(r.external_ref) = v_ref or upper(r.internal_ref) = v_ref)) into v_ok;
  insert into guest_lookup_attempts(external_ref, client_fingerprint, ok) values ('PHONE:' || v_phone, p_fingerprint, v_ok);
  if not v_ok then return jsonb_build_object('status', 'mismatch'); end if;
  return jsonb_build_object('status', 'ok', 'token', fn_phone_session(v_phone, 'booking_number'));
end $$;
grant execute on function fn_guest_phone_verify_ref(text, text, text) to anon, authenticated;

-- 3. the bookings on the verified phone (no money, no identity data — those stay behind the per-booking page)
create or replace function fn_guest_phone_reservations(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare s guest_phone_sessions%rowtype;
begin
  select * into s from guest_phone_sessions where token = p_token and expires_at > now();
  if not found then raise exception 'TOKEN_INVALID'; end if;
  return jsonb_build_object('phone_last4', right(s.phone, 4), 'reservations', coalesce((
    select jsonb_agg(jsonb_build_object(
      'ref', coalesce(r.external_ref, r.internal_ref), 'internal_ref', r.internal_ref, 'status', r.status,
      'check_in', r.check_in, 'check_out', r.check_out, 'nights', r.check_out - r.check_in,
      'branch_name', b.name_ar, 'category_name', c.name_ar, 'payment_status', r.payment_status,
      'access_status', r.access_status, 'identity_status', r.identity_status)
      order by (r.check_out < fn_branch_today(r.branch_id)), r.check_in)
    from reservations r
    join branches b on b.id = r.branch_id
    left join room_categories c on c.id = r.room_category_id
    where r.id in (select fn_phone_reservation_ids(s.phone))), '[]'::jsonb));
end $$;
grant execute on function fn_guest_phone_reservations(text) to anon, authenticated;

-- 4. open one booking → the usual guest token of /booking/status, /booking/registration
create or replace function fn_guest_phone_open(p_token text, p_internal_ref text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare s guest_phone_sessions%rowtype; r reservations%rowtype; v_token text;
begin
  select * into s from guest_phone_sessions where token = p_token and expires_at > now();
  if not found then raise exception 'TOKEN_INVALID'; end if;
  select * into r from reservations where internal_ref = p_internal_ref and id in (select fn_phone_reservation_ids(s.phone));
  if not found then raise exception 'NOT_FOUND'; end if;
  insert into registration_sessions(reservation_id, expires_at) values (r.id, now() + interval '24 hours') returning token into v_token;
  perform fn_audit(r.organization_id, r.branch_id, null, 'guest_verified_lookup', 'reservation', r.id, jsonb_build_object('channel', 'web', 'method', s.method));
  return jsonb_build_object('status', 'ok', 'token', v_token);
end $$;
grant execute on function fn_guest_phone_open(text, text) to anon, authenticated;
