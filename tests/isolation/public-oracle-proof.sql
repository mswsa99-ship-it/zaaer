-- LOCAL standalone transactional proof, no external messages/effects. Requires engine definitions.
\set ON_ERROR_STOP on
begin;
insert into organizations(id,name_ar,name_en,guest_slug) values
 ('e1710000-0000-0000-0000-000000000001','Public A','A','synthetic-public-a'),
 ('e1710000-0000-0000-0000-000000000002','Public B',null,'synthetic-public-b');
insert into branches(id,organization_id,name_ar) values
 ('e1710000-0000-0000-0000-000000000011','e1710000-0000-0000-0000-000000000001','A1'),
 ('e1710000-0000-0000-0000-000000000012','e1710000-0000-0000-0000-000000000002','B1');
insert into iso.target values('public-a|branch-1','public-a','branch-1','e1710000-0000-0000-0000-000000000001','e1710000-0000-0000-0000-000000000011');
insert into iso.rpc_adapter(signature,family,mutates,call_sql,public_keys) values
 ('fn_guest_site(p_slug text)','proof',false,$q$select fn_guest_site('synthetic-public-a')$q$,array['id','slug','name_ar','name_en']);
-- Direct identity oracle negative contracts.
do $$ declare good jsonb; o uuid := 'e1710000-0000-0000-0000-000000000001'; begin
 good:=fn_guest_site('synthetic-public-a');
 assert iso.public_identity_ok('fn_guest_site(p_slug text)',good,o), 'correct exact identity';
 assert not iso.public_identity_ok('fn_guest_site(p_slug text)',fn_guest_site('synthetic-public-b'),o), 'wrong hotel with valid four keys';
 assert not iso.public_identity_ok('fn_guest_site(p_slug text)',good||'{"slug":"wrong"}',o), 'wrong slug';
 assert not iso.public_identity_ok('fn_guest_site(p_slug text)',good||'{"name_ar":"wrong"}',o), 'wrong name';
 assert not coalesce(iso.public_identity_ok('fn_guest_site(p_slug text)',null,o),false), 'null result';
 assert not iso.public_identity_ok('fn_guest_site(p_slug text)',good-'name_en',o), 'missing nullable key';
 assert not iso.public_identity_ok('fn_guest_site(p_slug text)',jsonb_build_array(good),o), 'array instead of exact object';
 assert not iso.public_identity_ok('fn_guest_site(p_slug text)',good||jsonb_build_object('name_ar',jsonb_build_array(jsonb_build_object('id',o))),o), 'nested same-key shape not identity';
 assert not iso.public_identity_ok('fn_other_public()',good,o), 'unqualified signature';
end $$;
-- Use actual anon actor. Engine and oracle read expected private identity via existing test-only helpers.
set local role anon;
select iso.set_claims(null);
select iso.rpc_probe('public-positive','fn_guest_site(p_slug text)','guest|-|-','public-a|branch-1',false,iso.snap());
reset role;
do $$ begin
 assert exists(select 1 from iso.probe_result where probe_id='public-positive' and outcome='success' and rows_ret=0 and detail like '%public_keys_ok=true public_identity_ok=true extra_keys=0%'), 'anon exception exact payload';
end $$;
-- Keys alone must not bless a different valid hotel. The adapter is deliberately corrupted only inside rollback.
update iso.rpc_adapter set call_sql=$q$select fn_guest_site('synthetic-public-b')$q$ where signature='fn_guest_site(p_slug text)';
set local role anon;
select iso.rpc_probe('public-wrong-hotel','fn_guest_site(p_slug text)','guest|-|-','public-a|branch-1',false,iso.snap());
reset role;
do $$ begin
 assert exists(select 1 from iso.probe_result where probe_id='public-wrong-hotel' and outcome='success' and rows_ret>0 and detail like '%public_keys_ok=false public_identity_ok=false%'), 'wrong hotel fails closed despite four allowed keys';
end $$;
-- Nested arrays must terminate promptly, detect private keys and never earn identity credit.
update iso.rpc_adapter set call_sql=$q$select '{"id":[[{"private":"secret"}]],"slug":"synthetic-public-a","name_ar":"Public A","name_en":"A"}'::jsonb$q$ where signature='fn_guest_site(p_slug text)';
set local statement_timeout='3s';
set local role anon;
select iso.rpc_probe('public-nested','fn_guest_site(p_slug text)','guest|-|-','public-a|branch-1',false,iso.snap());
reset role;
do $$ begin
 assert exists(select 1 from iso.probe_result where probe_id='public-nested' and outcome='success' and rows_ret>0 and detail like '%public_keys_ok=false public_identity_ok=false%'), 'nested private key terminates and fails';
end $$;
-- Inactive/suspended target cannot be accepted even with a once-correct payload.
do $$ declare good jsonb; o uuid := 'e1710000-0000-0000-0000-000000000001'; begin
 good:=fn_guest_site('synthetic-public-a');
 update branches set is_active=false where organization_id=o;
 assert not iso.public_identity_ok('fn_guest_site(p_slug text)',good,o), 'no active branch';
 update branches set is_active=true,archived_at=now() where organization_id=o;
 assert not iso.public_identity_ok('fn_guest_site(p_slug text)',good,o), 'all branches archived';
 update branches set archived_at=null where organization_id=o;
 update organizations set platform_status='suspended' where id=o;
 assert not iso.public_identity_ok('fn_guest_site(p_slug text)',good,o), 'suspended hotel';
end $$;
select 'PUBLIC ORACLE PROOF COMPLETED, SCOPED NOT FULL GATE' as result;
rollback;
