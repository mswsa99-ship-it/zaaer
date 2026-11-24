-- ============================================================================================================
-- 0102 / plan 2.12. خروج فندق — a hotel leaves the platform, by the owner's own hand and nobody else's:
--   1. fn_hotel_exit_export  — a full copy of everything that says this hotel: every tenancy table (0076's 106),
--      the hotel's registry row and its support grants, with a manifest of per-table row counts, column lists and
--      SHA-256 hashes. The copy is the restorable one: it stays after the deletion, in tables no browser role can
--      read (service_role only, like 0082's platform tables).
--   2. fn_hotel_exit_suspend — only after a completed export: the hotel is suspended (0082's status), every staff
--      session ends.
--   3. fn_hotel_exit_delete  — only suspended, only against a completed export whose counts and hashes still match
--      the live tables byte for byte, and only when the caller types the hotel's exact name and its id (name/ID
--      confirmation — never an e-mail address). The deletion is one transaction: it either removes every tenancy
--      row of the hotel or nothing happens.
--   4. fn_hotel_exit_restore — the owner who exported can put everything back from the archive while it is in
--      «deleted» state, with the same id confirmation; the registry row returns to the status it had at export.
--
-- Retained, deliberately (exported and hashed, never deleted):
--   · audit_events — 0088: «the data purge is the single sanctioned exception»; hotel exit does not open a second
--     one, so the chain (fn_audit_chain_verify) survives the exit intact;
--   · platform_events — immutable by 0082's trigger; the platform's own record of the exit itself;
--   · organizations — the registry row stays as a tombstone (its slug stays taken) holding exited_at and the
--     archive id; its personal content (licence, site URL, logo, English name) is scrubbed.
-- Auth accounts of the hotel's staff are removed with the exit (their ids and e-mails live in the archived
-- staff_profiles rows); on a hosted project their password/MFA state is Supabase-managed — scripts/hotel-exit/
-- documents re-inviting them after a restore.
-- The owner path deliberately does NOT use fn_session_ok: after the suspension the hotel is «suspended» and
-- fn_session_ok would lock the owner out of the very exit they are performing. The exit guard checks the owner's
-- staff row of this hotel and the session's own validity instead. No service_role in a browser: these are RPCs
-- under the owner's JWT; the CLI (scripts/hotel-exit) runs them the same way, never with a service key client-side.
-- ============================================================================================================

create table if not exists hotel_exit_archives(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  hotel_name text not null,
  requested_by uuid not null,
  requested_at timestamptz not null default now(),
  status text not null default 'completed' check (status in ('completed','superseded','deleted','restored')),
  prior_platform_status text not null,
  table_count int not null,
  row_count bigint not null,
  overall_sha256 text not null,
  manifest jsonb not null
);
create table if not exists hotel_exit_rows(
  archive_id uuid not null references hotel_exit_archives(id) on delete cascade,
  organization_id uuid not null references organizations(id),
  table_name text not null,
  row_seq int not null,
  row_data jsonb not null,
  primary key (archive_id, table_name, row_seq)
);
alter table hotel_exit_archives enable row level security;
alter table hotel_exit_rows enable row level security;
revoke all on hotel_exit_archives, hotel_exit_rows from anon, authenticated;
grant select, insert, update, delete on hotel_exit_archives, hotel_exit_rows to service_role;

alter table organizations add column if not exists exited_at timestamptz;
alter table organizations add column if not exists exit_archive_id uuid;

-- The last-owner guard's single sanctioned exception: the documented hotel-exit deletion opens it from inside
-- fn_hotel_exit_delete only (the same shape 0088 gave the audit log for fn_purge_run).
create or replace function fn_guard_last_owner() returns trigger
language plpgsql security definer set search_path = public as $$
declare remaining int;
begin
  if tg_op = 'DELETE' and current_setting('app.hotel_exit', true) = 'on' then return old; end if;
  if tg_op = 'DELETE' or (old.role = 'owner' and old.is_active and (new.role <> 'owner' or not new.is_active)) then
    if old.role = 'owner' and old.is_active then
      select count(*) into remaining from staff_profiles where organization_id = old.organization_id and role = 'owner' and is_active and id <> old.id;
      if remaining = 0 then raise exception 'LAST_OWNER: cannot remove or demote the last active owner'; end if;
    end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
revoke all on function fn_guard_last_owner() from public, anon, authenticated;

-- The 106 tenancy tables (supabase/tenancy.json hotel+branch scopes) in a deletion order: a table always follows
-- the tables it references (children first), so the plain loop below never meets a foreign key of its own hotel.
-- tests/hotel-exit checks the list against the live catalogue and the foreign-key graph. audit_events is listed
-- (it is exported, and the coverage check wants it) but marked retained: the delete and the restore skip it.
create or replace function fn_hotel_exit_tables() returns table(table_name text, seq int, retained boolean)
language sql immutable set search_path = public as $$
  select v.table_name, v.seq, v.table_name = 'audit_events'
  from (values
    ('stay_acknowledgements',1),
    ('reservation_charges',2),
    ('human_handoff_tickets',3),
    ('financial_vouchers',4),
    ('conversation_messages',5),
    ('ai_tool_executions',6),
    ('ai_guest_session_usage',7),
    ('ai_guardrail_events',8),
    ('stay_payment_exceptions',9),
    ('review_items',10),
    ('reservation_nights',11),
    ('reservation_guests',12),
    ('reservation_allocations',13),
    ('registration_sessions',14),
    ('payment_transactions',15),
    ('invoices',16),
    ('housekeeping_tasks',17),
    ('discount_approvals',18),
    ('conversations',19),
    ('code_rotation_events',20),
    ('checkout_inspections',21),
    ('access_release_requests',22),
    ('access_delivery_events',23),
    ('room_licenses',24),
    ('reservations',25),
    ('maintenance_tickets',26),
    ('keyboxes',27),
    ('branch_media_items',28),
    ('bank_match_items',29),
    ('rooms',30),
    ('product_order_lines',31),
    ('product_branches',32),
    ('journal_lines',33),
    ('facilities',34),
    ('expense_attachments',35),
    ('bank_matches',36),
    ('unanswered_questions',37),
    ('service_definitions',38),
    ('released_slots',39),
    ('release_rules',40),
    ('rate_calendar',41),
    ('products',42),
    ('pos_settlements',43),
    ('platform_payouts',44),
    ('inventory_periods',45),
    ('gl_accounts',46),
    ('floors',47),
    ('expense_vouchers',48),
    ('day_closing_requests',49),
    ('day_closing_lines',50),
    ('bank_movements',51),
    ('ai_ops_messages',52),
    ('ai_action_proposals',53),
    ('whatsapp_outbox',54),
    ('whatsapp_inbound_messages',55),
    ('task_types',56),
    ('stay_extension_requests',57),
    ('staff_saved_views',58),
    ('room_categories',59),
    ('role_permissions',60),
    ('property_policies',61),
    ('product_orders',62),
    ('product_categories',63),
    ('notifications',64),
    ('knowledge_entries',65),
    ('journal_entries',66),
    ('guest_reviews',67),
    ('guest_phone_sessions',68),
    ('guest_phone_challenges',69),
    ('guest_lookup_attempts',70),
    ('guest_bans',71),
    ('finance_control_settings',72),
    ('expense_categories',73),
    ('day_closings',74),
    ('data_purge_requests',75),
    ('client_errors',76),
    ('cash_accounts',77),
    ('branch_whatsapp_channels',78),
    ('branch_payment_settings',79),
    ('branch_memberships',80),
    ('branch_media',81),
    ('branch_journey_settings',82),
    ('blocks',83),
    ('alert_rules',84),
    ('alert_events',85),
    ('ai_ops_conversations',86),
    ('ai_guest_usage_daily',87),
    ('ai_branch_usage_daily',88),
    ('accounting_periods',89),
    ('system_settings',90),
    ('staff_profiles',91),
    ('monitor_runs',92),
    ('journey_ticks',93),
    ('journey_messages',94),
    ('integration_events',95),
    ('guest_profiles',96),
    ('guest_phone_optouts',97),
    ('document_sequences',98),
    ('branches',99),
    ('booking_sources',100),
    ('bank_parse_rules',101),
    ('bank_messages',102),
    ('bank_mail_settings',103),
    ('audit_events',104),
    ('ai_usage_daily',105),
    ('ai_settings',106)
  ) v(table_name, seq)
  order by v.seq
$$;
revoke all on function fn_hotel_exit_tables() from public, anon;
grant execute on function fn_hotel_exit_tables() to authenticated;

-- The exit guard: a live session, then an active owner row of this very hotel. The hotel may be suspended —
-- that is exactly when the delete runs — so fn_session_ok's hotel clause does not apply here, its session clause does.
create or replace function fn_hotel_exit_session_ok() returns boolean
language sql stable security definer set search_path = public as $$
  select case when coalesce(auth.jwt()->>'session_id','') !~ '^[0-9a-fA-F-]{36}$' then true
              else exists(select 1 from auth.sessions s where s.id = (auth.jwt()->>'session_id')::uuid
                            and (s.not_after is null or s.not_after > now())) end
$$;
revoke all on function fn_hotel_exit_session_ok() from public, anon, authenticated;

create or replace function fn_hotel_exit_owner(p_org uuid) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare v uuid;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHENTICATED' using errcode = '42501'; end if;
  if not fn_hotel_exit_session_ok() then raise exception 'FORBIDDEN: session ended' using errcode = '42501'; end if;
  select sp.auth_user_id into v from staff_profiles sp
   where sp.organization_id = p_org and sp.auth_user_id = auth.uid() and sp.role = 'owner' and sp.is_active;
  if v is null then raise exception 'FORBIDDEN: hotel owner required' using errcode = '42501'; end if;
  return v;
end $$;
revoke all on function fn_hotel_exit_owner(uuid) from public, anon, authenticated;

-- One table's rows of the hotel, counted and hashed in a canonical form (rows ordered by their own json text),
-- so an export and a later re-count agree byte for byte. «organizations» filters by id, everything else by
-- organization_id.
create or replace function fn_hotel_exit_table_hash(p_table text, p_org uuid, out rows bigint, out sha256 text)
language plpgsql stable security definer set search_path = public, extensions as $$
declare v_filter text := case when p_table = 'organizations' then 'id' else 'organization_id' end;
begin
  execute format($f$select count(*)::bigint,
                           encode(extensions.digest(coalesce(string_agg(row_text, E'\n' order by row_text), ''), 'sha256'), 'hex')
                    from (select to_jsonb(t)::text as row_text from public.%I t where t.%I = $1) s$f$, p_table, v_filter)
  into rows, sha256 using p_org;
end $$;
revoke all on function fn_hotel_exit_table_hash(text, uuid) from public, anon, authenticated;

create or replace function fn_hotel_exit_columns(p_table text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((select jsonb_agg(column_name order by ordinal_position) from information_schema.columns
                   where table_schema = 'public' and table_name = p_table), '[]'::jsonb)
$$;
revoke all on function fn_hotel_exit_columns(text) from public, anon, authenticated;

-- Copy one table's rows of the hotel into the archive; returns its manifest entry (rows, sha256, columns).
create or replace function fn_hotel_exit_archive_table(p_archive uuid, p_table text, p_org uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_filter text := case when p_table = 'organizations' then 'id' else 'organization_id' end;
        n bigint; h text; h2 record;
begin
  execute format($f$insert into hotel_exit_rows(archive_id, organization_id, table_name, row_seq, row_data)
                    select $1, $4, $2, (row_number() over (order by row_text))::int, row_text::jsonb
                    from (select to_jsonb(t)::text as row_text from public.%I t where t.%I = $3) s$f$, p_table, v_filter)
  using p_archive, p_table, p_org, p_org;
  get diagnostics n = row_count;
  select * into h2 from fn_hotel_exit_table_hash(p_table, p_org);
  if h2.rows <> n then raise exception 'EXIT: archive_count_mismatch %', p_table; end if;
  return jsonb_build_object('rows', n, 'sha256', h2.sha256, 'columns', fn_hotel_exit_columns(p_table));
end $$;
revoke all on function fn_hotel_exit_archive_table(uuid, text, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------- export
create or replace function fn_hotel_exit_export(p_org uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_actor uuid := fn_hotel_exit_owner(p_org);
        v_org organizations%rowtype;
        v_archive uuid; t record; e jsonb; v_tables jsonb := '{}'; v_retained jsonb := '{}';
        v_rows bigint := 0; v_tables_n int := 0; v_overall text; v_files jsonb := '[]'; h record;
begin
  select * into v_org from organizations where id = p_org;
  if v_org.id is null then raise exception 'NOT_FOUND'; end if;
  if v_org.exited_at is not null then raise exception 'EXIT: already_exited'; end if;
  perform pg_advisory_xact_lock(hashtext('hotel-exit:' || p_org::text));

  insert into hotel_exit_archives(organization_id, hotel_name, requested_by, status, prior_platform_status,
                                  table_count, row_count, overall_sha256, manifest)
  values (p_org, v_org.name_ar, v_actor, 'completed', v_org.platform_status, 0, 0, '', '{}')
  returning id into v_archive;

  -- every tenancy table; the audit log is copied but marked retained (it is never deleted)
  for t in select * from fn_hotel_exit_tables() loop
    e := fn_hotel_exit_archive_table(v_archive, t.table_name, p_org);
    if t.retained then v_retained := v_retained || jsonb_build_object(t.table_name, e);
    else v_tables := v_tables || jsonb_build_object(t.table_name, e); end if;
    v_rows := v_rows + (e->>'rows')::bigint; v_tables_n := v_tables_n + 1;
  end loop;
  -- the registry row and the support grants: exported as well; both retained in place until the delete,
  -- the registry row retained (as a tombstone) even after it
  e := fn_hotel_exit_archive_table(v_archive, 'organizations', p_org);
  v_retained := v_retained || jsonb_build_object('organizations', e);
  v_rows := v_rows + (e->>'rows')::bigint; v_tables_n := v_tables_n + 1;
  e := fn_hotel_exit_archive_table(v_archive, 'platform_support_grants', p_org);
  v_tables := v_tables || jsonb_build_object('platform_support_grants', e);
  v_rows := v_rows + (e->>'rows')::bigint; v_tables_n := v_tables_n + 1;
  -- the platform's immutable record: counted and hashed for the owner, never touched
  select * into h from fn_hotel_exit_table_hash('platform_events', p_org);
  v_retained := v_retained || jsonb_build_object('platform_events', jsonb_build_object('rows', h.rows, 'sha256', h.sha256));

  -- the hotel's files travel inside their rows (they are bytea columns); the manifest names them so the owner
  -- sees them: media, expense receipts, the registry logo
  select coalesce(jsonb_agg(f), '[]') into v_files from (
    select jsonb_build_object('table', 'branch_media', 'id', sha256, 'sha256', sha256, 'mime', mime, 'bytes', octet_length(bytes)) as f
      from branch_media where organization_id = p_org
    union all
    select jsonb_build_object('table', 'branch_media_items', 'id', id, 'sha256', sha256, 'mime', coalesce(mime, url), 'bytes', octet_length(bytes))
      from branch_media_items where organization_id = p_org
    union all
    select jsonb_build_object('table', 'expense_attachments', 'id', id, 'sha256', sha256, 'mime', coalesce(mime, file_name), 'bytes', octet_length(bytes))
      from expense_attachments where organization_id = p_org
    union all
    select jsonb_build_object('table', 'organizations', 'id', id, 'sha256', logo_sha256, 'mime', logo_mime, 'bytes', octet_length(logo_bytes))
      from organizations where id = p_org and logo_bytes is not null
  ) x;
  v_retained := v_retained || jsonb_build_object('files_in_rows', jsonb_build_object('rows', jsonb_array_length(v_files), 'sha256', encode(extensions.digest(v_files::text, 'sha256'), 'hex')));

  select encode(extensions.digest(string_agg(line, E'\n' order by line), 'sha256'), 'hex') into v_overall
  from (select key || ':' || (value->>'rows') || ':' || (value->>'sha256') as line
        from (select * from jsonb_each(v_tables) union all select * from jsonb_each(v_retained)) e2) s;

  update hotel_exit_archives set table_count = v_tables_n, row_count = v_rows, overall_sha256 = v_overall,
    manifest = jsonb_build_object('hotel', jsonb_build_object('id', p_org, 'name_ar', v_org.name_ar, 'exported_at', now()),
                                  'tables', v_tables, 'retained', v_retained, 'files', v_files,
                                  'totals', jsonb_build_object('tables', v_tables_n, 'rows', v_rows, 'sha256', v_overall))
  where id = v_archive;
  -- re-requesting is safe: the new archive is complete on its own; the older ones step aside
  update hotel_exit_archives set status = 'superseded'
  where organization_id = p_org and id <> v_archive and status = 'completed';

  perform fn_platform_audit(p_org, 'hotel.exit_exported', null,
    jsonb_build_object('archive_id', v_archive, 'tables', v_tables_n, 'rows', v_rows, 'sha256', v_overall));
  return jsonb_build_object('archive_id', v_archive, 'tables', v_tables_n, 'rows', v_rows, 'sha256', v_overall,
                            'files', jsonb_array_length(v_files));
end $$;
revoke all on function fn_hotel_exit_export(uuid) from public, anon;
grant execute on function fn_hotel_exit_export(uuid) to authenticated;

-- Does the live hotel still match an archive, table by table? The deletion refuses to run on a stale or a
-- tampered export: what it removes must be exactly what was copied.
create or replace function fn_hotel_exit_verify(p_archive uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a hotel_exit_archives%rowtype; k text; e jsonb; h record; bad jsonb := '[]'; n int := 0;
begin
  select * into a from hotel_exit_archives where id = p_archive;
  if a.id is null then raise exception 'NOT_FOUND'; end if;
  if a.requested_by is distinct from auth.uid()
     and not exists(select 1 from staff_profiles sp where sp.organization_id = a.organization_id
                      and sp.auth_user_id = auth.uid() and sp.role = 'owner' and sp.is_active) then
    raise exception 'FORBIDDEN: hotel owner required' using errcode = '42501';
  end if;
  for k, e in select * from jsonb_each(a.manifest->'tables') loop
    n := n + 1;
    select * into h from fn_hotel_exit_table_hash(k, a.organization_id);
    if h.rows is distinct from (e->>'rows')::bigint or h.sha256 is distinct from (e->>'sha256') then
      bad := bad || jsonb_build_object(k, jsonb_build_object('expected', e->>'rows', 'found', h.rows));
    end if;
  end loop;
  return jsonb_build_object('ok', bad = '[]'::jsonb, 'checked', n, 'mismatches', bad);
end $$;
revoke all on function fn_hotel_exit_verify(uuid) from public, anon;
grant execute on function fn_hotel_exit_verify(uuid) to authenticated;

-- ---------------------------------------------------------------- suspend
create or replace function fn_hotel_exit_suspend(p_org uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_actor uuid := fn_hotel_exit_owner(p_org);
        v_org organizations%rowtype; v_archive uuid; n int := 0; r record;
begin
  select * into v_org from organizations where id = p_org;
  if v_org.id is null then raise exception 'NOT_FOUND'; end if;
  if v_org.exited_at is not null then raise exception 'EXIT: already_exited'; end if;
  perform pg_advisory_xact_lock(hashtext('hotel-exit:' || p_org::text));
  -- no suspension without a completed copy in hand
  select id into v_archive from hotel_exit_archives
   where organization_id = p_org and status = 'completed' order by requested_at desc limit 1;
  if v_archive is null then raise exception 'EXIT: export_required'; end if;
  if v_org.platform_status = 'suspended' then
    return jsonb_build_object('ok', true, 'already_suspended', true, 'archive_id', v_archive);
  end if;
  update organizations set platform_status = 'suspended',
    platform_status_reason = 'hotel exit (2.12): suspended by the owner after a full export',
    platform_status_changed_at = now()
  where id = p_org;
  for r in select auth_user_id from staff_profiles where organization_id = p_org and auth_user_id is not null loop
    n := n + fn_end_sessions(r.auth_user_id);
  end loop;
  perform fn_platform_audit(p_org, 'hotel.exit_suspended', null, jsonb_build_object('archive_id', v_archive, 'sessions_ended', n));
  return jsonb_build_object('ok', true, 'already_suspended', false, 'archive_id', v_archive, 'sessions_ended', n);
end $$;
revoke all on function fn_hotel_exit_suspend(uuid) from public, anon;
grant execute on function fn_hotel_exit_suspend(uuid) to authenticated;

-- ---------------------------------------------------------------- delete
create or replace function fn_hotel_exit_delete(p_org uuid, p_confirm_name text, p_confirm_id text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_actor uuid := fn_hotel_exit_owner(p_org);
        v_org organizations%rowtype; a hotel_exit_archives%rowtype;
        t record; n bigint; v_removed jsonb := '{}'; v_total bigint := 0;
        v_auth uuid[]; v_verify jsonb;
begin
  select * into v_org from organizations where id = p_org;
  if v_org.id is null then raise exception 'NOT_FOUND'; end if;
  if v_org.exited_at is not null then raise exception 'EXIT: already_exited'; end if;
  perform pg_advisory_xact_lock(hashtext('hotel-exit:' || p_org::text));
  -- the documented order is export, suspend, delete; and the confirmation is the hotel's exact name and its id
  if v_org.platform_status <> 'suspended' then raise exception 'EXIT: not_suspended'; end if;
  if p_confirm_name is null or p_confirm_name <> v_org.name_ar
     or p_confirm_id is null or p_confirm_id <> p_org::text then
    raise exception 'EXIT: confirmation_mismatch' using errcode = '22023';
  end if;
  select * into a from hotel_exit_archives
   where organization_id = p_org and status = 'completed' order by requested_at desc limit 1;
  if a.id is null then raise exception 'EXIT: export_required'; end if;
  v_verify := fn_hotel_exit_verify(a.id);
  if not (v_verify->>'ok')::boolean then
    raise exception 'EXIT: export_stale — the hotel changed or the copy was tampered with (%); export again before deleting', v_verify->'mismatches';
  end if;

  -- support grants name a staff member of the hotel: they leave first (their record is in the archive and in
  -- the immutable platform_events)
  delete from platform_support_grants where organization_id = p_org;
  get diagnostics n = row_count; v_removed := v_removed || jsonb_build_object('platform_support_grants', n); v_total := v_total + n;

  select array_agg(auth_user_id) into v_auth from staff_profiles where organization_id = p_org and auth_user_id is not null;

  perform set_config('app.hotel_exit', 'on', true);   -- the last-owner guard's single sanctioned exception, this delete only
  for t in select * from fn_hotel_exit_tables() where not retained loop
    execute format('delete from public.%I where organization_id = $1', t.table_name) using p_org;
    get diagnostics n = row_count;
    if n <> ((a.manifest->'tables'->t.table_name->>'rows')::bigint) then
      raise exception 'EXIT: count_drift % (% <> %)', t.table_name, n, a.manifest->'tables'->t.table_name->>'rows';
    end if;
    v_removed := v_removed || jsonb_build_object(t.table_name, n); v_total := v_total + n;
  end loop;
  perform set_config('app.hotel_exit', 'off', true);

  -- the hotel's auth accounts: their sessions and refresh tokens, then the users themselves — never looked up
  -- by e-mail, only by the staff rows just archived; an account that somehow still serves another hotel stays
  if v_auth is not null then
    delete from auth.refresh_tokens where user_id in (select unnest(v_auth)::text);
    delete from auth.sessions where user_id in (select unnest(v_auth));
    delete from auth.users u where u.id in (select unnest(v_auth))
      and not exists (select 1 from staff_profiles sp where sp.auth_user_id = u.id);
    get diagnostics n = row_count; v_removed := v_removed || jsonb_build_object('auth_users', n);
  end if;

  -- the registry row stays as a tombstone: slug kept (so nobody reuses it), personal content scrubbed
  update organizations set exited_at = now(), exit_archive_id = a.id,
    name_en = null, license_number = null, license_status = 'exited', guest_site_url = null,
    logo_mime = null, logo_bytes = null, logo_sha256 = null, updated_at = now()
  where id = p_org;
  update hotel_exit_archives set status = 'deleted' where id = a.id;

  perform fn_platform_audit(p_org, 'hotel.exit_deleted', null,
    jsonb_build_object('archive_id', a.id, 'rows', v_total, 'retained', jsonb_build_object('audit_events', true, 'platform_events', true)));
  return jsonb_build_object('ok', true, 'archive_id', a.id, 'rows_removed', v_total, 'removed', v_removed);
end $$;
revoke all on function fn_hotel_exit_delete(uuid, text, text) from public, anon;
grant execute on function fn_hotel_exit_delete(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------- restore
create or replace function fn_hotel_exit_restore(p_org uuid, p_archive uuid, p_confirm_id text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a hotel_exit_archives%rowtype; t record; k text; e jsonb; v_cols text; n bigint; v_total bigint := 0;
        v_restored jsonb := '{}'; v_cur jsonb;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHENTICATED' using errcode = '42501'; end if;
  if not fn_hotel_exit_session_ok() then raise exception 'FORBIDDEN: session ended' using errcode = '42501'; end if;
  select * into a from hotel_exit_archives where id = p_archive and organization_id = p_org;
  if a.id is null then raise exception 'NOT_FOUND'; end if;
  -- the owner who made the copy is the one who may put it back (identified by their account, never by e-mail)
  if a.requested_by is distinct from auth.uid() then raise exception 'FORBIDDEN: hotel owner required' using errcode = '42501'; end if;
  if a.status <> 'deleted' then raise exception 'EXIT: not_deleted'; end if;
  if p_confirm_id is null or p_confirm_id <> p_org::text then raise exception 'EXIT: confirmation_mismatch' using errcode = '22023'; end if;
  perform pg_advisory_xact_lock(hashtext('hotel-exit:' || p_org::text));

  -- the copy can only go back into the shape it was taken from
  for k, e in select * from jsonb_each(a.manifest->'tables') union all select 'organizations', a.manifest->'retained'->'organizations' loop
    v_cur := fn_hotel_exit_columns(k);
    if v_cur is distinct from (e->'columns') then raise exception 'EXIT: archive_outdated %', k; end if;
  end loop;

  -- the registry row first: its columns back as archived, the tombstone marks lifted, the status it had at export
  select string_agg(quote_ident(c), ',') into v_cols from jsonb_array_elements_text(a.manifest->'retained'->'organizations'->'columns') c
   where c not in ('id', 'exited_at', 'exit_archive_id', 'updated_at')
     and c not in (select column_name from information_schema.columns
                   where table_schema = 'public' and table_name = 'organizations' and is_generated = 'ALWAYS');
  execute format($f$update organizations o set (%s) = (select %s from jsonb_populate_record(null::organizations, $1) x),
                        exited_at = null, exit_archive_id = null, updated_at = now() where o.id = $2$f$, v_cols, v_cols)
  using (select row_data from hotel_exit_rows where archive_id = p_archive and table_name = 'organizations' limit 1), p_org;
  if not found then raise exception 'NOT_FOUND'; end if;

  -- then every tenancy table, parents before children (the deletion order reversed); the audit log never left.
  -- Triggers sleep for the insert loop: the seed triggers on organizations/branches would otherwise re-create
  -- default settings rows and collide with the archived ones, and the tenant-fill checks find every parent row
  -- already in place. The loop puts back exactly the archived rows of this hotel, nothing else; the setting is
  -- transaction-local and dies with any failure, and the whole restore is one transaction.
  perform set_config('session_replication_role', 'replica', true);
  for t in select * from fn_hotel_exit_tables() where not retained order by seq desc loop
    v_cols := (select string_agg(quote_ident(c), ',') from jsonb_array_elements_text(a.manifest->'tables'->t.table_name->'columns') c
                where c not in (select column_name from information_schema.columns
                                where table_schema = 'public' and table_name = t.table_name and is_generated = 'ALWAYS'));
    execute format($f$insert into public.%I (%s)
                      select %s from jsonb_populate_recordset(null::public.%I,
                        (select jsonb_agg(row_data order by row_seq) from hotel_exit_rows where archive_id = $1 and table_name = $2)) s$f$,
                   t.table_name, v_cols, v_cols, t.table_name)
    using p_archive, t.table_name;
    get diagnostics n = row_count;
    if n <> ((a.manifest->'tables'->t.table_name->>'rows')::bigint) then
      raise exception 'EXIT: restore_count % (% <> %)', t.table_name, n, a.manifest->'tables'->t.table_name->>'rows';
    end if;
    v_restored := v_restored || jsonb_build_object(t.table_name, n); v_total := v_total + n;
  end loop;
  -- the support grants name staff who are back now
  v_cols := (select string_agg(quote_ident(c), ',') from jsonb_array_elements_text(a.manifest->'tables'->'platform_support_grants'->'columns') c
              where c not in (select column_name from information_schema.columns
                              where table_schema = 'public' and table_name = 'platform_support_grants' and is_generated = 'ALWAYS'));
  execute format($f$insert into platform_support_grants (%s)
                    select %s from jsonb_populate_recordset(null::platform_support_grants,
                      (select jsonb_agg(row_data order by row_seq) from hotel_exit_rows where archive_id = $1 and table_name = 'platform_support_grants')) s$f$,
                 v_cols, v_cols)
  using p_archive;
  get diagnostics n = row_count; v_total := v_total + n;
  v_restored := v_restored || jsonb_build_object('platform_support_grants', n);
  perform set_config('session_replication_role', 'origin', true);

  -- accounts whose staff rows are back get their auth row back when it is gone (password/MFA are platform-side:
  -- on a hosted project the CLI documents re-inviting them); never by e-mail lookup, only the archived ids
  insert into auth.users(id, email, created_at)
  select (row_data->>'auth_user_id')::uuid, row_data->>'email', now()
  from hotel_exit_rows where archive_id = p_archive and table_name = 'staff_profiles' and row_data->>'auth_user_id' is not null
  on conflict (id) do nothing;
  get diagnostics n = row_count; v_restored := v_restored || jsonb_build_object('auth_users', n);

  update hotel_exit_archives set status = 'restored' where id = p_archive;
  perform fn_platform_audit(p_org, 'hotel.exit_restored', null, jsonb_build_object('archive_id', p_archive, 'rows', v_total));
  return jsonb_build_object('ok', true, 'archive_id', p_archive, 'rows_restored', v_total, 'restored', v_restored,
                            'platform_status', a.prior_platform_status);
end $$;
revoke all on function fn_hotel_exit_restore(uuid, uuid, text) from public, anon;
grant execute on function fn_hotel_exit_restore(uuid, uuid, text) to authenticated;

-- The archive rows point at their archive header: the pointer is registered like every other hotel-table pointer (FS03).
-- The check itself is trivially true (the header carries the same organization_id) but the registration is the rule.
drop trigger if exists zz_hotel_pointers on public.hotel_exit_rows;
create trigger zz_hotel_pointers after insert or update on public.hotel_exit_rows
  for each row execute function public.fn_hotel_pointers('archive_id', 'hotel_exit_archives');
