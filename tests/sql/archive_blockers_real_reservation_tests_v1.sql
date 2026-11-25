-- UNRUN. Archive/restore = entity page Edit. Run on migrations through 0129 (helpers) in TWO ways: baseline (candidate not applied) and with archive_edit_candidate_UNRUN.sql.
-- Expected on baseline: every individual non-owner positive (A1, A2, A3, R1) RED (cap 'definitions' denies them), all other cells identical. Fail-loud: exit 3 on any RED.
-- Self-contained synthetic tenant, rolled back. Denial credit only as 42501 with the positive control in the same fixture and zero effect.
\set ON_ERROR_STOP on
begin;
insert into organizations(id,name_ar) values('fb000000-0000-4000-8000-000000000001','AR tenant');
insert into branches(id,organization_id,name_ar) values('fb010000-0000-4000-8000-000000000001','fb000000-0000-4000-8000-000000000001','AR branch 1'),('fb010000-0000-4000-8000-000000000002','fb000000-0000-4000-8000-000000000001','AR branch 2');
insert into staff_profiles(id,auth_user_id,organization_id,full_name,email,role) values
('fb100000-0000-4000-8000-000000000001','fb200000-0000-4000-8000-000000000001','fb000000-0000-4000-8000-000000000001','Owner','ar-owner@example.test','owner'),
('fb100000-0000-4000-8000-000000000002','fb200000-0000-4000-8000-000000000002','fb000000-0000-4000-8000-000000000001','Ind edit','ar-i1@example.test','supervisor'),
('fb100000-0000-4000-8000-000000000003','fb200000-0000-4000-8000-000000000003','fb000000-0000-4000-8000-000000000001','Ind view only','ar-i2@example.test','supervisor'),
('fb100000-0000-4000-8000-000000000004','fb200000-0000-4000-8000-000000000004','fb000000-0000-4000-8000-000000000001','Ind view+delete','ar-i3@example.test','supervisor'),
('fb100000-0000-4000-8000-000000000005','fb200000-0000-4000-8000-000000000005','fb000000-0000-4000-8000-000000000001','Ind edit wrong pages','ar-i4@example.test','supervisor'),
('fb100000-0000-4000-8000-000000000006','fb200000-0000-4000-8000-000000000006','fb000000-0000-4000-8000-000000000001','Ind manager branch edit','ar-i5@example.test','manager'),
('fb100000-0000-4000-8000-000000000007','fb200000-0000-4000-8000-000000000007','fb000000-0000-4000-8000-000000000001','Legacy manager','ar-m@example.test','manager'),
('fb100000-0000-4000-8000-000000000008','fb200000-0000-4000-8000-000000000008','fb000000-0000-4000-8000-000000000001','Legacy supervisor','ar-s@example.test','supervisor'),
('fb100000-0000-4000-8000-000000000009','fb200000-0000-4000-8000-000000000009','fb000000-0000-4000-8000-000000000001','Individual-mode owner','ar-io@example.test','owner');
insert into branch_memberships(staff_id,branch_id)
 select s, b from (values ('fb100000-0000-4000-8000-000000000002'::uuid),('fb100000-0000-4000-8000-000000000003'),('fb100000-0000-4000-8000-000000000004'),('fb100000-0000-4000-8000-000000000005'),('fb100000-0000-4000-8000-000000000006'),('fb100000-0000-4000-8000-000000000007'),('fb100000-0000-4000-8000-000000000008')) a(s)
 cross join (values ('fb010000-0000-4000-8000-000000000001'::uuid)) c(b);
insert into staff_page_access(staff_id,organization_id,enabled,page_grants) values
('fb100000-0000-4000-8000-000000000002','fb000000-0000-4000-8000-000000000001',true,'{"/admin/structure":{"view":true,"edit":true},"/admin/rooms":{"view":true,"edit":true},"/admin/room-categories":{"view":true,"edit":true}}'),
('fb100000-0000-4000-8000-000000000003','fb000000-0000-4000-8000-000000000001',true,'{"/admin/structure":{"view":true},"/admin/rooms":{"view":true},"/admin/room-categories":{"view":true}}'),
('fb100000-0000-4000-8000-000000000004','fb000000-0000-4000-8000-000000000001',true,'{"/admin/structure":{"view":true,"delete":true},"/admin/rooms":{"view":true,"delete":true},"/admin/room-categories":{"view":true,"delete":true}}'),
('fb100000-0000-4000-8000-000000000005','fb000000-0000-4000-8000-000000000001',true,'{"/admin/services":{"view":true,"edit":true},"/admin/facilities":{"view":true,"edit":true}}'),
('fb100000-0000-4000-8000-000000000006','fb000000-0000-4000-8000-000000000001',true,'{"/admin/branches":{"view":true,"edit":true,"delete":true}}'),
('fb100000-0000-4000-8000-000000000009','fb000000-0000-4000-8000-000000000001',true,'{}');
-- definitions to archive: three blocks (A1, control for denials, R1), a category + two rooms
insert into blocks(id,organization_id,branch_id,name,sort_order) values
('fb300000-0000-4000-8000-000000000001','fb000000-0000-4000-8000-000000000001','fb010000-0000-4000-8000-000000000001','AR block edit',1),
('fb300000-0000-4000-8000-000000000002','fb000000-0000-4000-8000-000000000001','fb010000-0000-4000-8000-000000000001','AR block denied',2),
('fb300000-0000-4000-8000-000000000003','fb000000-0000-4000-8000-000000000001','fb010000-0000-4000-8000-000000000001','AR block legacy',3);
insert into staff_profiles(id,auth_user_id,organization_id,full_name,email,role) values
('fb100000-0000-4000-8000-000000000010','fb200000-0000-4000-8000-000000000010','fb000000-0000-4000-8000-000000000001','Ind edit all 6 pages','ar-i10@example.test','supervisor'),
('fb100000-0000-4000-8000-000000000011','fb200000-0000-4000-8000-000000000011','fb000000-0000-4000-8000-000000000001','Ind delete-only all 6 pages','ar-i11@example.test','supervisor');
insert into branch_memberships(staff_id,branch_id) values ('fb100000-0000-4000-8000-000000000010','fb010000-0000-4000-8000-000000000001'),('fb100000-0000-4000-8000-000000000011','fb010000-0000-4000-8000-000000000001');
insert into staff_page_access(staff_id,organization_id,enabled,page_grants) values
('fb100000-0000-4000-8000-000000000010','fb000000-0000-4000-8000-000000000001',true,'{"/admin/structure":{"view":true,"edit":true},"/admin/rooms":{"view":true,"edit":true},"/admin/room-categories":{"view":true,"edit":true},"/admin/facilities":{"view":true,"edit":true},"/admin/services":{"view":true,"edit":true},"/admin/task-types":{"view":true,"edit":true}}'),
('fb100000-0000-4000-8000-000000000011','fb000000-0000-4000-8000-000000000001',true,'{"/admin/structure":{"view":true,"delete":true},"/admin/rooms":{"view":true,"delete":true},"/admin/room-categories":{"view":true,"delete":true},"/admin/facilities":{"view":true,"delete":true},"/admin/services":{"view":true,"delete":true},"/admin/task-types":{"view":true,"delete":true}}');
-- one row of each other type (deliberately none for the denial user to touch twice: separate rows for the edit user and the delete-only user)
insert into floors(id,organization_id,branch_id,block_id,name) values ('fb400000-0000-4000-8000-000000000001','fb000000-0000-4000-8000-000000000001','fb010000-0000-4000-8000-000000000001','fb300000-0000-4000-8000-000000000002','AR floor e'),('fb400000-0000-4000-8000-000000000002','fb000000-0000-4000-8000-000000000001','fb010000-0000-4000-8000-000000000001','fb300000-0000-4000-8000-000000000002','AR floor d');
insert into room_categories(id,branch_id,organization_id,name_ar) values ('fb500000-0000-4000-8000-000000000001','fb010000-0000-4000-8000-000000000001','fb000000-0000-4000-8000-000000000001','AR cat e'),('fb500000-0000-4000-8000-000000000002','fb010000-0000-4000-8000-000000000001','fb000000-0000-4000-8000-000000000001','AR cat d'),('fb500000-0000-4000-8000-000000000003','fb010000-0000-4000-8000-000000000001','fb000000-0000-4000-8000-000000000001','AR cat host');
insert into rooms(id,branch_id,organization_id,category_id,room_number) values ('fb600000-0000-4000-8000-000000000001','fb010000-0000-4000-8000-000000000001','fb000000-0000-4000-8000-000000000001','fb500000-0000-4000-8000-000000000003','AR-1'),('fb600000-0000-4000-8000-000000000002','fb010000-0000-4000-8000-000000000001','fb000000-0000-4000-8000-000000000001','fb500000-0000-4000-8000-000000000003','AR-2');
insert into facilities(id,organization_id,branch_id,name) values ('fb700000-0000-4000-8000-000000000001','fb000000-0000-4000-8000-000000000001','fb010000-0000-4000-8000-000000000001','AR fac e'),('fb700000-0000-4000-8000-000000000002','fb000000-0000-4000-8000-000000000001','fb010000-0000-4000-8000-000000000001','AR fac d');
insert into service_definitions(id,organization_id,branch_id,name_ar) values ('fb800000-0000-4000-8000-000000000001','fb000000-0000-4000-8000-000000000001','fb010000-0000-4000-8000-000000000001','AR svc e'),('fb800000-0000-4000-8000-000000000002','fb000000-0000-4000-8000-000000000001','fb010000-0000-4000-8000-000000000001','AR svc d');
insert into task_types(id,organization_id,branch_id,name) values ('fb900000-0000-4000-8000-000000000001','fb000000-0000-4000-8000-000000000001','fb010000-0000-4000-8000-000000000001','AR tt e'),('fb900000-0000-4000-8000-000000000002','fb000000-0000-4000-8000-000000000001','fb010000-0000-4000-8000-000000000001','AR tt d');
insert into blocks(id,organization_id,branch_id,name,sort_order) values ('fb300000-0000-4000-8000-000000000004','fb000000-0000-4000-8000-000000000001','fb010000-0000-4000-8000-000000000001','AR block with room',4);
insert into rooms(id,branch_id,organization_id,category_id,room_number,block_id) values ('fb600000-0000-4000-8000-000000000004','fb010000-0000-4000-8000-000000000001','fb000000-0000-4000-8000-000000000001','fb500000-0000-4000-8000-000000000003','AR-4','fb300000-0000-4000-8000-000000000004');
insert into staff_profiles(id,auth_user_id,organization_id,full_name,email,role) values ('fb100000-0000-4000-8000-000000000070','fb200000-0000-4000-8000-000000000070','fb000000-0000-4000-8000-000000000001','RB editor','ar-rb70@example.test','manager');
insert into branch_memberships(staff_id,branch_id) values ('fb100000-0000-4000-8000-000000000070','fb010000-0000-4000-8000-000000000001');
insert into staff_page_access(staff_id,organization_id,enabled,page_grants,sensitive_grants) values ('fb100000-0000-4000-8000-000000000070','fb000000-0000-4000-8000-000000000001',true,'{"/admin/rooms":{"view":true,"edit":true},"/admin/room-categories":{"view":true,"edit":true}}','[]');
insert into room_categories(id,branch_id,organization_id,name_ar) values ('fb500000-0000-4000-8000-0000000000b1','fb010000-0000-4000-8000-000000000001','fb000000-0000-4000-8000-000000000001','RB cat'),('fb500000-0000-4000-8000-0000000000b2','fb010000-0000-4000-8000-000000000001','fb000000-0000-4000-8000-000000000001','RB cat2');
insert into rooms(id,branch_id,organization_id,category_id,room_number) values ('fb600000-0000-4000-8000-0000000000b1','fb010000-0000-4000-8000-000000000001','fb000000-0000-4000-8000-000000000001','fb500000-0000-4000-8000-0000000000b1','RB-1'),('fb600000-0000-4000-8000-0000000000b2','fb010000-0000-4000-8000-000000000001','fb000000-0000-4000-8000-000000000001','fb500000-0000-4000-8000-0000000000b1','RB-2'),('fb600000-0000-4000-8000-0000000000b3','fb010000-0000-4000-8000-000000000001','fb000000-0000-4000-8000-000000000001','fb500000-0000-4000-8000-0000000000b1','RB-3'),('fb600000-0000-4000-8000-0000000000b4','fb010000-0000-4000-8000-000000000001','fb000000-0000-4000-8000-000000000001','fb500000-0000-4000-8000-0000000000b1','RB-4');
insert into reservations(id,organization_id,branch_id,external_ref,check_in,check_out,status,room_category_id) values
('fb700000-0000-4000-8000-0000000000b1','fb000000-0000-4000-8000-000000000001','fb010000-0000-4000-8000-000000000001','RB-R1',current_date+1,current_date+5,'confirmed','fb500000-0000-4000-8000-0000000000b1'),
('fb700000-0000-4000-8000-0000000000b2','fb000000-0000-4000-8000-000000000001','fb010000-0000-4000-8000-000000000001','RB-R2',current_date+1,current_date+5,'cancelled','fb500000-0000-4000-8000-0000000000b1'),
('fb700000-0000-4000-8000-0000000000b3','fb000000-0000-4000-8000-000000000001','fb010000-0000-4000-8000-000000000001','RB-R3',current_date-9,current_date-5,'confirmed','fb500000-0000-4000-8000-0000000000b1'),
('fb700000-0000-4000-8000-0000000000b4','fb000000-0000-4000-8000-000000000001','fb010000-0000-4000-8000-000000000001','RB-R4',current_date+1,current_date+5,'confirmed','fb500000-0000-4000-8000-0000000000b2'),
('fb700000-0000-4000-8000-0000000000b5','fb000000-0000-4000-8000-000000000001','fb010000-0000-4000-8000-000000000001','RB-R5',current_date+1,current_date+5,'checked_in','fb500000-0000-4000-8000-0000000000b1');
insert into reservation_allocations(reservation_id,room_id,organization_id,branch_id,from_date,to_date,status) values
('fb700000-0000-4000-8000-0000000000b1','fb600000-0000-4000-8000-0000000000b1','fb000000-0000-4000-8000-000000000001','fb010000-0000-4000-8000-000000000001',current_date+1,current_date+5,'active'),
('fb700000-0000-4000-8000-0000000000b2','fb600000-0000-4000-8000-0000000000b2','fb000000-0000-4000-8000-000000000001','fb010000-0000-4000-8000-000000000001',current_date+1,current_date+5,'active'),
('fb700000-0000-4000-8000-0000000000b3','fb600000-0000-4000-8000-0000000000b3','fb000000-0000-4000-8000-000000000001','fb010000-0000-4000-8000-000000000001',current_date-9,current_date-5,'active'),
('fb700000-0000-4000-8000-0000000000b5','fb600000-0000-4000-8000-0000000000b4','fb000000-0000-4000-8000-000000000001','fb010000-0000-4000-8000-000000000001',current_date+1,current_date+5,'active');
create temp table res(name text primary key, ok boolean not null, detail text);
grant all on res to authenticated;
create function pg_temp.login(uid text) returns void language sql as $$select set_config('request.jwt.claim.sub',uid,false)::text::void$$;
create function pg_temp.att(uid text, q text) returns text language plpgsql as $$
begin perform pg_temp.login(uid); execute q; return 'ok'; exception when others then return sqlstate; end $$;
create function pg_temp.q(s text) returns text language plpgsql security definer as $$ declare r text; begin execute s into r; return r; end $$;
grant execute on function pg_temp.att(text,text), pg_temp.q(text) to authenticated;
create function pg_temp.cap(uid text) returns boolean language plpgsql as $$ begin perform pg_temp.login(uid); return fn_can('definitions'); end $$;
grant execute on function pg_temp.cap(text) to authenticated;
create function pg_temp.u(n int) returns text language sql as $$select 'fb200000-0000-4000-8000-00000000000'||n$$;
create function pg_temp.arch(ent text, id text, a boolean) returns text language sql as $$ select format('select fn_admin_archive_definition(%L,%L::uuid,%L,%L::boolean)', ent, id, 'ar-test', a::text) $$;
create function pg_temp.capc(uid text, code text) returns boolean language plpgsql as $$ begin perform pg_temp.login(uid); return fn_can(code); end $$;
grant execute on function pg_temp.capc(text,text) to authenticated;
create function pg_temp.attm(uid text, q text) returns text language plpgsql as $$ begin perform pg_temp.login(uid); execute q; return 'ok'; exception when others then return sqlstate||'|'||sqlerrm; end $$;
grant execute on function pg_temp.attm(text,text) to authenticated;
set role authenticated;
do $$ declare r text; begin
 r := pg_temp.attm('fb200000-0000-4000-8000-000000000070', format('select fn_admin_archive_definition(%L,%L::uuid,%L,true)','room','fb600000-0000-4000-8000-0000000000b1','rb-test'));
 insert into res values($n$RB1 Edit user: room with an active allocation on a confirmed future reservation refused P0001 HAS_OPEN_COMMITMENTS, room untouched$n$, r like 'P0001|HAS_OPEN_COMMITMENTS: 1%' and pg_temp.q('select (archived_at is null)::text from rooms where id=''fb600000-0000-4000-8000-0000000000b1''')='true', r);
 r := pg_temp.attm('fb200000-0000-4000-8000-000000000070', format('select fn_admin_archive_definition(%L,%L::uuid,%L,true)','room','fb600000-0000-4000-8000-0000000000b4','rb-test'));
 insert into res values($n$RB2 Edit user: room allocated to a checked-in future-dated reservation refused HAS_OPEN_COMMITMENTS, untouched$n$, r like 'P0001|HAS_OPEN_COMMITMENTS: 1%' and pg_temp.q('select (archived_at is null)::text from rooms where id=''fb600000-0000-4000-8000-0000000000b4''')='true', r);
 r := pg_temp.attm('fb200000-0000-4000-8000-000000000070', format('select fn_admin_archive_definition(%L,%L::uuid,%L,true)','room','fb600000-0000-4000-8000-0000000000b2','rb-test'));
 insert into res values($n$RB3 control: room whose only reservation is cancelled archives ok (the blocker is what refused RB1)$n$, r='ok' and pg_temp.q('select (archived_at is null)::text from rooms where id=''fb600000-0000-4000-8000-0000000000b2''')='false', r);
 r := pg_temp.attm('fb200000-0000-4000-8000-000000000070', format('select fn_admin_archive_definition(%L,%L::uuid,%L,true)','room','fb600000-0000-4000-8000-0000000000b3','rb-test'));
 insert into res values($n$RB4 control: room whose confirmed reservation already ended archives ok$n$, r='ok' and pg_temp.q('select (archived_at is null)::text from rooms where id=''fb600000-0000-4000-8000-0000000000b3''')='false', r);
 r := pg_temp.attm('fb200000-0000-4000-8000-000000000070', format('select fn_admin_archive_definition(%L,%L::uuid,%L,true)','room_category','fb500000-0000-4000-8000-0000000000b2','rb-test'));
 insert into res values($n$RB5 Edit user: room type with a confirmed future reservation and no active rooms refused HAS_OPEN_COMMITMENTS, type untouched$n$, r like 'P0001|HAS_OPEN_COMMITMENTS: 1%' and pg_temp.q('select (archived_at is null)::text from room_categories where id=''fb500000-0000-4000-8000-0000000000b2''')='true', r);
 r := pg_temp.attm('fb200000-0000-4000-8000-000000000070', format('select fn_admin_archive_definition(%L,%L::uuid,%L,false)','room','fb600000-0000-4000-8000-0000000000b1','rb-test'));
 insert into res values($n$RB6 restore of a never-archived room is not blocked (ok) and the reservation allocation is unchanged$n$, r='ok' and pg_temp.q('select count(*)::text from reservation_allocations where room_id=''fb600000-0000-4000-8000-0000000000b1'' and status=''active''')='1', r);
end $$;
reset role;
table res;
do $$ begin if (select count(*) from res) <> 6 or exists(select 1 from res where not ok) then raise exception 'REAL RESERVATION BLOCKER TESTS: % RED of % cells', (select count(*) from res where not ok), (select count(*) from res); end if; end $$;
rollback;
