-- =====================================================================
-- The review of 31 October, Phase 4b as the owner decided it (QN*; migration 0060): the owner's lists — a name search
-- that also finds the near spellings (OWNER-12), and a review list where an item can be objected to with a note that
-- reaches the branch's supervisors, and a «تمت المراجعة» taken back within 10 minutes by whoever marked it (OWNER-13).
-- =====================================================================
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create temp table ids(k text primary key, v uuid);
grant all on ids to public;
create or replace function t_login(p_uid uuid, p_email text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email)::text, false);
end $$;
create or replace function t_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;
create or replace function t_id(p_k text) returns uuid language sql security definer as $$ select v from ids where k = p_k $$;
create or replace function t_err(p_sql text, p_like text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'accepted';
exception when others then
  return case when sqlerrm like p_like then 'ok' else sqlerrm end;
end $$;

-- ---------------------------------------------------------------- fixtures: three guests and three review items of the seed branch
do $$ declare v_org uuid; b uuid := '00000000-0000-0000-0000-000000000010'; i int; r uuid; begin
  select organization_id into v_org from branches where id = b;
  insert into guest_profiles(organization_id, full_name, phone, notes) values (v_org, 'محمود القحطاني', '0559000601', 'QN') returning id into r; insert into ids values ('g_near', r);
  insert into guest_profiles(organization_id, full_name, phone, notes) values (v_org, 'محمد القحطاني', '0559000602', 'QN') returning id into r; insert into ids values ('g_exact', r);
  insert into guest_profiles(organization_id, full_name, phone, notes) values (v_org, 'عبدالله الزهراني', '0559000603', 'QN') returning id into r; insert into ids values ('g_spaced', r);
  for i in 1..3 loop
    insert into review_items(organization_id, branch_id, kind, entity_type, entity_id, summary)
    values (v_org, b, 'qn_test', 'reservation', gen_random_uuid(), 'بند اختبار ' || i) returning id into r;
    insert into ids values ('ri' || i, r);
  end loop;
end $$;

select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;

-- ---------------------------------------------------------------- QN01–QN03 the name search (OWNER-12)
do $$ declare r jsonb; begin
  r := fn_guest_profiles('{"q":"محمد القحطاني","limit":50}');
  perform t_record('QN01 a name finds itself first, then a near spelling marked «near» (محمود for محمد)',
    (select (x->>'id')::uuid from jsonb_array_elements(r->'rows') x where (x->>'near')::boolean is false and x->>'full_name' = 'محمد القحطاني') = t_id('g_exact')
    and exists (select 1 from jsonb_array_elements(r->'rows') x where (x->>'id')::uuid = t_id('g_near') and (x->>'near')::boolean)
    and (r->'rows'->0->>'near')::boolean is false and (r->>'near')::int >= 1, r::text);
  r := fn_guest_profiles('{"q":"عبد الله الزهراني","limit":50}');
  perform t_record('QN02 a space inside a name is not a different name (عبد الله = عبدالله): an exact match, not a near one',
    exists (select 1 from jsonb_array_elements(r->'rows') x where (x->>'id')::uuid = t_id('g_spaced') and (x->>'near')::boolean is false), r::text);
  r := fn_guest_profiles('{"q":"0559000602","limit":50}');
  perform t_record('QN03 a phone search finds the number only, with no near names',
    (r->>'total')::int = 1 and (r->>'near')::int = 0 and (r->'rows'->0->>'id')::uuid = t_id('g_exact'), r::text);
exception when others then perform t_record('QN01 a name finds itself first, then a near spelling marked «near» (محمود for محمد)', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- QN04–QN07 the review list (OWNER-13)
do $$ declare r jsonb; n int; begin
  perform t_record('QN04 an objection needs a note of three letters or more',
    t_err(format('select fn_review_mark(%L)', jsonb_build_object('ids', jsonb_build_array(t_id('ri1')), 'outcome', 'objection', 'note', 'لا')), '%objection_note%') = 'ok'
    and t_err(format('select fn_review_mark(%L)', jsonb_build_object('ids', jsonb_build_array(t_id('ri1')), 'outcome', 'maybe')), '%outcome%') = 'ok');
  r := fn_review_mark(jsonb_build_object('ids', jsonb_build_array(t_id('ri1')), 'outcome', 'objection', 'note', 'لماذا خُصم المبلغ؟'));
  select count(*) into n from notifications where audience = 'supervisor' and title like 'اعتراض المالك: بند اختبار 1%';
  perform t_record('QN05 an objection keeps the item open, says so on the list and tells the branch''s supervisors',
    (r->>'objected')::int = 1 and n = 1
    and exists (select 1 from jsonb_array_elements(fn_review_list('{"kind":"qn_test"}')->'items') x
                where (x->>'id')::uuid = t_id('ri1') and x->>'reviewed_at' is null and x->>'objection_note' = 'لماذا خُصم المبلغ؟'), r::text);
  r := fn_review_mark(jsonb_build_object('ids', jsonb_build_array(t_id('ri2'), t_id('ri3')), 'note', 'راجعتها'));
  perform t_record('QN06 «تمت المراجعة» closes the items, and the list says the caller marked them',
    (r->>'marked')::int = 2
    and (select bool_and((x->>'reviewed_by_me')::boolean) from jsonb_array_elements(fn_review_list('{"kind":"qn_test","status":"reviewed"}')->'items') x) is true, r::text);
  r := fn_review_undo(jsonb_build_object('ids', jsonb_build_array(t_id('ri2'))));
  perform t_record('QN07 the same reviewer takes a «تمت المراجعة» back within 10 minutes: the item is open again',
    (r->>'undone')::int = 1 and (select reviewed_at is null from review_items where id = t_id('ri2')), r::text);
exception when others then perform t_record('QN05 an objection keeps the item open, says so on the list and tells the branch''s supervisors', false, sqlerrm);
end $$;
reset role;
update review_items set reviewed_at = now() - interval '11 minutes' where id = t_id('ri3');
set role authenticated;
select t_record('QN08 after 10 minutes the mark stays: CORRECTION_WINDOW_PASSED, and the item is still reviewed',
  t_err(format('select fn_review_undo(%L)', jsonb_build_object('ids', jsonb_build_array(t_id('ri3')))), '%CORRECTION_WINDOW_PASSED%') = 'ok'
  and (select reviewed_at is not null from review_items where id = t_id('ri3')));
reset role;
select t_record('QN09 the name helpers are not open to the anonymous role',
  not has_function_privilege('anon', 'fn_name_closeness(text, text)', 'execute')
  and not has_function_privilege('anon', 'fn_review_undo(jsonb)', 'execute'));

select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),160) as detail from test_results order by ok nulls first, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from test_results where ok is not true) then raise exception 'REVIEW PHASE 4B TESTS FAILED'; end if;
  if (select count(*) from test_results) < 9 then raise exception 'REVIEW PHASE 4B TESTS INCOMPLETE: % of 9 checks ran', (select count(*) from test_results); end if;
end $$;
