-- 0097: editable hotel-scoped guest AI and OTP limits. Owner only, validated and audited.
alter table ai_settings add column if not exists guest_otp_device_hourly_limit int not null default 3 check (guest_otp_device_hourly_limit between 1 and 100);
alter table ai_settings add column if not exists guest_otp_phone_hourly_limit int not null default 6 check (guest_otp_phone_hourly_limit between 1 and 200);
alter table ai_settings add column if not exists guest_otp_cooldown_seconds int not null default 60 check (guest_otp_cooldown_seconds between 10 and 3600);

create or replace function fn_admin_update_ai_settings(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_fallbacks text[]; v_previous text[];
begin
  perform fn_require_role('owner');
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
      guest_otp_device_hourly_limit = coalesce((p->>'guest_otp_device_hourly_limit')::int, guest_otp_device_hourly_limit),
      guest_otp_phone_hourly_limit = coalesce((p->>'guest_otp_phone_hourly_limit')::int, guest_otp_phone_hourly_limit),
      guest_otp_cooldown_seconds = coalesce((p->>'guest_otp_cooldown_seconds')::int, guest_otp_cooldown_seconds),
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

CREATE OR REPLACE FUNCTION public.fn_guest_phone_start(p_phone text, p_fingerprint text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v_org uuid:=fn_guest_org_id(); v_phone text := fn_normalize_phone(p_phone); v_code text; v_id uuid; v_branch uuid;
        c_device_sends int;                      -- sends per device per phone per hour
        c_phone_sends int;                       -- total sends per phone per hour (flood bound)
        c_cooldown interval; -- the pause between code messages
        c_attempts constant int := 20;                         -- attempts per device per hour (unchanged)
begin
  if v_org is null or v_phone is null then return jsonb_build_object('status', 'invalid'); end if;
  insert into ai_settings(organization_id) values (v_org) on conflict do nothing;
  select guest_otp_device_hourly_limit, guest_otp_phone_hourly_limit, make_interval(secs => guest_otp_cooldown_seconds)
    into c_device_sends, c_phone_sends, c_cooldown from ai_settings where organization_id=v_org;
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

