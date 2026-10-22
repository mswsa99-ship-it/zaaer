/*
# 0008 — AI operations assistant (staff copilot) + operational context

Principles:
  * The assistant READS through narrow, branch-scoped functions and NEVER writes directly.
  * Every write it wants becomes an `ai_action_proposals` row that a human must confirm.
    Confirmation calls the very same RPCs the UI uses, under the confirming staff's own role,
    so the AI cannot escalate privileges or bypass a gate.
  * No keybox codes, document numbers, or secrets are reachable by the assistant.
  * The deterministic context (fn_ai_ops_context) powers the briefing and the no-AI fallback.
*/

alter table ai_settings add column if not exists ops_enabled boolean not null default true;
alter table ai_settings add column if not exists ops_daily_request_limit int not null default 500;
alter table ai_settings add column if not exists briefing_with_insights boolean not null default true;

create table if not exists ai_ops_conversations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid not null references branches(id) on delete cascade,
  staff_id uuid not null references staff_profiles(id) on delete cascade,
  title text,
  created_at timestamptz default now(),
  last_message_at timestamptz default now()
);
create index if not exists idx_ai_ops_conv_staff on ai_ops_conversations(staff_id, last_message_at desc);

create table if not exists ai_ops_messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references ai_ops_conversations(id) on delete cascade,
  sender text not null check (sender in ('staff','assistant','system')),
  content text not null,
  meta jsonb,
  created_at timestamptz default now()
);
create index if not exists idx_ai_ops_msg_conv on ai_ops_messages(conversation_id, created_at);

create table if not exists ai_action_proposals (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid not null references branches(id) on delete cascade,
  conversation_id uuid references ai_ops_conversations(id) on delete set null,
  staff_id uuid not null references staff_profiles(id) on delete cascade,
  action text not null,
  args jsonb not null,
  summary text not null,
  status text not null default 'proposed' check (status in ('proposed','executed','rejected','failed','expired')),
  result jsonb,
  error text,
  created_at timestamptz default now(),
  expires_at timestamptz not null default (now() + interval '30 minutes'),
  decided_at timestamptz,
  decided_by uuid
);
create index if not exists idx_ai_proposals_staff on ai_action_proposals(staff_id, status, created_at desc);

alter table ai_ops_conversations enable row level security;
alter table ai_ops_messages enable row level security;
alter table ai_action_proposals enable row level security;
create policy "own_conv_select" on ai_ops_conversations for select to authenticated using (staff_id = fn_staff_id());
create policy "own_conv_insert" on ai_ops_conversations for insert to authenticated with check (staff_id = fn_staff_id() and branch_id in (select fn_user_branch_ids()) and organization_id = fn_user_org_id());
create policy "own_conv_update" on ai_ops_conversations for update to authenticated using (staff_id = fn_staff_id()) with check (staff_id = fn_staff_id());
create policy "own_msg_select" on ai_ops_messages for select to authenticated using (conversation_id in (select id from ai_ops_conversations where staff_id = fn_staff_id()));
create policy "own_msg_insert" on ai_ops_messages for insert to authenticated with check (conversation_id in (select id from ai_ops_conversations where staff_id = fn_staff_id()));
create policy "own_proposals_select" on ai_action_proposals for select to authenticated using (staff_id = fn_staff_id());

-- Allowed actions and the RPC each one maps to. Kept in SQL so the edge function cannot invent new ones.
create or replace function fn_ai_ops_allowed_actions() returns text[] language sql immutable as $$
  select array['create_task','complete_task','set_cleanliness','amend_stay','switch_room','cancel_reservation','no_show','create_receipt','create_deposit','add_service','create_invoice','assign_task'];
$$;
grant execute on function fn_ai_ops_allowed_actions() to authenticated;

-- Proposal creation (called by the edge function as the staff user, or by the UI)
create or replace function fn_ai_ops_propose(p_conversation uuid, p_action text, p_args jsonb, p_summary text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c ai_ops_conversations%rowtype; pid uuid;
begin
  if fn_staff_id() is null then raise exception 'FORBIDDEN: staff only' using errcode = '42501'; end if;
  if not (p_action = any(fn_ai_ops_allowed_actions())) then raise exception 'VALIDATION: action'; end if;
  if coalesce(trim(p_summary),'') = '' then raise exception 'VALIDATION: summary'; end if;
  select * into c from ai_ops_conversations where id = p_conversation and staff_id = fn_staff_id();
  if not found then raise exception 'NOT_FOUND: conversation'; end if;
  insert into ai_action_proposals(organization_id, branch_id, conversation_id, staff_id, action, args, summary)
  values (c.organization_id, c.branch_id, c.id, fn_staff_id(), p_action, p_args, left(p_summary, 400)) returning id into pid;
  return jsonb_build_object('ok', true, 'proposal_id', pid, 'requires_confirmation', true);
end $$;
grant execute on function fn_ai_ops_propose(uuid, text, jsonb, text) to authenticated;

-- Human confirmation: dispatches to the real RPCs under the confirming staff's role. Nothing else can execute a proposal.
create or replace function fn_ai_ops_execute_proposal(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p ai_action_proposals%rowtype; res jsonb; a jsonb; key text;
begin
  select * into p from ai_action_proposals where id = p_id for update;
  if not found or p.staff_id <> fn_staff_id() then raise exception 'FORBIDDEN: not your proposal' using errcode = '42501'; end if;
  if p.status <> 'proposed' then raise exception 'PROPOSAL_STATUS_INVALID'; end if;
  if p.expires_at < now() then
    update ai_action_proposals set status = 'expired', decided_at = now(), decided_by = fn_staff_id() where id = p.id;
    return jsonb_build_object('ok', false, 'error', 'PROPOSAL_EXPIRED');
  end if;
  perform fn_require_branch(p.branch_id);
  a := p.args;
  key := 'ai:' || p.id::text;   -- idempotent money ops keyed by the proposal itself
  begin
    case p.action
      when 'create_task'        then res := fn_hk_create_task(a || jsonb_build_object('description', coalesce(a->>'description','') || ' (اقتراح المساعد)'));
      when 'complete_task'      then res := fn_hk_complete_task((a->>'task_id')::uuid, a->>'note', null);
      when 'assign_task'        then res := fn_hk_assign_task((a->>'task_id')::uuid, (a->>'assignee_id')::uuid);
      when 'set_cleanliness'    then res := fn_hk_set_cleanliness((a->>'room_id')::uuid, a->>'state', coalesce(a->>'reason','اقتراح المساعد'));
      when 'amend_stay'         then res := fn_staff_amend_stay((a->>'reservation_id')::uuid, (a->>'new_check_out')::date, coalesce(a->>'pricing_mode','keep_rate'), coalesce(a->>'reason', p.summary), null);
      when 'switch_room'        then res := fn_staff_switch_room((a->>'reservation_id')::uuid, (a->>'room_id')::uuid, (a->>'effective')::date, coalesce(a->>'reason', p.summary), null);
      when 'cancel_reservation' then res := fn_staff_cancel_reservation((a->>'reservation_id')::uuid, coalesce(a->>'reason', p.summary), 'staff', null);
      when 'no_show'            then res := fn_staff_no_show((a->>'reservation_id')::uuid, coalesce(a->>'reason', p.summary));
      when 'create_receipt'     then res := fn_create_voucher(jsonb_build_object('reservation_id', a->>'reservation_id', 'kind', 'receipt', 'amount_halalas', (a->>'amount_halalas')::bigint, 'method', a->>'method', 'reference', a->>'reference', 'note', 'اقتراح المساعد', 'idempotency_key', key));
      when 'create_deposit'     then res := fn_create_voucher(jsonb_build_object('reservation_id', a->>'reservation_id', 'kind', 'deposit', 'amount_halalas', (a->>'amount_halalas')::bigint, 'method', a->>'method', 'reference', a->>'reference', 'note', 'اقتراح المساعد', 'idempotency_key', key));
      when 'add_service'        then res := fn_staff_add_service((a->>'reservation_id')::uuid, (a->>'service_id')::uuid, coalesce((a->>'quantity')::numeric, 1), null);
      when 'create_invoice'     then res := fn_create_invoice((a->>'reservation_id')::uuid, null, null);
      else raise exception 'VALIDATION: action';
    end case;
  exception when others then
    -- record the failure on the proposal in an autonomous way: the outer transaction rolled back the business effect
    update ai_action_proposals set status = 'failed', error = left(sqlerrm, 300), decided_at = now(), decided_by = fn_staff_id() where id = p.id;
    return jsonb_build_object('ok', false, 'error', left(sqlerrm, 300));
  end;
  update ai_action_proposals set status = 'executed', result = res, decided_at = now(), decided_by = fn_staff_id() where id = p.id;
  perform fn_audit_change(p.branch_id, 'ai_proposal.executed', 'ai_action_proposal', p.id, null, jsonb_build_object('action', p.action, 'summary', p.summary, 'result', res));
  return jsonb_build_object('ok', true, 'result', res);
end $$;
grant execute on function fn_ai_ops_execute_proposal(uuid) to authenticated;

create or replace function fn_ai_ops_reject_proposal(p_id uuid, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  update ai_action_proposals set status = 'rejected', error = p_reason, decided_at = now(), decided_by = fn_staff_id()
  where id = p_id and staff_id = fn_staff_id() and status = 'proposed';
  if not found then raise exception 'NOT_FOUND'; end if;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function fn_ai_ops_reject_proposal(uuid, text) to authenticated;

-- Compact operational context for a branch and date: feeds the briefing, the chat tools and the no-AI fallback.
-- Contains no document numbers, no phone numbers, no access codes.
create or replace function fn_ai_ops_context_at(p_branch uuid, p_date date) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when p_branch in (select fn_user_branch_ids()) then jsonb_build_object(
    'branch', (select jsonb_build_object('id', id, 'name', name_ar, 'check_in_time', check_in_time, 'check_out_time', check_out_time) from branches where id = p_branch),
    'summary', fn_ops_daily_summary(p_branch, p_date),
    'arrivals', (select coalesce(jsonb_agg(jsonb_build_object('reservation_id', r.id, 'ref', r.internal_ref, 'guest', (select full_name from reservation_guests g where g.reservation_id = r.id and g.is_primary limit 1),
                   'status', r.status, 'room', (select room_number from rooms where id = r.room_id), 'category', (select name_ar from room_categories where id = r.room_category_id),
                   'nights', r.check_out - r.check_in, 'identity_status', r.identity_status, 'payment_status', r.payment_status, 'balance_due', r.balance_due_halalas, 'access_status', r.access_status, 'source', (select name from booking_sources where id = r.source_id)) order by r.status, r.internal_ref), '[]'::jsonb)
                 from reservations r where r.branch_id = p_branch and r.check_in = p_date and r.status in ('confirmed','pending_verification','checked_in')),
    'overdue_arrivals', (select coalesce(jsonb_agg(jsonb_build_object('reservation_id', r.id, 'ref', r.internal_ref, 'check_in', r.check_in, 'days_late', p_date - r.check_in) order by r.check_in), '[]'::jsonb)
                 from reservations r where r.branch_id = p_branch and r.check_in < p_date and r.status in ('confirmed','pending_verification')),
    'departures', (select coalesce(jsonb_agg(jsonb_build_object('reservation_id', r.id, 'ref', r.internal_ref, 'guest', (select full_name from reservation_guests g where g.reservation_id = r.id and g.is_primary limit 1),
                   'room', (select room_number from rooms where id = r.room_id), 'balance_due', r.balance_due_halalas, 'deposit_balance', r.deposit_balance_halalas) order by r.internal_ref), '[]'::jsonb)
                 from reservations r where r.branch_id = p_branch and r.check_out = p_date and r.status = 'checked_in'),
    'overstays', (select coalesce(jsonb_agg(jsonb_build_object('reservation_id', r.id, 'ref', r.internal_ref, 'room', (select room_number from rooms where id = r.room_id), 'check_out', r.check_out, 'days_over', p_date - r.check_out, 'balance_due', r.balance_due_halalas) order by r.check_out), '[]'::jsonb)
                 from reservations r where r.branch_id = p_branch and r.check_out < p_date and r.status = 'checked_in'),
    'in_house_with_balance', (select coalesce(jsonb_agg(jsonb_build_object('reservation_id', r.id, 'ref', r.internal_ref, 'room', (select room_number from rooms where id = r.room_id), 'balance_due', r.balance_due_halalas) order by r.balance_due_halalas desc), '[]'::jsonb)
                 from reservations r where r.branch_id = p_branch and r.status = 'checked_in' and r.balance_due_halalas > 0),
    'checked_out_with_deposit', (select coalesce(jsonb_agg(jsonb_build_object('reservation_id', r.id, 'ref', r.internal_ref, 'deposit_balance', r.deposit_balance_halalas, 'checked_out_at', r.actual_check_out) order by r.actual_check_out), '[]'::jsonb)
                 from reservations r where r.branch_id = p_branch and r.status = 'checked_out' and r.deposit_balance_halalas > 0),
    'units_needing_attention', (select coalesce(jsonb_agg(jsonb_build_object('room_id', r.id, 'room', r.room_number, 'status', r.status, 'cleanliness', r.cleanliness,
                   'open_tasks', (select count(*) from housekeeping_tasks h where h.room_id = r.id and h.status in ('pending','in_progress')),
                   'keybox_ready', exists (select 1 from keyboxes k where k.room_id = r.id and k.code_status = 'active' and k.field_tested),
                   'next_arrival', (select min(a.from_date) from reservation_allocations a join reservations rs on rs.id = a.reservation_id where a.room_id = r.id and a.status = 'active' and rs.status in ('confirmed','pending_verification') and a.from_date >= p_date)) order by r.room_number), '[]'::jsonb)
                 from rooms r where r.branch_id = p_branch and r.is_active and r.archived_at is null and (r.cleanliness <> 'clean' or r.status in ('cleaning','maintenance'))),
    'open_tasks', (select coalesce(jsonb_agg(jsonb_build_object('task_id', h.id, 'target', coalesce((select room_number from rooms where id = h.room_id), (select name from facilities where id = h.facility_id)),
                   'type', h.task_type_name_snapshot, 'priority', h.priority, 'status', h.status, 'assignee', (select full_name from staff_profiles where id = h.assignee_id), 'since', h.created_at) order by h.priority desc, h.created_at), '[]'::jsonb)
                 from housekeeping_tasks h where h.branch_id = p_branch and h.status in ('pending','in_progress')),
    'open_tickets', (select coalesce(jsonb_agg(jsonb_build_object('ticket_id', t.id, 'kind', t.kind, 'created_at', t.created_at) order by t.created_at), '[]'::jsonb) from human_handoff_tickets t where t.branch_id = p_branch and t.status = 'open'),
    'staff_on_branch', (select coalesce(jsonb_agg(jsonb_build_object('staff_id', s.id, 'name', s.full_name, 'role', s.role)), '[]'::jsonb)
                 from staff_profiles s where s.is_active and (s.role = 'owner' and s.organization_id = fn_user_org_id() or exists (select 1 from branch_memberships m where m.staff_id = s.id and m.branch_id = p_branch))),
    'generated_at', now()
  ) end;
$$;
revoke all on function fn_ai_ops_context_at(uuid, date) from public, anon, authenticated;

-- Roles without money visibility (housekeeping) get the same context with every balance removed (G21: least data per role)
create or replace function fn_ai_ops_context(p_branch uuid, p_date date default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare ctx jsonb; strip text[] := array['balance_due','deposit_balance','payment_status'];
begin
  ctx := fn_ai_ops_context_at(p_branch, coalesce(p_date, fn_branch_today(p_branch)));
  if ctx is null or fn_has_role('owner','manager','supervisor','finance') then return ctx; end if;
  ctx := ctx - 'in_house_with_balance' - 'checked_out_with_deposit';
  ctx := jsonb_set(ctx, '{summary}', (ctx->'summary') - 'finance');
  ctx := jsonb_set(ctx, '{arrivals}', coalesce((select jsonb_agg(e - strip) from jsonb_array_elements(ctx->'arrivals') e), '[]'::jsonb));
  ctx := jsonb_set(ctx, '{departures}', coalesce((select jsonb_agg(e - strip) from jsonb_array_elements(ctx->'departures') e), '[]'::jsonb));
  ctx := jsonb_set(ctx, '{overstays}', coalesce((select jsonb_agg(e - strip) from jsonb_array_elements(ctx->'overstays') e), '[]'::jsonb));
  return ctx;
end $$;
grant execute on function fn_ai_ops_context(uuid, date) to authenticated;

-- Reservation search for the assistant: by ref / external ref / guest name; returns no phone/document data
create or replace function fn_ai_ops_find_reservation(p_branch uuid, p_query text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('reservation_id', r.id, 'ref', r.internal_ref, 'external_ref', r.external_ref, 'guest', (select full_name from reservation_guests g where g.reservation_id = r.id and g.is_primary limit 1),
           'status', r.status, 'check_in', r.check_in, 'check_out', r.check_out, 'room', (select room_number from rooms where id = r.room_id), 'category_id', r.room_category_id,
           'balance_due', r.balance_due_halalas, 'deposit_balance', r.deposit_balance_halalas, 'payment_status', r.payment_status, 'identity_status', r.identity_status, 'version', r.version) order by r.check_in desc), '[]'::jsonb)
  from (select * from reservations r where r.branch_id = p_branch and r.branch_id in (select fn_user_branch_ids())
          and (r.internal_ref ilike '%' || p_query || '%' or coalesce(r.external_ref,'') ilike '%' || p_query || '%'
               or exists (select 1 from reservation_guests g where g.reservation_id = r.id and g.full_name ilike '%' || p_query || '%')
               or exists (select 1 from rooms rm where rm.id = r.room_id and rm.room_number = p_query))
        order by r.check_in desc limit 8) r;
$$;
grant execute on function fn_ai_ops_find_reservation(uuid, text) to authenticated;

-- creator relation for ledger views (NOT VALID: existing rows are not re-checked; new rows must reference a staff profile)
alter table financial_vouchers drop constraint if exists financial_vouchers_created_by_fkey;
alter table financial_vouchers add constraint financial_vouchers_created_by_fkey foreign key (created_by) references staff_profiles(id) on delete set null not valid;
alter table housekeeping_tasks drop constraint if exists housekeeping_tasks_created_by_fkey;
alter table housekeeping_tasks add constraint housekeeping_tasks_created_by_fkey foreign key (created_by) references staff_profiles(id) on delete set null not valid;

-- settings for the operations assistant are editable by the owner through the same RPC
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
    ops_enabled = coalesce((p->>'ops_enabled')::boolean, ops_enabled),
    ops_daily_request_limit = coalesce((p->>'ops_daily_request_limit')::int, ops_daily_request_limit),
    briefing_with_insights = coalesce((p->>'briefing_with_insights')::boolean, briefing_with_insights),
    updated_by = fn_staff_id(), updated_at = now()
  where organization_id = fn_user_org_id();
  perform fn_audit(fn_user_org_id(), null, fn_staff_id(), 'ai_settings_updated', 'ai_settings', fn_user_org_id(), p - 'extra_instructions');
  return jsonb_build_object('ok', true);
end $$;
grant execute on function fn_admin_update_ai_settings(jsonb) to authenticated;

-- G04 / A13: never remove the last active owner of an organization (trigger-level, so it also covers direct updates)
create or replace function fn_guard_last_owner() returns trigger
language plpgsql security definer set search_path = public as $$
declare remaining int;
begin
  if tg_op = 'DELETE' or (old.role = 'owner' and old.is_active and (new.role <> 'owner' or not new.is_active)) then
    if old.role = 'owner' and old.is_active then
      select count(*) into remaining from staff_profiles where organization_id = old.organization_id and role = 'owner' and is_active and id <> old.id;
      if remaining = 0 then raise exception 'LAST_OWNER: cannot remove or demote the last active owner'; end if;
    end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
drop trigger if exists trg_guard_last_owner on staff_profiles;
create trigger trg_guard_last_owner before update or delete on staff_profiles for each row execute function fn_guard_last_owner();


-- Atomic usage accounting for the edge functions (service role only): concurrent requests no longer overwrite each other
create or replace function fn_ai_usage_bump(p_org uuid, p_day date, p_requests int default 0, p_tokens_in int default 0, p_tokens_out int default 0, p_fallbacks int default 0, p_blocks int default 0) returns jsonb
language plpgsql security definer set search_path = public as $$
declare row ai_usage_daily%rowtype;
begin
  insert into ai_usage_daily(organization_id, day, requests, tokens_in, tokens_out, fallbacks, guardrail_blocks)
  values (p_org, p_day, p_requests, p_tokens_in, p_tokens_out, p_fallbacks, p_blocks)
  on conflict (organization_id, day) do update set
    requests = ai_usage_daily.requests + excluded.requests, tokens_in = ai_usage_daily.tokens_in + excluded.tokens_in,
    tokens_out = ai_usage_daily.tokens_out + excluded.tokens_out, fallbacks = ai_usage_daily.fallbacks + excluded.fallbacks,
    guardrail_blocks = ai_usage_daily.guardrail_blocks + excluded.guardrail_blocks
  returning * into row;
  return to_jsonb(row);
end $$;
revoke all on function fn_ai_usage_bump(uuid, date, int, int, int, int, int) from public, anon, authenticated;
