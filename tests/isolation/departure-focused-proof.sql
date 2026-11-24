-- Local iso minimal fixture only; all state/probes rolled back. No late fee branch.
\set ON_ERROR_STOP on
begin;
set local app.identity_key='departure-local-synthetic-key';
-- Reject outbound-capable fixture state, do not suppress channels or alerts.
do $$begin if exists(select 1 from branch_whatsapp_channels where enabled and mode='web_bridge' and bridge_key_hash is not null) then raise exception 'Outbound-capable channel state refused';end if;end $$;
\ir rpc-fixtures-departure.sql
create temp table dep_assert(name text,ok boolean);
create function pg_temp.depcheck(n text,b boolean) returns void language sql as $$insert into dep_assert values(n,coalesce(b,false))$$;
select fn_audit(c.org,c.branch,null,'journey.guest_departed','reservation',c.id::uuid,jsonb_build_object('after',jsonb_build_object('via','decoy'))) from iso.created c where c.tbl='reservations' and c.purpose='departure';
create temp table dep_audit_before as select id,md5(to_jsonb(a)::text) h from audit_events a;
do $$declare t record;rid uuid;tok text;slug text;badslug text;b jsonb;a jsonb;rb jsonb;ra jsonb;q text;err text;v jsonb;sig text; touches text[]; changes text[];begin
 for t in select * from iso.target order by key loop
  select c.id::uuid into rid from iso.created c where c.tbl='reservations' and c.purpose='departure' and c.branch=t.branch_id;
  select s.token into tok from registration_sessions s where s.reservation_id=rid;
  select guest_slug into slug from organizations where id=t.org;
  select guest_slug into badslug from organizations where id<>t.org order by id limit 1;
  perform iso.set_claims(null);
  perform set_config('request.headers',jsonb_build_object('x-hotel-slug',badslug)::text,true);
  b:=iso.snap();err:=null;
  set local role anon;
  begin perform fn_guest_departure_instructions(tok);exception when others then err:=sqlerrm;end;
  reset role;a:=iso.snap();
  perform pg_temp.depcheck(t.key||'/foreign-header instructions',err='TOKEN_INVALID' and b=a);
  b:=iso.snap();err:=null;set local role anon;
  begin perform fn_guest_departure(tok,'page');exception when others then err:=sqlerrm;end;
  reset role;a:=iso.snap();perform pg_temp.depcheck(t.key||'/foreign-header departure',err='TOKEN_INVALID' and b=a);
  perform set_config('request.headers',jsonb_build_object('x-hotel-slug',slug)::text,true);
  b:=iso.snap();err:=null;
  set local role anon;
  begin perform fn_guest_departure(tok,'page');exception when others then err:=sqlerrm;end;
  reset role;a:=iso.snap();
  perform pg_temp.depcheck(t.key||'/instructions-first rejection',err='VALIDATION: instructions_first' and b=a);
  foreach sig in array array['fn_guest_departure_instructions(p_token text)#departure','fn_guest_departure(p_token text, p_via text)#departure'] loop
   select iso.render_call(call_sql,t.key,'dep-proof') into q from iso.rpc_adapter where signature=sig;
   b:=iso.snap();rb:=iso.row_snaps(array(select id::text from organizations));
   set local role anon;execute q into v;reset role;
   a:=iso.snap();ra:=iso.row_snaps(array(select id::text from organizations));
   select array_agg(tbl||'|'||pk order by tbl,pk) into changes from iso.row_changes(rb,ra);
   select iso.touch_set(iso.render_call(touch_sql,t.key,'dep-proof')) into touches from iso.rpc_adapter where signature=sig;
   perform pg_temp.depcheck(t.key||'/'||sig||'/exact touch',changes @> touches and touches @> changes and cardinality(changes)=case when sig like 'fn_guest_departure_instructions%' then 1 else 3 end);
   perform pg_temp.depcheck(t.key||'/'||sig||'/effect',iso.eval_bool((select iso.render_call(effect_sql,t.key,'dep-proof') from iso.rpc_adapter where signature=sig)));
   perform pg_temp.depcheck(t.key||'/'||sig||'/no other public changes',not exists(select 1 from jsonb_each(iso.snap_diff(b,a)) d where d.key<>all(case when sig like 'fn_guest_departure_instructions%' then array['reservations'] else array['reservations','audit_events','alert_events'] end)));
  end loop;
  perform pg_temp.depcheck(t.key||'/guest audit attribution',exists(select 1 from audit_events where entity_id=rid and action='journey.guest_departed' and details->'after'->>'via'='page' and actor_id is null));
  b:=iso.snap();set local role anon;perform fn_guest_departure(tok,'page');reset role;a:=iso.snap();
  perform pg_temp.depcheck(t.key||'/repeat no write',a=b);
 end loop;
end $$;
select * from dep_assert order by name;
select count(*) assertions,count(*) filter(where not ok) failed from dep_assert;
do $$begin if exists(select 1 from dep_assert where not ok) then raise exception 'Departure proof failed';end if;
if exists(select 1 from dep_audit_before b left join audit_events a using(id) where b.h is distinct from md5(to_jsonb(a)::text)) then raise exception 'Preexisting departure audits changed';end if;end $$;
rollback;
