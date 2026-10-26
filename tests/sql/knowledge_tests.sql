-- =====================================================================
-- Knowledge base tests (K01–K12) — run after security_tests.sql / core_tests.sql
-- on the same database (reuses the fixtures and helpers they created).
-- Control: the assistant answers only from property records; staff-only entries
-- never reach anonymous clients; unanswered questions are logged without PII.
-- =====================================================================
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create or replace function t_login(p_uid uuid, p_email text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email)::text, false);
end $$;
create or replace function t_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;
create or replace function t_kb_count(p_org uuid) returns int language sql security definer as $$ select count(*)::int from knowledge_entries where organization_id = p_org $$;
create or replace function t_unanswered(p_norm text) returns table(asked int, status text) language sql security definer as $$ select asked_count, status from unanswered_questions where normalized = p_norm $$;
create or replace function t_audit_count(p_action text, p_entity uuid) returns int language sql security definer as $$ select count(*)::int from audit_events where action = p_action and entity_id = p_entity $$;

-- fixtures: a staff-only entry + an inactive entry + a second-org entry (as superuser)
reset role;
insert into knowledge_entries(id, organization_id, branch_id, category, question, keywords, answer, is_public)
values ('70000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010','services','ما رمز خزنة الاستقبال؟', array['خزنه'], 'سري للموظفين فقط', false)
on conflict do nothing;
insert into knowledge_entries(id, organization_id, branch_id, category, question, keywords, answer, is_active)
values ('70000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010','services','هل يوجد ساونا؟', array['ساونا'], 'معطل مؤقتًا', false)
on conflict do nothing;
insert into knowledge_entries(id, organization_id, branch_id, category, question, keywords, answer)
values ('70000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000011','services','سؤال منشأة أخرى', array['اخرى'], 'إجابة المنشأة الأخرى')
on conflict do nothing;

-- ---------- K01/K02: anonymous exposure ----------
set role anon;
do $$ declare n int; begin
  begin
    select count(*) into n from knowledge_entries;
    perform t_record('K01 anon cannot read knowledge_entries table', false, 'read ' || n || ' rows');
  exception when insufficient_privilege then
    perform t_record('K01 anon cannot read knowledge_entries table', true);
  end;
end $$;
-- fn_public_knowledge is the reception assistant's (an Edge Function, with the service key); 0045 closed it to visitors
reset role; set role service_role;
do $$ declare n int; m int; k int; begin
  select count(*) into n from fn_public_knowledge('00000000-0000-0000-0000-000000000010');
  select count(*) into m from fn_public_knowledge('00000000-0000-0000-0000-000000000010') where answer = 'سري للموظفين فقط' or answer = 'معطل مؤقتًا' or answer = 'إجابة المنشأة الأخرى';
  select count(*) into k from fn_public_knowledge('00000000-0000-0000-0000-000000000011');
  perform t_record('K02 fn_public_knowledge returns only public+active entries of the branch/org', n >= 10 and m = 0 and k = 1, format('branch10=%s leaked=%s branch11=%s', n, m, k));
end $$;
reset role; set role anon;
do $$ begin
  begin
    perform fn_record_unanswered('00000000-0000-0000-0000-000000000010', 'سؤال من مجهول', null);
    perform t_record('K03 anon cannot call fn_record_unanswered (service role only)', false);
  exception when insufficient_privilege then
    perform t_record('K03 anon cannot call fn_record_unanswered (service role only)', true);
  end;
end $$;
do $$ begin
  begin
    perform fn_admin_upsert_knowledge('{"question":"x y z","answer":"abc"}'::jsonb);
    perform t_record('K04 anon cannot upsert knowledge', false);
  exception when others then
    perform t_record('K04 anon cannot upsert knowledge', true, sqlerrm);
  end;
end $$;
reset role;

-- ---------- K05: housekeeping cannot write; staff can read within org only ----------
select t_login('a0000000-0000-0000-0000-000000000003','hk@test.local');
set role authenticated;
do $$ begin
  begin
    perform fn_admin_upsert_knowledge('{"branch_id":"00000000-0000-0000-0000-000000000010","question":"سؤال نظافة","answer":"جواب"}'::jsonb);
    perform t_record('K05 housekeeping cannot create knowledge entries', false);
  exception when others then
    perform t_record('K05 housekeeping cannot create knowledge entries', sqlerrm like 'FORBIDDEN%', sqlerrm);
  end;
end $$;
do $$ declare n int; begin
  select count(*) into n from knowledge_entries where organization_id = '00000000-0000-0000-0000-000000000002';
  perform t_record('K06 staff never see another organization''s entries through RLS', n = 0, 'saw ' || n);
end $$;
reset role;

-- ---------- K07–K10: supervisor manages entries, versioned and audited ----------
select t_login('a0000000-0000-0000-0000-000000000002','sup@test.local');
set role authenticated;
do $$ declare r jsonb; kid uuid; v int; begin
  r := fn_admin_upsert_knowledge('{"branch_id":"00000000-0000-0000-0000-000000000010","category":"services","question":"هل يوجد تأجير سيارات؟","keywords":["تأجير سيارات","ليموزين","Rent a Car"],"answer":"نعم، عبر الاستقبال."}'::jsonb);
  kid := (r->>'id')::uuid; v := (r->>'version')::int;
  perform t_record('K07 supervisor creates an entry; keywords normalized and lower-cased',
    (r->>'ok')::boolean and exists (select 1 from knowledge_entries k where k.id = kid and k.keywords @> array['تاجير سيارات','rent a car','ليموزين']), r::text);
  -- update without version → rejected; with stale version → conflict; with the right one → ok and audited
  begin
    perform fn_admin_upsert_knowledge(jsonb_build_object('id', kid, 'branch_id', '00000000-0000-0000-0000-000000000010', 'question', 'هل يوجد تأجير سيارات؟', 'answer', 'تعديل'));
    perform t_record('K08 update without expected version is rejected', false);
  exception when others then
    perform t_record('K08 update without expected version is rejected', sqlerrm like 'VERSION_REQUIRED%', sqlerrm);
  end;
  begin
    perform fn_admin_upsert_knowledge(jsonb_build_object('id', kid, 'branch_id', '00000000-0000-0000-0000-000000000010', 'question', 'هل يوجد تأجير سيارات؟', 'answer', 'تعديل', 'version', v + 5));
    perform t_record('K09 stale version → VERSION_CONFLICT', false);
  exception when others then
    perform t_record('K09 stale version → VERSION_CONFLICT', sqlerrm like 'VERSION_CONFLICT%', sqlerrm);
  end;
  r := fn_admin_upsert_knowledge(jsonb_build_object('id', kid, 'branch_id', '00000000-0000-0000-0000-000000000010', 'question', 'هل يوجد تأجير سيارات؟', 'keywords', jsonb_build_array('تأجير'), 'answer', 'نعم، عبر الاستقبال خلال ساعة.', 'version', v, 'reason', 'تحديث المدة'));
  perform t_record('K10 update with the right version bumps version and writes before/after audit',
    (r->>'version')::int = v + 1 and t_audit_count('knowledge.updated', kid) = 1 and t_audit_count('knowledge.created', kid) = 1, r::text);
  -- archive needs a reason, hides from public, restore brings it back
  begin
    perform fn_admin_archive_knowledge(kid, '', true);
    perform t_record('K11 archive requires a reason', false);
  exception when others then
    perform t_record('K11 archive requires a reason', sqlerrm like 'VALIDATION%', sqlerrm);
  end;
  perform fn_admin_archive_knowledge(kid, 'لم تعد الخدمة متاحة', true);
  perform t_record('K11b archived entry disappears from public answers but the row stays',
    not exists (select 1 from fn_public_knowledge('00000000-0000-0000-0000-000000000010') p where p.id = kid) and exists (select 1 from knowledge_entries k where k.id = kid and k.archived_at is not null));
  perform fn_admin_archive_knowledge(kid, null, false);
  perform t_record('K11c restored entry is public again', exists (select 1 from fn_public_knowledge('00000000-0000-0000-0000-000000000010') p where p.id = kid));
end $$;
reset role;

-- ---------- K12: unanswered log (service role), digits masked, dedup by normalized text, resolve flow ----------
set role service_role;
do $$ declare r jsonb; r2 jsonb; begin
  r := fn_record_unanswered('00000000-0000-0000-0000-000000000010', 'هل فيه جاكوزي؟ جوالي 0501234567', '00000000-0000-0000-0000-00000000c001');
  r2 := fn_record_unanswered('00000000-0000-0000-0000-000000000010', 'هَل فِيه جاكُوزي؟ جوالي 0509999999', null);
  perform t_record('K12 unanswered questions are logged once per normalized text, counted, with digits masked',
    (r->>'id') = (r2->>'id') and exists (select 1 from t_unanswered('هل فيه جاكوزي؟ جوالي #') u where u.asked = 2 and u.status = 'open')
    and not exists (select 1 from unanswered_questions where question like '%0501234567%'), r::text || ' ' || r2::text);
end $$;
reset role;
select t_login('a0000000-0000-0000-0000-000000000002','sup@test.local');
set role authenticated;
do $$ declare uq uuid; r jsonb; begin
  select id into uq from unanswered_questions where normalized = 'هل فيه جاكوزي؟ جوالي #';
  r := fn_admin_upsert_knowledge(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'question', 'هل يوجد جاكوزي؟', 'keywords', jsonb_build_array('جاكوزي'), 'answer', 'لا يوجد جاكوزي حاليًا.', 'unanswered_id', uq));
  perform t_record('K12b answering from the unanswered list links the entry and closes the question',
    exists (select 1 from unanswered_questions u where u.id = uq and u.status = 'answered' and u.knowledge_entry_id = (r->>'id')::uuid));
  perform fn_admin_resolve_unanswered(uq, 'ignored', 'سؤال غير مفيد');
  perform t_record('K12c resolve to ignored is audited', exists (select 1 from unanswered_questions u where u.id = uq and u.status = 'ignored') and t_audit_count('unanswered.ignored', uq) = 1);
end $$;
reset role;

select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),110) as detail from test_results order by ok, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if (select count(*) from test_results) < 16 then raise exception 'KNOWLEDGE TESTS INCOMPLETE: % of 16 checks ran', (select count(*) from test_results); end if;
  if exists (select 1 from test_results where ok is not true) then raise exception 'KNOWLEDGE TESTS FAILED'; end if;
end $$;
