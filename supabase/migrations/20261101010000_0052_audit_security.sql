-- 0052 — the security findings of the 31 October review, as the owner decided them (1 November 2026).
--
-- SEC-01 (critical): a supervisor or a manager could read every guest's link token (registration_sessions, and
--   conversations.guest_token) in every branch, then open the guest's door code with it — logged as seen by the guest.
--   Owner's decision «تقييد بالفرع + كشف مسجّل»:
--     * registration_sessions: read only for the reservation's own branch, and never its token (column grant);
--     * conversations: staff read every column except guest_token; «متحقق» comes from guest_verified;
--     * fn_guest_access_code called with a staff session follows fn_keybox_reveal's rules (capability keybox.code, the
--       branch, the guest in house) and is audited under that staff member; it never marks the code as received.
-- PERM-01/02, SEC-06 (owner's decision «المال فقط»): money never reaches a role the matrix does not let see it —
--   the day summary (finance block, unpaid arrivals, departures with a balance), the units board (balance due) and the
--   old assistant search (balance, deposit, payment status) return them only when fn_sees_money().
-- SEC-02 (owner's decision: no fixed limits per address; a guard on the conversation's rhythm): the same question
--   repeated, a burst of messages, or a conversation that used far more tokens than a normal one stops the AI on that
--   conversation, hands it to the supervisor with one ticket, and is recorded. The four numbers are AI settings.
-- SEC-05 (owner's decision «تدوير وتنبيه فقط»): when a staff member leaves a branch (deactivated, or the branch
--   removed from them) the branch's reception-computer key is marked «يجب تغييره» and the owner gets a review item;
--   a new key clears it. A burst of new WhatsApp contacts in one hour (a number the owner sets) raises a review item.

-- ---------------------------------------------------------------------------------------------- SEC-01 tokens
alter policy "staff_regsession_select" on registration_sessions
  using (fn_has_role('owner','manager','supervisor') and exists (
    select 1 from reservations r where r.id = registration_sessions.reservation_id and r.branch_id in (select fn_user_branch_ids())));
revoke select on registration_sessions from authenticated;
grant select (id, reservation_id, expires_at, used_at, created_at) on registration_sessions to authenticated;

alter table conversations add column if not exists guest_verified boolean generated always as (guest_token is not null) stored;
revoke select, update on conversations from authenticated;
grant select (id, reservation_id, channel, status, created_at, branch_id, guest_verified, client_fingerprint, last_message_at,
              handed_off_at, handoff_reason, wa_contact, wa_chat_id, wa_menu, human_active_until) on conversations to authenticated;

create or replace function fn_guest_access_code(p_token text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  rid uuid := fn_token_reservation(p_token);
  r reservations%rowtype; kb keyboxes%rowtype; ev record; v_code text; v_staff uuid := fn_staff_id();
begin
  select * into r from reservations where id = rid;
  -- a staff session on the guest's page: the same rules as «عرض الرمز» (fn_keybox_reveal), audited under that person
  if v_staff is not null then
    perform fn_require_cap('keybox.code');
    perform fn_require_branch(r.branch_id);
    if r.room_id is not null and fn_room_guest_in_house(r.room_id) and not fn_has_role('owner','manager','supervisor') then
      raise exception 'GUEST_IN_HOUSE' using errcode = '42501';
    end if;
  end if;
  select * into ev from fn_evaluate_access(rid, false);
  if r.access_status not in ('delivered','acknowledged') or not ev.allowed then
    return jsonb_build_object('allowed', false, 'reasons', coalesce(ev.reasons, array['لم يتم تسليم الرمز بعد']));
  end if;
  select * into kb from keyboxes where room_id = r.room_id limit 1;
  if kb.last_reservation_id is distinct from r.id then
    return jsonb_build_object('allowed', false, 'reasons', array['الرمز غير مخصص لهذا الحجز']);
  end if;
  v_code := pgp_sym_decrypt(kb.code_encrypted, fn_secret('keybox_key'));
  if v_staff is not null then
    perform fn_audit_change(r.branch_id, 'keybox.code_viewed', 'room', r.room_id, null,
      jsonb_build_object('code_version', kb.code_version, 'code_status', kb.code_status, 'via', 'guest_page', 'reservation_id', r.id), null);
  else
    update reservations set access_status = 'acknowledged', updated_at = now() where id = rid and access_status = 'delivered';
    update access_delivery_events set acknowledged = true where reservation_id = rid and acknowledged = false;
    perform fn_audit(r.organization_id, r.branch_id, null, 'guest_viewed_code', 'reservation', rid, jsonb_build_object('room_id', r.room_id, 'code_version', kb.code_version));
  end if;
  return jsonb_build_object('allowed', true, 'code', v_code, 'room_number', (select room_number from rooms where id = r.room_id));
end $$;
grant execute on function fn_guest_access_code(text) to anon, authenticated;

-- ---------------------------------------------------------------------------------------------- money only
-- the summary itself moves to fn_ops_daily_summary_core (no one calls it directly); _at strips money for a role without it
do $m$ begin
  if not exists (select 1 from pg_proc where proname = 'fn_ops_daily_summary_core' and pronamespace = 'public'::regnamespace) then
    alter function fn_ops_daily_summary_at(uuid, date) rename to fn_ops_daily_summary_core;
  end if;
end $m$;
revoke all on function fn_ops_daily_summary_core(uuid, date) from public, anon, authenticated;

create or replace function fn_ops_daily_summary_at(p_branch uuid, p_date date) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare s jsonb := fn_ops_daily_summary_core(p_branch, p_date);
begin
  if s is null or fn_sees_money() then return s; end if;
  return (s - 'finance')
    || jsonb_build_object('arrivals', (s->'arrivals') - 'unpaid', 'departures', (s->'departures') - 'with_balance', 'money_hidden', true);
end $$;
revoke all on function fn_ops_daily_summary_at(uuid, date) from public, anon;
grant execute on function fn_ops_daily_summary_at(uuid, date) to authenticated;

create or replace function fn_ops_units_board(p_branch uuid) returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'room_id', r.id, 'room_number', r.room_number, 'category', c.name_ar, 'block', b.name, 'floor', f.name,
    'is_active', r.is_active, 'status', r.status, 'cleanliness', r.cleanliness,
    'open_tasks', (select count(*) from housekeeping_tasks h where h.room_id = r.id and h.status in ('pending','in_progress')),
    'open_maintenance', (select count(*) from maintenance_tickets m where m.room_id = r.id and m.status <> 'resolved'),
    'keybox_ready', exists (select 1 from keyboxes k where k.room_id = r.id and k.code_status = 'active' and k.field_tested),
    'current', (select jsonb_build_object('reservation_id', rs.id, 'internal_ref', rs.internal_ref, 'status', rs.status, 'check_in', rs.check_in, 'check_out', rs.check_out,
                                          'guest', left(coalesce((select full_name from reservation_guests g where g.reservation_id = rs.id and g.is_primary limit 1), '—'), 40),
                                          'balance_due', case when m.sees then rs.balance_due_halalas end)
                from reservation_allocations a join reservations rs on rs.id = a.reservation_id
                where a.room_id = r.id and a.status = 'active' and rs.status in ('confirmed','checked_in','pending_verification')
                  -- a resident stays "current" on departure day and while overstaying, until checkout closes the allocation
                  and a.from_date <= fn_branch_today(p_branch) and (fn_branch_today(p_branch) < a.to_date or rs.status = 'checked_in')
                order by rs.status = 'checked_in' desc limit 1),
    'next', (select jsonb_build_object('internal_ref', rs.internal_ref, 'check_in', rs.check_in)
             from reservation_allocations a join reservations rs on rs.id = a.reservation_id
             where a.room_id = r.id and a.status = 'active' and rs.status in ('confirmed','pending_verification') and a.from_date > fn_branch_today(p_branch) order by a.from_date limit 1)
  ) order by c.sort_order, r.room_number), '[]'::jsonb)
  from rooms r join room_categories c on c.id = r.category_id left join blocks b on b.id = r.block_id left join floors f on f.id = r.floor_id
  cross join (select fn_sees_money() as sees) m
  where r.branch_id = p_branch and r.branch_id in (select fn_user_branch_ids()) and r.archived_at is null;
$$;

create or replace function fn_ai_ops_find_reservation(p_branch uuid, p_query text) returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(jsonb_agg(jsonb_build_object('reservation_id', r.id, 'ref', r.internal_ref, 'external_ref', r.external_ref, 'guest', (select full_name from reservation_guests g where g.reservation_id = r.id and g.is_primary limit 1),
           'status', r.status, 'check_in', r.check_in, 'check_out', r.check_out, 'room', (select room_number from rooms where id = r.room_id), 'category_id', r.room_category_id,
           'balance_due', case when m.sees then r.balance_due_halalas end, 'deposit_balance', case when m.sees then r.deposit_balance_halalas end,
           'payment_status', case when m.sees then r.payment_status end, 'identity_status', r.identity_status, 'version', r.version) order by r.check_in desc), '[]'::jsonb)
  from (select * from reservations r where r.branch_id = p_branch and r.branch_id in (select fn_user_branch_ids())
          and (r.internal_ref ilike '%' || p_query || '%' or coalesce(r.external_ref,'') ilike '%' || p_query || '%'
               or exists (select 1 from reservation_guests g where g.reservation_id = r.id and g.full_name ilike '%' || p_query || '%')
               or exists (select 1 from rooms rm where rm.id = r.room_id and rm.room_number = p_query))
        order by r.check_in desc limit 8) r
  cross join (select fn_sees_money() as sees) m;
$$;

-- ---------------------------------------------------------------------------------------------- SEC-02 the AI guard
alter table ai_settings add column if not exists guard_repeat_limit int not null default 3;
alter table ai_settings add column if not exists guard_burst_messages int not null default 15;
alter table ai_settings add column if not exists guard_burst_minutes int not null default 10;
alter table ai_settings add column if not exists guard_conversation_tokens int not null default 40000;
do $g$ begin
  if not exists (select 1 from pg_constraint where conname = 'ai_settings_guard_valid') then
    alter table ai_settings add constraint ai_settings_guard_valid check (
      guard_repeat_limit between 2 and 20 and guard_burst_messages between 3 and 200
      and guard_burst_minutes between 1 and 120 and guard_conversation_tokens between 1000 and 1000000);
  end if;
end $g$;

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

-- called by ai-reception (service role) after the guest's message is stored: stop or go on
create or replace function fn_ai_conversation_guard(p_conversation uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  c conversations%rowtype; s ai_settings%rowtype; v_reason text; v_kind text;
  v_repeat int; v_burst int; v_tokens bigint;
begin
  select * into c from conversations where id = p_conversation for update;
  if not found then return jsonb_build_object('stop', false); end if;
  if c.status = 'handed_off' then return jsonb_build_object('stop', true, 'already', true); end if;
  select * into s from ai_settings where organization_id = coalesce((select organization_id from branches where id = c.branch_id), fn_user_org_id());
  if not found then
    s.guard_repeat_limit := 3; s.guard_burst_messages := 15; s.guard_burst_minutes := 10; s.guard_conversation_tokens := 40000;
  end if;
  -- the same message, the guest's last few in a row
  select count(*) into v_repeat from (
    select lower(regexp_replace(btrim(content), '\s+', ' ', 'g')) as t from conversation_messages
    where conversation_id = c.id and sender = 'guest' order by created_at desc limit s.guard_repeat_limit) x
  where x.t = (select lower(regexp_replace(btrim(content), '\s+', ' ', 'g')) from conversation_messages
               where conversation_id = c.id and sender = 'guest' order by created_at desc limit 1);
  select count(*) into v_burst from conversation_messages
  where conversation_id = c.id and sender = 'guest' and created_at > now() - make_interval(mins => s.guard_burst_minutes);
  select coalesce(sum(coalesce((meta->'tokens'->>'in')::bigint, 0) + coalesce((meta->'tokens'->>'out')::bigint, 0)), 0) into v_tokens
  from conversation_messages where conversation_id = c.id and sender = 'assistant';

  if v_repeat >= s.guard_repeat_limit then v_kind := 'repeat'; v_reason := 'رسالة متكررة ' || v_repeat || ' مرات متتالية';
  elsif v_burst > s.guard_burst_messages then v_kind := 'burst'; v_reason := v_burst || ' رسالة خلال ' || s.guard_burst_minutes || ' دقيقة';
  elsif v_tokens > s.guard_conversation_tokens then v_kind := 'tokens'; v_reason := 'استهلاك غير معتاد للمحادثة (' || v_tokens || ' توكن)';
  else return jsonb_build_object('stop', false); end if;

  update conversations set status = 'handed_off', handed_off_at = now(), handoff_reason = 'أوقف الذكاء الاصطناعي: ' || v_reason where id = c.id;
  if not exists (select 1 from human_handoff_tickets where conversation_id = c.id and status = 'open') then
    insert into human_handoff_tickets(organization_id, branch_id, conversation_id, kind, details)
    values ((select organization_id from branches where id = c.branch_id), c.branch_id, c.id, 'assistance',
            jsonb_build_object('reason', 'أوقف الذكاء الاصطناعي على المحادثة: ' || v_reason, 'guard', v_kind));
    insert into notifications(branch_id, audience, title, body, link)
    values (c.branch_id, 'supervisor', 'أوقف المساعد محادثة', v_reason, '/staff/inbox');
  end if;
  insert into ai_guardrail_events(conversation_id, stage, rule, detail) values (c.id, 'budget', 'anomaly:' || v_kind, v_reason);
  return jsonb_build_object('stop', true, 'kind', v_kind, 'reason', v_reason);
end $$;
revoke all on function fn_ai_conversation_guard(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------- SEC-05 the bridge key
alter table branch_whatsapp_channels add column if not exists bridge_key_rotation_due_at timestamptz;
alter table branch_whatsapp_channels add column if not exists bridge_key_rotation_reason text;
alter table branch_whatsapp_channels add column if not exists alert_new_contacts_per_hour int not null default 30;
do $w$ begin
  if not exists (select 1 from pg_constraint where conname = 'whatsapp_alert_new_contacts') then
    alter table branch_whatsapp_channels add constraint whatsapp_alert_new_contacts check (alert_new_contacts_per_hour between 5 and 1000);
  end if;
end $w$;

-- a new key (or no key) clears «يجب تغييره»
create or replace function fn_trg_bridge_key_rotated() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.bridge_key_hash is distinct from old.bridge_key_hash then
    new.bridge_key_rotation_due_at := null; new.bridge_key_rotation_reason := null;
  end if;
  return new;
end $$;
create or replace trigger trg_bridge_key_rotated before update of bridge_key_hash on branch_whatsapp_channels
  for each row execute function fn_trg_bridge_key_rotated();

create or replace function fn_bridge_key_rotation_due(p_branch uuid, p_staff uuid, p_why text) returns void
language plpgsql security definer set search_path = public as $$
declare c branch_whatsapp_channels%rowtype; v_name text;
begin
  select * into c from branch_whatsapp_channels where branch_id = p_branch and bridge_key_hash is not null for update;
  if not found then return; end if;
  select full_name into v_name from staff_profiles where id = p_staff;
  update branch_whatsapp_channels set bridge_key_rotation_due_at = now(),
    bridge_key_rotation_reason = coalesce(v_name, 'موظف') || ' — ' || p_why where branch_id = p_branch;
  perform fn_add_review_item(p_branch, 'security:bridge_key_rotation', 'branch', p_branch, null,
    'غيّر مفتاح كمبيوتر الاستقبال: ' || coalesce(v_name, 'موظف') || ' ' || p_why, null,
    jsonb_build_object('staff_id', p_staff, 'key_last4', c.bridge_key_last4));
end $$;
revoke all on function fn_bridge_key_rotation_due(uuid, uuid, text) from public, anon, authenticated;

create or replace function fn_trg_staff_left_branch() returns trigger
language plpgsql security definer set search_path = public as $$
declare b uuid;
begin
  if tg_table_name = 'staff_profiles' then
    if coalesce(old.is_active, true) and new.is_active is false then
      for b in select branch_id from branch_memberships where staff_id = new.id and removed_at is null loop
        perform fn_bridge_key_rotation_due(b, new.id, 'أُوقف حسابه');
      end loop;
    end if;
  elsif old.removed_at is null and new.removed_at is not null then
    perform fn_bridge_key_rotation_due(new.branch_id, new.staff_id, 'أُزيل من الفرع');
  end if;
  return new;
end $$;
create or replace trigger trg_staff_left_branch after update of is_active on staff_profiles
  for each row execute function fn_trg_staff_left_branch();
-- a membership is retired by its removed_at (never removed as a row)
create or replace trigger trg_membership_left_branch after update of removed_at on branch_memberships
  for each row execute function fn_trg_staff_left_branch();

-- an unusual number of new WhatsApp contacts in an hour: one review item per hour at most
create or replace function fn_trg_whatsapp_contact_burst() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_limit int; v_n int;
begin
  if new.channel <> 'whatsapp' or new.branch_id is null then return new; end if;
  select alert_new_contacts_per_hour into v_limit from branch_whatsapp_channels where branch_id = new.branch_id;
  if v_limit is null then return new; end if;
  select count(*) into v_n from conversations where branch_id = new.branch_id and channel = 'whatsapp' and created_at > now() - interval '1 hour';
  if v_n > v_limit and not exists (select 1 from review_items where branch_id = new.branch_id and kind = 'security:whatsapp_burst'
                                     and created_at > now() - interval '1 hour') then
    perform fn_add_review_item(new.branch_id, 'security:whatsapp_burst', 'branch', new.branch_id, null,
      v_n || ' محادثة واتساب جديدة خلال ساعة (الحد ' || v_limit || ')', null, jsonb_build_object('count', v_n, 'limit', v_limit));
  end if;
  return new;
end $$;
create or replace trigger trg_whatsapp_contact_burst after insert on conversations
  for each row execute function fn_trg_whatsapp_contact_burst();

-- the owner's view of the two: whether the key must change and the burst number (and setting it)
create or replace function fn_admin_whatsapp_security(p_branch uuid, p jsonb default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c branch_whatsapp_channels%rowtype; v int;
begin
  perform fn_require_cap('security');
  perform fn_require_branch(p_branch);
  select * into c from branch_whatsapp_channels where branch_id = p_branch for update;
  if not found then return jsonb_build_object('configured', false); end if;
  if p is not null and p ? 'alert_new_contacts_per_hour' then
    if coalesce(p->>'alert_new_contacts_per_hour', '') !~ '^[0-9]{1,4}$' then raise exception 'VALIDATION: alert_new_contacts_per_hour'; end if;
    v := (p->>'alert_new_contacts_per_hour')::int;
    if v < 5 or v > 1000 then raise exception 'VALIDATION: alert_new_contacts_per_hour'; end if;
    if v <> c.alert_new_contacts_per_hour then
      update branch_whatsapp_channels set alert_new_contacts_per_hour = v where branch_id = p_branch;
      perform fn_audit_change(p_branch, 'whatsapp_channel_updated', 'branch', p_branch,
        jsonb_build_object('alert_new_contacts_per_hour', c.alert_new_contacts_per_hour), jsonb_build_object('alert_new_contacts_per_hour', v), null);
      c.alert_new_contacts_per_hour := v;
    end if;
  end if;
  return jsonb_build_object('configured', true, 'rotation_due_at', c.bridge_key_rotation_due_at, 'rotation_reason', c.bridge_key_rotation_reason,
    'alert_new_contacts_per_hour', c.alert_new_contacts_per_hour, 'has_bridge_key', c.bridge_key_hash is not null);
end $$;
revoke all on function fn_admin_whatsapp_security(uuid, jsonb) from public, anon;
grant execute on function fn_admin_whatsapp_security(uuid, jsonb) to authenticated;

-- trigger functions are never called through the API
revoke all on function fn_trg_bridge_key_rotated() from public, anon, authenticated;
revoke all on function fn_trg_staff_left_branch() from public, anon, authenticated;
revoke all on function fn_trg_whatsapp_contact_burst() from public, anon, authenticated;
