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


-- columns inside a unique index (primary key included) other than the tenant columns: a create payload varies them
-- so a duplicate-key error cannot hide a permission result.
create or replace function iso.in_uniq(p_tbl text, p_col text) returns boolean language sql stable set search_path = public, pg_temp as $$
  select exists (select 1 from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any (i.indkey)
                  where i.indrelid = ('public.'||p_tbl)::regclass and i.indisunique and a.attname = p_col
                    and p_col not in ('organization_id','branch_id'))
$$;
-- true when every unique index of the table consists of tenant columns only (one row per hotel/branch slot)
create or replace function iso.is_singleton(p_tbl text) returns boolean language sql stable set search_path = public, pg_temp as $$
  select exists (select 1 from pg_index i where i.indrelid = ('public.'||p_tbl)::regclass and i.indisunique
                  and not exists (select 1 from pg_attribute a where a.attrelid = i.indrelid and a.attnum = any (i.indkey)
                                   and a.attname not in ('organization_id','branch_id')))
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
  if iso.in_uniq(p_tbl, p_col) then
    case p_type
      when 'date' then return format('(current_date - (abs(hashtext(%L)) %% 20000))', p_salt);
      when 'integer', 'smallint', 'bigint' then return format('(1000 + abs(hashtext(%L)) %% 1000000)', p_salt);
      when 'numeric', 'real', 'double precision' then return format('(1000 + abs(hashtext(%L)) %% 1000000)', p_salt);
      when 'timestamp with time zone', 'timestamp without time zone' then return format('(now() - (abs(hashtext(%L)) %% 100000000) * interval ''1 second'')', p_salt);
      else null;
    end case;
  end if;
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
    return format('(select c.id::uuid from iso.created c where c.tbl = %L and c.org = %L::uuid and c.purpose = ''victim'' order by (c.branch is distinct from %L::uuid), c.id limit 1)',
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
    (select a.attname from pg_constraint con join pg_attribute a on a.attrelid = con.conrelid and a.attnum = con.conkey[1]
      where con.conrelid = ('public.'||p_tbl)::regclass and con.contype = 'p' limit 1),
    null)
$$;
create or replace function iso.pk_type(p_tbl text) returns text language sql stable set search_path = public, pg_temp as $$
  select format_type(a.atttypid, a.atttypmod) from pg_attribute a
   where a.attrelid = ('public.'||p_tbl)::regclass and a.attname = iso.pk_col(p_tbl) and not a.attisdropped
$$;


-- composite primary keys: the locator is a jsonb text of {col: value::text}; single keys keep the plain id text.
create or replace function iso.pk_cols(p_tbl text) returns text[] language sql stable set search_path = public, pg_temp as $$
  select array_agg(a.attname order by k.ord) from pg_constraint con
    cross join lateral unnest(con.conkey) with ordinality k(attnum, ord)
    join pg_attribute a on a.attrelid = con.conrelid and a.attnum = k.attnum
   where con.conrelid = ('public.'||p_tbl)::regclass and con.contype = 'p'
$$;
create or replace function iso.pk_is_composite(p_tbl text) returns boolean language sql stable set search_path = public, pg_temp as $$
  select coalesce(array_length(iso.pk_cols(p_tbl),1),0) > 1 and not exists (
    select 1 from pg_attribute a where a.attrelid = ('public.'||p_tbl)::regclass and a.attname = 'id' and not a.attisdropped)
$$;
create or replace function iso.pk_ret(p_tbl text) returns text language sql stable set search_path = public, pg_temp as $$
  select case when iso.pk_is_composite(p_tbl)
    then 'jsonb_build_object(' || (select string_agg(format('%L, %I::text', c, c), ', ') from unnest(iso.pk_cols(p_tbl)) c) || ')::text'
    else format('%I::text', iso.pk_col(p_tbl)) end
$$;
create or replace function iso.pk_where(p_tbl text, p_v text) returns text language sql stable set search_path = public, pg_temp as $$
  select case when iso.pk_is_composite(p_tbl)
    then (select string_agg(format('%I::text = %L', c, p_v::jsonb ->> c), ' and ') from unnest(iso.pk_cols(p_tbl)) c)
    else format('%I = %L::%s', iso.pk_col(p_tbl), p_v, iso.pk_type(p_tbl)) end
$$;

-- ---------------------------------------------------------------- seeder
-- insert one generic valid row into p_tbl for (p_org, p_branch); returns the new id or null when a
-- parent row is still missing (the caller retries on the next pass). Errors propagate to the caller's
-- exception handler with the statement logged.
create or replace function iso.try_seed(p_tbl text, p_org uuid, p_branch uuid, p_purpose text, p_salt text)
returns text language plpgsql set search_path = public, extensions, pg_temp as $$
declare cols text[]; vals text[]; c record; new_id text; pk text; missing_fk boolean := false;
begin
  pk := iso.pk_col(p_tbl);
  if pk is null then raise exception 'ISO_ADAPTER_INCOMPLETE: no primary key'; end if;
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
  execute format('insert into public.%I (%s) values (%s) returning %s', p_tbl,
                 array_to_string(cols, ', '), array_to_string(vals, ', '), iso.pk_ret(p_tbl)) into new_id;
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
  -- one extra leaf row per scope for delete probes: seeded last, so no child row references it
  for t in select s.tbl, s.scope from iso.scope s where s.scope in ('hotel','branch') and s.tbl not in (select tbl from iso.seed_skip) order by s.tbl loop
    for tg in select * from iso.target order by key loop
      scope_branch := case when t.scope = 'branch' then tg.branch_id else null end;
      begin
        perform iso.try_seed(t.tbl, tg.org, scope_branch, 'delvictim', tg.key || '-del');
      exception when others then null;
      end;
    end loop;
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
create or replace function iso.victim_id(p_tbl text, p_target text, p_purpose text default 'victim') returns text language sql stable set search_path = public, pg_temp as $$
  select c.id from iso.created c join iso.target t on t.key = p_target
   where c.tbl = p_tbl and c.org = t.org and c.purpose = p_purpose
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
    return format('select jsonb_build_object(''matched'', count(*), ''total'', count(*)) from (select 1 from public.%I where %s) s', p_tbl, iso.pk_where(p_tbl, v));
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
    if p_salt like 'slot-%' then
      -- control only: replace the victim row occupying the unique slot, then insert; runs as the table owner
      if v is null then return null; end if;
      return format('delete from public.%I where organization_id = %L::uuid' || case when br is not null then ' and branch_id = ' || quote_literal(br) || '::uuid' else '' end || ' /*SPLIT*/ with i as (insert into public.%I (%s) values (%s) returning organization_id) select jsonb_build_object(''matched'', count(*) filter (where organization_id = %L::uuid), ''total'', count(*)) from i',
                    p_tbl, org, p_tbl, array_to_string(cols, ', '), array_to_string(vals, ', '), org);
    end if;
    return format('with i as (insert into public.%I (%s) values (%s) returning organization_id) select jsonb_build_object(''matched'', count(*) filter (where organization_id = %L::uuid), ''total'', count(*)) from i',
                  p_tbl, array_to_string(cols, ', '), array_to_string(vals, ', '), org);
  elsif p_op = 'update' then
    if v is null then return null; end if;
    select format('with u as (update public.%I set %I = %s where %s and %s is distinct from %I returning 1) select jsonb_build_object(''matched'', count(*), ''total'', count(*)) from u',
                  p_tbl, uc.col, uc.expr, iso.pk_where(p_tbl, v), uc.expr, uc.col) into mc
      from iso.upd_choice uc where uc.tbl = p_tbl;
    return mc;
  elsif p_op = 'delete' then
    v := coalesce(iso.victim_id(p_tbl, p_target, 'delvictim'), v);
    if v is null then return null; end if;
    return format('with d as (delete from public.%I where %s returning 1) select jsonb_build_object(''matched'', count(*), ''total'', count(*)) from d', p_tbl, iso.pk_where(p_tbl, v));
  end if;
end $$;


-- ---------------------------------------------------------------- real-changing update adapters
-- For each table, the first candidate column whose update actually changes the victim row and passes the table's
-- constraints and triggers (checked as owner inside a rolled-back subtransaction). No candidate: no adapter (reported).
create table if not exists iso.upd_choice(tbl text primary key, col text, expr text);
-- reviewed source-backed immutability: (table, op) is rejected for every role including the owner; the control must
-- be refused with the cited guard message, and any actor success is a violation.
create table if not exists iso.immutable_op(tbl text, op text, guard_prefix text not null, source text not null, primary key (tbl, op));
create or replace function iso.choose_updates() returns void language plpgsql set search_path = public, extensions, pg_temp as $$
declare t record; c record; v text; exprx text; n int; done boolean; tg text;
begin
  delete from iso.upd_choice;
  for t in select s.tbl from iso.scope s where s.scope in ('hotel','branch') order by 1 loop
    tg := 'hotel-a|branch-1'; v := iso.victim_id(t.tbl, tg); done := false;
    if v is null or iso.pk_col(t.tbl) is null then continue; end if;
    for c in select a.attname as name, format_type(a.atttypid, a.atttypmod) as typ
               from pg_attribute a
              where a.attrelid = ('public.'||t.tbl)::regclass and a.attnum > 0 and not a.attisdropped
                and a.attgenerated = '' and a.attidentity = ''
                and a.attname not in ('organization_id','branch_id','id')
                and a.attname <> all (coalesce(iso.pk_cols(t.tbl), '{}'))
                and not iso.in_uniq(t.tbl, a.attname)
                and not exists (select 1 from pg_constraint k where k.conrelid = a.attrelid and k.contype = 'f' and a.attnum = any (k.conkey))
              order by (a.attname in ('updated_at','created_at')), a.attnum loop
      exprx := case
        when c.typ in ('text','character varying','character') then format('coalesce(%I, '''') || ''x''', c.name)
        when c.typ in ('integer','smallint','bigint','numeric','real','double precision') then format('coalesce(%I, 0) + 1', c.name)
        when c.typ = 'boolean' then format('not coalesce(%I, false)', c.name)
        when c.typ like 'timestamp%' then format('coalesce(%I, now()) + interval ''1 minute''', c.name)
        when c.typ = 'date' then format('coalesce(%I, current_date) + 1', c.name)
        when c.typ = 'jsonb' then format('coalesce(%I, ''{}''::jsonb) || ''{"iso":1}''::jsonb', c.name)
        else null end;
      if exprx is null then continue; end if;
      if exists (select 1 from iso.immutable_op where tbl = t.tbl and op = 'update') then
        insert into iso.upd_choice values (t.tbl, c.name, exprx);
        exit;
      end if;
      begin
        execute format('with u as (update public.%I set %I = %s where %s and %s is distinct from %I returning 1) select count(*) from u',
                       t.tbl, c.name, exprx, iso.pk_where(t.tbl, v), exprx, c.name) into n;
        if n > 0 or exists (select 1 from iso.immutable_op where tbl = t.tbl and op = 'update') then done := true; end if;
        raise exception 'ISO_ROLLBACK';
      exception when others then null;
      end;
      if done then
        insert into iso.upd_choice values (t.tbl, c.name, exprx);
        exit;
      end if;
    end loop;
  end loop;
end $$;

-- ---------------------------------------------------------------- single probe
-- runs one statement as the current role, measures, rolls back. p_before: group snapshot baseline.
create or replace function iso.probe_one(p_probe_id text, p_surface text, p_name text, p_op text,
                                         p_actor_key text, p_target_key text, p_stmt text, p_before jsonb, p_replica boolean default false) returns void
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
    if p_replica then perform set_config('session_replication_role', 'replica', true); end if;
    if position('/*SPLIT*/' in p_stmt) > 0 then
      execute split_part(p_stmt, '/*SPLIT*/', 1);
      p_stmt := split_part(p_stmt, '/*SPLIT*/', 2);
    end if;
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
  perform iso.choose_updates();
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
  -- unique-slot tables: a plain insert collides with the victim row, so the positive control replaces that row first.
  -- This runs with triggers and FK checks off (control proves statement shape only) and is labelled in the detail.
  for grp in select pr.name as tbl, pr.target_key from iso.probe_result pr
              where pr.actor_key = 'control' and pr.op = 'create' and pr.outcome = 'denied' and pr.sqlstate = '23505' loop
    delete from iso.probe_result where probe_id = 'table|'||grp.tbl||'|create|control|'||grp.target_key;
    before := iso.snap();
    stmt := iso.stmt_for(grp.tbl, 'create', grp.target_key, 'slot-' || grp.target_key);
    perform iso.probe_one('table|'||grp.tbl||'|create|control|'||grp.target_key, 'table', grp.tbl, 'create', 'control', grp.target_key, stmt, before, true);
    update iso.probe_result set detail = 'slot-replace control (triggers off): ' || coalesce(detail,'')
     where probe_id = 'table|'||grp.tbl||'|create|control|'||grp.target_key and outcome = 'success';
  end loop;
  -- FK-referenced victims: retry the delete with triggers and FK checks off, labelled; business-rule blocks stay failures
  for grp in select pr.name as tbl, pr.target_key from iso.probe_result pr
              where pr.actor_key = 'control' and pr.op = 'delete' and pr.outcome = 'denied' and pr.sqlstate = '23503' loop
    delete from iso.probe_result where probe_id = 'table|'||grp.tbl||'|delete|control|'||grp.target_key;
    before := iso.snap();
    stmt := iso.stmt_for(grp.tbl, 'delete', grp.target_key, 'control-' || grp.target_key);
    perform iso.probe_one('table|'||grp.tbl||'|delete|control|'||grp.target_key, 'table', grp.tbl, 'delete', 'control', grp.target_key, stmt, before, true);
    update iso.probe_result set detail = 'FK-bypass delete control (triggers off): ' || coalesce(detail,'')
     where probe_id = 'table|'||grp.tbl||'|delete|control|'||grp.target_key and outcome = 'success';
  end loop;
  -- relabel successful control probes as control-ok (probe_one wrote them as success)
  update iso.probe_result set outcome = 'control-ok' where actor_key = 'control' and outcome = 'success';
end $$;


-- ---------------------------------------------------------------- RPC adapters (surface = function)
-- Adapters (tests/isolation/rpc-adapters*.sql) fill iso.rpc_adapter; this runner never invents arguments.
-- One adapter exercises one operation (op) of one exact signature; all other operation cells stay unexecuted.
create table if not exists iso.rpc_adapter(
  signature text primary key, family text not null, mutates boolean not null,
  op text not null default 'read' check (op in ('read','create','update','delete')),
  call_sql text not null, control_sql text, reads_target boolean not null default false,
  public_keys text[],  -- public-by-design lookups: the result may carry only these jsonb keys (and the hotel's own id); extra keys or other markers are leaks
  effect_sql text,   -- read-only boolean SELECT for the intended row-level effect on the TARGET victim row; must be false before and true after the owner control
  guard_sql text,    -- read-only boolean SELECT that must stay true across the call (non-target rows unchanged)
  touch_sql text,    -- read-only select returning (tbl text, pk text): the EXACT rows the owner control may insert/update/delete in the target org (rendered like effect_sql, evaluated after the call)
  related_insert_tables text[],  -- tables where NEW rows (inserts only) are legitimately added, e.g. audit_events
  expect_tables text[],  -- exact tables the owner control must change (checked against the control's changed tables)
  caller_scoped boolean not null default false,  -- acts on the caller's own hotel by design: own-slice effects are expected, any other slice is a violation
  note text);
create table if not exists iso.rpc_adapter_skip(signature text primary key, reason text not null);
grant select on iso.rpc_adapter, iso.rpc_adapter_skip to anon, authenticated;

-- Placeholder contract (adapters quote, the renderer substitutes RAW values):
--   {org} {branch}          raw target hotel / branch uuid; {branch} is never null (all four targets are branches)
--   {salt}                  raw text [A-Za-z0-9_|:.-] unique per actor/target
--   {v:T}                   raw id of the 'victim' row of table T for the target (hotel scope: org match, branch null;
--                           branch scope: exact target branch). Composite locators are refused, use a dot column.
--   {v:T:val}               same, restricted to rows whose kind, role or status column (first one present) = val
--   {v:T.col}               raw text of column col of that victim row (value must not contain quote or backslash)
--   {s:role}                raw staff_profiles id of the registered fixture staff with that role holding a membership in the target branch
--   {v:T:val.col}           combination of the two; append @purpose (victim|delvictim) to pick another registered purpose
-- A placeholder that cannot be resolved exactly, or any text left in braces, returns NULL: the probe is adapter-incomplete,
-- never a denial. Callers write '{v:T}'::uuid, so values are substituted unquoted.
create or replace function iso.render_call(p_sql text, p_target text, p_salt text) returns text
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare out text := p_sql; m text[]; t record; sid text; val text; sc text; col text; selcol text; v_purpose text; idv text; ph text;
begin
  select * into t from iso.target where key = p_target;
  if t.key is null or p_salt !~ '^[A-Za-z0-9_|:.-]+$' then return null; end if;
  out := replace(replace(replace(out, '{org}', t.org::text), '{salt}', p_salt), '{branch}', t.branch_id::text);
  -- {s:role}: raw staff_profiles id of the registered fixture staff with that role who holds a branch membership in the target branch
  loop
    m := regexp_match(out, '\{s:([a-z_]+)\}');
    exit when m is null;
    select p.id::text into sid from branch_memberships bm join staff_profiles p on p.id = bm.staff_id
     where bm.branch_id = t.branch_id and p.organization_id = t.org and p.role::text = m[1]
       and exists (select 1 from iso.created c where c.tbl = 'staff_profiles' and c.id = p.id::text and c.purpose = 'victim')
     order by p.id limit 1;
    if sid is null then return null; end if;
    out := replace(out, '{s:' || m[1] || '}', sid);
  end loop;
  loop
    m := regexp_match(out, '\{v:([a-z_0-9]+)(?::([A-Za-z_0-9]+))?(?:\.([a-z_0-9]+))?(?:@([a-z]+))?\}');
    exit when m is null;
    ph := (regexp_match(out, '(\{v:[^}]*\})'))[1];
    v_purpose := coalesce(m[4], 'victim'); col := m[3];
    select s.scope into sc from iso.scope s where s.tbl = m[1];
    if sc is null or sc = 'platform' then return null; end if;
    if m[2] is null then
      select c.id into idv from iso.created c
       where c.tbl = m[1] and c.org = t.org and c.purpose = v_purpose
         and (case when sc = 'branch' then c.branch = t.branch_id else c.branch is null end)
       order by c.id limit 1;
    else
      selcol := (select a.attname from pg_attribute a where a.attrelid = ('public.'||m[1])::regclass and a.attname in ('kind','role','status') and not a.attisdropped
                  order by array_position(array['kind','role','status'], a.attname::text) limit 1);
      if selcol is null then return null; end if;
      if iso.pk_is_composite(m[1]) then return null; end if;
      execute format('select c.id from iso.created c where c.tbl = %L and c.org = %L::uuid and c.purpose = %L and (case when %L = ''branch'' then c.branch = %L::uuid else c.branch is null end) and exists (select 1 from public.%I x where x.%I::text = c.id and x.%I::text = %L) order by c.id limit 1',
                     m[1], t.org, v_purpose, sc, t.branch_id, m[1], iso.pk_col(m[1]), selcol, m[2]) into idv;
    end if;
    if idv is null or idv !~ '^([0-9a-fA-F-]{36}|[A-Za-z0-9_.-]{4,100})$' then return null; end if;
    if col is not null then
      if not exists (select 1 from pg_attribute a where a.attrelid = ('public.'||m[1])::regclass and a.attname = col and not a.attisdropped) then return null; end if;
      execute format('select x.%I::text from public.%I x where x.%I::text = %L', col, m[1], iso.pk_col(m[1]), idv) into val;
      if val is null or val ~ '[''\\]' then return null; end if;
    else
      val := idv;
    end if;
    out := replace(out, ph, val);
  end loop;
  if out ~ '\{[a-zA-Z]' then return null; end if;
  return out;
end $$;

-- distinctive text of the target slice: org/branch ids, victim ids and the ISO-<target> markers the seeder writes
create or replace function iso.target_markers(p_target text) returns text[] language sql stable security definer set search_path = public, pg_temp as $$
  select array[t.org::text, coalesce(t.branch_id::text, ''), 'ISO-' || t.key || '-']
         || coalesce((select array_agg(c.id) from iso.created c where c.org = t.org and c.branch is not distinct from t.branch_id and c.id ~ '^[0-9a-f-]{36}$'), '{}')
  from iso.target t where t.key = p_target
$$;

-- (table, org) slices whose content hash or row count differs between two iso.snap() results
create or replace function iso.snap_pairs(p_before jsonb, p_after jsonb) returns table(tbl text, org text) language sql immutable as $$
  select t.k, o.k from (select jsonb_object_keys(p_before || p_after) k) t,
    lateral (select jsonb_object_keys(coalesce(p_before->t.k,'{}'::jsonb) || coalesce(p_after->t.k,'{}'::jsonb)) k) o
   where (p_before->t.k->o.k) is distinct from (p_after->t.k->o.k)
$$;

-- 'tbl:delta,...' row-count deltas of the changed slices of one org
create or replace function iso.slice_n(j jsonb, t text, o text) returns int language sql immutable as $$ select coalesce((j->t->o->>0)::int, 0) $$;
-- evaluates one rendered read-only boolean SELECT as the harness; NULL = unrenderable, unsafe, errored or NULL result (never a pass)
create or replace function iso.eval_bool(q text) returns boolean language plpgsql security definer set search_path = public, pg_temp as $$
declare r boolean;
begin
  if q is null or q ~ ';' or q !~* '^\s*select\s' then return null; end if;
  execute q into r; return r;
exception when others then return null;
end $$;
-- row-level fingerprints {org:{tbl:{pk:md5(row)}}} for the given orgs (tables with organization_id); identity = primary key values, else the row hash
create or replace function iso.row_snaps(p_orgs text[]) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; o text; acc jsonb := '{}'::jsonb; ot jsonb; slice jsonb; kx text;
begin
  foreach o in array p_orgs loop
    ot := '{}'::jsonb;
    for r in select c.relname t from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
                and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'organization_id' and not a.attisdropped) order by 1 loop
      kx := (select string_agg(format('coalesce(to_jsonb(t)->>%L, '''')', c), ' || ''|'' || ') from unnest(coalesce(iso.pk_cols(r.t), '{}')) c);
      kx := coalesce(kx, 'md5(t::text)');
      execute format('select coalesce(jsonb_object_agg(k, h), ''{}''::jsonb) from (select %s k, md5(t::text) h from public.%I t where t.organization_id = %L::uuid) s', kx, r.t, o) into slice;
      if slice <> '{}'::jsonb then ot := ot || jsonb_build_object(r.t, slice); end if;
    end loop;
    -- organizations has no organization_id: its own row is the org's slice
    execute format('select coalesce(jsonb_object_agg(id::text, md5(t::text)), ''{}''::jsonb) from public.organizations t where id = %L::uuid', o) into slice;
    if slice <> '{}'::jsonb then ot := ot || jsonb_build_object('organizations', slice); end if;
    acc := acc || jsonb_build_object(o, ot);
  end loop;
  return acc;
end $$;
create or replace function iso.row_changes(p_before jsonb, p_after jsonb) returns table(org text, tbl text, pk text, kind text) language sql immutable as $$
  select o.k, t.k, p.k, case when b.v is null then 'ins' when a.v is null then 'del' else 'upd' end
    from (select jsonb_object_keys(p_before || p_after) k) o,
    lateral (select jsonb_object_keys(coalesce(p_before->o.k,'{}') || coalesce(p_after->o.k,'{}')) k) t,
    lateral (select jsonb_object_keys(coalesce(p_before->o.k->t.k,'{}') || coalesce(p_after->o.k->t.k,'{}')) k) p,
    lateral (select p_before->o.k->t.k->>p.k v) b, lateral (select p_after->o.k->t.k->>p.k v) a
   where b.v is distinct from a.v
$$;
-- the adapter's explicit touched-row set as 'tbl|pk' strings; NULL when unrenderable, unsafe or errored
create or replace function iso.touch_set(q text) returns text[] language plpgsql security definer set search_path = public, pg_temp as $$
declare r text[];
begin
  if q is null or q ~ ';' or q !~* '^\s*select\s' then return null; end if;
  execute 'select coalesce(array_agg(x.tbl || ''|'' || x.pk), ''{}'') from (' || q || ') x(tbl, pk)' into r; return r;
exception when others then return null;
end $$;
create or replace function iso.snap_deltas(p_before jsonb, p_after jsonb, p_org text) returns text language sql immutable as $$
  select coalesce(string_agg(p.tbl || ':' || (coalesce((p_after->p.tbl->p.org->>0)::int,0) - coalesce((p_before->p.tbl->p.org->>0)::int,0)), ',' order by p.tbl), '')
    from iso.snap_pairs(p_before, p_after) p where p.org = p_org
$$;

-- additive scope-provenance signal: structured branch fields in a jsonb result (key branch_id equal to the target branch, or branch_ids containing it)
-- Returns matching JSON object occurrences, not unique database rows, people, or individual fields.
-- Null branch_id or empty branch_ids are a separate unproven signal. Text markers remain unchanged.
create or replace function iso.branch_fields(p_res text, p_branch text) returns int[] language plpgsql immutable as $$
declare j jsonb; st int := 0; nl int := 0;
begin
  if p_branch is null or p_branch = '' then return array[0, 0]; end if;
  begin j := ('[' || p_res || ']')::jsonb; exception when others then begin j := p_res::jsonb; exception when others then return array[0, 0]; end; end;
  with recursive w(v) as (select j union all
         select c from w, lateral (select jsonb_array_elements(case jsonb_typeof(w.v) when 'array' then w.v when 'object' then (select coalesce(jsonb_agg(x.value), '[]'::jsonb) from jsonb_each(w.v) x) else '[]'::jsonb end) c) q)
  select count(*) filter (where (v->'branch_id') = to_jsonb(p_branch) or (jsonb_typeof(v->'branch_ids') = 'array' and (v->'branch_ids') @> to_jsonb(p_branch))),
         count(*) filter (where (v ? 'branch_id' and jsonb_typeof(v->'branch_id') = 'null') or (case when jsonb_typeof(v->'branch_ids') = 'array' then jsonb_array_length(v->'branch_ids') = 0 else false end))
    into st, nl from w where jsonb_typeof(v) = 'object';
  return array[st, nl];
end $$;

-- A public exception needs a source-grounded identity oracle, not keys alone.
-- Only guest_site is qualified here (0082). Other signatures fail closed until independently specified.
create or replace function iso.public_identity_ok(p_signature text, p_result jsonb, p_org uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select p_signature = 'fn_guest_site(p_slug text)' and jsonb_typeof(p_result) = 'object'
    and coalesce((select p_result = jsonb_build_object('id', o.id, 'slug', o.guest_slug, 'name_ar', o.name_ar, 'name_en', o.name_en)
      from organizations o where o.id = p_org and o.platform_status = 'active'
        and exists(select 1 from branches b where b.organization_id = o.id and b.is_active and b.archived_at is null)), false)
$$;

create or replace function iso.rpc_probe(p_probe_id text, p_sig text, p_actor_key text, p_target_key text, p_control boolean, p_before jsonb)
returns void language plpgsql set search_path = public, extensions, pg_temp as $$
declare a record; res text; hits int := 0; mk text; snap_after jsonb; stmt text; actor_org text; tgt_org text;
        ndiff int := 0; viol int := 0; eff int := 0; outside int := 0; changed text; own_tbls text[]; allowed text[];
        extra_keys int := 0; deltas text := ''; allowed_d text; e_sql text; g_sql text; eff_b boolean; eff_a boolean; grd_b boolean; grd_a boolean; asserted boolean := false; eff_bad text := ''; t_sql text; touch text[]; rs_b jsonb; rs_a jsonb; orgs_l text[]; bad_rows int := 0; miss_rows int := 0; nontarget text := 'unproven'; own_t boolean; ctl_delta int;  pub_keys int := 0; j jsonb; k text; first_marker boolean := true; bf int[] := array[0, 0]; tbranch text; jres text; public_identity boolean := false;
begin
  select * into a from iso.rpc_adapter where signature = p_sig;
  -- an explicit skip (outbound/platform/new-org effects) always wins over an adapter: never executed, never credited
  if exists (select 1 from iso.rpc_adapter_skip k where k.signature = split_part(p_sig, '#', 1)) then return; end if;
  select t.org::text into tgt_org from iso.target t where t.key = p_target_key;
  actor_org := case when p_control then tgt_org
                    else (select t.org::text from iso.target t where t.hotel = split_part(p_actor_key, '|', 2) limit 1) end;
  stmt := iso.render_call(case when p_control then coalesce(a.control_sql, a.call_sql) else a.call_sql end, p_target_key, p_actor_key || '-' || p_target_key);
  if stmt is null then
    insert into iso.probe_result values (p_probe_id, 'function', p_sig, a.op, p_actor_key, p_target_key, 'adapter-incomplete', null, null, null, null, null, 'adapter placeholder has no fixture row for this target');
    return;
  end if;
  -- caller-scoped attack: the own-slice tables the same-hotel owner control demonstrably changes are the allowed effect set
  if a.caller_scoped and not p_control then
    select string_to_array(nullif(substring(pr.detail from 'tbls=([^ ]*)'), ''), ',') into allowed
      from iso.probe_result pr
     where pr.surface = 'function' and pr.name = p_sig and pr.actor_key = 'control'
       and pr.target_key in (select t.key from iso.target t where t.org::text = actor_org) order by pr.target_key limit 1;
    allowed := coalesce(allowed, '{}');
    select substring(pr.detail from 'deltas=([^ ]*)') into allowed_d
      from iso.probe_result pr
     where pr.surface = 'function' and pr.name = p_sig and pr.actor_key = 'control'
       and pr.target_key in (select t.key from iso.target t where t.org::text = actor_org) order by pr.target_key limit 1;
  end if;
  asserted := a.mutates and a.effect_sql is not null;
  if asserted then
    e_sql := iso.render_call(a.effect_sql, p_target_key, p_actor_key || '-' || p_target_key);
    g_sql := iso.render_call(a.guard_sql, p_target_key, p_actor_key || '-' || p_target_key);
    if e_sql is null then
      insert into iso.probe_result values (p_probe_id, 'function', p_sig, a.op, p_actor_key, p_target_key, 'adapter-incomplete', null, null, null, null, null, 'effect_sql unrenderable for this target');
      return;
    end if;
    eff_b := iso.eval_bool(e_sql);
    grd_b := iso.eval_bool(g_sql);
    if a.touch_sql is not null then
      t_sql := iso.render_call(a.touch_sql, p_target_key, p_actor_key || '-' || p_target_key);
      orgs_l := case when p_control then array[tgt_org] else array(select distinct x from unnest(array[tgt_org, actor_org]) x) end;
      rs_b := iso.row_snaps(orgs_l);
    end if;
  end if;
  own_t := not p_control and split_part(p_actor_key, '|', 2) = split_part(p_target_key, '|', 1) and split_part(p_actor_key, '|', 3) = split_part(p_target_key, '|', 2);
  begin
    if a.mutates then
      execute 'select coalesce(string_agg(x::text, '','' ), '''') from (' || stmt || ') x' into res;
    else
      -- One execution only. Keep the raw marker aggregate unchanged alongside additive structured JSON.
      execute 'select coalesce(string_agg(x::text, '','' ), ''''), coalesce(jsonb_agg(to_jsonb(x)), ''[]''::jsonb)::text from (' || stmt || ') x' into res, jres;
      select t.branch_id::text into tbranch from iso.target t where t.key = p_target_key;
      bf := iso.branch_fields(jres, tbranch);
    end if;
    foreach mk in array iso.target_markers(p_target_key) loop
      -- public-by-design functions may return the hotel's own id (the first marker is the org id)
      if mk <> '' and position(mk in res) > 0 and not (a.public_keys is not null and first_marker) then hits := hits + 1; end if;
      first_marker := false;
    end loop;
    if a.public_keys is not null then
      -- Use the already collected single-execution rows, not PostgreSQL composite record text.
      -- A public JSON lookup must return exactly one row with exactly one column.
      if not a.mutates and jsonb_array_length(jres::jsonb) = 1
         and (select count(*) from jsonb_each(jres::jsonb->0)) = 1 then
        select value into j from jsonb_each(jres::jsonb->0);
      end if;
      if j is null or jsonb_typeof(j) not in ('object', 'array') then extra_keys := extra_keys + 1;
      else
        -- Strict recursive descent terminates on nested arrays and visits nested object keys.
        for k in select distinct jsonb_object_keys(v) from jsonb_path_query(j, 'strict $.**') v where jsonb_typeof(v) = 'object' loop
          if k = any (a.public_keys) then pub_keys := pub_keys + 1; else extra_keys := extra_keys + 1; end if;
        end loop;
      end if;
      public_identity := coalesce(iso.public_identity_ok(split_part(p_sig, '#', 1), j, tgt_org::uuid), false);
      if not public_identity then extra_keys := extra_keys + 1; end if;
    end if;
    snap_after := iso.snap();
    select count(*),
           count(*) filter (where not (a.caller_scoped and p.org = actor_org and p.tbl = any (coalesce(allowed, '{}'))
                                      and abs(coalesce((iso.slice_n(snap_after, p.tbl, p.org)) - (iso.slice_n(p_before, p.tbl, p.org)), 0))
                                          <= coalesce((select abs(split_part(d, ':', 2)::int) from unnest(string_to_array(coalesce(allowed_d, ''), ',')) d where split_part(d, ':', 1) = p.tbl limit 1), 0))),
           count(*) filter (where p.org = tgt_org),
           count(*) filter (where p.org is distinct from tgt_org),
           coalesce(string_agg(p.tbl || '@' || coalesce(p.org, '-'), ',' order by p.tbl, p.org), ''),
           coalesce(array_agg(p.tbl order by p.tbl) filter (where p.org = tgt_org), '{}')
      into ndiff, viol, eff, outside, changed, own_tbls
      from iso.snap_pairs(p_before, snap_after) p;
    if asserted then
      eff_a := iso.eval_bool(e_sql); grd_a := iso.eval_bool(g_sql);
      if p_control then
        if eff_b is distinct from false then eff_bad := 'effect_sql not false before the control (tautological or already true)';
        elsif eff_a is distinct from true then eff_bad := 'effect_sql not true after the control (assertion did not observe the intended effect)';
        elsif a.expect_tables is not null and (select array_agg(x order by x) from unnest(own_tbls) x) is distinct from (select array_agg(x order by x) from unnest(a.expect_tables) x) then
          eff_bad := 'control changed tables differ from expect_tables'; end if;
        if a.guard_sql is not null and (grd_b is distinct from true or grd_a is distinct from true) then eff_bad := coalesce(nullif(eff_bad,'') || '; ', '') || 'guard_sql not true across the control'; end if;
      else
        if eff_a is true then eff := eff + 1; if not (split_part(p_actor_key, '|', 2) = split_part(p_target_key, '|', 1) and split_part(p_actor_key, '|', 3) = split_part(p_target_key, '|', 2)) then eff_bad := 'effect_sql true on this target (attack changed the victim row)'; end if; end if;
        if eff_a is null then eff_bad := 'effect_sql unevaluable'; end if;
        if a.guard_sql is not null and (grd_a is distinct from true) then viol := viol + 1; eff_bad := coalesce(nullif(eff_bad,'') || '; ', '') || 'guard_sql false after the attack'; end if;
      end if;
    end if;
    if asserted and a.touch_sql is not null then
      touch := iso.touch_set(t_sql);
      rs_a := iso.row_snaps(orgs_l);
      if touch is null then
        if p_control then eff_bad := coalesce(nullif(eff_bad,'') || '; ', '') || 'touch_sql unrenderable or errored'; else eff_bad := 'effect_sql unevaluable'; end if;
      elsif p_control or own_t then
        -- every changed row must be an explicitly touched row or a new row in a related_insert_table; every touched row must actually change (tight contract)
        select count(*) into bad_rows from iso.row_changes(rs_b, rs_a) c
         where not ((c.tbl || '|' || c.pk) = any (touch)) and not (c.kind = 'ins' and c.tbl = any (coalesce(a.related_insert_tables, '{}')));
        select count(*) into miss_rows from unnest(touch) tr where not exists (select 1 from iso.row_changes(rs_b, rs_a) c where (c.tbl || '|' || c.pk) = tr);
        if p_control then
          if bad_rows > 0 or miss_rows > 0 then eff_bad := coalesce(nullif(eff_bad,'') || '; ', '') || 'row-level touch contract not exact: unlisted_rows=' || bad_rows || ' listed_unchanged=' || miss_rows; end if;
        elsif bad_rows > 0 then viol := viol + bad_rows; end if;
        nontarget := case when bad_rows = 0 and miss_rows = 0 then 'proved-rowlevel' else 'violated' end;
      else
        -- attack on a foreign slice: no row may be updated or deleted anywhere, new rows only in related_insert_tables
        select count(*) into bad_rows from iso.row_changes(rs_b, rs_a) c
         where not (c.kind = 'ins' and c.tbl = any (coalesce(a.related_insert_tables, '{}')));
        if bad_rows > 0 then viol := viol + bad_rows; eff := eff + 1; if eff_bad = '' then eff_bad := 'row-level change on a foreign slice'; end if; end if;
        nontarget := case when bad_rows = 0 then 'proved-rowlevel' else 'violated' end;
      end if;
    end if;
    deltas := iso.snap_deltas(p_before, snap_after, case when p_control then tgt_org else actor_org end);
    raise exception 'ISO_ROLLBACK';
  exception when others then
    if sqlstate = 'P0001' and sqlerrm = 'ISO_ROLLBACK' then
      -- Control: markers (or public keys) seen plus changed target-org tables. A control that changed any other org slice,
      --   or the global slice, is itself a scope violation, not a valid control.
      -- Attack: markers + extra keys + changed slices outside the allowed effect set.
      insert into iso.probe_result values (p_probe_id, 'function', p_sig, a.op, p_actor_key, p_target_key,
        case when p_control and outside > 0 then 'scope-violation'
             when p_control and asserted and eff_bad <> '' then 'invalid-effect'
             when not p_control and asserted and eff_bad = 'effect_sql unevaluable' then 'adapter-incomplete'
             else 'success' end, null, null, null,
        case when p_control then (case when a.public_keys is not null then pub_keys else hits end) + eff
             else hits + extra_keys + viol end,
        case when p_control then ndiff > 0 else viol > 0 end,
        left('markers=' || hits || ' changed=' || ndiff || ' violating=' || viol || ' outside=' || outside
             || ' public_keys_ok=' || (a.public_keys is not null and extra_keys = 0 and public_identity) || ' public_identity_ok=' || public_identity || ' extra_keys=' || extra_keys
             || ' nontarget=' || (case when asserted then nontarget else 'unproven' end) || ' effect=' || (case when not a.mutates then 'n/a' when not asserted then 'unasserted' when eff_bad = '' then 'asserted-ok' else 'asserted-BAD ' || replace(eff_bad, ' ', '_') end)
             || ' branch_struct=' || bf[1] || ' branch_null=' || bf[2] || ' prov=' || (case when a.mutates then 'unmeasured' when bf[1] > 0 then 'structured' when hits > 0 then 'text-only' else 'none' end)
             || ' tbls=' || array_to_string(own_tbls, ',') || ' deltas=' || deltas || ' ' || changed, 4000));
    else
      insert into iso.probe_result values (p_probe_id, 'function', p_sig, a.op, p_actor_key, p_target_key, 'denied', iso.err_class(sqlstate, sqlerrm), sqlstate, left(sqlerrm, 500), null, false, null);
    end if;
  end;
end $$;

create or replace function iso.run_rpc_controls(p_hotel text) returns void language plpgsql set search_path = public, pg_temp as $$
declare a record; p record; before jsonb;
begin
  -- positive control: the same-hotel owner (real role and claims), against each target of that hotel
  for a in select * from iso.rpc_adapter r where not exists (select 1 from iso.rpc_adapter_skip k where k.signature = split_part(r.signature, '#', 1)) order by signature loop
    before := iso.snap();
    for p in select * from iso.target where hotel = p_hotel order by key loop
      perform iso.rpc_probe('function|' || a.signature || '|' || a.op || '|control|' || p.key, a.signature, 'control', p.key, true, before);
    end loop;
  end loop;
end $$;

create or replace function iso.run_actor_rpcs(p_actor_key text) returns void language plpgsql set search_path = public, pg_temp as $$
declare a record; p record; before jsonb;
begin
  for a in select * from iso.rpc_adapter r where not exists (select 1 from iso.rpc_adapter_skip k where k.signature = split_part(r.signature, '#', 1)) order by signature loop
    before := iso.snap();
    for p in select * from iso.target order by key loop
      perform iso.rpc_probe('function|' || a.signature || '|' || a.op || '|' || p_actor_key || '|' || p.key, a.signature, p_actor_key, p.key, false, before);
    end loop;
  end loop;
end $$;
grant execute on all functions in schema iso to anon, authenticated;

-- ---------------------------------------------------------------- grants: probes run as the actor role and write results
grant usage on schema iso to anon, authenticated;
grant select on iso.ids, iso.scope, iso.created, iso.col_override, iso.seed_skip, iso.target, iso.actor, iso.fn_adapter, iso.upd_choice, iso.immutable_op to anon, authenticated;
grant insert, select on iso.probe_result to anon, authenticated;
grant insert on iso.cell_result to anon, authenticated;
grant execute on all functions in schema iso to anon, authenticated;

-- ---------------------------------------------------------------- wrapper emitter
-- run.sh executes: SELECT iso.emit_wrapper() -> a psql script of role sections.
create or replace function iso.emit_wrapper() returns text language plpgsql stable set search_path = public, pg_temp as $$
declare a record; acc text := E'select iso.set_claims(null);\nselect iso.run_controls();\n';
begin
  for a in select * from iso.actor where role = 'owner' order by key loop
    acc := acc || E'set role ' || a.db_role || E';\n'
        || format(E'select iso.set_claims(%s);\n', quote_literal(a.auth_user) || '::uuid')
        || format(E'select iso.run_rpc_controls(%L);\n', a.hotel) || E'reset role;\n';
  end loop;
  acc := acc || E'update iso.probe_result set outcome = ''control-ok'' where actor_key = ''control'' and surface = ''function'' and outcome = ''success'';\n';
  for a in select * from iso.actor order by key loop
    acc := acc || E'set role ' || a.db_role || E';\n'
        || format(E'select iso.set_claims(%s);\n', case when a.auth_user is null then 'null' else quote_literal(a.auth_user) || '::uuid' end)
        || format(E'select iso.run_actor_tables(%L);\n', a.key)
        || format(E'select iso.run_actor_rpcs(%L);\n', a.key)
        || E'reset role;\n';
  end loop;
  acc := acc || E'select iso.set_claims(null);\n';
  return acc;
end $$;
