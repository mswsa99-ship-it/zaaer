#!/usr/bin/env bash
# Shared by tests/sql/run.sh and scripts/migration-check.sh: a throwaway database shaped like a hosted Supabase
# project (extensions schema, auth shim, API roles and default grants, property time zone, test keys).
# Usage: source tests/sql/bootstrap.sh; bootstrap_db <name>
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
EOF
# Fixtures write "today" as current_date and mean the property's day, so suite sessions run in the property's zone
# (set here, not taken from the machine: CI runners are UTC). The product itself must not depend on the session zone
# (UTC on a hosted project): PL09 keeps session-zone dates out of every function, and local_date_tests.sql runs in UTC.
psql -d "$DB" -v ON_ERROR_STOP=1 -q -c "alter database $DB set app.keybox_key = 'test-keybox-key'; alter database $DB set app.identity_key = 'test-identity-key';" -c "alter database $DB set search_path = \"\$user\", public, extensions;" -c "alter database $DB set timezone = 'Asia/Riyadh';"
}
