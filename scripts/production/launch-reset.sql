-- =====================================================================
-- Production launch on the former staging project (run ONCE, by the owner, in the Supabase SQL Editor).
-- Keeps the property structure: organization, branches, blocks/floors, room categories, rooms, facilities,
-- prices, booking sources, policies, knowledge base, task types, services, staff and settings.
-- Removes everything that was demo traffic: guests, reservations, money, chats, tasks, AI logs.
-- Refuses to run once real work has started (more than 10 reservations or any voucher after launch day).
-- Not a migration: a fresh database built from supabase/migrations keeps its demo seed for the test suites.
-- =====================================================================
begin;

do $$ begin
  if (select count(*) from reservations) > 10 then
    raise exception 'launch-reset refused: % reservations exist — this database already has real work', (select count(*) from reservations);
  end if;
end $$;

-- staff copilot
delete from ai_action_proposals;
delete from ai_ops_conversations;            -- cascades ai_ops_messages
-- guest conversations and AI logs
delete from human_handoff_tickets;
delete from conversations;                   -- cascades messages, guardrail events, tool executions of chats
delete from ai_guardrail_events;
delete from ai_tool_executions;
delete from ai_usage_daily;
delete from unanswered_questions;
delete from guest_lookup_attempts;
delete from guest_phone_challenges;           -- «حجوزاتي» codes and phone sessions (0020)
delete from guest_phone_sessions;
delete from whatsapp_inbound_messages;        -- handled WhatsApp message ids (0021); the branch numbers themselves are settings and stay
delete from whatsapp_outbox;                  -- staff replies waiting for the reception computer (0023)
delete from integration_events;
delete from notifications;
-- operations
delete from housekeeping_tasks;
delete from maintenance_tickets;
delete from released_slots;
-- money (vouchers reference payments and each other: one statement each, children first)
delete from financial_vouchers;
delete from payment_transactions;
delete from reservation_charges;
delete from invoices;
-- stays and guests
delete from access_delivery_events;
delete from access_release_requests;
delete from registration_sessions;
delete from reservations;                    -- cascades allocations and reservation_guests
delete from guest_profiles;
-- numbering starts at 1 for real documents
delete from document_sequences;
-- units freed by the demo stays
update rooms set status = 'available' where status in ('occupied', 'reserved');

insert into audit_events (organization_id, action, entity_type, entity_id, details)
select id, 'system.production_launch', 'organization', id, jsonb_build_object('reason', 'production launch: demo guests, reservations, money and chats removed; structure kept')
from organizations;

commit;

select 'reservations' as t, count(*) from reservations
union all select 'guest_profiles', count(*) from guest_profiles
union all select 'financial_vouchers', count(*) from financial_vouchers
union all select 'conversations', count(*) from conversations
union all select 'rooms available', count(*) from rooms where status = 'available';
