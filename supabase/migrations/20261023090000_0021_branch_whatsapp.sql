-- =====================================================================
-- 0021 — WhatsApp per branch: every branch has its own WhatsApp Business number, set up by the owner on
-- /admin/whatsapp (no server secrets to edit by hand). Guests talk to the branch's number: the website shows its
-- QR code, the whatsapp-webhook function answers there, and the guest's bookings are found by the WhatsApp sender
-- number itself (WhatsApp has already verified that the sender owns it).
--
--   branch_whatsapp_channels   one row per branch. The access token and the app secret are stored encrypted
--                              (pgp_sym_encrypt with the server key from Vault); no function ever returns them to a
--                              browser — the owner sees "saved ••••1234" and can replace or clear them.
--   conversations.wa_contact   the guest's WhatsApp number on WhatsApp conversations (one thread per number+branch)
--   whatsapp_inbound_messages  WhatsApp message ids already handled (Meta retries deliveries; each is answered once)
-- =====================================================================

create table if not exists branch_whatsapp_channels (
  branch_id uuid primary key references branches(id),
  organization_id uuid not null references organizations(id),
  enabled boolean not null default false,
  display_phone text,                        -- the business number guests write to (international digits, e.g. 9665…)
  phone_number_id text unique,               -- Meta: WhatsApp Business phone number id
  waba_id text,                              -- Meta: WhatsApp Business account id (reference only)
  access_token_encrypted bytea,
  token_last4 text,
  app_secret_encrypted bytea,                -- signs Meta's webhook calls (X-Hub-Signature-256)
  verify_token text not null unique default (lower(encode(gen_random_bytes(16), 'hex'))),
  otp_template text,                         -- approved Authentication template for the «حجوزاتي» code on the website
  template_lang text not null default 'ar',
  status text not null default 'not_configured' check (status in ('not_configured', 'configured', 'active', 'error')),
  last_error text,
  last_checked_at timestamptz,
  verified_name text,                        -- the business name Meta shows for the number (from the connection test)
  updated_by uuid references staff_profiles(id),
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  constraint whatsapp_display_phone_digits check (display_phone is null or display_phone ~ '^\d{8,15}$'),
  constraint whatsapp_phone_number_id_digits check (phone_number_id is null or phone_number_id ~ '^\d{5,30}$'),
  constraint whatsapp_template_name check (otp_template is null or otp_template ~ '^[a-z0-9_]{1,250}$'),
  constraint whatsapp_template_lang check (template_lang ~ '^[a-z]{2,3}(_[A-Z]{2})?$')
);
alter table branch_whatsapp_channels enable row level security;
revoke all on branch_whatsapp_channels from anon, authenticated;

alter table conversations add column if not exists wa_contact text;
create index if not exists idx_conversations_wa on conversations(branch_id, wa_contact, last_message_at desc) where wa_contact is not null;

create table if not exists whatsapp_inbound_messages (
  wa_message_id text primary key,
  branch_id uuid references branches(id),
  received_at timestamptz not null default now()
);
alter table whatsapp_inbound_messages enable row level security;
revoke all on whatsapp_inbound_messages from anon, authenticated;

-- a WhatsApp sender number is itself the proof of ownership
do $$ begin
  alter table guest_phone_sessions drop constraint if exists guest_phone_sessions_method_check;
  alter table guest_phone_sessions add constraint guest_phone_sessions_method_check check (method in ('whatsapp_code', 'booking_number', 'whatsapp_sender'));
end $$;

-- ---------------------------------------------------------------------
-- owner: list + save (secrets write-only)
-- ---------------------------------------------------------------------
create or replace function fn_whatsapp_status(c branch_whatsapp_channels) returns text
language sql immutable set search_path = public, extensions as $$
  select case
    when c.display_phone is null or c.phone_number_id is null or c.access_token_encrypted is null or c.app_secret_encrypted is null then 'not_configured'
    when c.status in ('active', 'error') then c.status
    else 'configured' end
$$;

create or replace function fn_admin_whatsapp_channels() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform fn_require_role('owner');
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'branch_id', b.id, 'branch_name', b.name_ar, 'branch_phone', b.phone,
      'enabled', coalesce(c.enabled, false), 'display_phone', c.display_phone, 'phone_number_id', c.phone_number_id,
      'waba_id', c.waba_id, 'has_token', c.access_token_encrypted is not null, 'token_last4', c.token_last4,
      'has_app_secret', c.app_secret_encrypted is not null, 'verify_token', c.verify_token,
      'otp_template', c.otp_template, 'template_lang', coalesce(c.template_lang, 'ar'),
      'status', coalesce(c.status, 'not_configured'), 'last_error', c.last_error, 'last_checked_at', c.last_checked_at,
      'verified_name', c.verified_name, 'updated_at', c.updated_at) order by b.created_at)
    from branches b left join branch_whatsapp_channels c on c.branch_id = b.id
    where b.organization_id = fn_user_org_id() and b.archived_at is null), '[]'::jsonb);
end $$;
grant execute on function fn_admin_whatsapp_channels() to authenticated;

create or replace function fn_admin_whatsapp_save(p_branch uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_org uuid := fn_user_org_id();
  c branch_whatsapp_channels%rowtype;
  v_phone text; v_token text := nullif(btrim(coalesce(p->>'access_token', '')), '');
  v_secret text := nullif(btrim(coalesce(p->>'app_secret', '')), '');
  v_changed text[] := '{}';
begin
  perform fn_require_role('owner');
  if not exists (select 1 from branches where id = p_branch and organization_id = v_org) then raise exception 'NOT_FOUND: branch'; end if;
  insert into branch_whatsapp_channels(branch_id, organization_id) values (p_branch, v_org) on conflict (branch_id) do nothing;
  select * into c from branch_whatsapp_channels where branch_id = p_branch for update;

  if p ? 'display_phone' then
    v_phone := fn_normalize_phone(p->>'display_phone');
    if nullif(btrim(coalesce(p->>'display_phone', '')), '') is not null and v_phone is null then raise exception 'VALIDATION: display_phone'; end if;
    if v_phone is distinct from c.display_phone then c.display_phone := v_phone; v_changed := array_append(v_changed, 'display_phone'); end if;
  end if;
  if p ? 'phone_number_id' then
    if nullif(btrim(coalesce(p->>'phone_number_id', '')), '') is not null and btrim(p->>'phone_number_id') !~ '^\d{5,30}$' then raise exception 'VALIDATION: phone_number_id'; end if;
    if nullif(btrim(p->>'phone_number_id'), '') is distinct from c.phone_number_id then
      if exists (select 1 from branch_whatsapp_channels where phone_number_id = btrim(p->>'phone_number_id') and branch_id <> p_branch) then
        raise exception 'VALIDATION: phone_number_id already used by another branch';
      end if;
      c.phone_number_id := nullif(btrim(p->>'phone_number_id'), ''); v_changed := array_append(v_changed, 'phone_number_id');
    end if;
  end if;
  if p ? 'waba_id' and nullif(btrim(p->>'waba_id'), '') is distinct from c.waba_id then
    if nullif(btrim(coalesce(p->>'waba_id', '')), '') is not null and btrim(p->>'waba_id') !~ '^\d{5,30}$' then raise exception 'VALIDATION: waba_id'; end if;
    c.waba_id := nullif(btrim(p->>'waba_id'), ''); v_changed := array_append(v_changed, 'waba_id');
  end if;
  if p ? 'otp_template' and nullif(lower(btrim(p->>'otp_template')), '') is distinct from c.otp_template then
    c.otp_template := nullif(lower(btrim(p->>'otp_template')), ''); v_changed := array_append(v_changed, 'otp_template');
  end if;
  if p ? 'template_lang' and coalesce(nullif(btrim(p->>'template_lang'), ''), 'ar') <> c.template_lang then
    c.template_lang := coalesce(nullif(btrim(p->>'template_lang'), ''), 'ar'); v_changed := array_append(v_changed, 'template_lang');
  end if;
  if v_token is not null then
    if length(v_token) < 20 or v_token ~ '\s' then raise exception 'VALIDATION: access_token'; end if;
    c.access_token_encrypted := pgp_sym_encrypt(v_token, fn_secret('keybox_key')); c.token_last4 := right(v_token, 4);
    v_changed := array_append(v_changed, 'access_token');
  elsif coalesce((p->>'clear_access_token')::boolean, false) then
    c.access_token_encrypted := null; c.token_last4 := null; v_changed := array_append(v_changed, 'access_token_cleared');
  end if;
  if v_secret is not null then
    if length(v_secret) < 16 or v_secret ~ '\s' then raise exception 'VALIDATION: app_secret'; end if;
    c.app_secret_encrypted := pgp_sym_encrypt(v_secret, fn_secret('keybox_key')); v_changed := array_append(v_changed, 'app_secret');
  elsif coalesce((p->>'clear_app_secret')::boolean, false) then
    c.app_secret_encrypted := null; v_changed := array_append(v_changed, 'app_secret_cleared');
  end if;
  if coalesce((p->>'regenerate_verify_token')::boolean, false) then
    c.verify_token := lower(encode(gen_random_bytes(16), 'hex')); v_changed := array_append(v_changed, 'verify_token');
  end if;
  -- any change to the connection itself needs a new connection test before it counts as active
  if v_changed && array['display_phone', 'phone_number_id', 'access_token', 'access_token_cleared', 'app_secret', 'app_secret_cleared'] then
    c.status := 'configured'; c.last_error := null; c.verified_name := null;
  end if;
  c.status := fn_whatsapp_status(c);
  if p ? 'enabled' and (p->>'enabled')::boolean is distinct from c.enabled then
    if (p->>'enabled')::boolean and c.status = 'not_configured' then
      raise exception 'VALIDATION: channel_incomplete';
    end if;
    c.enabled := (p->>'enabled')::boolean; v_changed := array_append(v_changed, 'enabled');
  end if;
  if c.status = 'not_configured' and c.enabled then c.enabled := false; v_changed := array_append(v_changed, 'disabled_incomplete'); end if;

  update branch_whatsapp_channels set
    enabled = c.enabled, display_phone = c.display_phone, phone_number_id = c.phone_number_id, waba_id = c.waba_id,
    access_token_encrypted = c.access_token_encrypted, token_last4 = c.token_last4, app_secret_encrypted = c.app_secret_encrypted,
    verify_token = c.verify_token, otp_template = c.otp_template, template_lang = c.template_lang, status = c.status,
    last_error = c.last_error, verified_name = c.verified_name, updated_by = fn_staff_id(), updated_at = now()
  where branch_id = p_branch;
  -- audited by field name only: no token, secret or verify token in the log
  perform fn_audit(v_org, p_branch, fn_staff_id(), 'whatsapp_channel_updated', 'branch', p_branch,
    jsonb_build_object('changed', to_jsonb(v_changed), 'enabled', c.enabled, 'status', c.status,
                       'display_phone_last4', right(c.display_phone, 4), 'reason', nullif(p->>'reason', '')));
  return jsonb_build_object('ok', true, 'status', c.status, 'enabled', c.enabled, 'changed', to_jsonb(v_changed));
end $$;
grant execute on function fn_admin_whatsapp_save(uuid, jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- server side (edge functions, service role): decrypted channel, status updates
-- ---------------------------------------------------------------------
create or replace function fn_whatsapp_channel(p_branch uuid default null, p_phone_number_id text default null, p_verify_token text default null) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare c branch_whatsapp_channels%rowtype;
begin
  select * into c from branch_whatsapp_channels
   where (p_branch is not null and branch_id = p_branch)
      or (p_phone_number_id is not null and phone_number_id = p_phone_number_id)
      or (p_verify_token is not null and verify_token = p_verify_token)
   limit 1;
  if not found then return null; end if;
  return jsonb_build_object(
    'branch_id', c.branch_id, 'organization_id', c.organization_id, 'enabled', c.enabled, 'status', c.status,
    'display_phone', c.display_phone, 'phone_number_id', c.phone_number_id, 'otp_template', c.otp_template,
    'template_lang', c.template_lang, 'verify_token', c.verify_token,
    'access_token', case when c.access_token_encrypted is null then null else pgp_sym_decrypt(c.access_token_encrypted, fn_secret('keybox_key')) end,
    'app_secret', case when c.app_secret_encrypted is null then null else pgp_sym_decrypt(c.app_secret_encrypted, fn_secret('keybox_key')) end);
end $$;
revoke all on function fn_whatsapp_channel(uuid, text, text) from public, anon, authenticated;
grant execute on function fn_whatsapp_channel(uuid, text, text) to service_role;

create or replace function fn_whatsapp_mark(p_branch uuid, p_status text, p_error text default null, p_verified_name text default null) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_status not in ('active', 'error') then raise exception 'VALIDATION: status'; end if;
  update branch_whatsapp_channels
     set status = case when fn_whatsapp_status(branch_whatsapp_channels) = 'not_configured' then 'not_configured' else p_status end,
         last_error = case when p_status = 'error' then left(p_error, 300) else null end,
         verified_name = coalesce(p_verified_name, verified_name), last_checked_at = now()
   where branch_id = p_branch;
end $$;
revoke all on function fn_whatsapp_mark(uuid, text, text, text) from public, anon, authenticated;
grant execute on function fn_whatsapp_mark(uuid, text, text, text) to service_role;

-- ---------------------------------------------------------------------
-- public: what the website shows (the QR of the branch's number, or "soon" with the branch phone)
-- ---------------------------------------------------------------------
create or replace function fn_public_whatsapp(p_branch uuid) returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object(
    'active', coalesce(c.enabled and c.status in ('configured', 'active'), false),
    'wa_phone', case when c.enabled and c.status in ('configured', 'active') then c.display_phone end,
    'branch_name', b.name_ar, 'branch_phone', b.phone)
  from branches b left join branch_whatsapp_channels c on c.branch_id = b.id
  where b.id = p_branch and b.is_active and b.archived_at is null
$$;
grant execute on function fn_public_whatsapp(uuid) to anon, authenticated;

-- ---------------------------------------------------------------------
-- the guest's bookings from inside WhatsApp (service role: the webhook knows the verified sender number)
-- ---------------------------------------------------------------------
create or replace function fn_whatsapp_phone_session(p_phone text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare v_phone text := fn_normalize_phone(p_phone);
begin
  if v_phone is null then raise exception 'VALIDATION: phone'; end if;
  return fn_phone_session(v_phone, 'whatsapp_sender');
end $$;
revoke all on function fn_whatsapp_phone_session(text) from public, anon, authenticated;
grant execute on function fn_whatsapp_phone_session(text) to service_role;

-- opening a booking records which channel proved the phone (web code, booking number or the WhatsApp sender)
create or replace function fn_guest_phone_open(p_token text, p_internal_ref text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare s guest_phone_sessions%rowtype; r reservations%rowtype; v_token text;
begin
  select * into s from guest_phone_sessions where token = p_token and expires_at > now();
  if not found then raise exception 'TOKEN_INVALID'; end if;
  select * into r from reservations where internal_ref = p_internal_ref and id in (select fn_phone_reservation_ids(s.phone));
  if not found then raise exception 'NOT_FOUND'; end if;
  insert into registration_sessions(reservation_id, expires_at) values (r.id, now() + interval '24 hours') returning token into v_token;
  perform fn_audit(r.organization_id, r.branch_id, null, 'guest_verified_lookup', 'reservation', r.id,
    jsonb_build_object('channel', case when s.method = 'whatsapp_sender' then 'whatsapp' else 'web' end, 'method', s.method));
  return jsonb_build_object('status', 'ok', 'token', v_token);
end $$;
grant execute on function fn_guest_phone_open(text, text) to anon, authenticated;

-- the website's code is sent from the WhatsApp number of the branch of the guest's latest booking
create or replace function fn_guest_phone_start(p_phone text, p_fingerprint text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_phone text := fn_normalize_phone(p_phone); v_code text; v_id uuid; v_branch uuid;
begin
  if v_phone is null then return jsonb_build_object('status', 'invalid'); end if;
  if (select count(*) from guest_phone_challenges where phone = v_phone and created_at > now() - interval '1 hour') >= 5
     or (p_fingerprint is not null and (select count(*) from guest_phone_challenges where client_fingerprint = p_fingerprint and created_at > now() - interval '1 hour') >= 20) then
    return jsonb_build_object('status', 'throttled');
  end if;
  select r.branch_id into v_branch from reservations r where r.id in (select fn_phone_reservation_ids(v_phone)) order by r.check_in desc limit 1;
  if v_branch is null then
    return jsonb_build_object('status', 'no_reservations', 'phone', v_phone);
  end if;
  v_code := lpad((('x' || encode(gen_random_bytes(4), 'hex'))::bit(32)::bigint % 1000000)::text, 6, '0');
  insert into guest_phone_challenges(phone, code_hash, client_fingerprint)
  values (v_phone, 'pending', p_fingerprint) returning id into v_id;
  update guest_phone_challenges set code_hash = encode(digest(v_id::text || ':' || v_code, 'sha256'), 'hex') where id = v_id;
  return jsonb_build_object('status', 'ok', 'phone', v_phone, 'code', v_code, 'challenge_id', v_id, 'branch_id', v_branch);
end $$;
revoke all on function fn_guest_phone_start(text, text) from public, anon, authenticated;
grant execute on function fn_guest_phone_start(text, text) to service_role;
