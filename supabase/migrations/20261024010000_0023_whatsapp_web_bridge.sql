-- =====================================================================
-- 0023 — WhatsApp through WhatsApp Web on the reception computer (no Meta API).
--
-- A branch can now run its WhatsApp number in one of two ways (branch_whatsapp_channels.mode):
--   web_bridge  the branch's own WhatsApp (Business app on the branch phone) is linked, like WhatsApp Web, to a small
--               program on the reception computer. The program reads every new guest message, asks the wa-bridge
--               function for the answer (the same conversation flow and assistant as everywhere) and types it into
--               WhatsApp Web; staff replies from the inbox go out the same way. No Meta account, no per-message fees.
--   cloud_api   the official WhatsApp Cloud API (0021), unchanged.
--
-- The program authenticates with a per-branch bridge key: the owner creates it on /admin/whatsapp and downloads it
-- once inside bridge-config.json; only its SHA-256 is stored. A new key stops the old program at once.
--
-- A receptionist who answers a guest directly in WhatsApp (phone or the WhatsApp Web window) takes that chat over:
-- the assistant stays silent there for human_pause_minutes, and the message appears in the inbox. Staff replies from
-- the inbox do the same. "Return to the assistant" in the inbox ends the pause.
--
--   whatsapp_outbox          staff messages waiting for the reception computer to type them (ids only: the text and
--                            the chat are read from the message itself when it is sent)
--   conversations.wa_chat_id the WhatsApp Web chat of the thread (where replies go)
--   conversations.wa_menu    the numbered options the guest was last offered («أرسل رقم الخيار»)
--   conversations.human_active_until   the assistant is silent in this chat until then
-- =====================================================================

alter table branch_whatsapp_channels add column if not exists mode text not null default 'cloud_api';
-- the path chosen for this deployment; rows that already hold Cloud API details keep cloud_api
alter table branch_whatsapp_channels alter column mode set default 'web_bridge';
update branch_whatsapp_channels set mode = 'web_bridge'
 where phone_number_id is null and access_token_encrypted is null and app_secret_encrypted is null;

alter table branch_whatsapp_channels add column if not exists bridge_key_hash text;
alter table branch_whatsapp_channels add column if not exists bridge_key_last4 text;
alter table branch_whatsapp_channels add column if not exists bridge_key_created_at timestamptz;
alter table branch_whatsapp_channels add column if not exists bridge_status text;        -- what the program last reported
alter table branch_whatsapp_channels add column if not exists bridge_phone text;         -- the WhatsApp number linked in it
alter table branch_whatsapp_channels add column if not exists bridge_name text;          -- its WhatsApp profile name
alter table branch_whatsapp_channels add column if not exists bridge_version text;
alter table branch_whatsapp_channels add column if not exists bridge_last_seen timestamptz;
alter table branch_whatsapp_channels add column if not exists auto_reply boolean not null default true;
alter table branch_whatsapp_channels add column if not exists human_pause_minutes int not null default 60;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'whatsapp_mode') then
    alter table branch_whatsapp_channels add constraint whatsapp_mode check (mode in ('cloud_api', 'web_bridge'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'whatsapp_bridge_status') then
    alter table branch_whatsapp_channels add constraint whatsapp_bridge_status
      check (bridge_status is null or bridge_status in ('starting', 'qr', 'connected', 'disconnected', 'stopped'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'whatsapp_human_pause') then
    alter table branch_whatsapp_channels add constraint whatsapp_human_pause check (human_pause_minutes between 5 and 720);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'whatsapp_bridge_key_unique') then
    alter table branch_whatsapp_channels add constraint whatsapp_bridge_key_unique unique (bridge_key_hash);
  end if;
end $$;

alter table conversations add column if not exists wa_chat_id text;
alter table conversations add column if not exists wa_menu jsonb;
alter table conversations add column if not exists human_active_until timestamptz;

create table if not exists whatsapp_outbox (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references branches(id),
  message_id uuid not null,                  -- the staff message in conversation_messages
  status text not null default 'pending' check (status in ('pending', 'sending', 'sent', 'failed', 'expired')),
  attempts int not null default 0,
  wa_id text,
  error text,
  created_at timestamptz not null default now(),
  picked_at timestamptz,
  finished_at timestamptz
);
create index if not exists idx_whatsapp_outbox_open on whatsapp_outbox(branch_id, created_at) where status in ('pending', 'sending');
alter table whatsapp_outbox enable row level security;
revoke all on whatsapp_outbox from anon, authenticated;

-- ---------------------------------------------------------------------
-- status: a bridge channel is complete with the branch number and a bridge key
-- ---------------------------------------------------------------------
create or replace function fn_whatsapp_status(c branch_whatsapp_channels) returns text
language sql immutable set search_path = public, extensions as $$
  select case
    when c.mode = 'web_bridge' and (c.display_phone is null or c.bridge_key_hash is null) then 'not_configured'
    when c.mode is distinct from 'web_bridge' and (c.display_phone is null or c.phone_number_id is null
         or c.access_token_encrypted is null or c.app_secret_encrypted is null) then 'not_configured'
    when c.status in ('active', 'error') then c.status
    else 'configured' end
$$;

-- ---------------------------------------------------------------------
-- owner: list + save
-- ---------------------------------------------------------------------
create or replace function fn_admin_whatsapp_channels() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform fn_require_role('owner');
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'branch_id', b.id, 'branch_name', b.name_ar, 'branch_phone', b.phone,
      'mode', coalesce(c.mode, 'web_bridge'),
      'enabled', coalesce(c.enabled, false), 'display_phone', c.display_phone, 'phone_number_id', c.phone_number_id,
      'waba_id', c.waba_id, 'has_token', c.access_token_encrypted is not null, 'token_last4', c.token_last4,
      'has_app_secret', c.app_secret_encrypted is not null, 'verify_token', c.verify_token,
      'otp_template', c.otp_template, 'template_lang', coalesce(c.template_lang, 'ar'),
      'status', coalesce(c.status, 'not_configured'), 'last_error', c.last_error, 'last_checked_at', c.last_checked_at,
      'verified_name', c.verified_name, 'updated_at', c.updated_at,
      'auto_reply', coalesce(c.auto_reply, true), 'human_pause_minutes', coalesce(c.human_pause_minutes, 60),
      'has_bridge_key', c.bridge_key_hash is not null, 'bridge_key_last4', c.bridge_key_last4,
      'bridge_key_created_at', c.bridge_key_created_at, 'bridge_status', c.bridge_status, 'bridge_phone', c.bridge_phone,
      'bridge_name', c.bridge_name, 'bridge_version', c.bridge_version, 'bridge_last_seen', c.bridge_last_seen,
      'bridge_online', coalesce(c.bridge_last_seen > now() - interval '90 seconds', false)) order by b.created_at)
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
  v_key text; v_pause int;
begin
  perform fn_require_role('owner');
  if not exists (select 1 from branches where id = p_branch and organization_id = v_org) then raise exception 'NOT_FOUND: branch'; end if;
  insert into branch_whatsapp_channels(branch_id, organization_id) values (p_branch, v_org) on conflict (branch_id) do nothing;
  select * into c from branch_whatsapp_channels where branch_id = p_branch for update;

  if p ? 'mode' then
    if coalesce(p->>'mode', '') not in ('cloud_api', 'web_bridge') then raise exception 'VALIDATION: mode'; end if;
    if p->>'mode' <> c.mode then c.mode := p->>'mode'; v_changed := array_append(v_changed, 'mode'); end if;
  end if;
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

  -- reception-computer link: a new key replaces the old one at once (the old program is refused from now on)
  if coalesce((p->>'regenerate_bridge_key')::boolean, false) then
    v_key := 'zb_' || encode(gen_random_bytes(32), 'hex');
    c.bridge_key_hash := encode(digest(v_key, 'sha256'), 'hex'); c.bridge_key_last4 := right(v_key, 4); c.bridge_key_created_at := now();
    c.bridge_status := null; c.bridge_phone := null; c.bridge_name := null; c.bridge_version := null; c.bridge_last_seen := null;
    v_changed := array_append(v_changed, 'bridge_key');
  elsif coalesce((p->>'revoke_bridge_key')::boolean, false) and c.bridge_key_hash is not null then
    c.bridge_key_hash := null; c.bridge_key_last4 := null; c.bridge_key_created_at := null;
    c.bridge_status := null; c.bridge_last_seen := null;
    v_changed := array_append(v_changed, 'bridge_key_revoked');
  end if;
  if p ? 'auto_reply' then
    if jsonb_typeof(p->'auto_reply') <> 'boolean' then raise exception 'VALIDATION: auto_reply'; end if;
    if (p->>'auto_reply')::boolean <> c.auto_reply then c.auto_reply := (p->>'auto_reply')::boolean; v_changed := array_append(v_changed, 'auto_reply'); end if;
  end if;
  if p ? 'human_pause_minutes' then
    if jsonb_typeof(p->'human_pause_minutes') <> 'number' then raise exception 'VALIDATION: human_pause_minutes'; end if;
    v_pause := round((p->>'human_pause_minutes')::numeric);
    if v_pause < 5 or v_pause > 720 then raise exception 'VALIDATION: human_pause_minutes'; end if;
    if v_pause <> c.human_pause_minutes then c.human_pause_minutes := v_pause; v_changed := array_append(v_changed, 'human_pause_minutes'); end if;
  end if;

  -- any change to the connection itself needs a new test (Cloud API) or a new report from the program (bridge)
  if v_changed && array['mode', 'display_phone', 'phone_number_id', 'access_token', 'access_token_cleared', 'app_secret',
                        'app_secret_cleared', 'bridge_key', 'bridge_key_revoked'] then
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
    mode = c.mode, enabled = c.enabled, display_phone = c.display_phone, phone_number_id = c.phone_number_id, waba_id = c.waba_id,
    access_token_encrypted = c.access_token_encrypted, token_last4 = c.token_last4, app_secret_encrypted = c.app_secret_encrypted,
    verify_token = c.verify_token, otp_template = c.otp_template, template_lang = c.template_lang, status = c.status,
    last_error = c.last_error, verified_name = c.verified_name,
    bridge_key_hash = c.bridge_key_hash, bridge_key_last4 = c.bridge_key_last4, bridge_key_created_at = c.bridge_key_created_at,
    bridge_status = c.bridge_status, bridge_phone = c.bridge_phone, bridge_name = c.bridge_name, bridge_version = c.bridge_version,
    bridge_last_seen = c.bridge_last_seen, auto_reply = c.auto_reply, human_pause_minutes = c.human_pause_minutes,
    updated_by = fn_staff_id(), updated_at = now()
  where branch_id = p_branch;
  -- audited by field name only: no token, secret, verify token or bridge key in the log
  perform fn_audit(v_org, p_branch, fn_staff_id(), 'whatsapp_channel_updated', 'branch', p_branch,
    jsonb_build_object('changed', to_jsonb(v_changed), 'mode', c.mode, 'enabled', c.enabled, 'status', c.status,
                       'auto_reply', c.auto_reply, 'display_phone_last4', right(c.display_phone, 4), 'reason', nullif(p->>'reason', '')));
  -- the bridge key is returned this once (for bridge-config.json) and never again
  return jsonb_build_object('ok', true, 'status', c.status, 'enabled', c.enabled, 'mode', c.mode, 'changed', to_jsonb(v_changed))
      || case when v_key is null then '{}'::jsonb else jsonb_build_object('bridge_key', v_key) end;
end $$;
grant execute on function fn_admin_whatsapp_save(uuid, jsonb) to authenticated;

-- the Cloud API functions read the mode too (a bridge branch never answers Meta's webhook or sends through it)
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
    'branch_id', c.branch_id, 'organization_id', c.organization_id, 'mode', c.mode, 'enabled', c.enabled, 'status', c.status,
    'auto_reply', c.auto_reply, 'display_phone', c.display_phone, 'phone_number_id', c.phone_number_id, 'otp_template', c.otp_template,
    'template_lang', c.template_lang, 'verify_token', c.verify_token,
    'access_token', case when c.access_token_encrypted is null then null else pgp_sym_decrypt(c.access_token_encrypted, fn_secret('keybox_key')) end,
    'app_secret', case when c.app_secret_encrypted is null then null else pgp_sym_decrypt(c.app_secret_encrypted, fn_secret('keybox_key')) end);
end $$;
revoke all on function fn_whatsapp_channel(uuid, text, text) from public, anon, authenticated;
grant execute on function fn_whatsapp_channel(uuid, text, text) to service_role;

-- public: a bridge number keeps its QR while the reception computer is briefly off (the phone still receives)
create or replace function fn_public_whatsapp(p_branch uuid) returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object(
    'active', coalesce(c.enabled and (c.status in ('configured', 'active') or (c.mode = 'web_bridge' and c.status = 'error')), false),
    'wa_phone', case when c.enabled and (c.status in ('configured', 'active') or (c.mode = 'web_bridge' and c.status = 'error')) then c.display_phone end,
    'branch_name', b.name_ar, 'branch_phone', b.phone)
  from branches b left join branch_whatsapp_channels c on c.branch_id = b.id
  where b.id = p_branch and b.is_active and b.archived_at is null
$$;
grant execute on function fn_public_whatsapp(uuid) to anon, authenticated;

-- ---------------------------------------------------------------------
-- the program on the reception computer (wa-bridge function, service role)
-- ---------------------------------------------------------------------
create or replace function fn_wa_bridge_auth(p_key text) returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object('branch_id', c.branch_id, 'organization_id', c.organization_id, 'enabled', c.enabled,
    'auto_reply', c.auto_reply, 'status', c.status, 'display_phone', c.display_phone,
    'human_pause_minutes', c.human_pause_minutes, 'branch_name', b.name_ar)
  from branch_whatsapp_channels c join branches b on b.id = c.branch_id
  where coalesce(p_key, '') ~ '^zb_[0-9a-f]{64}$' and c.mode = 'web_bridge'
    and c.bridge_key_hash = encode(digest(p_key, 'sha256'), 'hex')
$$;
revoke all on function fn_wa_bridge_auth(text) from public, anon, authenticated;
grant execute on function fn_wa_bridge_auth(text) to service_role;

-- heartbeat: what the program sees (QR waiting, connected as which number, logged out …)
create or replace function fn_wa_bridge_beat(p_branch uuid, p_status text, p_phone text default null, p_name text default null,
                                             p_version text default null, p_detail text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare c branch_whatsapp_channels%rowtype; v_phone text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  if coalesce(p_status, '') not in ('starting', 'qr', 'connected', 'disconnected', 'stopped') then raise exception 'VALIDATION: status'; end if;
  select * into c from branch_whatsapp_channels where branch_id = p_branch and mode = 'web_bridge' for update;
  if not found then return null; end if;
  update branch_whatsapp_channels set
    bridge_status = p_status, bridge_last_seen = now(),
    bridge_phone = case when v_phone ~ '^\d{8,15}$' then v_phone else bridge_phone end,
    bridge_name = coalesce(left(nullif(btrim(p_name), ''), 80), bridge_name),
    bridge_version = coalesce(left(nullif(btrim(p_version), ''), 40), bridge_version),
    status = case when fn_whatsapp_status(c) = 'not_configured' then 'not_configured'
                  when p_status = 'connected' then 'active'
                  when p_status = 'disconnected' then 'error'
                  else status end,
    last_error = case when p_status = 'connected' then null
                      when p_status = 'disconnected' then left(coalesce(nullif(btrim(p_detail), ''), 'disconnected'), 300)
                      else last_error end,
    last_checked_at = case when p_status in ('connected', 'disconnected') then now() else last_checked_at end
  where branch_id = p_branch;
  return jsonb_build_object('enabled', c.enabled, 'auto_reply', c.auto_reply, 'human_pause_minutes', c.human_pause_minutes);
end $$;
revoke all on function fn_wa_bridge_beat(uuid, text, text, text, text, text) from public, anon, authenticated;
grant execute on function fn_wa_bridge_beat(uuid, text, text, text, text, text) to service_role;

-- staff replies waiting for the program: picked once; a pick without confirmation within 5 minutes is reported as
-- failed (never typed twice), and a reply that waited 12 hours (computer off) is not sent late
create or replace function fn_wa_bridge_poll(p_branch uuid, p_limit int default 5) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r record; v_out jsonb := '[]'::jsonb; v_text text; v_chat text;
begin
  with stale as (
    update whatsapp_outbox set status = case when status = 'sending' then 'failed' else 'expired' end,
           error = case when status = 'sending' then 'no_ack' else 'expired' end, finished_at = now()
     where branch_id = p_branch
       and ((status = 'sending' and picked_at < now() - interval '5 minutes') or (status = 'pending' and created_at < now() - interval '12 hours'))
    returning message_id, error)
  update conversation_messages m set meta = coalesce(m.meta, '{}'::jsonb) || jsonb_build_object('delivery', 'failed', 'error', s.error)
    from stale s where m.id = s.message_id;

  for r in
    select o.id, o.message_id from whatsapp_outbox o
     where o.branch_id = p_branch and o.status = 'pending'
     order by o.created_at limit greatest(1, least(coalesce(p_limit, 5), 20))
     for update skip locked
  loop
    v_text := null; v_chat := null;
    select m.content, cv.wa_chat_id into v_text, v_chat
      from conversation_messages m join conversations cv on cv.id = m.conversation_id
     where m.id = r.message_id and cv.branch_id = p_branch;
    if v_text is null or v_chat is null then
      update whatsapp_outbox set status = 'expired', error = 'message_gone', finished_at = now() where id = r.id;
    else
      update whatsapp_outbox set status = 'sending', picked_at = now(), attempts = attempts + 1 where id = r.id;
      v_out := v_out || jsonb_build_array(jsonb_build_object('id', r.id, 'chat_id', v_chat, 'text', v_text));
    end if;
  end loop;
  return v_out;
end $$;
revoke all on function fn_wa_bridge_poll(uuid, int) from public, anon, authenticated;
grant execute on function fn_wa_bridge_poll(uuid, int) to service_role;

create or replace function fn_wa_bridge_ack(p_branch uuid, p_id uuid, p_ok boolean, p_wa_id text default null, p_error text default null) returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare v_msg uuid;
begin
  update whatsapp_outbox set status = case when p_ok then 'sent' else 'failed' end, wa_id = left(p_wa_id, 200),
         error = case when p_ok then null else left(coalesce(nullif(btrim(p_error), ''), 'send_failed'), 200) end, finished_at = now()
   where id = p_id and branch_id = p_branch and status = 'sending'
  returning message_id into v_msg;
  if v_msg is null then return false; end if;
  update conversation_messages set meta = coalesce(meta, '{}'::jsonb)
         || jsonb_build_object('delivery', case when p_ok then 'sent' else 'failed' end)
         || case when p_ok then '{}'::jsonb else jsonb_build_object('error', left(coalesce(nullif(btrim(p_error), ''), 'send_failed'), 200)) end
   where id = v_msg;
  return true;
end $$;
revoke all on function fn_wa_bridge_ack(uuid, uuid, boolean, text, text) from public, anon, authenticated;
grant execute on function fn_wa_bridge_ack(uuid, uuid, boolean, text, text) to service_role;

-- a staff reply from the inbox on a bridge branch: queued for the reception computer, and the assistant steps back.
-- Like WhatsApp's own rule for businesses, only a guest who wrote in the last 24 hours gets a free-text reply.
create or replace function fn_wa_bridge_enqueue(p_message uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare m conversation_messages%rowtype; cv conversations%rowtype; c branch_whatsapp_channels%rowtype; v_last timestamptz; v_err text;
begin
  select * into m from conversation_messages where id = p_message and sender = 'supervisor';
  if not found then return jsonb_build_object('queued', false, 'error', 'not_found'); end if;
  select * into cv from conversations where id = m.conversation_id;
  select * into c from branch_whatsapp_channels where branch_id = cv.branch_id;
  if cv.channel <> 'whatsapp' or cv.wa_chat_id is null then v_err := 'not_whatsapp';
  elsif c.branch_id is null or c.mode <> 'web_bridge' or not c.enabled or c.bridge_key_hash is null then v_err := 'channel_unavailable';
  else
    select max(gm.created_at) into v_last from conversation_messages gm join conversations gc on gc.id = gm.conversation_id
     where gc.branch_id = cv.branch_id and gc.wa_contact = cv.wa_contact and gm.sender = 'guest';
    if v_last is null or v_last < now() - interval '24 hours' then v_err := 'window_closed'; end if;
  end if;
  if v_err is not null then
    update conversation_messages set meta = coalesce(meta, '{}'::jsonb) || jsonb_build_object('channel', 'whatsapp', 'delivery', 'failed', 'error', v_err) where id = m.id;
    return jsonb_build_object('queued', false, 'error', v_err);
  end if;
  insert into whatsapp_outbox(branch_id, message_id) values (cv.branch_id, m.id);
  update conversations set human_active_until = now() + make_interval(mins => c.human_pause_minutes), last_message_at = now() where id = cv.id;
  update conversation_messages set meta = coalesce(meta, '{}'::jsonb) || jsonb_build_object('channel', 'whatsapp', 'delivery', 'queued') where id = m.id;
  return jsonb_build_object('queued', true, 'bridge_online', coalesce(c.bridge_last_seen > now() - interval '90 seconds', false));
end $$;
revoke all on function fn_wa_bridge_enqueue(uuid) from public, anon, authenticated;
grant execute on function fn_wa_bridge_enqueue(uuid) to service_role;

-- ---------------------------------------------------------------------
-- inbox: take a conversation (the assistant steps back) or return it to the assistant — audited
-- ---------------------------------------------------------------------
create or replace function fn_conversation_take(p_conversation uuid, p_take boolean) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare cv conversations%rowtype; v_org uuid; v_pause int; v_until timestamptz;
begin
  perform fn_require_role('owner', 'manager', 'supervisor');
  select * into cv from conversations where id = p_conversation for update;
  if not found then raise exception 'NOT_FOUND: conversation'; end if;
  if cv.branch_id is not null and cv.branch_id not in (select fn_user_branch_ids()) then raise exception 'FORBIDDEN: branch'; end if;
  v_org := coalesce((select organization_id from branches where id = cv.branch_id), fn_user_org_id());
  if v_org is distinct from fn_user_org_id() then raise exception 'FORBIDDEN: branch'; end if;
  if p_take then
    select human_pause_minutes into v_pause from branch_whatsapp_channels where branch_id = cv.branch_id;
    v_until := case when cv.channel = 'whatsapp' then now() + make_interval(mins => coalesce(v_pause, 60)) end;
    update conversations set status = 'handed_off', handed_off_at = coalesce(handed_off_at, now()),
           human_active_until = coalesce(v_until, human_active_until) where id = cv.id;
  else
    update conversations set status = 'active', handed_off_at = null, human_active_until = null where id = cv.id;
  end if;
  perform fn_audit(v_org, cv.branch_id, fn_staff_id(), case when p_take then 'conversation_taken' else 'conversation_returned_to_assistant' end,
    'conversation', cv.id, jsonb_build_object('before', cv.status, 'after', case when p_take then 'handed_off' else 'active' end, 'channel', cv.channel));
  return jsonb_build_object('ok', true, 'status', case when p_take then 'handed_off' else 'active' end,
                            'human_active_until', case when p_take then coalesce(v_until, cv.human_active_until) end);
end $$;
grant execute on function fn_conversation_take(uuid, boolean) to authenticated;
