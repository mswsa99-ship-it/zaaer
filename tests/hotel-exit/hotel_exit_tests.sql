-- =====================================================================
-- 2.12 hotel exit (migration 0102): the owner exports everything, suspends,
-- then deletes with name/ID confirmation — and the copy restores.
-- Proves on one database with two hotels: the other hotel is untouched, the
-- export restores with matching totals, non-owners and guests are refused, a
-- failed/stale export blocks the deletion, and re-requesting every step is
-- safe. Synthetic hotels only (12..0a exits, 12..0b stays).
-- =====================================================================
\set ON_ERROR_STOP on
begin;

create temp table xe_results(name text, ok boolean, detail text);
grant all on xe_results to public;
create temp table xe_ctx(k text primary key, v text);
grant all on xe_ctx to public;
create temp table xe_snap(who text, t text, n bigint, primary key (who, t));
grant all on xe_snap to public;

create or replace function xe_record(p_name text, p_ok boolean, p_detail text default null) returns void
language sql security definer as $$ insert into xe_results values (p_name, p_ok, p_detail) $$;
create or replace function xe_login(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), false);
  perform set_config('request.jwt.claims', case when p_uid is null then '{}' else json_build_object('sub', p_uid)::text end, false);
end $$;
create or replace function xe_snap(p_who text, p_org uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t record; n bigint;
begin
  delete from xe_snap where who = p_who;
  for t in select table_name from fn_hotel_exit_tables() loop
    execute format('select count(*) from public.%I where organization_id = $1', t.table_name) into n using p_org;
    insert into xe_snap values (p_who, t.table_name, n);
  end loop;
end $$;
create or replace function xe_b_diff(p_a text, p_b text) returns text
language sql security definer set search_path = public as $$
  select string_agg(s1.t || ':' || s1.n || '->' || s2.n, ' ')
  from xe_snap s1 join xe_snap s2 on s1.t = s2.t and s1.n is distinct from s2.n
  where s1.who = p_a and s2.who = p_b
$$;

-- ---------------------------------------------------------------- fixtures
insert into organizations(id, name_ar, guest_slug) values
  ('12000000-0000-0000-0000-00000000000a', 'فندق الخروج', 'hotel-exit-a'),
  ('12000000-0000-0000-0000-00000000000b', 'فندق البقاء', 'hotel-stays-b');
insert into branches(id, organization_id, name_ar) values
  ('12000000-0000-0000-0000-0000000000a1', '12000000-0000-0000-0000-00000000000a', 'فرع أ1'),
  ('12000000-0000-0000-0000-0000000000b1', '12000000-0000-0000-0000-00000000000b', 'فرع ب1');
insert into auth.users(id, email) values
  ('a2000000-0000-0000-0000-00000000000a', 'xe-ownera@test.local'),
  ('a2000000-0000-0000-0000-0000000000a2', 'xe-mgra@test.local'),
  ('a2000000-0000-0000-0000-00000000000b', 'xe-ownerb@test.local'),
  ('a2000000-0000-0000-0000-0000000000cc', 'xe-stranger@test.local');
insert into staff_profiles(id, auth_user_id, organization_id, full_name, email, role) values
  ('12000000-0000-0000-0000-0000000000aa', 'a2000000-0000-0000-0000-00000000000a', '12000000-0000-0000-0000-00000000000a', 'مالك أ', 'xe-ownera@test.local', 'owner'),
  ('12000000-0000-0000-0000-0000000000ab', 'a2000000-0000-0000-0000-0000000000a2', '12000000-0000-0000-0000-00000000000a', 'مدير أ', 'xe-mgra@test.local', 'manager'),
  ('12000000-0000-0000-0000-0000000000ba', 'a2000000-0000-0000-0000-00000000000b', '12000000-0000-0000-0000-00000000000b', 'مالك ب', 'xe-ownerb@test.local', 'owner');
insert into branch_memberships(staff_id, branch_id) values
  ('12000000-0000-0000-0000-0000000000aa', '12000000-0000-0000-0000-0000000000a1'),
  ('12000000-0000-0000-0000-0000000000ab', '12000000-0000-0000-0000-0000000000a1'),
  ('12000000-0000-0000-0000-0000000000ba', '12000000-0000-0000-0000-0000000000b1');
insert into room_categories(id, branch_id, organization_id, name_ar) values
  ('12000000-0000-0000-0000-0000000000c1', '12000000-0000-0000-0000-0000000000a1', '12000000-0000-0000-0000-00000000000a', 'غرفة');
insert into rooms(id, branch_id, organization_id, category_id, room_number) values
  ('12000000-0000-0000-0000-0000000000d1', '12000000-0000-0000-0000-0000000000a1', '12000000-0000-0000-0000-00000000000a', '12000000-0000-0000-0000-0000000000c1', '101');
insert into guest_profiles(id, organization_id, full_name, phone) values
  ('12000000-0000-0000-0000-0000000000e1', '12000000-0000-0000-0000-00000000000a', 'نزيل أ', '0500000001'),
  ('12000000-0000-0000-0000-0000000000e2', '12000000-0000-0000-0000-00000000000b', 'نزيل ب', '0500000002');
insert into reservations(id, branch_id, organization_id, room_id, check_in, check_out, status) values
  ('12000000-0000-0000-0000-0000000000f1', '12000000-0000-0000-0000-0000000000a1', '12000000-0000-0000-0000-00000000000a',
   '12000000-0000-0000-0000-0000000000d1', current_date - 3, current_date - 1, 'checked_out');
insert into reservation_guests(reservation_id, guest_profile_id, full_name) values
  ('12000000-0000-0000-0000-0000000000f1', '12000000-0000-0000-0000-0000000000e1', 'نزيل أ');
insert into notifications(branch_id, title) values
  ('12000000-0000-0000-0000-0000000000a1', 'تنبيه أ'), ('12000000-0000-0000-0000-0000000000b1', 'تنبيه ب');
insert into conversations(channel, status, branch_id) values ('whatsapp', 'active', '12000000-0000-0000-0000-0000000000a1');
insert into branch_media(branch_id, kind, mime, bytes, sha256) values
  ('12000000-0000-0000-0000-0000000000a1', 'logo', 'image/png', '\x01020304', 'xe-media-sha');
insert into auth.sessions(id, user_id, not_after) values
  ('b2000000-0000-0000-0000-00000000000a', 'a2000000-0000-0000-0000-00000000000a', now() + interval '1 hour');
insert into auth.refresh_tokens(token, user_id, revoked, session_id) values
  ('xe-rt', 'a2000000-0000-0000-0000-00000000000a', false, 'b2000000-0000-0000-0000-00000000000a');
select xe_snap('B0', '12000000-0000-0000-0000-00000000000b');

-- ---------------------------------------------------------------- 1. shape and privileges
do $$
begin
  perform xe_record('X1.1 archive tables exist with RLS on, no API table grants, service_role may read',
    to_regclass('public.hotel_exit_archives') is not null and to_regclass('public.hotel_exit_rows') is not null
    and (select relrowsecurity from pg_class where oid = 'public.hotel_exit_archives'::regclass)
    and (select relrowsecurity from pg_class where oid = 'public.hotel_exit_rows'::regclass)
    and not has_table_privilege('anon', 'public.hotel_exit_archives', 'select')
    and not has_table_privilege('authenticated', 'public.hotel_exit_archives', 'select')
    and not has_table_privilege('authenticated', 'public.hotel_exit_rows', 'select')
    and has_table_privilege('service_role', 'public.hotel_exit_archives', 'select'));
  perform xe_record('X1.2 the five RPCs exist; authenticated may call, anon may not',
    to_regprocedure('public.fn_hotel_exit_export(uuid)') is not null
    and to_regprocedure('public.fn_hotel_exit_suspend(uuid)') is not null
    and to_regprocedure('public.fn_hotel_exit_delete(uuid,text,text)') is not null
    and to_regprocedure('public.fn_hotel_exit_restore(uuid,uuid,text)') is not null
    and to_regprocedure('public.fn_hotel_exit_verify(uuid)') is not null
    and has_function_privilege('authenticated', 'public.fn_hotel_exit_export(uuid)', 'execute')
    and has_function_privilege('authenticated', 'public.fn_hotel_exit_delete(uuid,text,text)', 'execute')
    and has_function_privilege('authenticated', 'public.fn_hotel_exit_restore(uuid,uuid,text)', 'execute')
    and not has_function_privilege('anon', 'public.fn_hotel_exit_export(uuid)', 'execute')
    and not has_function_privilege('anon', 'public.fn_hotel_exit_delete(uuid,text,text)', 'execute'));
  perform xe_record('X1.3 the table list covers every tenancy table (catalogue cross-check)',
    not exists (
      select 1 from information_schema.columns c
       where c.table_schema = 'public' and c.column_name = 'organization_id'
         and c.table_name not in ('platform_events', 'platform_support_grants', 'hotel_exit_archives', 'hotel_exit_rows')
         and c.table_name not in (select table_name from fn_hotel_exit_tables()))
    and not exists (
      select 1 from fn_hotel_exit_tables() x
       where not exists (select 1 from information_schema.columns c
                          where c.table_schema = 'public' and c.table_name = x.table_name and c.column_name = 'organization_id')));
  perform xe_record('X1.4 the order puts every referencing table before the table it references',
    not exists (
      select 1 from pg_constraint fk
        join pg_class cc on cc.oid = fk.conrelid join pg_namespace cn on cn.oid = cc.relnamespace
        join pg_class pc on pc.oid = fk.confrelid join pg_namespace pn on pn.oid = pc.relnamespace
        join fn_hotel_exit_tables() x1 on x1.table_name = cc.relname
        join fn_hotel_exit_tables() x2 on x2.table_name = pc.relname
       where fk.contype = 'f' and cn.nspname = 'public' and pn.nspname = 'public'
         and cc.relname <> pc.relname and x1.seq > x2.seq));
  perform xe_record('X1.5 the audit log is listed and marked retained; the list is the 106 tenancy tables',
    exists (select 1 from fn_hotel_exit_tables() where table_name = 'audit_events' and retained)
    and (select count(*) from fn_hotel_exit_tables()) = 106);
end $$;

-- ---------------------------------------------------------------- 2. refusals before anything exists
set local role anon;
do $$ declare e text; begin
  begin perform fn_hotel_exit_export('12000000-0000-0000-0000-00000000000a'); exception when others then e := sqlerrm; end;
  perform xe_record('X2.1 a guest (anon) cannot export', e is not null, e);
  e := null;
  begin perform fn_hotel_exit_delete('12000000-0000-0000-0000-00000000000a', 'فندق الخروج', '12000000-0000-0000-0000-00000000000a'); exception when others then e := sqlerrm; end;
  perform xe_record('X2.2 a guest (anon) cannot delete', e is not null, e);
end $$;
reset role;

select xe_login('a2000000-0000-0000-0000-0000000000cc');
set local role authenticated;
do $$ declare e text; begin
  begin perform fn_hotel_exit_export('12000000-0000-0000-0000-00000000000a'); exception when others then e := sqlerrm; end;
  perform xe_record('X2.3 a signed-in stranger cannot export', e like 'FORBIDDEN%', e);
end $$;
reset role;
select xe_login('a2000000-0000-0000-0000-0000000000a2');
do $$ declare e text; begin
  begin perform fn_hotel_exit_export('12000000-0000-0000-0000-00000000000a'); exception when others then e := sqlerrm; end;
  perform xe_record('X2.4 the hotel''s own manager (not owner) cannot export', e like 'FORBIDDEN%', e);
end $$;
reset role;
select xe_login('a2000000-0000-0000-0000-00000000000b');
do $$ declare e text; begin
  begin perform fn_hotel_exit_export('12000000-0000-0000-0000-00000000000a'); exception when others then e := sqlerrm; end;
  perform xe_record('X2.5 the other hotel''s owner cannot export this hotel', e like 'FORBIDDEN%', e);
  e := null;
  begin perform fn_hotel_exit_delete('12000000-0000-0000-0000-00000000000a', 'فندق الخروج', '12000000-0000-0000-0000-00000000000a'); exception when others then e := sqlerrm; end;
  perform xe_record('X2.6 the other hotel''s owner cannot delete this hotel', e like 'FORBIDDEN%', e);
end $$;
reset role;
select xe_login('a2000000-0000-0000-0000-00000000000a');
do $$ declare e text; begin
  begin perform fn_hotel_exit_suspend('12000000-0000-0000-0000-00000000000a'); exception when others then e := sqlerrm; end;
  perform xe_record('X2.7 no suspension before a completed export', e = 'EXIT: export_required', e);
  e := null;
  begin perform fn_hotel_exit_delete('12000000-0000-0000-0000-00000000000a', 'فندق الخروج', '12000000-0000-0000-0000-00000000000a'); exception when others then e := sqlerrm; end;
  perform xe_record('X2.8 no deletion before the suspension', e = 'EXIT: not_suspended', e);
  e := null;
  begin perform fn_hotel_exit_restore('12000000-0000-0000-0000-00000000000a', gen_random_uuid(), '12000000-0000-0000-0000-00000000000a'); exception when others then e := sqlerrm; end;
  perform xe_record('X2.9 no restore of an archive that does not exist', e = 'NOT_FOUND', e);
end $$;
reset role;
select xe_login(null);

-- ---------------------------------------------------------------- 3. the owner exports
select xe_login('a2000000-0000-0000-0000-00000000000a');
set local role authenticated;
do $$ declare r jsonb; begin
  r := fn_hotel_exit_export('12000000-0000-0000-0000-00000000000a');
  insert into xe_ctx values ('archive1', r->>'archive_id');
  perform xe_record('X3.1 the owner exports: 108 manifest tables, rows copied, one overall hash',
    (r->>'tables')::int = 108 and (r->>'rows')::bigint > 0 and length(r->>'sha256') = 64, r::text);
end $$;
reset role;
select xe_login(null);

do $$
declare a uuid := (select x.v::uuid from xe_ctx x where x.k = 'archive1'); m jsonb; n bigint; h text; expect bigint;
begin
  select manifest into m from hotel_exit_archives where id = a;
  insert into xe_ctx values ('manifest_rows1', m->'totals'->>'rows');
  perform xe_record('X3.2 the manifest counts match the live tables',
    (m->'tables'->'reservations'->>'rows')::int = 1 and (m->'tables'->'rooms'->>'rows')::int = 1
    and (m->'tables'->'staff_profiles'->>'rows')::int = 2 and (m->'tables'->'guest_profiles'->>'rows')::int = 1
    and (m->'tables'->'branches'->>'rows')::int = 1 and (m->'tables'->'conversations'->>'rows')::int = 1
    and (m->'retained'->'organizations'->>'rows')::int = 1,
    (select string_agg(key || '=' || (value->>'rows'), ' ') from jsonb_each(m->'tables') where (value->>'rows')::int > 0));
  select encode(extensions.digest(coalesce(string_agg(row_text, E'\n' order by row_text), ''), 'sha256'), 'hex')
    into h from (select to_jsonb(t)::text row_text from reservations t where organization_id = '12000000-0000-0000-0000-00000000000a') s;
  perform xe_record('X3.3 the manifest hash is recomputed from the live data', h = m->'tables'->'reservations'->>'sha256', h);
  select count(*) into n from hotel_exit_rows where archive_id = a;
  expect := (m->'totals'->>'rows')::bigint - (m->'retained'->'platform_events'->>'rows')::bigint;
  perform xe_record('X3.4 every counted row is in the copy (restorable)', n = expect, n || ' of ' || expect);
  perform xe_record('X3.5 the manifest names the hotel''s files (the branch media row)',
    jsonb_array_length(m->'files') = 1 and m->'files'->0->>'table' = 'branch_media', (m->'files')::text);
  perform xe_record('X3.6 the manifest records every table''s column list',
    jsonb_array_length(m->'tables'->'reservations'->'columns') > 10
    and jsonb_array_length(m->'retained'->'organizations'->'columns') > 5);
  insert into xe_ctx values ('audit_count_A', (select count(*)::text from audit_events where organization_id = '12000000-0000-0000-0000-00000000000a'));
  perform xe_record('X3.7 the hotel''s audit log was exported too (and stays put)',
    (m->'retained'->'audit_events'->>'rows')::bigint = (select x.v::bigint from xe_ctx x where x.k = 'audit_count_A'));
end $$;

-- ---------------------------------------------------------------- 4. re-exporting is safe
select xe_login('a2000000-0000-0000-0000-00000000000a');
set local role authenticated;
do $$ declare r jsonb; begin
  r := fn_hotel_exit_export('12000000-0000-0000-0000-00000000000a');
  insert into xe_ctx values ('archive2', r->>'archive_id');
  perform xe_record('X4.1 a second export is a new complete archive', (r->>'archive_id')::uuid <> (select x.v::uuid from xe_ctx x where x.k = 'archive1'), null);
end $$;
reset role;
select xe_login(null);
do $$
begin
  perform xe_record('X4.2 the earlier archive steps aside (superseded), the new one is the completed copy',
    (select status from hotel_exit_archives where id = (select x.v::uuid from xe_ctx x where x.k = 'archive1')) = 'superseded'
    and (select status from hotel_exit_archives where id = (select x.v::uuid from xe_ctx x where x.k = 'archive2')) = 'completed');
end $$;

-- ---------------------------------------------------------------- 5. suspend
select xe_login('a2000000-0000-0000-0000-00000000000a');
set local role authenticated;
do $$ declare r jsonb; begin
  r := fn_hotel_exit_suspend('12000000-0000-0000-0000-00000000000a');
  perform xe_record('X5.1 the owner suspends after the export', (r->>'ok')::boolean and not (r->>'already_suspended')::boolean, r::text);
  r := fn_hotel_exit_suspend('12000000-0000-0000-0000-00000000000a');
  perform xe_record('X5.2 re-suspending is a safe no-op', (r->>'ok')::boolean and (r->>'already_suspended')::boolean, r::text);
end $$;
do $$
begin
  perform xe_record('X5.4 the suspended hotel''s own owner keeps no staff scope (fn_session_ok)',
    fn_current_role() is null and fn_user_org_id() is null, null);
end $$;
reset role;
select xe_login(null);
do $$
begin
  perform xe_record('X5.3 suspended with a reason; the staff session ended and its refresh token revoked',
    (select platform_status from organizations where id = '12000000-0000-0000-0000-00000000000a') = 'suspended'
    and (select platform_status_reason from organizations where id = '12000000-0000-0000-0000-00000000000a') is not null
    and (select not_after <= clock_timestamp() from auth.sessions where id = 'b2000000-0000-0000-0000-00000000000a')
    and (select revoked from auth.refresh_tokens where token = 'xe-rt'));
  perform xe_record('X5.5 the suspended hotel vanishes from the guest site', fn_guest_site('hotel-exit-a') is null, null);
  perform xe_record('X5.6 the other hotel''s site is untouched', fn_guest_site('hotel-stays-b') is not null, null);
end $$;

-- ---------------------------------------------------------------- 6. confirmation, and a failed/stale export blocks the deletion
select xe_login('a2000000-0000-0000-0000-00000000000a');
set local role authenticated;
do $$ declare e text; begin
  begin perform fn_hotel_exit_delete('12000000-0000-0000-0000-00000000000a', 'اسم خطأ', '12000000-0000-0000-0000-00000000000a'); exception when others then e := sqlerrm; end;
  perform xe_record('X6.1 the exact hotel name is required', e = 'EXIT: confirmation_mismatch', e);
  e := null;
  begin perform fn_hotel_exit_delete('12000000-0000-0000-0000-00000000000a', 'فندق الخروج', '00000000-0000-0000-0000-000000000000'); exception when others then e := sqlerrm; end;
  perform xe_record('X6.2 the hotel''s id is required too', e = 'EXIT: confirmation_mismatch', e);
  e := null;
  begin perform fn_hotel_exit_delete('12000000-0000-0000-0000-00000000000a', 'xe-ownera@test.local', '12000000-0000-0000-0000-00000000000a'); exception when others then e := sqlerrm; end;
  perform xe_record('X6.3 an e-mail address is not a confirmation', e = 'EXIT: confirmation_mismatch', e);
end $$;
reset role;
select xe_login(null);

-- the hotel changed after the copy: a new notification lands in it
insert into notifications(branch_id, title) values ('12000000-0000-0000-0000-0000000000a1', 'تنبيه بعد التصدير');
select xe_login('a2000000-0000-0000-0000-00000000000a');
set local role authenticated;
do $$ declare e text; v jsonb; begin
  begin perform fn_hotel_exit_delete('12000000-0000-0000-0000-00000000000a', 'فندق الخروج', '12000000-0000-0000-0000-00000000000a'); exception when others then e := sqlerrm; end;
  perform xe_record('X6.4 a change after the export blocks the deletion (export again first)', e like 'EXIT: export_stale%', e);
  v := fn_hotel_exit_verify((select x.v::uuid from xe_ctx x where x.k = 'archive2'));
  perform xe_record('X6.5 verify names the drifted table', not (v->>'ok')::boolean and v->'mismatches'->0 ? 'notifications', v::text);
  -- a fresh copy matches again…
  v := fn_hotel_exit_export('12000000-0000-0000-0000-00000000000a');
  insert into xe_ctx values ('archive3', v->>'archive_id');
end $$;
reset role;
select xe_login(null);
-- …and a corrupted copy also blocks it (the manifest no longer describes the hotel)
update hotel_exit_archives
   set manifest = jsonb_set(manifest, '{tables,rooms,rows}', '999')
 where id = (select x.v::uuid from xe_ctx x where x.k = 'archive3');
select xe_login('a2000000-0000-0000-0000-00000000000a');
set local role authenticated;
do $$ declare e text; v jsonb; begin
  begin perform fn_hotel_exit_delete('12000000-0000-0000-0000-00000000000a', 'فندق الخروج', '12000000-0000-0000-0000-00000000000a'); exception when others then e := sqlerrm; end;
  perform xe_record('X6.6 a corrupted export blocks the deletion', e like 'EXIT: export_stale%', e);
  v := fn_hotel_exit_export('12000000-0000-0000-0000-00000000000a');
  insert into xe_ctx values ('archive4', v->>'archive_id');
  perform xe_record('X6.7 re-exporting after the blocks is safe', (v->>'archive_id') is not null, null);
end $$;
reset role;
select xe_login(null);

-- ---------------------------------------------------------------- 7. the deliberate delete
select xe_snap('B1_pre', '12000000-0000-0000-0000-00000000000b');
select xe_login('a2000000-0000-0000-0000-00000000000a');
set local role authenticated;
do $$ declare r jsonb; begin
  r := fn_hotel_exit_delete('12000000-0000-0000-0000-00000000000a', 'فندق الخروج', '12000000-0000-0000-0000-00000000000a');
  perform xe_record('X7.1 the confirmed delete runs and reports what it removed', (r->>'ok')::boolean and (r->>'rows_removed')::bigint > 0, r::text);
end $$;
reset role;
select xe_login(null);
do $$
declare t record; n bigint; leftover text := ''; a4 uuid := (select x.v::uuid from xe_ctx x where x.k = 'archive4');
begin
  for t in select table_name from fn_hotel_exit_tables() where not retained loop
    execute format('select count(*) from public.%I where organization_id = $1', t.table_name) into n using '12000000-0000-0000-0000-00000000000a'::uuid;
    if n > 0 then leftover := leftover || t.table_name || ':' || n || ' '; end if;
  end loop;
  perform xe_record('X7.2 every tenancy table is empty of the hotel (the audit log is retained by design)', leftover = '', leftover);
  perform xe_record('X7.3 the registry row is a tombstone: exited, scrubbed, slug kept',
    (select exited_at is not null and license_status = 'exited' and name_en is null and guest_site_url is null
            and logo_bytes is null and guest_slug = 'hotel-exit-a' and exit_archive_id = a4
       from organizations where id = '12000000-0000-0000-0000-00000000000a'));
  perform xe_record('X7.4 the copy survives the deletion (restorable)',
    (select status from hotel_exit_archives where id = a4) = 'deleted'
    and (select count(*) from hotel_exit_rows where archive_id = a4) > 0);
  perform xe_record('X7.5 the hotel''s auth accounts are gone, the other hotel''s stays',
    not exists (select 1 from auth.users where id in ('a2000000-0000-0000-0000-00000000000a', 'a2000000-0000-0000-0000-0000000000a2'))
    and exists (select 1 from auth.users where id = 'a2000000-0000-0000-0000-00000000000b'));
  perform xe_record('X7.6 the exit is on the immutable record (export, suspend, delete)',
    (select count(*) from platform_events where organization_id = '12000000-0000-0000-0000-00000000000a'
       and action in ('hotel.exit_exported', 'hotel.exit_suspended', 'hotel.exit_deleted')) >= 3,
    (select string_agg(action, ' ' order by created_at) from platform_events where organization_id = '12000000-0000-0000-0000-00000000000a'));
  perform xe_record('X7.7 the hotel''s audit log is retained, unaltered',
    (select count(*) from audit_events where organization_id = '12000000-0000-0000-0000-00000000000a')
      = (select x.v::bigint from xe_ctx x where x.k = 'audit_count_A'));
  perform xe_snap('B1_post', '12000000-0000-0000-0000-00000000000b');
  perform xe_record('X7.8 hotel B is untouched by the exit', xe_b_diff('B1_pre', 'B1_post') is null, xe_b_diff('B1_pre', 'B1_post'));
end $$;

-- ---------------------------------------------------------------- 8. after the exit nobody can run it again
select xe_login('a2000000-0000-0000-0000-00000000000a');
set local role authenticated;
do $$ declare e text; begin
  begin perform fn_hotel_exit_export('12000000-0000-0000-0000-00000000000a'); exception when others then e := sqlerrm; end;
  perform xe_record('X8.1 re-exporting after the exit is refused (the owner row is gone)', e like 'FORBIDDEN%', e);
  e := null;
  begin perform fn_hotel_exit_delete('12000000-0000-0000-0000-00000000000a', 'فندق الخروج', '12000000-0000-0000-0000-00000000000a'); exception when others then e := sqlerrm; end;
  perform xe_record('X8.2 re-deleting after the exit is refused', e like 'FORBIDDEN%', e);
end $$;
reset role;
select xe_login(null);

-- ---------------------------------------------------------------- 9. restore
select xe_login('a2000000-0000-0000-0000-00000000000b');
set local role authenticated;
do $$ declare e text; begin
  begin perform fn_hotel_exit_restore('12000000-0000-0000-0000-00000000000a', (select x.v::uuid from xe_ctx x where x.k = 'archive4'), '12000000-0000-0000-0000-00000000000a'); exception when others then e := sqlerrm; end;
  perform xe_record('X9.1 the other hotel''s owner cannot restore it', e like 'FORBIDDEN%', e);
end $$;
reset role;
select xe_login('a2000000-0000-0000-0000-0000000000cc');
set local role authenticated;
do $$ declare e text; begin
  begin perform fn_hotel_exit_restore('12000000-0000-0000-0000-00000000000a', (select x.v::uuid from xe_ctx x where x.k = 'archive4'), '12000000-0000-0000-0000-00000000000a'); exception when others then e := sqlerrm; end;
  perform xe_record('X9.2 a stranger cannot restore it', e like 'FORBIDDEN%', e);
end $$;
reset role;
select xe_login('a2000000-0000-0000-0000-00000000000a');
set local role authenticated;
do $$ declare e text; begin
  begin perform fn_hotel_exit_restore('12000000-0000-0000-0000-00000000000a', (select x.v::uuid from xe_ctx x where x.k = 'archive4'), '00000000-0000-0000-0000-000000000000'); exception when others then e := sqlerrm; end;
  perform xe_record('X9.3 the restore needs the id confirmation', e = 'EXIT: confirmation_mismatch', e);
end $$;
do $$ declare r jsonb; begin
  r := fn_hotel_exit_restore('12000000-0000-0000-0000-00000000000a', (select x.v::uuid from xe_ctx x where x.k = 'archive4'), '12000000-0000-0000-0000-00000000000a');
  perform xe_record('X9.4 the owner restores the hotel from the copy', (r->>'ok')::boolean, r::text);
end $$;
reset role;
select xe_login(null);
do $$
declare t record; n bigint; bad text := ''; a4 uuid := (select x.v::uuid from xe_ctx x where x.k = 'archive4'); m jsonb;
begin
  select manifest into m from hotel_exit_archives where id = a4;
  for t in select table_name from fn_hotel_exit_tables() where not retained loop
    execute format('select count(*) from public.%I where organization_id = $1', t.table_name) into n using '12000000-0000-0000-0000-00000000000a'::uuid;
    if n <> coalesce((m->'tables'->t.table_name->>'rows')::bigint, 0) then bad := bad || t.table_name || ':' || n || '≠' || (m->'tables'->t.table_name->>'rows') || ' '; end if;
  end loop;
  perform xe_record('X9.5 every table is back with its exported count', bad = '', bad);
  perform xe_record('X9.6 the restored rows are the original rows (same ids, same content, files intact)',
    exists (select 1 from reservations where id = '12000000-0000-0000-0000-0000000000f1' and status = 'checked_out')
    and exists (select 1 from reservation_guests where reservation_id = '12000000-0000-0000-0000-0000000000f1' and full_name = 'نزيل أ')
    and exists (select 1 from guest_profiles where id = '12000000-0000-0000-0000-0000000000e1' and full_name = 'نزيل أ')
    and exists (select 1 from branch_media where branch_id = '12000000-0000-0000-0000-0000000000a1' and bytes = '\x01020304'::bytea)
    and exists (select 1 from notifications where branch_id = '12000000-0000-0000-0000-0000000000a1' and title = 'تنبيه بعد التصدير'));
  -- the copy was taken while suspended: the hotel comes back suspended (reactivation is the platform
  -- operator's call, 0082), never silently active
  perform xe_record('X9.7 the registry returns to its status at export (suspended), tombstone lifted',
    (select platform_status from organizations where id = '12000000-0000-0000-0000-00000000000a') = 'suspended'
    and (select exited_at from organizations where id = '12000000-0000-0000-0000-00000000000a') is null
    and (select exit_archive_id from organizations where id = '12000000-0000-0000-0000-00000000000a') is null);
  perform xe_record('X9.8 the hotel''s auth accounts are back',
    exists (select 1 from auth.users where id = 'a2000000-0000-0000-0000-00000000000a')
    and exists (select 1 from auth.users where id = 'a2000000-0000-0000-0000-0000000000a2'));
  perform xe_record('X9.9 the archive is marked restored',
    (select status from hotel_exit_archives where id = a4) = 'restored');
  perform xe_snap('B2_post', '12000000-0000-0000-0000-00000000000b');
  perform xe_record('X9.10 hotel B is still untouched', xe_b_diff('B0', 'B2_post') is null, xe_b_diff('B0', 'B2_post'));
end $$;
select xe_login('a2000000-0000-0000-0000-00000000000a');
set local role authenticated;
do $$ declare e text; v jsonb; begin
  begin perform fn_hotel_exit_restore('12000000-0000-0000-0000-00000000000a', (select x.v::uuid from xe_ctx x where x.k = 'archive4'), '12000000-0000-0000-0000-00000000000a'); exception when others then e := sqlerrm; end;
  perform xe_record('X9.11 a second restore of the same copy is refused', e = 'EXIT: not_deleted', e);
  v := fn_hotel_exit_verify((select x.v::uuid from xe_ctx x where x.k = 'archive4'));
  perform xe_record('X9.12 the restored hotel verifies against the copy', (v->>'ok')::boolean, v::text);
  -- and the whole cycle can start again on the restored hotel: deleting it now needs the order again
  begin perform fn_hotel_exit_delete('12000000-0000-0000-0000-00000000000a', 'فندق الخروج', '12000000-0000-0000-0000-00000000000a'); exception when others then e := sqlerrm; end;
  perform xe_record('X9.13 the restored hotel cannot be deleted without a fresh export', e = 'EXIT: export_required', e);
end $$;
reset role;
select xe_login(null);

-- ---------------------------------------------------------------- result
select case when ok then 'PASS' else 'FAIL' end as result, name, case when ok then null else detail end as detail
from xe_results order by name;
do $$
begin
  if exists (select 1 from xe_results where ok is not true) then raise exception 'HOTEL EXIT TESTS FAILED'; end if;
  if (select count(*) from xe_results) < 30 then raise exception 'HOTEL EXIT TESTS INCOMPLETE: % checks ran', (select count(*) from xe_results); end if;
end $$;
rollback;
