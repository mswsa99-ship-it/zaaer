/*
# AI Receptionist — Core Schema

Creates the foundational schema for a hospitality reception system:
organizations, branches, room categories, rooms, keyboxes, booking sources,
reservations, guests, identity records, payments, access release, and audit.

All tenant-scoped tables carry organization_id + branch_id for RLS isolation.
UUIDs everywhere. Money stored as integer halalas (SAR * 100) for exactness.
*/

-- ============ EXTENSIONS ============
create extension if not exists "uuid-ossp";
create extension if not exists pgcrypto;

-- ============ ENUMS ============
do $$ begin
  create type role_code as enum ('owner','manager','supervisor','finance','housekeeping','guest');
exception when duplicate_object then null; end $$;

do $$ begin
  create type reservation_status as enum ('draft','pending_verification','confirmed','checked_in','checked_out','closed','cancelled','rejected');
exception when duplicate_object then null; end $$;

do $$ begin
  create type guest_verification_status as enum ('not_started','data_submitted','pending_supervisor','verified','rejected');
exception when duplicate_object then null; end $$;

do $$ begin
  create type payment_status as enum ('pending','processing','paid','failed','partially_paid','refunded');
exception when duplicate_object then null; end $$;

do $$ begin
  create type access_status as enum ('locked','eligibility_review','approved','delivery_pending','delivered','acknowledged');
exception when duplicate_object then null; end $$;

do $$ begin
  create type room_status as enum ('available','reserved','occupied','cleaning','maintenance','blocked','out_of_service','ready');
exception when duplicate_object then null; end $$;

do $$ begin
  create type identity_type as enum ('national_id','iqama','passport','gcc_id');
exception when duplicate_object then null; end $$;

do $$ begin
  create type payment_method as enum ('booking_platform','payment_link','pos');
exception when duplicate_object then null; end $$;

-- ============ ORGANIZATIONS & USERS ============
create table if not exists organizations (
  id uuid primary key default gen_random_uuid(),
  name_ar text not null,
  name_en text,
  license_number text,
  license_status text default 'active',
  created_at timestamptz default now()
);

create table if not exists branches (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  name_ar text not null,
  name_en text,
  city text,
  address text,
  map_url text,
  phone text,
  email text,
  check_in_time time default '16:00',
  check_out_time time default '12:00',
  logo_url text,
  is_active boolean default true,
  created_at timestamptz default now()
);

-- Staff profiles linked to auth.users
create table if not exists staff_profiles (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid unique,  -- references auth.users implicitly
  organization_id uuid not null references organizations(id) on delete cascade,
  full_name text not null,
  email text not null,
  phone text,
  role role_code not null default 'supervisor',
  is_active boolean default true,
  created_at timestamptz default now()
);

create table if not exists branch_memberships (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references staff_profiles(id) on delete cascade,
  branch_id uuid not null references branches(id) on delete cascade,
  created_at timestamptz default now(),
  unique (staff_id, branch_id)
);

-- ============ ROOMS ============
create table if not exists room_categories (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references branches(id) on delete cascade,
  organization_id uuid not null references organizations(id) on delete cascade,
  name_ar text not null,
  name_en text,
  description text,
  base_capacity int not null default 2,
  max_capacity int not null default 4,
  base_price_halalas bigint not null default 20000,
  amenities text[],
  is_public boolean default true,
  is_active boolean default true,
  sort_order int default 0,
  created_at timestamptz default now()
);

create table if not exists rooms (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references branches(id) on delete cascade,
  organization_id uuid not null references organizations(id) on delete cascade,
  category_id uuid not null references room_categories(id) on delete restrict,
  room_number text not null,
  floor int default 1,
  status room_status not null default 'available',
  created_at timestamptz default now(),
  unique (branch_id, room_number)
);

create index if not exists idx_rooms_branch_category on rooms(branch_id, category_id);
create index if not exists idx_rooms_status on rooms(status);

-- ============ KEYBOXES ============
-- code_encrypted holds the keybox combination encrypted with pgcrypto.
-- Only server-side / privileged roles should decrypt.
create table if not exists keyboxes (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references rooms(id) on delete cascade,
  branch_id uuid not null references branches(id) on delete cascade,
  code_encrypted bytea,
  code_version int default 1,
  code_status text default 'needs_change',  -- active | needs_change
  last_changed_at timestamptz,
  last_changed_by uuid,
  field_tested boolean default false,
  last_reservation_id uuid,
  requires_rotation boolean default true,
  created_at timestamptz default now()
);

-- ============ BOOKING SOURCES ============
create table if not exists booking_sources (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  name text not null,
  booking_url text,
  is_active boolean default true,
  created_at timestamptz default now()
);

-- ============ INVENTORY & RELEASE RULES ============
create table if not exists inventory_periods (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references branches(id) on delete cascade,
  category_id uuid not null references room_categories(id) on delete cascade,
  date date not null,
  total_units int not null default 0,
  publicly_visible_units int not null default 0,
  blocked_units int not null default 0,
  created_at timestamptz default now(),
  unique (branch_id, category_id, date)
);

create table if not exists release_rules (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references branches(id) on delete cascade,
  category_id uuid not null references room_categories(id) on delete cascade,
  enabled boolean default false,
  initial_public_release int not null default 1,
  release_increment int not null default 1,
  release_trigger text not null default 'access_delivered', -- access_delivered | confirmed | manual
  created_at timestamptz default now(),
  unique (branch_id, category_id)
);

-- Tracks which rooms have been "released" (made public) by the sequential rule
create table if not exists released_slots (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references branches(id) on delete cascade,
  category_id uuid not null references room_categories(id) on delete cascade,
  date date not null,
  released_count int not null default 0,
  updated_at timestamptz default now(),
  unique (branch_id, category_id, date)
);

-- ============ RESERVATIONS ============
create table if not exists reservations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid not null references branches(id) on delete cascade,
  internal_ref text unique not null default ('R-' || upper(left(encode(gen_random_bytes(6), 'hex'), 8))),
  external_ref text,
  source_id uuid references booking_sources(id),
  status reservation_status not null default 'pending_verification',
  booking_type text default 'individual',
  company_name text,
  visit_purpose text,
  check_in date not null,
  check_out date not null,
  adults int not null default 1,
  companions int not null default 0,
  room_category_id uuid references room_categories(id),
  room_id uuid references rooms(id),
  rent_amount_halalas bigint not null default 0,
  discount_halalas bigint default 0,
  addons_halalas bigint default 0,
  taxes_halalas bigint default 0,
  total_halalas bigint not null default 0,
  paid_halalas bigint default 0,
  payment_status payment_status not null default 'pending',
  identity_status guest_verification_status not null default 'not_started',
  government_registration boolean default false,
  access_status access_status not null default 'locked',
  keybox_delivered boolean default false,
  checkin_approved_by uuid,
  checkin_approved_at timestamptz,
  actual_check_in timestamptz,
  actual_check_out timestamptz,
  notes text,
  created_at timestamptz default now(),
  created_by uuid
);

create index if not exists idx_reservations_branch on reservations(branch_id);
create index if not exists idx_reservations_status on reservations(status);
create index if not exists idx_reservations_external on reservations(external_ref);
create index if not exists idx_reservations_dates on reservations(check_in, check_out);
create index if not exists idx_reservations_room on reservations(room_id);

-- Prevent overlapping confirmed reservations for the same room
create unique index if not exists uniq_reservation_room_overlap
  on reservations (room_id, check_in, check_out)
  where room_id is not null and status in ('confirmed','checked_in');

-- ============ GUESTS ============
create table if not exists guest_profiles (
  id uuid primary key default gen_random_uuid(),
  full_name text not null,
  phone text,
  nationality text,
  created_at timestamptz default now()
);

create table if not exists reservation_guests (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references reservations(id) on delete cascade,
  guest_profile_id uuid references guest_profiles(id),
  is_primary boolean default false,
  full_name text not null,
  identity_type identity_type,
  identity_number_encrypted bytea,  -- encrypted server-side
  identity_number_last4 text,
  identity_issue_number text,
  nationality text,
  birth_date date,
  phone text,
  phone_verified boolean default false,
  relationship text,
  verification_status guest_verification_status not null default 'not_started',
  data_submitted boolean default false,
  created_at timestamptz default now()
);

create index if not exists idx_resguests_reservation on reservation_guests(reservation_id);

-- ============ PAYMENTS ============
create table if not exists payment_transactions (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references reservations(id) on delete cascade,
  method payment_method not null,
  amount_halalas bigint not null,
  status payment_status not null default 'pending',
  provider text,
  provider_ref text,
  pos_ref text,
  verified_by uuid,
  verified_at timestamptz,
  idempotency_key text unique,
  created_at timestamptz default now()
);

create index if not exists idx_payments_reservation on payment_transactions(reservation_id);

-- ============ ACCESS RELEASE ============
create table if not exists access_release_requests (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references reservations(id) on delete cascade,
  status access_status not null default 'locked',
  evaluated_at timestamptz,
  denial_reason text,
  approved_by uuid,
  approved_at timestamptz,
  delivered_at timestamptz,
  created_at timestamptz default now()
);

create table if not exists access_delivery_events (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references reservations(id) on delete cascade,
  keybox_id uuid not null references keyboxes(id),
  channel text default 'screen',  -- screen | whatsapp | supervisor
  delivered_by uuid,
  acknowledged boolean default false,
  created_at timestamptz default now()
);

-- ============ CLEANING & MAINTENANCE ============
create table if not exists cleaning_tasks (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references rooms(id) on delete cascade,
  branch_id uuid not null references branches(id) on delete cascade,
  reservation_id uuid references reservations(id),
  status text default 'pending',  -- pending | in_progress | done
  assigned_to uuid,
  completed_at timestamptz,
  created_at timestamptz default now()
);

create table if not exists maintenance_tickets (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references rooms(id) on delete cascade,
  branch_id uuid not null references branches(id) on delete cascade,
  title text not null,
  description text,
  status text default 'open',  -- open | in_progress | resolved
  created_by uuid,
  created_at timestamptz default now()
);

-- ============ AUDIT LOG ============
create table if not exists audit_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid,
  branch_id uuid,
  actor_id uuid,
  action text not null,
  entity_type text,
  entity_id uuid,
  details jsonb,
  created_at timestamptz default now()
);

create index if not exists idx_audit_org on audit_events(organization_id);
create index if not exists idx_audit_branch on audit_events(branch_id);
create index if not exists idx_audit_entity on audit_events(entity_type, entity_id);

-- ============ NOTIFICATIONS ============
create table if not exists notifications (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid references branches(id) on delete cascade,
  audience text default 'supervisor',  -- supervisor | manager | guest
  title text not null,
  body text,
  link text,
  read_at timestamptz,
  created_at timestamptz default now()
);

-- ============ CONVERSATIONS (guest-facing chat) ============
create table if not exists conversations (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid references reservations(id) on delete set null,
  channel text default 'screen',  -- screen | whatsapp
  status text default 'active',  -- active | handed_off | closed
  created_at timestamptz default now()
);

create table if not exists conversation_messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references conversations(id) on delete cascade,
  sender text not null,  -- guest | assistant | supervisor
  content text not null,
  created_at timestamptz default now()
);

create index if not exists idx_messages_conversation on conversation_messages(conversation_id);

-- ============ REGISTRATION SESSIONS ============
create table if not exists registration_sessions (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references reservations(id) on delete cascade,
  token text unique not null default (upper(left(encode(gen_random_bytes(12), 'hex'), 16))),
  expires_at timestamptz not null default (now() + interval '24 hours'),
  used_at timestamptz,
  created_at timestamptz default now()
);

create index if not exists idx_regsession_token on registration_sessions(token);
