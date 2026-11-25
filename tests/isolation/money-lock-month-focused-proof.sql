-- Money-bank lane: fn_accounting_lock_month(p_month date, p_lock boolean, p_reason text). Class A, org-level (no org argument).
-- Disposable database only, one transaction, rolls back. Refuses to run if an enabled keyed web_bridge channel exists.
\set ON_ERROR_STOP on
begin;
set local app.identity_key='money-lockmonth-local-synthetic-key';
do $$begin if exists(select 1 from branch_whatsapp_channels where enabled and mode='web_bridge' and bridge_key_hash is not null) then raise exception 'REFUSED: enabled keyed web_bridge channel exists';end if;end $$;
create temp table lm_assert(name text, ok boolean, detail text);
create function pg_temp.lmchk(n text, b boolean, d text default null) returns void language sql as $$insert into lm_assert values(n, coalesce(b,false), d)$$;
create temp table lm_ob as select count(*) cnt from whatsapp_outbox;
do $$
declare t record; own uuid; foreign_own uuid; sid uuid; b jsonb; a jsonb; rb jsonb; ra jsonb; r jsonb; err text; orgs text[]; act record; changes text[]; au record; n int; can boolean; m date; k int := 0; ap accounting_periods%rowtype; sig text;
begin
 orgs := array(select id::text from organizations);
 for t in select distinct on (hotel) * from iso.target order by hotel, key loop
  k := k + 1; m := ('2019-0'||k||'-15')::date;
  select auth_user into own from iso.actor where role='owner' and hotel=t.hotel;
  select auth_user into foreign_own from iso.actor where role='owner' and hotel<>t.hotel order by key limit 1;
  select staff.id into sid from staff_profiles staff where staff.auth_user_id=own;
  perform pg_temp.lmchk(t.hotel||'/precondition: month has no period row', not exists(select 1 from accounting_periods where organization_id=t.org and month=date_trunc('month',m)::date));
  -- validation, not denial credit
  for sig in select unnest(array['future month','blank reason','long reason']) loop
   perform iso.set_claims(own); b:=iso.snap(); err:=null; set local role authenticated;
   begin
    if sig='future month' then perform fn_accounting_lock_month((current_date + interval '90 days')::date, true, 'x');
    elsif sig='blank reason' then perform fn_accounting_lock_month(m, true, '   ');
    else perform fn_accounting_lock_month(m, true, repeat('x',501)); end if;
   exception when others then err:=sqlerrm; end; reset role; a:=iso.snap();
   perform pg_temp.lmchk(t.hotel||'/validation '||sig||' (not a denial)', err like 'VALIDATION%' and a=b, err);
  end loop;
  -- anon
  perform iso.set_claims(null); b:=iso.snap(); err:=null; set local role anon;
  begin perform fn_accounting_lock_month(m, true, 'anon'); exception when others then err:=sqlerrm; end; reset role; a:=iso.snap();
  perform pg_temp.lmchk(t.hotel||'/anon refused', err like 'permission denied%' and a=b, err);
  -- same-hotel non-owner roles: those lacking accounts.close_month are refused with no write; capable ones are listed
  for act in select * from iso.actor x where x.hotel=t.hotel and x.role<>'owner' and x.role<>'guest' order by x.key loop
   perform iso.set_claims(act.auth_user); set local role authenticated; can := fn_can('accounts.close_month'); reset role;
   continue when can;
   b:=iso.snap(); err:=null; set local role authenticated;
   begin perform fn_accounting_lock_month(m, true, 'wrong actor'); exception when others then err:=sqlerrm; end; reset role; a:=iso.snap();
   perform pg_temp.lmchk(t.hotel||'/'||act.key||' refused (cap=false)', (err like 'FORBIDDEN%' or err like 'PAGE_%' or err like 'permission denied%') and a=b, err);
  end loop;
  perform pg_temp.lmchk(t.hotel||'/capability-holding non-owner roles (recorded, not asserted as denied)', true, (select string_agg(x.key, ',') from iso.actor x where x.hotel=t.hotel and x.role not in ('owner','guest')));
  -- lock: exact touched rows
  perform iso.set_claims(own); rb:=iso.row_snaps(orgs); set local role authenticated; r := fn_accounting_lock_month(m, true, 'lm-lock-'||t.hotel); reset role; ra:=iso.row_snaps(orgs);
  select array_agg(x.tbl||'|'||x.kind order by x.tbl, x.kind) into changes from iso.row_changes(rb, ra) x;
  perform pg_temp.lmchk(t.hotel||'/lock exact touched rows: one period insert + one audit insert', changes = array['accounting_periods|ins','audit_events|ins'], changes::text);
  perform pg_temp.lmchk(t.hotel||'/lock no other org changed', not exists(select 1 from iso.row_changes(rb, ra) x where x.org<>t.org::text));
  select * into ap from accounting_periods where organization_id=t.org and month=date_trunc('month',m)::date;
  perform pg_temp.lmchk(t.hotel||'/lock literal row', (r->>'ok')::boolean and (r->>'locked')::boolean and ap.locked and ap.changed_by=sid and ap.reason='lm-lock-'||t.hotel and r->>'month'=to_char(m,'YYYY-MM'), to_jsonb(ap)::text);
  select * into au from audit_events e where e.action='accounting.month_locked' and e.organization_id=t.org order by e.created_at desc limit 1;
  perform pg_temp.lmchk(t.hotel||'/lock audit identity', au.actor_id=sid and au.branch_id is null and au.details::text like '%'||to_char(m,'YYYY-MM')||'%' and au.details::text like '%lm-lock-'||t.hotel||'%', au.details::text);
  -- repeat lock: unchanged, no write
  b:=iso.snap(); set local role authenticated; r := fn_accounting_lock_month(m, true, 'again'); reset role; a:=iso.snap();
  perform pg_temp.lmchk(t.hotel||'/repeat lock is unchanged and writes nothing', (r->>'unchanged')::boolean and a=b, r::text);
  -- the other hotel's owner cannot see or change this period (no org argument: attack is via the same month)
  perform iso.set_claims(foreign_own); rb:=iso.row_snaps(orgs); set local role authenticated; r := fn_accounting_lock_month(m, false, 'foreign unlock attempt'); reset role; ra:=iso.row_snaps(orgs);
  perform pg_temp.lmchk(t.hotel||'/foreign owner unlocking the same month leaves this hotel locked', (select locked from accounting_periods where organization_id=t.org and month=date_trunc('month',m)::date) and not exists(select 1 from iso.row_changes(rb, ra) x where x.org=t.org::text), r::text);
  -- unlock: exact touched rows
  perform iso.set_claims(own); rb:=iso.row_snaps(orgs); set local role authenticated; r := fn_accounting_lock_month(m, false, 'lm-open-'||t.hotel); reset role; ra:=iso.row_snaps(orgs);
  select array_agg(x.tbl||'|'||x.kind order by x.tbl, x.kind) into changes from iso.row_changes(rb, ra) x;
  perform pg_temp.lmchk(t.hotel||'/unlock exact touched rows: one period update + one audit insert', changes = array['accounting_periods|upd','audit_events|ins'], changes::text);
  select * into ap from accounting_periods where organization_id=t.org and month=date_trunc('month',m)::date;
  perform pg_temp.lmchk(t.hotel||'/unlock literal row', not ap.locked and ap.reason='lm-open-'||t.hotel and ap.changed_by=sid, to_jsonb(ap)::text);
  select * into au from audit_events e where e.action='accounting.month_opened' and e.organization_id=t.org order by e.created_at desc limit 1;
  perform pg_temp.lmchk(t.hotel||'/unlock audit identity', au.actor_id=sid and au.details::text like '%lm-open-'||t.hotel||'%', au.details::text);
 end loop;
 perform pg_temp.lmchk('no outbox change', (select count(*) from whatsapp_outbox)=(select cnt from lm_ob));
end $$;
select name, ok::text as ok, coalesce(detail,'') as detail from lm_assert order by ok, name;
do $$ begin if exists(select 1 from lm_assert where not ok) then raise exception 'FAIL count %', (select count(*) from lm_assert where not ok); end if; end $$;
rollback;
