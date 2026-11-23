-- Plan 2.6 independent negative controls. Synthetic fixtures only, rolled back.
\set ON_ERROR_STOP on
begin;
create temp table test_results(name text,ok boolean,detail text);
grant all on test_results to public;
do $$
declare a uuid:='90000000-0000-0000-0000-000000000101'; b uuid:='90000000-0000-0000-0000-000000000102'; ba uuid:='90000000-0000-0000-0000-000000000111'; bb uuid:='90000000-0000-0000-0000-000000000112'; ra uuid; rb uuid; tok text; answer jsonb; n int; denied boolean:=false; code text; tok_a text; tok_b text; guest_tok text; review_tok text:='GT-review-token-only-test'; own_ref text;
begin
 insert into organizations(id,name_ar) values(a,'فندق فحص الزائر الأول'),(b,'فندق فحص الزائر الثاني');
 update organizations set guest_slug=id::text where id in(a,b);
 insert into branches(id,organization_id,name_ar) values(ba,a,'فرع الزائر الأول'),(bb,b,'فرع الزائر الثاني');
 insert into reservations(organization_id,branch_id,external_ref,check_in,check_out) values(a,ba,'GT-HOTEL-A',current_date,current_date+1) returning id into ra;
 insert into reservations(organization_id,branch_id,external_ref,check_in,check_out) values(b,bb,'GT-HOTEL-B',current_date,current_date+1) returning id into rb;
 insert into reservation_guests(reservation_id,is_primary,full_name,phone) values(ra,true,'ضيف فحص أول','0509876101'),(rb,true,'ضيف فحص ثان','0509876101');
 -- No caller-supplied hotel: must not silently select a hotel in a multi-hotel deployment.
 perform set_config('request.headers','{}',true);
 execute 'set local role anon';
 begin select count(*) into n from branches; exception when insufficient_privilege then n:=0; end;
 execute 'reset role';
 insert into test_results values('GT01 visitors cannot enumerate raw branches of all hotels',n=0,n::text);
 execute 'set local role anon';
 begin answer:=fn_public_organization(); exception when others then answer:=null; end;
 execute 'reset role';
 insert into test_results values('GT02 address-less visitor never gets the first active hotel',answer is null,null);
 -- A single booking reference must not authorize the same phone at an unrelated hotel.
 execute 'set local role anon';
 begin
  answer:=fn_guest_phone_verify_ref('0509876101','GT-HOTEL-A','gt-negative');
  if answer->>'token' is not null then
   answer:=fn_guest_phone_reservations(answer->>'token');
   denied:=not exists(select 1 from jsonb_array_elements(answer->'reservations') x where x->>'ref'='GT-HOTEL-B');
  else denied:=true; end if;
 exception when others then denied:=true; end;
 execute 'reset role';
 insert into test_results values('GT03 one hotel reference never grants another hotels booking',denied,null);
 -- WhatsApp is already bound to a branch. Its session constructor must accept and enforce that branch.
 if to_regprocedure('public.fn_whatsapp_phone_session(text,uuid)') is null then
  insert into test_results values('GT04 WhatsApp sessions carry their authenticated branch',false,'scoped constructor missing');
 else
  execute 'select fn_whatsapp_phone_session($1,$2)' into tok using '0509876101',ba;
  select count(*) into n from guest_phone_sessions where token=tok and organization_id=a and branch_id=ba;
  answer:=fn_guest_phone_reservations(tok);
  insert into test_results values('GT04 WhatsApp sessions carry their authenticated branch',n=1 and jsonb_array_length(answer->'reservations')=1 and answer->'reservations'->0->>'ref'='GT-HOTEL-A',null);
 end if;
 insert into test_results select 'GT05 public site resolver exists',to_regprocedure('public.fn_guest_site(text)') is not null,null;
 if to_regprocedure('public.fn_guest_site(text)') is not null then
  perform set_config('request.headers',jsonb_build_object('x-hotel-slug',a::text)::text,true);
  execute 'set local role anon';
  select count(*) into n from branches;
  answer:=fn_guest_phone_verify_ref('0509876101','GT-HOTEL-A','gt-a'); tok_a:=answer->>'token';
  answer:=fn_guest_phone_reservations(tok_a);
  insert into test_results values('GT06 selected hotel A lists one branch and one own booking',n=1 and jsonb_array_length(answer->'reservations')=1 and answer->'reservations'->0->>'ref'='GT-HOTEL-A',null);
  own_ref:=answer->'reservations'->0->>'internal_ref';
  answer:=fn_guest_phone_verify_ref('0509876101','GT-HOTEL-B','gt-a');
  insert into test_results values('GT07 hotel B reference is refused on hotel A address',answer->>'status'='mismatch' and answer->>'token' is null,null);
  answer:=fn_guest_phone_open(tok_a,own_ref); guest_tok:=answer->>'token';
  execute 'reset role';
  -- Reservation internals are not readable as anon. The own ref was saved separately below.
  perform set_config('request.headers',jsonb_build_object('x-hotel-slug',b::text)::text,true);
  execute 'set local role anon';
  denied:=false;
  begin perform fn_guest_phone_reservations(tok_a); exception when others then denied:=sqlerrm='TOKEN_INVALID'; end;
  insert into test_results values('GT08 hotel A phone capability is rejected on hotel B address',denied,null);
  denied:=false;
  begin perform fn_guest_session(guest_tok); exception when others then denied:=sqlerrm='TOKEN_INVALID'; end;
  insert into test_results values('GT14 hotel A per-booking link is refused under hotel B address',denied,null);
  answer:=fn_public_branch(ba);
  insert into test_results values('GT09 cross-hotel public branch lookup returns no record',answer is null,null);
  answer:=fn_guest_phone_verify_ref('0509876101','GT-HOTEL-B','gt-b'); tok_b:=answer->>'token';
  answer:=fn_guest_phone_reservations(tok_b);
  insert into test_results values('GT10 same phone independently verifies hotel B only',jsonb_array_length(answer->'reservations')=1 and answer->'reservations'->0->>'ref'='GT-HOTEL-B',null);
  execute 'reset role';
  insert into guest_reviews(organization_id,branch_id,reservation_id,token_hash) values(a,ba,ra,encode(extensions.digest(review_tok,'sha256'),'hex'));
  execute 'set local role anon';
  denied:=false;
  begin perform fn_public_review(review_tok); exception when others then denied:=sqlerrm='TOKEN_INVALID'; end;
  insert into test_results values('GT15 hotel A review link is rejected under hotel B address',denied,null);
  denied:=false;
  begin perform fn_public_submit_review(review_tok,'{"overall":10}'::jsonb); exception when others then denied:=sqlerrm='TOKEN_INVALID'; end;
  insert into test_results values('GT17 cross-hotel review write is rejected',denied,null);
  execute 'reset role';
  perform set_config('request.headers',jsonb_build_object('x-guest-token',review_tok)::text,true);
  execute 'set local role anon';
  answer:=fn_public_organization();
  insert into test_results values('GT18 legacy review token brands its own hotel',answer->>'name_ar'='فندق فحص الزائر الأول',null);
  execute 'reset role';
  perform set_config('request.headers',jsonb_build_object('x-hotel-slug',a::text)::text,true);
  execute 'set local role anon';
  answer:=fn_public_review(review_tok);
  insert into test_results values('GT16 review link still works at its own hotel address',answer->>'branch_name'='فرع الزائر الأول',null);
  execute 'reset role';
  -- An A code cannot be consumed on B, and its success marks only A's guest as phone-verified.
  perform set_config('request.headers',jsonb_build_object('x-hotel-slug',a::text)::text,true);
  answer:=fn_guest_phone_start('0509876101','gt-code'); code:=answer->>'code';
  insert into test_results values('GT11 OTP uses the selected hotels booking branch',answer->>'branch_id'=ba::text,null);
  perform set_config('request.headers',jsonb_build_object('x-hotel-slug',b::text)::text,true);
  answer:=fn_guest_phone_verify('0509876101',code,'gt-code');
  insert into test_results values('GT12 hotel A code is not a hotel B proof',answer->>'status'='expired' and answer->>'token' is null,null);
  perform set_config('request.headers',jsonb_build_object('x-hotel-slug',a::text)::text,true);
  answer:=fn_guest_phone_verify('0509876101',code,'gt-code');
  insert into test_results select 'GT13 code verification changes only its own hotels guest',answer->>'status'='ok' and (select phone_verified from reservation_guests where reservation_id=ra) and not (select phone_verified from reservation_guests where reservation_id=rb),null;
 end if;
end $$;
select case when ok then 'PASS' else 'FAIL' end as result,name,detail from test_results order by name;
do $$ begin
 if exists(select 1 from test_results where ok is not true) or (select count(*) from test_results)<>18 then raise exception 'GUEST HOTEL TESTS FAILED'; end if;
end $$;
rollback;
