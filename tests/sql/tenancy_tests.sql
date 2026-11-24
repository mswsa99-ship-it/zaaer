-- =====================================================================
-- Every row says its hotel, and every branch row its branch (TN10–TN17; migration 0076, plan item 2.2).
-- The hotel tables below are supabase/tenancy.json's «hotel» scope (tests/unit/tenancy.test.ts TN06 keeps the two
-- lists equal); every other table but the hotels' registry is a branch table.
-- Fixtures (security_tests.sql, core_tests.sql): organisation 00..01 with branches 10 and 12; organisation 00..02
-- with branch 11; unit 101 (00..100) on branch 10.
-- =====================================================================
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
create or replace function tn_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;
create temp table tn_hotel_tables(t text primary key);
insert into tn_hotel_tables values
 ('accounting_periods'),('ai_settings'),('ai_usage_daily'),('alert_rules'),('bank_mail_settings'),('bank_match_items'),('bank_matches'),
 ('bank_messages'),('bank_parse_rules'),('booking_sources'),('branches'),('client_errors'),('document_sequences'),('expense_categories'),
 ('finance_control_settings'),('guest_bans'),('guest_phone_optouts'),('guest_profiles'),('hotel_exit_archives'),('hotel_exit_rows'),('integration_events'),('product_categories'),('product_order_lines'),('products'),('role_permissions'),
 ('staff_profiles'),('staff_saved_views'),('system_settings');
create temp table tn_children(t text, parent text, link text);
insert into tn_children values
 ('access_delivery_events','reservations','reservation_id'),('access_release_requests','reservations','reservation_id'),
 ('ai_guardrail_events','conversations','conversation_id'),('ai_ops_messages','ai_ops_conversations','conversation_id'),
 ('ai_tool_executions','conversations','conversation_id'),('code_rotation_events','keyboxes','keybox_id'),
 ('conversation_messages','conversations','conversation_id'),('day_closing_lines','day_closings','closing_id'),
 ('journal_lines','journal_entries','entry_id'),('payment_transactions','reservations','reservation_id'),
 ('registration_sessions','reservations','reservation_id'),('reservation_guests','reservations','reservation_id');

-- ---------------------------------------------------------------- TN10 the columns are there
do $$ declare missing text; begin
  select string_agg(c.relname || '.' || col, ', ' order by c.relname) into missing
    from pg_class c cross join (values ('organization_id'), ('branch_id')) v(col)
   where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and c.relname not in ('organizations','platform_operators','platform_events','platform_support_grants')
     and not (v.col = 'branch_id' and c.relname in (select t from tn_hotel_tables))
     and not exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = v.col and not a.attisdropped);
  perform tn_record('TN10 every table but the hotels'' registry has organization_id, and every branch table branch_id too', missing is null, missing);
end $$;

-- ---------------------------------------------------------------- TN11 every row agrees with its branch and its parent
do $$ declare r record; bad text := ''; n bigint; total bigint := 0; begin
  for r in select c.relname as t from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
             and c.relname not in ('organizations', 'branches','platform_operators','platform_events','platform_support_grants') and c.relname not in (select t from tn_hotel_tables) loop
    execute format('select count(*) from public.%I x join branches b on b.id = x.branch_id where x.organization_id is distinct from b.organization_id', r.t) into n;
    if n > 0 then bad := bad || r.t || ':' || n || ' '; end if;
    execute format('select count(*) from public.%I', r.t) into n; total := total + n;
  end loop;
  for r in select * from tn_children loop
    execute format('select count(*) from public.%I x join public.%I p on p.id = x.%I where x.organization_id is distinct from p.organization_id or x.branch_id is distinct from p.branch_id', r.t, r.parent, r.link) into n;
    if n > 0 then bad := bad || r.t || '≠' || r.parent || ':' || n || ' '; end if;
  end loop;
  perform tn_record('TN11 every branch row''s hotel is its branch''s, and every child row''s hotel and branch are its parent''s (' || total || ' rows after the other files)', bad = '', bad);
end $$;

-- ---------------------------------------------------------------- TN12 filled when the insert does not say them
do $$ declare n_org uuid; m_org uuid; m_branch uuid; c uuid; begin
  insert into notifications(branch_id, title) values ('00000000-0000-0000-0000-000000000012', 'TN12') returning organization_id into n_org;
  insert into conversations(channel, status, branch_id) values ('screen', 'active', '00000000-0000-0000-0000-000000000012') returning id into c;
  insert into conversation_messages(conversation_id, sender, content) values (c, 'guest', 'TN12') returning organization_id, branch_id into m_org, m_branch;
  perform tn_record('TN12 a branch row and a child row inserted without their hotel and branch get them from the branch and the parent',
    n_org = '00000000-0000-0000-0000-000000000001' and m_org = '00000000-0000-0000-0000-000000000001' and m_branch = '00000000-0000-0000-0000-000000000012',
    coalesce(n_org::text, '∅') || ' ' || coalesce(m_org::text, '∅') || ' ' || coalesce(m_branch::text, '∅'));
exception when others then perform tn_record('TN12 a branch row and a child row inserted without their hotel and branch get them', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- TN13 a row naming another hotel or branch is refused
do $$ declare e1 text; e2 text; e3 text; c uuid; begin
  begin insert into notifications(branch_id, organization_id, title) values ('00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000002', 'TN13'); e1 := 'accepted';
  exception when others then e1 := sqlerrm; end;
  select id into c from conversations where branch_id = '00000000-0000-0000-0000-000000000012' order by created_at desc limit 1;
  begin insert into conversation_messages(conversation_id, sender, content, organization_id) values (c, 'guest', 'TN13', '00000000-0000-0000-0000-000000000002'); e2 := 'accepted';
  exception when others then e2 := sqlerrm; end;
  begin insert into conversation_messages(conversation_id, sender, content, branch_id) values (c, 'guest', 'TN13', '00000000-0000-0000-0000-000000000010'); e3 := 'accepted';
  exception when others then e3 := sqlerrm; end;
  perform tn_record('TN13 a row that names another hotel than its branch''s, or a hotel or branch other than its parent''s, is refused',
    e1 like 'TENANT:%' and e2 like 'TENANT:%' and e3 like 'TENANT:%', e1 || ' | ' || e2 || ' | ' || e3);
end $$;

-- ---------------------------------------------------------------- TN14 a row moves between its hotel's branches, never to another hotel
do $$ declare k uuid; e text; o uuid; begin
  insert into notifications(branch_id, title) values ('00000000-0000-0000-0000-000000000010', 'TN14') returning id into k;
  update notifications set branch_id = '00000000-0000-0000-0000-000000000012' where id = k returning organization_id into o;
  begin update notifications set branch_id = '00000000-0000-0000-0000-000000000011' where id = k; e := 'accepted';
  exception when others then e := sqlerrm; end;
  perform tn_record('TN14 a row moves to another branch of its hotel, and a move to another hotel''s branch is refused',
    o = '00000000-0000-0000-0000-000000000001' and e like 'TENANT:%' and (select branch_id from notifications where id = k) = '00000000-0000-0000-0000-000000000012', e);
exception when others then perform tn_record('TN14 a row moves to another branch of its hotel', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- TN15 an update that does not touch the two columns keeps them; one that does is checked
do $$ declare k uuid; o uuid; e text; begin
  insert into notifications(branch_id, title) values ('00000000-0000-0000-0000-000000000010', 'TN15') returning id into k;
  update notifications set read_at = now() where id = k returning organization_id into o;
  begin update notifications set organization_id = '00000000-0000-0000-0000-000000000002' where id = k; e := 'accepted';
  exception when others then e := sqlerrm; end;
  perform tn_record('TN15 an update of other columns keeps the row''s hotel, and setting another hotel on it is refused',
    o = '00000000-0000-0000-0000-000000000001' and e like 'TENANT:%', e);
end $$;

-- ---------------------------------------------------------------- TN16 a row without a link keeps what it was given
do $$ declare o uuid; o2 uuid; k uuid; begin
  insert into notifications(title, organization_id) values ('TN16 whole hotel', '00000000-0000-0000-0000-000000000001') returning id, organization_id into k, o;
  update notifications set read_at = now() where id = k returning organization_id into o2;
  perform tn_record('TN16 a notification for the whole hotel (no branch) keeps the hotel it was given, also after an update',
    o = '00000000-0000-0000-0000-000000000001' and o2 = o, coalesce(o::text, '∅') || ' ' || coalesce(o2::text, '∅'));
exception when others then perform tn_record('TN16 a notification for the whole hotel keeps its hotel', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- TN17 the trigger is on the 28 tables, first among each one's triggers
do $$ declare n int; firsts int; tables int; begin
  select count(*) into n from pg_trigger where tgname = 'a_tenant_fill' and not tgisinternal;
  select count(*) into tables from (select distinct tgrelid from pg_trigger where tgname = 'a_tenant_fill') s;
  select count(*) into firsts from pg_trigger t where t.tgname = 'a_tenant_fill'
     and not exists (select 1 from pg_trigger o where o.tgrelid = t.tgrelid and not o.tgisinternal and o.tgname < t.tgname
                       and (o.tgtype & 2) = 2);   -- another BEFORE trigger that would run earlier
  perform tn_record('TN17 fn_tenant_fill runs on 28 tables, before any other BEFORE trigger of each, and no API role may call it',
    n = 28 and tables = 28 and firsts = 28 and not has_function_privilege('authenticated', 'fn_tenant_fill()', 'execute')
    and not has_function_privilege('anon', 'fn_tenant_fill()', 'execute'),
    n || ' triggers on ' || tables || ' tables, first on ' || firsts);
end $$;

-- ---------------------------------------------------------------- TN18 the log fills its row's hotel
do $$ declare o1 uuid; o2 uuid; begin
  insert into audit_events(branch_id, action, entity_type) values ('00000000-0000-0000-0000-000000000012', 'tn18.branch', 'test') returning organization_id into o1;
  insert into audit_events(actor_id, action, entity_type) values ('10000000-0000-0000-0000-000000000005', 'tn18.actor', 'test') returning organization_id into o2;
  perform tn_record('TN18 a log row with a branch takes the branch''s hotel, and one with only a staff member that member''s hotel',
    o1 = '00000000-0000-0000-0000-000000000001' and o2 = '00000000-0000-0000-0000-000000000002', coalesce(o1::text, '∅') || ' ' || coalesce(o2::text, '∅'));
exception when others then perform tn_record('TN18 a log row takes its hotel', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- TN20–TN23 the row rules: the hotel first (0077, plan item 2.3)
do $$ declare missing text; shared text; begin
  select string_agg(tablename || '.' || policyname, ', ') into missing from pg_policies
   where schemaname = 'public' and roles = array['authenticated']::name[] and tablename not in ('organizations', 'staff_profiles')
     and not (coalesce(qual, 'false') = 'false' and coalesce(with_check, 'false') = 'false')
     and not (coalesce(qual, '') like '((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) AND %'
              or (qual is null and with_check like '((organization_id = ( SELECT fn_user_org_id() AS fn_user_org_id)) AND %'));
  select string_agg(tablename || '.' || policyname, ', ') into shared from pg_policies
   where schemaname = 'public' and roles @> array['anon', 'authenticated']::name[];
  perform tn_record('TN20 every rule a signed-in staff member goes through asks the hotel first, and no rule serves visitors and staff alike',
    missing is null and shared is null, coalesce(missing, '') || ' | ' || coalesce(shared, ''));
end $$;
create or replace function tn_login(p uuid) returns void language plpgsql as $$ begin
  perform set_config('request.jwt.claim.sub', p::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, false); end $$;
create temp table tn_seen(who text, t text, n bigint);
grant all on tn_seen to public;
-- every table with the column, read through the rules as each person; a table they may not read at all counts 0
do $$ declare r record; n bigint; who record; begin
  for who in select * from (values ('owner of the other hotel', 'a0000000-0000-0000-0000-000000000005'::uuid, 'organization_id', '00000000-0000-0000-0000-000000000001'::uuid),
                                   ('owner of this hotel', 'a0000000-0000-0000-0000-000000000001'::uuid, 'organization_id', '00000000-0000-0000-0000-000000000002'::uuid),
                                   ('supervisor of branch B', 'a0000000-0000-0000-0000-000000000006'::uuid, 'branch_id', '00000000-0000-0000-0000-000000000010'::uuid)) v(name, uid, col, other) loop
    perform tn_login(who.uid);
    for r in select c.relname as t from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
               and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = who.col and not a.attisdropped) loop
      execute 'set local role authenticated';
      begin execute format('select count(*) from public.%I where %I = $1', r.t, who.col) into n using who.other;
      exception when insufficient_privilege then n := 0; end;
      execute 'reset role';
      insert into tn_seen values (who.name, r.t, n);
    end loop;
  end loop;
  perform tn_login(null);
end $$;
do $$ declare leak text; own bigint; begin
  select string_agg(t || ':' || n, ' ') into leak from tn_seen where who = 'owner of the other hotel' and n > 0;
  perform tn_record('TN21 the other hotel''s owner reads not one row of this hotel, in any table', leak is null, leak);
  select string_agg(t || ':' || n, ' ') into leak from tn_seen where who = 'owner of this hotel' and n > 0;
  perform tn_record('TN22 this hotel''s owner reads not one row of the other hotel, in any table', leak is null, leak);
end $$;
do $$ declare leak text; begin
  -- seen across branches by design: who works in which branch (the staff screens), and which products each branch sells
  select string_agg(t || ':' || n, ' ') into leak from tn_seen
   where who = 'supervisor of branch B' and n > 0 and t not in ('branch_memberships', 'product_branches');
  perform tn_record('TN23 a supervisor of branch B reads no row of branch A in any branch table but the hotel''s staff and product lists', leak is null, leak);
end $$;

select case when ok then 'PASS' else 'FAIL' end as result, name, case when ok then null else detail end as detail from test_results order by name;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from test_results where ok is not true) then raise exception 'TENANCY TESTS FAILED'; end if;
  if (select count(*) from test_results) < 13 then raise exception 'TENANCY TESTS INCOMPLETE: % of 13 checks ran', (select count(*) from test_results); end if;
end $$;
