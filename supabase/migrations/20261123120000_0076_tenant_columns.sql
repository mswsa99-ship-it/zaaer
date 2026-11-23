-- ============================================================================================================
-- 0076 — Every row says its hotel, and every branch row its branch (plan item 2.2; owner, 23 Nov 2026: many hotels,
-- many branches in each; one account belongs to one hotel). supabase/tenancy.json classifies the tables; the 31 whose
-- rows did not say their hotel (and, for 15 of them, their branch) get the columns here:
--   · 16 branch tables that had branch_id only get organization_id, from their branch;
--   · 12 tables found through a parent (a reservation, a conversation, a keybox, a day closing, a journal entry, an
--     assistant conversation) get organization_id and branch_id, from that parent;
--   · the guest's 3 (looking a booking up, the phone code, the phone session) get both columns, empty until the
--     guest's pages know which hotel they are on (item 2.6).
-- fn_tenant_fill, a trigger on each of the 28 with a branch or a parent, fills the two columns on every insert and
-- update and refuses a row that names a hotel or a branch other than its branch's or its parent's, and a row that
-- would move to another hotel. The columns stay empty only where the link itself is empty (a conversation not yet
-- tied to a branch, a notification for the whole hotel, a WhatsApp message from an unknown number, a journal entry of
-- the hotel as a whole). The rows of today are filled once; the tables' own triggers (a keybox's code state, a
-- journal entry's balance, a member leaving a branch) do not read the new columns, and no row's content changes.
-- The log (audit_events) had its two columns already, but some of its rows left the hotel empty — an expense category
-- created, a cash account opened with a branch: fn_audit_enrich now fills the hotel from the row's branch, else from
-- the staff member who acted, and the rows of today get it the same way (a system event with neither stays empty).
-- ============================================================================================================

create or replace function fn_tenant_fill() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_link uuid; v_org uuid; v_branch uuid; parent text := TG_ARGV[0];
begin
  -- on an update the caller did not touch the two columns: they follow the link again
  if TG_OP = 'UPDATE' then
    if NEW.organization_id is not distinct from OLD.organization_id then NEW.organization_id := null; end if;
    if parent <> 'branch' and NEW.branch_id is not distinct from OLD.branch_id then NEW.branch_id := null; end if;
  end if;
  if parent = 'branch' then
    if NEW.branch_id is null then
      if TG_OP = 'UPDATE' and NEW.organization_id is null then NEW.organization_id := OLD.organization_id; end if;
      return NEW;
    end if;
    select b.organization_id into v_org from branches b where b.id = NEW.branch_id;
    if NEW.organization_id is not null and NEW.organization_id is distinct from v_org then
      raise exception 'TENANT: the row''s hotel is not its branch''s' using errcode = '42501';
    end if;
  else
    v_link := (to_jsonb(NEW) ->> TG_ARGV[1])::uuid;
    if v_link is null then
      if TG_OP = 'UPDATE' then
        NEW.organization_id := coalesce(NEW.organization_id, OLD.organization_id);
        NEW.branch_id := coalesce(NEW.branch_id, OLD.branch_id);
      end if;
      return NEW;
    end if;
    execute format('select organization_id, branch_id from public.%I where id = $1', parent) into v_org, v_branch using v_link;
    if (NEW.organization_id is not null and NEW.organization_id is distinct from v_org)
       or (NEW.branch_id is not null and NEW.branch_id is distinct from v_branch) then
      raise exception 'TENANT: the row''s hotel or branch is not its parent''s (%)', parent using errcode = '42501';
    end if;
    NEW.branch_id := v_branch;
  end if;
  if TG_OP = 'UPDATE' and OLD.organization_id is not null and v_org is distinct from OLD.organization_id then
    raise exception 'TENANT: a row cannot move to another hotel' using errcode = '42501';
  end if;
  NEW.organization_id := v_org;
  return NEW;
end $$;
revoke all on function fn_tenant_fill() from public, anon, authenticated;

-- ---------------------------------------------------------------- the columns
alter table branch_media add column if not exists organization_id uuid references organizations(id);
alter table branch_memberships add column if not exists organization_id uuid references organizations(id);
alter table conversations add column if not exists organization_id uuid references organizations(id);
alter table day_closing_requests add column if not exists organization_id uuid references organizations(id);
alter table expense_attachments add column if not exists organization_id uuid references organizations(id);
alter table inventory_periods add column if not exists organization_id uuid references organizations(id);
alter table journey_ticks add column if not exists organization_id uuid references organizations(id);
alter table keyboxes add column if not exists organization_id uuid references organizations(id);
alter table maintenance_tickets add column if not exists organization_id uuid references organizations(id);
alter table monitor_runs add column if not exists organization_id uuid references organizations(id);
alter table notifications add column if not exists organization_id uuid references organizations(id);
alter table release_rules add column if not exists organization_id uuid references organizations(id);
alter table released_slots add column if not exists organization_id uuid references organizations(id);
alter table reservation_allocations add column if not exists organization_id uuid references organizations(id);
alter table whatsapp_inbound_messages add column if not exists organization_id uuid references organizations(id);
alter table whatsapp_outbox add column if not exists organization_id uuid references organizations(id);
alter table access_delivery_events add column if not exists organization_id uuid references organizations(id);
alter table access_delivery_events add column if not exists branch_id uuid references branches(id);
alter table access_release_requests add column if not exists organization_id uuid references organizations(id);
alter table access_release_requests add column if not exists branch_id uuid references branches(id);
alter table ai_guardrail_events add column if not exists organization_id uuid references organizations(id);
alter table ai_guardrail_events add column if not exists branch_id uuid references branches(id);
alter table ai_ops_messages add column if not exists organization_id uuid references organizations(id);
alter table ai_ops_messages add column if not exists branch_id uuid references branches(id);
alter table ai_tool_executions add column if not exists organization_id uuid references organizations(id);
alter table ai_tool_executions add column if not exists branch_id uuid references branches(id);
alter table code_rotation_events add column if not exists organization_id uuid references organizations(id);
alter table code_rotation_events add column if not exists branch_id uuid references branches(id);
alter table conversation_messages add column if not exists organization_id uuid references organizations(id);
alter table conversation_messages add column if not exists branch_id uuid references branches(id);
alter table day_closing_lines add column if not exists organization_id uuid references organizations(id);
alter table day_closing_lines add column if not exists branch_id uuid references branches(id);
alter table journal_lines add column if not exists organization_id uuid references organizations(id);
alter table journal_lines add column if not exists branch_id uuid references branches(id);
alter table payment_transactions add column if not exists organization_id uuid references organizations(id);
alter table payment_transactions add column if not exists branch_id uuid references branches(id);
alter table registration_sessions add column if not exists organization_id uuid references organizations(id);
alter table registration_sessions add column if not exists branch_id uuid references branches(id);
alter table reservation_guests add column if not exists organization_id uuid references organizations(id);
alter table reservation_guests add column if not exists branch_id uuid references branches(id);
alter table guest_lookup_attempts add column if not exists organization_id uuid references organizations(id);
alter table guest_lookup_attempts add column if not exists branch_id uuid references branches(id);
alter table guest_phone_challenges add column if not exists organization_id uuid references organizations(id);
alter table guest_phone_challenges add column if not exists branch_id uuid references branches(id);
alter table guest_phone_sessions add column if not exists organization_id uuid references organizations(id);
alter table guest_phone_sessions add column if not exists branch_id uuid references branches(id);

-- ---------------------------------------------------------------- today's rows, once
update branch_media x set organization_id = b.organization_id from branches b where b.id = x.branch_id and x.organization_id is distinct from b.organization_id;
update branch_memberships x set organization_id = b.organization_id from branches b where b.id = x.branch_id and x.organization_id is distinct from b.organization_id;
update conversations x set organization_id = b.organization_id from branches b where b.id = x.branch_id and x.organization_id is distinct from b.organization_id;
update day_closing_requests x set organization_id = b.organization_id from branches b where b.id = x.branch_id and x.organization_id is distinct from b.organization_id;
update expense_attachments x set organization_id = b.organization_id from branches b where b.id = x.branch_id and x.organization_id is distinct from b.organization_id;
update inventory_periods x set organization_id = b.organization_id from branches b where b.id = x.branch_id and x.organization_id is distinct from b.organization_id;
update journey_ticks x set organization_id = b.organization_id from branches b where b.id = x.branch_id and x.organization_id is distinct from b.organization_id;
update keyboxes x set organization_id = b.organization_id from branches b where b.id = x.branch_id and x.organization_id is distinct from b.organization_id;
update maintenance_tickets x set organization_id = b.organization_id from branches b where b.id = x.branch_id and x.organization_id is distinct from b.organization_id;
update monitor_runs x set organization_id = b.organization_id from branches b where b.id = x.branch_id and x.organization_id is distinct from b.organization_id;
update notifications x set organization_id = b.organization_id from branches b where b.id = x.branch_id and x.organization_id is distinct from b.organization_id;
update release_rules x set organization_id = b.organization_id from branches b where b.id = x.branch_id and x.organization_id is distinct from b.organization_id;
update released_slots x set organization_id = b.organization_id from branches b where b.id = x.branch_id and x.organization_id is distinct from b.organization_id;
update reservation_allocations x set organization_id = b.organization_id from branches b where b.id = x.branch_id and x.organization_id is distinct from b.organization_id;
update whatsapp_inbound_messages x set organization_id = b.organization_id from branches b where b.id = x.branch_id and x.organization_id is distinct from b.organization_id;
update whatsapp_outbox x set organization_id = b.organization_id from branches b where b.id = x.branch_id and x.organization_id is distinct from b.organization_id;
update access_delivery_events x set organization_id = p.organization_id, branch_id = p.branch_id from reservations p where p.id = x.reservation_id and (x.organization_id is distinct from p.organization_id or x.branch_id is distinct from p.branch_id);
update access_release_requests x set organization_id = p.organization_id, branch_id = p.branch_id from reservations p where p.id = x.reservation_id and (x.organization_id is distinct from p.organization_id or x.branch_id is distinct from p.branch_id);
update ai_guardrail_events x set organization_id = p.organization_id, branch_id = p.branch_id from conversations p where p.id = x.conversation_id and (x.organization_id is distinct from p.organization_id or x.branch_id is distinct from p.branch_id);
update ai_ops_messages x set organization_id = p.organization_id, branch_id = p.branch_id from ai_ops_conversations p where p.id = x.conversation_id and (x.organization_id is distinct from p.organization_id or x.branch_id is distinct from p.branch_id);
update ai_tool_executions x set organization_id = p.organization_id, branch_id = p.branch_id from conversations p where p.id = x.conversation_id and (x.organization_id is distinct from p.organization_id or x.branch_id is distinct from p.branch_id);
update code_rotation_events x set organization_id = p.organization_id, branch_id = p.branch_id from keyboxes p where p.id = x.keybox_id and (x.organization_id is distinct from p.organization_id or x.branch_id is distinct from p.branch_id);
update conversation_messages x set organization_id = p.organization_id, branch_id = p.branch_id from conversations p where p.id = x.conversation_id and (x.organization_id is distinct from p.organization_id or x.branch_id is distinct from p.branch_id);
update day_closing_lines x set organization_id = p.organization_id, branch_id = p.branch_id from day_closings p where p.id = x.closing_id and (x.organization_id is distinct from p.organization_id or x.branch_id is distinct from p.branch_id);
update journal_lines x set organization_id = p.organization_id, branch_id = p.branch_id from journal_entries p where p.id = x.entry_id and (x.organization_id is distinct from p.organization_id or x.branch_id is distinct from p.branch_id);
update payment_transactions x set organization_id = p.organization_id, branch_id = p.branch_id from reservations p where p.id = x.reservation_id and (x.organization_id is distinct from p.organization_id or x.branch_id is distinct from p.branch_id);
update registration_sessions x set organization_id = p.organization_id, branch_id = p.branch_id from reservations p where p.id = x.reservation_id and (x.organization_id is distinct from p.organization_id or x.branch_id is distinct from p.branch_id);
update reservation_guests x set organization_id = p.organization_id, branch_id = p.branch_id from reservations p where p.id = x.reservation_id and (x.organization_id is distinct from p.organization_id or x.branch_id is distinct from p.branch_id);

update audit_events x set organization_id = b.organization_id from branches b where x.organization_id is null and b.id = x.branch_id;
update audit_events x set organization_id = sp.organization_id from staff_profiles sp where x.organization_id is null and sp.id = x.actor_id;

-- the log fills the hotel itself from now on (one block added to the definition in force, once)
do $$
declare fn oid; def text; n int;
        old_p constant text := $a$  new.actor_id := coalesce(new.actor_id, fn_staff_id());$a$;
        new_p constant text := $b$  new.actor_id := coalesce(new.actor_id, fn_staff_id());
  -- the row's hotel (0076): from its branch, else from the staff member who acted
  if new.organization_id is null and new.branch_id is not null then
    select b.organization_id into new.organization_id from branches b where b.id = new.branch_id;
  end if;
  if new.organization_id is null and new.actor_id is not null then
    select sp.organization_id into new.organization_id from staff_profiles sp where sp.id = new.actor_id;
  end if;$b$;
begin
  select p.oid into fn from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'fn_audit_enrich';
  def := pg_get_functiondef(fn);
  if position('the row''s hotel (0076)' in def) > 0 then return; end if;
  n := (length(def) - length(replace(def, old_p, ''))) / length(old_p);
  if n <> 1 then raise exception '0076: the actor line of fn_audit_enrich was found % times, not once', n; end if;
  execute replace(def, old_p, new_p);
end $$;

-- the deferred checks those updates queued (a journal entry still balances) run now, so the tables can be altered
set constraints all immediate;

-- ---------------------------------------------------------------- required where the link is
alter table branch_media alter column organization_id set not null;
alter table branch_memberships alter column organization_id set not null;
alter table day_closing_requests alter column organization_id set not null;
alter table expense_attachments alter column organization_id set not null;
alter table inventory_periods alter column organization_id set not null;
alter table journey_ticks alter column organization_id set not null;
alter table keyboxes alter column organization_id set not null;
alter table maintenance_tickets alter column organization_id set not null;
alter table monitor_runs alter column organization_id set not null;
alter table release_rules alter column organization_id set not null;
alter table released_slots alter column organization_id set not null;
alter table reservation_allocations alter column organization_id set not null;
alter table whatsapp_outbox alter column organization_id set not null;
alter table access_delivery_events alter column organization_id set not null;
alter table access_delivery_events alter column branch_id set not null;
alter table access_release_requests alter column organization_id set not null;
alter table access_release_requests alter column branch_id set not null;
alter table ai_ops_messages alter column organization_id set not null;
alter table ai_ops_messages alter column branch_id set not null;
alter table code_rotation_events alter column organization_id set not null;
alter table code_rotation_events alter column branch_id set not null;
alter table day_closing_lines alter column organization_id set not null;
alter table day_closing_lines alter column branch_id set not null;
alter table journal_lines alter column organization_id set not null;
alter table payment_transactions alter column organization_id set not null;
alter table payment_transactions alter column branch_id set not null;
alter table registration_sessions alter column organization_id set not null;
alter table registration_sessions alter column branch_id set not null;
alter table reservation_guests alter column organization_id set not null;
alter table reservation_guests alter column branch_id set not null;

-- ---------------------------------------------------------------- filled and checked on every insert and update (first among each table's triggers)
create or replace trigger a_tenant_fill before insert or update on branch_media for each row execute function fn_tenant_fill('branch');
create or replace trigger a_tenant_fill before insert or update on branch_memberships for each row execute function fn_tenant_fill('branch');
create or replace trigger a_tenant_fill before insert or update on conversations for each row execute function fn_tenant_fill('branch');
create or replace trigger a_tenant_fill before insert or update on day_closing_requests for each row execute function fn_tenant_fill('branch');
create or replace trigger a_tenant_fill before insert or update on expense_attachments for each row execute function fn_tenant_fill('branch');
create or replace trigger a_tenant_fill before insert or update on inventory_periods for each row execute function fn_tenant_fill('branch');
create or replace trigger a_tenant_fill before insert or update on journey_ticks for each row execute function fn_tenant_fill('branch');
create or replace trigger a_tenant_fill before insert or update on keyboxes for each row execute function fn_tenant_fill('branch');
create or replace trigger a_tenant_fill before insert or update on maintenance_tickets for each row execute function fn_tenant_fill('branch');
create or replace trigger a_tenant_fill before insert or update on monitor_runs for each row execute function fn_tenant_fill('branch');
create or replace trigger a_tenant_fill before insert or update on notifications for each row execute function fn_tenant_fill('branch');
create or replace trigger a_tenant_fill before insert or update on release_rules for each row execute function fn_tenant_fill('branch');
create or replace trigger a_tenant_fill before insert or update on released_slots for each row execute function fn_tenant_fill('branch');
create or replace trigger a_tenant_fill before insert or update on reservation_allocations for each row execute function fn_tenant_fill('branch');
create or replace trigger a_tenant_fill before insert or update on whatsapp_inbound_messages for each row execute function fn_tenant_fill('branch');
create or replace trigger a_tenant_fill before insert or update on whatsapp_outbox for each row execute function fn_tenant_fill('branch');
create or replace trigger a_tenant_fill before insert or update on access_delivery_events for each row execute function fn_tenant_fill('reservations', 'reservation_id');
create or replace trigger a_tenant_fill before insert or update on access_release_requests for each row execute function fn_tenant_fill('reservations', 'reservation_id');
create or replace trigger a_tenant_fill before insert or update on ai_guardrail_events for each row execute function fn_tenant_fill('conversations', 'conversation_id');
create or replace trigger a_tenant_fill before insert or update on ai_ops_messages for each row execute function fn_tenant_fill('ai_ops_conversations', 'conversation_id');
create or replace trigger a_tenant_fill before insert or update on ai_tool_executions for each row execute function fn_tenant_fill('conversations', 'conversation_id');
create or replace trigger a_tenant_fill before insert or update on code_rotation_events for each row execute function fn_tenant_fill('keyboxes', 'keybox_id');
create or replace trigger a_tenant_fill before insert or update on conversation_messages for each row execute function fn_tenant_fill('conversations', 'conversation_id');
create or replace trigger a_tenant_fill before insert or update on day_closing_lines for each row execute function fn_tenant_fill('day_closings', 'closing_id');
create or replace trigger a_tenant_fill before insert or update on journal_lines for each row execute function fn_tenant_fill('journal_entries', 'entry_id');
create or replace trigger a_tenant_fill before insert or update on payment_transactions for each row execute function fn_tenant_fill('reservations', 'reservation_id');
create or replace trigger a_tenant_fill before insert or update on registration_sessions for each row execute function fn_tenant_fill('reservations', 'reservation_id');
create or replace trigger a_tenant_fill before insert or update on reservation_guests for each row execute function fn_tenant_fill('reservations', 'reservation_id');

-- ---------------------------------------------------------------- found by hotel (the rules of item 2.3 read these)
create index if not exists branch_media_org_idx on branch_media(organization_id);
create index if not exists branch_memberships_org_idx on branch_memberships(organization_id);
create index if not exists conversations_org_idx on conversations(organization_id);
create index if not exists day_closing_requests_org_idx on day_closing_requests(organization_id);
create index if not exists expense_attachments_org_idx on expense_attachments(organization_id);
create index if not exists inventory_periods_org_idx on inventory_periods(organization_id);
create index if not exists journey_ticks_org_idx on journey_ticks(organization_id);
create index if not exists keyboxes_org_idx on keyboxes(organization_id);
create index if not exists maintenance_tickets_org_idx on maintenance_tickets(organization_id);
create index if not exists monitor_runs_org_idx on monitor_runs(organization_id);
create index if not exists notifications_org_idx on notifications(organization_id);
create index if not exists release_rules_org_idx on release_rules(organization_id);
create index if not exists released_slots_org_idx on released_slots(organization_id);
create index if not exists reservation_allocations_org_idx on reservation_allocations(organization_id);
create index if not exists whatsapp_inbound_messages_org_idx on whatsapp_inbound_messages(organization_id);
create index if not exists whatsapp_outbox_org_idx on whatsapp_outbox(organization_id);
create index if not exists access_delivery_events_org_idx on access_delivery_events(organization_id);
create index if not exists access_release_requests_org_idx on access_release_requests(organization_id);
create index if not exists ai_guardrail_events_org_idx on ai_guardrail_events(organization_id);
create index if not exists ai_ops_messages_org_idx on ai_ops_messages(organization_id);
create index if not exists ai_tool_executions_org_idx on ai_tool_executions(organization_id);
create index if not exists code_rotation_events_org_idx on code_rotation_events(organization_id);
create index if not exists conversation_messages_org_idx on conversation_messages(organization_id);
create index if not exists day_closing_lines_org_idx on day_closing_lines(organization_id);
create index if not exists journal_lines_org_idx on journal_lines(organization_id);
create index if not exists payment_transactions_org_idx on payment_transactions(organization_id);
create index if not exists registration_sessions_org_idx on registration_sessions(organization_id);
create index if not exists reservation_guests_org_idx on reservation_guests(organization_id);
create index if not exists guest_lookup_attempts_org_idx on guest_lookup_attempts(organization_id);
create index if not exists guest_phone_challenges_org_idx on guest_phone_challenges(organization_id);
create index if not exists guest_phone_sessions_org_idx on guest_phone_sessions(organization_id);
create index if not exists access_delivery_events_branch_idx on access_delivery_events(branch_id);
create index if not exists access_release_requests_branch_idx on access_release_requests(branch_id);
create index if not exists ai_guardrail_events_branch_idx on ai_guardrail_events(branch_id);
create index if not exists ai_ops_messages_branch_idx on ai_ops_messages(branch_id);
create index if not exists ai_tool_executions_branch_idx on ai_tool_executions(branch_id);
create index if not exists code_rotation_events_branch_idx on code_rotation_events(branch_id);
create index if not exists conversation_messages_branch_idx on conversation_messages(branch_id);
create index if not exists day_closing_lines_branch_idx on day_closing_lines(branch_id);
create index if not exists journal_lines_branch_idx on journal_lines(branch_id);
create index if not exists payment_transactions_branch_idx on payment_transactions(branch_id);
create index if not exists registration_sessions_branch_idx on registration_sessions(branch_id);
create index if not exists reservation_guests_branch_idx on reservation_guests(branch_id);
create index if not exists guest_lookup_attempts_branch_idx on guest_lookup_attempts(branch_id);
create index if not exists guest_phone_challenges_branch_idx on guest_phone_challenges(branch_id);
create index if not exists guest_phone_sessions_branch_idx on guest_phone_sessions(branch_id);
