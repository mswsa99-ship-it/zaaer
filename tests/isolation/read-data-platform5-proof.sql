-- read-data lane, platform/exit/status five (read-only): fn_platform_operator_id, fn_platform_hotels, fn_hotel_exit_tables, fn_hotel_exit_verify, fn_backup_status.
-- Local disposable PG16, base fixtures.sql only, one rolled-back transaction, strict gate. Synthetic operator / archive / backup_runs fixtures inserted in-transaction.
-- No exit mutators, no auth/session changes, no protected function is called. Run: psql -X -d iso_* -v ON_ERROR_STOP=1 -v strict=1 -f tests/isolation/read-data-platform5-proof.sql
\set ON_ERROR_STOP on
begin;
create temp table res(spec text, actor text, ctx text, expect text, got text, ok boolean, detail text);
grant all on res to public;
create temp table orgs as select * from (values ('A','a1000000-0000-0000-0000-000000000001'::uuid),('B','a1000000-0000-0000-0000-000000000002'::uuid),('O','00000000-0000-0000-0000-000000000001'::uuid)) v(code, org);
grant all on orgs to public;
update organizations o set name_ar = 'MK-HOT-' || g.code from orgs g where g.org = o.id;
-- synthetic operators: OPX (not staff, active), OPI (not staff, inactive), owner A's own login also an operator (to test the suspended-session rule)
create temp table ops as select 'OPX'::text k, 'f0000000-0000-0000-0000-0000000000a1'::uuid u union all select 'OPI', 'f0000000-0000-0000-0000-0000000000a2'::uuid;
grant all on ops to public;
insert into platform_operators(auth_user_id, full_name, is_active) values ('f0000000-0000-0000-0000-0000000000a1', 'MK-OP-X', true), ('f0000000-0000-0000-0000-0000000000a2', 'MK-OP-I', false);
insert into platform_operators(auth_user_id, full_name, is_active) select auth_user, 'MK-OP-OWNERA', true from iso.actor where key = 'owner|hotel-a|-';
-- backup runs per org (marker run_ref), newest backup failed, one drill
insert into backup_runs(organization_id, kind, reason, status, started_at, finished_at, run_ref, size_bytes, sha256, tables_count, rows_total, verification)
  select g.org, 'backup', 'manual', 'success', now() - interval '2 hours', now() - interval '2 hours', 'MK-BK-' || g.code, 1000 + ascii(g.code), repeat(lower(to_hex(ascii(g.code))), 32), 10 + ascii(g.code) % 7, 500 + ascii(g.code), 'MK-VER-' || g.code from orgs g;
insert into backup_runs(organization_id, kind, reason, status, started_at, finished_at, run_ref, error)
  select g.org, 'backup', 'manual', 'failed', now() - interval '1 hour', now() - interval '1 hour', 'MK-FAIL-' || g.code, 'MK-ERR-' || g.code from orgs g;
insert into backup_runs(organization_id, kind, reason, status, started_at, finished_at, run_ref, verification)
  select g.org, 'restore_drill', 'drill', 'success', now() - interval '30 minutes', now() - interval '30 minutes', 'MK-DR-' || g.code, 'MK-DRV-' || g.code from orgs g;
-- exit archives: manifest computed independently (same row/hash definition, own SQL), for A and B; tampered / catalog-drift variants for A
create temp table arch(k text, org uuid, id uuid, requested_by uuid);
grant all on arch to public;
create or replace function pg_temp.mk_manifest(p_org uuid) returns jsonb language plpgsql as $f$
declare t text; flt text; rows bigint; sha text; m jsonb := '{}';
begin
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind in ('r','p') and not c.relispartition
     and c.relname not in ('platform_events','hotel_exit_archives','hotel_exit_rows','audit_events')
     and (c.relname = 'platform_support_grants' or exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'organization_id' and a.attnum > 0 and not a.attisdropped)) order by 1 loop
    flt := case when t = 'organizations' then 'id' else 'organization_id' end;
    execute format($q$select count(*)::bigint, encode(extensions.digest(coalesce(string_agg(r, E'\n' order by r), ''), 'sha256'), 'hex') from (select to_jsonb(x)::text r from public.%I x where x.%I = $1) s$q$, t, flt) into rows, sha using p_org;
    m := m || jsonb_build_object(t, jsonb_build_object('rows', rows, 'sha256', sha));
  end loop;
  return m;
end $f$;
grant execute on function pg_temp.mk_manifest(uuid) to public;
insert into arch select 'A-good', o.org, gen_random_uuid(), (select auth_user from iso.actor where key = 'owner|hotel-a|-') from orgs o where o.code = 'A';
insert into arch select 'B-good', o.org, gen_random_uuid(), (select auth_user from iso.actor where key = 'owner|hotel-b|-') from orgs o where o.code = 'B';
insert into arch select 'A-byop', o.org, gen_random_uuid(), 'f0000000-0000-0000-0000-0000000000a1' from orgs o where o.code = 'A';
insert into arch select 'A-tamper', o.org, gen_random_uuid(), (select auth_user from iso.actor where key = 'owner|hotel-a|-') from orgs o where o.code = 'A';
insert into arch select 'A-shatamper', o.org, gen_random_uuid(), (select auth_user from iso.actor where key = 'owner|hotel-a|-') from orgs o where o.code = 'A';
insert into arch select 'A-missing', o.org, gen_random_uuid(), (select auth_user from iso.actor where key = 'owner|hotel-a|-') from orgs o where o.code = 'A';
insert into arch select 'A-extra', o.org, gen_random_uuid(), (select auth_user from iso.actor where key = 'owner|hotel-a|-') from orgs o where o.code = 'A';
insert into hotel_exit_archives(id, organization_id, hotel_name, requested_by, prior_platform_status, table_count, row_count, overall_sha256, manifest)
  select a.id, a.org, 'MK-HOT-' || left(a.k, 1), a.requested_by, 'active', 1, 1, repeat('0', 64),
    jsonb_build_object('tables', case a.k when 'A-tamper' then jsonb_set(pg_temp.mk_manifest(a.org), '{branches,rows}', '999') when 'A-shatamper' then jsonb_set(pg_temp.mk_manifest(a.org), '{branches,sha256}', '"deadbeef"') when 'A-missing' then pg_temp.mk_manifest(a.org) - 'rooms'
             when 'A-extra' then pg_temp.mk_manifest(a.org) || '{"zz_not_a_table":{"rows":0,"sha256":"x"}}'::jsonb else pg_temp.mk_manifest(a.org) end) from arch a;
do $$ begin
  if (select count(*) from jsonb_object_keys((select manifest->'tables' from hotel_exit_archives h join arch a on a.id = h.id and a.k = 'A-good'))) < 20 then raise exception 'manifest precondition'; end if;
  if (select count(distinct x) from (select (manifest->'tables'->'branches'->>'rows') x from hotel_exit_archives h join arch a on a.id = h.id and a.k in ('A-good','B-good')) q) <> 1 then null; end if;
end $$;
create temp table spa_orig as select * from staff_page_access;
grant all on spa_orig to public;
-- hotel A is suspended in a later step (suspended staff session); keep original status to restore
do $$
declare a record; msg text; r jsonb; rt text; got text; exp_c text; ok boolean; det text; v_unused uuid; ocode text; arow record; ex jsonb; bad int; n int; sid uuid; v_org uuid; st text; b_before jsonb; b_after jsonb; k text; claim uuid;
begin
 -- ============ fn_hotel_exit_tables (pure catalog): independent oracle from pg_catalog
 perform iso.set_claims(null);
 create temp table tabs_exp on commit drop as select c.oid, c.relname::text t from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r','p') and not c.relispartition and c.relname not in ('platform_events','platform_support_grants','hotel_exit_archives','hotel_exit_rows')
     and exists (select 1 from pg_attribute x where x.attrelid = c.oid and x.attname = 'organization_id' and x.attnum > 0 and not x.attisdropped);
 for a in select * from (values ('owner|hotel-a|-'),('manager|hotel-b|branch-1'),('guest|-|-'),('operator')) v(k) loop
  claim := case a.k when 'operator' then 'f0000000-0000-0000-0000-0000000000a1'::uuid else (select auth_user from iso.actor where key = a.k) end;
  perform iso.set_claims(claim);
  set local role authenticated; create temp table got_t on commit drop as select * from fn_hotel_exit_tables(); reset role;
  ok := true; det := null;
  if (select array_agg(table_name order by table_name) from got_t) is distinct from (select array_agg(t order by t) from tabs_exp) then ok := false; det := 'table set differs from catalog oracle'; end if;
  if (select count(*) from got_t) < 100 then ok := false; det := 'ORACLE weak: fewer than 100 tables'; end if;
  if (select array_agg(seq order by seq) from got_t) is distinct from (select array_agg(g) from generate_series(1, (select count(*) from got_t)::int) g) then ok := false; det := 'seq not 1..n'; end if;
  if exists (select 1 from got_t where retained <> (table_name = 'audit_events')) then ok := false; det := 'retained flag wrong'; end if;
  select count(*) into bad from pg_constraint fk join tabs_exp ch on ch.oid = fk.conrelid join tabs_exp pa on pa.oid = fk.confrelid join got_t gc on gc.table_name = ch.t join got_t gp on gp.table_name = pa.t
    where fk.contype = 'f' and fk.conrelid <> fk.confrelid and gc.seq > gp.seq;
  if bad > 0 then ok := false; det := 'child after parent in ' || bad || ' FKs'; end if;
  insert into res values ('fn_hotel_exit_tables', a.k, 'authenticated', 'allow', 'allow', ok, det);
  drop table got_t;
 end loop;
 perform iso.set_claims(null); msg := null; set local role anon;
 begin perform * from fn_hotel_exit_tables(); exception when others then msg := sqlerrm; end; reset role;
 insert into res values ('fn_hotel_exit_tables', 'anon', 'anon', 'deny', case when msg is null then 'allow' else 'deny' end, msg is not null, msg);

 -- ============ operator identity and hotel list
 for a in select * from (values ('OPX','f0000000-0000-0000-0000-0000000000a1','allow'),('OPI','f0000000-0000-0000-0000-0000000000a2','deny'),('owner-a-operator',null,'allow'),
          ('manager-a-not-operator',null,'deny'),('owner-b-not-operator',null,'deny'),('guest',null,'deny'),('random-uuid','f0000000-0000-0000-0000-0000000000ff','deny'),('anon',null,'deny')) v(k, u, e) loop
  claim := case a.k when 'owner-a-operator' then (select auth_user from iso.actor where key = 'owner|hotel-a|-') when 'manager-a-not-operator' then (select auth_user from iso.actor where key = 'manager|hotel-a|branch-1')
     when 'owner-b-not-operator' then (select auth_user from iso.actor where key = 'owner|hotel-b|-') when 'guest' then null when 'anon' then null else a.u::uuid end;
  perform iso.set_claims(claim);
  msg := null; rt := null;
  if a.k = 'anon' then set local role anon; else set local role authenticated; end if;
  begin select fn_platform_operator_id()::text into rt; exception when others then msg := sqlerrm; end; reset role;
  got := case when msg is not null then 'deny' when rt is null then 'deny' else 'allow' end;
  ok := got = a.e and (a.e = 'deny' or rt = coalesce(a.u, claim::text));
  insert into res values ('fn_platform_operator_id', a.k, 'ctx', a.e, got, ok, coalesce(msg, rt));
  msg := null; r := null;
  if a.k = 'anon' then set local role anon; else set local role authenticated; end if;
  begin r := fn_platform_hotels(); exception when others then msg := sqlerrm; end; reset role;
  got := case when msg is null then 'allow' when msg like 'FORBIDDEN%' or msg like 'permission denied%' then 'deny' else 'error' end;
  ok := got = a.e; det := msg;
  if ok and got = 'allow' then
    ex := (select jsonb_agg(jsonb_build_object('id', o.id, 'name_ar', o.name_ar, 'slug', o.guest_slug, 'status', o.platform_status, 'branches', (select count(*) from branches b where b.organization_id = o.id)) order by o.created_at) from organizations o);
    if jsonb_array_length(r) <> 3 then ok := false; det := 'hotel count ' || jsonb_array_length(r); end if;
    if (select jsonb_agg(to_jsonb(q) - 'pending_owner_id' - 'owner_invited' order by ord) from (select e.value - 'pending_owner_id' - 'owner_invited' as q, e.ordinality ord from jsonb_array_elements(r) with ordinality e) z) is distinct from ex then ok := false; det := 'EXACT mismatch ' || left(r::text, 200); end if;
    if not exists (select 1 from jsonb_array_elements(r) e where e->>'name_ar' = 'MK-HOT-A' and (e->>'branches')::int = 2) or not exists (select 1 from jsonb_array_elements(r) e where e->>'name_ar' = 'MK-HOT-O' and (e->>'branches')::int = 1) then ok := false; det := 'marker/branch count missing'; end if;
    if exists (select 1 from jsonb_array_elements(r) e where (e->>'owner_invited')::boolean is distinct from (select bool_or(s.auth_user_id is not null) from staff_profiles s where s.organization_id = (e->>'id')::uuid and s.role = 'owner')) then ok := false; det := 'owner_invited mismatch'; end if;
  end if;
  insert into res values ('fn_platform_hotels', a.k, 'ctx', a.e, got, ok, det);
 end loop;
 -- suspended hotel: staff session of a suspended hotel loses operator identity even if listed as operator
 update organizations set platform_status = 'suspended' where id = (select org from orgs where code = 'A');
 perform iso.set_claims((select auth_user from iso.actor where key = 'owner|hotel-a|-'));
 set local role authenticated; rt := fn_platform_operator_id()::text; reset role;
 insert into res values ('fn_platform_operator_id', 'owner-a-operator', 'hotel-A-suspended', 'deny', case when rt is null then 'deny' else 'allow' end, rt is null, rt);
 perform iso.set_claims('f0000000-0000-0000-0000-0000000000a1'); set local role authenticated; r := fn_platform_hotels(); reset role;
 insert into res values ('fn_platform_hotels', 'OPX', 'hotel-A-suspended', 'allow', 'allow', exists (select 1 from jsonb_array_elements(r) e where e->>'name_ar' = 'MK-HOT-A' and e->>'status' = 'suspended'), left(r::text, 120));
 update organizations set platform_status = 'active' where id = (select org from orgs where code = 'A');

 -- ============ per-actor: exit_verify and backup_status
 for a in select * from iso.actor order by hotel nulls first, role, branch loop
  b_before := iso.snap();
  select organization_id, id into v_org, sid from staff_profiles where auth_user_id = a.auth_user;
  ocode := case a.hotel when 'hotel-a' then 'A' when 'hotel-b' then 'B' else null end;
  perform iso.set_claims(a.auth_user);
  -- fn_hotel_exit_verify: requester or active owner of the archive's hotel only
  for arow in select * from arch order by k loop
    exp_c := case when a.auth_user is null then 'deny' when arow.requested_by = a.auth_user or (a.role = 'owner' and v_org = arow.org) then 'allow' else 'deny' end;
    msg := null; r := null; set local role authenticated;
    begin r := fn_hotel_exit_verify(arow.id); exception when others then msg := sqlerrm; end; reset role;
    got := case when msg is null then 'allow' when msg like 'FORBIDDEN%' then 'deny' when msg like 'EXIT: archive_catalog_outdated' then 'outdated' else 'error' end;
    ok := true; det := msg;
    if exp_c = 'deny' then ok := got = 'deny';
    elsif arow.k in ('A-missing','A-extra') then ok := got = 'outdated'; exp_c := 'outdated';
    elsif got <> 'allow' then ok := false;
    elsif arow.k = 'A-tamper' then
      ok := (r->>'ok') = 'false' and jsonb_array_length(r->'mismatches') = 1 and (r->'mismatches'->0->'branches'->>'expected') = '999'
            and (r->'mismatches'->0->'branches'->>'found')::int = (select count(*) from branches where organization_id = arow.org);
      det := left(r::text, 160);
    elsif arow.k = 'A-shatamper' then
      ok := (r->>'ok') = 'false' and jsonb_array_length(r->'mismatches') = 1 and r->'mismatches'->0 ? 'branches'; det := left(r::text, 160);
    else
      ok := (r->>'ok') = 'true' and (r->>'checked')::int = (select count(*) from jsonb_object_keys((select manifest->'tables' from hotel_exit_archives where id = arow.id))) and r->'mismatches' = '[]'::jsonb;
      det := left(r::text, 160);
    end if;
    insert into res values ('fn_hotel_exit_verify', a.key, arow.k, exp_c, got, ok, det);
  end loop;
  msg := null; set local role authenticated;
  begin r := fn_hotel_exit_verify('99999999-9999-9999-9999-999999999999'); exception when others then msg := sqlerrm; end; reset role;
  insert into res values ('fn_hotel_exit_verify', a.key, 'unknown-id', 'deny', case when msg like 'NOT_FOUND%' or msg like 'FORBIDDEN%' then 'deny' else 'allow' end, msg like 'NOT_FOUND%' or msg like 'FORBIDDEN%', msg);
  -- fn_backup_status: owner of the caller's hotel, page grant in individual mode; content must be that hotel's markers only
  if ocode is not null then
   for st in select unnest(array['legacy','ind-full','ind-none']) loop
    delete from staff_page_access where staff_id = sid;
    if st = 'ind-full' then insert into staff_page_access(staff_id, organization_id, enabled, page_grants) values (sid, v_org, true, '{"/admin/backups":{"view":true}}'::jsonb); end if;
    if st = 'ind-none' then insert into staff_page_access(staff_id, organization_id, enabled, page_grants) values (sid, v_org, true, '{}'::jsonb); end if;
    exp_c := case when a.role = 'owner' and st in ('legacy','ind-full') then 'allow' when a.role = 'owner' then 'allow' else 'deny' end;
    msg := null; r := null; set local role authenticated;
    begin r := fn_backup_status(); exception when others then msg := sqlerrm; end; reset role;
    got := case when msg is null then 'allow' when msg like 'FORBIDDEN%' then 'deny' else 'error' end; ok := got = exp_c; det := msg;
    if ok and got = 'allow' then
      if r->'last_success'->>'run_ref' <> 'MK-BK-' || ocode or r->'last_success'->>'verification' <> 'MK-VER-' || ocode
         or (r->'last_success'->>'size_bytes')::bigint <> 1000 + ascii(ocode) or (r->'last_success'->>'sha256') <> repeat(lower(to_hex(ascii(ocode))), 32)
         or r->'last_run'->>'status' <> 'failed' or r->'last_run'->>'error' <> 'MK-ERR-' || ocode
         or r->'last_restore_drill'->>'verification' <> 'MK-DRV-' || ocode or (r->>'failures_since_last_success')::int <> 1 then ok := false; det := 'EXACT mismatch ' || left(r::text, 240); end if;
      if r::text ~ 'MK-[A-Z]+-[A-Z]' and r::text ~* ('MK-[A-Z]+-' || (case ocode when 'A' then '[BO]' else '[AO]' end)) then ok := false; det := 'LEAK foreign marker'; end if;
    end if;
    insert into res values ('fn_backup_status', a.key, st, exp_c, got, ok, det);
   end loop;
   delete from staff_page_access where staff_id = sid; insert into staff_page_access select * from spa_orig where staff_id = sid;
  end if;
  b_after := iso.snap();
  insert into res values ('SNAPSHOT', a.key, '-', 'no-write', case when iso.snap_diff(b_before, b_after) = '{}'::jsonb then 'no-write' else 'WROTE' end, iso.snap_diff(b_before, b_after) = '{}'::jsonb, null);
 end loop;
 perform iso.set_claims(null); set local role anon; msg := null;
 begin perform fn_backup_status(); exception when others then msg := sqlerrm; end; reset role;
 insert into res values ('fn_backup_status', 'anon', '-', 'deny', case when msg is null then 'allow' else 'deny' end, msg is not null, msg);
 set local role anon; msg := null;
 begin perform fn_hotel_exit_verify((select id from arch limit 1)); exception when others then msg := sqlerrm; end; reset role;
 insert into res values ('fn_hotel_exit_verify', 'anon', '-', 'deny', case when msg is null then 'allow' else 'deny' end, msg is not null, msg);
end $$;

select spec, count(*) calls, count(*) filter (where expect = 'allow') allow_exp, count(*) filter (where expect in ('deny','outdated')) deny_exp, count(*) filter (where not ok) failures from res group by 1 order by 1;
select * from res where not ok or detail like 'ORACLE%' order by spec, actor, ctx limit 60;
select count(*) total_calls, count(*) filter (where not ok) failures from res;
select (:strict = 1 and exists (select 1 from res where not ok)) as fail \gset
\if :fail
  select 1/0 as read_data_platform5_strict_failure;
\endif
rollback;
