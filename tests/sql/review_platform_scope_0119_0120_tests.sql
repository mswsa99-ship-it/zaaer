-- 0119 review objection notifications and 0120 grouped platform check keep the tenant and branch boundary.
-- Run on a DB through 0125 with the seed rows. Rolls back.
\set ON_ERROR_STOP off
begin;
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create or replace function xg_login(p_uid uuid, p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email)::text, false); end $$;
create or replace function xg_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$ insert into test_results values (p_name, p_ok, p_detail); $$;
create or replace function xg_sd(p_sql text) returns bigint language plpgsql security definer as $$ declare n bigint; begin execute p_sql into n; return n; end $$;
grant execute on function xg_login(uuid,text), xg_record(text,boolean,text), xg_sd(text) to public;
insert into branches(id, organization_id, name_ar) values ('1a910000-0000-0000-0000-000000000012','00000000-0000-0000-0000-000000000001','rp other branch') on conflict do nothing;
insert into staff_profiles(id, auth_user_id, organization_id, full_name, email, role) values
 ('1c000000-0000-0000-0000-000000000001','cc000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','rp owner','rpowner@test.local','owner'),
 ('1c000000-0000-0000-0000-000000000002','cc000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001','rp manager','rpmgr@test.local','manager');
insert into branch_memberships(staff_id, branch_id, organization_id) values
 ('1c000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000001'),
 ('1c000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000001');
insert into organizations(id, name_ar) values ('1f900000-0000-0000-0000-000000000002','rp foreign org') on conflict do nothing;
insert into branches(id, organization_id, name_ar) values ('1f900000-0000-0000-0000-000000000012','1f900000-0000-0000-0000-000000000002','rp foreign branch') on conflict do nothing;
insert into booking_sources(id, organization_id, name, kind) values ('1f900000-0000-0000-0000-000000000022','1f900000-0000-0000-0000-000000000002','rp foreign ext','external') on conflict do nothing;
-- review items: own branch, other branch (same org), foreign org; the decoys already carry an objection (what the 0119 loop used to notify on)
insert into review_items(id, organization_id, branch_id, kind, entity_type, entity_id, summary, objection_note, objection_at) values
 ('1c100000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010','manual','reservation','1c100000-0000-0000-0000-0000000000a1','RP own branch',null,null),
 ('1c100000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001','1a910000-0000-0000-0000-000000000012','manual','reservation','1c100000-0000-0000-0000-0000000000a2','RP other-branch decoy','old objection',now()),
 ('1c100000-0000-0000-0000-000000000003','1f900000-0000-0000-0000-000000000002','1f900000-0000-0000-0000-000000000012','manual','reservation','1c100000-0000-0000-0000-0000000000a3','RP foreign-org decoy','old objection',now());
select xg_record('RP00 fixtures: decoys with open objections exist in another branch and another org', xg_sd('select count(*) from review_items where id in (''1c100000-0000-0000-0000-000000000002'',''1c100000-0000-0000-0000-000000000003'') and objection_at is not null and reviewed_at is null')=2);
create temp table n0 as select count(*) c from notifications;
set role authenticated;
select xg_login('cc000000-0000-0000-0000-000000000001','rpowner@test.local');
do $$ declare j jsonb; begin
 j := fn_review_mark('{"outcome":"objection","note":"objection note","ids":["1c100000-0000-0000-0000-000000000001","1c100000-0000-0000-0000-000000000002","1c100000-0000-0000-0000-000000000003"]}'::jsonb);
 perform xg_record('RP01 owner objection on three ids: own branch + same-org other branch (owner scope = every org branch, fn_user_branch_ids) = 2, foreign org excluded', (j->>'objected')::int=2, j::text);
end $$;
reset role;
select xg_record('RP02 positive control: a notification exists for the own-branch item', xg_sd('select count(*) from notifications where title like ''%RP own branch%''')=1);
select xg_record('RP03 same-org other branch IS notified for an owner (owner scope covers all branches of the org; this is the contract, not a leak)', xg_sd('select count(*) from notifications where title like ''%RP other-branch decoy%''')=1, xg_sd('select count(*) from notifications where title like ''%RP other-branch decoy%''')::text);
select xg_record('RP04 NO notification for the foreign-org decoy', xg_sd('select count(*) from notifications where title like ''%RP foreign-org decoy%''')=0, xg_sd('select count(*) from notifications where title like ''%RP foreign-org decoy%''')::text);
select xg_record('RP05 foreign-org decoy row untouched (still the old objection note)', xg_sd('select count(*) from review_items where id=''1c100000-0000-0000-0000-000000000003'' and objection_note=''old objection''')=1);
-- ---- 0120: a grouped platform check must not reach a unit of the same group in a branch the actor does not belong to ----
insert into reservations(id, organization_id, branch_id, source_id, group_ref, check_in, check_out, external_ref) values
 ('1c200000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000020','RPGRP','2027-03-01','2027-03-03','RP-A'),
 ('1c200000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001','1a910000-0000-0000-0000-000000000012','00000000-0000-0000-0000-000000000020','RPGRP','2027-03-01','2027-03-03','RP-B'),
 ('1c200000-0000-0000-0000-000000000003','1f900000-0000-0000-0000-000000000002','1f900000-0000-0000-0000-000000000012','1f900000-0000-0000-0000-000000000022','RPGRP','2027-03-01','2027-03-03','RP-C');
select xg_record('RP10 fixtures: one group_ref across own branch, other branch of the same org, and a foreign org', xg_sd('select count(*) from reservations where group_ref=''RPGRP''')=3);
set role authenticated;
select xg_login('cc000000-0000-0000-0000-000000000002','rpmgr@test.local');
do $$ declare j jsonb; begin
 j := fn_platform_mark_checked('{"reservation_id":"1c200000-0000-0000-0000-000000000001","checked":true}'::jsonb);
 perform xg_record('RP11 manager of branch 10 marks the group: exactly 1 unit updated', (j->>'units')::int=1, j::text);
end $$;
reset role;
select xg_record('RP12 positive control: the own-branch unit is verified', xg_sd('select count(*) from reservations where id=''1c200000-0000-0000-0000-000000000001'' and platform_verified_at is not null')=1);
select xg_record('RP13 same-org other-branch unit of the group is NOT verified', xg_sd('select count(*) from reservations where id=''1c200000-0000-0000-0000-000000000002'' and platform_verified_at is not null')=0);
select xg_record('RP14 foreign-org unit of the group is NOT verified', xg_sd('select count(*) from reservations where id=''1c200000-0000-0000-0000-000000000003'' and platform_verified_at is not null')=0);
select res, name, detail from (select case when ok then 'PASS' else 'FAIL' end as res, name, detail from test_results) q order by res desc, name;
select count(*) filter (where ok) pass, count(*) filter (where not ok) fail from test_results;
rollback;
