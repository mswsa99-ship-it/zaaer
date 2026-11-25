-- =====================================================================
-- 0082 — plan 5.1 (S1): the guest assistant's budget.
--
-- A limit per session (already: per_session_message_limit) AND per device (new), a phone code
-- after a number of anonymous messages (new), and a daily ceiling per branch (new) and per hotel
-- (existing daily_request_limit, now reserved atomically). An anonymous caller cannot drain
-- another caller's share: every device has its own counter.
--
-- fn_ai_guest_reserve is the single admission point for a guest message (service role only —
-- ai-reception calls it before the input gate). Each counter is one atomic check-and-increment
-- statement, so a flood of simultaneous messages never pushes a counter past its limit; the
-- per-device and per-conversation advisory locks keep the OTP gate and the session count exact
-- under the same flood. The numbers (10 messages before the code, 30 per device per day, 500 per
-- branch per day) are defaults the plan left open; the owner can tune them per hotel.
--
-- AUTHORED, NOT APPLIED anywhere: the integrator rehearses this migration and wires ai-reception
-- (call fn_ai_guest_reserve for screen-channel guest messages; pass p_requests => 0 to
-- fn_ai_usage_bump for a message the reserve already counted, tokens still bump after the call).
-- =====================================================================

-- per-hotel knobs on the owner's AI settings row (same place as the existing limits)
alter table ai_settings add column if not exists guest_otp_after_messages int not null default 10;
alter table ai_settings add column if not exists guest_device_daily_message_limit int not null default 30;
alter table ai_settings add column if not exists guest_branch_daily_message_limit int not null default 500;
alter table ai_settings drop constraint if exists ai_settings_guest_limits_valid;
alter table ai_settings add constraint ai_settings_guest_limits_valid check (
  guest_otp_after_messages between 1 and 100
  and guest_device_daily_message_limit between 1 and 1000
  and guest_branch_daily_message_limit between 1 and 100000
) not valid;
alter table ai_settings validate constraint ai_settings_guest_limits_valid;

-- one counter per device (browser fingerprint) per branch per day
create table if not exists ai_guest_usage_daily (
  organization_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid not null references branches(id) on delete cascade,
  client_fingerprint text not null,
  day date not null default current_date,
  messages int not null default 0,
  primary key (organization_id, branch_id, client_fingerprint, day)
);

-- one counter per branch per day (the branch ceiling of plan 5.1)
create table if not exists ai_branch_usage_daily (
  organization_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid not null references branches(id) on delete cascade,
  day date not null default current_date,
  messages int not null default 0,
  primary key (branch_id, day)
);

-- the admitted-session counter (review fix of 24 Nov 2026): one row per conversation, advanced
-- atomically inside fn_ai_guest_reserve. A recount of conversation_messages cannot cap a race —
-- the edge function inserts the message after the reserve's locks are gone, so two concurrent
-- callers both read a passing count; this counter is reserved inside the same transaction as the
-- admission itself. It is seeded from the messages already stored, so a conversation keeps what
-- it already spent.
create table if not exists ai_guest_session_usage (
  organization_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid not null references branches(id) on delete cascade,
  conversation_id uuid not null references conversations(id) on delete cascade,
  admitted int not null default 0,
  primary key (conversation_id)
);
insert into ai_guest_session_usage(organization_id, branch_id, conversation_id, admitted)
select c.organization_id, c.branch_id, c.id,
       (select count(*) from conversation_messages m where m.conversation_id = c.id and m.sender = 'guest')
from conversations c
on conflict (conversation_id) do nothing;

alter table ai_guest_usage_daily enable row level security;
alter table ai_branch_usage_daily enable row level security;
alter table ai_guest_session_usage enable row level security;
revoke all on ai_guest_usage_daily, ai_branch_usage_daily, ai_guest_session_usage from anon, authenticated;

-- 0078's row rule: a counter row cannot point to a branch of another hotel (FS03)
create or replace trigger zz_hotel_pointers after insert or update of branch_id, organization_id on public.ai_guest_usage_daily
  for each row execute function fn_hotel_pointers('branch_id', 'branches');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, organization_id on public.ai_branch_usage_daily
  for each row execute function fn_hotel_pointers('branch_id', 'branches');
create or replace trigger zz_hotel_pointers after insert or update of branch_id, conversation_id, organization_id on public.ai_guest_session_usage
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'conversation_id', 'conversations');

-- Admission of one guest message. Statuses:
--   ok | session_limit | otp_required | device_limit | branch_limit | hotel_limit
--   | branch_not_found | conversation_not_found
-- Only 'ok' consumes quota. The OTP gate reads the device's counter BEFORE the increment, so the
-- gate itself never drains; a caller verified by a phone code or a booking link (p_verified)
-- skips the gate and stays under the session, device, branch and hotel caps like everyone else.
create or replace function fn_ai_guest_reserve(p_branch uuid, p_conversation uuid, p_fingerprint text, p_verified boolean default false)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_branch branches%rowtype;
  v_conv conversations%rowtype;
  s ai_settings%rowtype;
  v_fp text := coalesce(nullif(left(coalesce(p_fingerprint, ''), 120), ''), '(unknown)');
  -- the usage counters' day is the UTC day ai-reception uses, never the session time zone (0019, PL09)
  v_day date := (now() at time zone 'utc')::date;
  v_session int; v_device int; v_device_before int; v_branch_used int; v_hotel int;
  v_reject text;
begin
  select * into v_branch from branches where id = p_branch and is_active and archived_at is null;
  if not found then return jsonb_build_object('status', 'branch_not_found'); end if;
  select * into v_conv from conversations where id = p_conversation and organization_id = v_branch.organization_id and branch_id = v_branch.id;
  if not found then return jsonb_build_object('status', 'conversation_not_found'); end if;
  insert into ai_settings(organization_id) values (v_branch.organization_id) on conflict do nothing;
  select * into s from ai_settings where organization_id = v_branch.organization_id;

  -- fixed lock order (device, then conversation) so concurrent floods serialize instead of racing
  perform pg_advisory_xact_lock(hashtext('ai-guest-dev:' || v_branch.id::text || ':' || v_fp));
  perform pg_advisory_xact_lock(hashtext('ai-guest-conv:' || p_conversation::text));

  -- the phone code after a number of anonymous messages (plan 5.1: رمز الجوال بعد عدد من الرسائل).
  -- The gate reads the device's counter BEFORE any increment, so the gate itself never drains.
  select g.messages into v_device_before from ai_guest_usage_daily g
   where g.organization_id = v_branch.organization_id and g.branch_id = v_branch.id
     and g.client_fingerprint = v_fp and g.day = v_day;
  if not coalesce(p_verified, false) and coalesce(v_device_before, 0) >= s.guest_otp_after_messages then
    return jsonb_build_object('status', 'otp_required', 'device_used', coalesce(v_device_before, 0));
  end if;

  -- Admission is all-or-nothing (review fixes of 24 Nov 2026). Every cap is one atomic
  -- check-and-increment upsert inside a subtransaction; a reject at any cap raises, the
  -- subtransaction rolls the earlier counters back, and a refused message consumes nothing
  -- (before this, a branch_limit or hotel_limit return kept the +1 the device had already taken).
  -- The session cap is the admitted counter, not a recount of conversation_messages: the edge
  -- function inserts the message after this call's locks are gone, and a recount let two
  -- concurrent callers both pass (مجهول لا يستنزف ميزانية غيره: each device spends only its own).
  begin
    insert into ai_guest_session_usage(organization_id, branch_id, conversation_id, admitted)
    values (v_branch.organization_id, v_branch.id, p_conversation, 1)
    on conflict (conversation_id) do update
      set admitted = ai_guest_session_usage.admitted + 1
      where ai_guest_session_usage.admitted < s.per_session_message_limit
    returning admitted into v_session;
    if v_session is null then v_reject := 'session_limit'; raise exception 'guest_reserve_reject' using errcode = 'P0001'; end if;

    insert into ai_guest_usage_daily(organization_id, branch_id, client_fingerprint, day, messages)
    values (v_branch.organization_id, v_branch.id, v_fp, v_day, 1)
    on conflict (organization_id, branch_id, client_fingerprint, day) do update
      set messages = ai_guest_usage_daily.messages + 1
      where ai_guest_usage_daily.messages < s.guest_device_daily_message_limit
    returning messages into v_device;
    if v_device is null then v_reject := 'device_limit'; raise exception 'guest_reserve_reject' using errcode = 'P0001'; end if;

    insert into ai_branch_usage_daily(organization_id, branch_id, day, messages)
    values (v_branch.organization_id, v_branch.id, v_day, 1)
    on conflict (branch_id, day) do update
      set messages = ai_branch_usage_daily.messages + 1
      where ai_branch_usage_daily.messages < s.guest_branch_daily_message_limit
    returning messages into v_branch_used;
    if v_branch_used is null then v_reject := 'branch_limit'; raise exception 'guest_reserve_reject' using errcode = 'P0001'; end if;

    -- the hotel ceiling is the existing daily request budget, reserved atomically here; the edge
    -- function then bumps tokens only (p_requests => 0) for a message this reserve already counted
    insert into ai_usage_daily(organization_id, day, requests)
    values (v_branch.organization_id, v_day, 1)
    on conflict (organization_id, day) do update
      set requests = ai_usage_daily.requests + 1
      where ai_usage_daily.requests < s.daily_request_limit
    returning requests into v_hotel;
    if v_hotel is null then v_reject := 'hotel_limit'; raise exception 'guest_reserve_reject' using errcode = 'P0001'; end if;
  exception when raise_exception then
    -- the earlier counters rolled back with the subtransaction; report the cap that refused
    select u.admitted into v_session from ai_guest_session_usage u where u.conversation_id = p_conversation;
    return jsonb_build_object('status', v_reject, 'session_used', coalesce(v_session, 0));
  end;

  return jsonb_build_object('status', 'ok', 'session_used', v_session,
                            'device_used', v_device, 'branch_used', v_branch_used, 'hotel_used', v_hotel);
end $$;
revoke all on function fn_ai_guest_reserve(uuid, uuid, text, boolean) from public, anon, authenticated;
grant execute on function fn_ai_guest_reserve(uuid, uuid, text, boolean) to service_role;

-- the owner tunes the three new limits where the other AI limits already live
create or replace function fn_admin_update_ai_settings(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_fallbacks text[]; v_previous text[];
begin
  perform fn_require_cap('security');
  if p ? 'fallback_models' then
    if jsonb_typeof(p->'fallback_models') <> 'array' then raise exception 'VALIDATION: fallback_models must be a list'; end if;
    select coalesce(array_agg(m order by i), '{}') into v_fallbacks
    from (select lower(btrim(e.v)) as m, min(e.i) as i
          from jsonb_array_elements_text(p->'fallback_models') with ordinality as e(v, i)
          where btrim(e.v) <> ''
          group by 1) s;
    if cardinality(v_fallbacks) > 3 then raise exception 'VALIDATION: at most 3 fallback models'; end if;
    if exists (select 1 from unnest(v_fallbacks) m where m !~ '^[a-z0-9][a-z0-9.-]{0,62}$') then
      raise exception 'VALIDATION: fallback_models must be model ids (a-z 0-9 . -)';
    end if;
  end if;
  insert into ai_settings(organization_id) values (fn_user_org_id()) on conflict do nothing;
  select fallback_models into v_previous from ai_settings where organization_id = fn_user_org_id();
  begin
    update ai_settings set
      enabled = coalesce((p->>'enabled')::boolean, enabled),
      provider = coalesce(p->>'provider', provider),
      model = coalesce(nullif(trim(p->>'model'),''), model),
      fallback_models = coalesce(v_fallbacks, fallback_models),
      temperature = coalesce((p->>'temperature')::numeric, temperature),
      max_output_tokens = coalesce((p->>'max_output_tokens')::int, max_output_tokens),
      timeout_ms = coalesce((p->>'timeout_ms')::int, timeout_ms),
      daily_request_limit = coalesce((p->>'daily_request_limit')::int, daily_request_limit),
      daily_token_budget = coalesce((p->>'daily_token_budget')::int, daily_token_budget),
      per_session_message_limit = coalesce((p->>'per_session_message_limit')::int, per_session_message_limit),
      strict_scope = coalesce((p->>'strict_scope')::boolean, strict_scope),
      extra_instructions = coalesce(p->>'extra_instructions', extra_instructions),
      ops_enabled = coalesce((p->>'ops_enabled')::boolean, ops_enabled),
      ops_daily_request_limit = coalesce((p->>'ops_daily_request_limit')::int, ops_daily_request_limit),
      briefing_with_insights = coalesce((p->>'briefing_with_insights')::boolean, briefing_with_insights),
      guard_repeat_limit = coalesce((p->>'guard_repeat_limit')::int, guard_repeat_limit),
      guard_burst_messages = coalesce((p->>'guard_burst_messages')::int, guard_burst_messages),
      guard_burst_minutes = coalesce((p->>'guard_burst_minutes')::int, guard_burst_minutes),
      guard_conversation_tokens = coalesce((p->>'guard_conversation_tokens')::int, guard_conversation_tokens),
      guest_otp_after_messages = coalesce((p->>'guest_otp_after_messages')::int, guest_otp_after_messages),
      guest_device_daily_message_limit = coalesce((p->>'guest_device_daily_message_limit')::int, guest_device_daily_message_limit),
      guest_branch_daily_message_limit = coalesce((p->>'guest_branch_daily_message_limit')::int, guest_branch_daily_message_limit),
      updated_by = fn_staff_id(), updated_at = now()
    where organization_id = fn_user_org_id();
  exception when check_violation then
    raise exception 'VALIDATION: ai_guard';
  end;
  perform fn_audit(fn_user_org_id(), null, fn_staff_id(), 'ai_settings_updated', 'ai_settings', fn_user_org_id(),
    (p - 'extra_instructions' - 'fallback_models')
    || case when v_fallbacks is null then '{}'::jsonb
            else jsonb_build_object('fallback_models', to_jsonb(v_fallbacks), 'previous_fallback_models', to_jsonb(v_previous)) end);
  return jsonb_build_object('ok', true);
end $$;
grant execute on function fn_admin_update_ai_settings(jsonb) to authenticated;
