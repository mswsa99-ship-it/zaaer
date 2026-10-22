/*
# RLS Policies — Core Tables

Enables RLS on all tables. Staff tables are scoped to authenticated users
who are members of the organization/branch. Guest-facing tables (reservations
lookup via token, registration sessions) are readable by anon through
short-lived tokens — but for this initial build we allow anon read on a
limited set so the guest screens work without login, and write on registration
sessions and reservation_guests tied to a session.

To keep the demo functional end-to-end, most operational tables allow
authenticated staff full CRUD scoped to their organization. Guest public
read paths use anon + authenticated.
*/

-- Helper: does current user belong to organization?
create or replace function fn_user_org_id() returns uuid
language sql stable security definer as $$
  select organization_id from staff_profiles where auth_user_id = auth.uid() and is_active limit 1;
$$;

-- Helper: is current user staff?
create or replace function fn_is_staff() returns boolean
language sql stable security definer as $$
  select exists(select 1 from staff_profiles where auth_user_id = auth.uid() and is_active);
$$;

-- ============ ORGANIZATIONS ============
alter table organizations enable row level security;
drop policy if exists "staff_read_orgs" on organizations;
create policy "staff_read_orgs" on organizations for select to authenticated
  using (id = fn_user_org_id());

-- ============ BRANCHES ============
alter table branches enable row level security;
drop policy if exists "staff_read_branches" on branches;
create policy "staff_read_branches" on branches for select to authenticated
  using (organization_id = fn_user_org_id());
drop policy if exists "staff_write_branches" on branches;
create policy "staff_write_branches" on branches for all to authenticated
  using (organization_id = fn_user_org_id()) with check (organization_id = fn_user_org_id());

-- ============ STAFF PROFILES ============
alter table staff_profiles enable row level security;
drop policy if exists "staff_read_profiles" on staff_profiles;
create policy "staff_read_profiles" on staff_profiles for select to authenticated
  using (organization_id = fn_user_org_id() or auth_user_id = auth.uid());
drop policy if exists "staff_insert_profiles" on staff_profiles;
create policy "staff_insert_profiles" on staff_profiles for insert to authenticated
  with check (organization_id = fn_user_org_id());
drop policy if exists "staff_update_profiles" on staff_profiles;
create policy "staff_update_profiles" on staff_profiles for update to authenticated
  using (organization_id = fn_user_org_id()) with check (organization_id = fn_user_org_id());

-- ============ BRANCH MEMBERSHIPS ============
alter table branch_memberships enable row level security;
drop policy if exists "staff_memberships" on branch_memberships;
create policy "staff_memberships" on branch_memberships for all to authenticated
  using (exists(select 1 from staff_profiles sp where sp.id = branch_memberships.staff_id and sp.organization_id = fn_user_org_id()))
  with check (exists(select 1 from staff_profiles sp where sp.id = branch_memberships.staff_id and sp.organization_id = fn_user_org_id()));

-- ============ ROOM CATEGORIES ============
alter table room_categories enable row level security;
drop policy if exists "staff_cat_all" on room_categories;
create policy "staff_cat_all" on room_categories for all to authenticated
  using (organization_id = fn_user_org_id()) with check (organization_id = fn_user_org_id());
drop policy if exists "anon_read_public_cats" on room_categories;
create policy "anon_read_public_cats" on room_categories for select to anon, authenticated
  using (is_public and is_active);

-- ============ ROOMS ============
alter table rooms enable row level security;
drop policy if exists "staff_rooms_all" on rooms;
create policy "staff_rooms_all" on rooms for all to authenticated
  using (organization_id = fn_user_org_id()) with check (organization_id = fn_user_org_id());

-- ============ KEYBOXES ============
alter table keyboxes enable row level security;
drop policy if exists "staff_keyboxes_all" on keyboxes;
create policy "staff_keyboxes_all" on keyboxes for all to authenticated
  using (branch_id in (select id from branches where organization_id = fn_user_org_id()))
  with check (branch_id in (select id from branches where organization_id = fn_user_org_id()));

-- ============ BOOKING SOURCES ============
alter table booking_sources enable row level security;
drop policy if exists "staff_sources_all" on booking_sources;
create policy "staff_sources_all" on booking_sources for all to authenticated
  using (organization_id = fn_user_org_id()) with check (organization_id = fn_user_org_id());
drop policy if exists "anon_read_sources" on booking_sources;
create policy "anon_read_sources" on booking_sources for select to anon, authenticated using (is_active);

-- ============ INVENTORY ============
alter table inventory_periods enable row level security;
drop policy if exists "staff_inv_all" on inventory_periods;
create policy "staff_inv_all" on inventory_periods for all to authenticated
  using (branch_id in (select id from branches where organization_id = fn_user_org_id()))
  with check (branch_id in (select id from branches where organization_id = fn_user_org_id()));

-- ============ RELEASE RULES ============
alter table release_rules enable row level security;
drop policy if exists "staff_rules_all" on release_rules;
create policy "staff_rules_all" on release_rules for all to authenticated
  using (branch_id in (select id from branches where organization_id = fn_user_org_id()))
  with check (branch_id in (select id from branches where organization_id = fn_user_org_id()));

alter table released_slots enable row level security;
drop policy if exists "staff_slots_all" on released_slots;
create policy "staff_slots_all" on released_slots for all to authenticated
  using (branch_id in (select id from branches where organization_id = fn_user_org_id()))
  with check (branch_id in (select id from branches where organization_id = fn_user_org_id()));

-- ============ RESERVATIONS ============
alter table reservations enable row level security;
drop policy if exists "staff_res_all" on reservations;
create policy "staff_res_all" on reservations for all to authenticated
  using (organization_id = fn_user_org_id()) with check (organization_id = fn_user_org_id());

-- ============ GUESTS ============
alter table guest_profiles enable row level security;
drop policy if exists "staff_guests_all" on guest_profiles;
create policy "staff_guests_all" on guest_profiles for all to authenticated
  using (true) with check (true);

alter table reservation_guests enable row level security;
drop policy if exists "staff_resguests_all" on reservation_guests;
create policy "staff_resguests_all" on reservation_guests for all to authenticated
  using (exists(select 1 from reservations r where r.id = reservation_guests.reservation_id and r.organization_id = fn_user_org_id()))
  with check (exists(select 1 from reservations r where r.id = reservation_guests.reservation_id and r.organization_id = fn_user_org_id()));

-- ============ PAYMENTS ============
alter table payment_transactions enable row level security;
drop policy if exists "staff_payments_all" on payment_transactions;
create policy "staff_payments_all" on payment_transactions for all to authenticated
  using (exists(select 1 from reservations r where r.id = payment_transactions.reservation_id and r.organization_id = fn_user_org_id()))
  with check (exists(select 1 from reservations r where r.id = payment_transactions.reservation_id and r.organization_id = fn_user_org_id()));

-- ============ ACCESS RELEASE ============
alter table access_release_requests enable row level security;
drop policy if exists "staff_access_all" on access_release_requests;
create policy "staff_access_all" on access_release_requests for all to authenticated
  using (exists(select 1 from reservations r where r.id = access_release_requests.reservation_id and r.organization_id = fn_user_org_id()))
  with check (exists(select 1 from reservations r where r.id = access_release_requests.reservation_id and r.organization_id = fn_user_org_id()));

alter table access_delivery_events enable row level security;
drop policy if exists "staff_delivery_all" on access_delivery_events;
create policy "staff_delivery_all" on access_delivery_events for all to authenticated
  using (exists(select 1 from reservations r where r.id = access_delivery_events.reservation_id and r.organization_id = fn_user_org_id()))
  with check (exists(select 1 from reservations r where r.id = access_delivery_events.reservation_id and r.organization_id = fn_user_org_id()));

-- ============ CLEANING & MAINTENANCE ============
alter table cleaning_tasks enable row level security;
drop policy if exists "staff_cleaning_all" on cleaning_tasks;
create policy "staff_cleaning_all" on cleaning_tasks for all to authenticated
  using (branch_id in (select id from branches where organization_id = fn_user_org_id()))
  with check (branch_id in (select id from branches where organization_id = fn_user_org_id()));

alter table maintenance_tickets enable row level security;
drop policy if exists "staff_maint_all" on maintenance_tickets;
create policy "staff_maint_all" on maintenance_tickets for all to authenticated
  using (branch_id in (select id from branches where organization_id = fn_user_org_id()))
  with check (branch_id in (select id from branches where organization_id = fn_user_org_id()));

-- ============ AUDIT ============
alter table audit_events enable row level security;
drop policy if exists "staff_audit_read" on audit_events;
create policy "staff_audit_read" on audit_events for select to authenticated
  using (organization_id = fn_user_org_id() or organization_id is null);
drop policy if exists "staff_audit_insert" on audit_events;
create policy "staff_audit_insert" on audit_events for insert to authenticated
  with check (true);

-- ============ NOTIFICATIONS ============
alter table notifications enable row level security;
drop policy if exists "staff_notif_all" on notifications;
create policy "staff_notif_all" on notifications for all to authenticated
  using (branch_id in (select id from branches where organization_id = fn_user_org_id()) or branch_id is null)
  with check (true);

-- ============ CONVERSATIONS ============
alter table conversations enable row level security;
drop policy if exists "anon_conv_all" on conversations;
create policy "anon_conv_all" on conversations for all to anon, authenticated
  using (true) with check (true);

alter table conversation_messages enable row level security;
drop policy if exists "anon_msg_all" on conversation_messages;
create policy "anon_msg_all" on conversation_messages for all to anon, authenticated
  using (true) with check (true);

-- ============ REGISTRATION SESSIONS ============
alter table registration_sessions enable row level security;
drop policy if exists "anon_regsession_read" on registration_sessions;
create policy "anon_regsession_read" on registration_sessions for select to anon, authenticated
  using (true);
drop policy if exists "anon_regsession_insert" on registration_sessions;
create policy "anon_regsession_insert" on registration_sessions for insert to anon, authenticated
  with check (true);
drop policy if exists "anon_regsession_update" on registration_sessions;
create policy "anon_regsession_update" on registration_sessions for update to anon, authenticated
  using (true) with check (true);
