-- 0107 / 2.12: discover the current hotel catalog, including finance and backup.
-- This is additive to 0102. No production rows are changed by this migration.
-- Keep the independent completeness test: do not freeze its expected table count.
create or replace function public.fn_hotel_exit_tables()
returns table(table_name text, seq int, retained boolean)
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
  pending oid[];
  next_oid oid;
  next_name text;
  position_no int := 0;
begin
  -- Includes room_licenses through its organization_id, without special access.
  -- Only real public tables, not views. The exclusions are handled separately by
  -- the exit RPCs (platform) or are the archive itself. Include partition roots,
  -- not their physical children: the root already covers all partition rows.
  select coalesce(array_agg(c.oid order by c.relname), '{}'::oid[]) into pending
  from pg_catalog.pg_class c
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind in ('r', 'p')
    and not c.relispartition
    and c.relname not in ('platform_events', 'platform_support_grants',
                          'hotel_exit_archives', 'hotel_exit_rows')
    and exists (select 1 from pg_catalog.pg_attribute a
                where a.attrelid = c.oid and a.attname = 'organization_id'
                  and a.attnum > 0 and not a.attisdropped);

  -- Kahn topological sort in deletion direction. A child must be emitted before
  -- any parent it references, even for ON DELETE CASCADE (counts must not drift).
  -- A self-FK is deleted in a single statement and is not an ordering edge.
  while cardinality(pending) > 0 loop
    select c.oid, c.relname::text into next_oid, next_name
    from pg_catalog.pg_class c
    where c.oid = any(pending)
      and not exists (
        select 1 from pg_catalog.pg_constraint fk
        where fk.contype = 'f' and fk.confrelid = c.oid
          and fk.conrelid = any(pending) and fk.conrelid <> fk.confrelid)
    order by c.relname limit 1;
    if next_oid is null then
      raise exception 'EXIT: catalog_fk_cycle %',
        (select string_agg(c.relname::text, ', ' order by c.relname)
           from pg_catalog.pg_class c where c.oid = any(pending));
    end if;
    position_no := position_no + 1;
    table_name := next_name;
    seq := position_no;
    retained := next_name = 'audit_events';
    return next;
    pending := array_remove(pending, next_oid);
  end loop;
end $$;
revoke all on function public.fn_hotel_exit_tables() from public, anon;
grant execute on function public.fn_hotel_exit_tables() to authenticated;

-- Reject archives whose catalog predates the current schema.
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
  -- Catalog changes require a fresh export. Both directions matter: a removed
  -- table or a changed retention policy is also incompatible with this archive.
  if exists (
    with expected as (
      select x.table_name from fn_hotel_exit_tables() x where not x.retained
      union all select 'platform_support_grants'
    ), actual as (select jsonb_object_keys(a.manifest->'tables') as table_name)
    select * from expected except select * from actual
  ) or exists (
    with expected as (
      select x.table_name from fn_hotel_exit_tables() x where not x.retained
      union all select 'platform_support_grants'
    ), actual as (select jsonb_object_keys(a.manifest->'tables') as table_name)
    select * from actual except select * from expected
  ) then
    raise exception 'EXIT: archive_catalog_outdated';
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

-- Reject archives whose catalog predates the current schema.
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

  -- Catalog changes require a fresh export. Both directions matter: a removed
  -- table or a changed retention policy is also incompatible with this archive.
  if exists (
    with expected as (
      select x.table_name from fn_hotel_exit_tables() x where not x.retained
      union all select 'platform_support_grants'
    ), actual as (select jsonb_object_keys(a.manifest->'tables') as table_name)
    select * from expected except select * from actual
  ) or exists (
    with expected as (
      select x.table_name from fn_hotel_exit_tables() x where not x.retained
      union all select 'platform_support_grants'
    ), actual as (select jsonb_object_keys(a.manifest->'tables') as table_name)
    select * from actual except select * from expected
  ) then
    raise exception 'EXIT: archive_catalog_outdated';
  end if;

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
    execute format($f$insert into public.%I (%s) overriding system value
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

