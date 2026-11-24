-- Guest bearer-capability proof for the read-only token function fn_guest_checkout: exact response identity.
-- Credential: registration_sessions.token with optional request.headers x-hotel-slug (source: fn_guest_checkout -> fn_checkout_offer(fn_token_reservation(token))).
-- Contract proved: own token (+ matching header or no header) returns the offer of EXACTLY that reservation (room number, balance, deposit, status, check_out, instructions text,
-- open flag), never the same-hotel decoy's or the other hotel's values; foreign-hotel header, unknown token, expired token and suspended org -> TOKEN_INVALID; the function writes nothing.
-- Scope: 2 hotels x (target reservation + same-hotel decoy reservation), anon role, own synthetic rows, rolled back. Local synthetic DB only.
-- NOT a proof for other token functions, not a call-graph proof, not PG16 unless run there. Late-hours/night-extension fields (open stays with a late_checkout, next arrival) are not asserted.
\set ON_ERROR_STOP on
begin;
set local app.identity_key = 'guest-checkout-local-test-only';
insert into organizations(id,name_ar,guest_slug) values
 ('e1850000-0000-0000-0000-000000000001','GC Hotel A','gc-gate-a'),('e1850000-0000-0000-0000-000000000002','GC Hotel B','gc-gate-b');
insert into branches(id,organization_id,name_ar) values
 ('e1850000-0000-0000-0000-000000000011','e1850000-0000-0000-0000-000000000001','GC A1'),('e1850000-0000-0000-0000-000000000012','e1850000-0000-0000-0000-000000000002','GC B1');
insert into branch_journey_settings(branch_id, organization_id, checkout_instructions) values
 ('e1850000-0000-0000-0000-000000000011','e1850000-0000-0000-0000-000000000001','GC-INSTR-HOTEL-A-ONLY'),('e1850000-0000-0000-0000-000000000012','e1850000-0000-0000-0000-000000000002','GC-INSTR-HOTEL-B-ONLY')
 on conflict (branch_id) do update set checkout_instructions = excluded.checkout_instructions;
insert into room_categories(id,organization_id,branch_id,name_ar) values
 ('e1850000-0000-0000-0000-000000000301','e1850000-0000-0000-0000-000000000001','e1850000-0000-0000-0000-000000000011','GC Cat A'),
 ('e1850000-0000-0000-0000-000000000302','e1850000-0000-0000-0000-000000000002','e1850000-0000-0000-0000-000000000012','GC Cat B');
insert into rooms(id,organization_id,branch_id,category_id,room_number) values
 ('e1850000-0000-0000-0000-000000000201','e1850000-0000-0000-0000-000000000001','e1850000-0000-0000-0000-000000000011','e1850000-0000-0000-0000-000000000301','GC-A-OWN'),
 ('e1850000-0000-0000-0000-000000000203','e1850000-0000-0000-0000-000000000001','e1850000-0000-0000-0000-000000000011','e1850000-0000-0000-0000-000000000301','GC-A-DECOY'),
 ('e1850000-0000-0000-0000-000000000202','e1850000-0000-0000-0000-000000000002','e1850000-0000-0000-0000-000000000012','e1850000-0000-0000-0000-000000000302','GC-B-OWN'),
 ('e1850000-0000-0000-0000-000000000204','e1850000-0000-0000-0000-000000000002','e1850000-0000-0000-0000-000000000012','e1850000-0000-0000-0000-000000000302','GC-B-DECOY');
insert into reservations(id,organization_id,branch_id,check_in,check_out,status,room_id,balance_due_halalas,deposit_balance_halalas) values
 ('e1850000-0000-0000-0000-000000000101','e1850000-0000-0000-0000-000000000001','e1850000-0000-0000-0000-000000000011',current_date-1,current_date,'checked_in','e1850000-0000-0000-0000-000000000201',1111,111),
 ('e1850000-0000-0000-0000-000000000103','e1850000-0000-0000-0000-000000000001','e1850000-0000-0000-0000-000000000011',current_date-1,current_date,'checked_in','e1850000-0000-0000-0000-000000000203',3333,333),
 ('e1850000-0000-0000-0000-000000000102','e1850000-0000-0000-0000-000000000002','e1850000-0000-0000-0000-000000000012',current_date-1,current_date,'checked_in','e1850000-0000-0000-0000-000000000202',2222,222),
 ('e1850000-0000-0000-0000-000000000104','e1850000-0000-0000-0000-000000000002','e1850000-0000-0000-0000-000000000012',current_date-1,current_date,'checked_in','e1850000-0000-0000-0000-000000000204',4444,444);
insert into registration_sessions(reservation_id,token,expires_at) values
 ('e1850000-0000-0000-0000-000000000101','GC-TOK-A',now()+interval '1 hour'),('e1850000-0000-0000-0000-000000000103','GC-TOK-A-DECOY',now()+interval '1 hour'),
 ('e1850000-0000-0000-0000-000000000102','GC-TOK-B',now()+interval '1 hour'),('e1850000-0000-0000-0000-000000000104','GC-TOK-B-DECOY',now()+interval '1 hour');
create temp table fx as select * from (values
 ('A','gc-gate-a','gc-gate-b','GC-TOK-A','GC-TOK-A-DECOY','GC-A-OWN','GC-A-DECOY',1111,111,'GC-INSTR-HOTEL-A-ONLY','e1850000-0000-0000-0000-000000000001'::uuid),
 ('B','gc-gate-b','gc-gate-a','GC-TOK-B','GC-TOK-B-DECOY','GC-B-OWN','GC-B-DECOY',2222,222,'GC-INSTR-HOTEL-B-ONLY','e1850000-0000-0000-0000-000000000002'::uuid)
 ) v(h,slug,fslug,tok,dtok,room,droom,bal,dep,instr,org);
create temp table gcp(name text not null, ok boolean not null);
create function pg_temp.snap() returns text language plpgsql as $$
declare t record; v text; acc text := '';
begin
 for t in select relname from pg_class where relnamespace='public'::regnamespace and relkind='r' order by relname loop
  execute format('select md5(coalesce(string_agg(md5(to_jsonb(q)::text),'''' order by md5(to_jsonb(q)::text)),'''')) from public.%I q', t.relname) into v;
  acc := acc || t.relname || ':' || v || ';';
 end loop; return md5(acc);
end $$;
create function pg_temp.try(p_sql text, p_slug text) returns text language plpgsql as $$
declare r text;
begin
  perform set_config('request.headers', case when p_slug is null then '{}' else json_build_object('x-hotel-slug', p_slug)::text end, true);
  perform set_config('request.jwt.claims','{}',true);
  perform set_config('request.jwt.claim.sub','',true);
  set local role anon;
  begin execute p_sql into r; r := 'ok:'||coalesce(r,'');
  exception when others then r := sqlerrm; end;
  reset role; return r;
end $$;
grant all on gcp to anon;
create function pg_temp.chk(p_name text, p_ok boolean) returns void language sql as $$ insert into gcp values (p_name, coalesce(p_ok,false)) $$;
do $$
declare f record; res text; j jsonb; sc text; b text; a text; tok text; slug text; n int;
begin
 for f in select * from fx order by h loop
  -- NEGATIVES: must fail with TOKEN_INVALID and write nothing
  foreach sc in array array['foreign-header','unknown-token','expired','suspended-org','suspended-org-with-header'] loop
   if sc='expired' then update registration_sessions set expires_at=now()-interval '1 minute' where token=f.tok; end if;
   if sc like 'suspended-org%' then update organizations set platform_status='suspended' where id=f.org; end if;
   tok := case when sc='unknown-token' then 'GC-NOT-A-TOKEN' else f.tok end;
   slug := case sc when 'foreign-header' then f.fslug when 'suspended-org' then null else f.slug end;
   b := pg_temp.snap(); res := pg_temp.try(format('select fn_guest_checkout(%L)::text', tok), slug); a := pg_temp.snap();
   perform pg_temp.chk(f.h||': '||sc||' -> TOKEN_INVALID', res='TOKEN_INVALID');
   perform pg_temp.chk(f.h||': '||sc||' -> nothing written', a=b);
   if sc='expired' then update registration_sessions set expires_at=now()+interval '1 hour' where token=f.tok; end if;
   if sc like 'suspended-org%' then update organizations set platform_status='active' where id=f.org; end if;
  end loop;
  -- POSITIVES: exact identity, with the header and without it (bearer contract)
  foreach sc in array array['with-header','no-header'] loop
   b := pg_temp.snap(); res := pg_temp.try(format('select fn_guest_checkout(%L)::text', f.tok), case sc when 'with-header' then f.slug end); a := pg_temp.snap();
   perform pg_temp.chk(f.h||': own token '||sc||' succeeds', left(res,3)='ok:');
   j := nullif(substr(res,4),'')::jsonb;
   perform pg_temp.chk(f.h||': '||sc||' room_number is the own reservation room', j->>'room_number'=f.room);
   perform pg_temp.chk(f.h||': '||sc||' balance_due/deposit are the own values ('||f.bal||'/'||f.dep||')', (j->>'balance_due')::bigint=f.bal and (j->>'deposit_halalas')::bigint=f.dep);
   perform pg_temp.chk(f.h||': '||sc||' open=true, status checked_in, check_out today', (j->>'open')::boolean is true and j->>'status'='checked_in' and (j->>'check_out')::date=current_date);
   perform pg_temp.chk(f.h||': '||sc||' instructions text is the own hotel text only', j->>'instructions'=f.instr);
   perform pg_temp.chk(f.h||': '||sc||' response carries no decoy/other-hotel room, balance or instructions',
     position(f.droom in res)=0 and position('GC-'||case f.h when 'A' then 'B' else 'A' end||'-' in res)=0 and position('GC-INSTR-HOTEL-'||case f.h when 'A' then 'B' else 'A' end in res)=0
     and (j->>'balance_due')::bigint <> case f.h when 'A' then 3333 else 4444 end);
   perform pg_temp.chk(f.h||': '||sc||' writes nothing', a=b);
  end loop;
  -- same-hotel decoy token returns the decoy's own values (identity follows the token, not the hotel)
  res := pg_temp.try(format('select fn_guest_checkout(%L)::text', f.dtok), f.slug); j := nullif(substr(res,4),'')::jsonb;
  perform pg_temp.chk(f.h||': decoy token returns the decoy room and balance, not the target''s', j->>'room_number'=f.droom and (j->>'balance_due')::bigint = case f.h when 'A' then 3333 else 4444 end);
  -- the decoy token with the other hotel header is refused
  res := pg_temp.try(format('select fn_guest_checkout(%L)::text', f.dtok), f.fslug);
  perform pg_temp.chk(f.h||': decoy token + foreign header -> TOKEN_INVALID', res='TOKEN_INVALID');
 end loop;
end $$;
select case when ok then 'proof-ok' else 'proof-FAILED' end as result, name from gcp order by name;
select count(*) as assertion_count, count(*) filter(where ok is distinct from true) as failed from gcp;
do $$ begin if exists (select 1 from gcp where ok is distinct from true) then raise exception 'guest checkout proof failed'; end if; end $$;
rollback;
