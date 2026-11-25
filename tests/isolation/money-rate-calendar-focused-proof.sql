-- Money lane remaining3: fn_rate_calendar_set(p jsonb). Class A, branch-scoped. Disposable DB only, one transaction, rolls back.
-- Refuses to run if an enabled keyed web_bridge channel exists; asserts no outbox change.
\set ON_ERROR_STOP on
begin;
set local app.identity_key='money-ratecal-local-synthetic-key';
do $$begin if exists(select 1 from branch_whatsapp_channels where enabled and mode='web_bridge' and bridge_key_hash is not null) then raise exception 'REFUSED: enabled keyed web_bridge channel exists';end if;end $$;
create temp table rc_assert(name text, ok boolean, detail text);
create function pg_temp.rcchk(n text, b boolean, d text default null) returns void language sql as $$insert into rc_assert values(n, coalesce(b,false), d)$$;
create temp table rc_ob as select count(*) obn from whatsapp_outbox;
do $$
declare t record; own uuid; foreign_own uuid; sid uuid; b jsonb; a jsonb; rb jsonb; ra jsonb; r jsonb; err text; orgs text[]; act record; changes text[]; au record; can boolean; cat uuid; p jsonb; d1 date; d2 date; k int := 0; price bigint; row_ record; sig text; minp bigint;
begin
 orgs := array(select id::text from organizations);
 for t in select * from iso.target order by key loop
  k := k + 1; price := 45000 + k * 100;
  select auth_user into own from iso.actor where role='owner' and hotel=t.hotel;
  select auth_user into foreign_own from iso.actor where role='owner' and hotel<>t.hotel order by key limit 1;
  select staff.id into sid from staff_profiles staff where staff.auth_user_id=own;
  select c.id, c.min_nightly_halalas into cat, minp from room_categories c where c.branch_id=t.branch_id and c.archived_at is null order by c.id limit 1;
  d1 := current_date + 20 + k; d2 := d1 + 1;
  perform pg_temp.rcchk(t.key||'/fixture category and no calendar row on target nights', cat is not null and not exists(select 1 from rate_calendar rc where rc.category_id=cat and rc.night in (d1,d2)), cat::text);
  p := jsonb_build_object('branch_id', t.branch_id, 'category_ids', jsonb_build_array(cat), 'from', d1, 'to', d2, 'price_halalas', price);
  -- validation
  for sig in select unnest(array['no price','past night','range inverted','zero amount']) loop
   perform iso.set_claims(own); b:=iso.snap(); err:=null; set local role authenticated;
   begin
    if sig='no price' then perform fn_rate_calendar_set(p - 'price_halalas');
    elsif sig='past night' then perform fn_rate_calendar_set(p || jsonb_build_object('from', current_date - 3, 'to', current_date - 2));
    elsif sig='range inverted' then perform fn_rate_calendar_set(p || jsonb_build_object('from', d2, 'to', d1));
    else perform fn_rate_calendar_set(p || '{"price_halalas":0}'); end if;
   exception when others then err:=sqlerrm; end; reset role; a:=iso.snap();
   perform pg_temp.rcchk(t.key||'/validation '||sig||' (not a denial)', err like 'VALIDATION%' and a=b, err);
  end loop;
  -- foreign owner (other hotel), same payload
  perform iso.set_claims(foreign_own); b:=iso.snap(); err:=null; set local role authenticated;
  begin perform fn_rate_calendar_set(p); exception when others then err:=sqlerrm; end; reset role; a:=iso.snap();
  perform pg_temp.rcchk(t.key||'/foreign owner refused, whole-public no-write', err is not null and (err like 'FORBIDDEN%' or err like 'BRANCH%' or err like 'PAGE_%' or err like 'permission denied%') and a=b, err);
  -- anon
  perform iso.set_claims(null); b:=iso.snap(); err:=null; set local role anon;
  begin perform fn_rate_calendar_set(p); exception when others then err:=sqlerrm; end; reset role; a:=iso.snap();
  perform pg_temp.rcchk(t.key||'/anon refused', err like 'permission denied%' and a=b, err);
  -- same-hotel actors: wrong branch or role without the rates capability
  for act in select * from iso.actor x where x.hotel=t.hotel and x.role<>'owner' and x.role<>'guest' order by x.key loop
   perform iso.set_claims(act.auth_user); set local role authenticated; can := fn_can('rates'); reset role;
   continue when act.branch is not distinct from replace(t.key, t.hotel||'|', '') and can;
   b:=iso.snap(); err:=null; set local role authenticated;
   begin perform fn_rate_calendar_set(p); exception when others then err:=sqlerrm; end; reset role; a:=iso.snap();
   perform pg_temp.rcchk(t.key||'/'||act.key||' refused (cap='||can||')', (err like 'FORBIDDEN%' or err like 'PAGE_%' or err like 'permission denied%' or err like 'BRANCH%') and a=b, err);
  end loop;
  -- authorized control
  perform iso.set_claims(own); rb:=iso.row_snaps(orgs); set local role authenticated;
  begin r := fn_rate_calendar_set(p); exception when others then err:=sqlerrm; r := jsonb_build_object('err', err); end;
  reset role; ra:=iso.row_snaps(orgs);
  select array_agg(x.tbl||'|'||x.kind order by x.tbl, x.kind) into changes from iso.row_changes(rb, ra) x;
  perform pg_temp.rcchk(t.key||'/exact touched rows: two calendar inserts (two nights) and one audit, nothing else', changes = array['audit_events|ins','rate_calendar|ins','rate_calendar|ins'], changes::text);
  perform pg_temp.rcchk(t.key||'/no other org changed', not exists(select 1 from iso.row_changes(rb, ra) x where x.org<>t.org::text));
  perform pg_temp.rcchk(t.key||'/result carries no error', r->>'err' is null, r::text);
  perform pg_temp.rcchk(t.key||'/literal rows: category, both nights, price, branch and org', (select count(*) from rate_calendar rc where rc.category_id=cat and rc.night in (d1,d2) and rc.price_halalas=price and rc.branch_id=t.branch_id and rc.organization_id=t.org)=2,
     (select jsonb_agg(to_jsonb(rc)) from rate_calendar rc where rc.category_id=cat and rc.night in (d1,d2))::text);
  select * into au from audit_events e where e.organization_id=t.org and e.branch_id=t.branch_id and e.action like 'rate%' order by e.created_at desc limit 1;
  perform pg_temp.rcchk(t.key||'/audit identity', au.actor_id=sid and au.details::text like '%'||price||'%', au.details::text);
  -- repeat with the same price: rows unchanged in value, no third night, no other category
  rb:=iso.row_snaps(orgs); set local role authenticated; r := fn_rate_calendar_set(p); reset role; ra:=iso.row_snaps(orgs);
  perform pg_temp.rcchk(t.key||'/repeat leaves exactly two rows at the same price; OBSERVED touched '||coalesce((select array_agg(x.tbl||'|'||x.kind order by x.tbl, x.kind)::text from iso.row_changes(rb, ra) x),'none'),
     (select count(*) from rate_calendar rc where rc.category_id=cat and rc.night in (d1,d2) and rc.price_halalas=price)=2 and (select count(*) from rate_calendar rc where rc.category_id=cat and rc.night between d1 and d2)=2, r::text);
  -- clear: both nights removed or blanked for this category only
  perform iso.set_claims(own); rb:=iso.row_snaps(orgs); set local role authenticated; r := fn_rate_calendar_set(p - 'price_halalas' || '{"clear":"true"}'); reset role; ra:=iso.row_snaps(orgs);
  perform pg_temp.rcchk(t.key||'/clear leaves no priced rows on the target nights; OBSERVED touched '||coalesce((select array_agg(x.tbl||'|'||x.kind order by x.tbl, x.kind)::text from iso.row_changes(rb, ra) x),'none'),
     not exists(select 1 from rate_calendar rc where rc.category_id=cat and rc.night in (d1,d2) and rc.price_halalas is not null) and not exists(select 1 from iso.row_changes(rb, ra) x where x.org<>t.org::text), r::text);
 end loop;
 perform pg_temp.rcchk('no outbox change', (select count(*) from whatsapp_outbox)=(select obn from rc_ob));
end $$;
select name, ok::text as ok, coalesce(detail,'') as detail from rc_assert order by ok, name;
do $$ begin if exists(select 1 from rc_assert where not ok) then raise exception 'FAIL count %', (select count(*) from rc_assert where not ok); end if; end $$;
rollback;
