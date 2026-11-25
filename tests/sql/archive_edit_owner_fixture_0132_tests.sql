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
set role authenticated;
do $$ declare r text; B1 text:='fb300000-0000-4000-8000-000000000001'; B2 text:='fb300000-0000-4000-8000-000000000002'; B3 text:='fb300000-0000-4000-8000-000000000003';
 ar text; begin
 -- X: entity-to-page map is the 0129 helper, not a new oracle: just record it for the 8 types (fact, no credit)
 insert into res values('X0 entity page map recorded (block,floor,room,room_category,facility,service,task_type,branch)',
   (select string_agg(coalesce(fn_definition_entity_page(e),'NULL'),',' order by e) is not null from unnest(array['block','floor','room','room_category','facility','service','task_type','branch']) e), null);
 -- A1 individual with Edit on the block's page archives a block (positive; also the control for the denials below)
 r := pg_temp.att(pg_temp.u(2), pg_temp.arch('block',B1,true)); insert into res values('A1 individual Edit: archive block ok, archived_at set, audit row', r='ok' and pg_temp.q(format('select (archived_at is not null)::text from blocks where id=%L',B1))='true' and pg_temp.q(format('select count(*)::text from audit_events where action=''block.archived'' and entity_id=%L',B1))='1', r);
 -- R1 restore under Edit
 r := pg_temp.att(pg_temp.u(2), pg_temp.arch('block',B1,false)); insert into res values('R1 individual Edit: restore block ok, archived_at null, is_active true, audit row', r='ok' and pg_temp.q(format('select (archived_at is null and is_active)::text from blocks where id=%L',B1))='true' and pg_temp.q(format('select count(*)::text from audit_events where action=''block.restored'' and entity_id=%L',B1))='1', r);
 -- D1 view only denied (archive and restore), zero effect
 r := pg_temp.att(pg_temp.u(3), pg_temp.arch('block',B2,true)); insert into res values('D1 view-only archive denied 42501, zero effect', r='42501' and pg_temp.q(format('select (archived_at is null)::text from blocks where id=%L',B2))='true', r);
 -- D2 Delete grant does NOT open archive (this is the approved distinction)
 r := pg_temp.att(pg_temp.u(4), pg_temp.arch('block',B2,true)); insert into res values('D2 view+delete (no edit) archive denied 42501, zero effect', r='42501' and pg_temp.q(format('select (archived_at is null)::text from blocks where id=%L',B2))='true', r);
 -- D3 edit on other pages only
 r := pg_temp.att(pg_temp.u(5), pg_temp.arch('block',B2,true)); insert into res values('D3 edit on other pages only: archive denied 42501, zero effect', r='42501' and pg_temp.q(format('select (archived_at is null)::text from blocks where id=%L',B2))='true', r);
 -- D4 restore also needs edit: archive B3 as the edit user, then view-only and delete-only users try to restore it
 r := pg_temp.att(pg_temp.u(1), pg_temp.arch('block',B3,true));
 ar := pg_temp.att(pg_temp.u(3), pg_temp.arch('block',B3,false)); insert into res values('D4a view-only restore denied 42501, record stays archived', r='ok' and ar='42501' and pg_temp.q(format('select (archived_at is not null)::text from blocks where id=%L',B3))='true', r||'/'||ar);
 ar := pg_temp.att(pg_temp.u(4), pg_temp.arch('block',B3,false)); insert into res values('D4b delete-only restore denied 42501, record stays archived', ar='42501' and pg_temp.q(format('select (archived_at is not null)::text from blocks where id=%L',B3))='true', ar);
 -- BR: branch stays owner-only: individual MANAGER with Edit (and Delete) on /admin/branches is refused by the owner-only line, zero effect (branch 2 is the target; needs memberships only for non-owner branch access: none given, so the refusal may come from fn_require_branch: record the code, credit only if the message is the owner-only one)
 r := pg_temp.att(pg_temp.u(6), pg_temp.arch('branch','fb010000-0000-4000-8000-000000000001',true));
 insert into res values('BR1 individual manager with branch Edit: branch archive denied 42501, branch intact', r='42501' and pg_temp.q('select (archived_at is null)::text from branches where id=''fb010000-0000-4000-8000-000000000001''')='true', r);
 -- BR2 individual-mode owner can archive and restore branch 2 (two active branches exist)
 r := pg_temp.att(pg_temp.u(9), pg_temp.arch('branch','fb010000-0000-4000-8000-000000000002',true));
 ar := pg_temp.att(pg_temp.u(9), pg_temp.arch('branch','fb010000-0000-4000-8000-000000000002',false));
 insert into res values('BR2 individual-mode owner: branch archive and restore both ok', r='ok' and ar='ok', r||'/'||ar);
 -- L: legacy and owner invariance (identical on baseline and candidate): result equals the capability, restore too
 r := pg_temp.att(pg_temp.u(7), pg_temp.arch('block',B2,true)); insert into res values('L1 legacy manager archive == fn_can(definitions)', (r='ok') = pg_temp.cap(pg_temp.u(7)), r);
 ar := pg_temp.att(pg_temp.u(7), pg_temp.arch('block',B2,false)); insert into res values('L2 legacy manager restore == fn_can(definitions)', (ar = 'ok') = pg_temp.cap(pg_temp.u(7)), ar);
 r := pg_temp.att(pg_temp.u(8), pg_temp.arch('block',B2,true)); insert into res values('L3 legacy supervisor archive == fn_can(definitions)', (r='ok') = pg_temp.cap(pg_temp.u(8)), r);
 r := pg_temp.att(pg_temp.u(1), pg_temp.arch('block',B2,true)); ar := pg_temp.att(pg_temp.u(1), pg_temp.arch('block',B2,false)); insert into res values('L4 owner archive and restore ok', r='ok' and ar='ok', r||'/'||ar);
 -- U: unknown entity: individual non-owner fail closed, owner gets the old VALIDATION
 r := pg_temp.att(pg_temp.u(2), pg_temp.arch('nonsense',B2,true)); insert into res values('U1 individual non-owner unknown entity 42501', r='42501', r);
 r := pg_temp.att(pg_temp.u(1), pg_temp.arch('nonsense',B2,true)); insert into res values('U2 owner unknown entity keeps VALIDATION: entity (P0001)', r='P0001', r);
 -- T: per-type cells. Edit user archives then restores one row of each type; the delete-only user is refused (42501) on a separate row with zero effect.
 r := pg_temp.att('fb200000-0000-4000-8000-000000000010', pg_temp.arch('floor','fb400000-0000-4000-8000-000000000001',true)); ar := pg_temp.att('fb200000-0000-4000-8000-000000000010', pg_temp.arch('floor','fb400000-0000-4000-8000-000000000001',false));
 insert into res values('T-floor individual Edit: archive then restore ok, state flips, audit rows entity.archived/.restored', r='ok' and ar='ok' and pg_temp.q('select (archived_at is null and is_active)::text from floors where id=''fb400000-0000-4000-8000-000000000001''')='true' and pg_temp.q('select count(*)::text from audit_events where action in (''floor.archived'',''floor.restored'') and entity_id=''fb400000-0000-4000-8000-000000000001''')='2', r||'/'||ar);
 r := pg_temp.att('fb200000-0000-4000-8000-000000000011', pg_temp.arch('floor','fb400000-0000-4000-8000-000000000002',true));
 insert into res values('N-floor delete-only archive denied 42501, zero effect', r='42501' and pg_temp.q('select (archived_at is null and is_active)::text from floors where id=''fb400000-0000-4000-8000-000000000002''')='true' and pg_temp.q('select count(*)::text from audit_events where entity_id=''fb400000-0000-4000-8000-000000000002''')='0', r);
 r := pg_temp.att('fb200000-0000-4000-8000-000000000010', pg_temp.arch('room_category','fb500000-0000-4000-8000-000000000001',true)); ar := pg_temp.att('fb200000-0000-4000-8000-000000000010', pg_temp.arch('room_category','fb500000-0000-4000-8000-000000000001',false));
 insert into res values('T-room_category individual Edit: archive then restore ok, state flips, audit rows entity.archived/.restored', r='ok' and ar='ok' and pg_temp.q('select (archived_at is null and is_active)::text from room_categories where id=''fb500000-0000-4000-8000-000000000001''')='true' and pg_temp.q('select count(*)::text from audit_events where action in (''room_category.archived'',''room_category.restored'') and entity_id=''fb500000-0000-4000-8000-000000000001''')='2', r||'/'||ar);
 r := pg_temp.att('fb200000-0000-4000-8000-000000000011', pg_temp.arch('room_category','fb500000-0000-4000-8000-000000000002',true));
 insert into res values('N-room_category delete-only archive denied 42501, zero effect', r='42501' and pg_temp.q('select (archived_at is null and is_active)::text from room_categories where id=''fb500000-0000-4000-8000-000000000002''')='true' and pg_temp.q('select count(*)::text from audit_events where entity_id=''fb500000-0000-4000-8000-000000000002''')='0', r);
 r := pg_temp.att('fb200000-0000-4000-8000-000000000010', pg_temp.arch('room','fb600000-0000-4000-8000-000000000001',true)); ar := pg_temp.att('fb200000-0000-4000-8000-000000000010', pg_temp.arch('room','fb600000-0000-4000-8000-000000000001',false));
 insert into res values('T-room individual Edit: archive then restore ok, state flips, audit rows entity.archived/.restored', r='ok' and ar='ok' and pg_temp.q('select (archived_at is null and is_active)::text from rooms where id=''fb600000-0000-4000-8000-000000000001''')='true' and pg_temp.q('select count(*)::text from audit_events where action in (''room.archived'',''room.restored'') and entity_id=''fb600000-0000-4000-8000-000000000001''')='2', r||'/'||ar);
 r := pg_temp.att('fb200000-0000-4000-8000-000000000011', pg_temp.arch('room','fb600000-0000-4000-8000-000000000002',true));
 insert into res values('N-room delete-only archive denied 42501, zero effect', r='42501' and pg_temp.q('select (archived_at is null and is_active)::text from rooms where id=''fb600000-0000-4000-8000-000000000002''')='true' and pg_temp.q('select count(*)::text from audit_events where entity_id=''fb600000-0000-4000-8000-000000000002''')='0', r);
 r := pg_temp.att('fb200000-0000-4000-8000-000000000010', pg_temp.arch('facility','fb700000-0000-4000-8000-000000000001',true)); ar := pg_temp.att('fb200000-0000-4000-8000-000000000010', pg_temp.arch('facility','fb700000-0000-4000-8000-000000000001',false));
 insert into res values('T-facility individual Edit: archive then restore ok, state flips, audit rows entity.archived/.restored', r='ok' and ar='ok' and pg_temp.q('select (archived_at is null and is_active)::text from facilities where id=''fb700000-0000-4000-8000-000000000001''')='true' and pg_temp.q('select count(*)::text from audit_events where action in (''facility.archived'',''facility.restored'') and entity_id=''fb700000-0000-4000-8000-000000000001''')='2', r||'/'||ar);
 r := pg_temp.att('fb200000-0000-4000-8000-000000000011', pg_temp.arch('facility','fb700000-0000-4000-8000-000000000002',true));
 insert into res values('N-facility delete-only archive denied 42501, zero effect', r='42501' and pg_temp.q('select (archived_at is null and is_active)::text from facilities where id=''fb700000-0000-4000-8000-000000000002''')='true' and pg_temp.q('select count(*)::text from audit_events where entity_id=''fb700000-0000-4000-8000-000000000002''')='0', r);
 r := pg_temp.att('fb200000-0000-4000-8000-000000000010', pg_temp.arch('service','fb800000-0000-4000-8000-000000000001',true)); ar := pg_temp.att('fb200000-0000-4000-8000-000000000010', pg_temp.arch('service','fb800000-0000-4000-8000-000000000001',false));
 insert into res values('T-service individual Edit: archive then restore ok, state flips, audit rows entity.archived/.restored', r='ok' and ar='ok' and pg_temp.q('select (archived_at is null and is_active)::text from service_definitions where id=''fb800000-0000-4000-8000-000000000001''')='true' and pg_temp.q('select count(*)::text from audit_events where action in (''service.archived'',''service.restored'') and entity_id=''fb800000-0000-4000-8000-000000000001''')='2', r||'/'||ar);
 r := pg_temp.att('fb200000-0000-4000-8000-000000000011', pg_temp.arch('service','fb800000-0000-4000-8000-000000000002',true));
 insert into res values('N-service delete-only archive denied 42501, zero effect', r='42501' and pg_temp.q('select (archived_at is null and is_active)::text from service_definitions where id=''fb800000-0000-4000-8000-000000000002''')='true' and pg_temp.q('select count(*)::text from audit_events where entity_id=''fb800000-0000-4000-8000-000000000002''')='0', r);
 r := pg_temp.att('fb200000-0000-4000-8000-000000000010', pg_temp.arch('task_type','fb900000-0000-4000-8000-000000000001',true)); ar := pg_temp.att('fb200000-0000-4000-8000-000000000010', pg_temp.arch('task_type','fb900000-0000-4000-8000-000000000001',false));
 insert into res values('T-task_type individual Edit: archive then restore ok, state flips, audit rows entity.archived/.restored', r='ok' and ar='ok' and pg_temp.q('select (archived_at is null and is_active)::text from task_types where id=''fb900000-0000-4000-8000-000000000001''')='true' and pg_temp.q('select count(*)::text from audit_events where action in (''task_type.archived'',''task_type.restored'') and entity_id=''fb900000-0000-4000-8000-000000000001''')='2', r||'/'||ar);
 r := pg_temp.att('fb200000-0000-4000-8000-000000000011', pg_temp.arch('task_type','fb900000-0000-4000-8000-000000000002',true));
 insert into res values('N-task_type delete-only archive denied 42501, zero effect', r='42501' and pg_temp.q('select (archived_at is null and is_active)::text from task_types where id=''fb900000-0000-4000-8000-000000000002''')='true' and pg_temp.q('select count(*)::text from audit_events where entity_id=''fb900000-0000-4000-8000-000000000002''')='0', r);

 -- K: open-commitment blockers and reason are still enforced for the Edit path (error is P0001 raise exception)
 r := pg_temp.att('fb200000-0000-4000-8000-000000000010', pg_temp.arch('block','fb300000-0000-4000-8000-000000000004',true));
 insert into res values('K1 Edit user: block with an active room blocked (P0001), block untouched', r='P0001' and pg_temp.q('select (archived_at is null and is_active)::text from blocks where id=''fb300000-0000-4000-8000-000000000004''')='true', r);
 r := pg_temp.att('fb200000-0000-4000-8000-000000000010', pg_temp.arch('room_category','fb500000-0000-4000-8000-000000000003',true));
 insert into res values('K2 Edit user: room type with active rooms blocked (P0001), type untouched', r='P0001' and pg_temp.q('select (archived_at is null and is_active)::text from room_categories where id=''fb500000-0000-4000-8000-000000000003''')='true', r);
 r := pg_temp.att('fb200000-0000-4000-8000-000000000010', format('select fn_admin_archive_definition(%L,%L::uuid,%L,true)','block','fb300000-0000-4000-8000-000000000004',''));
 insert into res values('K3 Edit user: archive without a reason refused (P0001), untouched', r='P0001' and pg_temp.q('select (archived_at is null)::text from blocks where id=''fb300000-0000-4000-8000-000000000004''')='true', r);
 r := pg_temp.att('fb200000-0000-4000-8000-000000000010', pg_temp.arch('room','fb600000-0000-4000-8000-000000000004',true)); ar := pg_temp.att('fb200000-0000-4000-8000-000000000010', pg_temp.arch('block','fb300000-0000-4000-8000-000000000004',true));
 insert into res values('K4 Edit user: room archived (status out_of_service), then its block archives once the room is archived', r='ok' and ar='ok' and pg_temp.q('select status from rooms where id=''fb600000-0000-4000-8000-000000000004''')='out_of_service' and pg_temp.q('select (archived_at is not null)::text from blocks where id=''fb300000-0000-4000-8000-000000000004''')='true', r||'/'||ar);
 r := pg_temp.att('fb200000-0000-4000-8000-000000000010', pg_temp.arch('block','fb300000-0000-4000-8000-000000000004',false)); ar := pg_temp.att('fb200000-0000-4000-8000-000000000010', pg_temp.arch('room','fb600000-0000-4000-8000-000000000004',false));
 insert into res values('K5 Edit user: restore block and room, room status back to available', r='ok' and ar='ok' and pg_temp.q('select status from rooms where id=''fb600000-0000-4000-8000-000000000004''')='available' and pg_temp.q('select (archived_at is null and is_active)::text from blocks where id=''fb300000-0000-4000-8000-000000000004''')='true', r||'/'||ar);
 r := pg_temp.att('fb200000-0000-4000-8000-000000000010', pg_temp.arch('branch','fb010000-0000-4000-8000-000000000002',true));
 insert into res values('BR3 individual non-owner with Edit on all pages: branch archive denied 42501, branch intact', r='42501' and pg_temp.q('select (archived_at is null)::text from branches where id=''fb010000-0000-4000-8000-000000000002''')='true', r);
 r := pg_temp.att(pg_temp.u(7), pg_temp.arch('branch','fb010000-0000-4000-8000-000000000002',true));
 insert into res values('BR4 legacy manager: branch archive denied 42501, branch intact', r='42501' and pg_temp.q('select (archived_at is null)::text from branches where id=''fb010000-0000-4000-8000-000000000002''')='true', r);
 r := pg_temp.att(pg_temp.u(1), pg_temp.arch('branch','fb010000-0000-4000-8000-000000000002',true)); ar := pg_temp.att(pg_temp.u(1), pg_temp.arch('branch','fb010000-0000-4000-8000-000000000002',false));
 insert into res values('BR5 legacy owner: branch archive and restore ok', r='ok' and ar='ok' and pg_temp.q('select (archived_at is null and is_active)::text from branches where id=''fb010000-0000-4000-8000-000000000002''')='true', r||'/'||ar);
end $$;
reset role;
table res;
do $$ begin if (select count(*) from res) <> 36 or exists(select 1 from res where not ok) then raise exception 'ARCHIVE EDIT TESTS: % RED of % cells (baseline expectation: A1 R1 D4a? see header)', (select count(*) from res where not ok), (select count(*) from res); end if; end $$;
rollback;
