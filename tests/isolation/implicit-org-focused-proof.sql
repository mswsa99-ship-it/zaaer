-- Standalone proof for the 5 implicit-org admin creators: fn_admin_upsert_source / _product_category / _expense_category / _bank_rule / _knowledge.
-- Source fact: none takes an org or branch id; the row org comes from fn_user_org_id() (the caller's own org). So a foreign hotel's owner legitimately creates in ITS OWN org.
-- Contract proved, per actor owner (hotel-a, hotel-b) x function: (1) the call succeeds; (2) in the actor's org exactly 2 rows appear: one row in the expected table carrying the unique marker
-- and one audit_events row (action <entity>.created, entity_type, entity_id = the new row id); nothing else changes in that org; (3) the OTHER org's rows are byte-identical (all tables with organization_id).
-- Own-org effect is NOT labelled a foreign denial. Not proved: update-existing, validation/duplicate branches, nonowner roles, protected/outbound paths (none touched).
-- Load after engine.sql + fixtures.sql (base iso.actor/iso.target). No trigger/FK disabled. Rolled back. PGlite unless run on PG16.
\set ON_ERROR_STOP on
begin;
create temp table sn(tag text, org uuid, t text, id text, h text);
create temp table res(name text, ok boolean);
create function pg_temp.take(p_tag text) returns void language plpgsql as $$
declare r record;
begin
 for r in select c.relname t from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r'
   and exists(select 1 from pg_attribute a where a.attrelid=c.oid and a.attname='organization_id' and not a.attisdropped)
   and exists(select 1 from pg_attribute a where a.attrelid=c.oid and a.attname='id' and not a.attisdropped) loop
  execute format('insert into sn select %L, x.organization_id, %L, x.id::text, md5(to_jsonb(x)::text) from public.%I x', p_tag, r.t, r.t);
 end loop;
end $$;
do $$
declare a record; f record; o uuid; n_own int; n_oth int; newrows jsonb; tbl text; aud int; rid text; mk text; i int := 0;
begin
 for a in select * from iso.actor where role='owner' order by key loop
  select org into o from iso.target where hotel=a.hotel limit 1;
  for f in select * from (values
    ('fn_admin_upsert_source','booking_sources','source.created','booking_source','jsonb_build_object(''name'',''%M'',''kind'',''external'')'),
    ('fn_admin_upsert_product_category','product_categories','product_category.created','product_category','jsonb_build_object(''name'',''%M'')'),
    ('fn_admin_upsert_expense_category','expense_categories','expense_category.created','expense_category','jsonb_build_object(''name'',''%M'')'),
    ('fn_admin_upsert_bank_rule','bank_parse_rules','bank_rule.created','bank_rule','jsonb_build_object(''keyword'',''%M'',''kind'',''deposit'',''priority'',''5'')'),
    ('fn_admin_upsert_knowledge','knowledge_entries','knowledge.created','knowledge_entry','jsonb_build_object(''question'',''%M'',''answer'',''ans-%M'',''title'',''%M'')')
   ) v(fn,tbl,act,ety,pl) loop
   i := i+1; mk := 'ioz-'||a.hotel||'-'||i;
   delete from sn; perform pg_temp.take('b');
   perform iso.set_claims(a.auth_user); set local role authenticated;
   execute format('select %I(%s)', f.fn, replace(f.pl,'%M',mk));
   reset role; perform pg_temp.take('a');
   -- own org: rows added / changed / removed
   select count(*) into n_own from (select t,id,h from sn where tag='a' and org=o except select t,id,h from sn where tag='b' and org=o) z;
   insert into res select f.fn||'|'||a.key||'|own-org-exactly-2-changed-rows', n_own=2 and not exists (select 1 from sn b where b.tag='b' and b.org=o and not exists (select 1 from sn x where x.tag='a' and x.org=o and x.t=b.t and x.id=b.id));
   -- the new row in the expected table carries the marker
   execute format('select x.id::text from %I x where x.organization_id=%L and to_jsonb(x)::text like %L', f.tbl, o, '%'||mk||'%') into rid;
   insert into res select f.fn||'|'||a.key||'|expected-row-with-marker', rid is not null and exists(select 1 from sn x where x.tag='a' and x.t=f.tbl and x.id=rid) and not exists(select 1 from sn x where x.tag='b' and x.t=f.tbl and x.id=rid);
   select count(*) into aud from audit_events e where e.organization_id=o and e.action=f.act and e.entity_type=f.ety and e.entity_id::text=rid and exists(select 1 from sn x where x.tag='a' and x.t='audit_events' and x.id=e.id::text) and not exists(select 1 from sn x where x.tag='b' and x.t='audit_events' and x.id=e.id::text);
   insert into res select f.fn||'|'||a.key||'|one-audit-row', aud=1;
   -- other org unchanged
   select count(*) into n_oth from ((select org,t,id,h from sn where tag='a' and org<>o except select org,t,id,h from sn where tag='b' and org<>o) union all (select org,t,id,h from sn where tag='b' and org<>o except select org,t,id,h from sn where tag='a' and org<>o)) z;
   insert into res select f.fn||'|'||a.key||'|other-orgs-unchanged', n_oth=0 and (select count(*) from sn where tag='a' and org<>o)>0;
  end loop;
 end loop;
end $$;
select name, ok from res order by name;
do $$ begin
 if (select count(*) from res)<>40 or exists(select 1 from res where not ok) then raise exception 'implicit-org proof FAILED: % of % ok; failing: %', (select count(*) from res where ok),(select count(*) from res),(select string_agg(name,', ') from res where not ok); end if;
 raise notice 'implicit-org proof OK 40/40';
end $$;
rollback;
