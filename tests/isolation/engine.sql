-- =====================================================================
-- Plan item 2.11 isolation gate: engine (definitions only, no probes here).
-- Experimental partial runner. No complete RPC adapters or role-operation oracle yet.
-- Everything lives in schema iso; probes run through a generated wrapper
-- that sets role + JWT claims per actor (see iso.emit_wrapper()).
-- Denial classes: FORBIDDEN:/TENANT:/42501 = permission; VALIDATION:/LIMIT:/
-- IMMUTABLE:/23xxx = data/business; anything else = unattributed.
-- A probe that errors leaves no side effects (statement atomicity); a probe
-- that succeeds is measured and then rolled back inside its savepoint.
-- =====================================================================
\set ON_ERROR_STOP on
create schema if not exists iso;

-- ---------------------------------------------------------------- ids
create table if not exists iso.ids(key text primary key, id uuid);
create or replace function iso.id(p_key text) returns uuid language sql stable as
  $$ select id from iso.ids where key = p_key $$;

-- scope per table, loaded from supabase/tenancy.json by run.sh
create table if not exists iso.scope(tbl text primary key, scope text not null check (scope in ('platform','hotel','branch')));

-- registry of every row the seeder creates (FK targets and probe victims)
create table if not exists iso.created(
  tbl text not null, id text not null, org uuid, branch uuid, purpose text not null default 'victim',
  primary key (tbl, id));

-- column-level seed/probe value overrides: $ORG$, $BRANCH$, $SALT$ placeholders
create table if not exists iso.col_override(tbl text, col text, expr text, primary key (tbl, col));

-- tables the seeder must skip (populated by hand in fixtures.sql)
create table if not exists iso.seed_skip(tbl text primary key, reason text not null);

-- function adapter registry
create table if not exists iso.fn_adapter(
  signature text primary key, kind text not null check (kind in ('generic','custom','unsupported')),
  reason text);

-- probe results: one row per executed probe (a probe may back many matrix cells)
create table if not exists iso.probe_result(
  probe_id text primary key,        -- surface|name|op|actorKey|targetKey
  surface text not null, name text not null, op text not null,
  actor_key text not null, target_key text not null,
  outcome text not null,            -- success | denied | control-ok | control-failed | adapter-incomplete
  errclass text,                    -- permission | validation | unattributed | null
  sqlstate text, sqlerrm text,
  rows_ret integer,                 -- rows returned/affected
  side_effect boolean,              -- measured before rollback for successful write probes
  detail text);

-- matrix-cell results (one row per matrix cell, id identical to matrix-generator's)
create table if not exists iso.cell_result(
  id text primary key, outcome text not null check (outcome in ('pass','fail')),
  evidence text not null, expectation text not null, observed text not null);

create table if not exists iso.seed_error(tbl text, target text, state text, message text);

-- ---------------------------------------------------------------- actors
-- actor keys: owner-a, manager-a-1, supervisor-a-2, finance-b-1, housekeeping-b-2, guest, ...
create table if not exists iso.actor(
  key text primary key, role text not null, hotel text, branch text,   -- hotel/branch: a/b and 1/2 (nominal for owner/guest)
  auth_user uuid, db_role text not null);

create or replace function iso.set_claims(p_auth_user uuid) returns void language plpgsql as $$
begin
  if p_auth_user is null then
    perform set_config('request.jwt.claim.sub', '', false);
    perform set_config('request.jwt.claims', '', false);
  else
    perform set_config('request.jwt.claim.sub', p_auth_user::text, false);
    perform set_config('request.jwt.claims', json_build_object('sub', p_auth_user)::text, false);
  end if;
end $$;

-- ---------------------------------------------------------------- snapshot
-- per-table, per-hotel row count + content hash; security definer so it reads regardless of role/RLS.
create or replace function iso.snap() returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; o record; acc jsonb := '{}'::jsonb; slice jsonb; has_org boolean;
begin
  for r in select c.relname as t from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' order by 1 loop
    has_org := exists (select 1 from pg_attribute a where a.attrelid = ('public.'||r.t)::regclass and a.attname = 'organization_id' and not a.attisdropped);
    if has_org then
      execute format('select jsonb_object_agg(coalesce(o,''-''), jsonb_build_array(n,h)) from (
                        select organization_id::text o, count(*) n, md5(coalesce(string_agg(h,'''' order by h),'''')) h
                        from (select md5(t::text) h, t.organization_id from public.%I t) s group by 1) q', r.t) into slice;
    else
      execute format('select jsonb_build_object(''-'', jsonb_build_array(count(*), md5(coalesce(string_agg(h,'''' order by h),''''))))
                        from (select md5(t::text) h from public.%I t) s', r.t) into slice;
    end if;
    acc := acc || jsonb_build_object(r.t, coalesce(slice,'{}'::jsonb));
  end loop;
  return acc;
end $$;

-- diff of two snapshots: jsonb {table: {org: {before, after}}} for changed slices only
create or replace function iso.snap_diff(p_before jsonb, p_after jsonb) returns jsonb language sql immutable as $$
  select coalesce(jsonb_object_agg(k, jsonb_build_object('before', p_before->k, 'after', p_after->k)), '{}'::jsonb)
  from (select jsonb_object_keys(p_before || p_after) as k) keys
  where p_before->k is distinct from p_after->k
$$;

-- ---------------------------------------------------------------- generic row builder
-- value expression for one column; p_org/p_branch are the victim hotel/branch, p_salt makes text unique.
create or replace function iso.col_value(p_tbl text, p_col text, p_type text, p_org uuid, p_branch uuid, p_salt text)
returns text language plpgsql stable set search_path = public, pg_temp as $$
declare ov text; fk record; lbl text;
begin
  select expr into ov from iso.col_override where tbl = p_tbl and col = p_col;
  if found then
    return replace(replace(replace(ov, '$ORG$', quote_literal(p_org)), '$BRANCH$', coalesce(quote_literal(p_branch),'null')), '$SALT$', quote_literal(p_salt));
  end if;
  if p_col = 'organization_id' then return quote_literal(p_org) || '::uuid'; end if;
  if p_col = 'branch_id' then
    if p_branch is null then return 'null::uuid'; end if;
    return quote_literal(p_branch) || '::uuid';
  end if;
  -- single-column foreign key: prefer a row the seeder already registered for the same hotel/branch
  select cf.relname as ref into fk from pg_constraint con
    join pg_class cf on cf.oid = con.confrelid
    join pg_attribute af on af.attrelid = con.conrelid and af.attnum = con.conkey[1]
   where con.conrelid = ('public.'||p_tbl)::regclass and con.contype = 'f' and array_length(con.conkey,1) = 1
     and af.attname = p_col and cf.relnamespace = 'public'::regnamespace;
  if found then
    return format('(select c.id::uuid from iso.created c where c.tbl = %L and c.org = %L::uuid order by (c.branch is distinct from %L::uuid), c.id limit 1)',
                  fk.ref, p_org, p_branch);
  end if;
  -- a value the table's own check constraints allow for this column (first literal compared against it)
  if p_type in ('text','character varying','character') then
    select (regexp_match(pg_get_constraintdef(con.oid), '\m' || p_col || '\M[^'']*''([^'']+)'''))[1] into lbl
      from pg_constraint con
     where con.conrelid = ('public.'||p_tbl)::regclass and con.contype = 'c'
       and pg_get_constraintdef(con.oid) ~ ('\m' || p_col || '\M')
     order by con.oid limit 1;
    if lbl is not null then return quote_literal(lbl); end if;
  end if;
  -- enum first label
  select e.enumlabel into lbl from pg_type ty join pg_enum e on e.enumtypid = ty.oid
   where ty.typname = p_type order by e.enumsortorder limit 1;
  if found then return quote_literal(lbl) || '::' || p_type; end if;
  case p_type
    when 'text', 'character varying', 'character' then return quote_literal('ISO-' || p_salt);
    when 'uuid' then return 'gen_random_uuid()';
    when 'integer', 'smallint', 'bigint' then return '1';
    when 'numeric', 'real', 'double precision' then return '1';
    when 'boolean' then return 'true';
    when 'date' then return 'current_date';
    when 'timestamp with time zone', 'timestamp without time zone' then return 'now()';
    when 'time without time zone' then return '''10:00''::time';
    when 'jsonb', 'json' then return '''{}''::jsonb';
    when 'bytea' then return '''\\x01''::bytea';
    when 'inet' then return '''127.0.0.1''::inet';
    else
      if p_type like '%[]' or p_type like '%ARRAY' then return '''{}''::' || p_type; end if;
      return quote_literal('ISO-' || p_salt);
  end case;
end $$;

-- ---------------------------------------------------------------- primary key helpers (some singleton tables key on organization_id)
create or replace function iso.pk_col(p_tbl text) returns text language sql stable set search_path = public, pg_temp as $$
  select coalesce(
    (select a.attname from pg_attribute a where a.attrelid = ('public.'||p_tbl)::regclass and a.attname = 'id' and not a.attisdropped),
    (select a.attname from pg_constraint con join pg_attribute a on a.attrelid = con.conrelid and a.attnum = con.conkey[1]
      where con.conrelid = ('public.'||p_tbl)::regclass and con.contype = 'p' and array_length(con.conkey,1) = 1 limit 1),
    null)
$$;
create or replace function iso.pk_type(p_tbl text) returns text language sql stable set search_path = public, pg_temp as $$
  select format_type(a.atttypid, a.atttypmod) from pg_attribute a
   where a.attrelid = ('public.'||p_tbl)::regclass and a.attname = iso.pk_col(p_tbl) and not a.attisdropped
$$;

-- ---------------------------------------------------------------- seeder
-- insert one generic valid row into p_tbl for (p_org, p_branch); returns the new id or null when a
-- parent row is still missing (the caller retries on the next pass). Errors propagate to the caller's
-- exception handler with the statement logged.
create or replace function iso.try_seed(p_tbl text, p_org uuid, p_branch uuid, p_purpose text, p_salt text)
returns text language plpgsql set search_path = public, pg_temp as $$
declare cols text[]; vals text[]; c record; new_id text; pk text; missing_fk boolean := false;
begin
  pk := iso.pk_col(p_tbl);
  if pk is null then raise exception 'ISO_ADAPTER_INCOMPLETE: composite primary key'; end if;
  for c in select a.attname as name, format_type(a.atttypid, a.atttypmod) as typ, a.attnotnull as nn,
                  (ad.adbin is not null or a.attidentity <> '') as has_def
             from pg_attribute a left join pg_attrdef ad on ad.adrelid = a.attrelid and ad.adnum = a.attnum
            where a.attrelid = ('public.'||p_tbl)::regclass and a.attnum > 0 and not a.attisdropped
            order by a.attnum loop
    if c.name = 'organization_id' or c.name = 'branch_id' or (c.nn and not c.has_def)
       or exists (select 1 from iso.col_override o where o.tbl = p_tbl and o.col = c.name) then
      cols := cols || c.name;
      vals := vals || iso.col_value(p_tbl, c.name, c.typ, p_org, p_branch, p_salt);
    end if;
  end loop;
  -- a null FK expression means the parent is not seeded yet: defer
  select exists (select 1 from unnest(vals) v where v is null) into missing_fk;
  if missing_fk then return null; end if;
  execute format('insert into public.%I (%s) values (%s) returning %I::text', p_tbl,
                 array_to_string(cols, ', '), array_to_string(vals, ', '), pk) into new_id;
  insert into iso.created(tbl, id, org, branch, purpose) values (p_tbl, new_id, p_org, p_branch, p_purpose);
  return new_id;
end $$;

-- victim scopes: (hotel a, branch 1), (a,2), (b,1), (b,2); hotel-scope tables use branch null.
create table if not exists iso.target(key text primary key, hotel text not null, branch text, org uuid not null, branch_id uuid);

-- seed victims + one sacrificial row (delete target) per scope; fixpoint over deferred tables.
create or replace function iso.seed_all() returns void language plpgsql set search_path = public, pg_temp as $$
declare t record; tg record; pass int; outstanding int; new_id text; scope_branch uuid;
begin
  for pass in 1..8 loop
    outstanding := 0;
    for t in select s.tbl, s.scope from iso.scope s where s.scope in ('hotel','branch') and s.tbl not in (select tbl from iso.seed_skip) order by s.tbl loop
      for tg in select * from iso.target order by key loop
        scope_branch := case when t.scope = 'branch' then tg.branch_id else null end;
        if not exists (select 1 from iso.created c where c.tbl = t.tbl and c.org = tg.org and c.branch is not distinct from scope_branch and c.purpose = 'victim') then
          begin
            new_id := iso.try_seed(t.tbl, tg.org, scope_branch, 'victim', tg.key || '-' || pass);
            if new_id is null then outstanding := outstanding + 1; end if;
          exception when others then
            outstanding := outstanding + 1;
            if pass = 8 then insert into iso.seed_error values(t.tbl,tg.key,sqlstate,sqlerrm); end if;
          end;
        end if;
      end loop;
    end loop;
    exit when outstanding = 0;
  end loop;
  -- sacrificial rows for delete probes (children keep pointing at the victim rows)
  for pass in 1..8 loop
    outstanding := 0;
    for t in select s.tbl, s.scope from iso.scope s where s.scope in ('hotel','branch') and s.tbl not in (select tbl from iso.seed_skip) order by s.tbl loop
      if not exists (select 1 from iso.created c where c.tbl = t.tbl and c.purpose = 'sacrificial') then
        begin
          -- one sacrificial row in hotel a branch 1 (or hotel scope a) is enough: the delete control proves the payload,
          -- delete attacks aim at the victim rows of each scope
          perform iso.try_seed(t.tbl, iso.id('org-a'),
                    case when t.scope = 'branch' then iso.id('branch-a-1') end, 'sacrificial', 'sac-' || pass);
        exception when others then null;
        end;
      end if;
    end loop;
    exit when outstanding = 0;
  end loop;
end $$;

-- ---------------------------------------------------------------- error classification
create or replace function iso.err_class(p_state text, p_msg text) returns text language sql immutable as $$
  select case
    when p_state = '42501' then 'permission'
    when p_msg like 'FORBIDDEN:%' or p_msg like 'TENANT:%' or p_msg like 'TOKEN_INVALID%' then 'permission'
    when p_msg like 'VALIDATION:%' or p_msg like 'LIMIT:%' or p_msg like 'IMMUTABLE:%' then 'validation'
    when p_state like '23%' then 'validation'
    else 'unattributed'
  end $$;

-- ---------------------------------------------------------------- probe statements
-- every probe statement returns jsonb {matched: rows of the victim slice reached, total: rows touched}
create or replace function iso.victim_id(p_tbl text, p_target text) returns text language sql stable set search_path = public, pg_temp as $$
  select c.id from iso.created c join iso.target t on t.key = p_target
   where c.tbl = p_tbl and c.org = t.org and c.purpose = 'victim'
     and c.branch is not distinct from case when (select scope from iso.scope where tbl = p_tbl) = 'branch' then t.branch_id end
   order by c.id limit 1
$$;

create or replace function iso.mutable_col(p_tbl text) returns text language sql stable set search_path = public, pg_temp as $$
  select coalesce(
    (select a.attname from pg_attribute a
      where a.attrelid = ('public.'||p_tbl)::regclass and a.attnum > 0 and not a.attisdropped
        and a.attname = any (array['updated_at','notes','name','title','content_ar','description','summary','raw_body','question','answer','name_ar','full_name','reason','detail'])
      order by array_position(array['updated_at','notes','name','title','content_ar','description','summary','raw_body','question','answer','name_ar','full_name','reason','detail'], a.attname) limit 1),
    null)
$$;

create or replace function iso.stmt_for(p_tbl text, p_op text, p_target text, p_salt text) returns text language plpgsql stable set search_path = public, pg_temp as $$
declare v text; org uuid; br uuid; cols text[]; vals text[]; c record; mc text; pk text; pkt text;
begin
  pk := iso.pk_col(p_tbl); pkt := iso.pk_type(p_tbl);
  if pk is null or pkt is null then return null; end if;
  v := iso.victim_id(p_tbl, p_target);
  select t.org, case when s.scope = 'branch' then t.branch_id end into org, br
    from iso.target t join iso.scope s on s.tbl = p_tbl where t.key = p_target;
  if p_op = 'read' then
    if v is null then return null; end if;
    return format('select jsonb_build_object(''matched'', count(*), ''total'', count(*)) from (select 1 from public.%I where %I = %L::%s) s', p_tbl, pk, v, pkt);
  elsif p_op = 'create' then
    for c in select a.attname as name, format_type(a.atttypid, a.atttypmod) as typ, a.attnotnull as nn,
                    (ad.adbin is not null or a.attidentity <> '') as has_def
               from pg_attribute a left join pg_attrdef ad on ad.adrelid = a.attrelid and ad.adnum = a.attnum
              where a.attrelid = ('public.'||p_tbl)::regclass and a.attnum > 0 and not a.attisdropped order by a.attnum loop
      if c.name = 'organization_id' or c.name = 'branch_id' or (c.nn and not c.has_def)
         or exists (select 1 from iso.col_override o where o.tbl = p_tbl and o.col = c.name) then
        cols := cols || c.name;
        vals := vals || iso.col_value(p_tbl, c.name, c.typ, org, br, p_salt);
      end if;
    end loop;
    if exists (select 1 from unnest(vals) val where val is null) then return null; end if;  -- parent row unavailable: adapter incomplete
    return format('with i as (insert into public.%I (%s) values (%s) returning organization_id) select jsonb_build_object(''matched'', count(*) filter (where organization_id = %L::uuid), ''total'', count(*)) from i',
                  p_tbl, array_to_string(cols, ', '), array_to_string(vals, ', '), org);
  elsif p_op = 'update' then
    if v is null then return null; end if;
    mc := iso.mutable_col(p_tbl);
    if mc is null then return null; end if;
    return format('with u as (update public.%I set %I = %I where %I = %L::%s returning 1) select jsonb_build_object(''matched'', count(*), ''total'', count(*)) from u', p_tbl, mc, mc, pk, v, pkt);
  elsif p_op = 'delete' then
    if v is null then return null; end if;
    return format('with d as (delete from public.%I where %I = %L::%s returning 1) select jsonb_build_object(''matched'', count(*), ''total'', count(*)) from d', p_tbl, pk, v, pkt);
  end if;
end $$;

-- ---------------------------------------------------------------- single probe
-- runs one statement as the current role, measures, rolls back. p_before: group snapshot baseline.
create or replace function iso.probe_one(p_probe_id text, p_surface text, p_name text, p_op text,
                                         p_actor_key text, p_target_key text, p_stmt text, p_before jsonb) returns void
language plpgsql set search_path = public, extensions, pg_temp as $$
declare res jsonb; snap_after jsonb; diff jsonb := '{}'::jsonb; matched int := 0; total int := 0;
        out text; ecl text; est text; emsg text;
begin
  if p_stmt is null then
    insert into iso.probe_result values (p_probe_id, p_surface, p_name, p_op, p_actor_key, p_target_key,
      'adapter-incomplete', null, null, null, null, null, 'no victim row or no valid payload for this table/op/target');
    return;
  end if;
  begin
    execute p_stmt into res;
    matched := coalesce((res->>'matched')::int, 0);
    total := coalesce((res->>'total')::int, 0);
    if true then
      snap_after := iso.snap();
      diff := iso.snap_diff(p_before, snap_after);
    end if;
    raise exception 'ISO_ROLLBACK';
  exception
    when others then
      if sqlstate = 'P0001' and sqlerrm = 'ISO_ROLLBACK' then
        insert into iso.probe_result values (p_probe_id, p_surface, p_name, p_op, p_actor_key, p_target_key,
          'success', null, null, null, matched, diff <> '{}'::jsonb, left(diff::text, 4000));
      else
        insert into iso.probe_result values (p_probe_id, p_surface, p_name, p_op, p_actor_key, p_target_key,
          'denied', iso.err_class(sqlstate, sqlerrm), sqlstate, left(sqlerrm, 500), null, false, null);
      end if;
  end;
end $$;

-- ---------------------------------------------------------------- probe queue (tables)
-- one probe per (table, op, identity, target). Cells map onto these probes in probes.sql.
create or replace function iso.run_actor_tables(p_actor_key text) returns void
language plpgsql set search_path = public, pg_temp as $$
declare a record; grp record; p record; before jsonb; stmt text; probe_id text;
begin
  select * into a from iso.actor where key = p_actor_key;
  for grp in select s.tbl, o.op from iso.scope s cross join (values ('read'),('create'),('update'),('delete')) o(op)
              where s.scope in ('hotel','branch') order by s.tbl, o.op loop
    before := iso.snap();
    for p in select t.key as target from iso.target t order by t.key loop
      probe_id := 'table|' || grp.tbl || '|' || grp.op || '|' || p_actor_key || '|' || p.target;
      stmt := iso.stmt_for(grp.tbl, grp.op, p.target, p_actor_key || '-' || p.target);
      perform iso.probe_one(probe_id, 'table', grp.tbl, grp.op, p_actor_key, p.target, stmt, before);
    end loop;
  end loop;
end $$;

-- ---------------------------------------------------------------- controls (run as superuser)
-- Exact statement-shape controls run before attacks. Failures remain failures, never permission evidence.
create or replace function iso.run_controls() returns void
language plpgsql set search_path = public, pg_temp as $$
declare grp record; p record; v text; stmt text; before jsonb; op_name text;
begin
  for grp in select s.tbl, s.scope from iso.scope s where s.scope in ('hotel','branch') order by s.tbl loop
    before := iso.snap();
    for p in select * from iso.target order by key loop
      v := iso.victim_id(grp.tbl, p.key);
      if v is null then
        insert into iso.probe_result values ('table|'||grp.tbl||'|create|control|'||p.key, 'table', grp.tbl, 'create', 'control', p.key,
          'control-failed', 'unattributed', null, null, null, null, 'seeder produced no victim row for this target (see run log)');
        continue;
      end if;
      -- Execute the exact operation shape; a seed row alone is not a positive CRUD control.
      for op_name in select unnest(array['read','create','update','delete']) loop
        stmt := iso.stmt_for(grp.tbl, op_name, p.key, 'control-' || p.key);
        perform iso.probe_one('table|'||grp.tbl||'|'||op_name||'|control|'||p.key,
          'table',grp.tbl,op_name,'control',p.key,stmt,before);
      end loop;
    end loop;
  end loop;
  -- relabel successful control probes as control-ok (probe_one wrote them as success)
  update iso.probe_result set outcome = 'control-ok' where actor_key = 'control' and outcome = 'success';
end $$;

-- ---------------------------------------------------------------- grants: probes run as the actor role and write results
grant usage on schema iso to anon, authenticated;
grant select on iso.ids, iso.scope, iso.created, iso.col_override, iso.seed_skip, iso.target, iso.actor, iso.fn_adapter to anon, authenticated;
grant insert on iso.probe_result, iso.cell_result to anon, authenticated;
grant execute on all functions in schema iso to anon, authenticated;

-- ---------------------------------------------------------------- wrapper emitter
-- run.sh executes: SELECT iso.emit_wrapper() -> a psql script of role sections.
create or replace function iso.emit_wrapper() returns text language plpgsql stable set search_path = public, pg_temp as $$
declare a record; acc text := E'select iso.set_claims(null);\nselect iso.run_controls();\n';
begin
  for a in select * from iso.actor order by key loop
    acc := acc || E'set role ' || a.db_role || E';\n'
        || format(E'select iso.set_claims(%s);\n', case when a.auth_user is null then 'null' else quote_literal(a.auth_user) || '::uuid' end)
        || format(E'select iso.run_actor_tables(%L);\n', a.key)
        || E'reset role;\n';
  end loop;
  acc := acc || E'select iso.set_claims(null);\n';
  return acc;
end $$;
