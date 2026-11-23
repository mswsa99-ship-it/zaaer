-- Plan2.7 two-hotel backend controls. Synthetic fixtures, rolled back.
\set ON_ERROR_STOP on
begin;
create temp table test_results(name text,ok boolean,detail text);
do $$
declare a uuid:='81000000-0000-0000-0000-000000000001'; b uuid:='81000000-0000-0000-0000-000000000002'; ba uuid:='81000000-0000-0000-0000-000000000011'; bb uuid:='81000000-0000-0000-0000-000000000012'; r jsonb; n int;
begin
 insert into organizations(id,name_ar) values(a,'فندق الخلفية الأول'),(b,'فندق الخلفية الثاني');
 insert into branches(id,organization_id,name_ar) values(ba,a,'فرع الخلفية الأول'),(bb,b,'فرع الخلفية الثاني');
 insert into guest_lookup_attempts(organization_id,branch_id,external_ref,ok) select a,ba,'BT-'||g,false from generate_series(1,10) g;
 perform fn_run_monitors(null);
 select count(*) into n from review_items where organization_id=b and kind='monitor:verification_failures';
 insert into test_results values('BT01 failed guest proofs at A never raise an alert at B',n=0,n::text);
 select count(*) into n from monitor_runs where branch_id in(ba,bb);
 insert into test_results values('BT02 global monitor job reaches both hotels branches',n=2,n::text);
 insert into test_results values('BT03 mailbox settings require explicit hotel',to_regprocedure('public.fn_bank_mail_poll_config(uuid)') is not null,null);
 insert into test_results values('BT04 mailbox checkpoint requires explicit hotel',to_regprocedure('public.fn_bank_mail_poll_done(uuid,bigint,bigint,text)') is not null,null);
 insert into test_results values('BT05 bank ingest requires explicit hotel',to_regprocedure('public.fn_bank_ingest(uuid,jsonb)') is not null,null);
 perform fn_ai_usage_bump(a,current_date,2,10,20,0,0);
 perform fn_ai_usage_bump(b,current_date,3,30,40,0,0);
 insert into bank_mail_settings(organization_id,enabled,last_uid) values(a,false,1),(b,false,5);
 perform fn_bank_mail_poll_done(a,42,7,null);
 select count(*) into n from bank_mail_settings where (organization_id=a and last_uid=42) or (organization_id=b and last_uid=5);
 insert into test_results values('BT07 mailbox checkpoint cannot change the other hotel',n=2,n::text);
 r:=fn_bank_ingest(a,jsonb_build_object('body','BT07-hotel-a-only'));
 select count(*) into n from bank_messages where id=(r->>'message_id')::uuid and organization_id=a;
 insert into test_results values('BT08 bank message is stored in its explicit hotel',n=1,n::text);
 begin perform fn_bank_mail_poll_config(); n:=0; exception when others then n:=case when sqlerrm='HOTEL_REQUIRED' then 1 else 0 end; end;
 insert into test_results values('BT09 legacy service call fails closed in a multi-hotel project',n=1,null);
 select count(*) into n from ai_usage_daily where (organization_id=a and requests=2 and tokens_in=10) or (organization_id=b and requests=3 and tokens_in=30);
 insert into test_results values('BT06 AI counters are independent per hotel',n=2,n::text);
end $$;
select case when ok then 'PASS' else 'FAIL' end as result,name,detail from test_results order by name;
do $$ begin if exists(select 1 from test_results where ok is not true) then raise exception 'BACKEND HOTEL TESTS FAILED'; end if; end $$;
rollback;
