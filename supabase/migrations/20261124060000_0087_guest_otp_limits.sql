-- =====================================================================
-- 0083 — plan 5.2 (S2): the code messages («حجوزاتي» WhatsApp code).
--
-- A cap on SUCCESSFUL sends per phone, a cooldown between sends, and «إيقاف» honored. The
-- number's owner is not choked by someone else's attempts (لا يُخنق صاحب الرقم بمحاولات غيره):
--   - a send whose WhatsApp delivery fails is marked failed and frees its slot again;
--   - each device has its own send allowance per phone, so one stranger's device cannot spend
--     the owner's (a per-phone ceiling still bounds the total a phone can be flooded with);
--   - wrong guesses only lock further GUESSING — the right code still verifies afterwards.
--
-- AUTHORED, NOT APPLIED anywhere: the integrator rehearses this migration and wires
--   - guest-otp/index.ts: call fn_guest_phone_mark_sent(challenge_id, r.ok) after waSend;
--   - whatsapp-webhook / wa-bridge: an inbound «إيقاف»/stop calls fn_guest_phone_optout,
--     «استئناف»/start calls fn_guest_phone_optin (per branch's organization).
-- The numbers (3 sends per device per phone per hour, 6 per phone per hour, 60 seconds cooldown)
-- are defaults the plan left open.
-- =====================================================================

alter table guest_phone_challenges add column if not exists send_state text not null default 'pending';
alter table guest_phone_challenges drop constraint if exists guest_phone_challenges_send_state_valid;
alter table guest_phone_challenges add constraint guest_phone_challenges_send_state_valid check (send_state in ('pending', 'sent', 'failed'));
alter table guest_phone_challenges add column if not exists sent_at timestamptz;
create index if not exists idx_phone_challenges_sent on guest_phone_challenges(organization_id, phone, send_state, created_at);

-- «إيقاف»: a phone that asked for no more code messages. service role only (the webhook writes it).
create table if not exists guest_phone_optouts (
  organization_id uuid not null references organizations(id) on delete cascade,
  phone text not null,
  reason text,
  created_at timestamptz not null default now(),
  primary key (organization_id, phone)
);
alter table guest_phone_optouts enable row level security;
revoke all on guest_phone_optouts from anon, authenticated;

create or replace function fn_guest_phone_optout(p_org uuid, p_phone text, p_reason text default null) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_phone text := fn_normalize_phone(p_phone);
begin
  if p_org is null or v_phone is null or not exists (select 1 from organizations where id = p_org) then
    raise exception 'VALIDATION: phone_or_org';
  end if;
  insert into guest_phone_optouts(organization_id, phone, reason) values (p_org, v_phone, nullif(left(coalesce(p_reason, ''), 200), ''))
  on conflict (organization_id, phone) do nothing;
end $$;
revoke all on function fn_guest_phone_optout(uuid, text, text) from public, anon, authenticated;
grant execute on function fn_guest_phone_optout(uuid, text, text) to service_role;

create or replace function fn_guest_phone_optin(p_org uuid, p_phone text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_phone text := fn_normalize_phone(p_phone);
begin
  if p_org is null or v_phone is null then raise exception 'VALIDATION: phone_or_org'; end if;
  delete from guest_phone_optouts where organization_id = p_org and phone = v_phone;
end $$;
revoke all on function fn_guest_phone_optin(uuid, text) from public, anon, authenticated;
grant execute on function fn_guest_phone_optin(uuid, text) to service_role;

-- the guest-otp edge function reports the real outcome of the WhatsApp send: only a sent message
-- spends the phone's allowance; a failed one frees the slot it tentatively held
create or replace function fn_guest_phone_mark_sent(p_challenge uuid, p_sent boolean) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_sent then
    update guest_phone_challenges set send_state = 'sent', sent_at = now() where id = p_challenge and send_state = 'pending';
  else
    update guest_phone_challenges set send_state = 'failed' where id = p_challenge and send_state = 'pending';
  end if;
end $$;
revoke all on function fn_guest_phone_mark_sent(uuid, boolean) from public, anon, authenticated;
grant execute on function fn_guest_phone_mark_sent(uuid, boolean) to service_role;

-- 1. start — with the send cap, the cooldown and «إيقاف» (replaces the 0080 shape; the flow,
--    the hashing and the answers the edge function relies on are unchanged)
CREATE OR REPLACE FUNCTION public.fn_guest_phone_start(p_phone text, p_fingerprint text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v_org uuid:=fn_guest_org_id(); v_phone text := fn_normalize_phone(p_phone); v_code text; v_id uuid; v_branch uuid;
        c_device_sends constant int := 3;                      -- sends per device per phone per hour
        c_phone_sends constant int := 6;                       -- total sends per phone per hour (flood bound)
        c_cooldown constant interval := interval '60 seconds'; -- the pause between code messages
        c_attempts constant int := 20;                         -- attempts per device per hour (unchanged)
begin
  if v_org is null or v_phone is null then return jsonb_build_object('status', 'invalid'); end if;
  perform pg_advisory_xact_lock(hashtext('otp:' || v_org::text || ':' || v_phone));
  -- «إيقاف» is honored: nothing more is sent to a phone that asked to stop (the answer is the
  -- same 'throttled' as any other limit, so the page does not reveal that this phone opted out)
  if exists (select 1 from guest_phone_optouts where organization_id = v_org and phone = v_phone) then
    return jsonb_build_object('status', 'throttled');
  end if;
  -- the cap is on messages actually sent or on their way; a failed send frees its slot again
  if (select count(*) from guest_phone_challenges
       where organization_id = v_org and phone = v_phone and send_state <> 'failed'
         and created_at > now() - interval '1 hour') >= c_phone_sends
     or (p_fingerprint is not null and (select count(*) from guest_phone_challenges
       where organization_id = v_org and phone = v_phone and client_fingerprint = p_fingerprint and send_state <> 'failed'
         and created_at > now() - interval '1 hour') >= c_device_sends)
     or (select max(coalesce(sent_at, created_at)) from guest_phone_challenges
       where organization_id = v_org and phone = v_phone and send_state <> 'failed') > now() - c_cooldown then
    return jsonb_build_object('status', 'throttled');
  end if;
  -- attempts (any outcome) stay bounded per device, so a stranger cannot stack rows either
  if (p_fingerprint is not null and (select count(*) from guest_phone_challenges
       where organization_id = v_org and client_fingerprint = p_fingerprint and created_at > now() - interval '1 hour') >= c_attempts) then
    return jsonb_build_object('status', 'throttled');
  end if;
  select r.branch_id into v_branch from reservations r where r.id in (select fn_phone_reservation_ids(v_phone,v_org)) order by r.check_in desc limit 1;
  if v_branch is null then
    return jsonb_build_object('status', 'no_reservations', 'phone', v_phone);
  end if;
  v_code := lpad((('x' || encode(gen_random_bytes(4), 'hex'))::bit(32)::bigint % 1000000)::text, 6, '0');
  insert into guest_phone_challenges(phone, code_hash, client_fingerprint,organization_id,branch_id)
  values (v_phone, 'pending', p_fingerprint,v_org,v_branch) returning id into v_id;
  update guest_phone_challenges set code_hash = encode(digest(v_id::text || ':' || v_code, 'sha256'), 'hex') where id = v_id;
  return jsonb_build_object('status', 'ok', 'phone', v_phone, 'code', v_code, 'challenge_id', v_id, 'branch_id', v_branch);
end $function$
;
revoke all on function fn_guest_phone_start(text, text) from public, anon, authenticated;
grant execute on function fn_guest_phone_start(text, text) to service_role;

-- 2. verify — wrong guesses throttle only further guessing; the right code always passes, so the
--    number's owner is never locked out by someone else's attempts
CREATE OR REPLACE FUNCTION public.fn_guest_phone_verify(p_phone text, p_code text, p_fingerprint text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v_org uuid:=fn_guest_org_id(); v_phone text := fn_normalize_phone(p_phone); c guest_phone_challenges%rowtype;
        v_code text := regexp_replace(translate(coalesce(p_code, ''), '٠١٢٣٤٥٦٧٨٩', '0123456789'), '\D', '', 'g');
        v_match boolean;
begin
  if v_org is null or v_phone is null or v_code !~ '^\d{6}$' then return jsonb_build_object('status', 'invalid'); end if;
  select * into c from guest_phone_challenges
   where organization_id=v_org and phone = v_phone and verified_at is null and expires_at > now()
   order by created_at desc limit 1 for update;
  if not found then return jsonb_build_object('status', 'expired'); end if;
  v_match := c.code_hash = encode(digest(c.id::text || ':' || v_code, 'sha256'), 'hex');
  if not v_match then
    if c.attempts >= 5 then return jsonb_build_object('status', 'throttled'); end if;
    update guest_phone_challenges set attempts = attempts + 1 where id = c.id;
    return jsonb_build_object('status', 'mismatch', 'attempts_left', 4 - c.attempts);
  end if;
  update guest_phone_challenges set verified_at = now() where id = c.id;
  update reservation_guests g set phone_verified = true
   where g.is_primary and g.reservation_id in (select fn_phone_reservation_ids(v_phone,v_org)) and fn_normalize_phone(g.phone) = v_phone;
  return jsonb_build_object('status', 'ok', 'token', fn_phone_session(v_phone, 'whatsapp_code',v_org));
end $function$
;
grant execute on function fn_guest_phone_verify(text, text, text) to anon, authenticated;
