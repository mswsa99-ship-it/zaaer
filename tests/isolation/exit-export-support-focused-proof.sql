-- Local qualification: fn_hotel_exit_export (0102) and fn_platform_support_guests (0082). Source 27a2339.
-- Disposable DB, synthetic rows (ids fb...), one transaction, rolled back. No suspend/delete/restore, no protected
-- function (fn_platform_grant_support is never called: grants are inserted as fixture rows).
begin;
create temp table test_results(name text primary key, ok boolean not null, detail text);
grant all on test_results to public;
create temp table snap(k text primary key, v text);
grant all on snap to public;
create function pg_temp.rec(n text, ok boolean, d text default null) returns void language sql security definer as $$ insert into test_results values(n, coalesce(ok,false), d) $$;
create function pg_temp.cnt(q text) returns bigint language plpgsql security definer as $$ declare n bigint; begin execute q into n; return n; end $$;
create function pg_temp.txt(q text) returns text language plpgsql security definer as $$ declare n text; begin execute q into n; return n; end $$;
create function pg_temp.login(uid text, sess text default null) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub',uid,false);
  perform set_config('request.jwt.claims', case when sess is null then json_build_object('sub',uid)::text else json_build_object('sub',uid,'session_id',sess)::text end,false); end $$;
create function pg_temp.fails(n text, stmt text, p_like text) returns void language plpgsql as $$
declare m text; begin
  begin execute stmt; perform pg_temp.rec(n,false,'did not fail');
  exception when others then get stacked diagnostics m = message_text; perform pg_temp.rec(n, m like p_like, m); end;
end $$;
grant execute on function pg_temp.rec(text,boolean,text), pg_temp.cnt(text), pg_temp.txt(text), pg_temp.login(text,text), pg_temp.fails(text,text,text) to public;

-- fixtures: org A (exports), org B (decoy), org C (suspended)
insert into organizations(id,name_ar) values ('fb000000-0000-4000-8000-00000000000a','XS hotel A'),('fb000000-0000-4000-8000-00000000000b','XS hotel B'),('fb000000-0000-4000-8000-00000000000c','XS hotel C');
insert into branches(id,organization_id,name_ar) values ('fb100000-0000-4000-8000-000000000001','fb000000-0000-4000-8000-00000000000a','XS A1'),('fb100000-0000-4000-8000-000000000002','fb000000-0000-4000-8000-00000000000b','XS B1');
insert into staff_profiles(id,auth_user_id,organization_id,full_name,email,role) values
 ('fb200000-0000-4000-8000-000000000001','fb300000-0000-4000-8000-000000000001','fb000000-0000-4000-8000-00000000000a','XS owner A','xs-owner-a@example.test','owner'),
 ('fb200000-0000-4000-8000-000000000002','fb300000-0000-4000-8000-000000000002','fb000000-0000-4000-8000-00000000000a','XS manager A','xs-mgr-a@example.test','manager'),
 ('fb200000-0000-4000-8000-000000000003','fb300000-0000-4000-8000-000000000003','fb000000-0000-4000-8000-00000000000b','XS owner B','xs-owner-b@example.test','owner'),
 ('fb200000-0000-4000-8000-000000000004','fb300000-0000-4000-8000-000000000004','fb000000-0000-4000-8000-00000000000c','XS owner C','xs-owner-c@example.test','owner');
insert into service_definitions(organization_id,branch_id,name_ar) select 'fb000000-0000-4000-8000-00000000000a','fb100000-0000-4000-8000-000000000001','XS svc A '||g from generate_series(1,3) g;
insert into service_definitions(organization_id,branch_id,name_ar) values ('fb000000-0000-4000-8000-00000000000b','fb100000-0000-4000-8000-000000000002','XS svc B');
insert into platform_operators(auth_user_id,full_name,is_active) values ('fb400000-0000-4000-8000-000000000001','XS operator 1',true),('fb400000-0000-4000-8000-000000000002','XS operator 2',true),('fb400000-0000-4000-8000-000000000003','XS inactive operator',false);
-- guest_profiles is global in this schema? find its tenant column
select pg_temp.rec('pre: guest_profiles has organization_id', exists(select 1 from information_schema.columns where table_name='guest_profiles' and column_name='organization_id'));
insert into guest_profiles(id,organization_id,full_name,phone,nationality)
 select ('fb500000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid,'fb000000-0000-4000-8000-00000000000a','XS guest A '||g,'0500000'||lpad(g::text,3,'0'),'SA' from generate_series(1,103) g;
insert into guest_profiles(id,organization_id,full_name,phone) select ('fb600000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid,'fb000000-0000-4000-8000-00000000000b','XS guest B '||g,'0511111'||lpad(g::text,3,'0') from generate_series(1,3) g;
insert into guest_profiles(id,organization_id,full_name) values ('fb700000-0000-4000-8000-000000000001','fb000000-0000-4000-8000-00000000000c','XS guest C');
insert into platform_support_grants(id,organization_id,operator_user_id,approved_by,reason,expires_at,revoked_at,created_at) values
 ('fb800000-0000-4000-8000-000000000001','fb000000-0000-4000-8000-00000000000a','fb400000-0000-4000-8000-000000000001','fb200000-0000-4000-8000-000000000001','XS valid grant A', now()+interval '2 hours',null,now()),
 ('fb800000-0000-4000-8000-000000000002','fb000000-0000-4000-8000-00000000000a','fb400000-0000-4000-8000-000000000002','fb200000-0000-4000-8000-000000000001','XS grant of operator 2', now()+interval '2 hours',null,now()),
 ('fb800000-0000-4000-8000-000000000003','fb000000-0000-4000-8000-00000000000a','fb400000-0000-4000-8000-000000000001','fb200000-0000-4000-8000-000000000001','XS revoked grant', now()+interval '2 hours',now(),now()),
 ('fb800000-0000-4000-8000-000000000004','fb000000-0000-4000-8000-00000000000a','fb400000-0000-4000-8000-000000000001','fb200000-0000-4000-8000-000000000001','XS expired grant', now()-interval '1 hour',null,now()-interval '3 hours'),
 ('fb800000-0000-4000-8000-000000000005','fb000000-0000-4000-8000-00000000000b','fb400000-0000-4000-8000-000000000001','fb200000-0000-4000-8000-000000000003','XS valid grant B', now()+interval '2 hours',null,now()),
 ('fb800000-0000-4000-8000-000000000006','fb000000-0000-4000-8000-00000000000c','fb400000-0000-4000-8000-000000000001','fb200000-0000-4000-8000-000000000004','XS grant on suspended hotel', now()+interval '2 hours',null,now()),
 ('fb800000-0000-4000-8000-000000000007','fb000000-0000-4000-8000-00000000000a','fb400000-0000-4000-8000-000000000003','fb200000-0000-4000-8000-000000000001','XS grant of inactive operator', now()+interval '2 hours',null,now());
update organizations set platform_status='suspended' where id='fb000000-0000-4000-8000-00000000000c';  -- fixture state, not via fn_hotel_exit_suspend
select pg_temp.rec('pre: no channel keys, outbox and journey_messages empty', pg_temp.cnt('select count(*) from branch_whatsapp_channels where bridge_key_hash is not null')=0 and pg_temp.cnt('select count(*) from whatsapp_outbox')=0 and pg_temp.cnt('select count(*) from journey_messages')=0);
insert into snap values
 ('orgs', pg_temp.txt($q$select md5(string_agg(to_jsonb(o)::text,'|' order by id)) from organizations o$q$)),
 ('guestsA', pg_temp.txt($q$select md5(string_agg(to_jsonb(g)::text,'|' order by id)) from guest_profiles g where organization_id='fb000000-0000-4000-8000-00000000000a'$q$)),
 ('guestsB', pg_temp.txt($q$select md5(string_agg(to_jsonb(g)::text,'|' order by id)) from guest_profiles g where organization_id='fb000000-0000-4000-8000-00000000000b'$q$)),
 ('grants', pg_temp.txt($q$select md5(string_agg(to_jsonb(g)::text,'|' order by id)) from platform_support_grants g$q$)),
 ('svcA', pg_temp.txt($q$select md5(string_agg(to_jsonb(g)::text,'|' order by id)) from service_definitions g where organization_id='fb000000-0000-4000-8000-00000000000a'$q$));
-- independent oracle for the guest_profiles table hash, computed here, not by the function under test
insert into snap values ('gp_hash_A', pg_temp.txt($q$select encode(extensions.digest(string_agg(to_jsonb(t)::text, E'\n' order by to_jsonb(t)::text),'sha256'),'hex') from guest_profiles t where organization_id='fb000000-0000-4000-8000-00000000000a'$q$));
insert into snap values ('svc_hash_A', pg_temp.txt($q$select encode(extensions.digest(string_agg(to_jsonb(t)::text, E'\n' order by to_jsonb(t)::text),'sha256'),'hex') from service_definitions t where organization_id='fb000000-0000-4000-8000-00000000000a'$q$));

-- =================== EXPORT ===================
set role authenticated;
select pg_temp.login('fb300000-0000-4000-8000-000000000001');
create temp table exp1(r jsonb); grant all on exp1 to public;
insert into exp1 select fn_hotel_exit_export('fb000000-0000-4000-8000-00000000000a');
reset role;
do $$ declare r jsonb := (select r from exp1); a hotel_exit_archives%rowtype; n_rows bigint; begin
  select * into a from hotel_exit_archives where id=(r->>'archive_id')::uuid;
  select count(*) into n_rows from hotel_exit_rows where archive_id=a.id;
  perform pg_temp.rec('E1 response has archive_id, tables, rows, sha256, files', r ? 'archive_id' and r ? 'tables' and r ? 'rows' and r ? 'sha256' and r ? 'files', r::text);
  perform pg_temp.rec('E2 archive row: hotel A, name, status completed, requested_by owner uid, prior status active',
    a.organization_id='fb000000-0000-4000-8000-00000000000a' and a.hotel_name='XS hotel A' and a.status='completed'
    and a.requested_by='fb300000-0000-4000-8000-000000000001' and a.prior_platform_status='active', to_jsonb(a)::text);
  perform pg_temp.rec('E3 archive totals match the response and the stored rows', a.row_count=(r->>'rows')::bigint and a.table_count=(r->>'tables')::int and a.overall_sha256=r->>'sha256' and a.row_count=n_rows, 'rows='||n_rows||' count='||a.row_count);
  perform pg_temp.rec('E4 every archived row belongs to hotel A, none to B or C', not exists(select 1 from hotel_exit_rows where archive_id=a.id and organization_id<>'fb000000-0000-4000-8000-00000000000a'), null);
  perform pg_temp.rec('E5 guest_profiles manifest: 103 rows and sha256 equal to an independent hash',
    (a.manifest->'tables'->'guest_profiles'->>'rows')='103' and (a.manifest->'tables'->'guest_profiles'->>'sha256')=(select v from snap where k='gp_hash_A')
    and (select count(*) from hotel_exit_rows where archive_id=a.id and table_name='guest_profiles')=103, a.manifest->'tables'->'guest_profiles'->>'rows');
  perform pg_temp.rec('E6 service_definitions manifest: 3 rows (not B''s) and independent sha256',
    (a.manifest->'tables'->'service_definitions'->>'rows')='3' and (a.manifest->'tables'->'service_definitions'->>'sha256')=(select v from snap where k='svc_hash_A'), null);
  perform pg_temp.rec('E7 organizations tombstone exported as 1 retained row; grants table named; platform_events counted not touched',
    (a.manifest->'retained'->'organizations'->>'rows')='1' and a.manifest->'tables' ? 'platform_support_grants' and a.manifest->'retained' ? 'platform_events', null);
  perform pg_temp.rec('E8 archive_row_data decodes: a guest row carries its own name and hotel',
    exists(select 1 from hotel_exit_rows where archive_id=a.id and table_name='guest_profiles' and row_data->>'full_name'='XS guest A 7' and row_data->>'organization_id'='fb000000-0000-4000-8000-00000000000a'), null);
  perform pg_temp.rec('E9 platform audit: one hotel.exit_exported by the owner for hotel A with the archive id, tables, rows, sha',
    (select count(*) from platform_events where action='hotel.exit_exported')=1
    and exists(select 1 from platform_events where action='hotel.exit_exported' and actor_user_id='fb300000-0000-4000-8000-000000000001' and organization_id='fb000000-0000-4000-8000-00000000000a'
               and details->>'archive_id'=a.id::text and (details->>'rows')::bigint=a.row_count and details->>'sha256'=a.overall_sha256), null);
end $$;
select pg_temp.rec('E10 export is read-only for the hotel: organizations, A and B guests, service rows, grants unchanged',
  pg_temp.txt($q$select md5(string_agg(to_jsonb(o)::text,'|' order by id)) from organizations o$q$)=(select v from snap where k='orgs')
  and pg_temp.txt($q$select md5(string_agg(to_jsonb(g)::text,'|' order by id)) from guest_profiles g where organization_id='fb000000-0000-4000-8000-00000000000a'$q$)=(select v from snap where k='guestsA')
  and pg_temp.txt($q$select md5(string_agg(to_jsonb(g)::text,'|' order by id)) from guest_profiles g where organization_id='fb000000-0000-4000-8000-00000000000b'$q$)=(select v from snap where k='guestsB')
  and pg_temp.txt($q$select md5(string_agg(to_jsonb(g)::text,'|' order by id)) from service_definitions g where organization_id='fb000000-0000-4000-8000-00000000000a'$q$)=(select v from snap where k='svcA')
  and pg_temp.txt($q$select md5(string_agg(to_jsonb(g)::text,'|' order by id)) from platform_support_grants g$q$)=(select v from snap where k='grants'));
select pg_temp.rec('E11 no archive, row or audit for hotel B', pg_temp.cnt($q$select count(*) from hotel_exit_archives where organization_id='fb000000-0000-4000-8000-00000000000b'$q$)=0 and pg_temp.cnt($q$select count(*) from hotel_exit_rows where organization_id='fb000000-0000-4000-8000-00000000000b'$q$)=0 and pg_temp.cnt($q$select count(*) from platform_events where organization_id='fb000000-0000-4000-8000-00000000000b'$q$)=0);
-- re-export supersedes
set role authenticated; select pg_temp.login('fb300000-0000-4000-8000-000000000001');
create temp table exp2(r jsonb); grant all on exp2 to public;
insert into exp2 select fn_hotel_exit_export('fb000000-0000-4000-8000-00000000000a');
reset role;
select pg_temp.rec('E12 second export: new archive completed, first superseded, two audit rows, hotel tables identical, only the retained platform_events entry differs (it now counts the first export audit row: 0 then 1)',
  (select r->>'archive_id' from exp2)<>(select r->>'archive_id' from exp1)
  and (select status from hotel_exit_archives where id=(select (r->>'archive_id')::uuid from exp1))='superseded'
  and (select status from hotel_exit_archives where id=(select (r->>'archive_id')::uuid from exp2))='completed'
  and pg_temp.cnt($q$select count(*) from platform_events where action='hotel.exit_exported'$q$)=2
  and (select a.manifest->'tables' from hotel_exit_archives a where a.id=(select (r->>'archive_id')::uuid from exp1)) = (select a.manifest->'tables' from hotel_exit_archives a where a.id=(select (r->>'archive_id')::uuid from exp2))
  and (select (a.manifest->'retained'->'platform_events'->>'rows') from hotel_exit_archives a where a.id=(select (r->>'archive_id')::uuid from exp1))='0'
  and (select (a.manifest->'retained'->'platform_events'->>'rows') from hotel_exit_archives a where a.id=(select (r->>'archive_id')::uuid from exp2))='1'
  and (select r->>'sha256' from exp2)<>(select r->>'sha256' from exp1));
-- export negatives
insert into snap values ('arch_n', pg_temp.cnt('select count(*) from hotel_exit_archives')::text),('rows_n', pg_temp.cnt('select count(*) from hotel_exit_rows')::text),('ev_n', pg_temp.cnt('select count(*) from platform_events')::text);
set role authenticated;
select pg_temp.login('fb300000-0000-4000-8000-000000000003');
select pg_temp.fails('E13 owner of hotel B refused on hotel A',$q$select fn_hotel_exit_export('fb000000-0000-4000-8000-00000000000a')$q$,'FORBIDDEN: hotel owner required%');
select pg_temp.login('fb300000-0000-4000-8000-000000000002');
select pg_temp.fails('E14 manager of hotel A refused',$q$select fn_hotel_exit_export('fb000000-0000-4000-8000-00000000000a')$q$,'FORBIDDEN: hotel owner required%');
select pg_temp.login('fb400000-0000-4000-8000-000000000001');
select pg_temp.fails('E15 platform operator (not a hotel owner) refused',$q$select fn_hotel_exit_export('fb000000-0000-4000-8000-00000000000a')$q$,'FORBIDDEN: hotel owner required%');
select pg_temp.login('fb300000-0000-4000-8000-000000000001');
select pg_temp.fails('E17 unknown hotel id refused (not owner of it)',$q$select fn_hotel_exit_export('fb000000-0000-4000-8000-0000000000ff')$q$,'FORBIDDEN: hotel owner required%');
set role anon;
select pg_temp.fails('E18 anon cannot execute',$q$select fn_hotel_exit_export('fb000000-0000-4000-8000-00000000000a')$q$,'%permission denied%');
reset role;
select pg_temp.rec('E13-E18 no write: archives, rows, platform events unchanged', pg_temp.cnt('select count(*) from hotel_exit_archives')=(select v::bigint from snap where k='arch_n') and pg_temp.cnt('select count(*) from hotel_exit_rows')=(select v::bigint from snap where k='rows_n') and pg_temp.cnt('select count(*) from platform_events')=(select v::bigint from snap where k='ev_n'));
-- already exited (fixture flag set directly, never through exit_delete)
update organizations set exited_at=now() where id='fb000000-0000-4000-8000-00000000000b';
set role authenticated; select pg_temp.login('fb300000-0000-4000-8000-000000000003');
select pg_temp.fails('E19 already-exited hotel refused',$q$select fn_hotel_exit_export('fb000000-0000-4000-8000-00000000000b')$q$,'EXIT: already_exited%');
reset role;
update organizations set exited_at=null where id='fb000000-0000-4000-8000-00000000000b';
select pg_temp.rec('E19 nothing written for the exited hotel', pg_temp.cnt($q$select count(*) from hotel_exit_archives where organization_id='fb000000-0000-4000-8000-00000000000b'$q$)=0);

-- =================== SUPPORT GUESTS ===================
insert into snap values ('ev_s', pg_temp.cnt('select count(*) from platform_events')::text);
set role authenticated; select pg_temp.login('fb400000-0000-4000-8000-000000000001');
create temp table sg1(r jsonb); grant all on sg1 to public;
insert into sg1 select fn_platform_support_guests('fb800000-0000-4000-8000-000000000001');
reset role;
select pg_temp.rec('S1 returns exactly 100 of the hotel''s 103 guests', jsonb_array_length((select r from sg1))=100);
select pg_temp.rec('S2 each element has only id and full_name (no phone, nationality)', not exists(select 1 from sg1, jsonb_array_elements(r) e where (select count(*) from jsonb_object_keys(e))<>2 or not (e ? 'id' and e ? 'full_name')));
select pg_temp.rec('S3 result equals the 100 lowest ids of hotel A with their names, in order',
  (select r from sg1) = (select jsonb_agg(jsonb_build_object('id',id,'full_name',full_name) order by id) from (select id,full_name from guest_profiles where organization_id='fb000000-0000-4000-8000-00000000000a' order by id limit 100) x));
select pg_temp.rec('S4 no guest of hotel B or C in the result', not exists(select 1 from sg1, jsonb_array_elements(r) e where (e->>'id')::uuid in (select id from guest_profiles where organization_id<>'fb000000-0000-4000-8000-00000000000a')));
select pg_temp.rec('S5 exactly one platform audit support.guests_read: operator, hotel A, reason, grant id, fields, limit 100',
  pg_temp.cnt($q$select count(*) from platform_events where action='support.guests_read'$q$)=1 and pg_temp.cnt('select count(*) from platform_events')=(select v::bigint+1 from snap where k='ev_s')
  and exists(select 1 from platform_events where action='support.guests_read' and actor_user_id='fb400000-0000-4000-8000-000000000001' and organization_id='fb000000-0000-4000-8000-00000000000a' and reason='XS valid grant A'
     and details->>'grant_id'='fb800000-0000-4000-8000-000000000001' and details->'fields'='["id","full_name"]'::jsonb and details->>'limit'='100'));
select pg_temp.rec('S6 read-only: guests, grants, hotels unchanged',
  pg_temp.txt($q$select md5(string_agg(to_jsonb(g)::text,'|' order by id)) from guest_profiles g where organization_id='fb000000-0000-4000-8000-00000000000a'$q$)=(select v from snap where k='guestsA')
  and pg_temp.txt($q$select md5(string_agg(to_jsonb(g)::text,'|' order by id)) from platform_support_grants g$q$)=(select v from snap where k='grants'));
-- foreign positive control: operator 1's grant on hotel B returns B's 3 guests only
set role authenticated; select pg_temp.login('fb400000-0000-4000-8000-000000000001');
create temp table sg2(r jsonb); grant all on sg2 to public;
insert into sg2 select fn_platform_support_guests('fb800000-0000-4000-8000-000000000005');
reset role;
select pg_temp.rec('S7 grant on hotel B returns B''s 3 guests only', jsonb_array_length((select r from sg2))=3 and not exists(select 1 from sg2, jsonb_array_elements(r) e where e->>'full_name' not like 'XS guest B %'));
insert into snap values ('ev_n2', pg_temp.cnt('select count(*) from platform_events')::text);
set role authenticated;
select pg_temp.login('fb400000-0000-4000-8000-000000000001');
select pg_temp.fails('S8 grant belonging to another operator',$q$select fn_platform_support_guests('fb800000-0000-4000-8000-000000000002')$q$,'FORBIDDEN: support grant required%');
select pg_temp.fails('S9 revoked grant',$q$select fn_platform_support_guests('fb800000-0000-4000-8000-000000000003')$q$,'FORBIDDEN: support grant required%');
select pg_temp.fails('S10 expired grant',$q$select fn_platform_support_guests('fb800000-0000-4000-8000-000000000004')$q$,'FORBIDDEN: support grant required%');
select pg_temp.fails('S11 grant on a suspended hotel',$q$select fn_platform_support_guests('fb800000-0000-4000-8000-000000000006')$q$,'FORBIDDEN: support grant required%');
select pg_temp.fails('S12 unknown grant id',$q$select fn_platform_support_guests('fb800000-0000-4000-8000-0000000000ff')$q$,'FORBIDDEN: support grant required%');
select pg_temp.fails('S13 null grant id',$q$select fn_platform_support_guests(null)$q$,'FORBIDDEN: support grant required%');
select pg_temp.login('fb400000-0000-4000-8000-000000000003');
select pg_temp.fails('S14 inactive operator',$q$select fn_platform_support_guests('fb800000-0000-4000-8000-000000000007')$q$,'FORBIDDEN: platform operator required%');
select pg_temp.login('fb300000-0000-4000-8000-000000000001');
select pg_temp.fails('S15 hotel owner (not an operator) with a valid grant id',$q$select fn_platform_support_guests('fb800000-0000-4000-8000-000000000001')$q$,'FORBIDDEN: platform operator required%');
set role anon;
select pg_temp.fails('S17 anon cannot execute',$q$select fn_platform_support_guests('fb800000-0000-4000-8000-000000000001')$q$,'%permission denied%');
reset role;
select pg_temp.rec('S8-S17 no platform event written by any refusal', pg_temp.cnt('select count(*) from platform_events')=(select v::bigint from snap where k='ev_n2'));
select pg_temp.rec('Z no outbound: outbox, journey_messages, channel keys still zero', pg_temp.cnt('select count(*) from whatsapp_outbox')=0 and pg_temp.cnt('select count(*) from journey_messages')=0 and pg_temp.cnt('select count(*) from branch_whatsapp_channels where bridge_key_hash is not null')=0);
select name, ok, left(coalesce(detail,''),100) detail from test_results order by name;
select case when exists(select 1 from test_results where not ok) then 'FAILED' else 'ALL PASS ('||(select count(*) from test_results)||')' end as result;
do $$begin if exists(select 1 from test_results where not ok) then raise exception 'Export/support assertion failed';end if;end $$;
rollback;
