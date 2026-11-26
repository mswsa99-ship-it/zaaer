-- Policies and knowledge base inherited from the hotel level (migration 0149): IN01-IN20.
-- Self-contained synthetic tenant, rolled back. Prints FAIL rows (run.sh fails the suite on any).
\set ON_ERROR_STOP off
begin;
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create or replace function in_rec(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$ insert into test_results values (p_name, coalesce(p_ok,false), p_detail); $$;
create or replace function in_login(p_uid uuid) returns void language plpgsql as $$ begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid)::text, false); end $$;
create or replace function in_masters() returns jsonb language sql security definer as $$ select fn_policy_masters_of('ac000000-0000-4000-8000-000000000001') $$;
insert into organizations(id,name_ar) values('ac000000-0000-4000-8000-000000000001','IN org'),('ac000000-0000-4000-8000-000000000002','IN other org');
insert into branches(id,organization_id,name_ar) values
 ('ac010000-0000-4000-8000-000000000001','ac000000-0000-4000-8000-000000000001','بريدة'),
 ('ac010000-0000-4000-8000-000000000002','ac000000-0000-4000-8000-000000000001','عنيزة'),
 ('ac010000-0000-4000-8000-000000000003','ac000000-0000-4000-8000-000000000002','other');
insert into staff_profiles(id,auth_user_id,organization_id,full_name,email,role) values
 ('ac100000-0000-4000-8000-000000000001','ac200000-0000-4000-8000-000000000001','ac000000-0000-4000-8000-000000000001','IN owner','in-owner@example.test','owner'),
 ('ac100000-0000-4000-8000-000000000002','ac200000-0000-4000-8000-000000000002','ac000000-0000-4000-8000-000000000001','IN supervisor','in-sup@example.test','supervisor');
insert into branch_memberships(staff_id,branch_id) values ('ac100000-0000-4000-8000-000000000001','ac010000-0000-4000-8000-000000000001'),('ac100000-0000-4000-8000-000000000001','ac010000-0000-4000-8000-000000000002'),('ac100000-0000-4000-8000-000000000002','ac010000-0000-4000-8000-000000000001');
-- Aneeza already has its own check-in text (an existing standalone policy); Buraydah has none
insert into property_policies(id,organization_id,branch_id,topic,title,content_ar,sort_order) values
 ('ac300000-0000-4000-8000-000000000002','ac000000-0000-4000-8000-000000000001','ac010000-0000-4000-8000-000000000002','checkin','الوصول','الوصول من الساعة 3:00 عصرًا',1);
grant all on all tables in schema public to authenticated;
set role authenticated;
select in_login('ac200000-0000-4000-8000-000000000001');
do $$ declare pv jsonb; ap jsonb; d jsonb; r record; n int; begin
  d := '{"topic":"checkin","title":"الوصول والمغادرة","content_ar":"الوصول من الساعة 4:00 عصرًا","is_public":true,"sort_order":1}'::jsonb;
  pv := fn_policy_master_preview(d);
  perform in_rec('IN01 preview lists both branches of this hotel only', jsonb_array_length(pv->'branches') = 2);
  perform in_rec('IN02 nothing is written by the preview', (select count(*) from property_policies where organization_id='ac000000-0000-4000-8000-000000000001') = 1 and in_masters() = '[]'::jsonb);
  perform in_rec('IN03 branch without the topic gets a copy, branch with its own text is linked and keeps it',
    (select e->>'action' from jsonb_array_elements(pv->'branches') e where e->>'branch_name'='بريدة') = 'create'
    and (select e->>'action' from jsonb_array_elements(pv->'branches') e where e->>'branch_name'='عنيزة') = 'link_existing');
  begin perform fn_policy_master_apply(d || '{"token":"x"}'::jsonb); perform in_rec('IN04 a wrong token is refused', false);
  exception when others then perform in_rec('IN04 a wrong token is refused', sqlerrm like '%PREVIEW_STALE%', sqlerrm); end;
  ap := fn_policy_master_apply((d || jsonb_build_object('id', pv->'master'->>'id', 'token', pv->>'token')));
  perform in_rec('IN05 apply creates one copy and keeps one own text', (ap->>'created')::int = 1 and (ap->>'kept_own')::int = 1, ap::text);
  perform in_rec('IN06 Aneeza text untouched, now linked with content_ar as its own field',
    (select content_ar like '%3:00%' and master_id is not null and 'content_ar' = any(override_fields) from property_policies where id='ac300000-0000-4000-8000-000000000002'));
  perform in_rec('IN07 Buraydah copy carries the hotel text', (select content_ar like '%4:00%' and override_fields = '{}' from property_policies where branch_id='ac010000-0000-4000-8000-000000000001' and topic='checkin'));
  -- the hotel text changes
  d := (d || jsonb_build_object('id', pv->'master'->>'id', 'version', 1, 'content_ar', 'الوصول من الساعة 5:00 عصرًا'));
  pv := fn_policy_master_preview(d);
  perform in_rec('IN08 preview: Buraydah updates content_ar, Aneeza keeps its own',
    (select e->'update_fields' = '["content_ar"]'::jsonb from jsonb_array_elements(pv->'branches') e where e->>'branch_name'='بريدة')
    and (select e->>'action' = 'keep_override' and e->'overwritable_fields' ? 'content_ar' from jsonb_array_elements(pv->'branches') e where e->>'branch_name'='عنيزة'));
  begin perform fn_policy_master_apply(d || jsonb_build_object('token', pv->>'token', 'version', 5)); perform in_rec('IN09 a stale version is refused', false);
  exception when others then perform in_rec('IN09 a stale version is refused', true, sqlerrm); end;
  ap := fn_policy_master_apply(d || jsonb_build_object('token', pv->>'token'));
  perform in_rec('IN10 default apply: Buraydah follows, Aneeza keeps 3:00', (select content_ar like '%5:00%' from property_policies where branch_id='ac010000-0000-4000-8000-000000000001' and topic='checkin') and (select content_ar like '%3:00%' from property_policies where id='ac300000-0000-4000-8000-000000000002') and (ap->>'overwritten')::int = 0, ap::text);
  -- explicit overwrite of the chosen branch
  d := d || '{"version":2,"content_ar":"الوصول من الساعة 6:00 عصرًا"}'::jsonb;
  pv := fn_policy_master_preview(d);
  begin perform fn_policy_master_apply(d || jsonb_build_object('token', pv->>'token', 'overwrite_branches', jsonb_build_array('ac010000-0000-4000-8000-000000000001'))); perform in_rec('IN11 overwriting a branch that has no own text is refused', false);
  exception when others then perform in_rec('IN11 overwriting a branch that has no own text is refused', sqlerrm like '%overwrite_not_overridden%', sqlerrm); end;
  ap := fn_policy_master_apply(d || jsonb_build_object('token', pv->>'token', 'overwrite_branches', jsonb_build_array('ac010000-0000-4000-8000-000000000002')));
  perform in_rec('IN12 chosen branch overwritten, audited with before text', (ap->>'overwritten')::int = 1 and (select content_ar like '%6:00%' and override_fields = '{}' from property_policies where id='ac300000-0000-4000-8000-000000000002')
    and exists (select 1 from audit_events where action='policy.master_overwrote_branch' and entity_id='ac300000-0000-4000-8000-000000000002' and details->'before'->>'content_ar' like '%3:00%'), ap::text);
  -- a direct edit on the old screen marks the field as the branch's own, and revert gives it back
  update property_policies set content_ar = 'الوصول من الساعة 2:00 عصرًا' where branch_id='ac010000-0000-4000-8000-000000000001' and topic='checkin';
  perform in_rec('IN13 direct edit keeps the link and records the own field', (select master_id is not null and override_fields = array['content_ar'] from property_policies where branch_id='ac010000-0000-4000-8000-000000000001' and topic='checkin'));
  update property_policies set master_id = null, override_fields = '{}' where branch_id='ac010000-0000-4000-8000-000000000001' and topic='checkin';
  perform in_rec('IN14 a client cannot unlink or clear overrides', (select master_id is not null and override_fields = array['content_ar'] from property_policies where branch_id='ac010000-0000-4000-8000-000000000001' and topic='checkin'));
  perform fn_policy_branch_revert((select id from property_policies where branch_id='ac010000-0000-4000-8000-000000000001' and topic='checkin'), null, 'back');
  perform in_rec('IN15 revert restores the hotel text', (select content_ar like '%6:00%' and override_fields = '{}' from property_policies where branch_id='ac010000-0000-4000-8000-000000000001' and topic='checkin'));
  -- knowledge
  perform fn_admin_upsert_knowledge('{"branch_id":null,"question":"هل يوجد مواقف؟","answer":"نعم مجانية","keywords":["مواقف"]}'::jsonb);
  declare e uuid := (select id from knowledge_entries where organization_id='ac000000-0000-4000-8000-000000000001' and branch_id is null and question like '%مواقف%'); o jsonb; kp jsonb;
  begin
    o := fn_knowledge_branch_override(e, 'ac010000-0000-4000-8000-000000000002', '{"answer":"نعم بمقابل"}');
    perform in_rec('IN16 override hides the shared entry for that branch only',
      (select count(*) from fn_staff_knowledge('ac010000-0000-4000-8000-000000000002') where question like '%مواقف%') = 1
      and (select answer from fn_staff_knowledge('ac010000-0000-4000-8000-000000000002') where question like '%مواقف%') like '%بمقابل%'
      and (select answer from fn_staff_knowledge('ac010000-0000-4000-8000-000000000001') where question like '%مواقف%') like '%مجانية%');
    perform in_rec('IN17 the override can be edited without a false conflict',
      (fn_admin_upsert_knowledge(jsonb_build_object('id', o->>'id', 'version', (o->>'version')::int, 'question', 'هل يوجد مواقف؟', 'answer', 'نعم بمقابل رمزي'))->>'ok')::boolean);
    kp := fn_knowledge_main_preview(e, '{"answer":"نعم مجانية للنزلاء","version":1}');
    perform in_rec('IN18 knowledge preview: Buraydah inherits, Aneeza keeps',
      (select e2->>'action' from jsonb_array_elements(kp->'branches') e2 where e2->>'branch_name'='بريدة') = 'inherits'
      and (select e2->>'action' from jsonb_array_elements(kp->'branches') e2 where e2->>'branch_name'='عنيزة') = 'keep_override');
    perform fn_knowledge_main_apply(e, '{"answer":"نعم مجانية للنزلاء","version":1}'::jsonb || jsonb_build_object('token', kp->>'token'));
    perform in_rec('IN19 apply updates the shared entry, Aneeza keeps its own', (select answer like '%للنزلاء%' from knowledge_entries where id = e)
      and (select answer like '%رمزي%' from knowledge_entries where id = (o->>'id')::uuid));
    perform fn_knowledge_revert_override((o->>'id')::uuid, 'back');
    perform in_rec('IN20 revert: Aneeza follows the shared entry again, own text archived not erased',
      (select answer from fn_staff_knowledge('ac010000-0000-4000-8000-000000000002') where question like '%مواقف%') like '%للنزلاء%'
      and (select archived_at is not null from knowledge_entries where id = (o->>'id')::uuid));
  end;
end $$;
-- a supervisor of one branch cannot make a hotel-level change; the other hotel never appears
select in_login('ac200000-0000-4000-8000-000000000002');
do $$ begin
  begin perform fn_policy_master_preview('{"topic":"wifi","title":"x","content_ar":"y"}'::jsonb); perform in_rec('IN21 no hotel-level policy change without access to every branch and the policies permission', false);
  exception when others then perform in_rec('IN21 no hotel-level policy change without access to every branch and the policies permission', sqlerrm like 'FORBIDDEN%', sqlerrm); end;
end $$;

-- more checks (as the owner again)
reset role;
create or replace function in_rowhash(p_id uuid) returns text language sql security definer as $$ select md5(p::text) from property_policies p where id = p_id $$;
create or replace function in_exec(p_fn text, p_role text) returns boolean language sql security definer as $$ select has_function_privilege(p_role, p_fn::regprocedure, 'execute') $$;
set role authenticated;
select in_login('ac200000-0000-4000-8000-000000000001');
do $$ declare d jsonb; pv jsonb; h1 text; h2 text; tok text; begin
  d := '{"topic":"parking","title":"المواقف","content_ar":"مجانية","is_public":true}'::jsonb;
  pv := fn_policy_master_preview(d);
  begin perform fn_policy_master_apply(d || jsonb_build_object('id', pv->'master'->>'id', 'token', '1.' || repeat('a',64))); perform in_rec('IN22 an expired token is refused', false);
  exception when others then perform in_rec('IN22 an expired token is refused', sqlerrm like '%PREVIEW_EXPIRED%', sqlerrm); end;
  begin perform fn_policy_master_apply(d || jsonb_build_object('id', pv->'master'->>'id', 'token', split_part(pv->>'token','.',1) || '.' || repeat('b',64))); perform in_rec('IN23 a tampered token is refused', false);
  exception when others then perform in_rec('IN23 a tampered token is refused', sqlerrm like '%PREVIEW_STALE%', sqlerrm); end;
  begin perform fn_policy_master_apply(d || jsonb_build_object('id', pv->'master'->>'id', 'token', pv->>'token', 'content_ar', 'مدفوعة')); perform in_rec('IN24 a token for other content is refused', false);
  exception when others then perform in_rec('IN24 a token for other content is refused', sqlerrm like '%PREVIEW_STALE%', sqlerrm); end;
  perform fn_policy_master_apply(d || jsonb_build_object('id', pv->'master'->>'id', 'token', pv->>'token'));
  begin perform fn_policy_master_apply(d || jsonb_build_object('id', pv->'master'->>'id', 'token', pv->>'token')); perform in_rec('IN25 replaying an applied preview is refused', false);
  exception when others then perform in_rec('IN25 replaying an applied preview is refused', sqlerrm like '%PREVIEW_STALE%', sqlerrm); end;
  -- unselected customised branch: byte identical after a default apply
  update property_policies set content_ar = 'الوصول من الساعة 3:30 عصرًا' where id = 'ac300000-0000-4000-8000-000000000002';
  h1 := in_rowhash('ac300000-0000-4000-8000-000000000002');
  d := '{"topic":"checkin","version":3,"title":"الوصول والمغادرة","content_ar":"الوصول من الساعة 7:00 عصرًا","is_public":true,"sort_order":1}'::jsonb || jsonb_build_object('id', (select m->>'id' from jsonb_array_elements(in_masters()) m where m->>'topic'='checkin'));
  pv := fn_policy_master_preview(d);
  perform fn_policy_master_apply(d || jsonb_build_object('token', pv->>'token'));
  h2 := in_rowhash('ac300000-0000-4000-8000-000000000002');
  perform in_rec('IN26 a branch that keeps its own text is byte for byte unchanged', h1 = h2 and (select content_ar like '%3:30%' from property_policies where id = 'ac300000-0000-4000-8000-000000000002'));
  perform in_rec('IN27 internal helpers and the guest-side knowledge function are not callable by the API roles',
    not in_exec('fn_policy_plan(uuid,jsonb)','authenticated') and not in_exec('fn_preview_token(text,uuid,bigint,text)','authenticated')
    and not in_exec('fn_policy_masters_of(uuid)','authenticated') and not in_exec('fn_policy_master_apply(jsonb)','anon')
    and not in_exec('fn_public_knowledge(uuid)','authenticated') and not in_exec('fn_public_knowledge(uuid)','anon')
    and in_exec('fn_policy_master_apply(jsonb)','authenticated') and (select relrowsecurity from pg_class where oid = 'policy_masters'::regclass) and not exists (select 1 from pg_policy where polrelid = 'policy_masters'::regclass));
end $$;
-- a manager who sees one branch only: edits a hotel-level knowledge entry as before (parity with fn_admin_upsert_knowledge), may not make a hotel-wide policy change
reset role;
insert into staff_profiles(id,auth_user_id,organization_id,full_name,email,role) values ('ac100000-0000-4000-8000-000000000003','ac200000-0000-4000-8000-000000000003','ac000000-0000-4000-8000-000000000001','IN manager','in-mgr@example.test','manager');
insert into branch_memberships(staff_id,branch_id) values ('ac100000-0000-4000-8000-000000000003','ac010000-0000-4000-8000-000000000001');
set role authenticated;
select in_login('ac200000-0000-4000-8000-000000000003');
do $$ declare e uuid := (select id from knowledge_entries where organization_id='ac000000-0000-4000-8000-000000000001' and branch_id is null and question like '%مواقف%'); kp jsonb; v int := (select version from knowledge_entries where id = (select id from knowledge_entries where organization_id='ac000000-0000-4000-8000-000000000001' and branch_id is null and question like '%مواقف%')); begin
  kp := fn_knowledge_main_preview(e, jsonb_build_object('answer','نعم مجانية دائمًا','version',v));
  perform fn_knowledge_main_apply(e, jsonb_build_object('answer','نعم مجانية دائمًا','version',v,'token',kp->>'token'));
  perform in_rec('IN28 a one-branch manager edits a hotel-level knowledge entry as the old function allowed', (select answer like '%دائمًا%' from knowledge_entries where id = e));
  begin perform fn_policy_master_preview('{"topic":"wifi","title":"x","content_ar":"y"}'::jsonb); perform in_rec('IN29 a one-branch manager cannot make a hotel-wide policy change', false);
  exception when others then perform in_rec('IN29 a one-branch manager cannot make a hotel-wide policy change', sqlerrm like 'FORBIDDEN%', sqlerrm); end;
end $$;
-- the supervisor cannot use the hotel-level knowledge edit
select in_login('ac200000-0000-4000-8000-000000000002');
do $$ begin
  begin perform fn_knowledge_main_preview((select id from knowledge_entries where organization_id='ac000000-0000-4000-8000-000000000001' and branch_id is null and question like '%مواقف%'), '{"answer":"x"}'::jsonb); perform in_rec('IN30 a supervisor cannot edit a hotel-level knowledge entry', false);
  exception when others then perform in_rec('IN30 a supervisor cannot edit a hotel-level knowledge entry', sqlerrm like 'FORBIDDEN%', sqlerrm); end;
end $$;

-- exit catalogue, overwrite authority, individual mode
reset role;
do $$ declare a int; b int; begin
  select seq into a from fn_hotel_exit_tables() where table_name = 'policy_masters'; select seq into b from fn_hotel_exit_tables() where table_name = 'property_policies';
  perform in_rec('IN31 the hotel exit catalogue includes policy_masters, emptied after the branch rows that point to it', a is not null and b is not null and b < a, a::text || ' ' || b::text);
end $$;
insert into staff_profiles(id,auth_user_id,organization_id,full_name,email,role) values ('ac100000-0000-4000-8000-000000000004','ac200000-0000-4000-8000-000000000004','ac000000-0000-4000-8000-000000000001','IN individual supervisor','in-ind@example.test','supervisor');
insert into branch_memberships(staff_id,branch_id) values ('ac100000-0000-4000-8000-000000000004','ac010000-0000-4000-8000-000000000001');
insert into staff_page_access(staff_id,organization_id,enabled,page_grants) values ('ac100000-0000-4000-8000-000000000004','ac000000-0000-4000-8000-000000000001',true,'{"/admin/policies":{"view":true,"add":true,"edit":true},"/admin/knowledge":{"view":true,"add":true,"edit":true}}');
create or replace function in_ans(p_id uuid) returns text language sql security definer as $$ select answer from knowledge_entries where id = p_id $$;
create or replace function in_shared() returns uuid language sql security definer as $$ select id from knowledge_entries where organization_id='ac000000-0000-4000-8000-000000000001' and branch_id is null and question like '%مواقف%' $$;
create or replace function in_ovr_ans() returns text language sql security definer as $$ select answer from knowledge_entries where branch_id = 'ac010000-0000-4000-8000-000000000002' and overrides_entry_id = in_shared() $$;
-- an override in the second branch (made by the owner) that the one-branch manager must not be able to overwrite
set role authenticated; select in_login('ac200000-0000-4000-8000-000000000001');
select fn_knowledge_branch_override(in_shared(), 'ac010000-0000-4000-8000-000000000002', '{"answer":"نص عنيزة الخاص"}'::jsonb);
select in_login('ac200000-0000-4000-8000-000000000003');
do $$ declare kp jsonb; e uuid := in_shared(); v int := (select version from knowledge_entries where id = in_shared()); before text := in_ans(in_shared()); begin
  kp := fn_knowledge_main_preview(e, jsonb_build_object('answer','نص جديد للجميع','version',v));
  begin
    perform fn_knowledge_main_apply(e, jsonb_build_object('answer','نص جديد للجميع','version',v,'token',kp->>'token','overwrite_branches',jsonb_build_array('ac010000-0000-4000-8000-000000000002')));
    perform in_rec('IN32 a one-branch manager cannot overwrite another branch''s own entry', false);
  exception when others then perform in_rec('IN32 a one-branch manager cannot overwrite another branch''s own entry, and nothing is applied', sqlerrm like 'FORBIDDEN%' and in_ans(e) = before, sqlerrm); end;
end $$;
-- an individual-mode supervisor with page grants: no hotel-level writes of either kind, may revert a policy of their own branch
select in_login('ac200000-0000-4000-8000-000000000004');
do $$ declare pid uuid; begin
  begin perform fn_policy_master_preview('{"topic":"wifi","title":"x","content_ar":"y"}'::jsonb); perform in_rec('IN33 an individual-mode supervisor cannot make a hotel-level policy change', false);
  exception when others then perform in_rec('IN33 an individual-mode supervisor cannot make a hotel-level policy change', sqlerrm like 'FORBIDDEN%', sqlerrm); end;
  begin perform fn_knowledge_main_preview(in_shared(), '{"answer":"x"}'::jsonb); perform in_rec('IN34 an individual-mode supervisor cannot edit a hotel-level knowledge entry', false);
  exception when others then perform in_rec('IN34 an individual-mode supervisor cannot edit a hotel-level knowledge entry', sqlerrm like 'FORBIDDEN%', sqlerrm); end;
  select id into pid from property_policies where branch_id = 'ac010000-0000-4000-8000-000000000001' and topic = 'checkin';
  update property_policies set content_ar = 'نص فرع بريدة' where id = pid;
  perform fn_policy_branch_revert(pid, null, 'x');
  perform in_rec('IN35 an individual-mode supervisor with the policies page edit grant reverts their own branch policy, as they could edit it', (select content_ar like '%7:00%' from property_policies where id = pid));
end $$;

-- redaction: the one-branch manager's knowledge preview names only their own branch and shows no override id of another branch
select in_login('ac200000-0000-4000-8000-000000000003');
do $$ declare kp jsonb; b4 text; begin
  kp := fn_knowledge_main_preview(in_shared(), jsonb_build_object('answer','نص آخر','version',(select version from knowledge_entries where id = in_shared())));
  perform in_rec('IN36 a one-branch manager sees only their own branch in the preview, the other is only counted',
    jsonb_array_length(kp->'branches') = 1 and kp->'branches'->0->>'branch_id' = 'ac010000-0000-4000-8000-000000000001'
    and (kp->'hidden_branches'->>'keep_override')::int = 1 and kp::text not like '%عنيزة%' and kp::text not like '%ac010000-0000-4000-8000-000000000002%', kp::text);
  b4 := in_ovr_ans();
  -- that preview's token still applies (it binds the full plan)
  perform fn_knowledge_main_apply(in_shared(), jsonb_build_object('answer','نص آخر','version',(select version from knowledge_entries where id = in_shared()),'token',kp->>'token'));
  perform in_rec('IN37 the redacted preview still applies; the hidden branch keeps its own text', in_ans(in_shared()) like '%آخر%' and in_ovr_ans() is not distinct from b4 and b4 is not null, coalesce(in_ovr_ans(),'NULL'));
end $$;
-- the server secret missing: no preview, no apply (fails closed, never a public constant)
select in_login('ac200000-0000-4000-8000-000000000001');
do $$ declare pv jsonb; begin
  pv := fn_policy_master_preview('{"topic":"privacy","title":"الخصوصية","content_ar":"نص"}'::jsonb);
  perform set_config('app.identity_key', '', true);
  begin perform fn_policy_master_preview('{"topic":"privacy","title":"الخصوصية","content_ar":"نص"}'::jsonb); perform in_rec('IN38 with no server secret a preview is refused', false);
  exception when others then perform in_rec('IN38 with no server secret a preview is refused', (sqlerrm like '%PREVIEW_UNAVAILABLE%' or sqlerrm like '%SECRET_NOT_CONFIGURED%'), sqlerrm); end;
  begin perform fn_policy_master_apply('{"topic":"privacy","title":"الخصوصية","content_ar":"نص"}'::jsonb || jsonb_build_object('id', pv->'master'->>'id', 'token', '9999999999.' || repeat('0',64))); perform in_rec('IN39 with no server secret an apply with a made-up token is refused, nothing is written', false);
  exception when others then perform in_rec('IN39 with no server secret an apply with a made-up token is refused, nothing is written', (sqlerrm like '%PREVIEW_UNAVAILABLE%' or sqlerrm like '%SECRET_NOT_CONFIGURED%') and not exists (select 1 from property_policies where topic = 'privacy'), sqlerrm); end;
  begin perform fn_policy_master_apply('{"topic":"privacy","title":"الخصوصية","content_ar":"نص"}'::jsonb || jsonb_build_object('id', pv->'master'->>'id', 'token', '9999999999.' || repeat('0',64))); exception when others then null; end;
  perform set_config('app.identity_key', 'test-identity-key', true);
end $$;

-- trigger bypass: a client that sets the marker itself (flag value 1, or any guess) still cannot move the link
select in_login('ac200000-0000-4000-8000-000000000001');
do $$ declare mid uuid; pid uuid; begin
  select id, master_id into pid, mid from property_policies where master_id is not null and organization_id='ac000000-0000-4000-8000-000000000001' limit 1;
  perform set_config('app.policy_sync', '1', true);
  update property_policies set master_id = null, master_version = 99, override_fields = '{}' where id = pid;
  perform in_rec('IN40 a client setting app.policy_sync=1 cannot unlink or re-version a branch row',
    (select master_id = mid and master_version <> 99 from property_policies where id = pid));
  perform set_config('app.policy_sync', '', true);
  perform in_rec('IN41 the marker is not left set after the RPCs', coalesce(current_setting('app.policy_sync', true), '') = '');
end $$;
reset role;
select 'FAIL' as result, name, detail from test_results where not ok;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from test_results;
rollback;
