-- Guest bearer-capability proof for the token MUTATORS fn_guest_submit_checkin, fn_guest_set_children, fn_guest_acknowledge
-- (+ fn_guest_submit foreign-guest attempt and the read-only fn_guest_checkout no-write check).
-- Credential: registration_sessions.token (the guest's actual bearer capability) with optional request.headers x-hotel-slug.
-- Source: fn_token_reservation (0082): token must be live and its org active; when x-hotel-slug is present the token's org must equal fn_guest_org_id();
--         without the header the token alone resolves its own reservation (bearer contract). No owner role, no header heuristic acceptance.
-- Scope: 2 hotels x (target reservation + same-hotel decoy reservation), anon role, own synthetic rows, rolled back. Local synthetic DB only.
-- NOT a proof for other token functions, not a call-graph proof, not PG16 unless run there.
\set ON_ERROR_STOP on
begin;
-- Synthetic, transaction-local test bootstrap only. No real key material.
set local app.identity_key = 'guest-mutator-local-test-only';
insert into organizations(id,name_ar,guest_slug) values
 ('e1820000-0000-0000-0000-000000000001','GM Hotel A','gm-gate-a'),('e1820000-0000-0000-0000-000000000002','GM Hotel B','gm-gate-b');
insert into branches(id,organization_id,name_ar) values
 ('e1820000-0000-0000-0000-000000000011','e1820000-0000-0000-0000-000000000001','GM A1'),('e1820000-0000-0000-0000-000000000012','e1820000-0000-0000-0000-000000000002','GM B1');
insert into reservations(id,organization_id,branch_id,check_in,check_out) values
 ('e1820000-0000-0000-0000-000000000101','e1820000-0000-0000-0000-000000000001','e1820000-0000-0000-0000-000000000011',current_date,current_date+2),
 ('e1820000-0000-0000-0000-000000000103','e1820000-0000-0000-0000-000000000001','e1820000-0000-0000-0000-000000000011',current_date,current_date+2),
 ('e1820000-0000-0000-0000-000000000102','e1820000-0000-0000-0000-000000000002','e1820000-0000-0000-0000-000000000012',current_date,current_date+2),
 ('e1820000-0000-0000-0000-000000000104','e1820000-0000-0000-0000-000000000002','e1820000-0000-0000-0000-000000000012',current_date,current_date+2);
insert into reservation_guests(reservation_id,is_primary,full_name) select id,true,'Gm Guest Name' from reservations where organization_id in ('e1820000-0000-0000-0000-000000000001','e1820000-0000-0000-0000-000000000002');
insert into registration_sessions(reservation_id,token,expires_at) values
 ('e1820000-0000-0000-0000-000000000101','GM-TOK-A',now()+interval '1 hour'),('e1820000-0000-0000-0000-000000000103','GM-TOK-A-DECOY',now()+interval '1 hour'),
 ('e1820000-0000-0000-0000-000000000102','GM-TOK-B',now()+interval '1 hour'),('e1820000-0000-0000-0000-000000000104','GM-TOK-B-DECOY',now()+interval '1 hour');
create temp table fx as select * from (values
 ('A','gm-gate-a','gm-gate-b','e1820000-0000-0000-0000-000000000101'::uuid,'GM-TOK-A','e1820000-0000-0000-0000-000000000103'::uuid,'GM-TOK-A-DECOY','e1820000-0000-0000-0000-000000000001'::uuid),
 ('B','gm-gate-b','gm-gate-a','e1820000-0000-0000-0000-000000000102'::uuid,'GM-TOK-B','e1820000-0000-0000-0000-000000000104'::uuid,'GM-TOK-B-DECOY','e1820000-0000-0000-0000-000000000002'::uuid)
 ) v(h,slug,fslug,rid,tok,drid,dtok,org);
create temp table gmp(name text not null, ok boolean not null);
-- every reservation of the proof, with the rows a mutator can touch, in one jsonb (superuser read)
create function pg_temp.outside_snap() returns jsonb language plpgsql as $$
declare t record; cond text; v text; result jsonb := '{}'::jsonb;
begin
 for t in select relname from pg_class where relnamespace='public'::regnamespace and relkind='r' order by relname loop
  cond := case t.relname
   when 'reservations' then 'id not in (select rid from fx union all select drid from fx)'
   when 'audit_events' then 'entity_id is null or entity_id not in (select rid from fx union all select drid from fx)'
   when 'notifications' then 'link is null or link not in (select ''/staff/reservations/''||rid from fx union all select ''/staff/reservations/''||drid from fx)'
   when 'access_release_requests' then 'reservation_id not in (select rid from fx union all select drid from fx)'
   when 'stay_acknowledgements' then 'reservation_id not in (select rid from fx union all select drid from fx)'
   when 'reservation_guests' then 'reservation_id not in (select rid from fx union all select drid from fx)'
   else 'true' end;
  execute format($snap$select md5(coalesce(string_agg(md5(to_jsonb(q)::text),'' order by md5(to_jsonb(q)::text)),'')) from public.%I q where %s$snap$, t.relname, cond) into v;
  result := result || jsonb_build_object(t.relname,v);
 end loop;
 return result;
end $$;
create function pg_temp.snap() returns jsonb language sql as $$
 select jsonb_object_agg(r.id::text, jsonb_build_object('res', to_jsonb(r), 'audit', (select count(*) from audit_events a where a.entity_id=r.id),
   'notif', (select count(*) from notifications n where n.link='/staff/reservations/'||r.id::text), 'arr', (select count(*) from access_release_requests q where q.reservation_id=r.id),
   'ack', (select count(*) from stay_acknowledgements k where k.reservation_id=r.id), 'guests', (select count(*) from reservation_guests g where g.reservation_id=r.id),
   'audit_rows', (select coalesce(jsonb_agg(to_jsonb(a) order by a.id),'[]') from audit_events a where a.entity_id=r.id),
   'notif_rows', (select coalesce(jsonb_agg(to_jsonb(n) order by n.id),'[]') from notifications n where n.link='/staff/reservations/'||r.id::text),
   'arr_rows', (select coalesce(jsonb_agg(to_jsonb(q) order by q.id),'[]') from access_release_requests q where q.reservation_id=r.id),
   'ack_rows', (select coalesce(jsonb_agg(to_jsonb(k) order by k.id),'[]') from stay_acknowledgements k where k.reservation_id=r.id),
   'guest_rows', (select coalesce(jsonb_agg(to_jsonb(g) order by g.id),'[]') from reservation_guests g where g.reservation_id=r.id)))
   || jsonb_build_object('_all_other_public_rows',pg_temp.outside_snap())
 from reservations r where r.organization_id in (select org from fx) $$;
create function pg_temp.changed(b jsonb, a jsonb) returns text[] language sql as $$
 select coalesce(array_agg(k order by k),'{}') from jsonb_object_keys(a) k where a->k is distinct from b->k $$;
-- run one guest call as anon with an optional site header; returns 'ok:<result>' or the error text. Never lets an error escape.
create function pg_temp.try(p_sql text, p_slug text) returns text language plpgsql as $$
declare r text;
begin
  perform set_config('request.headers', case when p_slug is null then '{}' else json_build_object('x-hotel-slug', p_slug)::text end, true);
  -- Clear all inherited staff claims before the actual guest boundary.
  perform set_config('request.jwt.claims','{}',true);
  perform set_config('request.jwt.claim.sub','',true);
  set local role anon;
  begin execute p_sql into r; r := 'ok:'||coalesce(r,'');
  exception when others then r := sqlerrm; end;
  reset role; return r;
end $$;
grant all on gmp to anon;
create function pg_temp.chk(p_name text, p_ok boolean) returns void language sql as $$ insert into gmp values (p_name, coalesce(p_ok,false)) $$;
create function pg_temp.sqlfor(p_fn text, p_tok text, p_hash text) returns text language sql as $$
 select case p_fn when 'checkin' then format('select fn_guest_submit_checkin(%L)::text', p_tok)
                  when 'children' then format('select fn_guest_set_children(%L, ''[5]''::jsonb)::text', p_tok)
                  else format('select fn_guest_acknowledge(%L, %L)::text', p_tok, p_hash) end $$;
do $$
declare f record; fn text; sc text; b jsonb; a jsonb; res text; tok text; slug text; h text; fh text; own text; dec text; v jsonb; fg uuid; dg uuid; pay jsonb; fo record;
begin
 for f in select * from fx order by h loop
  own := f.rid::text; dec := f.drid::text;
  select * into fo from fx where fx.h <> f.h;
  foreach fn in array array['checkin','children','ack'] loop
   h := 'gm-hash-'||f.h;
   -- NEGATIVES first: the call must fail and nothing may change in any of the 4 reservations
   foreach sc in array array['foreign-header','invalid-token','expired','suspended-org','suspended-org-with-header'] loop
    if sc='expired' then update registration_sessions set expires_at=now()-interval '1 minute' where token=f.tok; end if;
    if sc like 'suspended-org%' then update organizations set platform_status='suspended' where id=f.org; end if;
    tok := case when sc='invalid-token' then 'GM-NOT-A-TOKEN' else f.tok end;
    slug := case sc when 'foreign-header' then f.fslug when 'suspended-org' then null else f.slug end;
    b := pg_temp.snap(); res := pg_temp.try(pg_temp.sqlfor(fn,tok,h), slug); a := pg_temp.snap();
    perform pg_temp.chk(f.h||'/'||fn||': '||sc||' -> TOKEN_INVALID', res='TOKEN_INVALID');
    perform pg_temp.chk(f.h||'/'||fn||': '||sc||' -> no row changed in any of the 4 reservations', pg_temp.changed(b,a)='{}');
    if sc='expired' then update registration_sessions set expires_at=now()+interval '1 hour' where token=f.tok; end if;
    if sc like 'suspended-org%' then update organizations set platform_status='active' where id=f.org; end if;
   end loop;
   -- POSITIVE 1: own token + matching header -> success; only the token's own reservation changes
   if fn='ack' then h := (pg_temp.try(format('select fn_guest_stay_summary(%L)->>''hash''',f.tok), f.slug)); h := substr(h,4); end if;
   b := pg_temp.snap(); res := pg_temp.try(pg_temp.sqlfor(fn,f.tok,h), f.slug); a := pg_temp.snap();
   perform pg_temp.chk(f.h||'/'||fn||': own token + matching header succeeds', left(res,3)='ok:');
   perform pg_temp.chk(f.h||'/'||fn||': only the own reservation changed (decoy + foreign hotel untouched)', pg_temp.changed(b,a)=array[own]);
   if fn='checkin' then
     perform pg_temp.chk(f.h||'/checkin: own access_status locked->eligibility_review, 1 release request, 1 notification, 1 audit',
       b->own->'res'->>'access_status'='locked' and a->own->'res'->>'access_status'='eligibility_review' and (a->own->>'arr')::int=(b->own->>'arr')::int+1 and (a->own->>'notif')::int=(b->own->>'notif')::int+1 and (a->own->>'audit')::int=(b->own->>'audit')::int+1);
   elsif fn='children' then
     perform pg_temp.chk(f.h||'/children: own children_ages=[5], 1 notification, 1 audit', a->own->'res'->'children_ages'='[5]'::jsonb and (a->own->>'notif')::int=(b->own->>'notif')::int+1 and (a->own->>'audit')::int=(b->own->>'audit')::int+1);
   else
     perform pg_temp.chk(f.h||'/ack: own 1 stay acknowledgement with the passed hash, 1 audit', (a->own->>'ack')::int=(b->own->>'ack')::int+1 and (a->own->>'audit')::int=(b->own->>'audit')::int+1
       and exists (select 1 from stay_acknowledgements k where k.reservation_id=f.rid and k.text_hash=h));
   end if;
   -- POSITIVE 2: the decoy's own token, bearer without any header -> only the decoy changes
   if fn='ack' then h := substr(pg_temp.try(format('select fn_guest_stay_summary(%L)->>''hash''',f.dtok), null),4); end if;
   b := pg_temp.snap(); res := pg_temp.try(pg_temp.sqlfor(fn,f.dtok,h), null); a := pg_temp.snap();
   perform pg_temp.chk(f.h||'/'||fn||': decoy own token without header (bearer) succeeds', left(res,3)='ok:');
   perform pg_temp.chk(f.h||'/'||fn||': bearer call changed only the decoy reservation', pg_temp.changed(b,a)=array[dec]);
   -- REPEAT with the own token: never touches another reservation
   if fn='ack' then h := substr(pg_temp.try(format('select fn_guest_stay_summary(%L)->>''hash''',f.tok), f.slug),4); end if;
   b := pg_temp.snap(); res := pg_temp.try(pg_temp.sqlfor(fn,f.tok,h), f.slug); a := pg_temp.snap();
   perform pg_temp.chk(f.h||'/'||fn||': repeat own call changes at most the own reservation', pg_temp.changed(b,a) <@ array[own]);
   if fn in ('checkin','ack') then perform pg_temp.chk(f.h||'/'||fn||': repeat is idempotent (no row changed)', pg_temp.changed(b,a)='{}'); end if;
   -- FOREIGN-OBJECT with the same own token
   if fn='ack' then
     -- the other hotel's own summary hash passed with this hotel's token: the source verifies the hash against THIS token's summary (SUMMARY_CHANGED), nothing is recorded anywhere
     fh := substr(pg_temp.try(format('select fn_guest_stay_summary(%L)->>''hash''',fo.tok), fo.slug),4);
     b := pg_temp.snap(); res := pg_temp.try(pg_temp.sqlfor('ack',f.tok,fh), f.slug); a := pg_temp.snap();
     perform pg_temp.chk(f.h||'/ack: foreign-hotel hash with own token is refused (SUMMARY_CHANGED) and recorded nowhere', fh<>h and res like 'SUMMARY_CHANGED%' and pg_temp.changed(b,a)='{}' and not exists (select 1 from stay_acknowledgements k where k.text_hash=fh and k.reservation_id=f.rid));
   elsif fn='children' then
     b := pg_temp.snap(); res := pg_temp.try(format('select fn_guest_set_children(%L, ''[99]''::jsonb)::text', f.tok), f.slug); a := pg_temp.snap();
     perform pg_temp.chk(f.h||'/children: invalid ages [99] with the own token is refused and changes nothing', res like 'VALIDATION%' and pg_temp.changed(b,a)='{}');
   end if;
  end loop;
  -- fn_guest_submit with a guest id that belongs to another reservation (foreign hotel, same-hotel decoy): refused, nothing changes
  select g.id into fg from reservation_guests g where g.reservation_id=fo.rid and g.is_primary;
  select g.id into dg from reservation_guests g where g.reservation_id=f.drid and g.is_primary;
  pay := jsonb_build_object('full_name','Aaaa Bbbb Cccc','identity_type','national_id','identity_number','1000000001','nationality','SA','birth_date','1990-01-01','consent','true','phone','0551234567','ack_hash','gm-submit-hash');
  foreach sc in array array['foreign-hotel-guest','same-hotel-decoy-guest'] loop
   b := pg_temp.snap(); res := pg_temp.try(format('select fn_guest_submit(%L, %L::uuid, %L::jsonb)::text', f.tok, case when sc like 'foreign%' then fg else dg end, pay), f.slug); a := pg_temp.snap();
   perform pg_temp.chk(f.h||'/submit: '||sc||' id with own token -> GUEST_NOT_FOUND (got: '||left(res,40)||')', res='GUEST_NOT_FOUND');
   perform pg_temp.chk(f.h||'/submit: '||sc||' id with own token changes nothing', pg_temp.changed(b,a)='{}');
  end loop;
  -- fn_guest_checkout is STABLE/read: own token returns data and writes nothing; foreign header refused
  b := pg_temp.snap(); res := pg_temp.try(format('select fn_guest_checkout(%L)::text', f.tok), f.slug); a := pg_temp.snap();
  perform pg_temp.chk(f.h||'/checkout(read): own token returns data, writes nothing', left(res,3)='ok:' and pg_temp.changed(b,a)='{}');
  res := pg_temp.try(format('select fn_guest_checkout(%L)::text', f.tok), f.fslug);
  perform pg_temp.chk(f.h||'/checkout(read): foreign header -> TOKEN_INVALID', res='TOKEN_INVALID');
 end loop;
end $$;
select case when ok then 'proof-ok' else 'proof-FAILED' end as result, name from gmp order by name;
select count(*) as assertion_count, count(*) filter(where ok is distinct from true) as failed from gmp;
do $$ begin if exists (select 1 from gmp where ok is distinct from true) then raise exception 'guest mutator proof failed'; end if; end $$;
rollback;
