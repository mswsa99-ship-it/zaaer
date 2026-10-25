-- =====================================================================
-- Lists, calendar, log, exports, report filters, task times, staff editor, forced sign-out and capability usage
-- (Phase 6, migrations 0040–0041): decisions 14, 28, 34, 35, 36, 43 (G25, X09), 55 (G26, D04).
-- LS01–LS08  the reservations list: every filter equals an independent query, pages, sort, money gating, branches.
-- SV01–SV04  saved views: own rows only, one default, at most 20, archived not erased.
-- CL01–CL04  «تقويم الحجوزات»: window, units, segments clipped to the window, money gating, branch.
-- AL01–AL07  the log: readable names, filters, pages, security rows for the owner only, branch scoping, details.
-- VL01–VL05  the ledger: filters, pages, totals over the whole set (no 2000 limit), roles.
-- RP01–RP08  the reports' filters (staff, method, account, source, type) against independent sums; the options;
--            the signatures without filters are gone (0041).
-- X09a–X09d  every export source: count and ids equal an independent query with the same filters; no row of
--            another branch; no silent limit.
-- TS01–TS03  the task's start and end (decision 28).
-- ST01–ST15  the staff list, «تعديل موظف», activation, «تسجيل خروج إجباري», retired memberships, the audit rows.
-- CU01–CU05  «استعمال القدرات» with D04: «غير محسوم» where the log cannot tell, never «غير مستخدم».
-- Runs after guests_platforms_tests.sql on the same database (its organisation, branch 010, branch B 012, staff).
-- =====================================================================
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create temp table ids(k text primary key, v uuid);
grant all on ids to public;
create temp table vals(k text primary key, v text);
grant all on vals to public;
create or replace function t_login(p_uid uuid, p_email text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email)::text, false);
end $$;
-- a sign-in whose token names its session, as every Supabase access token does (decision 34)
create or replace function t_login_session(p_uid uuid, p_email text, p_session uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email, 'session_id', p_session)::text, false);
end $$;
create or replace function t_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;
create or replace function t_id(p_k text) returns uuid language sql security definer as $$ select v from ids where k = p_k $$;
create or replace function t_set(p_k text, p_v uuid) returns void language sql security definer as $$ insert into ids values (p_k, p_v) on conflict (k) do update set v = excluded.v $$;
create or replace function t_count(p_sql text) returns bigint language plpgsql security definer as $$ declare n bigint; begin execute p_sql into n; return n; end $$;
create or replace function t_text(p_sql text) returns text language plpgsql security definer as $$ declare n text; begin execute p_sql into n; return n; end $$;
create or replace function t_today() returns date language sql security definer as $$ select fn_branch_today('00000000-0000-0000-0000-000000000010') $$;
create or replace function t_fails(p_sql text, p_like text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'accepted';
exception when others then
  return case when sqlerrm like p_like then 'ok' else sqlerrm end;
end $$;
-- the ids of a filtered list, every page (the way an export reads it), as a sorted array
create or replace function t_list_ids(p_branch uuid, p_filters jsonb, p_page int) returns uuid[] language plpgsql as $$
declare acc uuid[] := '{}'; r jsonb; off int := 0; total int;
begin
  loop
    r := fn_reservation_list(p_branch, p_filters, p_page, off);
    total := (r->>'total')::int;
    acc := acc || coalesce((select array_agg((x->>'id')::uuid) from jsonb_array_elements(r->'rows') x), '{}');
    off := off + p_page;
    exit when jsonb_array_length(r->'rows') = 0 or off >= total;
  end loop;
  return coalesce((select array_agg(x order by x) from unnest(acc) x), '{}');
end $$;
create or replace function t_audit_ids(p jsonb, p_page int) returns uuid[] language plpgsql as $$
declare acc uuid[] := '{}'; r jsonb; off int := 0; total int;
begin
  loop
    r := fn_audit_list(p || jsonb_build_object('limit', p_page, 'offset', off));
    total := (r->>'total')::int;
    acc := acc || coalesce((select array_agg((x->>'id')::uuid) from jsonb_array_elements(r->'rows') x), '{}');
    off := off + p_page;
    exit when jsonb_array_length(r->'rows') = 0 or off >= total;
  end loop;
  return coalesce((select array_agg(x order by x) from unnest(acc) x), '{}');
end $$;
create or replace function t_voucher_ids(p jsonb, p_page int) returns uuid[] language plpgsql as $$
declare acc uuid[] := '{}'; r jsonb; off int := 0; total int;
begin
  loop
    r := fn_voucher_list(p || jsonb_build_object('limit', p_page, 'offset', off));
    total := (r->>'total')::int;
    acc := acc || coalesce((select array_agg((x->>'id')::uuid) from jsonb_array_elements(r->'rows') x), '{}');
    off := off + p_page;
    exit when jsonb_array_length(r->'rows') = 0 or off >= total;
  end loop;
  return coalesce((select array_agg(x order by x) from unnest(acc) x), '{}');
end $$;
-- the same set from the table itself (security definer: no policy in the way), sorted
create or replace function t_ids(p_sql text) returns uuid[] language plpgsql security definer as $$
declare a uuid[]; begin execute 'select array_agg(id order by id) from (' || p_sql || ') q' into a; return coalesce(a, '{}'); end $$;
-- the session tables as Supabase Auth keeps them: open a session for an auth user, read it back
create or replace function t_session_open(p_user uuid) returns uuid language plpgsql security definer as $$
declare sid uuid := gen_random_uuid();
begin
  insert into auth.sessions(id, user_id, aal) values (sid, p_user, 'aal1');
  insert into auth.refresh_tokens(token, user_id, revoked, session_id) values ('tok-' || sid::text, p_user::text, false, sid);
  return sid;
end $$;
create or replace function t_session_ended(p_session uuid) returns boolean language sql security definer as $$
  select exists (select 1 from auth.sessions where id = p_session and not_after is not null and not_after <= now())
     and not exists (select 1 from auth.refresh_tokens where session_id = p_session and coalesce(revoked, false) = false);
$$;
create or replace function t_staff(p uuid) returns staff_profiles language sql security definer as $$ select * from staff_profiles where id = p $$;
create or replace function t_membership_rows(p_staff uuid, p_branch uuid) returns table(n bigint, removed bigint) language sql security definer as $$
  select count(*), count(*) filter (where removed_at is not null) from branch_memberships where staff_id = p_staff and branch_id = p_branch;
$$;
create or replace function t_audit_last(p_action text, p_entity uuid) returns audit_events language sql security definer as $$
  select * from audit_events where action = p_action and entity_id = p_entity order by created_at desc, id desc limit 1;
$$;
-- an old audit row (the log's horizon for D04): the enrich trigger fills actor, source and category as it always does
create or replace function t_audit_backdated(p_org uuid, p_branch uuid, p_action text, p_entity text, p_ago interval, p_details jsonb default '{"test": "backdated"}'::jsonb) returns void language plpgsql security definer as $$
begin
  insert into audit_events(organization_id, branch_id, action, entity_type, entity_id, details, created_at)
  values (p_org, p_branch, p_action, p_entity, gen_random_uuid(), p_details, now() - p_ago);
end $$;
create or replace function t_task(p uuid) returns housekeeping_tasks language sql security definer as $$ select * from housekeeping_tasks where id = p $$;

-- ---------------------------------------------------------------- fixtures
select t_set('box', (select id from cash_accounts where branch_id = '00000000-0000-0000-0000-000000000010' and kind = 'cash_box' order by created_at limit 1));
-- a booking in branch B, so the branch scoping of every list has something to leak
select t_login('a0000000-0000-0000-0000-000000000006', 'supB@test.local');
set role authenticated;
do $$ declare r jsonb; begin
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000012', 'category_id', '00000000-0000-0000-0000-000000000039',
         'room_id', '00000000-0000-0000-0000-000000000199', 'check_in', t_today() + 40, 'check_out', t_today() + 42, 'guest_name', 'ضيف الفرع ب',
         'guest_phone', '0500009901', 'source_id', '00000000-0000-0000-0000-000000000021'));
  perform t_set('res_b', (r->>'id')::uuid);
exception when others then perform t_record('fixture: a booking in branch B', false, sqlerrm); end $$;
reset role;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;

-- =====================================================================
-- LS. The reservations list (decision 14, 10.1) and X09b
-- =====================================================================
-- every filter of the reference against an independent query over the table
do $$ declare f record; want uuid[]; got uuid[]; r jsonb; n int := 0; bad text := ''; begin
  for f in select * from (values
    ('status', '{"status":"confirmed,checked_in"}'::jsonb, 'status in (''confirmed'',''checked_in'')'),
    ('open_only', '{"open_only":"true"}', 'status in (''pending_verification'',''confirmed'',''checked_in'')'),
    ('check_in window', jsonb_build_object('check_in_from', t_today() - 3, 'check_in_to', t_today() + 3), format('check_in between %L and %L', t_today() - 3, t_today() + 3)),
    ('check_out window', jsonb_build_object('check_out_from', t_today(), 'check_out_to', t_today() + 7), format('check_out between %L and %L', t_today(), t_today() + 7)),
    ('created today (branch day)', jsonb_build_object('created_from', t_today(), 'created_to', t_today()), format('(created_at at time zone ''Asia/Riyadh'')::date = %L', t_today())),
    ('stay_on', jsonb_build_object('stay_on', t_today()), format('check_in <= %L and check_out > %L', t_today(), t_today())),
    ('source', '{"source_id":"00000000-0000-0000-0000-000000000020"}', 'source_id = ''00000000-0000-0000-0000-000000000020'''),
    ('category', '{"category_id":"00000000-0000-0000-0000-000000000030"}', 'room_category_id = ''00000000-0000-0000-0000-000000000030'''),
    ('room number', '{"room_number":"101"}', 'room_id = ''00000000-0000-0000-0000-000000000100'''),
    ('booking_type', '{"booking_type":"individual"}', 'booking_type = ''individual'''),
    ('price_basis', '{"price_basis":"nightly"}', 'price_basis = ''nightly'''),
    ('payment_status', '{"payment_status":"paid"}', 'payment_status = ''paid'''),
    ('has_discount', '{"has_discount":"true"}', 'discount_halalas > 0'),
    ('has_balance (money role)', '{"has_balance":"true"}', 'balance_due_halalas > 0'),
    ('platform_collects', '{"platform_collects":"true"}', 'platform_collects = true'),
    ('q by number', jsonb_build_object('q', t_text('select internal_ref from reservations where branch_id = ''00000000-0000-0000-0000-000000000010'' order by created_at limit 1')),
                    format('internal_ref ilike %L', '%' || t_text('select internal_ref from reservations where branch_id = ''00000000-0000-0000-0000-000000000010'' order by created_at limit 1') || '%')),
    ('cancelled with cancel_reference', '{"status":"cancelled","q":"CXL"}', 'status = ''cancelled'' and (cancel_reference ilike ''%CXL%'' or internal_ref ilike ''%CXL%'' or coalesce(external_ref,'''') ilike ''%CXL%'' or coalesce(company_name,'''') ilike ''%CXL%'')')
  ) as t(name, filters, pred) loop
    want := t_ids('select id from reservations where branch_id = ''00000000-0000-0000-0000-000000000010'' and ' || f.pred);
    got := t_list_ids('00000000-0000-0000-0000-000000000010', f.filters, 7);
    r := fn_reservation_list('00000000-0000-0000-0000-000000000010', f.filters, 1000, 0);
    if want = got and (r->>'total')::int = coalesce(array_length(want, 1), 0) then n := n + 1; else bad := bad || f.name || ' (' || coalesce(array_length(want, 1), 0) || ' vs ' || coalesce(array_length(got, 1), 0) || ') '; end if;
  end loop;
  perform t_record('LS01 / X09b every filter of the list returns exactly the rows an independent query returns, read in pages of 7, with the exact total', bad = '', n || ' filters; ' || bad);
exception when others then perform t_record('LS01 / X09b every filter of the list returns exactly the rows an independent query returns, read in pages of 7, with the exact total', false, sqlerrm); end $$;

-- pages and the limit cap
do $$ declare a jsonb; b jsonb; big jsonb; begin
  a := fn_reservation_list('00000000-0000-0000-0000-000000000010', '{}'::jsonb, 2, 0);
  b := fn_reservation_list('00000000-0000-0000-0000-000000000010', '{}'::jsonb, 2, 2);
  big := fn_reservation_list('00000000-0000-0000-0000-000000000010', '{}'::jsonb, 100000, 0);
  perform t_record('LS02 pages of two do not overlap, the total is the whole set on every page, and a limit above 1000 is capped (not refused) while the total stays exact',
    jsonb_array_length(a->'rows') = 2 and jsonb_array_length(b->'rows') = 2 and (a->'rows'->0->>'id') <> (b->'rows'->0->>'id') and (a->'rows'->1->>'id') <> (b->'rows'->0->>'id')
    and (a->>'total')::int = (b->>'total')::int and (a->>'total')::int = t_count('select count(*) from reservations where branch_id = ''00000000-0000-0000-0000-000000000010''')
    and jsonb_array_length(big->'rows') = least((big->>'total')::int, 1000),
    a->>'total' || ' / ' || jsonb_array_length(big->'rows'));
exception when others then perform t_record('LS02 pages of two do not overlap, the total is the whole set on every page, and a limit above 1000 is capped (not refused) while the total stays exact', false, sqlerrm); end $$;

-- sort
do $$ declare r jsonb; asc_ok boolean; ref_ok boolean; dflt_ok boolean; begin
  r := fn_reservation_list('00000000-0000-0000-0000-000000000010', '{"sort":"check_in_asc"}'::jsonb, 1000, 0);
  select bool_and((x->>'check_in')::date <= (nx->>'check_in')::date) into asc_ok from (select x, lead(x) over () as nx from jsonb_array_elements(r->'rows') x) z where nx is not null;
  r := fn_reservation_list('00000000-0000-0000-0000-000000000010', '{"sort":"ref"}'::jsonb, 1000, 0);
  select bool_and((x->>'internal_ref') <= (nx->>'internal_ref')) into ref_ok from (select x, lead(x) over () as nx from jsonb_array_elements(r->'rows') x) z where nx is not null;
  r := fn_reservation_list('00000000-0000-0000-0000-000000000010', '{}'::jsonb, 1000, 0);
  select bool_and((x->>'check_in')::date >= (nx->>'check_in')::date) into dflt_ok from (select x, lead(x) over () as nx from jsonb_array_elements(r->'rows') x) z where nx is not null;
  perform t_record('LS03 sort: arrival ascending, number ascending, and the default (arrival descending)', asc_ok and ref_ok and dflt_ok, asc_ok || '/' || ref_ok || '/' || dflt_ok);
exception when others then perform t_record('LS03 sort: arrival ascending, number ascending, and the default (arrival descending)', false, sqlerrm); end $$;

-- the columns a picker needs are there (owner)
do $$ declare r jsonb; row jsonb; missing text[]; begin
  r := fn_reservation_list('00000000-0000-0000-0000-000000000010', '{}'::jsonb, 1, 0);
  row := r->'rows'->0;
  select array_agg(k) into missing from unnest(array['internal_ref','status','check_in','check_out','nights','guest_name','room_number','source_name','category_name','booking_type','company_name',
    'price_basis','adults','companions','platform_booked_on','platform_collects','created_by_name','actual_check_in','actual_check_out','cancelled_at','cancel_reference',
    'total_halalas','paid_halalas','discount_halalas','nightly_rate_halalas','balance_due_halalas','deposit_balance_halalas','payment_status','identity_status','access_status','created_at','group_ref','hold','ban','rating']) k
  where not (row ? k);
  perform t_record('LS04 the row carries every column the column picker offers', missing is null, coalesce(array_to_string(missing, ','), 'all present'));
exception when others then perform t_record('LS04 the row carries every column the column picker offers', false, sqlerrm); end $$;

-- money gating and the balance filter for housekeeping
select t_login('a0000000-0000-0000-0000-000000000003', 'hk@test.local');
do $$ declare r jsonb; f jsonb; money_seen boolean; begin
  r := fn_reservation_list('00000000-0000-0000-0000-000000000010', '{}'::jsonb, 1000, 0);
  select bool_or(x->>'total_halalas' is not null or x->>'paid_halalas' is not null or x->>'balance_due_halalas' is not null or x->>'discount_halalas' is not null or x->>'nightly_rate_halalas' is not null or x->>'ban' is not null or x->>'rating' is not null)
    into money_seen from jsonb_array_elements(r->'rows') x;
  f := fn_reservation_list('00000000-0000-0000-0000-000000000010', '{"has_balance":"true"}'::jsonb, 1000, 0);
  perform t_record('LS05 housekeeping reads the list without money, bans or ratings, and the balance filter yields nothing for them (no inference from counts)',
    coalesce(money_seen, false) = false and (r->>'total')::int > 0 and (f->>'total')::int = 0, r->>'total' || ' rows; balance filter → ' || (f->>'total'));
exception when others then perform t_record('LS05 housekeeping reads the list without money, bans or ratings, and the balance filter yields nothing for them (no inference from counts)', false, sqlerrm); end $$;

-- branch scoping: a supervisor of branch 010 asking for branch B gets nothing; branch B's own supervisor gets its booking; the owner gets both
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
do $$ declare r jsonb; begin
  r := fn_reservation_list('00000000-0000-0000-0000-000000000012', '{}'::jsonb, 1000, 0);
  perform t_record('LS06 a supervisor of branch 010 gets no row of branch B', (r->>'total')::int = 0 and jsonb_array_length(r->'rows') = 0, r->>'total');
exception when others then perform t_record('LS06 a supervisor of branch 010 gets no row of branch B', false, sqlerrm); end $$;
select t_login('a0000000-0000-0000-0000-000000000006', 'supB@test.local');
do $$ declare r jsonb; o jsonb; begin
  r := fn_reservation_list('00000000-0000-0000-0000-000000000012', '{}'::jsonb, 1000, 0);
  o := fn_reservation_list('00000000-0000-0000-0000-000000000010', '{}'::jsonb, 1000, 0);
  perform t_record('LS07 branch B''s supervisor gets branch B''s booking and nothing of branch 010',
    (r->>'total')::int = t_count('select count(*) from reservations where branch_id = ''00000000-0000-0000-0000-000000000012''') and (r->'rows'->0->>'id')::uuid = t_id('res_b') and (o->>'total')::int = 0,
    r->>'total' || ' / ' || (o->>'total'));
exception when others then perform t_record('LS07 branch B''s supervisor gets branch B''s booking and nothing of branch 010', false, sqlerrm); end $$;
-- a visitor gets nothing at all
reset role;
select set_config('request.jwt.claim.sub', '', false), set_config('request.jwt.claims', '{"role":"anon"}', false);
set role anon;
select t_record('LS08 a visitor cannot call the list', t_fails('select fn_reservation_list(''00000000-0000-0000-0000-000000000010'', ''{}''::jsonb, 10, 0)', '%permission denied%') = 'ok',
                t_fails('select fn_reservation_list(''00000000-0000-0000-0000-000000000010'', ''{}''::jsonb, 10, 0)', '%permission denied%'));
reset role;

-- =====================================================================
-- SV. Saved views (decision 14): own rows only, one default, at most 20, archived not erased
-- =====================================================================
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
set role authenticated;
do $$ declare a jsonb; b jsonb; l jsonb; begin
  a := fn_saved_view_save('{"screen":"reservations","name":"الوصول اليوم","filters":{"check_in_from":"2026-01-01"},"columns":["internal_ref","guest_name"],"is_default":true}'::jsonb);
  b := fn_saved_view_save('{"screen":"reservations","name":"الشركات","filters":{"booking_type":"company"},"is_default":true}'::jsonb);
  perform t_set('view_a', (a->>'id')::uuid); perform t_set('view_b', (b->>'id')::uuid);
  l := fn_saved_views_list('reservations');
  perform t_record('SV01 two views saved; the second default replaces the first; the list is ordered default first and keeps filters and columns',
    jsonb_array_length(l) = 2 and (l->0->>'id')::uuid = (b->>'id')::uuid and (l->0->>'is_default')::boolean and not (l->1->>'is_default')::boolean
    and l->1->'columns' = '["internal_ref","guest_name"]'::jsonb and l->1->'filters'->>'check_in_from' = '2026-01-01', l::text);
exception when others then perform t_record('SV01 two views saved; the second default replaces the first; the list is ordered default first and keeps filters and columns', false, sqlerrm); end $$;
do $$ declare l jsonb; begin
  perform fn_saved_view_save(jsonb_build_object('id', t_id('view_a'), 'screen', 'reservations', 'name', 'الوصول اليوم (معدّل)', 'filters', '{"check_in_from":"2026-02-01"}'::jsonb));
  l := fn_saved_views_list('reservations');
  perform t_record('SV02 saving by id renames and replaces the filters without a new row', jsonb_array_length(l) = 2 and exists (select 1 from jsonb_array_elements(l) x where x->>'name' = 'الوصول اليوم (معدّل)' and x->'filters'->>'check_in_from' = '2026-02-01'), l::text);
exception when others then perform t_record('SV02 saving by id renames and replaces the filters without a new row', false, sqlerrm); end $$;
-- another person sees none of them, by function or by table; a bad screen or an empty name is refused
select t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
do $$ declare n int; begin
  select count(*) into n from staff_saved_views;
  perform t_record('SV03 another staff member sees no view of the supervisor (function and table), and a wrong screen or an empty name is refused',
    jsonb_array_length(fn_saved_views_list('reservations')) = 0 and n = 0
    and t_fails('select fn_saved_view_save(''{"screen":"nope","name":"x"}''::jsonb)', 'VALIDATION: screen%') = 'ok'
    and t_fails('select fn_saved_view_save(''{"screen":"audit","name":"  "}''::jsonb)', 'VALIDATION: name%') = 'ok'
    and t_fails(format('select fn_saved_view_remove(%L)', t_id('view_a')), 'NOT_FOUND%') = 'ok', n::text);
exception when others then perform t_record('SV03 another staff member sees no view of the supervisor (function and table), and a wrong screen or an empty name is refused', false, sqlerrm); end $$;
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
do $$ declare i int; m text; l jsonb; kept bigint; begin
  for i in 3..20 loop perform fn_saved_view_save(jsonb_build_object('screen', 'reservations', 'name', 'عرض ' || i)); end loop;
  m := t_fails('select fn_saved_view_save(''{"screen":"reservations","name":"الحادي والعشرون"}''::jsonb)', 'LIMIT: saved_views%');
  perform fn_saved_view_remove(t_id('view_b'));
  l := fn_saved_views_list('reservations');
  kept := t_count(format('select count(*) from staff_saved_views where id = %L and archived_at is not null', t_id('view_b')));
  perform fn_saved_view_save('{"screen":"reservations","name":"بعد الأرشفة"}'::jsonb);
  perform t_record('SV04 at most 20 live views per screen; removing one archives it (the row stays) and frees a place; no view is left default',
    m = 'ok' and jsonb_array_length(l) = 19 and kept = 1 and jsonb_array_length(fn_saved_views_list('reservations')) = 20
    and not exists (select 1 from jsonb_array_elements(fn_saved_views_list('reservations')) x where (x->>'is_default')::boolean), m || ' / ' || jsonb_array_length(l) || ' / kept ' || kept);
exception when others then perform t_record('SV04 at most 20 live views per screen; removing one archives it (the row stays) and frees a place; no view is left default', false, sqlerrm); end $$;

-- =====================================================================
-- CL. «تقويم الحجوزات» (decision 14, 10.2)
-- =====================================================================
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
select t_record('CL01 the window is at most 62 days and never reversed; another organisation''s branch is refused',
  t_fails(format('select fn_reservation_calendar(%L, %L, %L)', '00000000-0000-0000-0000-000000000010', t_today(), t_today() + 63), 'VALIDATION: range%') = 'ok'
  and t_fails(format('select fn_reservation_calendar(%L, %L, %L)', '00000000-0000-0000-0000-000000000010', t_today(), t_today() - 1), 'VALIDATION: range%') = 'ok'
  and t_fails(format('select fn_reservation_calendar(%L, %L, %L)', '00000000-0000-0000-0000-000000000011', t_today(), t_today() + 7), 'FORBIDDEN%') = 'ok');
do $$ declare c jsonb; d0 date := t_today() - 7; d1 date := t_today() + 21; units_ok boolean; seg_want bigint; seg_got int; clip_ok boolean; cancelled_in boolean; begin
  c := fn_reservation_calendar('00000000-0000-0000-0000-000000000010', d0, d1);
  units_ok := jsonb_array_length(c->'units') = t_count('select count(*) from rooms where branch_id = ''00000000-0000-0000-0000-000000000010'' and archived_at is null');
  seg_want := t_count(format('select count(*) from reservation_allocations a join reservations r on r.id = a.reservation_id where a.branch_id = %L and a.status in (''active'',''closed'') and r.status not in (''cancelled'',''rejected'',''no_show'') and a.from_date <= %L and a.to_date > %L', '00000000-0000-0000-0000-000000000010', d1, d0));
  seg_got := jsonb_array_length(c->'segments');
  select bool_and((x->>'from_date')::date >= d0 and (x->>'to_date')::date <= d1 + 1 and (x->>'from_date')::date < (x->>'to_date')::date
                  and ((x->>'starts_before')::boolean = ((x->>'from_date')::date = d0 and exists (select 1 from reservation_allocations a where a.reservation_id = (x->>'reservation_id')::uuid and a.room_id = (x->>'room_id')::uuid and a.from_date < d0))))
    into clip_ok from jsonb_array_elements(c->'segments') x;
  select bool_or(x->>'status' in ('cancelled', 'rejected', 'no_show')) into cancelled_in from jsonb_array_elements(c->'segments') x;
  perform t_record('CL02 the calendar lists every live unit of the branch and exactly the allocations that touch the window, clipped to it, with the before/after flags; nothing cancelled',
    units_ok and seg_want = seg_got and seg_got > 0 and coalesce(clip_ok, true) and coalesce(cancelled_in, false) = false and (c->>'today')::date = t_today(),
    'units ' || jsonb_array_length(c->'units') || ', segments ' || seg_got || ' vs ' || seg_want);
exception when others then perform t_record('CL02 the calendar lists every live unit of the branch and exactly the allocations that touch the window, clipped to it, with the before/after flags; nothing cancelled', false, sqlerrm); end $$;
select t_login('a0000000-0000-0000-0000-000000000003', 'hk@test.local');
do $$ declare c jsonb; money boolean; begin
  c := fn_reservation_calendar('00000000-0000-0000-0000-000000000010', t_today() - 7, t_today() + 21);
  select bool_or(x->>'payment_status' is not null or x->>'balance_due_halalas' is not null) into money from jsonb_array_elements(c->'segments') x;
  perform t_record('CL03 housekeeping sees the calendar (units, cleanliness, who is in) without payment states or balances', jsonb_array_length(c->'segments') > 0 and coalesce(money, false) = false and c->'units'->0 ? 'cleanliness', jsonb_array_length(c->'segments')::text);
exception when others then perform t_record('CL03 housekeeping sees the calendar (units, cleanliness, who is in) without payment states or balances', false, sqlerrm); end $$;
select t_login('a0000000-0000-0000-0000-000000000006', 'supB@test.local');
select t_record('CL04 branch B''s supervisor is refused the calendar of branch 010', t_fails(format('select fn_reservation_calendar(%L, %L, %L)', '00000000-0000-0000-0000-000000000010', t_today(), t_today() + 7), 'FORBIDDEN%') = 'ok');

-- =====================================================================
-- AL. The log (decision 14, 10.3) and X09c
-- =====================================================================
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
do $$ declare r jsonb; want uuid[]; got uuid[]; begin
  r := fn_audit_list('{}'::jsonb);
  want := t_ids('select id from audit_events where organization_id = ''00000000-0000-0000-0000-000000000001''');
  got := t_audit_ids('{}'::jsonb, 97);
  perform t_record('AL01 / X09c the owner''s unfiltered log: the total is the organisation''s whole log, the default page is 50, and the pages together are exactly the independent set',
    (r->>'total')::int = array_length(want, 1) and jsonb_array_length(r->'rows') = 50 and (r->>'limit')::int = 50 and want = got and array_length(got, 1) > 400,
    r->>'total' || ' rows, ' || array_length(got, 1) || ' through pages of 97');
exception when others then perform t_record('AL01 / X09c the owner''s unfiltered log: the total is the organisation''s whole log, the default page is 50, and the pages together are exactly the independent set', false, sqlerrm); end $$;
do $$ declare r jsonb; begin
  r := fn_audit_list('{"limit": 5000}'::jsonb);
  perform t_record('AL02 a page above 500 is capped, not refused; the total stays exact', jsonb_array_length(r->'rows') = 500 and (r->>'limit')::int = 500 and (r->>'total')::int > 500, r->>'total');
exception when others then perform t_record('AL02 a page above 500 is capped, not refused; the total stays exact', false, sqlerrm); end $$;
-- every filter against an independent query
do $$ declare f record; want uuid[]; got uuid[]; n int := 0; bad text := ''; anchor audit_events; begin
  select * into anchor from audit_events where organization_id = '00000000-0000-0000-0000-000000000001' and action = 'reservation.created' and branch_id = '00000000-0000-0000-0000-000000000010' order by created_at limit 1;
  for f in select * from (values
    ('branch', jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010'), 'branch_id = ''00000000-0000-0000-0000-000000000010'''),
    ('action exact', '{"action":"reservation.created"}'::jsonb, 'action = ''reservation.created'''),
    ('action prefix', '{"action":"reservation.","action_prefix":true}', 'action like ''reservation.%'''),
    ('entity type', '{"entity_type":"voucher"}', 'entity_type = ''voucher'''),
    ('entity id', jsonb_build_object('entity_id', anchor.entity_id), format('entity_id = %L', anchor.entity_id)),
    ('correlation', jsonb_build_object('correlation_id', anchor.correlation_id), format('correlation_id = %L', anchor.correlation_id)),
    ('actor', jsonb_build_object('actor_id', '10000000-0000-0000-0000-000000000002'), 'actor_id = ''10000000-0000-0000-0000-000000000002'''),
    ('category security', '{"category":"security"}', 'category = ''security'''),
    ('result rejected', '{"result":"rejected"}', 'result = ''rejected'''),
    ('source screen', '{"source":"screen"}', 'source = ''screen'''),
    ('today (branch day)', jsonb_build_object('from', t_today(), 'to', t_today()), format('(created_at at time zone ''Asia/Riyadh'')::date = %L', t_today())),
    ('before today', jsonb_build_object('to', t_today() - 1), format('(created_at at time zone ''Asia/Riyadh'')::date <= %L', t_today() - 1)),
    ('q by Arabic name', '{"q":"إنشاء حجز"}', 'action = ''reservation.created'''),
    ('q by entity id', jsonb_build_object('q', anchor.entity_id::text), format('entity_id = %L', anchor.entity_id))
  ) as t(name, filters, pred) loop
    want := t_ids('select id from audit_events where organization_id = ''00000000-0000-0000-0000-000000000001'' and ' || f.pred);
    got := t_audit_ids(f.filters, 41);
    if want = got then n := n + 1; else bad := bad || f.name || ' (' || coalesce(array_length(want, 1), 0) || ' vs ' || coalesce(array_length(got, 1), 0) || ') '; end if;
  end loop;
  perform t_record('AL03 / X09c every filter of the log (branch, action, prefix, entity, id, correlation, actor, category, result, source, day, name search) equals an independent query, read in pages of 41', bad = '', n || ' filters; ' || bad);
exception when others then perform t_record('AL03 / X09c every filter of the log (branch, action, prefix, entity, id, correlation, actor, category, result, source, day, name search) equals an independent query, read in pages of 41', false, sqlerrm); end $$;
-- readable names and references
do $$ declare r jsonb; row jsonb; vrow jsonb; begin
  r := fn_audit_list('{"action":"reservation.created","limit":1}'::jsonb);
  row := r->'rows'->0;
  vrow := fn_audit_list('{"action":"voucher.receipt_created","limit":1}'::jsonb)->'rows'->0;
  perform t_record('AL04 a row reads in Arabic: the action name, the entity name, the booking''s number as reference, the person''s name, the branch name; a voucher row names its number',
    row->>'action_label' = 'إنشاء حجز' and row->>'entity_label' = 'حجز' and row->>'entity_ref' = (select internal_ref from reservations where id = (row->>'entity_id')::uuid)
    and coalesce(row->>'actor_name', '') <> '' and row->>'branch_name' is not null and vrow->>'action_label' = 'إنشاء سند قبض' and vrow->>'entity_label' = 'سند'
    and vrow->>'entity_ref' = (select number from financial_vouchers where id = (vrow->>'entity_id')::uuid)
    and fn_audit_action_label('x.frobbed') = 'frobbed — x' and fn_audit_action_label('plain_code') = 'plain code' and fn_audit_action_label('room.deleted') = 'حذف وحدة',
    row::text);
exception when others then perform t_record('AL04 a row reads in Arabic: the action name, the entity name, the booking''s number as reference, the person''s name, the branch name; a voucher row names its number', false, sqlerrm); end $$;
-- the manager: business rows of their branches only, details included; the supervisor: no details; housekeeping and finance: refused
select t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
do $$ declare r jsonb; want uuid[]; got uuid[]; leak boolean; begin
  want := t_ids('select id from audit_events where organization_id = ''00000000-0000-0000-0000-000000000001'' and category <> ''security'' and (branch_id is null or branch_id = ''00000000-0000-0000-0000-000000000010'')');
  got := t_audit_ids('{}'::jsonb, 150);
  r := fn_audit_list('{"category":"security"}'::jsonb);
  select bool_or(x->>'branch_id' = '00000000-0000-0000-0000-000000000012' or x->>'category' = 'security') into leak from jsonb_array_elements(fn_audit_list('{"limit":500}'::jsonb)->'rows') x;
  perform t_record('AL05 / X09c the manager''s log is exactly the business rows of their branch (and the branch-less ones): no security row even when asked for, no branch B row, details included',
    want = got and (r->>'total')::int = 0 and coalesce(leak, false) = false and array_length(got, 1) > 100
    and exists (select 1 from jsonb_array_elements(fn_audit_list('{"action":"reservation.created","limit":5}'::jsonb)->'rows') x where x->'details' is not null and x->'details' <> 'null'::jsonb), array_length(got, 1)::text);
exception when others then perform t_record('AL05 / X09c the manager''s log is exactly the business rows of their branch (and the branch-less ones): no security row even when asked for, no branch B row, details included', false, sqlerrm); end $$;
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
do $$ declare r jsonb; det boolean; begin
  r := fn_audit_list('{"limit":500}'::jsonb);
  select bool_or(x->'details' is not null and x->'details' <> 'null'::jsonb) into det from jsonb_array_elements(r->'rows') x;
  perform t_record('AL06 the supervisor reads the log without the details column (names, references and reasons only)', (r->>'total')::int > 0 and coalesce(det, false) = false, r->>'total');
exception when others then perform t_record('AL06 the supervisor reads the log without the details column (names, references and reasons only)', false, sqlerrm); end $$;
select t_login('a0000000-0000-0000-0000-000000000003', 'hk@test.local');
select t_record('AL07 housekeeping and finance are refused the log', t_fails('select fn_audit_list(''{}''::jsonb)', 'FORBIDDEN%') = 'ok');

-- =====================================================================
-- VL. The ledger (decision 14, 10.4) and X09a: filters, pages, totals over the whole set
-- =====================================================================
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
do $$ declare r jsonb; want uuid[]; got uuid[]; sum_want bigint; begin
  r := fn_voucher_list('{"branch_id":"00000000-0000-0000-0000-000000000010"}'::jsonb);
  want := t_ids('select id from financial_vouchers where branch_id = ''00000000-0000-0000-0000-000000000010'' and status = ''approved''');
  got := t_voucher_ids('{"branch_id":"00000000-0000-0000-0000-000000000010"}'::jsonb, 9);
  sum_want := t_count('select coalesce(sum(amount_halalas), 0) from financial_vouchers where branch_id = ''00000000-0000-0000-0000-000000000010'' and status = ''approved'' and kind = ''receipt''');
  perform t_record('VL01 / X09a the ledger of a branch: approved by default, the exact total, pages of 9 add up to the independent set, and the receipts total is summed over the whole set (not the page)',
    (r->>'total')::int = array_length(want, 1) and want = got and (r->'totals'->>'receipts')::bigint = sum_want and (r->'totals'->>'approved')::int = array_length(want, 1)
    and (r->'totals'->>'cancelled')::int = 0 and jsonb_array_length(r->'rows') = least(array_length(want, 1), 100),
    r->>'total' || ' vouchers, receipts ' || (r->'totals'->>'receipts'));
exception when others then perform t_record('VL01 / X09a the ledger of a branch: approved by default, the exact total, pages of 9 add up to the independent set, and the receipts total is summed over the whole set (not the page)', false, sqlerrm); end $$;
do $$ declare f record; want uuid[]; got uuid[]; n int := 0; bad text := ''; some_number text; some_res uuid; begin
  select number, reservation_id into some_number, some_res from financial_vouchers where branch_id = '00000000-0000-0000-0000-000000000010' and status = 'approved' and reservation_id is not null order by created_at limit 1;
  for f in select * from (values
    ('kind deposit', '{"kind":"deposit"}'::jsonb, 'status = ''approved'' and kind = ''deposit'''),
    ('method cash', '{"method":"cash"}', 'status = ''approved'' and method = ''cash'''),
    ('method pos', '{"method":"pos"}', 'status = ''approved'' and method = ''pos'''),
    ('account (box)', jsonb_build_object('account_id', t_id('box')), format('status = ''approved'' and account_id = %L', t_id('box'))),
    ('account none', '{"account_id":"none"}', 'status = ''approved'' and account_id is null'),
    ('status cancelled', '{"status":"cancelled"}', 'status = ''cancelled'''),
    ('status all', '{"status":"all"}', 'true'),
    ('staff', '{"staff_id":"10000000-0000-0000-0000-000000000002"}', 'status = ''approved'' and created_by = ''10000000-0000-0000-0000-000000000002'''),
    ('reservation', jsonb_build_object('reservation_id', some_res), format('status = ''approved'' and reservation_id = %L', some_res)),
    ('today (branch day)', jsonb_build_object('from', t_today(), 'to', t_today()), format('status = ''approved'' and (occurred_at at time zone ''Asia/Riyadh'')::date = %L', t_today())),
    ('q by number', jsonb_build_object('q', some_number), format('status = ''approved'' and number ilike %L', '%' || some_number || '%'))
  ) as t(name, filters, pred) loop
    want := t_ids('select id from financial_vouchers where branch_id = ''00000000-0000-0000-0000-000000000010'' and ' || f.pred);
    got := t_voucher_ids(f.filters || '{"branch_id":"00000000-0000-0000-0000-000000000010"}'::jsonb, 4);
    if want = got then n := n + 1; else bad := bad || f.name || ' (' || coalesce(array_length(want, 1), 0) || ' vs ' || coalesce(array_length(got, 1), 0) || ') '; end if;
  end loop;
  perform t_record('VL02 / X09a every filter of the ledger (kind, method, account, no account, status, staff, booking, day, number) equals an independent query, read in pages of 4', bad = '', n || ' filters; ' || bad);
exception when others then perform t_record('VL02 / X09a every filter of the ledger (kind, method, account, no account, status, staff, booking, day, number) equals an independent query, read in pages of 4', false, sqlerrm); end $$;
do $$ declare r jsonb; cash bigint; box_in bigint; begin
  r := fn_voucher_list('{"branch_id":"00000000-0000-0000-0000-000000000010","limit":1}'::jsonb);
  cash := t_count('select coalesce(sum(amount_halalas), 0) from financial_vouchers where branch_id = ''00000000-0000-0000-0000-000000000010'' and status = ''approved'' and kind = ''receipt'' and method = ''cash''');
  box_in := t_count(format('select coalesce(sum(amount_halalas), 0) from financial_vouchers where branch_id = ''00000000-0000-0000-0000-000000000010'' and status = ''approved'' and kind in (''receipt'',''deposit'') and account_id = %L', t_id('box')));
  perform t_record('VL03 the by-method and by-account totals are over the whole filtered set even when the page holds one row',
    jsonb_array_length(r->'rows') = 1 and (select (x->>'amount_halalas')::bigint from jsonb_array_elements(r->'totals'->'by_method') x where x->>'method' = 'cash') = cash
    and (select (x->>'in_halalas')::bigint from jsonb_array_elements(r->'totals'->'by_account') x where (x->>'account_id')::uuid = t_id('box')) = box_in,
    'cash ' || cash || ', box in ' || box_in);
exception when others then perform t_record('VL03 the by-method and by-account totals are over the whole filtered set even when the page holds one row', false, sqlerrm); end $$;
select t_record('VL04 the ledger needs a branch, a sane period and a known status',
  t_fails('select fn_voucher_list(''{}''::jsonb)', 'VALIDATION: branch_id%') = 'ok'
  and t_fails('select fn_voucher_list(''{"branch_id":"00000000-0000-0000-0000-000000000010","from":"2026-02-02","to":"2026-02-01"}''::jsonb)', 'VALIDATION: period%') = 'ok'
  and t_fails('select fn_voucher_list(''{"branch_id":"00000000-0000-0000-0000-000000000010","status":"weird"}''::jsonb)', 'VALIDATION: status%') = 'ok');
do $$ declare hk text; supb text; fin int; begin
  perform t_login('a0000000-0000-0000-0000-000000000003', 'hk@test.local');
  hk := t_fails('select fn_voucher_list(''{"branch_id":"00000000-0000-0000-0000-000000000010"}''::jsonb)', 'FORBIDDEN%');
  perform t_login('a0000000-0000-0000-0000-000000000006', 'supB@test.local');
  supb := t_fails('select fn_voucher_list(''{"branch_id":"00000000-0000-0000-0000-000000000010"}''::jsonb)', 'FORBIDDEN%');
  perform t_login('a0000000-0000-0000-0000-000000000004', 'fin@test.local');
  fin := (fn_voucher_list('{"branch_id":"00000000-0000-0000-0000-000000000010"}'::jsonb)->>'total')::int;
  perform t_record('VL05 housekeeping is refused the ledger; branch B''s supervisor is refused branch 010''s; finance reads it', hk = 'ok' and supb = 'ok' and fin > 0, hk || ' / ' || supb || ' / ' || fin);
exception when others then perform t_record('VL05 housekeeping is refused the ledger; branch B''s supervisor is refused branch 010''s; finance reads it', false, sqlerrm); end $$;

-- =====================================================================
-- RP. Reports with filters (decision 36) and X09d
-- =====================================================================
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
do $$ declare d0 date := t_today() - 30; d1 date := t_today(); r jsonb; u jsonb; want bigint; begin
  u := fn_reports_finance('00000000-0000-0000-0000-000000000010', d0, d1, '{}'::jsonb);
  r := fn_reports_finance('00000000-0000-0000-0000-000000000010', d0, d1, '{"staff_id":"10000000-0000-0000-0000-000000000002"}'::jsonb);
  want := t_count(format('select coalesce(sum(amount_halalas), 0) from financial_vouchers where branch_id = %L and status = ''approved'' and kind = ''receipt'' and created_by = %L and (occurred_at at time zone ''Asia/Riyadh'')::date between %L and %L',
                  '00000000-0000-0000-0000-000000000010', '10000000-0000-0000-0000-000000000002', d0, d1));
  perform t_record('RP01 / X09d the finance report by staff member: receipts equal the independent sum, by_staff holds that person only, the collection rate is not claimed, filtered is flagged; unfiltered it is not',
    (r->'ledger'->>'receipts')::bigint = want and want > 0 and (r->'ledger'->>'receipts')::bigint < (u->'ledger'->>'receipts')::bigint
    and jsonb_array_length(r->'by_staff') = 1 and r->'by_staff'->0->>'staff_id' = '10000000-0000-0000-0000-000000000002' and r->>'collection_rate_pct' is null
    and (r->>'filtered')::boolean and not (u->>'filtered')::boolean and u->>'collection_rate_pct' is not null and r->'filters'->>'staff_id' = '10000000-0000-0000-0000-000000000002',
    'staff ' || want || ' of ' || (u->'ledger'->>'receipts'));
exception when others then perform t_record('RP01 / X09d the finance report by staff member: receipts equal the independent sum, by_staff holds that person only, the collection rate is not claimed, filtered is flagged; unfiltered it is not', false, sqlerrm); end $$;
do $$ declare d0 date := t_today() - 30; d1 date := t_today(); r jsonb; want bigint; a jsonb; want_a bigint; nn jsonb; want_n bigint; begin
  r := fn_reports_finance('00000000-0000-0000-0000-000000000010', d0, d1, '{"method":"cash"}'::jsonb);
  want := t_count(format('select coalesce(sum(amount_halalas), 0) from financial_vouchers where branch_id = %L and status = ''approved'' and kind = ''receipt'' and method = ''cash'' and (occurred_at at time zone ''Asia/Riyadh'')::date between %L and %L', '00000000-0000-0000-0000-000000000010', d0, d1));
  a := fn_reports_finance('00000000-0000-0000-0000-000000000010', d0, d1, jsonb_build_object('account_id', t_id('box')));
  want_a := t_count(format('select coalesce(sum(amount_halalas), 0) from financial_vouchers where branch_id = %L and status = ''approved'' and kind = ''receipt'' and account_id = %L and (occurred_at at time zone ''Asia/Riyadh'')::date between %L and %L', '00000000-0000-0000-0000-000000000010', t_id('box'), d0, d1));
  nn := fn_reports_finance('00000000-0000-0000-0000-000000000010', d0, d1, '{"account_id":"none"}'::jsonb);
  want_n := t_count(format('select coalesce(sum(amount_halalas), 0) from financial_vouchers where branch_id = %L and status = ''approved'' and kind = ''receipt'' and account_id is null and (occurred_at at time zone ''Asia/Riyadh'')::date between %L and %L', '00000000-0000-0000-0000-000000000010', d0, d1));
  perform t_record('RP02 / X09d by payment method, by box or account, and «بلا صندوق»: each total equals its independent sum; by_method holds the one method',
    (r->'ledger'->>'receipts')::bigint = want and jsonb_array_length(r->'by_method') = 1 and r->'by_method'->0->>'method' = 'cash'
    and (a->'ledger'->>'receipts')::bigint = want_a and jsonb_array_length(a->'by_account') = 1 and (nn->'ledger'->>'receipts')::bigint = want_n and jsonb_array_length(nn->'by_account') = 0,
    'cash ' || want || ', box ' || want_a || ', none ' || want_n);
exception when others then perform t_record('RP02 / X09d by payment method, by box or account, and «بلا صندوق»: each total equals its independent sum; by_method holds the one method', false, sqlerrm); end $$;
do $$ declare d0 date := t_today() - 30; d1 date := t_today(); r jsonb; want_cnt bigint; want_rc bigint; c jsonb; want_c bigint; begin
  r := fn_reports_finance('00000000-0000-0000-0000-000000000010', d0, d1, '{"source_id":"00000000-0000-0000-0000-000000000020"}'::jsonb);
  want_cnt := t_count(format('select count(*) from reservations where branch_id = %L and source_id = ''00000000-0000-0000-0000-000000000020'' and check_in <= %L and check_out > %L', '00000000-0000-0000-0000-000000000010', d1, d0));
  want_rc := t_count(format('select coalesce(sum(v.amount_halalas), 0) from financial_vouchers v join reservations x on x.id = v.reservation_id where v.branch_id = %L and v.status = ''approved'' and v.kind = ''receipt'' and x.source_id = ''00000000-0000-0000-0000-000000000020'' and (v.occurred_at at time zone ''Asia/Riyadh'')::date between %L and %L', '00000000-0000-0000-0000-000000000010', d0, d1));
  c := fn_reports_finance('00000000-0000-0000-0000-000000000010', d0, d1, '{"category_id":"00000000-0000-0000-0000-000000000030"}'::jsonb);
  want_c := t_count(format('select count(*) from reservations where branch_id = %L and room_category_id = ''00000000-0000-0000-0000-000000000030'' and check_in <= %L and check_out > %L', '00000000-0000-0000-0000-000000000010', d1, d0));
  perform t_record('RP03 / X09d by booking source and by unit type: the bookings counted and the receipts summed follow the filter (receipts through the voucher''s booking)',
    (r->'reservations'->>'count')::int = want_cnt and (r->'ledger'->>'receipts')::bigint = want_rc and jsonb_array_length(r->'reservations'->'by_source') <= 1
    and (c->'reservations'->>'count')::int = want_c, want_cnt || ' bookings, ' || want_rc || ' receipts; type ' || want_c);
exception when others then perform t_record('RP03 / X09d by booking source and by unit type: the bookings counted and the receipts summed follow the filter (receipts through the voucher''s booking)', false, sqlerrm); end $$;
do $$ declare d0 date := t_today() - 30; d1 date := t_today(); r jsonb; u jsonb; want bigint; aft jsonb; want_aft bigint; begin
  u := fn_reports_discounts('00000000-0000-0000-0000-000000000010', d0, d1, '{}'::jsonb);
  r := fn_reports_discounts('00000000-0000-0000-0000-000000000010', d0, d1, '{"staff_id":"10000000-0000-0000-0000-000000000002"}'::jsonb);
  want := t_count(format('select count(*) from reservation_charges where branch_id = %L and kind = ''discount'' and created_by = %L and (created_at at time zone ''Asia/Riyadh'')::date between %L and %L', '00000000-0000-0000-0000-000000000010', '10000000-0000-0000-0000-000000000002', d0, d1));
  aft := fn_reports_discounts('00000000-0000-0000-0000-000000000010', d0, d1, '{"after_arrival":true}'::jsonb);
  want_aft := t_count(format('select count(*) from reservation_charges ch join reservations x on x.id = ch.reservation_id where ch.branch_id = %L and ch.kind = ''discount'' and x.actual_check_in is not null and ch.created_at >= x.actual_check_in and (ch.created_at at time zone ''Asia/Riyadh'')::date between %L and %L', '00000000-0000-0000-0000-000000000010', d0, d1));
  perform t_record('RP04 / X09d the discounts report by staff member and «بعد الوصول»: counts equal independent queries; rows and by_staff follow',
    (r->>'count')::int = want and (u->>'count')::int >= want and jsonb_array_length(r->'rows') = want and (aft->>'count')::int = want_aft and jsonb_array_length(aft->'rows') = want_aft
    and (want = 0 or jsonb_array_length(r->'by_staff') = 1), 'staff ' || want || ' of ' || (u->>'count') || '; after arrival ' || want_aft);
exception when others then perform t_record('RP04 / X09d the discounts report by staff member and «بعد الوصول»: counts equal independent queries; rows and by_staff follow', false, sqlerrm); end $$;
do $$ declare d0 date := t_today() - 30; d1 date := t_today(); l jsonb; want bigint; i jsonb; want_i bigint; begin
  l := fn_reports_late_entries('00000000-0000-0000-0000-000000000010', d0, d1, 0, '{"staff_id":"10000000-0000-0000-0000-000000000002"}'::jsonb);
  want := t_count(format('select count(*) from reservations r join booking_sources s on s.id = r.source_id and s.kind = ''external'' where r.branch_id = %L and r.platform_booked_on is not null and r.created_by = %L and (r.created_at at time zone ''Asia/Riyadh'')::date between %L and %L', '00000000-0000-0000-0000-000000000010', '10000000-0000-0000-0000-000000000002', d0, d1));
  i := fn_reports_identities('00000000-0000-0000-0000-000000000010', d0, d1, 'all', '{"staff_id":"10000000-0000-0000-0000-000000000002"}'::jsonb);
  want_i := t_count(format('select count(*) from reservation_guests g join reservations r on r.id = g.reservation_id where r.branch_id = %L and g.verification_status = ''verified'' and g.verified_by = %L and (g.verified_at at time zone ''Asia/Riyadh'')::date between %L and %L', '00000000-0000-0000-0000-000000000010', '10000000-0000-0000-0000-000000000002', d0, d1));
  perform t_record('RP05 / X09d the late-entries and identities reports by staff member equal independent queries and echo their filters',
    (l->>'platform_bookings')::int = want and (i->>'count')::int = want_i and l->'filters'->>'staff_id' = '10000000-0000-0000-0000-000000000002' and i->'filters'->>'path' = 'all',
    'platform ' || want || ', identities ' || want_i);
exception when others then perform t_record('RP05 / X09d the late-entries and identities reports by staff member equal independent queries and echo their filters', false, sqlerrm); end $$;
do $$ declare o jsonb; begin
  o := fn_report_filter_options('00000000-0000-0000-0000-000000000010');
  perform t_record('RP06 the filter options of a branch: its staff (the owner and the members, the deactivated marked), its boxes and accounts, the organisation''s sources, its unit types and floors',
    exists (select 1 from jsonb_array_elements(o->'staff') x where x->>'id' = '10000000-0000-0000-0000-000000000001')
    and exists (select 1 from jsonb_array_elements(o->'staff') x where x->>'id' = '10000000-0000-0000-0000-000000000007' and not (x->>'is_active')::boolean)
    and not exists (select 1 from jsonb_array_elements(o->'staff') x where x->>'id' = '10000000-0000-0000-0000-000000000006')
    and jsonb_array_length(o->'accounts') >= 3 and jsonb_array_length(o->'sources') >= 12 and jsonb_array_length(o->'categories') > 0 and o ? 'floors',
    jsonb_array_length(o->'staff') || ' staff');
exception when others then perform t_record('RP06 the filter options of a branch: its staff (the owner and the members, the deactivated marked), its boxes and accounts, the organisation''s sources, its unit types and floors', false, sqlerrm); end $$;
select t_login('a0000000-0000-0000-0000-000000000006', 'supB@test.local');
select t_record('RP07 branch B''s supervisor gets no options for branch 010 and is refused its reports',
  fn_report_filter_options('00000000-0000-0000-0000-000000000010') = '{}'::jsonb
  and t_fails(format('select fn_reports_finance(%L, %L, %L, ''{}''::jsonb)', '00000000-0000-0000-0000-000000000010', t_today() - 7, t_today()), 'FORBIDDEN%') = 'ok');
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
select t_record('RP08 the report signatures without filters are gone (0041): one call resolves to one function',
  t_fails(format('select fn_reports_finance(%L, %L, %L)', '00000000-0000-0000-0000-000000000010', t_today() - 7, t_today()), '%does not exist%') = 'ok'
  and t_fails(format('select fn_reports_discounts(%L, %L, %L)', '00000000-0000-0000-0000-000000000010', t_today() - 7, t_today()), '%does not exist%') = 'ok'
  and t_fails(format('select fn_reports_late_entries(%L, %L, %L, 1)', '00000000-0000-0000-0000-000000000010', t_today() - 7, t_today()), '%does not exist%') = 'ok'
  and t_fails(format('select fn_reports_identities(%L, %L, %L, ''office'')', '00000000-0000-0000-0000-000000000010', t_today() - 7, t_today()), '%does not exist%') = 'ok');

-- =====================================================================
-- TS. The task's start and end (decision 28)
-- =====================================================================
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
do $$ declare r jsonb; t housekeeping_tasks; begin
  r := fn_hk_create_task(jsonb_build_object('room_id', '00000000-0000-0000-0000-000000000102', 'task_type_id', '00000000-0000-0000-0000-000000000420', 'description', 'بلا موعد'));
  t := t_task((r->>'id')::uuid);
  perform t_set('task_now', t.id);
  perform t_record('TS01 a task without a start gets «الآن» as its start and no end', t.scheduled_start is not null and t.scheduled_start between now() - interval '1 minute' and now() + interval '1 second' and t.scheduled_end is null, t.scheduled_start::text);
exception when others then perform t_record('TS01 a task without a start gets «الآن» as its start and no end', false, sqlerrm); end $$;
do $$ declare r jsonb; t housekeeping_tasks; s timestamptz := date_trunc('hour', now()) + interval '1 day'; begin
  r := fn_hk_create_task(jsonb_build_object('room_id', '00000000-0000-0000-0000-000000000102', 'task_type_id', '00000000-0000-0000-0000-000000000420', 'scheduled_start', s, 'scheduled_end', s + interval '2 hours', 'description', 'بموعد'));
  t := t_task((r->>'id')::uuid);
  perform t_record('TS02 a planned start and end are kept as given; an end before the start is refused',
    t.scheduled_start = s and t.scheduled_end = s + interval '2 hours'
    and t_fails(format('select fn_hk_create_task(%L::jsonb)', jsonb_build_object('room_id', '00000000-0000-0000-0000-000000000102', 'task_type_id', '00000000-0000-0000-0000-000000000420', 'scheduled_start', s, 'scheduled_end', s - interval '1 hour')), 'VALIDATION: schedule%') = 'ok',
    t.scheduled_start || ' → ' || t.scheduled_end);
exception when others then perform t_record('TS02 a planned start and end are kept as given; an end before the start is refused', false, sqlerrm); end $$;
-- no reminder and no automatic end: a task whose end has passed is still open
do $$ declare r jsonb; t housekeeping_tasks; begin
  r := fn_hk_create_task(jsonb_build_object('room_id', '00000000-0000-0000-0000-000000000102', 'task_type_id', '00000000-0000-0000-0000-000000000420', 'scheduled_start', now() - interval '3 hours', 'scheduled_end', now() - interval '1 hour', 'description', 'انتهى موعدها'));
  t := t_task((r->>'id')::uuid);
  perform t_record('TS03 a task past its planned end stays open (no automatic end, no late flag on the server)', t.status = 'pending' and t.completed_at is null and t.scheduled_end < now(), t.status);
exception when others then perform t_record('TS03 a task past its planned end stays open (no automatic end, no late flag on the server)', false, sqlerrm); end $$;

-- =====================================================================
-- ST. Staff: the list, «تعديل موظف», activation, «تسجيل خروج إجباري» (decisions 34, 35)
-- =====================================================================
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
do $$ declare r jsonb; begin
  r := fn_staff_invite('p6-staff@test.local', 'موظف المرحلة 6', 'supervisor', array['00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000012']::uuid[]);
  perform t_set('p6', (r->>'staff_id')::uuid);
exception when others then perform t_record('fixture: invite a staff member for the editor tests', false, sqlerrm); end $$;
do $$ declare l jsonb; me jsonb; p6 jsonb; begin
  l := fn_admin_staff_list();
  select x into me from jsonb_array_elements(l) x where x->>'id' = '10000000-0000-0000-0000-000000000001';
  select x into p6 from jsonb_array_elements(l) x where (x->>'id')::uuid = t_id('p6');
  perform t_record('ST01 the owner''s staff list: everyone of the organisation with role, activity, link state, branches, and «أنا» on the owner''s own row',
    (me->>'is_me')::boolean and me ? 'phone' and p6->'branch_ids' @> '["00000000-0000-0000-0000-000000000010","00000000-0000-0000-0000-000000000012"]'::jsonb and not (p6->>'linked')::boolean
    and not exists (select 1 from jsonb_array_elements(l) x where x->>'id' = '10000000-0000-0000-0000-000000000005'), jsonb_array_length(l) || ' staff');
exception when others then perform t_record('ST01 the owner''s staff list: everyone of the organisation with role, activity, link state, branches, and «أنا» on the owner''s own row', false, sqlerrm); end $$;
select t_record('ST02 the editor refuses: no reason, an email change, the guest role, an unknown staff member',
  t_fails(format('select fn_admin_update_staff(%L::jsonb)', jsonb_build_object('staff_id', t_id('p6'), 'full_name', 'x')), 'VALIDATION: reason%') = 'ok'
  and t_fails(format('select fn_admin_update_staff(%L::jsonb)', jsonb_build_object('staff_id', t_id('p6'), 'email', 'other@test.local', 'reason', 'اختبار')), 'EMAIL_NOT_EDITABLE%') = 'ok'
  and t_fails(format('select fn_admin_update_staff(%L::jsonb)', jsonb_build_object('staff_id', t_id('p6'), 'role', 'guest', 'reason', 'اختبار')), 'INVALID_ROLE%') = 'ok'
  and t_fails(format('select fn_admin_update_staff(%L::jsonb)', jsonb_build_object('staff_id', gen_random_uuid(), 'full_name', 'x', 'reason', 'اختبار')), 'NOT_FOUND%') = 'ok');
do $$ declare r jsonb; sp staff_profiles; a audit_events; m record; begin
  r := fn_admin_update_staff(jsonb_build_object('staff_id', t_id('p6'), 'full_name', 'موظف المرحلة 6 (معدّل)', 'phone', '+966 50 000 1234', 'branch_ids', jsonb_build_array('00000000-0000-0000-0000-000000000010'), 'reason', 'نقل إلى فرع واحد'));
  sp := t_staff(t_id('p6'));
  a := t_audit_last('staff.updated', t_id('p6'));
  select * into m from t_membership_rows(t_id('p6'), '00000000-0000-0000-0000-000000000012');
  perform t_record('ST03 «تعديل موظف»: name, phone and branches change in one call; the branch removed is retired (the row stays, removed_at set); one audit row with before, after, what changed, the reason, the phone masked',
    sp.full_name = 'موظف المرحلة 6 (معدّل)' and sp.phone = '+966500001234' and r->'changed' @> '["full_name","phone","branches"]'::jsonb
    and m.n = 1 and m.removed = 1
    and a.category = 'security' and a.details->>'reason' = 'نقل إلى فرع واحد' and a.details->'before'->'branch_ids' @> '["00000000-0000-0000-0000-000000000012"]'::jsonb
    and a.details->'after'->'branch_ids' = '["00000000-0000-0000-0000-000000000010"]'::jsonb and a.details->'after'->>'phone' = '••••1234' and a.details::text not like '%500001234%'
    and a.details->'before'->>'full_name' = 'موظف المرحلة 6' and a.actor_id = '10000000-0000-0000-0000-000000000001',
    r::text || ' ' || a.details::text);
exception when others then perform t_record('ST03 «تعديل موظف»: name, phone and branches change in one call; the branch removed is retired (the row stays, removed_at set); one audit row with before, after, what changed, the reason, the phone masked', false, sqlerrm); end $$;
do $$ declare r jsonb; m record; begin
  r := fn_admin_update_staff(jsonb_build_object('staff_id', t_id('p6'), 'branch_ids', jsonb_build_array('00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000012'), 'reason', 'إعادة الفرع'));
  select * into m from t_membership_rows(t_id('p6'), '00000000-0000-0000-0000-000000000012');
  perform t_record('ST04 giving the branch back re-opens the same membership row (no duplicate, removed_at cleared); an identical call again changes nothing',
    r->'changed' = '["branches"]'::jsonb and m.n = 1 and m.removed = 0
    and (fn_admin_update_staff(jsonb_build_object('staff_id', t_id('p6'), 'branch_ids', jsonb_build_array('00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000012'), 'reason', 'لا شيء'))->>'unchanged')::boolean,
    r::text);
exception when others then perform t_record('ST04 giving the branch back re-opens the same membership row (no duplicate, removed_at cleared); an identical call again changes nothing', false, sqlerrm); end $$;
do $$ declare r jsonb; a audit_events; begin
  r := fn_admin_update_staff(jsonb_build_object('staff_id', t_id('p6'), 'role', 'manager', 'reason', 'ترقية'));
  a := t_audit_last('staff.role_changed', t_id('p6'));
  perform t_record('ST05 a role change is its own audit action with before and after and the reason',
    r->'changed' = '["role"]'::jsonb and (t_staff(t_id('p6'))).role = 'manager' and a.details->'before'->>'role' = 'supervisor' and a.details->'after'->>'role' = 'manager' and a.details->>'reason' = 'ترقية', a.details::text);
exception when others then perform t_record('ST05 a role change is its own audit action with before and after and the reason', false, sqlerrm); end $$;
select t_record('ST06 no one edits their own role or branches, even the owner; their own name is fine',
  t_fails(format('select fn_admin_update_staff(%L::jsonb)', jsonb_build_object('staff_id', '10000000-0000-0000-0000-000000000001', 'role', 'manager', 'reason', 'اختبار')), 'SELF_ROLE_OR_BRANCHES%') = 'ok'
  and t_fails(format('select fn_admin_update_staff(%L::jsonb)', jsonb_build_object('staff_id', '10000000-0000-0000-0000-000000000001', 'branch_ids', jsonb_build_array('00000000-0000-0000-0000-000000000010'), 'reason', 'اختبار')), 'SELF_ROLE_OR_BRANCHES%') = 'ok'
  and (fn_admin_update_staff(jsonb_build_object('staff_id', '10000000-0000-0000-0000-000000000001', 'full_name', 'المالك', 'reason', 'الاسم نفسه'))->>'unchanged')::boolean);
-- the retired membership takes effect at once: the supervisor loses branch 2d1b… before their next operation
do $$ declare before_n int; after_n int; r jsonb; keep uuid[]; begin
  select coalesce(array_agg(m.branch_id), '{}') into keep from branch_memberships m where m.staff_id = '10000000-0000-0000-0000-000000000002' and m.removed_at is null;
  r := fn_admin_update_staff(jsonb_build_object('staff_id', '10000000-0000-0000-0000-000000000002', 'branch_ids', to_jsonb(keep || '00000000-0000-0000-0000-000000000012'::uuid), 'reason', 'إضافة فرع B'));
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  select count(*) into before_n from fn_user_branch_ids() b where b = '00000000-0000-0000-0000-000000000012';
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  r := fn_admin_update_staff(jsonb_build_object('staff_id', '10000000-0000-0000-0000-000000000002', 'branch_ids', to_jsonb(keep), 'reason', 'سحب فرع B'));
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  select count(*) into after_n from fn_user_branch_ids() b where b = '00000000-0000-0000-0000-000000000012';
  perform t_record('ST07 a branch taken away is gone from the person''s branches at their very next request (no cached membership on the server); branch 010 stays',
    before_n = 1 and after_n = 0 and exists (select 1 from fn_user_branch_ids() b where b = '00000000-0000-0000-0000-000000000010')
    and t_fails(format('select fn_reservation_calendar(%L, %L, %L)', '00000000-0000-0000-0000-000000000012', t_today(), t_today() + 7), 'FORBIDDEN%') = 'ok', before_n || ' → ' || after_n);
exception when others then perform t_record('ST07 a branch taken away is gone from the person''s branches at their very next request (no cached membership on the server); branch 010 stays', false, sqlerrm); end $$;
select t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
do $$ declare l jsonb; begin
  l := fn_admin_staff_list();
  perform t_record('ST08 the manager reads the staff list without phones and cannot edit, activate or deactivate anyone',
    jsonb_array_length(l) > 0 and not exists (select 1 from jsonb_array_elements(l) x where x->>'phone' is not null)
    and t_fails(format('select fn_admin_update_staff(%L::jsonb)', jsonb_build_object('staff_id', t_id('p6'), 'full_name', 'x', 'reason', 'اختبار')), 'FORBIDDEN%') = 'ok'
    and t_fails(format('select fn_admin_set_staff_active(%L, false, ''اختبار'')', t_id('p6')), 'FORBIDDEN%') = 'ok', jsonb_array_length(l)::text);
exception when others then perform t_record('ST08 the manager reads the staff list without phones and cannot edit, activate or deactivate anyone', false, sqlerrm); end $$;
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
select t_record('ST09 the supervisor gets an empty staff list and is refused the forced sign-out',
  fn_admin_staff_list() = '[]'::jsonb and t_fails(format('select fn_admin_force_logout(%L, ''اختبار'')', t_id('p6')), 'FORBIDDEN%') = 'ok');

-- forced sign-out: every session of the person ends now, on every device; the account stays active
reset role;
select t_set('sess1', t_session_open('a0000000-0000-0000-0000-000000000002')), t_set('sess2', t_session_open('a0000000-0000-0000-0000-000000000002'));
select t_login_session('a0000000-0000-0000-0000-000000000002', 'sup@test.local', t_id('sess1'));
set role authenticated;
select t_record('ST10 a token that names an open session is a staff member as before', fn_staff_id() = '10000000-0000-0000-0000-000000000002' and (fn_reservation_list('00000000-0000-0000-0000-000000000010', '{}'::jsonb, 1, 0)->>'total')::int > 0);
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
do $$ declare r jsonb; a audit_events; sp staff_profiles; begin
  r := fn_admin_force_logout('10000000-0000-0000-0000-000000000002', 'جهاز مفقود');
  a := t_audit_last('staff.signed_out', '10000000-0000-0000-0000-000000000002');
  sp := t_staff('10000000-0000-0000-0000-000000000002');
  perform t_record('ST11 «تسجيل خروج إجباري» ends both sessions (timeboxed now, refresh tokens revoked), keeps the account active, and is logged as a security event with the reason and who did it',
    (r->>'sessions_ended')::int = 2 and t_session_ended(t_id('sess1')) and t_session_ended(t_id('sess2')) and sp.is_active and sp.sessions_ended_at is not null
    and a.category = 'security' and a.details->>'reason' = 'جهاز مفقود' and (a.details->>'sessions_ended')::int = 2 and a.actor_id = '10000000-0000-0000-0000-000000000001'
    and exists (select 1 from jsonb_array_elements(fn_admin_staff_list()) x where x->>'id' = '10000000-0000-0000-0000-000000000002' and x->>'sessions_ended_at' is not null),
    r::text);
exception when others then perform t_record('ST11 «تسجيل خروج إجباري» ends both sessions (timeboxed now, refresh tokens revoked), keeps the account active, and is logged as a security event with the reason and who did it', false, sqlerrm); end $$;
select t_login_session('a0000000-0000-0000-0000-000000000002', 'sup@test.local', t_id('sess1'));
do $$ declare n int; no_id boolean; no_role boolean; total int; op text; again uuid; begin
  no_id := fn_staff_id() is null; no_role := fn_current_role() is null;
  select count(*) into n from reservations;
  total := (fn_reservation_list('00000000-0000-0000-0000-000000000010', '{}'::jsonb, 1, 0)->>'total')::int;
  op := t_fails(format('select fn_hk_create_task(%L::jsonb)', jsonb_build_object('room_id', '00000000-0000-0000-0000-000000000102', 'task_type_id', '00000000-0000-0000-0000-000000000420')), 'FORBIDDEN%');
  perform t_login_session('a0000000-0000-0000-0000-000000000002', 'sup@test.local', t_session_open('a0000000-0000-0000-0000-000000000002'));
  again := fn_staff_id();
  perform t_record('ST12 the token still in hand is refused on its next request on any device: no staff identity, no rows, no operation; a fresh sign-in (a new session) works again',
    no_id and no_role and n = 0 and total = 0 and op = 'ok' and again = '10000000-0000-0000-0000-000000000002', n || ' rows, op ' || op);
exception when others then perform t_record('ST12 the token still in hand is refused on its next request on any device: no staff identity, no rows, no operation; a fresh sign-in (a new session) works again', false, sqlerrm); end $$;
-- the manager's limits, oneself, the reason
select t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
select t_record('ST13 the manager signs out a supervisor but neither an owner nor a manager nor themselves, and never without a reason',
  (fn_admin_force_logout('10000000-0000-0000-0000-000000000002', 'اختبار المدير')->>'ok')::boolean
  and t_fails('select fn_admin_force_logout(''10000000-0000-0000-0000-000000000001'', ''اختبار'')', 'FORBIDDEN%') = 'ok'
  and t_fails(format('select fn_admin_force_logout(%L, ''اختبار'')', t_id('p6')), 'FORBIDDEN%') = 'ok'
  and t_fails('select fn_admin_force_logout(''10000000-0000-0000-0000-000000000008'', ''اختبار'')', 'SELF_NOT_ALLOWED%') = 'ok'
  and t_fails('select fn_admin_force_logout(''10000000-0000-0000-0000-000000000002'', ''  '')', 'VALIDATION: reason%') = 'ok');
-- deactivation ends the sessions too; reactivation does not revive them
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
do $$ declare s uuid; r jsonb; a audit_events; off_ok boolean; back jsonb; on_ok boolean; begin
  perform t_text(format('update staff_profiles set auth_user_id = %L where id = %L returning auth_user_id', 'a0000000-0000-0000-0000-0000000000a6', t_id('p6')));   -- link the invited account (as Supabase does at first sign-in)
  s := t_session_open('a0000000-0000-0000-0000-0000000000a6');
  r := fn_admin_set_staff_active(t_id('p6'), false, 'انتهى عقده');
  a := t_audit_last('staff.deactivated', t_id('p6'));
  off_ok := (r->>'sessions_ended')::int = 1 and t_session_ended(s) and not (t_staff(t_id('p6'))).is_active and a.details->>'reason' = 'انتهى عقده';
  back := fn_admin_set_staff_active(t_id('p6'), true, 'عاد');
  on_ok := (back->>'is_active')::boolean and t_session_ended(s) and (t_staff(t_id('p6'))).is_active;
  perform t_record('ST14 deactivating ends the person''s sessions and records the reason; reactivating later does not bring the old session back; no reason → refused; the owner cannot deactivate himself',
    off_ok and on_ok
    and t_fails(format('select fn_admin_set_staff_active(%L, false, '''')', t_id('p6')), 'VALIDATION: reason%') = 'ok'
    and t_fails('select fn_admin_set_staff_active(''10000000-0000-0000-0000-000000000001'', false, ''اختبار'')', 'SELF_NOT_ALLOWED%') = 'ok', r::text || ' ' || back::text);
exception when others then perform t_record('ST14 deactivating ends the person''s sessions and records the reason; reactivating later does not bring the old session back; no reason → refused; the owner cannot deactivate himself', false, sqlerrm); end $$;
-- the branch's staff for screens and the assistant: live members only
do $$ declare l jsonb; begin
  perform fn_admin_update_staff(jsonb_build_object('staff_id', t_id('p6'), 'branch_ids', jsonb_build_array('00000000-0000-0000-0000-000000000012'), 'reason', 'فرع B فقط'));
  l := fn_branch_staff('00000000-0000-0000-0000-000000000010');
  perform t_record('ST15 fn_branch_staff lists the owner and the live members of the branch, not a retired membership nor a deactivated person; a retired member cannot be assigned a task there',
    exists (select 1 from jsonb_array_elements(l) x where x->>'id' = '10000000-0000-0000-0000-000000000001')
    and exists (select 1 from jsonb_array_elements(l) x where x->>'id' = '10000000-0000-0000-0000-000000000002')
    and not exists (select 1 from jsonb_array_elements(l) x where (x->>'id')::uuid = t_id('p6'))
    and not exists (select 1 from jsonb_array_elements(l) x where x->>'id' = '10000000-0000-0000-0000-000000000007')
    and t_fails(format('select fn_hk_assign_task(%L, %L)', t_id('task_now'), t_id('p6')), 'ASSIGNEE_NOT_IN_BRANCH%') = 'ok'
    and fn_branch_staff('00000000-0000-0000-0000-000000000011') = '[]'::jsonb, l::text);
exception when others then perform t_record('ST15 fn_branch_staff lists the owner and the live members of the branch, not a retired membership nor a deactivated person; a retired member cannot be assigned a task there', false, sqlerrm); end $$;

-- =====================================================================
-- CU. «استعمال القدرات» (decision 55; control G26; D04)
-- =====================================================================
select t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
select t_record('CU01 the usage report is the owner''s only', t_fails('select fn_reports_capability_usage(''{}''::jsonb)', 'FORBIDDEN%') = 'ok');
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
do $$ declare r jsonb; row jsonb; want bigint; last_want timestamptz; begin
  r := fn_reports_capability_usage('{"weeks": 4}'::jsonb);
  select x into row from jsonb_array_elements(r->'rows') x where x->>'code' = 'reservations.create';
  want := t_count('select count(*) from audit_events where organization_id = ''00000000-0000-0000-0000-000000000001'' and action = ''reservation.created'' and result = ''success'' and created_at >= now() - interval ''4 weeks''');
  select max(created_at) into last_want from audit_events where organization_id = '00000000-0000-0000-0000-000000000001' and action = 'reservation.created' and result = 'success';
  perform t_record('CU02 a capability used this window: «مستخدم», the window count and the last successful use equal the log, the users are people',
    row->>'status' = 'used' and (row->>'window_count')::int = want and want > 0 and (row->>'last_success_at')::timestamptz = last_want and (row->'by'->>'human')::int > 0
    and (row->>'core')::boolean = false and row->>'area' = 'الحجوزات', row::text);
exception when others then perform t_record('CU02 a capability used this window: «مستخدم», the window count and the last successful use equal the log, the users are people', false, sqlerrm); end $$;
do $$ declare r jsonb; begin
  r := fn_reports_capability_usage('{"weeks": 4}'::jsonb);
  perform t_record('CU03 a window the log does not cover (the log is younger than four weeks) makes every unused capability «غير محسوم», never «غير مستخدم»; read-only screens are «غير مقيس»; the core-administration mark is carried',
    not (r->>'log_covers_window')::boolean
    and not exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'status' = 'idle')
    and exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'status' = 'undetermined' and x->>'coverage' = 'full')
    and (select x->>'status' from jsonb_array_elements(r->'rows') x where x->>'code' = 'screens.reports') = 'unmeasured'
    and (select (x->>'core')::boolean from jsonb_array_elements(r->'rows') x where x->>'code' = 'admin.facilities')
    and (r->>'weeks')::int = 4 and (fn_reports_capability_usage('{"weeks": 0}'::jsonb)->>'weeks')::int = 1 and (fn_reports_capability_usage('{"weeks": 99}'::jsonb)->>'weeks')::int = 26,
    (select string_agg(distinct x->>'status', ',') from jsonb_array_elements(r->'rows') x));
exception when others then perform t_record('CU03 a window the log does not cover (the log is younger than four weeks) makes every unused capability «غير محسوم», never «غير مستخدم»; read-only screens are «غير مقيس»; the core-administration mark is carried', false, sqlerrm); end $$;
-- D04 in the second organisation: its log starts 40 days ago (so the window is covered); one partial capability was
-- last used 40 days ago; one full capability never → «غير محسوم» for the first, «غير مستخدم» for the second
reset role;
select set_config('request.jwt.claim.sub', '', false), set_config('request.jwt.claims', '', false);
select t_audit_backdated('00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000011', 'reservation.created', 'reservation', interval '40 days'),
       t_audit_backdated('00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000011', 'reservation.summary_signed', 'reservation', interval '40 days'),
       t_audit_backdated('00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000011', 'task.created', 'housekeeping_task', interval '3 days');
select t_login('a0000000-0000-0000-0000-000000000005', 'owner2@test.local');
set role authenticated;
do $$ declare r jsonb; summ jsonb; maint jsonb; tasks jsonb; crt jsonb; begin
  r := fn_reports_capability_usage('{"weeks": 4}'::jsonb);
  select x into summ from jsonb_array_elements(r->'rows') x where x->>'code' = 'stay.summary';
  select x into maint from jsonb_array_elements(r->'rows') x where x->>'code' = 'housekeeping.maintenance';
  select x into tasks from jsonb_array_elements(r->'rows') x where x->>'code' = 'housekeeping.tasks';
  select x into crt from jsonb_array_elements(r->'rows') x where x->>'code' = 'reservations.create';
  perform t_record('CU04 / D04 with the window covered: a capability the log sees only partly, last used 40 days ago → «غير محسوم» (the old use shown), never «غير مستخدم»; a fully audited one never used → «غير مستخدم»; one used 3 days ago → «مستخدم» with a week count of 1',
    (r->>'log_covers_window')::boolean and summ->>'status' = 'undetermined' and summ->>'coverage' = 'partial' and (summ->>'last_success_at')::timestamptz < now() - interval '39 days' and (summ->>'window_count')::int = 0
    and maint->>'status' = 'idle' and maint->>'last_success_at' is null
    and tasks->>'status' = 'used' and (tasks->>'week_count')::int = 1 and (tasks->>'window_count')::int = 1
    and crt->>'status' = 'idle' and (crt->>'last_success_at')::timestamptz < now() - interval '39 days',
    'summary ' || (summ->>'status') || ', maintenance ' || (maint->>'status') || ', tasks ' || (tasks->>'status') || ', create ' || (crt->>'status'));
exception when others then perform t_record('CU04 / D04 with the window covered: a capability the log sees only partly, last used 40 days ago → «غير محسوم» (the old use shown), never «غير مستخدم»; a fully audited one never used → «غير مستخدم»; one used 3 days ago → «مستخدم» with a week count of 1', false, sqlerrm); end $$;
-- a purge of the log inside the window breaks the measure: everything unused becomes «غير محسوم» again; nothing is ever removed by the report
reset role;
select set_config('request.jwt.claim.sub', '', false), set_config('request.jwt.claims', '', false);
select t_audit_backdated('00000000-0000-0000-0000-000000000002', null, 'data_purge_executed', 'organization', interval '1 day', '{"categories": ["audit"]}'::jsonb);
select t_login('a0000000-0000-0000-0000-000000000005', 'owner2@test.local');
set role authenticated;
do $$ declare r jsonb; n_before bigint; n_after bigint; begin
  n_before := t_count('select count(*) from audit_events');
  r := fn_reports_capability_usage('{"weeks": 4}'::jsonb);
  n_after := t_count('select count(*) from audit_events');
  perform t_record('CU05 a purge of the log inside the window: the window is no longer covered, «غير مستخدم» disappears (undetermined instead), «استعمال القدرات» itself writes and removes nothing (decision 53), and the note says so',
    not (r->>'log_covers_window')::boolean and not exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'status' = 'idle')
    and (select x->>'status' from jsonb_array_elements(r->'rows') x where x->>'code' = 'housekeeping.maintenance') = 'undetermined'
    and (select x->>'status' from jsonb_array_elements(r->'rows') x where x->>'code' = 'housekeeping.tasks') = 'used'
    and n_before = n_after and r->>'note' like '%القرار 53%' and r->>'note' like '%غير محسوم%', 'rows ' || n_before || ' → ' || n_after);
exception when others then perform t_record('CU05 a purge of the log inside the window: the window is no longer covered, «غير مستخدم» disappears (undetermined instead), «استعمال القدرات» itself writes and removes nothing (decision 53), and the note says so', false, sqlerrm); end $$;

-- =====================================================================
-- RESULTS
-- =====================================================================
reset role;
select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),150) as detail from test_results order by ok, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if (select count(*) from test_results) < 59 then raise exception 'LISTS AND REPORTS TESTS INCOMPLETE: % of 59 checks ran', (select count(*) from test_results); end if;
  if exists (select 1 from test_results where ok is not true) then raise exception 'LISTS AND REPORTS TESTS FAILED'; end if;
end $$;
