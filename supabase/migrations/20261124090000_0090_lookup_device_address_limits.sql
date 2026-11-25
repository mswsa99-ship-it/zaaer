-- =====================================================================
-- 0084 — plan 5.8 (finding S9): the booking-number lookup gets its extra limits. Today only the guessed number
-- is throttled (5 failures / 15 minutes), so one caller rotates numbers freely. Now a device (its fingerprint)
-- stops after 20 failed lookups in an hour and an address after 40 (a shared network gets more room); failed
-- attempts only, exactly like the per-number limit, so genuine guests on one network are not punished for one
-- another's typos. Both booking-number paths obey: fn_guest_lookup and fn_guest_phone_verify_ref, each within
-- its own hotel.
-- The address derives in the server from the request's forwarded list — the last entry is the one the hosting
-- proxy appends; earlier entries are caller-supplied and never trusted.
-- =====================================================================

alter table guest_lookup_attempts add column if not exists client_address text;
create index if not exists idx_lookup_attempts_fp on guest_lookup_attempts(client_fingerprint, created_at);
create index if not exists idx_lookup_attempts_addr on guest_lookup_attempts(client_address, created_at);

create or replace function fn_client_address() returns text
language plpgsql stable set search_path = public as $$
declare v text; parts text[]; a text;
begin
  v := fn_request_header('x-forwarded-for');
  if v is null then return null; end if;
  parts := string_to_array(v, ',');
  a := btrim(parts[array_length(parts, 1)]);
  if a ~ '^[0-9A-Fa-f:.]{3,45}$' then return a; end if;
  return null;
end $$;
revoke all on function fn_client_address() from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.fn_guest_lookup(p_external_ref text, p_phone_last4 text, p_source_id uuid DEFAULT NULL::uuid, p_fingerprint text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_org uuid:=fn_guest_org_id();
  r reservations%rowtype;
  pg reservation_guests%rowtype;
  v_ref text := upper(trim(p_external_ref));
  v_token text;
  attempts int;
  v_match boolean := false;
  v_fp text;
  v_addr text;
begin
  if v_org is null or v_ref = '' or p_phone_last4 !~ '^\d{4}$' then
    return jsonb_build_object('status','invalid');
  end if;

  -- brute-force throttle: 5 failed attempts / 15 min per reference
  select count(*) into attempts from guest_lookup_attempts
   where organization_id=v_org and external_ref = v_ref and not ok and created_at > now() - interval '15 minutes';
  if attempts >= 5 then
    return jsonb_build_object('status','throttled');
  end if;

  -- plan 5.8 (S9): beyond the five failures per booking number, one device or one address cannot keep guessing
  -- numbers — 20 failures an hour per device, 40 per address (a shared network); failures only, like the
  -- per-number limit. The address derives in the server from the request's forwarded list (its last entry).
  v_fp := nullif(btrim(coalesce(p_fingerprint, '')), '');
  v_addr := fn_client_address();
  if v_fp is not null and (select count(*) from guest_lookup_attempts where organization_id = v_org and client_fingerprint = v_fp and not ok and created_at > now() - interval '1 hour') >= 20 then
    return jsonb_build_object('status','throttled');
  end if;
  if v_addr is not null and (select count(*) from guest_lookup_attempts where organization_id = v_org and client_address = v_addr and not ok and created_at > now() - interval '1 hour') >= 40 then
    return jsonb_build_object('status','throttled');
  end if;

  select * into r from reservations
   where organization_id=v_org and upper(external_ref) = v_ref and (p_source_id is null or source_id = p_source_id)
     and status not in ('cancelled','rejected','closed')
   limit 1;

  if not found then
    insert into guest_lookup_attempts(external_ref, client_fingerprint, client_address, ok, organization_id) values (v_ref, v_fp, v_addr, false, v_org);
    insert into human_handoff_tickets(organization_id, branch_id, kind, external_ref, source_name, details)
    select o.id, null, 'unmatched_reservation', v_ref, (select name from booking_sources where id = p_source_id),
           jsonb_build_object('phone_last4_given', true)
    from organizations o where o.id=v_org;
    return jsonb_build_object('status','unmatched');
  end if;

  select * into pg from reservation_guests where reservation_id = r.id and is_primary limit 1;
  if found and pg.phone is not null and right(regexp_replace(pg.phone,'\D','','g'),4) = p_phone_last4 then
    v_match := true;
  elsif found and pg.guest_profile_id is not null then
    select right(regexp_replace(phone,'\D','','g'),4) = p_phone_last4 into v_match from guest_profiles where id = pg.guest_profile_id;
  end if;

  insert into guest_lookup_attempts(external_ref, client_fingerprint, client_address, ok, organization_id) values (v_ref, v_fp, v_addr, coalesce(v_match,false), v_org);
  if not coalesce(v_match,false) then
    return jsonb_build_object('status','mismatch');
  end if;

  insert into registration_sessions(reservation_id, expires_at) values (r.id, now() + interval '24 hours')
  returning token into v_token;
  perform fn_audit(r.organization_id, r.branch_id, null, 'guest_verified_lookup', 'reservation', r.id, jsonb_build_object('channel','web'));
  return jsonb_build_object('status','ok','token', v_token);
end $function$;
CREATE OR REPLACE FUNCTION public.fn_guest_phone_verify_ref(p_phone text, p_ref text, p_fingerprint text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v_org uuid:=fn_guest_org_id(); v_phone text := fn_normalize_phone(p_phone); v_ref text := upper(trim(coalesce(p_ref, ''))); v_ok boolean;
        v_fp text := nullif(btrim(coalesce(p_fingerprint, '')), ''); v_addr text := fn_client_address();
begin
  if v_org is null or v_phone is null or v_ref = '' then return jsonb_build_object('status', 'invalid'); end if;
  perform pg_advisory_xact_lock(hashtext('lookup:' || v_phone));
  if (select count(*) from guest_lookup_attempts where organization_id=v_org and external_ref = 'PHONE:' || v_phone and not ok and created_at > now() - interval '15 minutes') >= 5 then
    return jsonb_build_object('status', 'throttled');
  end if;
  -- plan 5.8 (S9): the same per-device and per-address limits as the booking-number lookup
  if v_fp is not null and (select count(*) from guest_lookup_attempts where organization_id = v_org and client_fingerprint = v_fp and not ok and created_at > now() - interval '1 hour') >= 20 then
    return jsonb_build_object('status', 'throttled');
  end if;
  if v_addr is not null and (select count(*) from guest_lookup_attempts where organization_id = v_org and client_address = v_addr and not ok and created_at > now() - interval '1 hour') >= 40 then
    return jsonb_build_object('status', 'throttled');
  end if;
  select exists (select 1 from reservations r where r.id in (select fn_phone_reservation_ids(v_phone,v_org))
                  and (upper(r.external_ref) = v_ref or upper(r.internal_ref) = v_ref)) into v_ok;
  insert into guest_lookup_attempts(external_ref, client_fingerprint, client_address, ok, organization_id) values ('PHONE:' || v_phone, v_fp, v_addr, v_ok, v_org);
  if not v_ok then return jsonb_build_object('status', 'mismatch'); end if;
  return jsonb_build_object('status', 'ok', 'token', fn_phone_session(v_phone, 'booking_number',v_org));
end $function$;
