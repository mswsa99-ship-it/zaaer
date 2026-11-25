-- =====================================================================
-- Every function a visitor or a staff member may call keeps to the hotel and the branch (FS*; migration 0078, plan
-- item 2.4). supabase/function-scope.json says the rule and lists, with their reasons, the functions that keep to it
-- otherwise; FS01 fails on a function that calls none of the checks and is not listed, FS02 on a listed one that no
-- longer needs it. FS03–FS05: since 0078 a row cannot point to another hotel's row, and none of the test rows does. FS10–FS13 probe every function a
-- signed-in staff member may call and a visitor may not (the visitor's functions are public pages or one link's own;
-- item 2.6 binds them to the site's hotel), as the other hotel's owner and as branch B's supervisor, with this hotel's and branch A's
-- ids (every function, every argument filled from the target's rows, its JSON from the target's own row), undoing each
-- call: no answer may carry the target's ids or names, and no row of the target may change.
-- Fixtures (security_tests.sql, core_tests.sql): organisation 00..01 with branches 10 (A) and 12 (B); organisation
-- 00..02 with branch 11; its owner a0..05; supervisor a0..06 on branch 12 only; owner a0..01 of organisation 00..01.
-- =====================================================================
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create or replace function fs_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;
\set fs_cfg `cat supabase/function-scope.json`
create temp table fs_cfg as select :'fs_cfg'::jsonb as j;

-- ---------------------------------------------------------------- FS01–FS02 the static rule and its reasoned list
create temp table fs_fn as
select p.oid, p.proname as name, p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as sig,
       p.prosecdef as sd, p.prorettype = 'trigger'::regtype as trig, p.prorettype = 'void'::regtype as void,
       has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute') as exposed,
       regexp_replace(regexp_replace(p.prosrc, '/\*.*?\*/', ' ', 'g'), '--[^\n]*', ' ', 'g') as body
from pg_proc p
where p.pronamespace = 'public'::regnamespace and p.proname like 'fn\_%'
  and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e');
create temp table fs_word as select distinct f.oid, lower(m[1]) as w from fs_fn f, regexp_matches(f.body, '([A-Za-z_][A-Za-z0-9_]*)', 'g') m;
create temp table fs_tab as select distinct w.oid from fs_word w join pg_class c on c.relname = w.w and c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p', 'v');
create temp table fs_call as select distinct w.oid as caller, g.oid as callee, g.name as callee_name from fs_word w join fs_fn g on g.name = w.w where g.oid <> w.oid;
create temp table fs_free(name text primary key);   -- the helpers of the reasoned list: they answer nothing of a hotel
insert into fs_free select jsonb_object_keys(j->'helpers') from fs_cfg;
-- a check: the scope primitives, and every function returning void that calls one of them
create temp table fs_check(name text primary key);
insert into fs_check values ('fn_user_org_id'), ('fn_user_branch_ids'), ('fn_require_branch'), ('fn_staff_id'), ('fn_token_reservation');
insert into fs_check select distinct f.name from fs_fn f join fs_call c on c.caller = f.oid where f.void and c.callee_name in ('fn_user_org_id', 'fn_user_branch_ids', 'fn_require_branch', 'fn_staff_id') on conflict do nothing;
create temp table fs_checked as
select f.oid from fs_fn f where f.body ~* 'auth\.uid\(\)' or exists (select 1 from fs_call c where c.caller = f.oid and c.callee_name in (select name from fs_check));
create temp table fs_unscoped as
with recursive u(oid) as (
  select f.oid from fs_fn f where f.oid in (select oid from fs_tab) and f.name not in (select name from fs_free) and f.name not in (select name from fs_check) and f.oid not in (select oid from fs_checked)
  union
  select c.caller from fs_call c join u on u.oid = c.callee join fs_fn f on f.oid = c.caller
   where f.name not in (select name from fs_free) and f.name not in (select name from fs_check) and f.oid not in (select oid from fs_checked)
)
select distinct f.* from fs_fn f join u on u.oid = f.oid;

do $$ declare missing text; stale text; ghosts text; begin
  select string_agg(sig, ', ' order by sig) into missing from fs_unscoped
   where sd and exposed and not trig and sig not in (select jsonb_object_keys(j->'exceptions') from fs_cfg);
  perform fs_record('FS01 every function a visitor or a staff member may call calls a hotel or branch check, touches no table, or is listed with its reason',
    missing is null, missing);
  select string_agg(k, ', ' order by k) into stale from (select jsonb_object_keys(j->'exceptions') as k from fs_cfg) e
   where k not in (select sig from fs_unscoped where sd and exposed and not trig);
  select string_agg(k, ', ' order by k) into ghosts from (select jsonb_object_keys(j->'helpers') as k from fs_cfg) h
   where k not in (select name from fs_fn);
  perform fs_record('FS02 every listed exception is a callable function that would fail FS01 without its entry, and every helper exists',
    stale is null and ghosts is null, coalesce(stale, '') || ' | ' || coalesce(ghosts, ''));
end $$;

-- ---------------------------------------------------------------- FS03–FS04 a row cannot point to another hotel's row
do $$ declare missing text; callable boolean; fn regproc := to_regproc('public.fn_hotel_pointers'); begin
  select string_agg(child || '.' || col || '→' || parent, ', ' order by child, col) into missing from (
    select c.conrelid::regclass::text as child, a.attname as col, c.confrelid::regclass::text as parent, c.conrelid
      from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
     where c.contype = 'f' and c.connamespace = 'public'::regnamespace and c.confrelid <> 'public.organizations'::regclass
       and exists (select 1 from pg_attribute x where x.attrelid = c.conrelid and x.attname = 'organization_id' and not x.attisdropped)
       and exists (select 1 from pg_attribute x where x.attrelid = c.confrelid and x.attname = 'organization_id' and not x.attisdropped)) k
   where not exists (
     select 1 from pg_trigger t
      where t.tgrelid = k.conrelid and t.tgname = 'zz_hotel_pointers' and t.tgfoid = fn
        and exists (select 1 from generate_series(0, t.tgnargs / 2 - 1) i
                     where (string_to_array(encode(t.tgargs, 'escape'), '\000'))[2 * i + 1] = k.col
                       and (string_to_array(encode(t.tgargs, 'escape'), '\000'))[2 * i + 2] = k.parent));
  callable := fn is null or has_function_privilege('anon', fn, 'execute') or has_function_privilege('authenticated', fn, 'execute');
  perform fs_record('FS03 every pointer from one hotel table to another is checked by fn_hotel_pointers on its table, and no API role may call it',
    missing is null and not callable, left(coalesce(missing, ''), 600) || case when fn is null then ' | no fn_hotel_pointers' when callable then ' | callable' else '' end);
end $$;
do $$ declare gp uuid; g uuid; rid uuid; own_cat uuid; a text; b text; c text; d text; begin
  begin
    insert into guest_profiles(organization_id, full_name, phone) values ('00000000-0000-0000-0000-000000000002', 'ضيف فندق آخر', '0551230000') returning id into gp;
    select id into g from reservation_guests where organization_id = '00000000-0000-0000-0000-000000000001' order by id limit 1;
    begin update reservation_guests set guest_profile_id = gp where id = g; a := 'accepted';
    exception when foreign_key_violation then a := case when sqlerrm like 'HOTEL_MISMATCH%' then 'ok' else sqlerrm end; end;
    select id into rid from reservations where organization_id = '00000000-0000-0000-0000-000000000001' order by id limit 1;
    begin update reservations set branch_id = '00000000-0000-0000-0000-000000000011' where id = rid; b := 'accepted';
    exception when foreign_key_violation then b := case when sqlerrm like 'HOTEL_MISMATCH%' then 'ok' else sqlerrm end; end;
    begin insert into branch_memberships(staff_id, branch_id) values ('10000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000010'); c := 'accepted';
    exception when foreign_key_violation then c := case when sqlerrm like 'HOTEL_MISMATCH%' then 'ok' else sqlerrm end; end;
    select room_category_id into own_cat from reservations where id = rid;
    begin update reservations set room_category_id = own_cat where id = rid; d := 'ok';
    exception when others then d := sqlerrm; end;
    raise exception using errcode = 'P0F98', message = 'fs: undo';
  exception when sqlstate 'P0F98' then null; end;
  perform fs_record('FS04 a guest record taking another hotel''s profile, a booking moved to another hotel''s branch, a membership of another hotel''s staff are refused; a pointer to the own hotel passes',
    a = 'ok' and b = 'ok' and c = 'ok' and d = 'ok', concat_ws(' | ', a, b, c, d));
end $$;

-- the rows already there: none points to another hotel's row (the trigger checks what is written from 0078 on)
do $$ declare k record; n bigint; bad text; total int := 0; begin
  for k in select c.conrelid::regclass::text as child, a.attname as col, c.confrelid::regclass::text as parent
             from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
            where c.contype = 'f' and c.connamespace = 'public'::regnamespace and c.confrelid <> 'public.organizations'::regclass
              and exists (select 1 from pg_attribute x where x.attrelid = c.conrelid and x.attname = 'organization_id' and not x.attisdropped)
              and exists (select 1 from pg_attribute x where x.attrelid = c.confrelid and x.attname = 'organization_id' and not x.attisdropped) loop
    execute format('select count(*) from %s ch join %s p on p.id = ch.%I where ch.organization_id <> p.organization_id', k.child, k.parent, k.col) into n;
    total := total + 1;
    if n > 0 then bad := concat_ws(' ', bad, k.child || '.' || k.col || ':' || n); end if;
  end loop;
  perform fs_record('FS05 no row of the other test files points to another hotel''s row (' || total || ' pointers read)', bad is null and total >= 200, bad);
end $$;

-- ---------------------------------------------------------------- FS10–FS13 the probe
-- which table a uuid parameter or a JSON key names: by its stem (p_room, room_id → room), unless the function says otherwise
create temp table fs_stem(stem text primary key, tbl text not null);
insert into fs_stem values
  ('branch', 'branches'), ('reservation', 'reservations'), ('exclude_reservation', 'reservations'), ('room', 'rooms'), ('target_room', 'rooms'),
  ('task', 'housekeeping_tasks'), ('movement', 'bank_movements'), ('staff', 'staff_profiles'), ('assignee', 'staff_profiles'), ('target', 'staff_profiles'),
  ('conversation', 'conversations'), ('invoice', 'invoices'), ('order', 'product_orders'), ('payout', 'platform_payouts'), ('product', 'products'),
  ('source', 'booking_sources'), ('block', 'blocks'), ('floor', 'floors'), ('facility', 'facilities'), ('task_type', 'task_types'),
  ('profile', 'guest_profiles'), ('guest', 'reservation_guests'), ('voucher', 'financial_vouchers'), ('original_voucher', 'financial_vouchers'),
  ('unanswered', 'unanswered_questions'), ('category', 'room_categories'), ('account', 'cash_accounts'), ('alert', 'alert_events'),
  ('service', 'service_definitions'), ('message', 'bank_messages'), ('review', 'guest_reviews'), ('request', 'stay_extension_requests'),
  ('ticket', 'human_handoff_tickets'), ('match', 'bank_matches'), ('closing', 'day_closings'), ('entry', 'journal_entries'),
  ('rule', 'release_rules'), ('period', 'inventory_periods'), ('keybox', 'keyboxes'), ('charge', 'reservation_charges'),
  ('allocation', 'reservation_allocations'), ('notification', 'notifications'), ('proposal', 'ai_action_proposals'), ('view', 'staff_saved_views'),
  ('question', 'unanswered_questions'), ('policy', 'property_policies');
create temp table fs_override(fn text, param text, tbl text, primary key (fn, param));
insert into fs_override values
  ('fn_admin_approve_media_item', 'p_id', 'branch_media_items'), ('fn_admin_archive_media_item', 'p_id', 'branch_media_items'),
  ('fn_admin_archive_cash_account', 'p_id', 'cash_accounts'), ('fn_admin_archive_knowledge', 'p_id', 'knowledge_entries'),
  ('fn_admin_resolve_unanswered', 'p_id', 'unanswered_questions'), ('fn_ai_ops_execute_proposal', 'p_id', 'ai_action_proposals'),
  ('fn_ai_ops_reject_proposal', 'p_id', 'ai_action_proposals'), ('fn_branch_photo', 'p_id', 'branch_media_items'),
  ('fn_day_closing_request_edit', 'p_id', 'day_closings'), ('fn_day_closing_review', 'p_id', 'day_closings'), ('fn_day_closing_submit', 'p_id', 'day_closings'),
  ('fn_expense_attachment', 'p_id', 'expense_vouchers'), ('fn_expense_cancel', 'p_id', 'expense_vouchers'), ('fn_guest_profile', 'p_id', 'guest_profiles'),
  ('fn_saved_view_remove', 'p_id', 'staff_saved_views'),
  ('fn_account_statement', 'p_account', 'gl_accounts'),
  ('fn_staff_resolve_maintenance', 'p_ticket', 'maintenance_tickets'), ('fn_staff_resolve_ticket', 'p_ticket', 'human_handoff_tickets'),
  ('fn_day_closing_decide', 'p_request', 'day_closing_requests'), ('fn_staff_review_reply', 'p_review', 'guest_reviews'),
  ('fn_expense_create', 'category_id', 'expense_categories'), ('fn_bank_convert', 'category_id', 'expense_categories'),
  ('fn_admin_upsert_product', 'category_id', 'product_categories'),
  ('fn_admin_set_inventory', 'id', 'inventory_periods'), ('fn_admin_set_source_active', 'id', 'booking_sources'), ('fn_admin_set_source_commission', 'id', 'booking_sources'),
  ('fn_admin_upsert_bank_rule', 'id', 'bank_parse_rules'), ('fn_admin_upsert_block', 'id', 'blocks'), ('fn_admin_upsert_branch', 'id', 'branches'),
  ('fn_admin_upsert_cash_account', 'id', 'cash_accounts'), ('fn_admin_upsert_expense_category', 'id', 'expense_categories'),
  ('fn_admin_upsert_facility', 'id', 'facilities'), ('fn_admin_upsert_floor', 'id', 'floors'), ('fn_admin_upsert_knowledge', 'id', 'knowledge_entries'),
  ('fn_admin_upsert_media_item', 'id', 'branch_media_items'), ('fn_admin_upsert_product', 'id', 'products'),
  ('fn_admin_upsert_product_category', 'id', 'product_categories'), ('fn_admin_upsert_release_rule', 'id', 'release_rules'),
  ('fn_admin_upsert_room', 'id', 'rooms'), ('fn_admin_upsert_room_category', 'id', 'room_categories'), ('fn_admin_upsert_service', 'id', 'service_definitions'),
  ('fn_admin_upsert_source', 'id', 'booking_sources'), ('fn_admin_upsert_task_type', 'id', 'task_types'), ('fn_day_closing_amend', 'id', 'day_closings'),
  ('fn_saved_view_save', 'id', 'staff_saved_views');
-- the functions that take an entity's kind beside its id are called once per kind
create temp table fs_entity(entity text primary key, tbl text);
insert into fs_entity values ('branch', 'branches'), ('block', 'blocks'), ('floor', 'floors'), ('room_category', 'room_categories'), ('room', 'rooms'),
  ('facility', 'facilities'), ('task_type', 'task_types'), ('service', 'service_definitions');
-- the main table of a function that takes a JSON payload: the row its "row" calls copy their payload from
create temp table fs_main(fn text primary key, tbl text);
insert into fs_main values
  ('fn_create_voucher', 'financial_vouchers'), ('fn_refund', 'financial_vouchers'), ('fn_staff_correct_voucher', 'financial_vouchers'),
  ('fn_hk_create_task', 'housekeeping_tasks'), ('fn_expense_create', 'expense_vouchers'), ('fn_staff_enter_guest', 'reservation_guests'),
  ('fn_staff_pay_product_order', 'product_orders'), ('fn_staff_record_inspection', 'checkout_inspections'), ('fn_guest_ban', 'guest_profiles'),
  ('fn_guest_rate', 'guest_profiles'), ('fn_staff_create_reservation', 'reservations'), ('fn_staff_amend_stay', 'reservations'),
  ('fn_staff_adjust_price', 'reservations'), ('fn_staff_cancel', 'reservations'), ('fn_staff_set_hold', 'reservations'), ('fn_staff_shomoos', 'reservations'),
  ('fn_staff_deliver_access_code', 'reservations'), ('fn_platform_mark_checked', 'reservations'), ('fn_staff_update_platform', 'reservations'),
  ('fn_day_closing_save', 'day_closings'), ('fn_admin_save_payment_settings', 'branch_payment_settings'), ('fn_admin_journey_settings_save', 'branch_journey_settings'),
  ('fn_admin_whatsapp_save', 'branch_whatsapp_channels'), ('fn_admin_alert_rule_save', 'alert_rules'), ('fn_rate_calendar_set', 'rate_calendar'),
  ('fn_pos_settle', 'pos_settlements'), ('fn_platform_payout_confirm', 'platform_payouts'), ('fn_bank_convert', 'bank_movements'),
  ('fn_staff_check_in', 'reservations'), ('fn_staff_check_out', 'reservations'), ('fn_invoice_preview', 'invoices'), ('fn_staff_edit_invoice', 'invoices'),
  ('fn_staff_add_damage', 'reservation_charges'), ('fn_admin_set_branch_guide', 'branches'), ('fn_admin_set_branch_media', 'branch_media');

create or replace function pg_temp.fs_table_for(p_fn text, p_param text) returns text language sql as $$
  select coalesce((select tbl from fs_override where fn = p_fn and param = p_param),
                  (select tbl from fs_stem where stem = regexp_replace(regexp_replace(p_param, '^p_', ''), '_ids?$', '')));
$$;

-- the first value a function's checks allow for a name (a parameter or a variable): x in ('a', …), x = 'a', case x when 'a'
create or replace function pg_temp.fs_enum(p_body text, p_var text) returns text language sql as $$
  select coalesce((regexp_match(p_body, '\m' || p_var || '\M\s*\)?\s*(?:not\s+)?in\s*\(\s*''([^'']+)''', 'i'))[1],
                  (regexp_match(p_body, '\m' || p_var || '\M\s*\)?\s*(?:=|<>|!=)\s*''([^'']+)''', 'i'))[1],
                  (regexp_match(p_body, 'case\s+' || p_var || '\M\s+when\s+''([^'']+)''', 'i'))[1]);
$$;

-- the rows a probe aims at, one per table: the target hotel's (or the target branch's) first row
create temp table fs_target(scope text, tbl text, id uuid, version int, primary key (scope, tbl));
create or replace function pg_temp.fs_pick(p_scope text, p_org uuid, p_branch uuid, p_no_branch_first boolean default false) returns void language plpgsql as $$
declare r record; v_id uuid; v_ver int; has_ver boolean; has_branch boolean;
begin
  for r in select c.relname from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
             and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'id' and not a.attisdropped)
             and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'organization_id' and not a.attisdropped) loop
    has_ver := exists (select 1 from pg_attribute a where a.attrelid = ('public.' || r.relname)::regclass and a.attname = 'version' and not a.attisdropped);
    has_branch := exists (select 1 from pg_attribute a where a.attrelid = ('public.' || r.relname)::regclass and a.attname = 'branch_id' and not a.attisdropped);
    v_id := null; v_ver := null;
    if p_branch is not null and r.relname = 'branches' then
      v_id := p_branch;
    elsif p_branch is not null and has_branch then
      execute format('select id%s from public.%I where branch_id = $1 order by id limit 1', case when has_ver then ', version' else ', null::int' end, r.relname) into v_id, v_ver using p_branch;
    else
      execute format('select id%s from public.%I where organization_id = $1 order by %s id limit 1', case when has_ver then ', version' else ', null::int' end, r.relname,
                     case when has_branch and p_no_branch_first then '(branch_id is null) desc,' else '' end) into v_id, v_ver using p_org;
    end if;
    if v_id is not null then insert into fs_target values (p_scope, r.relname, v_id, v_ver); end if;
  end loop;
end $$;

-- a value for one JSON key, by how the function casts it and what its checks allow
create or replace function pg_temp.fs_json_value(p_scope text, p_fn text, p_body text, p_pname text, k text, p_own_branch uuid, p_variant text) returns jsonb language plpgsql as $$
declare t text; v uuid; cast_to text; ev text; var text;
begin
  if k ~ '(^id$|_id$)' then
    t := pg_temp.fs_table_for(p_fn, k);
    if t = 'branches' and p_variant in ('own_branch', 'row_own') then return to_jsonb(p_own_branch); end if;
    select id into v from fs_target where scope = p_scope and tbl = t;
    return to_jsonb(v);
  elsif k ~ '_ids$' then
    t := pg_temp.fs_table_for(p_fn, k);
    if t = 'branches' and p_variant in ('own_branch', 'row_own') then return jsonb_build_array(p_own_branch); end if;
    select id into v from fs_target where scope = p_scope and tbl = t;
    return case when v is null then '[]'::jsonb else jsonb_build_array(v) end;
  end if;
  cast_to := (regexp_match(p_body, '''' || k || '''\s*(?:,\s*''''\s*)?\)?\s*::\s*([a-z_]+)', 'i'))[1];
  if cast_to in ('boolean', 'bool') then return 'true'::jsonb; end if;
  if cast_to in ('int', 'integer', 'bigint', 'numeric', 'smallint', 'int4', 'int8') then return '1'::jsonb; end if;
  if cast_to = 'date' then return to_jsonb(current_date + 1); end if;
  if cast_to in ('timestamptz', 'timestamp') then return to_jsonb(now()); end if;
  if cast_to = 'time' then return '"10:00"'::jsonb; end if;
  if cast_to = 'jsonb' then return '{}'::jsonb; end if;
  ev := (regexp_match(p_body, '''' || k || '''\s*\)?\s*(?:not\s+)?in\s*\(\s*''([^'']+)''', 'i'))[1];
  if ev is null then
    var := (regexp_match(p_body, '(v_[a-z_0-9]+)[a-z_ ]*:=\s*[^;]*' || p_pname || '\s*->>\s*''' || k || '''', 'i'))[1];
    if var is not null then ev := pg_temp.fs_enum(p_body, var); end if;
  end if;
  if ev is not null then return to_jsonb(ev); end if;
  if k in ('check_in', 'from', 'from_date', 'date', 'day', 'on', 'starts_on', 'effective', 'month', 'business_date', 'entry_date', 'booked_on') then return to_jsonb(current_date + 1); end if;
  if k in ('check_out', 'to', 'to_date', 'until', 'ends_on') then return to_jsonb(current_date + 3); end if;
  if k ~ '(halalas|amount|quantity|price|rate|nights|adults|companions|count|days|minutes|hours|percent|capacity|priority|limit|version|sort)' then return '1'::jsonb; end if;
  if k in ('units', 'items', 'lines', 'aspects', 'companions_details', 'targets', 'changes', 'ids', 'fallback_models') then return '[]'::jsonb; end if;
  return to_jsonb('فحص'::text);
end $$;

-- the whole argument list of one call
create or replace function pg_temp.fs_args(p_scope text, p_oid oid, p_own_branch uuid, p_variant text, p_entity text) returns text language plpgsql as $$
declare f record; a record; acc text := ''; tb text; v uuid; ver int; first_ver int; o jsonb; k text; base jsonb; ev text; val text;
begin
  select p.proname, p.prosrc as body, coalesce(p.proargnames[1:p.pronargs], array[]::text[]) as names, p.proargtypes::oid[] as types into f from pg_proc p where p.oid = p_oid;
  for a in select n, t::regtype as t, i from unnest(f.names, f.types) with ordinality u(n, t, i) order by i loop
    val := 'null';
    if a.t = 'uuid'::regtype then
      tb := case when a.n = 'p_id' and p_entity is not null then (select tbl from fs_entity where entity = p_entity) else pg_temp.fs_table_for(f.proname, a.n) end;
      if tb = 'branches' and p_variant in ('own_branch', 'row_own') then val := quote_literal(p_own_branch) || '::uuid';
      else
        v := null; ver := null;
        select id, version into v, ver from fs_target where scope = p_scope and tbl = tb;
        if v is not null then val := quote_literal(v) || '::uuid'; first_ver := coalesce(first_ver, ver); else val := 'null::uuid'; end if;
      end if;
    elsif a.t = 'uuid[]'::regtype then
      tb := pg_temp.fs_table_for(f.proname, a.n);
      if tb = 'branches' and p_variant in ('own_branch', 'row_own') then val := quote_literal(array[p_own_branch]) || '::uuid[]';
      else v := null; select id into v from fs_target where scope = p_scope and tbl = tb; val := coalesce(quote_literal(array[v]) || '::uuid[]', 'null::uuid[]'); end if;
    elsif a.t = 'jsonb'::regtype then
      if a.n not in ('p', 'p_payload') then
        val := case when a.n in ('p_ages', 'p_items', 'p_targets', 'p_details') then '''[]''::jsonb' else '''{}''::jsonb' end;
      else
        o := '{}'::jsonb;
        if p_variant in ('row', 'row_own') then
          tb := coalesce((select tbl from fs_main where fn = f.proname), (select tbl from fs_override where fn = f.proname and param = 'id'));
          if tb is not null then
            v := null; select id into v from fs_target where scope = p_scope and tbl = tb;
            if v is not null then
              execute format('select to_jsonb(x) from public.%I x where id = $1', tb) into base using v;
              o := coalesce(base, '{}'::jsonb);
              if tb = 'reservations' then o := o || jsonb_build_object('reservation_id', v); end if;
              if o ? 'version' then o := o || jsonb_build_object('expected_version', o->'version'); end if;
            end if;
          end if;
        end if;
        for k in select distinct m[1] from regexp_matches(f.body, '\m' || a.n || '\s*->>?\s*''([a-z_0-9]+)''', 'g') m loop
          if not (o ? k) then o := o || jsonb_build_object(k, pg_temp.fs_json_value(p_scope, f.proname, f.body, a.n, k, p_own_branch, p_variant)); end if;
        end loop;
        if p_variant = 'row_own' and o ? 'branch_id' then o := o || jsonb_build_object('branch_id', p_own_branch); end if;
        val := quote_literal(o) || '::jsonb';
      end if;
    elsif a.t = 'text'::regtype then
      if a.n = 'p_entity' then val := quote_literal(p_entity);
      elsif a.n in ('p_reason', 'p_note', 'p_description', 'p_reply', 'p_summary', 'p_title', 'p_override_reason') then val := quote_literal('سبب فحص العزل بين الفنادق');
      elsif a.n = 'p_email' then val := quote_literal('probe@example.com');
      elsif a.n = 'p_phone' then val := quote_literal('0500000000');
      else ev := pg_temp.fs_enum(f.body, a.n); val := quote_literal(coalesce(ev, 'فحص')); end if;
    elsif a.t = 'date'::regtype then
      val := quote_literal(case when a.n in ('p_from', 'p_check_in') then current_date - 30 when a.n in ('p_to', 'p_check_out', 'p_new_check_out') then current_date + 30 else current_date end) || '::date';
    elsif a.t in ('integer'::regtype, 'bigint'::regtype, 'numeric'::regtype) then
      val := case when a.n in ('p_expected_version', 'p_version') then coalesce(first_ver, 1)::text else '1' end;
    elsif a.t = 'boolean'::regtype then val := 'true';
    elsif a.t = 'role_code'::regtype then val := '''supervisor''::role_code';
    elsif a.t = 'role_code[]'::regtype then val := '''{supervisor}''::role_code[]';
    elsif a.t = 'payment_method'::regtype then val := '''cash''::payment_method';
    elsif a.t = 'text[]'::regtype then val := '''{}''::text[]';
    elsif a.t = 'timestamp with time zone'::regtype then val := 'now()';
    elsif a.t = 'interval'::regtype then val := '''1 hour''::interval';
    end if;
    acc := acc || case when a.i > 1 then ', ' else '' end || val;
  end loop;
  return acc;
end $$;

-- what the target owns: its ids, and its proper names that the caller's hotel does not also have
create temp table fs_leak_id(scope text, id uuid, primary key (scope, id));
create temp table fs_leak_name(scope text, name text);
create or replace function pg_temp.fs_leaks(p_scope text, p_org uuid, p_branch uuid, p_caller_org uuid) returns void language plpgsql as $$
declare r record;
begin
  for r in select c.relname, exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'branch_id' and not a.attisdropped) as has_branch
             from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
             and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'id' and not a.attisdropped)
             and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'organization_id' and not a.attisdropped) loop
    if p_branch is null then
      execute format('insert into fs_leak_id select $1, id from public.%I where organization_id = $2 on conflict do nothing', r.relname) using p_scope, p_org;
    elsif r.has_branch and r.relname <> 'branches' then
      execute format('insert into fs_leak_id select $1, id from public.%I where branch_id = $2 on conflict do nothing', r.relname) using p_scope, p_branch;
    end if;
  end loop;
  if p_branch is null then
    insert into fs_leak_id values (p_scope, p_org) on conflict do nothing;
    insert into fs_leak_name select p_scope, n from (
      select name_ar as n from branches where organization_id = p_org
      union select full_name from guest_profiles where organization_id = p_org
      union select full_name from reservation_guests where organization_id = p_org
      union select full_name from staff_profiles where organization_id = p_org
      union select name_ar from room_categories where organization_id = p_org) x
     where length(n) >= 8 and n like '% %' and n not in (
      select name_ar from branches where organization_id = p_caller_org union select full_name from guest_profiles where organization_id = p_caller_org
      union select full_name from reservation_guests where organization_id = p_caller_org union select full_name from staff_profiles where organization_id = p_caller_org
      union select name_ar from room_categories where organization_id = p_caller_org);
  else
    insert into fs_leak_name select p_scope, n from (
      select full_name as n from reservation_guests where branch_id = p_branch
      union select name_ar from room_categories where branch_id = p_branch) x
     where length(n) >= 8 and n like '% %' and n not in (select full_name from reservation_guests where branch_id <> p_branch union select name_ar from room_categories where branch_id <> p_branch);
  end if;
end $$;

-- the target's rows, as one hash per table
create or replace function pg_temp.fs_fingerprint(p_org uuid, p_branch uuid) returns text language plpgsql as $$
declare r record; acc text := ''; h text;
begin
  for r in select c.relname from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
             and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = case when p_branch is null then 'organization_id' else 'branch_id' end and not a.attisdropped)
           order by c.relname loop
    if p_branch is null then
      execute format('select md5(coalesce(string_agg(t::text, ''|'' order by t::text), '''')) from public.%I t where organization_id = $1', r.relname) into h using p_org;
    else
      execute format('select md5(coalesce(string_agg(t::text, ''|'' order by t::text), '''')) from public.%I t where branch_id = $1', r.relname) into h using p_branch;
    end if;
    acc := acc || r.relname || ':' || h || ';';
  end loop;
  return acc;
end $$;

create temp table fs_result(scope text, fn text, variant text, outcome text, detail text, args text);
grant all on fs_result, fs_target, fs_leak_id, fs_leak_name, fs_stem, fs_override, fs_entity, fs_main to public;

create or replace function pg_temp.fs_probe(p_scope text, p_uid uuid, p_org uuid, p_branch uuid, p_own_branch uuid) returns void language plpgsql as $$
declare f record; base text; call text; v_out text; v_after text; leak text; variant text; ent text; args text; done boolean;
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, false);
  base := pg_temp.fs_fingerprint(p_org, p_branch);
  for f in select p.oid, p.proname, p.proretset, coalesce(p.proargnames[1:p.pronargs], array[]::text[]) as names, p.proargtypes::oid[] as types
             from pg_proc p
            where p.pronamespace = 'public'::regnamespace and p.proname like 'fn\_%' and p.prosecdef and p.prorettype <> 'trigger'::regtype and p.provariadic = 0
              and has_function_privilege('authenticated', p.oid, 'execute') and not has_function_privilege('anon', p.oid, 'execute')
            order by p.proname, p.oid loop
    for variant in select unnest(case when 'jsonb'::regtype::oid = any(f.types) then array['target', 'own_branch', 'row', 'row_own']
                                      when exists (select 1 from unnest(f.types) t where t in ('uuid'::regtype::oid, 'uuid[]'::regtype::oid)) then array['target', 'own_branch']
                                      else array['target'] end) loop
      for ent in select unnest(case when 'p_entity' = any(f.names) then array(select entity from fs_entity order by entity) else array[null::text] end) loop
        args := pg_temp.fs_args(p_scope, f.oid, p_own_branch, variant, ent);
        call := case when f.proretset then format('select string_agg(x::text, ''|'') from public.%I(%s) x', f.proname, args)
                     else format('select public.%I(%s)::text', f.proname, args) end;
        v_out := null; leak := null; v_after := null; done := false;
        begin
          execute 'set local role authenticated';
          execute call into v_out;
          execute 'reset role';
          done := true;
          select string_agg(distinct m[1], ' ') into leak
            from regexp_matches(coalesce(v_out, ''), '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})', 'g') m
           where exists (select 1 from fs_leak_id l where l.scope = p_scope and l.id = m[1]::uuid) and position(m[1] in args) = 0;
          if leak is null then
            select string_agg(n.name, ' / ') into leak from fs_leak_name n where n.scope = p_scope and position(n.name in coalesce(v_out, '')) > 0;
          end if;
          v_after := pg_temp.fs_fingerprint(p_org, p_branch);
          raise exception using errcode = 'P0F99', message = 'fs probe: undo';
        exception
          when sqlstate 'P0F99' then
            insert into fs_result values (p_scope, f.proname || coalesce('[' || ent || ']', ''), variant,
              case when leak is not null then 'LEAK-READ' when v_after <> base then 'LEAK-WRITE' else 'ran, nothing of the target' end,
              case when leak is not null then left(leak, 300) when v_after <> base then (
                select string_agg(split_part(x, ':', 1), ',') from (select unnest(string_to_array(v_after, ';')) except select unnest(string_to_array(base, ';'))) d(x)) else left(v_out, 120) end,
              left(args, 600));
          when others then
            insert into fs_result values (p_scope, f.proname || coalesce('[' || ent || ']', ''), variant, case when done then 'probe error' else 'refused' end, left(sqlstate || ' ' || sqlerrm, 160), left(args, 600));
        end;
      end loop;
    end loop;
  end loop;
end $$;


select pg_temp.fs_pick('hotel', '00000000-0000-0000-0000-000000000001', null);
select pg_temp.fs_leaks('hotel', '00000000-0000-0000-0000-000000000001', null, '00000000-0000-0000-0000-000000000002');
-- the same hotel again, with a row that has no branch first where a table has one (a hotel-wide ticket, note, account …)
select pg_temp.fs_pick('hotel0', '00000000-0000-0000-0000-000000000001', null, true);
select pg_temp.fs_leaks('hotel0', '00000000-0000-0000-0000-000000000001', null, '00000000-0000-0000-0000-000000000002');
select pg_temp.fs_pick('branch', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000010');
select pg_temp.fs_leaks('branch', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001');
select pg_temp.fs_pick('back', '00000000-0000-0000-0000-000000000002', null);
select pg_temp.fs_leaks('back', '00000000-0000-0000-0000-000000000002', null, '00000000-0000-0000-0000-000000000001');
select pg_temp.fs_probe('hotel', 'a0000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000001', null, '00000000-0000-0000-0000-000000000011');
select pg_temp.fs_probe('hotel0', 'a0000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000001', null, '00000000-0000-0000-0000-000000000011');
select pg_temp.fs_probe('branch', 'a0000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000012');
select pg_temp.fs_probe('back', 'a0000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002', null, '00000000-0000-0000-0000-000000000010');
select set_config('request.jwt.claim.sub', '', false), set_config('request.jwt.claims', '{"role":"anon"}', false);

do $$ declare leak text; begin
  select string_agg(fn || ' (' || variant || '): ' || outcome || ' ' || left(coalesce(detail, ''), 90), '; ' order by fn, variant) into leak
    from fs_result where scope in ('hotel', 'hotel0') and outcome not in ('refused', 'ran, nothing of the target');
  perform fs_record('FS10 the other hotel''s owner, calling every function with this hotel''s ids (its branches'' rows, then its rows without a branch), gets nothing of this hotel and changes none of its rows', leak is null, leak);
  select string_agg(fn || ' (' || variant || '): ' || outcome || ' ' || left(coalesce(detail, ''), 90), '; ' order by fn, variant) into leak
    from fs_result where scope = 'branch' and outcome not in ('refused', 'ran, nothing of the target');
  perform fs_record('FS11 branch B''s supervisor, calling every function with branch A''s ids, gets nothing of branch A and changes none of its rows', leak is null, leak);
  select string_agg(fn || ' (' || variant || '): ' || outcome || ' ' || left(coalesce(detail, ''), 90), '; ' order by fn, variant) into leak
    from fs_result where scope = 'back' and outcome not in ('refused', 'ran, nothing of the target');
  perform fs_record('FS12 this hotel''s owner, calling every function with the other hotel''s ids, gets nothing of it and changes none of its rows', leak is null, leak);
end $$;
do $$ declare missed text; n int; conclusive int; ratio numeric; begin
  select string_agg(p.proname, ', ' order by p.proname) into missed from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname like 'fn\_%' and p.prosecdef and p.prorettype <> 'trigger'::regtype and p.provariadic = 0
     and has_function_privilege('authenticated', p.oid, 'execute') and not has_function_privilege('anon', p.oid, 'execute')
     and not exists (select 1 from fs_result r where r.scope = 'hotel' and split_part(r.fn, '[', 1) = p.proname);
  select count(distinct fn), count(distinct fn) filter (where outcome like 'ran%' or detail like '42501%' or detail ~ '(NOT_FOUND|FORBIDDEN|TOKEN_INVALID|BRANCH_MISMATCH|HOTEL_MISMATCH)')
    into n, conclusive from fs_result where scope = 'hotel';
  ratio := round(100.0 * conclusive / greatest(n, 1), 1);
  perform fs_record('FS13 the probe calls every function a staff member may call and a visitor may not, and reaches a check or an answer in at least 85% of them (' || conclusive || ' of ' || n || ', ' || ratio || '%)',
    missed is null and ratio >= 85, coalesce(missed, ''));
end $$;

select case when ok then 'PASS' else 'FAIL' end as result, name, case when ok then null else left(detail, 1500) end as detail from test_results order by name;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from test_results where ok is not true) then raise exception 'FUNCTION SCOPE TESTS FAILED'; end if;
  if (select count(*) from test_results) < 9 then raise exception 'FUNCTION SCOPE TESTS INCOMPLETE: % of 9 checks ran', (select count(*) from test_results); end if;
end $$;
