-- Item 7.1 (O4/T6): the recorded backup state is enforced in the database, not the screen.
-- The backup tooling (service_role) writes runs; the owner alone reads the status; every other role is refused.
\set ON_ERROR_STOP on
begin;
create temp table test_results(name text, ok boolean, detail text);
do $$
declare a uuid:='92000000-0000-0000-0000-000000000001'; b uuid:='92000000-0000-0000-0000-000000000002';
        u_owner uuid:='92000000-0000-0000-0000-000000000003'; u_mgr uuid:='92000000-0000-0000-0000-000000000004';
        run uuid; run2 uuid; blocked boolean; role_name role_code; v_status jsonb;
begin
 insert into organizations(id,name_ar) values(a,'فندق النسخ الاحتياطي'),(b,'فندق آخر للنسخ');
 insert into staff_profiles(auth_user_id,organization_id,full_name,email,role) values
   (u_owner,a,'مالك النسخ','backup-owner@example.test','owner'),
   (u_mgr,a,'مدير النسخ','backup-manager@example.test','manager');

 -- BK-01: the tooling (service_role) opens and closes a successful backup run with its evidence
 execute 'set local role service_role';
 run := fn_backup_run_start('backup','scheduled','backup-20261124-090000.tar.gpg',a);
 perform fn_backup_run_finish(run,'success',1048576,lpad('a',64,'a'),100,42311,'manifest-hashes+restore-counts');
 run2 := fn_backup_run_start('restore_drill','drill','drill-2026-11',a);
 perform fn_backup_run_finish(run2,'success',null,null,null,null,'restore:counts+hashes identical');
 execute 'reset role';
 insert into test_results select 'BK-01 service tooling records a verified run',
   status='success' and tables_count=100 and rows_total=42311 and finished_at is not null, null
   from backup_runs where id=run;

 -- BK-02: a success without its verification is refused
 execute 'set local role service_role';
 run := fn_backup_run_start('backup','manual','backup-no-verification.tar.gpg',a);
 begin perform fn_backup_run_finish(run,'success',1,lpad('b',64,'b')); blocked:=false; exception when others then blocked:=true; end;
 execute 'reset role';
 insert into test_results values('BK-02 success without verification refused',blocked,null);

 -- BK-03: the owner reads «آخر نسخة» from the recorded state
 perform set_config('request.jwt.claim.sub',u_owner::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',u_owner,'role','authenticated')::text,true);
 execute 'set local role authenticated';
 v_status := fn_backup_status();
 execute 'reset role';
 insert into test_results values('BK-03 owner sees the last successful backup',
   v_status->'last_success'->>'run_ref'='backup-20261124-090000.tar.gpg'
   and (v_status->'last_success'->>'tables_count')::int=100
   and v_status->'last_restore_drill'->>'status'='success'
   and (v_status->>'failures_since_last_success')::int=0, v_status::text);

 -- BK-04: a manager is refused by the server
 perform set_config('request.jwt.claim.sub',u_mgr::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',u_mgr,'role','authenticated')::text,true);
 execute 'set local role authenticated';
 begin perform fn_backup_status(); blocked:=false; exception when insufficient_privilege then blocked:=true; end;
 execute 'reset role';
 insert into test_results values('BK-04 manager refused by server',blocked,null);

 -- BK-05: a staff session can never write a run, even calling the tooling's functions directly
 execute 'set local role authenticated';
 begin perform fn_backup_run_start('backup','manual','forged',a); blocked:=false; exception when insufficient_privilege then blocked:=true; end;
 execute 'reset role';
 insert into test_results values('BK-05 staff session cannot record a run',blocked,null);

 -- BK-06: no API role reads the table directly (RLS has no policy for anyone)
 execute 'set local role authenticated';
 begin perform 1 from backup_runs limit 1; blocked:=false; exception when insufficient_privilege then blocked:=true; end;
 execute 'reset role';
 insert into test_results values('BK-06 direct table read refused',blocked,null);

 -- BK-07: a failed run after the success is visible as a failure, with the last success still standing
 execute 'set local role service_role';
 run := fn_backup_run_start('backup','scheduled','backup-20261125-090000.tar.gpg',a);
 perform fn_backup_run_finish(run,'failed',null,null,null,null,null,'upload failed');
 execute 'reset role';
 perform set_config('request.jwt.claim.sub',u_owner::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',u_owner,'role','authenticated')::text,true);
 execute 'set local role authenticated';
 v_status := fn_backup_status();
 execute 'reset role';
 insert into test_results values('BK-07 failure surfaced, last success kept',
   v_status->'last_run'->>'status'='failed' and v_status->'last_run'->>'error'='upload failed'
   and v_status->'last_success'->>'run_ref'='backup-20261124-090000.tar.gpg'
   and (v_status->>'failures_since_last_success')::int=1, v_status::text);

 -- BK-08: a malformed archive hash is rejected by the constraint
 execute 'set local role service_role';
 run := fn_backup_run_start('backup','manual','backup-bad-hash.tar.gpg',a);
 begin perform fn_backup_run_finish(run,'success',10,'not-a-hash',0,0,'manifest-hashes'); blocked:=false;
   exception when check_violation then blocked:=true; end;
 execute 'reset role';
 insert into test_results values('BK-08 malformed sha256 rejected',blocked,null);

 -- BK-09: a run_ref carrying a path is rejected (references only, no usernames or hosts)
 execute 'set local role service_role';
 begin perform fn_backup_run_start('backup','manual','/home/someone/backup.tar.gpg',a); blocked:=false;
   exception when check_violation then blocked:=true; end;
 execute 'reset role';
 insert into test_results values('BK-09 path-shaped run_ref rejected',blocked,null);
 -- BK-10: every non-owner role is refused, and a second hotel's owner cannot see this hotel's archive.
 foreach role_name in array array['manager','supervisor','finance','housekeeping','guest']::role_code[] loop
   update staff_profiles set role=role_name where auth_user_id=u_mgr;
   perform set_config('request.jwt.claim.sub',u_mgr::text,true);
   execute 'set local role authenticated';
   begin perform fn_backup_status(); blocked:=false; exception when insufficient_privilege then blocked:=true; end;
   execute 'reset role';
   insert into test_results values('BK-10 forbidden role ' || role_name::text,blocked,null);
 end loop;
 update staff_profiles set role='owner',organization_id=b where auth_user_id=u_mgr;
 execute 'set local role authenticated';
 v_status:=fn_backup_status();
 execute 'reset role';
 insert into test_results values('BK-11 other hotel owner sees no foreign state', v_status->'last_success'='null'::jsonb and v_status->'last_run'='null'::jsonb,null);

end $$;
select case when ok then 'PASS' else 'FAIL' end as result,name,detail from test_results;
do $$begin if exists(select 1 from test_results where not coalesce(ok,false)) then raise exception 'backup state tests failed';end if;end$$;
rollback;
