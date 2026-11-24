#!/usr/bin/env bash
# Shared by tests/sql/run.sh and scripts/migration-check.sh: a throwaway database shaped like a hosted Supabase
# project (extensions schema, auth shim, API roles and default grants, property time zone, test keys).
# Usage: source tests/sql/bootstrap.sh; bootstrap_db <name>
# The settings the suites depend on live on the DATABASE (ALTER DATABASE ... SET), and CREATE DATABASE ... TEMPLATE does NOT copy them.
# Every caller that clones a bootstrapped database must call this on the clone; assert_db_settings fails closed when one is missing.
apply_db_settings() {
local DB="$1"
psql -d "$DB" -v ON_ERROR_STOP=1 -q -c "alter database $DB set app.keybox_key = 'test-keybox-key'; alter database $DB set app.identity_key = 'test-identity-key';" -c "alter database $DB set search_path = \"\$user\", public, extensions;" -c "alter database $DB set timezone = 'Asia/Riyadh'; alter database $DB set request.headers = '{\"x-hotel-slug\":\"00000000-0000-0000-0000-000000000001\"}';"
}
assert_db_settings() {
local DB="$1" n
n=$(psql -Atq -d postgres -c "select count(*) from pg_db_role_setting s join pg_database d on d.oid=s.setdatabase, unnest(s.setconfig) c where d.datname='$DB' and s.setrole=0 and split_part(c,'=',1) in ('app.keybox_key','app.identity_key','search_path','TimeZone','request.headers')")
[ "$n" = 5 ] || { echo "DB SETTINGS MISSING on $DB: found $n of 5 (app.keybox_key, app.identity_key, search_path, TimeZone, request.headers)"; return 1; }
}
bootstrap_db() {
local DB="$1"
psql -v ON_ERROR_STOP=1 -q -c "drop database if exists $DB;" -c "create database $DB;"
psql -d "$DB" -v ON_ERROR_STOP=1 -q <<'EOF'
-- Mirror Supabase's extension layout: pgcrypto / uuid-ossp live in schema "extensions" (not public),
-- and the database search_path is "$user", public, extensions. A SECURITY DEFINER function pinned to
-- search_path = public cannot see them there — exactly as on a hosted project — so the tests catch it.
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;
-- Local shim for Supabase's auth schema and API roles
create schema if not exists auth;
create or replace function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid $$;
create or replace function auth.jwt() returns jsonb language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claims', true),'')::jsonb, '{}'::jsonb) $$;
-- the session tables as Supabase Auth keeps them (the columns 0040 reads and writes): a token's session_id names a
-- row here; a session the owner ended has not_after in the past and its refresh tokens revoked
create table if not exists auth.sessions (id uuid primary key, user_id uuid not null, created_at timestamptz default now(), updated_at timestamptz default now(),
  factor_id uuid, aal text, not_after timestamptz, refreshed_at timestamp, user_agent text, ip inet, tag text);
create table if not exists auth.refresh_tokens (id bigserial primary key, token varchar(255), user_id varchar(255), revoked boolean, created_at timestamptz default now(),
  updated_at timestamptz default now(), parent varchar(255), session_id uuid);
-- the columns of Supabase's auth.users that 0074 reads (an account exists, its e-mail confirmed, its last sign-in)
create table if not exists auth.users (id uuid primary key, email text, email_confirmed_at timestamptz, last_sign_in_at timestamptz,
  created_at timestamptz default now());
do $$ begin create role anon nologin; exception when duplicate_object then null; end $$;
do $$ begin create role authenticated nologin; exception when duplicate_object then null; end $$;
do $$ begin create role service_role nologin bypassrls; exception when duplicate_object then null; end $$;
grant usage on schema public to anon, authenticated, service_role;
grant usage on schema extensions to anon, authenticated, service_role;
-- Supabase default privileges: API roles get table grants; RLS does the filtering
grant all on all tables in schema public to anon, authenticated, service_role;
grant all on all sequences in schema public to anon, authenticated, service_role;
grant execute on all functions in schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant execute on functions to anon, authenticated, service_role;
-- The hosted project also keeps a leftover schema from a first attempt, zz_first_attempt: 24 empty tables named like
-- ours, with table privileges for the API roles (no USAGE on the schema, so the API cannot reach them). A catalog
-- lookup by table name alone finds those too and answers wrongly for public — 0033 skipped a grant that way (0035).
-- The test database keeps the same names, so such a lookup fails here as it does there.
create schema if not exists zz_first_attempt;
do $$ declare t text; begin
  foreach t in array array['access_delivery_events', 'access_release_requests', 'audit_events', 'booking_sources', 'branch_memberships',
                           'branches', 'cleaning_tasks', 'conversation_messages', 'conversations', 'guest_profiles', 'inventory_periods',
                           'keyboxes', 'maintenance_tickets', 'notifications', 'organizations', 'payment_transactions',
                           'registration_sessions', 'release_rules', 'released_slots', 'reservation_guests', 'reservations',
                           'room_categories', 'rooms', 'staff_profiles'] loop
    execute format('create table if not exists zz_first_attempt.%I (id uuid primary key)', t);
    execute format('grant all on zz_first_attempt.%I to anon, authenticated, service_role', t);
  end loop;
end $$;
EOF
# Fixtures write "today" as current_date and mean the property's day, so suite sessions run in the property's zone
# (set here, not taken from the machine: CI runners are UTC). The product itself must not depend on the session zone
# (UTC on a hosted project): PL09 keeps session-zone dates out of every function, and local_date_tests.sql runs in UTC.
apply_db_settings "$DB"
}
