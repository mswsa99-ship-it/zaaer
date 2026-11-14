-- 0070 — the guest journey after the stay (plan «خطة تصحيح ملاحظات التجربة», stage م٤): W3 the check-out options and
-- the extension, W4 the departure and the deposit's return, W5 the review, W6 the alert rules. Every number of the
-- journey is a setting of the branch (the owner's), and every message to the guest goes out on the branch's WhatsApp
-- (the reception computer) from the server itself, whenever that computer asks for its messages:
--   · at 10:00 on the day of departure (a setting) the guest is offered: leaving between 12 and 1 (free), one night
--     more (when the room is free that night), or hours after 1 PM at 5 riyals each, a part of an hour counted whole,
--     with no limit but the room's next guest and the hour of cleaning before them; a night or hours are held for the
--     guest while they pay (30 minutes, a setting) and given back when not paid in time (before 1 PM);
--   · the guest reads the departure instructions, then says «غادرت وسلّمت المفتاح»: the stay waits for the reception's
--     check (the inspection, then the check-out); from the confirmed check-out the deposit is returned within 3 hours
--     (a setting) — by transfer with its number or in cash from the branch's box — and the guest's receipt goes out
--     only once the return is recorded;
--   · 60 minutes after the confirmed check-out (a setting) one invitation to review: an overall mark out of 10 asked
--     on its own, and six aspects; a mark under 9 (a setting) alerts the owner at once; the reception answers it;
--   · each event of the journey has its rule: who is told (the branch's responsible — مأمون or مهيدي — its fallback —
--     the administration — or a role), by which channel (in the system, WhatsApp, or both: WhatsApp in place of SMS),
--     after how long, and to whom it climbs when nobody acts.

-- ---------------------------------------------------------------------------------------------------------------
-- 1. The journey's settings, per branch (every number above), and the address of the guests' pages
-- ---------------------------------------------------------------------------------------------------------------
create table if not exists branch_journey_settings (
  branch_id uuid primary key references branches(id),
  organization_id uuid not null references organizations(id),
  journey_enabled boolean not null default true,              -- the journey's messages go out on the branch's WhatsApp
  checkout_message_time time not null default '10:00',
  free_checkout_until time not null default '13:00',          -- leaving by then costs nothing (12–1)
  late_hour_price_halalas bigint not null default 500,
  cleaning_buffer_minutes int not null default 60,
  hold_minutes int not null default 30,
  checkout_instructions text,
  deposit_refund_hours int not null default 3,
  review_delay_minutes int not null default 60,
  review_alert_below smallint not null default 9,
  responsible_staff_id uuid references staff_profiles(id),    -- مأمون or مهيدي: the branch's responsible
  fallback_staff_id uuid references staff_profiles(id),       -- the administration: when the responsible does not act
  version int not null default 1,
  updated_by uuid references staff_profiles(id),
  updated_at timestamptz not null default now(),
  constraint journey_late_price_valid check (late_hour_price_halalas between 0 and 1000000),
  constraint journey_buffer_valid check (cleaning_buffer_minutes between 0 and 240),
  constraint journey_hold_valid check (hold_minutes between 5 and 240),
  constraint journey_instructions_valid check (checkout_instructions is null or char_length(checkout_instructions) <= 1500),
  constraint journey_refund_hours_valid check (deposit_refund_hours between 1 and 72),
  constraint journey_review_delay_valid check (review_delay_minutes between 10 and 1440),
  constraint journey_review_alert_valid check (review_alert_below between 1 and 10),
  constraint journey_free_until_valid check (free_checkout_until > checkout_message_time)
);
insert into branch_journey_settings(branch_id, organization_id) select id, organization_id from branches on conflict do nothing;

create or replace function fn_trg_branch_journey_settings() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into branch_journey_settings(branch_id, organization_id) values (new.id, new.organization_id) on conflict do nothing;
  return new;
end $$;
revoke all on function fn_trg_branch_journey_settings() from public, anon, authenticated;
create or replace trigger trg_branch_journey_settings after insert on branches for each row execute function fn_trg_branch_journey_settings();

-- the address of the guests' pages, for the links the server writes itself (a review's page)
alter table organizations add column if not exists guest_site_url text;
update organizations set guest_site_url = 'https://mswsa99-ship-it.github.io/zaaer' where guest_site_url is null;

-- what the guest chose for the day of departure, and when they said they had left
alter table reservations add column if not exists checkout_choice text;
alter table reservations add column if not exists checkout_choice_at timestamptz;
alter table reservations add column if not exists guest_departed_at timestamptz;
alter table reservations add column if not exists guest_departed_via text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'reservations_checkout_choice_valid') then
    alter table reservations add constraint reservations_checkout_choice_valid check (checkout_choice is null or checkout_choice in ('on_time'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'reservations_departed_via_valid') then
    alter table reservations add constraint reservations_departed_via_valid check (guest_departed_via is null or guest_departed_via in ('whatsapp', 'page'));
  end if;
end $$;
-- read by the staff of the stay's branch, as every column of a stay that is not money (0011, 0033, 0035)
grant select (checkout_choice, checkout_choice_at, guest_departed_at, guest_departed_via) on reservations to authenticated;

-- the branch-local clock
create or replace function fn_journey_local_time(p_branch uuid) returns time
language sql stable security definer set search_path = public as $$
  select (now() at time zone coalesce((select timezone from branches where id = p_branch), 'Asia/Riyadh'))::time
$$;
revoke all on function fn_journey_local_time(uuid) from public, anon, authenticated;

create or replace function fn_ar_hours(n integer) returns text language sql immutable set search_path = public as $$
  select case when n = 1 then 'ساعة واحدة' when n = 2 then 'ساعتان' when n between 3 and 10 then n || ' ساعات' else n || ' ساعة' end
$$;
revoke all on function fn_ar_hours(integer) from public, anon;
grant execute on function fn_ar_hours(integer) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------------------------
-- 2. W6 — the alert rules: for each event who is told, by which channel, after how long, and to whom it climbs
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_alert_event_label(p_event text) returns text language sql immutable set search_path = public as $$
  select case p_event
    when 'guest_departed' then 'غادر النزيل — بانتظار التحقق'
    when 'deposit_overdue' then 'تأخر رد التأمين عن مهلته'
    when 'review_low' then 'تقييم أقل من الحد'
    when 'extension_requested' then 'طلب تمديد أو خروج متأخر'
    when 'extension_unpaid' then 'تمديد لم يُدفع في مهلته'
    when 'product_order' then 'طلب منتجات بانتظار الدفع'
    when 'guest_handoff' then 'طلب النزيل موظفًا'
    when 'message_failed' then 'تعذّر إرسال رسالة للنزيل'
  end
$$;
revoke all on function fn_alert_event_label(text) from public, anon;
grant execute on function fn_alert_event_label(text) to authenticated, service_role;

create table if not exists alert_rules (
  organization_id uuid not null references organizations(id),
  event text not null,
  enabled boolean not null default true,
  recipients text[] not null default '{responsible}',
  channel text not null default 'both',
  delay_minutes int not null default 0,
  escalate_after_minutes int,                                 -- null: it does not climb
  escalate_to text not null default 'fallback',
  version int not null default 1,
  updated_by uuid references staff_profiles(id),
  updated_at timestamptz not null default now(),
  primary key (organization_id, event),
  constraint alert_rule_event_valid check (fn_alert_event_label(event) is not null),
  constraint alert_rule_recipients_valid check (cardinality(recipients) between 1 and 5 and recipients <@ array['responsible', 'fallback', 'owner', 'manager', 'supervisor']),
  constraint alert_rule_channel_valid check (channel in ('app', 'whatsapp', 'both')),
  constraint alert_rule_delay_valid check (delay_minutes between 0 and 1440),
  constraint alert_rule_escalation_valid check (escalate_after_minutes is null or escalate_after_minutes between 1 and 1440),
  constraint alert_rule_escalate_to_valid check (escalate_to in ('fallback', 'owner'))
);

-- the defaults: the branch's responsible first, the administration when nobody acts
create or replace function fn_alert_rules_seed(p_org uuid) returns void
language sql security definer set search_path = public as $$
  insert into alert_rules(organization_id, event, recipients, channel, delay_minutes, escalate_after_minutes, escalate_to)
  select p_org, e, rc::text[], ch, 0, esc, 'fallback' from (values
    ('guest_departed', '{responsible}', 'both', 30),
    ('deposit_overdue', '{responsible}', 'both', 30),
    ('review_low', '{owner}', 'both', null),
    ('extension_requested', '{responsible}', 'both', 15),
    ('extension_unpaid', '{responsible}', 'app', 30),
    ('product_order', '{responsible}', 'app', 30),
    ('guest_handoff', '{responsible}', 'both', 10),
    ('message_failed', '{responsible}', 'app', null)) d(e, rc, ch, esc)
  on conflict do nothing
$$;
revoke all on function fn_alert_rules_seed(uuid) from public, anon, authenticated;
select fn_alert_rules_seed(id) from organizations;
create or replace function fn_trg_org_alert_rules() returns trigger
language plpgsql security definer set search_path = public as $$
begin perform fn_alert_rules_seed(new.id); return new; end $$;
revoke all on function fn_trg_org_alert_rules() from public, anon, authenticated;
create or replace trigger trg_org_alert_rules after insert on organizations for each row execute function fn_trg_org_alert_rules();

create table if not exists alert_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  branch_id uuid not null,
  event text not null,
  ref_key text not null,                                      -- the thing it is about (once per event and thing)
  reservation_id uuid,
  title text not null,
  body text,
  link text,
  created_at timestamptz not null default now(),
  notify_at timestamptz not null default now(),
  notified_at timestamptz,
  notified_to jsonb,
  escalated_at timestamptz,
  escalated_to jsonb,
  resolved_at timestamptz,
  resolved_by uuid references staff_profiles(id),
  resolved_how text,
  constraint alert_event_valid check (fn_alert_event_label(event) is not null),
  constraint alert_event_resolved_how_valid check (resolved_how is null or resolved_how in ('auto', 'staff'))
);
create unique index if not exists uniq_alert_event on alert_events(event, ref_key);
create index if not exists idx_alert_events_open on alert_events(branch_id, created_at desc) where resolved_at is null;

-- the people of a branch a rule names: its responsible (or its supervisors when none is chosen), its fallback (or the
-- owners), the owners, or a role among those working in the branch
create or replace function fn_alert_people(p_branch uuid, p_recipients text[])
returns table(staff_id uuid, full_name text, phone text, role text)
language sql stable security definer set search_path = public as $$
  with b as (select id, organization_id from branches where id = p_branch),
       s as (select * from branch_journey_settings where branch_id = p_branch),
       works as (select sp.* from staff_profiles sp, b
                  where sp.organization_id = b.organization_id and sp.is_active
                    and (sp.role = 'owner' or exists (select 1 from branch_memberships m where m.staff_id = sp.id and m.branch_id = b.id and m.removed_at is null))),
       chosen as (
         select w.id from works w where 'responsible' = any(p_recipients) and w.id = (select responsible_staff_id from s)
         union select w.id from works w where 'responsible' = any(p_recipients) and (select responsible_staff_id from s) is null and w.role = 'supervisor'
         union select sp.id from staff_profiles sp, b where 'fallback' = any(p_recipients) and sp.organization_id = b.organization_id and sp.is_active and sp.id = (select fallback_staff_id from s)
         union select w.id from works w where 'fallback' = any(p_recipients) and (select fallback_staff_id from s) is null and w.role = 'owner'
         union select w.id from works w where w.role::text = any(p_recipients) and w.role::text in ('owner', 'manager', 'supervisor'))
  select sp.id, sp.full_name, sp.phone, sp.role::text from staff_profiles sp where sp.id in (select id from chosen)
$$;
revoke all on function fn_alert_people(uuid, text[]) from public, anon, authenticated;

-- a WhatsApp message to a member of staff, on the branch's reception computer (a conversation of its own, kept closed
-- so it never mixes with the guests'): 'queued', 'no_phone' or 'channel_unavailable'
create or replace function fn_staff_whatsapp(p_branch uuid, p_phone text, p_text text) returns text
language plpgsql security definer set search_path = public as $$
declare v_phone text := fn_normalize_phone(p_phone); cid uuid; mid uuid;
begin
  if v_phone is null then return 'no_phone'; end if;
  if not exists (select 1 from branch_whatsapp_channels where branch_id = p_branch and mode = 'web_bridge' and enabled and bridge_key_hash is not null) then
    return 'channel_unavailable';
  end if;
  select id into cid from conversations where branch_id = p_branch and wa_contact = v_phone and status = 'closed' and handoff_reason = 'تنبيهات الموظفين'
   order by created_at desc limit 1;
  if cid is null then
    insert into conversations(branch_id, channel, status, wa_contact, wa_chat_id, last_message_at, handoff_reason)
    values (p_branch, 'whatsapp', 'closed', v_phone, v_phone || '@c.us', now(), 'تنبيهات الموظفين') returning id into cid;
  end if;
  insert into conversation_messages(conversation_id, sender, content, meta)
  values (cid, 'assistant', p_text, jsonb_build_object('mode', 'staff_alert', 'channel', 'whatsapp', 'delivery', 'queued')) returning id into mid;
  insert into whatsapp_outbox(branch_id, message_id) values (p_branch, mid);
  return 'queued';
end $$;
revoke all on function fn_staff_whatsapp(uuid, text, text) from public, anon, authenticated;

-- tells the people of an alert (or, climbing, those it climbs to) by the rule's channel; records who and how
create or replace function fn_alert_notify(p_alert uuid, p_escalation boolean) returns void
language plpgsql security definer set search_path = public as $$
declare a alert_events%rowtype; rl alert_rules%rowtype; who jsonb := '[]'::jsonb; p record; wa text; txt text;
begin
  select * into a from alert_events where id = p_alert for update;
  if not found or a.resolved_at is not null then return; end if;
  select * into rl from alert_rules where organization_id = a.organization_id and event = a.event;
  if not found then return; end if;
  txt := case when p_escalation then 'تصعيد — لم يُعالَج بعد: ' else '' end || a.title || coalesce(E'\n' || a.body, '');
  if rl.channel in ('app', 'both') then
    insert into notifications(branch_id, audience, title, body, link)
    values (a.branch_id, case when p_escalation or rl.recipients <@ array['owner'] then 'manager' else 'supervisor' end,
            case when p_escalation then 'تصعيد: ' else '' end || a.title, a.body, a.link);
  end if;
  for p in select * from fn_alert_people(a.branch_id, case when p_escalation then array[rl.escalate_to] else rl.recipients end) order by full_name loop
    wa := case when rl.channel in ('whatsapp', 'both') then fn_staff_whatsapp(a.branch_id, p.phone, '🔔 ' || txt) end;
    who := who || jsonb_build_array(jsonb_build_object('staff_id', p.staff_id, 'name', p.full_name, 'app', rl.channel in ('app', 'both'), 'whatsapp', wa));
  end loop;
  if p_escalation then
    update alert_events set escalated_at = now(), escalated_to = who where id = a.id;
  else
    update alert_events set notified_at = now(), notified_to = who where id = a.id;
  end if;
end $$;
revoke all on function fn_alert_notify(uuid, boolean) from public, anon, authenticated;

-- an event happened: once per event and thing, by its rule (nothing when the rule is off)
create or replace function fn_alert_raise(p_branch uuid, p_event text, p_ref text, p_title text, p_body text, p_link text, p_reservation uuid default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare rl alert_rules%rowtype; v_org uuid; v_id uuid;
begin
  select organization_id into v_org from branches where id = p_branch;
  if v_org is null then return null; end if;
  select * into rl from alert_rules where organization_id = v_org and event = p_event;
  if not found or not rl.enabled then return null; end if;
  insert into alert_events(organization_id, branch_id, event, ref_key, reservation_id, title, body, link, notify_at)
  values (v_org, p_branch, p_event, p_ref, p_reservation, left(p_title, 200), left(p_body, 1000), p_link, now() + make_interval(mins => rl.delay_minutes))
  on conflict (event, ref_key) do nothing
  returning id into v_id;
  if v_id is not null and rl.delay_minutes = 0 then perform fn_alert_notify(v_id, false); end if;
  return v_id;
end $$;
revoke all on function fn_alert_raise(uuid, text, text, text, text, text, uuid) from public, anon, authenticated;

-- the thing was dealt with: its alert is closed (and stops climbing)
create or replace function fn_alert_resolve(p_event text, p_ref text) returns void
language sql security definer set search_path = public as $$
  update alert_events set resolved_at = now(), resolved_how = 'auto' where event = p_event and ref_key = p_ref and resolved_at is null
$$;
revoke all on function fn_alert_resolve(text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 3. The journey's messages to the guest: on the branch's WhatsApp, each kind once per stay (and thing)
-- ---------------------------------------------------------------------------------------------------------------
-- the exact text to type, when it is not the stored copy (a link with its key is typed, never kept)
alter table whatsapp_outbox add column if not exists body text;

create table if not exists journey_messages (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  branch_id uuid not null,
  reservation_id uuid not null,                               -- no reference: the trial-data purge removes stays
  kind text not null,
  ref_key text not null default '',
  status text not null,
  reason text,
  conversation_id uuid,
  message_id uuid,
  created_at timestamptz not null default now(),
  constraint journey_message_kind_valid check (kind in ('checkout_options', 'extension_confirmed', 'extension_released', 'checkout_confirmed',
                                                         'deposit_refunded', 'review_invite', 'review_reply')),
  constraint journey_message_status_valid check (status in ('queued', 'skipped')),
  constraint journey_message_reason_valid check (reason is null or reason in ('journey_off', 'channel_unavailable', 'no_phone'))
);
create unique index if not exists uniq_journey_message on journey_messages(reservation_id, kind, ref_key);
create index if not exists idx_journey_messages_branch on journey_messages(branch_id, created_at desc);

create or replace function fn_journey_keycap(n int) returns text language sql immutable set search_path = public as $$
  select case when n between 0 and 9 then chr(48 + n) || chr(65039) || chr(8419) when n = 10 then chr(128287) else n || '.' end
$$;
revoke all on function fn_journey_keycap(int) from public, anon, authenticated;

-- a message and its numbered options, as the reception computer types them (_shared/wa_text.ts), and the menu the
-- guest's answer is read against (conversations.wa_menu)
create or replace function fn_journey_render(p_body text, p_options jsonb) returns jsonb
language sql stable set search_path = public as $$
  select case when p_options is null or jsonb_array_length(p_options) = 0 then jsonb_build_object('text', p_body, 'menu', null)
    else jsonb_build_object(
      'text', p_body || E'\n\n' || (select string_agg(fn_journey_keycap(o.n::int) || ' ' || (o.x->>'title'), E'\n' order by o.n) from jsonb_array_elements(p_options) with ordinality o(x, n))
              || E'\n\n' || 'أرسل رقم الخيار.',
      'menu', jsonb_build_object('at', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
                                 'options', (select jsonb_agg(jsonb_build_object('n', o.n, 'id', o.x->>'id', 'title', o.x->>'title') order by o.n)
                                               from jsonb_array_elements(p_options) with ordinality o(x, n)))) end
$$;
revoke all on function fn_journey_render(text, jsonb) from public, anon, authenticated;

-- the number the stay's guest is reached on (the main guest's, as WhatsApp writes it), or null
create or replace function fn_reservation_guest_phone(p_reservation uuid) returns text
language sql stable security definer set search_path = public as $$
  select fn_normalize_phone(coalesce(nullif(g.phone, ''), gp.phone))
  from reservation_guests g left join guest_profiles gp on gp.id = g.guest_profile_id
  where g.reservation_id = p_reservation and coalesce(nullif(g.phone, ''), gp.phone) is not null
  order by g.is_primary desc, g.created_at limit 1
$$;
revoke all on function fn_reservation_guest_phone(uuid) from public, anon, authenticated;

-- sends one message of the journey to the stay's guest: once per kind and thing. The conversation is the guest's
-- open one on the branch's number (or a new one), bound to the stay so the assistant and the options act on it.
-- p_typed: the text to type when it differs from the copy kept (a link with its key). Returns 'queued' or why not.
create or replace function fn_journey_send(p_reservation uuid, p_kind text, p_ref text, p_body text, p_options jsonb default null, p_typed text default null)
returns text
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; s branch_journey_settings%rowtype; v_phone text; why text; cid uuid; tok text; mid uuid; rendered jsonb; typed jsonb;
begin
  select * into r from reservations where id = p_reservation;
  if not found then return 'not_found'; end if;
  if exists (select 1 from journey_messages where reservation_id = r.id and kind = p_kind and ref_key = coalesce(p_ref, '')) then return 'already'; end if;
  select * into s from branch_journey_settings where branch_id = r.branch_id;
  v_phone := fn_reservation_guest_phone(r.id);
  why := case when not coalesce(s.journey_enabled, true) then 'journey_off'
              when not exists (select 1 from branch_whatsapp_channels where branch_id = r.branch_id and mode = 'web_bridge' and enabled and bridge_key_hash is not null) then 'channel_unavailable'
              when v_phone is null then 'no_phone' end;
  if why is not null then
    insert into journey_messages(organization_id, branch_id, reservation_id, kind, ref_key, status, reason)
    values (r.organization_id, r.branch_id, r.id, p_kind, coalesce(p_ref, ''), 'skipped', why);
    if why <> 'journey_off' then
      perform fn_alert_raise(r.branch_id, 'message_failed', 'journey:' || r.id || ':' || p_kind || ':' || coalesce(p_ref, ''),
        'تعذّر إرسال رسالة للنزيل — ' || coalesce((select 'غرفة ' || room_number from rooms where id = r.room_id), r.internal_ref),
        case why when 'no_phone' then 'لا يوجد جوال للنزيل في الحجز ' when 'channel_unavailable' then 'واتساب الفرع غير مربوط بكمبيوتر الاستقبال — ' else '' end
          || r.internal_ref || '. أبلغ النزيل بنفسك.', '/staff/journey', r.id);
    end if;
    return why;
  end if;
  rendered := fn_journey_render(p_body, p_options);
  -- the guest's open conversation with the branch (a message in the last 24 hours), else a new one
  select id into cid from conversations
   where branch_id = r.branch_id and wa_contact = v_phone and status <> 'closed' and last_message_at > now() - interval '24 hours'
   order by last_message_at desc limit 1;
  insert into registration_sessions(reservation_id) values (r.id) returning token into tok;
  if cid is null then
    -- (bound to the stay by its key: the conversation is the guest's — guest_verified follows the key)
    insert into conversations(branch_id, reservation_id, channel, status, guest_token, wa_contact, wa_chat_id, last_message_at)
    values (r.branch_id, r.id, 'whatsapp', 'active', tok, v_phone, v_phone || '@c.us', now()) returning id into cid;
  end if;
  update conversations set reservation_id = r.id, guest_token = tok, last_message_at = now(),
                           wa_menu = case when rendered->'menu' = 'null'::jsonb then null else rendered->'menu' end
   where id = cid;
  insert into conversation_messages(conversation_id, sender, content, meta)
  values (cid, 'assistant', rendered->>'text', jsonb_build_object('mode', 'journey', 'kind', p_kind, 'channel', 'whatsapp', 'delivery', 'queued'))
  returning id into mid;
  typed := case when p_typed is not null then fn_journey_render(p_typed, p_options) end;
  insert into whatsapp_outbox(branch_id, message_id, body) values (r.branch_id, mid, typed->>'text');
  insert into journey_messages(organization_id, branch_id, reservation_id, kind, ref_key, status, conversation_id, message_id)
  values (r.organization_id, r.branch_id, r.id, p_kind, coalesce(p_ref, ''), 'queued', cid, mid);
  return 'queued';
end $$;
revoke all on function fn_journey_send(uuid, text, text, text, jsonb, text) from public, anon, authenticated;

-- the reception computer's pick of its messages: the journey looks at the clock first (its messages go out in the same
-- pick), and a message typed with its own text uses it
create or replace function fn_wa_bridge_poll(p_branch uuid, p_limit int default 5) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r record; v_out jsonb := '[]'::jsonb; v_text text; v_chat text;
begin
  begin
    perform fn_journey_tick(p_branch, false);
  exception when others then
    raise warning 'journey tick: %', sqlerrm;                 -- the computer's messages go out whatever the journey's state
  end;
  with stale as (
    update whatsapp_outbox set status = case when status = 'sending' then 'failed' else 'expired' end,
           error = case when status = 'sending' then 'no_ack' else 'expired' end, finished_at = now(), body = null
     where branch_id = p_branch
       and ((status = 'sending' and picked_at < now() - interval '5 minutes') or (status = 'pending' and created_at < now() - interval '12 hours'))
    returning message_id, error)
  update conversation_messages m set meta = coalesce(m.meta, '{}'::jsonb) || jsonb_build_object('delivery', 'failed', 'error', s.error)
    from stale s where m.id = s.message_id;

  for r in
    select o.id, o.message_id, o.body from whatsapp_outbox o
     where o.branch_id = p_branch and o.status = 'pending'
     order by o.created_at limit greatest(1, least(coalesce(p_limit, 5), 20))
     for update skip locked
  loop
    v_text := null; v_chat := null;
    select coalesce(r.body, m.content), cv.wa_chat_id into v_text, v_chat
      from conversation_messages m join conversations cv on cv.id = m.conversation_id
     where m.id = r.message_id and cv.branch_id = p_branch;
    if v_text is null or v_chat is null then
      update whatsapp_outbox set status = 'expired', error = 'message_gone', finished_at = now(), body = null where id = r.id;
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
         error = case when p_ok then null else left(coalesce(nullif(btrim(p_error), ''), 'send_failed'), 200) end, finished_at = now(), body = null
   where id = p_id and branch_id = p_branch
     and (status = 'sending' or (coalesce(p_ok, false) and status = 'failed' and error = 'no_ack'))
  returning message_id into v_msg;
  if v_msg is null then return false; end if;
  update conversation_messages set meta = case
           when p_ok then (coalesce(meta, '{}'::jsonb) - 'error') || jsonb_build_object('delivery', 'sent')
           else coalesce(meta, '{}'::jsonb) || jsonb_build_object('delivery', 'failed', 'error', left(coalesce(nullif(btrim(p_error), ''), 'send_failed'), 200)) end
   where id = v_msg;
  return true;
end $$;
revoke all on function fn_wa_bridge_ack(uuid, uuid, boolean, text, text) from public, anon, authenticated;
grant execute on function fn_wa_bridge_ack(uuid, uuid, boolean, text, text) to service_role;

-- ---------------------------------------------------------------------------------------------------------------
-- 4. W3 — the check-out options and the extension
-- ---------------------------------------------------------------------------------------------------------------
-- the hour that late hours end at, from the free hour's end (midnight is 24:00, the end of the day of departure)
create or replace function fn_late_until(p_from time, p_hours int) returns text language sql immutable set search_path = public as $$
  select case when extract(epoch from p_from) + p_hours * 3600 >= 86400 then '24:00' else to_char(p_from + make_interval(hours => p_hours), 'HH24:MI') end
$$;
revoke all on function fn_late_until(time, int) from public, anon, authenticated;

-- the extension of a stay, as the reception's «تمديد» makes it (0033), without the caller's checks: the reception's
-- function checks its caller and then asks this one; the journey asks it for the guest's night, and to give a night
-- back that was held and not paid (p_staff_rules false: neither the weekly stay's rule nor «not before today» — a
-- night given back is not a departure)
create or replace function fn_amend_stay_internal(p_reservation uuid, p_new_check_out date, p_pricing_mode text, p_reason text, p_staff_rules boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; a reservation_allocations%rowtype; delta int; before jsonb; runs jsonb; platform boolean; last_price bigint; refund bigint;
begin
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  if r.status not in ('confirmed','checked_in','pending_verification') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  if p_new_check_out <= r.check_in then raise exception 'VALIDATION: dates'; end if;
  if p_staff_rules and r.status = 'checked_in' and p_new_check_out <= fn_branch_today(r.branch_id) and p_new_check_out < r.check_out then raise exception 'VALIDATION: checkout_in_past'; end if;
  delta := p_new_check_out - r.check_out;
  if delta = 0 then return jsonb_build_object('ok', true, 'unchanged', true); end if;
  -- decision 3: a night unpaid past its deadline stops the extension until it is paid or a reason is recorded
  if delta > 0 and r.status = 'checked_in' and fn_overdue_blocked(r.id) then
    raise exception 'PAYMENT_OVERDUE: a night is unpaid past its deadline';
  end if;
  -- leaving a weekly or monthly stay early is settled by the owner or a manager (decision 15)
  if p_staff_rules and delta < 0 and r.price_basis in ('weekly', 'monthly') and not fn_has_role('owner','manager') then
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
    perform fn_add_charge(r.id, 'adjustment', 'تقصير الإقامة ' || fn_ar_nights(abs(delta)), 1, -refund, true, p_reason, null, p_new_check_out, r.check_out);
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
revoke all on function fn_amend_stay_internal(uuid, date, text, text, boolean) from public, anon, authenticated;

create or replace function fn_staff_amend_stay(p_reservation uuid, p_new_check_out date, p_pricing_mode text, p_reason text, p_expected_version integer default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype;
begin
  perform fn_require_cap('stay.extend');
  if coalesce(trim(p_reason),'') = '' then raise exception 'VALIDATION: reason'; end if;
  if p_pricing_mode not in ('keep_rate','reprice') then raise exception 'VALIDATION: pricing_mode'; end if;
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  perform fn_check_version_strict(r.version, p_expected_version);
  return fn_amend_stay_internal(p_reservation, p_new_check_out, p_pricing_mode, p_reason, true);
end $$;
revoke all on function fn_staff_amend_stay(uuid, date, text, text, integer) from public, anon;
grant execute on function fn_staff_amend_stay(uuid, date, text, text, integer) to authenticated;

-- a room is free for the nights [from, to), whoever asks (the room's own allocations and an overstay)
create or replace function fn_room_free_internal(p_room uuid, p_from date, p_to date, p_exclude uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (select 1 from reservation_allocations a
                      where a.room_id = p_room and a.status = 'active' and daterange(a.from_date, a.to_date, '[)') && daterange(p_from, p_to, '[)')
                        and a.reservation_id is distinct from p_exclude)
     and not fn_room_overstay_blocks(p_room, p_from, p_to, p_exclude)
$$;
revoke all on function fn_room_free_internal(uuid, date, date, uuid) from public, anon, authenticated;

create table if not exists stay_extension_requests (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  branch_id uuid not null,
  reservation_id uuid not null,                               -- no reference: the trial-data purge removes stays
  kind text not null,
  hours int,
  late_until time,
  amount_halalas bigint not null default 0,
  status text not null default 'held',
  hold_until timestamptz,
  source text not null,
  previous_check_out date,
  previous_late_until time,
  charge_id uuid,
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid references staff_profiles(id),
  decision_reason text,
  version int not null default 1,
  constraint extension_kind_valid check (kind in ('night', 'hours')),
  constraint extension_hours_valid check ((kind = 'hours') = (hours is not null and hours between 1 and 23 and late_until is not null)),
  constraint extension_status_valid check (status in ('held', 'paid', 'confirmed', 'released', 'overdue')),
  constraint extension_source_valid check (source in ('whatsapp', 'page'))
);
create unique index if not exists uniq_open_extension on stay_extension_requests(reservation_id) where status in ('held', 'overdue');
create index if not exists idx_extension_branch on stay_extension_requests(branch_id, created_at desc);

-- what the guest may choose today: the day of departure only, the stay in its room. The night's price is the stay's
-- own night (with the tax of the stay's policy); the hours run from the free hour's end to the next guest's arrival
-- less the cleaning hour (no next guest that day: to midnight)
create or replace function fn_checkout_offer(p_reservation uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r reservations%rowtype; b branches%rowtype; s branch_journey_settings%rowtype; v_today date; v_open boolean; night_ok boolean := false;
        v_night bigint; night_net bigint; night_tax bigint; next_arrival boolean; limit_end time; hours_max int := 0; req stay_extension_requests%rowtype;
        hour_net bigint; hour_tax bigint;
begin
  select * into r from reservations where id = p_reservation;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  select * into b from branches where id = r.branch_id;
  select * into s from branch_journey_settings where branch_id = r.branch_id;
  v_today := fn_branch_today(r.branch_id);
  v_open := r.status = 'checked_in' and r.room_id is not null and r.check_out = v_today and r.guest_departed_at is null;
  select * into req from stay_extension_requests where reservation_id = r.id order by created_at desc limit 1;
  if v_open then
    select n.price_halalas into v_night from reservation_nights n where n.reservation_id = r.id and n.status = 'active' order by n.night desc limit 1;
    v_night := coalesce(v_night, r.nightly_rate_halalas, 0);
    select * into night_net, night_tax from fn_reservation_tax(r.id, v_night, true);
    night_ok := v_night > 0 and fn_room_free_internal(r.room_id, r.check_out, r.check_out + 1, r.id) and not fn_overdue_blocked(r.id);
    next_arrival := exists (select 1 from reservation_allocations a where a.room_id = r.room_id and a.status = 'active' and a.from_date = v_today and a.reservation_id <> r.id);
    limit_end := case when next_arrival then b.check_in_time - make_interval(mins => s.cleaning_buffer_minutes) else time '24:00' end;
    if limit_end > s.free_checkout_until then
      hours_max := floor(extract(epoch from (limit_end - s.free_checkout_until)) / 3600)::int;
    end if;
    select * into hour_net, hour_tax from fn_charge_tax(r.id, 'services', s.late_hour_price_halalas, true);
  end if;
  return jsonb_build_object(
    'open', v_open, 'status', r.status, 'check_out', r.check_out, 'room_number', (select room_number from rooms where id = r.room_id),
    'free_until', to_char(s.free_checkout_until, 'HH24:MI'), 'check_out_time', to_char(b.check_out_time, 'HH24:MI'),
    'night', jsonb_build_object('available', night_ok, 'price_halalas', case when v_open then night_net + night_tax end),
    'hours', jsonb_build_object('max', hours_max, 'price_halalas', case when v_open then hour_net + hour_tax end,
                                'until_limit', case when v_open and hours_max > 0 then fn_late_until(s.free_checkout_until, hours_max) end,
                                'next_guest', coalesce(next_arrival, false)),
    'hold_minutes', s.hold_minutes, 'choice', r.checkout_choice, 'late_checkout_until', to_char(r.late_checkout_until, 'HH24:MI'),
    'instructions', s.checkout_instructions, 'departed_at', r.guest_departed_at,
    'deposit_halalas', r.deposit_balance_halalas, 'refund_hours', s.deposit_refund_hours, 'balance_due', r.balance_due_halalas,
    'request', case when req.id is null then null else jsonb_build_object('id', req.id, 'kind', req.kind, 'hours', req.hours, 'late_until', to_char(req.late_until, 'HH24:MI'),
                                                                          'amount_halalas', req.amount_halalas, 'status', req.status, 'hold_until', req.hold_until) end);
end $$;
revoke all on function fn_checkout_offer(uuid) from public, anon, authenticated;

-- the guest's choice: 'on_time' (leaving between 12 and 1), 'night', 'hours' (with how many), or 'cancel' (a night
-- or hours held and not yet paid, given back). One held request at a time.
create or replace function fn_checkout_choose(p_reservation uuid, p_choice text, p_hours int, p_source text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; s branch_journey_settings%rowtype; o jsonb; q stay_extension_requests%rowtype; total0 bigint; amt bigint; cid uuid;
        v_until time; v_room text;
begin
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  select * into s from branch_journey_settings where branch_id = r.branch_id;
  v_room := coalesce((select room_number from rooms where id = r.room_id), '');
  if p_choice = 'cancel' then
    select * into q from stay_extension_requests where reservation_id = r.id and status = 'held' for update;
    if not found then raise exception 'VALIDATION: extension_none'; end if;
    perform fn_extension_release(q.id, 'ألغاه النزيل', 'released');
    return fn_checkout_offer(r.id);
  end if;
  if p_choice is null or p_choice not in ('on_time', 'night', 'hours') then raise exception 'VALIDATION: checkout_choice'; end if;
  o := fn_checkout_offer(r.id);
  if not (o->>'open')::boolean then raise exception 'VALIDATION: checkout_not_today'; end if;
  if exists (select 1 from stay_extension_requests where reservation_id = r.id and status in ('held', 'overdue')) then raise exception 'VALIDATION: extension_pending'; end if;
  if p_choice = 'on_time' then
    update reservations set checkout_choice = 'on_time', checkout_choice_at = now(), updated_at = now() where id = r.id;
    perform fn_audit_change(r.branch_id, 'journey.checkout_on_time', 'reservation', r.id, null, jsonb_build_object('source', p_source));
    return fn_checkout_offer(r.id);
  end if;
  total0 := r.total_halalas;
  if p_choice = 'night' then
    if not (o->'night'->>'available')::boolean then raise exception 'VALIDATION: night_unavailable'; end if;
    perform fn_amend_stay_internal(r.id, r.check_out + 1, 'keep_rate', 'ليلة إضافية بطلب النزيل', false);
    select total_halalas into amt from reservations where id = r.id;
    insert into stay_extension_requests(organization_id, branch_id, reservation_id, kind, amount_halalas, hold_until, source, previous_check_out)
    values (r.organization_id, r.branch_id, r.id, 'night', amt - total0, now() + make_interval(mins => s.hold_minutes), p_source, r.check_out)
    returning * into q;
  else
    if p_hours is null or p_hours < 1 or p_hours > coalesce((o->'hours'->>'max')::int, 0) then raise exception 'VALIDATION: late_hours'; end if;
    v_until := fn_late_until(s.free_checkout_until, p_hours)::time;
    cid := fn_add_charge(r.id, 'addon', 'خروج متأخر ' || fn_ar_hours(p_hours) || ' حتى ' || to_char(v_until, 'HH24:MI'), p_hours, s.late_hour_price_halalas, true,
                         'بطلب النزيل', null, fn_branch_today(r.branch_id), fn_branch_today(r.branch_id));
    update reservations set late_checkout_until = v_until, updated_at = now() where id = r.id;
    perform fn_recompute_reservation_finance(r.id);
    select total_halalas into amt from reservations where id = r.id;
    insert into stay_extension_requests(organization_id, branch_id, reservation_id, kind, hours, late_until, amount_halalas, hold_until, source, previous_late_until, charge_id)
    values (r.organization_id, r.branch_id, r.id, 'hours', p_hours, v_until, amt - total0, now() + make_interval(mins => s.hold_minutes), p_source, r.late_checkout_until, cid)
    returning * into q;
  end if;
  perform fn_audit_change(r.branch_id, 'journey.extension_held', 'extension_request', q.id, null,
    jsonb_build_object('kind', q.kind, 'hours', q.hours, 'amount_halalas', q.amount_halalas, 'hold_until', q.hold_until, 'source', p_source));
  -- nothing to pay (a credit on the stay): it stands at once
  if (select balance_due_halalas from reservations where id = r.id) <= 0 then
    update stay_extension_requests set status = 'paid', decided_at = now() where id = q.id;
  else
    perform fn_alert_raise(r.branch_id, 'extension_requested', 'extension:' || q.id,
      case q.kind when 'night' then 'طلب ليلة إضافية' else 'طلب خروج متأخر ' || fn_ar_hours(q.hours) end || ' — غرفة ' || v_room,
      'المبلغ ' || fn_sar_text(q.amount_halalas) || '، محجوز حتى ' || to_char(q.hold_until at time zone coalesce((select timezone from branches where id = r.branch_id), 'Asia/Riyadh'), 'HH24:MI')
        || '. يُثبَّت عند سداد رصيد الحجز.', '/staff/journey', r.id);
  end if;
  return fn_checkout_offer(r.id);
end $$;
revoke all on function fn_checkout_choose(uuid, text, int, text) from public, anon, authenticated;

-- a held night or hours given back (not paid in time, cancelled by the guest, or by the reception): the night returns
-- to the room, the late hours' line gets its exact opposite (the line and its tax), the stay is as before
create or replace function fn_extension_release(p_request uuid, p_reason text, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare q stay_extension_requests%rowtype; c record; nid uuid;
begin
  select * into q from stay_extension_requests where id = p_request for update;
  if not found or q.status not in ('held', 'overdue') then return; end if;
  if q.kind = 'night' then
    if (select check_out from reservations where id = q.reservation_id) > q.previous_check_out then
      perform fn_amend_stay_internal(q.reservation_id, q.previous_check_out, 'keep_rate', p_reason, false);
    end if;
  else
    for c in select * from reservation_charges where id = q.charge_id and total_halalas <> 0 loop
      insert into reservation_charges(organization_id, branch_id, reservation_id, kind, description, quantity, unit_price_halalas, total_halalas, taxable,
                                      reason, created_by, service_from, service_to)
      values (c.organization_id, c.branch_id, c.reservation_id, c.kind, 'إلغاء: ' || c.description, c.quantity, -c.unit_price_halalas, -c.total_halalas, c.taxable,
              p_reason, fn_staff_id(), c.service_from, c.service_to)
      returning id into nid;
      insert into reservation_charges(organization_id, branch_id, reservation_id, kind, description, quantity, unit_price_halalas, total_halalas, taxable,
                                      reason, created_by, service_from, service_to, base_charge_id)
      select t.organization_id, t.branch_id, t.reservation_id, 'tax', 'إلغاء: ' || t.description, t.quantity, -t.unit_price_halalas, -t.total_halalas, t.taxable,
             p_reason, fn_staff_id(), t.service_from, t.service_to, nid
        from reservation_charges t where t.base_charge_id = c.id and t.kind = 'tax';
    end loop;
    update reservations set late_checkout_until = q.previous_late_until, updated_at = now() where id = q.reservation_id;
    perform fn_recompute_reservation_finance(q.reservation_id);
  end if;
  update stay_extension_requests set status = p_status, decided_at = now(), decided_by = fn_staff_id(), decision_reason = p_reason, version = version + 1 where id = q.id;
  perform fn_alert_resolve('extension_requested', 'extension:' || q.id);
  perform fn_alert_resolve('extension_unpaid', 'extension:' || q.id);
  perform fn_audit_change(q.branch_id, 'journey.extension_released', 'extension_request', q.id, jsonb_build_object('status', q.status),
                          jsonb_build_object('status', p_status, 'kind', q.kind, 'amount_halalas', q.amount_halalas), p_reason);
end $$;
revoke all on function fn_extension_release(uuid, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 5. W4 — the departure and the deposit's return
-- ---------------------------------------------------------------------------------------------------------------
-- «غادرت وسلّمت المفتاح»: the stay waits for the reception's check (once)
create or replace function fn_departure_confirm(p_reservation uuid, p_via text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; v_room text;
begin
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  if r.status <> 'checked_in' then raise exception 'VALIDATION: not_in_stay'; end if;
  if r.guest_departed_at is not null then return jsonb_build_object('ok', true, 'already', true, 'departed_at', r.guest_departed_at); end if;
  update reservations set guest_departed_at = now(), guest_departed_via = p_via, updated_at = now() where id = r.id;
  v_room := coalesce((select room_number from rooms where id = r.room_id), r.internal_ref);
  perform fn_audit_change(r.branch_id, 'journey.guest_departed', 'reservation', r.id, null, jsonb_build_object('via', p_via));
  perform fn_alert_raise(r.branch_id, 'guest_departed', 'departed:' || r.id, 'غادر نزيل غرفة ' || v_room || ' — بانتظار التحقق',
    'افحص الوحدة ثم أكمل المغادرة' || case when r.deposit_balance_halalas > 0 then '، ثم رد التأمين ' || fn_sar_text(r.deposit_balance_halalas) else '' end || '.',
    '/staff/journey', r.id);
  return jsonb_build_object('ok', true, 'already', false, 'departed_at', now());
end $$;
revoke all on function fn_departure_confirm(uuid, text) from public, anon, authenticated;

-- the deposit is returned by transfer (with its number) or in cash from the branch's box (decision of 27 October)
do $$
declare fn oid; def text; n int;
        old_m constant text := $a$    m := p->>'method';
  end if;
  if m is null then raise exception 'VALIDATION: method'; end if;$a$;
        new_m constant text := $b$    m := p->>'method';
  end if;
  if m is null then raise exception 'VALIDATION: method'; end if;
  if kind = 'deposit_refund' and m not in ('cash', 'bank_transfer') then raise exception 'VALIDATION: deposit_method'; end if;$b$;
begin
  select p.oid into fn from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'fn_refund';
  def := pg_get_functiondef(fn);
  if position($c$if kind = 'deposit_refund' and m not in ('cash', 'bank_transfer')$c$ in def) > 0 then return; end if;
  n := (length(def) - length(replace(def, old_m, ''))) / length(old_m);
  if n <> 1 then raise exception '0070: the method lines of fn_refund were found % times, not once', n; end if;
  execute replace(def, old_m, new_m);
end $$;

-- the confirmed check-out: the departure's alert is closed, and the guest is told — with the deposit's return
create or replace function fn_trg_journey_checkout() returns trigger
language plpgsql security definer set search_path = public as $$
declare s branch_journey_settings%rowtype; v_room text;
begin
  if new.status = 'checked_out' and old.status = 'checked_in' then
    perform fn_alert_resolve('guest_departed', 'departed:' || new.id);
    select * into s from branch_journey_settings where branch_id = new.branch_id;
    v_room := coalesce((select room_number from rooms where id = new.room_id), '');
    perform fn_journey_send(new.id, 'checkout_confirmed', '',
      'تم تأكيد خروجك من غرفة ' || v_room || '. شكرًا لإقامتك معنا.'
      || case when new.deposit_balance_halalas > 0 then E'\n' || 'يُرد تأمينك (' || fn_sar_text(new.deposit_balance_halalas) || ') خلال '
                   || fn_ar_hours(s.deposit_refund_hours) || ': تحويلًا إلى حسابك أو نقدًا من الاستقبال، ويصلك إيصال الرد هنا.' else '' end);
  end if;
  return new;
end $$;
revoke all on function fn_trg_journey_checkout() from public, anon, authenticated;
create or replace trigger trg_journey_checkout after update of status on reservations for each row execute function fn_trg_journey_checkout();

-- the receipt of the deposit's return goes out only once the return is recorded
create or replace function fn_trg_journey_deposit_refund() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.kind = 'deposit_refund' and new.status = 'approved' and new.reservation_id is not null then
    perform fn_journey_send(new.reservation_id, 'deposit_refunded', new.id::text,
      'رُد إليك تأمينك ' || fn_sar_text(new.amount_halalas)
      || case when new.method::text = 'bank_transfer' then ' بالتحويل' || coalesce(' (رقم العملية ' || nullif(new.reference, '') || ')', '') else ' نقدًا' end
      || '. رقم السند ' || new.number || '. شكرًا لك.');
  end if;
  return new;
end $$;
revoke all on function fn_trg_journey_deposit_refund() from public, anon, authenticated;
create or replace trigger trg_journey_deposit_refund after insert on financial_vouchers for each row execute function fn_trg_journey_deposit_refund();

-- ---------------------------------------------------------------------------------------------------------------
-- 6. W5 — the review
-- ---------------------------------------------------------------------------------------------------------------
create table if not exists guest_reviews (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  branch_id uuid not null,
  reservation_id uuid not null,                               -- no reference: the trial-data purge removes stays
  token_hash text not null,
  invited_at timestamptz not null default now(),
  invite_status text,
  submitted_at timestamptz,
  overall smallint,                                           -- asked on its own, not the aspects' average
  staff smallint, cleanliness smallint, comfort smallint, facilities smallint, value smallint, location smallint,
  comment text,
  reply text,
  replied_by uuid references staff_profiles(id),
  replied_at timestamptz,
  version int not null default 1,
  constraint review_marks_valid check (
    (overall is null or overall between 1 and 10) and (staff is null or staff between 1 and 10) and (cleanliness is null or cleanliness between 1 and 10)
    and (comfort is null or comfort between 1 and 10) and (facilities is null or facilities between 1 and 10) and (value is null or value between 1 and 10)
    and (location is null or location between 1 and 10)),
  constraint review_complete check (submitted_at is null or (overall is not null and staff is not null and cleanliness is not null and comfort is not null
                                                              and facilities is not null and value is not null and location is not null)),
  constraint review_comment_valid check (comment is null or char_length(comment) <= 1000),
  constraint review_reply_valid check (reply is null or char_length(reply) between 1 and 1000)
);
create unique index if not exists uniq_review_stay on guest_reviews(reservation_id);
create unique index if not exists uniq_review_token on guest_reviews(token_hash);
create index if not exists idx_reviews_branch on guest_reviews(branch_id, submitted_at desc);

-- the six aspects, in the order they are asked
create or replace function fn_review_aspects() returns jsonb language sql immutable set search_path = public as $$
  select '[{"key":"staff","label":"تعامل الموظفين"},{"key":"cleanliness","label":"النظافة"},{"key":"comfort","label":"الراحة"},{"key":"facilities","label":"المرافق"},{"key":"value","label":"القيمة مقابل السعر"},{"key":"location","label":"الموقع"}]'::jsonb
$$;
revoke all on function fn_review_aspects() from public, anon;
grant execute on function fn_review_aspects() to authenticated, service_role;

-- one invitation for a stay: its page's key is typed in the message and kept only as its hash
create or replace function fn_review_invite(p_reservation uuid) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare r reservations%rowtype; tok text; v_site text; st text; v_id uuid;
begin
  select * into r from reservations where id = p_reservation;
  if not found or exists (select 1 from guest_reviews where reservation_id = r.id) then return 'already'; end if;
  tok := encode(gen_random_bytes(18), 'hex');
  insert into guest_reviews(organization_id, branch_id, reservation_id, token_hash) values (r.organization_id, r.branch_id, r.id, encode(digest(tok, 'sha256'), 'hex'))
  returning id into v_id;
  v_site := rtrim((select guest_site_url from organizations where id = r.organization_id), '/');
  st := fn_journey_send(r.id, 'review_invite', '',
    'شكرًا لإقامتك معنا. يسعدنا تقييمك في دقيقة: درجة عامة من 10 وستة جوانب.' || E'\n' || coalesce(v_site, '') || '/booking/review/…', null,
    'شكرًا لإقامتك معنا. يسعدنا تقييمك في دقيقة: درجة عامة من 10 وستة جوانب.' || E'\n' || coalesce(v_site, '') || '/booking/review/' || tok);
  update guest_reviews set invite_status = st where id = v_id;
  return st;
end $$;
revoke all on function fn_review_invite(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 7. The clock of the journey: whenever the reception computer asks for its messages, or a member of staff's screen
--    looks (at most once a minute per branch)
-- ---------------------------------------------------------------------------------------------------------------
create table if not exists journey_ticks (branch_id uuid primary key, last_at timestamptz not null);

-- p_at: the moment the clock is read at (now, unless a check asks for another hour of the same day)
create or replace function fn_journey_tick(p_branch uuid, p_force boolean, p_at timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s branch_journey_settings%rowtype; v_today date; v_now time; q record; r record; n_options int := 0; n_reviews int := 0; n_paid int := 0;
        n_released int := 0; n_esc int := 0; o jsonb; opts jsonb; v_room text; v_tz text; a record;
begin
  if not pg_try_advisory_xact_lock(hashtext('journey:' || p_branch)) then return jsonb_build_object('ran', false); end if;
  if not p_force and exists (select 1 from journey_ticks where branch_id = p_branch and last_at > now() - interval '50 seconds') then
    return jsonb_build_object('ran', false);
  end if;
  insert into journey_ticks(branch_id, last_at) values (p_branch, now()) on conflict (branch_id) do update set last_at = now();
  select * into s from branch_journey_settings where branch_id = p_branch;
  if not found then return jsonb_build_object('ran', false); end if;
  v_tz := coalesce((select timezone from branches where id = p_branch), 'Asia/Riyadh');
  v_today := (p_at at time zone v_tz)::date; v_now := (p_at at time zone v_tz)::time;

  -- (1) the night or hours held: paid → it stands; time over → given back (before the free hour ends), or overdue
  for q in select x.*, rs.balance_due_halalas as due, rs.status as res_status, rs.room_id from stay_extension_requests x join reservations rs on rs.id = x.reservation_id
            where x.branch_id = p_branch and x.status in ('held', 'overdue') order by x.created_at loop
    if q.due <= 0 then
      update stay_extension_requests set status = 'paid', decided_at = now(), version = version + 1 where id = q.id;
      perform fn_alert_resolve('extension_requested', 'extension:' || q.id);
      perform fn_alert_resolve('extension_unpaid', 'extension:' || q.id);
      perform fn_journey_send(q.reservation_id, 'extension_confirmed', q.id::text,
        case q.kind when 'night' then 'تم تثبيت ليلتك الإضافية. موعد خروجك الجديد غدًا بين 12 و1 ظهرًا.'
                    else 'تم تثبيت خروجك المتأخر حتى ' || to_char(q.late_until, 'HH24:MI') || '.' end);
      n_paid := n_paid + 1;
    elsif q.status = 'held' and q.hold_until < p_at then
      if q.res_status = 'checked_in' and v_now < s.free_checkout_until then
        perform fn_extension_release(q.id, 'انتهت مهلة الدفع', 'released');
        perform fn_journey_send(q.reservation_id, 'extension_released', q.id::text,
          'انتهت مهلة الدفع فأُلغي طلب ' || case q.kind when 'night' then 'الليلة الإضافية' else 'الخروج المتأخر' end
          || '. موعد خروجك اليوم قبل ' || to_char(s.free_checkout_until, 'HH24:MI') || '. للمساعدة اطلب موظف الاستقبال.');
        n_released := n_released + 1;
      else
        update stay_extension_requests set status = 'overdue', version = version + 1 where id = q.id;
        perform fn_alert_raise(p_branch, 'extension_unpaid', 'extension:' || q.id,
          case q.kind when 'night' then 'ليلة إضافية لم تُدفع' else 'خروج متأخر لم يُدفع' end || ' — غرفة ' || coalesce((select room_number from rooms where id = q.room_id), ''),
          'انتهت مهلة الدفع بعد ' || to_char(s.free_checkout_until, 'HH24:MI') || '؛ حصّل المبلغ ' || fn_sar_text(q.amount_halalas) || ' أو ألغِ الطلب.', '/staff/journey', q.reservation_id);
      end if;
    end if;
  end loop;

  -- (2) the morning of departure: the options, once, from the message's hour until the free hour ends
  if v_now >= s.checkout_message_time and v_now < s.free_checkout_until then
    for r in select rs.id, rs.room_id from reservations rs
              where rs.branch_id = p_branch and rs.status = 'checked_in' and rs.room_id is not null and rs.check_out = v_today
                and rs.guest_departed_at is null and rs.checkout_choice is null
                and not exists (select 1 from stay_extension_requests x where x.reservation_id = rs.id)
                and not exists (select 1 from journey_messages m where m.reservation_id = rs.id and m.kind = 'checkout_options') loop
      o := fn_checkout_offer(r.id);
      opts := jsonb_build_array(jsonb_build_object('id', 'CO:ONTIME', 'title', 'سأخرج في الموعد (12–1)'));
      if (o->'night'->>'available')::boolean then
        opts := opts || jsonb_build_array(jsonb_build_object('id', 'CO:NIGHT', 'title', 'ليلة إضافية — ' || fn_sar_text((o->'night'->>'price_halalas')::bigint)));
      end if;
      if (o->'hours'->>'max')::int > 0 then
        opts := opts || jsonb_build_array(jsonb_build_object('id', 'CO:HOURS', 'title', 'ساعات بعد ' || (o->>'free_until') || ' — ' || fn_sar_text((o->'hours'->>'price_halalas')::bigint) || ' للساعة'));
      end if;
      opts := opts || jsonb_build_array(jsonb_build_object('id', 'HUMAN', 'title', 'التحدث مع موظف'));
      perform fn_journey_send(r.id, 'checkout_options', '',
        'صباح الخير. موعد خروجك اليوم من غرفة ' || coalesce(o->>'room_number', '') || ' بين 12 و1 ظهرًا. ماذا تفضّل؟', opts);
      n_options := n_options + 1;
    end loop;
  end if;

  -- (3) one invitation to review, the delay after the confirmed check-out (within two days of it)
  for r in select rs.id from reservations rs
            where rs.branch_id = p_branch and rs.status in ('checked_out', 'closed') and rs.actual_check_out is not null
              and rs.actual_check_out <= p_at - make_interval(mins => s.review_delay_minutes) and rs.actual_check_out > p_at - interval '2 days'
              and not exists (select 1 from guest_reviews g where g.reservation_id = rs.id) loop
    perform fn_review_invite(r.id);
    n_reviews := n_reviews + 1;
  end loop;

  -- (4) the deposit's return past its hours (from the confirmed check-out); closed once nothing is left to return
  for r in select rs.id, rs.room_id, rs.deposit_balance_halalas, rs.actual_check_out from reservations rs
            where rs.branch_id = p_branch and rs.status in ('checked_out', 'closed') and rs.deposit_balance_halalas > 0 and rs.actual_check_out is not null
              and rs.actual_check_out <= p_at - make_interval(hours => s.deposit_refund_hours) and rs.actual_check_out > p_at - interval '7 days' loop
    perform fn_alert_raise(p_branch, 'deposit_overdue', 'deposit:' || r.id,
      'تأخر رد تأمين غرفة ' || coalesce((select room_number from rooms where id = r.room_id), '') || ' (' || fn_sar_text(r.deposit_balance_halalas) || ')',
      'مضت ' || fn_ar_hours(s.deposit_refund_hours) || ' على تأكيد الخروج. رد التأمين تحويلًا برقم العملية أو نقدًا من صندوق الفرع.', '/staff/journey', r.id);
  end loop;
  for a in select e.id, e.ref_key from alert_events e where e.branch_id = p_branch and e.event = 'deposit_overdue' and e.resolved_at is null loop
    if coalesce((select deposit_balance_halalas from reservations where id = substr(a.ref_key, 9)::uuid), 0) <= 0 then
      update alert_events set resolved_at = now(), resolved_how = 'auto' where id = a.id;
    end if;
  end loop;
  -- a departure the reception already handled another way (the stay is no longer in the house)
  update alert_events e set resolved_at = now(), resolved_how = 'auto'
   where e.branch_id = p_branch and e.event = 'guest_departed' and e.resolved_at is null
     and not exists (select 1 from reservations rs where rs.id = e.reservation_id and rs.status = 'checked_in');

  -- (5) the alerts whose delay is over, then those nobody acted on: they climb
  for a in select e.id from alert_events e where e.branch_id = p_branch and e.resolved_at is null and e.notified_at is null and e.notify_at <= p_at loop
    perform fn_alert_notify(a.id, false);
  end loop;
  for a in select e.id from alert_events e join alert_rules rl on rl.organization_id = e.organization_id and rl.event = e.event
            where e.branch_id = p_branch and e.resolved_at is null and e.notified_at is not null and e.escalated_at is null
              and rl.escalate_after_minutes is not null and e.notified_at <= p_at - make_interval(mins => rl.escalate_after_minutes) loop
    perform fn_alert_notify(a.id, true);
    n_esc := n_esc + 1;
  end loop;
  return jsonb_build_object('ran', true, 'options', n_options, 'reviews', n_reviews, 'paid', n_paid, 'released', n_released, 'escalated', n_esc);
end $$;
revoke all on function fn_journey_tick(uuid, boolean, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 8. The events of W1 and of the conversation, by their rules: a product order waiting for its payment, a guest
--    asking for a member of staff
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_trg_journey_product_order() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    perform fn_alert_raise(new.branch_id, 'product_order', 'order:' || new.id, 'طلب منتجات بانتظار الدفع — ' || new.number
      || coalesce(' — غرفة ' || (select rm.room_number from reservations rs join rooms rm on rm.id = rs.room_id where rs.id = new.reservation_id), ''),
      'تسلّم الدفع ليُصدر السند وتُنشأ مهمة التسليم.', '/staff/orders', new.reservation_id);
  elsif new.status is distinct from old.status and new.status <> 'pending_payment' then
    perform fn_alert_resolve('product_order', 'order:' || new.id);
  end if;
  return new;
end $$;
revoke all on function fn_trg_journey_product_order() from public, anon, authenticated;
create or replace trigger trg_journey_product_order after insert or update of status on product_orders for each row execute function fn_trg_journey_product_order();

create or replace function fn_trg_journey_handoff() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.branch_id is null then return new; end if;
  if tg_op = 'INSERT' then
    perform fn_alert_raise(new.branch_id, 'guest_handoff', 'handoff:' || new.id,
      'نزيل يطلب موظفًا' || coalesce(' — ' || nullif(new.source_name, ''), ''), left(coalesce(new.details->>'reason', new.details->>'message', new.kind), 300), '/staff/inbox', new.reservation_id);
  elsif new.status is distinct from old.status and new.status <> 'open' then
    perform fn_alert_resolve('guest_handoff', 'handoff:' || new.id);
  end if;
  return new;
end $$;
revoke all on function fn_trg_journey_handoff() from public, anon, authenticated;
create or replace trigger trg_journey_handoff after insert or update of status on human_handoff_tickets for each row execute function fn_trg_journey_handoff();

-- ---------------------------------------------------------------------------------------------------------------
-- 9. Who reads what: the settings and the rules in the screens through functions; the journey's records by the
--    staff of their branches
-- ---------------------------------------------------------------------------------------------------------------
alter table branch_journey_settings enable row level security;
alter table alert_rules enable row level security;
alter table alert_events enable row level security;
alter table journey_messages enable row level security;
alter table journey_ticks enable row level security;
alter table stay_extension_requests enable row level security;
alter table guest_reviews enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'branch_journey_settings' and policyname = 'journey_settings_read') then
    create policy "journey_settings_read" on branch_journey_settings for select to authenticated using (branch_id in (select fn_user_branch_ids()));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'alert_rules' and policyname = 'alert_rules_read') then
    create policy "alert_rules_read" on alert_rules for select to authenticated using (organization_id = fn_user_org_id());
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'alert_events' and policyname = 'alert_events_read') then
    create policy "alert_events_read" on alert_events for select to authenticated using (branch_id in (select fn_user_branch_ids()));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'journey_messages' and policyname = 'journey_messages_read') then
    create policy "journey_messages_read" on journey_messages for select to authenticated using (branch_id in (select fn_user_branch_ids()));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'stay_extension_requests' and policyname = 'extension_requests_read') then
    create policy "extension_requests_read" on stay_extension_requests for select to authenticated using (branch_id in (select fn_user_branch_ids()) and fn_sees_money());
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'guest_reviews' and policyname = 'guest_reviews_read') then
    create policy "guest_reviews_read" on guest_reviews for select to authenticated using (branch_id in (select fn_user_branch_ids()));
  end if;
end $$;
revoke all on branch_journey_settings, alert_rules, alert_events, journey_messages, journey_ticks, stay_extension_requests, guest_reviews from anon, authenticated;
grant select on branch_journey_settings, alert_rules, alert_events, journey_messages, stay_extension_requests to authenticated;
-- a review's page key is never read back, not even as its hash
grant select (id, organization_id, branch_id, reservation_id, invited_at, invite_status, submitted_at, overall, staff, cleanliness, comfort, facilities, value, location,
              comment, reply, replied_by, replied_at, version) on guest_reviews to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 10. The guest (the stay's pages, by their key; and WhatsApp, through the server)
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_guest_checkout(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  return fn_checkout_offer(fn_token_reservation(p_token));
end $$;
revoke all on function fn_guest_checkout(text) from public;
grant execute on function fn_guest_checkout(text) to anon, authenticated, service_role;

create or replace function fn_guest_checkout_choose(p_token text, p_choice text, p_hours int default null, p_via text default 'page') returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(p_via, '') not in ('page', 'whatsapp') then raise exception 'VALIDATION: via'; end if;
  return fn_checkout_choose(fn_token_reservation(p_token), p_choice, p_hours, p_via);
end $$;
revoke all on function fn_guest_checkout_choose(text, text, int, text) from public;
grant execute on function fn_guest_checkout_choose(text, text, int, text) to anon, authenticated, service_role;

create or replace function fn_guest_departure(p_token text, p_via text default 'page') returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(p_via, '') not in ('page', 'whatsapp') then raise exception 'VALIDATION: via'; end if;
  return fn_departure_confirm(fn_token_reservation(p_token), p_via);
end $$;
revoke all on function fn_guest_departure(text, text) from public;
grant execute on function fn_guest_departure(text, text) to anon, authenticated, service_role;

-- a review's page: open for 14 days after its invitation; answered once
create or replace function fn_public_review(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare g guest_reviews%rowtype; r reservations%rowtype;
begin
  select * into g from guest_reviews where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex') and invited_at > now() - interval '14 days';
  if not found then raise exception 'TOKEN_INVALID' using errcode = 'P0002'; end if;
  select * into r from reservations where id = g.reservation_id;
  return jsonb_build_object('branch_name', (select name_ar from branches where id = g.branch_id), 'check_in', r.check_in, 'check_out', r.check_out,
                            'submitted', g.submitted_at is not null, 'aspects', fn_review_aspects(), 'reply', g.reply);
end $$;
revoke all on function fn_public_review(text) from public;
grant execute on function fn_public_review(text) to anon, authenticated, service_role;

create or replace function fn_public_submit_review(p_token text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare g guest_reviews%rowtype; k text; s branch_journey_settings%rowtype; v_comment text := nullif(btrim(coalesce(p->>'comment', '')), ''); v_room text;
begin
  select * into g from guest_reviews where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex') and invited_at > now() - interval '14 days' for update;
  if not found then raise exception 'TOKEN_INVALID' using errcode = 'P0002'; end if;
  if g.submitted_at is not null then raise exception 'VALIDATION: review_submitted'; end if;
  if p is null or jsonb_typeof(p) <> 'object' then raise exception 'VALIDATION: review_marks'; end if;
  foreach k in array array['overall', 'staff', 'cleanliness', 'comfort', 'facilities', 'value', 'location'] loop
    if coalesce(p->>k, '') !~ '^[0-9]{1,2}$' or (p->>k)::int not between 1 and 10 then raise exception 'VALIDATION: review_marks'; end if;
  end loop;
  if v_comment is not null and char_length(v_comment) > 1000 then raise exception 'VALIDATION: review_comment'; end if;
  update guest_reviews set submitted_at = now(), overall = (p->>'overall')::int, staff = (p->>'staff')::int, cleanliness = (p->>'cleanliness')::int,
         comfort = (p->>'comfort')::int, facilities = (p->>'facilities')::int, value = (p->>'value')::int, location = (p->>'location')::int,
         comment = v_comment, version = version + 1
   where id = g.id;
  select * into s from branch_journey_settings where branch_id = g.branch_id;
  if (p->>'overall')::int < s.review_alert_below then
    v_room := coalesce((select rm.room_number from reservations rs join rooms rm on rm.id = rs.room_id where rs.id = g.reservation_id), '');
    perform fn_alert_raise(g.branch_id, 'review_low', 'review:' || g.id, 'تقييم ' || (p->>'overall') || ' من 10 — غرفة ' || v_room,
      coalesce(left(v_comment, 300), 'بلا تعليق'), '/staff/journey', g.reservation_id);
  end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function fn_public_submit_review(text, jsonb) from public;
grant execute on function fn_public_submit_review(text, jsonb) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------------------------
-- 11. The reception: «رحلة الضيف» — the held requests, the departures to check, the deposits to return, the reviews,
--     the open alerts
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_staff_journey_tick(p_branch uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t jsonb;
begin
  perform fn_require_branch(p_branch);
  if not fn_has_role('owner', 'manager', 'supervisor') then raise exception 'FORBIDDEN: journey' using errcode = '42501'; end if;
  t := fn_journey_tick(p_branch, false);
  return t || jsonb_build_object('open_alerts', (select count(*) from alert_events where branch_id = p_branch and resolved_at is null and notified_at is not null));
end $$;
revoke all on function fn_staff_journey_tick(uuid) from public, anon;
grant execute on function fn_staff_journey_tick(uuid) to authenticated;

create or replace function fn_staff_journey(p_branch uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s branch_journey_settings%rowtype; v_today date;
begin
  perform fn_require_branch(p_branch);
  if not fn_has_role('owner', 'manager', 'supervisor') then raise exception 'FORBIDDEN: journey' using errcode = '42501'; end if;
  select * into s from branch_journey_settings where branch_id = p_branch;
  v_today := fn_branch_today(p_branch);
  return jsonb_build_object(
    'settings', jsonb_build_object('journey_enabled', s.journey_enabled, 'checkout_message_time', to_char(s.checkout_message_time, 'HH24:MI'),
                                   'free_until', to_char(s.free_checkout_until, 'HH24:MI'), 'refund_hours', s.deposit_refund_hours, 'review_alert_below', s.review_alert_below),
    'channel_ready', exists (select 1 from branch_whatsapp_channels where branch_id = p_branch and mode = 'web_bridge' and enabled and bridge_key_hash is not null),
    'departing', coalesce((select jsonb_agg(jsonb_build_object('reservation_id', rs.id, 'internal_ref', rs.internal_ref, 'room_number', rm.room_number,
                                     'choice', rs.checkout_choice, 'late_checkout_until', to_char(rs.late_checkout_until, 'HH24:MI'), 'departed_at', rs.guest_departed_at,
                                     'message', (select m.status || coalesce(':' || m.reason, '') from journey_messages m where m.reservation_id = rs.id and m.kind = 'checkout_options'))
                                   order by rm.room_number)
                          from reservations rs join rooms rm on rm.id = rs.room_id
                         where rs.branch_id = p_branch and rs.status = 'checked_in' and rs.check_out <= v_today), '[]'::jsonb),
    'requests', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'reservation_id', x.reservation_id, 'internal_ref', rs.internal_ref, 'room_number', rm.room_number,
                                     'kind', x.kind, 'hours', x.hours, 'late_until', to_char(x.late_until, 'HH24:MI'), 'amount_halalas', x.amount_halalas,
                                     'status', x.status, 'hold_until', x.hold_until, 'source', x.source, 'created_at', x.created_at, 'version', x.version)
                                   order by x.created_at desc)
                          from stay_extension_requests x join reservations rs on rs.id = x.reservation_id left join rooms rm on rm.id = rs.room_id
                         where x.branch_id = p_branch and (x.status in ('held', 'overdue') or x.created_at > now() - interval '2 days')), '[]'::jsonb),
    'awaiting_check', coalesce((select jsonb_agg(jsonb_build_object('reservation_id', rs.id, 'internal_ref', rs.internal_ref, 'room_number', rm.room_number,
                                     'departed_at', rs.guest_departed_at, 'via', rs.guest_departed_via, 'deposit_halalas', rs.deposit_balance_halalas,
                                     'balance_due', rs.balance_due_halalas) order by rs.guest_departed_at)
                          from reservations rs left join rooms rm on rm.id = rs.room_id
                         where rs.branch_id = p_branch and rs.status = 'checked_in' and rs.guest_departed_at is not null), '[]'::jsonb),
    'deposits', coalesce((select jsonb_agg(jsonb_build_object('reservation_id', rs.id, 'internal_ref', rs.internal_ref, 'room_number', rm.room_number,
                                     'deposit_halalas', rs.deposit_balance_halalas, 'checked_out_at', rs.actual_check_out,
                                     'due_at', rs.actual_check_out + make_interval(hours => s.deposit_refund_hours),
                                     'overdue', rs.actual_check_out + make_interval(hours => s.deposit_refund_hours) < now()) order by rs.actual_check_out)
                          from reservations rs left join rooms rm on rm.id = rs.room_id
                         where rs.branch_id = p_branch and rs.status in ('checked_out', 'closed') and rs.deposit_balance_halalas > 0
                           and rs.actual_check_out > now() - interval '30 days'), '[]'::jsonb),
    'alerts', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'event', e.event, 'label', fn_alert_event_label(e.event), 'title', e.title, 'body', e.body,
                                     'link', e.link, 'created_at', e.created_at, 'notify_at', e.notify_at, 'notified_at', e.notified_at, 'notified_to', e.notified_to,
                                     'escalated_at', e.escalated_at, 'escalated_to', e.escalated_to) order by e.created_at desc)
                          from alert_events e where e.branch_id = p_branch and e.resolved_at is null), '[]'::jsonb));
end $$;
revoke all on function fn_staff_journey(uuid) from public, anon;
grant execute on function fn_staff_journey(uuid) to authenticated;

-- the reception keeps a held request without its payment now («تثبيت»), or gives it back («إلغاء»), with a reason
create or replace function fn_staff_extension_decide(p_request uuid, p_action text, p_reason text, p_expected_version int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare q stay_extension_requests%rowtype; v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  perform fn_require_cap('stay.extend');
  select * into q from stay_extension_requests where id = p_request and organization_id = fn_user_org_id();
  if not found then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(q.branch_id);
  if p_action is null or p_action not in ('confirm', 'release') then raise exception 'VALIDATION: action'; end if;
  if v_reason is null or char_length(v_reason) > 300 then raise exception 'VALIDATION: reason'; end if;
  perform 1 from reservations where id = q.reservation_id for update;
  select * into q from stay_extension_requests where id = q.id for update;
  perform fn_check_version_strict(q.version, p_expected_version);
  if q.status not in ('held', 'overdue') then raise exception 'VALIDATION: extension_status'; end if;
  if p_action = 'confirm' then
    update stay_extension_requests set status = 'confirmed', decided_at = now(), decided_by = fn_staff_id(), decision_reason = v_reason, version = version + 1 where id = q.id;
    perform fn_alert_resolve('extension_requested', 'extension:' || q.id);
    perform fn_alert_resolve('extension_unpaid', 'extension:' || q.id);
    perform fn_audit_change(q.branch_id, 'journey.extension_confirmed', 'extension_request', q.id, jsonb_build_object('status', q.status),
                            jsonb_build_object('status', 'confirmed', 'kind', q.kind, 'amount_halalas', q.amount_halalas), v_reason);
  else
    perform fn_extension_release(q.id, v_reason, 'released');
  end if;
  return jsonb_build_object('ok', true, 'status', (select status from stay_extension_requests where id = q.id));
end $$;
revoke all on function fn_staff_extension_decide(uuid, text, text, int) from public, anon;
grant execute on function fn_staff_extension_decide(uuid, text, text, int) to authenticated;

create or replace function fn_staff_alert_resolve(p_alert uuid, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a alert_events%rowtype;
begin
  select * into a from alert_events where id = p_alert and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(a.branch_id);
  if not fn_has_role('owner', 'manager', 'supervisor') then raise exception 'FORBIDDEN: journey' using errcode = '42501'; end if;
  if a.resolved_at is not null then return jsonb_build_object('ok', true, 'already', true); end if;
  update alert_events set resolved_at = now(), resolved_by = fn_staff_id(), resolved_how = 'staff' where id = a.id;
  perform fn_audit_change(a.branch_id, 'alert.resolved', 'alert_event', a.id, null,
                          jsonb_build_object('event', a.event, 'title', a.title), nullif(btrim(coalesce(p_note, '')), ''));
  return jsonb_build_object('ok', true, 'already', false);
end $$;
revoke all on function fn_staff_alert_resolve(uuid, text) from public, anon;
grant execute on function fn_staff_alert_resolve(uuid, text) to authenticated;

-- the reviews of a branch: the latest, the averages, those under the alert's mark
create or replace function fn_staff_reviews(p_branch uuid, p_days int default 30) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s branch_journey_settings%rowtype;
begin
  perform fn_require_cap('conversation.take');
  perform fn_require_branch(p_branch);
  if p_days is null or p_days not between 1 and 365 then raise exception 'VALIDATION: days'; end if;
  select * into s from branch_journey_settings where branch_id = p_branch;
  return jsonb_build_object(
    'aspects', fn_review_aspects(), 'alert_below', s.review_alert_below,
    'summary', (select jsonb_build_object('count', count(*), 'overall', round(avg(overall), 1), 'staff', round(avg(staff), 1), 'cleanliness', round(avg(cleanliness), 1),
                                          'comfort', round(avg(comfort), 1), 'facilities', round(avg(facilities), 1), 'value', round(avg(value), 1), 'location', round(avg(location), 1),
                                          'below', count(*) filter (where overall < s.review_alert_below))
                  from guest_reviews where branch_id = p_branch and submitted_at > now() - make_interval(days => p_days)),
    'invited', (select count(*) from guest_reviews where branch_id = p_branch and invited_at > now() - make_interval(days => p_days)),
    'reviews', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'reservation_id', g.reservation_id, 'internal_ref', rs.internal_ref, 'room_number', rm.room_number,
                                     'submitted_at', g.submitted_at, 'overall', g.overall, 'staff', g.staff, 'cleanliness', g.cleanliness, 'comfort', g.comfort,
                                     'facilities', g.facilities, 'value', g.value, 'location', g.location, 'comment', g.comment, 'reply', g.reply,
                                     'replied_at', g.replied_at, 'version', g.version) order by g.submitted_at desc)
                          from guest_reviews g left join reservations rs on rs.id = g.reservation_id left join rooms rm on rm.id = rs.room_id
                         where g.branch_id = p_branch and g.submitted_at > now() - make_interval(days => p_days)), '[]'::jsonb));
end $$;
revoke all on function fn_staff_reviews(uuid, int) from public, anon;
grant execute on function fn_staff_reviews(uuid, int) to authenticated;

-- the reception answers a review (whoever may answer the guests); the answer reaches the guest on WhatsApp
create or replace function fn_staff_review_reply(p_review uuid, p_reply text, p_expected_version int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g guest_reviews%rowtype; v_reply text := nullif(btrim(coalesce(p_reply, '')), '');
begin
  perform fn_require_cap('conversation.take');
  select * into g from guest_reviews where id = p_review and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(g.branch_id);
  perform fn_check_version_strict(g.version, p_expected_version);
  if g.submitted_at is null then raise exception 'VALIDATION: review_not_submitted'; end if;
  if g.reply is not null then raise exception 'VALIDATION: review_replied'; end if;
  if v_reply is null or char_length(v_reply) > 1000 then raise exception 'VALIDATION: review_reply'; end if;
  update guest_reviews set reply = v_reply, replied_by = fn_staff_id(), replied_at = now(), version = version + 1 where id = g.id;
  perform fn_alert_resolve('review_low', 'review:' || g.id);
  perform fn_audit_change(g.branch_id, 'review.replied', 'guest_review', g.id, null, jsonb_build_object('overall', g.overall, 'reply', v_reply));
  perform fn_journey_send(g.reservation_id, 'review_reply', g.id::text, 'شكرًا لتقييمك. رد الإدارة:' || E'\n' || v_reply);
  return jsonb_build_object('ok', true);
end $$;
revoke all on function fn_staff_review_reply(uuid, text, int) from public, anon;
grant execute on function fn_staff_review_reply(uuid, text, int) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 12. The settings («رحلة الضيف» in the administration): the branch's numbers (the owner or the manager), the alert
--     rules and the guests' site (the owner's)
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_admin_journey_settings(p_branch uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s branch_journey_settings%rowtype;
begin
  perform fn_require_cap('branch.settings');
  perform fn_require_branch(p_branch);
  select * into s from branch_journey_settings where branch_id = p_branch;
  return jsonb_build_object(
    'branch_id', p_branch, 'journey_enabled', s.journey_enabled, 'checkout_message_time', to_char(s.checkout_message_time, 'HH24:MI'),
    'free_checkout_until', to_char(s.free_checkout_until, 'HH24:MI'), 'late_hour_price_halalas', s.late_hour_price_halalas,
    'cleaning_buffer_minutes', s.cleaning_buffer_minutes, 'hold_minutes', s.hold_minutes, 'checkout_instructions', s.checkout_instructions,
    'deposit_refund_hours', s.deposit_refund_hours, 'review_delay_minutes', s.review_delay_minutes, 'review_alert_below', s.review_alert_below,
    'responsible_staff_id', s.responsible_staff_id, 'fallback_staff_id', s.fallback_staff_id, 'version', s.version,
    'channel_ready', exists (select 1 from branch_whatsapp_channels where branch_id = p_branch and mode = 'web_bridge' and enabled and bridge_key_hash is not null),
    'guest_site_url', (select guest_site_url from organizations where id = fn_user_org_id()),
    'staff', coalesce((select jsonb_agg(jsonb_build_object('id', sp.id, 'name', sp.full_name, 'role', sp.role, 'has_phone', fn_normalize_phone(sp.phone) is not null)
                                        order by sp.role, sp.full_name)
                         from staff_profiles sp
                        where sp.organization_id = fn_user_org_id() and sp.is_active and sp.role in ('owner', 'manager', 'supervisor')
                          and (sp.role = 'owner' or exists (select 1 from branch_memberships m where m.staff_id = sp.id and m.branch_id = p_branch and m.removed_at is null))), '[]'::jsonb));
end $$;
revoke all on function fn_admin_journey_settings(uuid) from public, anon;
grant execute on function fn_admin_journey_settings(uuid) to authenticated;

create or replace function fn_admin_journey_settings_save(p_branch uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s branch_journey_settings%rowtype; before jsonb; k text; t time; v_staff uuid; v_out branch_journey_settings%rowtype;
begin
  perform fn_require_cap('branch.settings');
  perform fn_require_branch(p_branch);
  select * into s from branch_journey_settings where branch_id = p_branch for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform fn_check_version_strict(s.version, nullif(p->>'version', '')::int);
  before := to_jsonb(s);
  if p ? 'journey_enabled' then
    if jsonb_typeof(p->'journey_enabled') <> 'boolean' then raise exception 'VALIDATION: journey_enabled'; end if;
    s.journey_enabled := (p->>'journey_enabled')::boolean;
  end if;
  foreach k in array array['checkout_message_time', 'free_checkout_until'] loop
    if p ? k then
      if coalesce(p->>k, '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then raise exception 'VALIDATION: journey_time'; end if;
      t := (p->>k)::time;
      if k = 'checkout_message_time' then s.checkout_message_time := t; else s.free_checkout_until := t; end if;
    end if;
  end loop;
  if s.free_checkout_until <= s.checkout_message_time then raise exception 'VALIDATION: journey_time'; end if;
  if s.free_checkout_until < (select check_out_time from branches where id = p_branch) then raise exception 'VALIDATION: free_checkout_until'; end if;
  if p ? 'late_hour_price_halalas' then
    if coalesce(p->>'late_hour_price_halalas', '') !~ '^[0-9]{1,7}$' or (p->>'late_hour_price_halalas')::bigint > 1000000 then raise exception 'VALIDATION: amount'; end if;
    s.late_hour_price_halalas := (p->>'late_hour_price_halalas')::bigint;
  end if;
  if p ? 'cleaning_buffer_minutes' then
    if coalesce(p->>'cleaning_buffer_minutes', '') !~ '^[0-9]{1,3}$' or (p->>'cleaning_buffer_minutes')::int > 240 then raise exception 'VALIDATION: cleaning_buffer'; end if;
    s.cleaning_buffer_minutes := (p->>'cleaning_buffer_minutes')::int;
  end if;
  if p ? 'hold_minutes' then
    if coalesce(p->>'hold_minutes', '') !~ '^[0-9]{1,3}$' or (p->>'hold_minutes')::int not between 5 and 240 then raise exception 'VALIDATION: hold_minutes'; end if;
    s.hold_minutes := (p->>'hold_minutes')::int;
  end if;
  if p ? 'checkout_instructions' then
    s.checkout_instructions := nullif(btrim(coalesce(p->>'checkout_instructions', '')), '');
    if s.checkout_instructions is not null and char_length(s.checkout_instructions) > 1500 then raise exception 'VALIDATION: checkout_instructions'; end if;
  end if;
  if p ? 'deposit_refund_hours' then
    if coalesce(p->>'deposit_refund_hours', '') !~ '^[0-9]{1,2}$' or (p->>'deposit_refund_hours')::int not between 1 and 72 then raise exception 'VALIDATION: refund_hours'; end if;
    s.deposit_refund_hours := (p->>'deposit_refund_hours')::int;
  end if;
  if p ? 'review_delay_minutes' then
    if coalesce(p->>'review_delay_minutes', '') !~ '^[0-9]{1,4}$' or (p->>'review_delay_minutes')::int not between 10 and 1440 then raise exception 'VALIDATION: review_delay'; end if;
    s.review_delay_minutes := (p->>'review_delay_minutes')::int;
  end if;
  if p ? 'review_alert_below' then
    if coalesce(p->>'review_alert_below', '') !~ '^[0-9]{1,2}$' or (p->>'review_alert_below')::int not between 1 and 10 then raise exception 'VALIDATION: review_alert_below'; end if;
    s.review_alert_below := (p->>'review_alert_below')::int;
  end if;
  foreach k in array array['responsible_staff_id', 'fallback_staff_id'] loop
    if p ? k then
      v_staff := null;
      if nullif(p->>k, '') is not null then
        if p->>k !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then raise exception 'VALIDATION: journey_staff'; end if;
        select sp.id into v_staff from staff_profiles sp
         where sp.id = (p->>k)::uuid and sp.organization_id = fn_user_org_id() and sp.is_active and sp.role in ('owner', 'manager', 'supervisor')
           and (k = 'fallback_staff_id' or sp.role = 'owner' or exists (select 1 from branch_memberships m where m.staff_id = sp.id and m.branch_id = p_branch and m.removed_at is null));
        if v_staff is null then raise exception 'VALIDATION: journey_staff'; end if;
      end if;
      if k = 'responsible_staff_id' then s.responsible_staff_id := v_staff; else s.fallback_staff_id := v_staff; end if;
    end if;
  end loop;
  update branch_journey_settings set journey_enabled = s.journey_enabled, checkout_message_time = s.checkout_message_time, free_checkout_until = s.free_checkout_until,
         late_hour_price_halalas = s.late_hour_price_halalas, cleaning_buffer_minutes = s.cleaning_buffer_minutes, hold_minutes = s.hold_minutes,
         checkout_instructions = s.checkout_instructions, deposit_refund_hours = s.deposit_refund_hours, review_delay_minutes = s.review_delay_minutes,
         review_alert_below = s.review_alert_below, responsible_staff_id = s.responsible_staff_id, fallback_staff_id = s.fallback_staff_id,
         version = version + 1, updated_by = fn_staff_id(), updated_at = now()
   where branch_id = p_branch returning * into v_out;
  perform fn_audit_change(p_branch, 'journey.settings_changed', 'journey_settings', p_branch, before - 'updated_at' - 'updated_by' - 'version',
                          to_jsonb(v_out) - 'updated_at' - 'updated_by' - 'version');
  return jsonb_build_object('ok', true, 'version', v_out.version);
end $$;
revoke all on function fn_admin_journey_settings_save(uuid, jsonb) from public, anon;
grant execute on function fn_admin_journey_settings_save(uuid, jsonb) to authenticated;

create or replace function fn_admin_alert_rules() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform fn_require_cap('branch.settings');
  return coalesce((select jsonb_agg(jsonb_build_object('event', r.event, 'label', fn_alert_event_label(r.event), 'enabled', r.enabled, 'recipients', to_jsonb(r.recipients),
                                                       'channel', r.channel, 'delay_minutes', r.delay_minutes, 'escalate_after_minutes', r.escalate_after_minutes,
                                                       'escalate_to', r.escalate_to, 'version', r.version)
                                    order by array_position(array['guest_departed', 'deposit_overdue', 'review_low', 'extension_requested', 'extension_unpaid',
                                                                  'product_order', 'guest_handoff', 'message_failed'], r.event))
                     from alert_rules r where r.organization_id = fn_user_org_id()), '[]'::jsonb);
end $$;
revoke all on function fn_admin_alert_rules() from public, anon;
grant execute on function fn_admin_alert_rules() to authenticated;

-- a rule is the owner's (who is told, and how, is a decision on people)
create or replace function fn_admin_alert_rule_save(p_event text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare rl alert_rules%rowtype; before jsonb; v_rec text[];
begin
  perform fn_require_role('owner');
  select * into rl from alert_rules where organization_id = fn_user_org_id() and event = p_event for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform fn_check_version_strict(rl.version, nullif(p->>'version', '')::int);
  before := to_jsonb(rl);
  if p ? 'enabled' then
    if jsonb_typeof(p->'enabled') <> 'boolean' then raise exception 'VALIDATION: alert_rule'; end if;
    rl.enabled := (p->>'enabled')::boolean;
  end if;
  if p ? 'recipients' then
    if jsonb_typeof(p->'recipients') <> 'array' then raise exception 'VALIDATION: alert_recipients'; end if;
    select array_agg(distinct x order by x) into v_rec from jsonb_array_elements_text(p->'recipients') x;
    if v_rec is null or cardinality(v_rec) not between 1 and 5 or not (v_rec <@ array['responsible', 'fallback', 'owner', 'manager', 'supervisor']) then
      raise exception 'VALIDATION: alert_recipients';
    end if;
    rl.recipients := v_rec;
  end if;
  if p ? 'channel' then
    if coalesce(p->>'channel', '') not in ('app', 'whatsapp', 'both') then raise exception 'VALIDATION: alert_channel'; end if;
    rl.channel := p->>'channel';
  end if;
  if p ? 'delay_minutes' then
    if coalesce(p->>'delay_minutes', '') !~ '^[0-9]{1,4}$' or (p->>'delay_minutes')::int > 1440 then raise exception 'VALIDATION: alert_delay'; end if;
    rl.delay_minutes := (p->>'delay_minutes')::int;
  end if;
  if p ? 'escalate_after_minutes' then
    if p->'escalate_after_minutes' = 'null'::jsonb then rl.escalate_after_minutes := null;
    elsif coalesce(p->>'escalate_after_minutes', '') !~ '^[0-9]{1,4}$' or (p->>'escalate_after_minutes')::int not between 1 and 1440 then raise exception 'VALIDATION: alert_escalation';
    else rl.escalate_after_minutes := (p->>'escalate_after_minutes')::int; end if;
  end if;
  if p ? 'escalate_to' then
    if coalesce(p->>'escalate_to', '') not in ('fallback', 'owner') then raise exception 'VALIDATION: alert_escalation'; end if;
    rl.escalate_to := p->>'escalate_to';
  end if;
  update alert_rules set enabled = rl.enabled, recipients = rl.recipients, channel = rl.channel, delay_minutes = rl.delay_minutes,
         escalate_after_minutes = rl.escalate_after_minutes, escalate_to = rl.escalate_to, version = version + 1, updated_by = fn_staff_id(), updated_at = now()
   where organization_id = rl.organization_id and event = rl.event returning * into rl;
  perform fn_audit_change(null, 'alert_rule.changed', 'alert_rule', null, before - 'updated_at' - 'updated_by' - 'version',
                          (to_jsonb(rl) - 'updated_at' - 'updated_by' - 'version') || jsonb_build_object('label', fn_alert_event_label(rl.event)));
  return jsonb_build_object('ok', true, 'version', rl.version);
end $$;
revoke all on function fn_admin_alert_rule_save(text, jsonb) from public, anon;
grant execute on function fn_admin_alert_rule_save(text, jsonb) to authenticated;

create or replace function fn_admin_set_guest_site(p_url text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v text := nullif(rtrim(btrim(coalesce(p_url, '')), '/'), ''); before text;
begin
  perform fn_require_role('owner');
  if v is not null and (not fn_valid_https_url(v) or char_length(v) > 200) then raise exception 'VALIDATION: guest_site_url'; end if;
  select guest_site_url into before from organizations where id = fn_user_org_id() for update;
  update organizations set guest_site_url = v where id = fn_user_org_id();
  perform fn_audit_change(null, 'journey.site_changed', 'organization', fn_user_org_id(), jsonb_build_object('guest_site_url', before), jsonb_build_object('guest_site_url', v));
  return jsonb_build_object('ok', true);
end $$;
revoke all on function fn_admin_set_guest_site(text) from public, anon;
grant execute on function fn_admin_set_guest_site(text) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 13. The log lines
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_audit_accounting_label(p_action text) returns text
language sql immutable set search_path = public as $$
  select case p_action
      when 'day_closing.created' then 'بدء إقفال يوم'
      when 'day_closing.submitted' then 'إرسال إقفال يوم'
      when 'day_closing.amended' then 'تعديل إقفال يوم خلال المهلة'
      when 'day_closing.edit_requested' then 'طلب تعديل إقفال بعد المهلة'
      when 'day_closing.edit_approved' then 'الموافقة على تعديل إقفال'
      when 'day_closing.edit_rejected' then 'رفض تعديل إقفال'
      when 'branch.day_close_rules_changed' then 'تغيير مهلة تعديل الإقفال'
      when 'expense.created' then 'إصدار سند صرف'
      when 'expense.cancelled' then 'إلغاء سند صرف'
      when 'expense_category.created' then 'إضافة تصنيف مصروف'
      when 'expense_category.updated' then 'تعديل تصنيف مصروف'
      when 'cash_account.opening_set' then 'تحديد الرصيد الافتتاحي'
      when 'accounting.month_locked' then 'قفل شهر محاسبي'
      when 'accounting.month_opened' then 'فتح شهر محاسبي'
      when 'bank_mail.settings_changed' then 'تعديل بريد البنك'
      when 'bank_rule.created' then 'إضافة قاعدة قراءة رسائل البنك'
      when 'bank_rule.updated' then 'تعديل قاعدة قراءة رسائل البنك'
      when 'bank_message.reparsed' then 'إعادة قراءة رسالة بنكية'
      when 'bank_movement.assigned' then 'نسبة حركة بنكية لحساب فرع'
      when 'bank_movement.matched' then 'مطابقة حركة بنكية'
      when 'bank_movement.unmatched' then 'فك مطابقة حركة بنكية'
      when 'bank_movement.converted' then 'تحويل حركة بنكية إلى سند'
      when 'product_category.created' then 'إضافة فئة منتجات'
      when 'product_category.updated' then 'تعديل فئة منتجات'
      when 'product.created' then 'إضافة منتج'
      when 'product.updated' then 'تعديل منتج'
      when 'product.availability_changed' then 'تغيير إتاحة منتج في فرع'
      when 'product_order.created' then 'طلب منتجات جديد'
      when 'product_order.added' then 'إضافة إلى طلب منتجات'
      when 'product_order.paid' then 'دفع طلب منتجات'
      when 'product_order.delivered' then 'تسليم طلب منتجات'
      when 'product_order.cancelled' then 'إلغاء طلب منتجات'
      when 'journey.settings_changed' then 'تعديل إعدادات رحلة الضيف'
      when 'journey.site_changed' then 'تعديل عنوان صفحات النزلاء'
      when 'journey.checkout_on_time' then 'اختيار النزيل الخروج في موعده'
      when 'journey.extension_held' then 'حجز تمديد أو خروج متأخر بطلب النزيل'
      when 'journey.extension_confirmed' then 'تثبيت تمديد دون دفعه الآن'
      when 'journey.extension_released' then 'إلغاء تمديد محجوز'
      when 'journey.guest_departed' then 'إبلاغ النزيل بمغادرته'
      when 'alert_rule.changed' then 'تعديل قاعدة تنبيه'
      when 'alert.resolved' then 'إغلاق تنبيه'
      when 'review.replied' then 'الرد على تقييم'
      else null
    end;
$$;
revoke all on function fn_audit_accounting_label(text) from public, anon;
grant execute on function fn_audit_accounting_label(text) to authenticated, service_role;
do $$
declare fn oid; def text; n int;
        old_e constant text := $a$when 'product_order' then 'طلب منتجات' end$a$;
        new_e constant text := $b$when 'product_order' then 'طلب منتجات' when 'extension_request' then 'طلب تمديد' when 'guest_review' then 'تقييم نزيل' when 'alert_rule' then 'قاعدة تنبيه' when 'alert_event' then 'تنبيه' when 'journey_settings' then 'إعدادات رحلة الضيف' end$b$;
begin
  select p.oid into fn from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'fn_audit_entity_label';
  def := pg_get_functiondef(fn);
  n := (length(def) - length(replace(def, old_e, ''))) / length(old_e);
  if n <> 1 then raise exception '0070: the closing line of fn_audit_entity_label was found % times, not once', n; end if;
  execute replace(def, old_e, new_e);
end $$;
