-- Standalone proof for 3 implicit-org admin updaters: fn_admin_alert_rule_save (event key of the caller's own org), fn_admin_update_ai_settings, fn_admin_update_organization (non-sensitive field only: delay_minutes / extra_instructions / name_en).
-- Source fact: none takes an org or branch id; the row org comes from fn_user_org_id() (the caller's own org). So a foreign hotel's owner legitimately updates ITS OWN org's row. No recipients/channel/enabled/provider/model change, so nothing outbound is enabled.
-- Contract proved, per actor owner (hotel-a, hotel-b) x function: (1) the call succeeds; (2) in the actor's org exactly 2 rows change: the expected row (updated value verified) and one new audit_events row (action verified); nothing else changes in that org; (3) the OTHER org's rows are byte-identical (all tables with organization_id).
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
 loop
  execute format('insert into sn select %L, x.organization_id, %L, coalesce(to_jsonb(x)->>''id'', to_jsonb(x)->>''organization_id'')||coalesce(''|''||(to_jsonb(x)->>''event''),''''), md5(to_jsonb(x)::text) from public.%I x', p_tag, r.t, r.t);
 end loop;
 insert into sn select p_tag, x.id, 'organizations', x.id::text, md5(to_jsonb(x)::text) from organizations x;
end $$;
do $$
declare a record; f record; o uuid; n_own int; n_oth int; i int := 0; cnt int; aud int; mk text;
begin
 for a in select * from iso.actor where role='owner' order by key loop
  select org into o from iso.target where hotel=a.hotel limit 1;
  for f in select * from (values
    ('fn_admin_alert_rule_save','alert_rules','alert_rule.changed','x.delay_minutes=7',
      'select fn_admin_alert_rule_save((select event from alert_rules where organization_id=%L order by event limit 1), jsonb_build_object(''delay_minutes'',7,''version'',(select version from alert_rules where organization_id=%L order by event limit 1)))'),
    ('fn_admin_update_ai_settings','ai_settings','ai_settings_updated','x.extra_instructions=%M',
      'select fn_admin_update_ai_settings(jsonb_build_object(''extra_instructions'',%M))'),
    ('fn_admin_update_organization','organizations','organization.updated','x.name_en=%M',
      'select fn_admin_update_organization(jsonb_build_object(''name_en'',%M))')
   ) v(fn,tbl,act,cond,call) loop
   i := i+1; mk := quote_literal('ioz2-'||a.hotel||'-'||i);
   delete from sn; perform pg_temp.take('b');
   perform iso.set_claims(a.auth_user); set local role authenticated;
   execute replace(replace(replace(f.call,'%M',mk),'%L',quote_literal(o::text)),'%L',quote_literal(o::text));
   reset role; perform pg_temp.take('a');
   select count(*) into n_own from (select t,id,h from sn where tag='a' and org=o except select t,id,h from sn where tag='b' and org=o) z;
   insert into res select f.fn||'|'||a.key||'|own-org-exactly-2-changed-rows', n_own=2 and not exists (select 1 from sn b where b.tag='b' and b.org=o and not exists (select 1 from sn x where x.tag='a' and x.org=o and x.t=b.t and x.id=b.id));
   execute format('select count(*) from %I x where (x.%s=%L) and %s and exists (select 1 from sn s where s.tag=%L and s.t=%L and s.id=coalesce(to_jsonb(x)->>''id'', to_jsonb(x)->>''organization_id'')||coalesce(''|''||(to_jsonb(x)->>''event''),'''')) and not exists (select 1 from sn s where s.tag=%L and s.t=%L and s.id=coalesce(to_jsonb(x)->>''id'', to_jsonb(x)->>''organization_id'')||coalesce(''|''||(to_jsonb(x)->>''event''),'''') and s.h=md5(to_jsonb(x)::text))',
     f.tbl, case when f.tbl='organizations' then 'id' else 'organization_id' end, o, replace(f.cond,'%M',mk), 'a', f.tbl, 'b', f.tbl) into cnt;
   insert into res select f.fn||'|'||a.key||'|expected-row-updated-once', cnt=1;
   select count(*) into aud from audit_events e where e.organization_id=o and e.action=f.act and exists(select 1 from sn x where x.tag='a' and x.t='audit_events' and x.id=e.id::text) and not exists(select 1 from sn x where x.tag='b' and x.t='audit_events' and x.id=e.id::text);
   insert into res select f.fn||'|'||a.key||'|one-audit-row', aud=1;
   select count(*) into n_oth from ((select org,t,id,h from sn where tag='a' and org<>o except select org,t,id,h from sn where tag='b' and org<>o) union all (select org,t,id,h from sn where tag='b' and org<>o except select org,t,id,h from sn where tag='a' and org<>o)) z;
   insert into res select f.fn||'|'||a.key||'|other-orgs-unchanged', n_oth=0 and (select count(*) from sn where tag='a' and org<>o)>0;
  end loop;
 end loop;
end $$;
select name, ok from res order by name;
do $$ begin
 if (select count(*) from res)<>24 or exists(select 1 from res where not ok) then raise exception 'implicit-org-2 proof FAILED: % of % ok; failing: %', (select count(*) from res where ok),(select count(*) from res),(select string_agg(name,', ') from res where not ok); end if;
 raise notice 'implicit-org-2 proof OK 24/24';
end $$;
rollback;
