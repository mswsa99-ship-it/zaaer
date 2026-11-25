-- =====================================================================
-- 0103 — item 7.1 (O4/T6): recorded backup and restore-drill state.
--
--  The acceptance: a weekly encrypted backup and one before every deploy, a monthly restore drill, and «آخر نسخة»
--  visible to the owner in admin. This migration is the verified state behind that page: every backup run and every
--  restore drill lands here, written only by the backup tooling (service_role), read by the owner alone through
--  fn_backup_status(). Staff clients can never write a row, and no API role reads the table directly.
--
--  The row stores evidence pointers (archive reference, sha256, sizes, how success was verified), never secrets:
--  no passphrases, no keys, no storage credentials, no connection strings.
-- =====================================================================

create table if not exists backup_runs (
  id uuid primary key default gen_random_uuid(),
  -- insertion order: started_at ties are normal (now() is the transaction clock), so ordering uses this
  seq bigint generated always as identity unique,
  organization_id uuid references organizations(id) on delete cascade,
  -- backup: an encrypted archive was produced; restore_drill: an archive was restored and compared (T6)
  kind text not null check (kind in ('backup', 'restore_drill')),
  reason text not null default 'scheduled' check (reason in ('scheduled', 'pre-deploy', 'manual', 'drill')),
  status text not null check (status in ('running', 'success', 'failed')),
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  -- archive file name or drill identifier; a reference, not a path with usernames or hosts
  run_ref text not null check (btrim(run_ref) <> '' and length(run_ref) <= 200 and run_ref !~ '[/\\]'),
  size_bytes bigint check (size_bytes is null or size_bytes >= 0),
  sha256 text check (sha256 is null or sha256 ~ '^[0-9a-f]{64}$'),
  tables_count int check (tables_count is null or tables_count >= 0),
  rows_total bigint check (rows_total is null or rows_total >= 0),
  -- how success was proven, e.g. 'manifest-hashes' or 'restore:counts+hashes identical'
  verification text check (verification is null or length(verification) <= 200),
  -- failure class only (e.g. 'pg_dump failed', 'upload failed', 'hash mismatch'); never credentials or paths
  error text check (error is null or length(error) <= 300),
  created_at timestamptz not null default now()
);
alter table backup_runs enable row level security;
-- No policies at all: no API role reads or writes the table directly. The functions below are the only doors.
revoke all on backup_runs from anon, authenticated;

-- the backup tooling opens a run; service_role only, never a staff session
create or replace function fn_backup_run_start(p_kind text, p_reason text, p_run_ref text, p_organization_id uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into backup_runs(kind, reason, status, run_ref, organization_id) values (p_kind, p_reason, 'running', p_run_ref, p_organization_id)
    returning id into v_id;
  return v_id;
end $$;
revoke all on function fn_backup_run_start(text, text, text, uuid) from public, anon, authenticated;
grant execute on function fn_backup_run_start(text, text, text, uuid) to service_role;

-- the backup tooling closes a run; a success must say how it was verified
create or replace function fn_backup_run_finish(p_id uuid, p_status text, p_size_bytes bigint default null,
  p_sha256 text default null, p_tables_count int default null, p_rows_total bigint default null,
  p_verification text default null, p_error text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_status not in ('success','failed') then raise exception 'VALIDATION: terminal status required' using errcode='22023'; end if;
  if p_status = 'success' and (p_verification is null or btrim(p_verification) = '') then
    raise exception 'VALIDATION: a success must name its verification' using errcode = '22023';
  end if;
  if p_status = 'success' and exists (select 1 from backup_runs where id=p_id and kind='backup')
     and (p_sha256 is null or p_size_bytes is null or p_tables_count is null or p_rows_total is null) then
    raise exception 'VALIDATION: backup evidence required' using errcode='22023';
  end if;
  if p_status = 'failed' and (p_error is null or btrim(p_error) = '') then
    raise exception 'VALIDATION: a failure must name its error class' using errcode = '22023';
  end if;
  update backup_runs set status = p_status, finished_at = now(), size_bytes = p_size_bytes, sha256 = p_sha256,
    tables_count = p_tables_count, rows_total = p_rows_total, verification = p_verification, error = p_error
  where id = p_id and status = 'running';
  if not found then raise exception 'VALIDATION: no running backup run with that id' using errcode = '22023'; end if;
end $$;
revoke all on function fn_backup_run_finish(uuid, text, bigint, text, int, bigint, text, text) from public, anon, authenticated;
grant execute on function fn_backup_run_finish(uuid, text, bigint, text, int, bigint, text, text) to service_role;

-- «آخر نسخة» for the owner: the last successful backup, the latest run whatever happened, the last restore drill,
-- and any failures since that success. Owner only, the server enforces it.
create or replace function fn_backup_status() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_last_success backup_runs%rowtype; v_last_run backup_runs%rowtype; v_last_drill backup_runs%rowtype;
        v_failures int;
begin
  perform fn_require_role('owner');
  select * into v_last_success from backup_runs where organization_id = fn_user_org_id() and kind = 'backup' and status = 'success'
    order by seq desc limit 1;
  select * into v_last_run from backup_runs where organization_id = fn_user_org_id() and kind = 'backup' order by seq desc limit 1;
  select * into v_last_drill from backup_runs where organization_id = fn_user_org_id() and kind = 'restore_drill' order by seq desc limit 1;
  select count(*) into v_failures from backup_runs where organization_id = fn_user_org_id() and kind = 'backup' and status = 'failed'
    and seq > coalesce(v_last_success.seq, 0);
  return jsonb_build_object(
    'last_success', case when v_last_success.id is null then null else jsonb_build_object(
      'finished_at', v_last_success.finished_at, 'run_ref', v_last_success.run_ref,
      'size_bytes', v_last_success.size_bytes, 'sha256', v_last_success.sha256,
      'tables_count', v_last_success.tables_count, 'rows_total', v_last_success.rows_total,
      'reason', v_last_success.reason, 'verification', v_last_success.verification) end,
    'last_run', case when v_last_run.id is null then null else jsonb_build_object(
      'started_at', v_last_run.started_at, 'finished_at', v_last_run.finished_at,
      'status', v_last_run.status, 'reason', v_last_run.reason, 'error', v_last_run.error) end,
    'last_restore_drill', case when v_last_drill.id is null then null else jsonb_build_object(
      'started_at', v_last_drill.started_at, 'finished_at', v_last_drill.finished_at,
      'status', v_last_drill.status, 'verification', v_last_drill.verification, 'error', v_last_drill.error) end,
    'failures_since_last_success', v_failures);
end $$;
revoke all on function fn_backup_status() from public, anon;
grant execute on function fn_backup_status() to authenticated;
