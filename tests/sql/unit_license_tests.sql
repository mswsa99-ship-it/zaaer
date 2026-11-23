-- =====================================================================
-- The unit's licence number (UL*; migration 0075, plan item 1.8): read by the owner, the manager and the supervisor
-- of the unit's branch and by no one else — not a visitor, not finance, not housekeeping, not another branch's
-- supervisor, not another organisation; changed by those three when the matrix lets them edit the units
-- («definitions»); Latin letters, digits, «-» and «/» up to 40; logged with its last four characters only; and kept
-- in a table no role reads, which only the two functions of 0075 mention.
-- Fixtures (security_tests.sql, core_tests.sql): owner 10..01, supervisor 10..02, housekeeping 10..03 and finance
-- 10..04 on branch 10; supervisor 10..06 on branch 12 only; manager 10..08 on branch 10; the other organisation's
-- owner 10..05. Units: 101 (00..100) on branch 10.
-- =====================================================================
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create or replace function ul_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;
create or replace function ul_login(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), false);
  perform set_config('request.jwt.claims', case when p_uid is null then '{"role":"anon"}' else json_build_object('sub', p_uid, 'role', 'authenticated')::text end, false);
end $$;
-- what the table holds, read as its owner (the tests' own eyes; no role can do this)
create or replace function ul_stored(p_room uuid) returns text language sql security definer as $$
  select license_number from room_licenses where room_id = p_room
$$;
create or replace function ul_last_log(p_room uuid) returns audit_events language sql security definer as $$
  select * from audit_events where action = 'room.license_set' and entity_id = p_room order by created_at desc, id desc limit 1
$$;
grant execute on function ul_stored(uuid), ul_last_log(uuid) to public;

-- ---------------------------------------------------------------- UL01 a visitor cannot read or write it
select ul_login(null);
set role anon;
do $$ declare e1 text; e2 text; begin
  begin perform fn_room_licenses('00000000-0000-0000-0000-000000000010'); e1 := 'accepted'; exception when others then e1 := sqlerrm; end;
  begin perform fn_admin_set_room_license('00000000-0000-0000-0000-000000000100', 'X1'); e2 := 'accepted'; exception when others then e2 := sqlerrm; end;
  perform ul_record('UL01 a visitor can neither read the licence numbers nor set one', e1 like '%permission denied%' and e2 like '%permission denied%', e1 || ' | ' || e2);
end $$;
reset role;

-- ---------------------------------------------------------------- UL02–UL03 the owner sets one; the number's rule
select ul_login('a0000000-0000-0000-0000-000000000001');
set role authenticated;
do $$ declare r jsonb; l jsonb; begin
  r := fn_admin_set_room_license('00000000-0000-0000-0000-000000000100', '  tl-٢٠٢٥/0101 ');
  l := fn_room_licenses('00000000-0000-0000-0000-000000000010');
  perform ul_record('UL02 the owner sets unit 101''s licence: Arabic-Indic digits read as Latin, letters in capitals, spaces trimmed; the branch''s list shows it',
    r->>'license_number' = 'TL-2025/0101' and ul_stored('00000000-0000-0000-0000-000000000100') = 'TL-2025/0101'
    and exists (select 1 from jsonb_array_elements(l) x where x->>'room_id' = '00000000-0000-0000-0000-000000000100' and x->>'license_number' = 'TL-2025/0101'),
    r::text || ' | ' || l::text);
exception when others then perform ul_record('UL02 the owner sets unit 101''s licence', false, sqlerrm);
end $$;
do $$ declare bad text; out text := ''; ok boolean := true; e text; begin
  foreach bad in array array['ترخيص 12', 'A B', '-ABC', '/12', 'A_1', 'A.1', repeat('9', 41)] loop
    begin perform fn_admin_set_room_license('00000000-0000-0000-0000-000000000100', bad); e := 'accepted'; exception when others then e := sqlerrm; end;
    ok := ok and e = 'VALIDATION: room_license'; out := out || bad || '→' || e || ' ';
  end loop;
  perform ul_record('UL03 a number with Arabic letters, a space, a leading «-» or «/», another symbol or more than 40 characters is refused and the stored one stays',
    ok and ul_stored('00000000-0000-0000-0000-000000000100') = 'TL-2025/0101', out);
end $$;
reset role;

-- ---------------------------------------------------------------- UL04–UL05 the manager edits; the supervisor reads
select ul_login('a0000000-0000-0000-0000-000000000008');
set role authenticated;
do $$ declare r jsonb; l jsonb; begin
  l := fn_room_licenses('00000000-0000-0000-0000-000000000010');
  r := fn_admin_set_room_license('00000000-0000-0000-0000-000000000100', 'TL-2025/0102');
  perform ul_record('UL04 the branch''s manager reads the licence and changes it',
    l::text like '%TL-2025/0101%' and r->>'license_number' = 'TL-2025/0102' and ul_stored('00000000-0000-0000-0000-000000000100') = 'TL-2025/0102', l::text || ' | ' || r::text);
exception when others then perform ul_record('UL04 the branch''s manager reads the licence and changes it', false, sqlerrm);
end $$;
reset role;
select ul_login('a0000000-0000-0000-0000-000000000002');
set role authenticated;
do $$ declare l jsonb; e text; begin
  l := fn_room_licenses('00000000-0000-0000-0000-000000000010');
  begin perform fn_admin_set_room_license('00000000-0000-0000-0000-000000000100', 'SUP-1'); e := 'accepted'; exception when others then e := sqlerrm; end;
  perform ul_record('UL05 the branch''s supervisor reads the licence but, without «definitions» in the matrix, cannot change it',
    l::text like '%TL-2025/0102%' and e like 'FORBIDDEN%' and ul_stored('00000000-0000-0000-0000-000000000100') = 'TL-2025/0102', l::text || ' | ' || e);
exception when others then perform ul_record('UL05 the branch''s supervisor reads the licence', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- UL06–UL07 finance and housekeeping: nothing
select ul_login('a0000000-0000-0000-0000-000000000004');
set role authenticated;
do $$ declare e1 text; e2 text; begin
  begin perform fn_room_licenses('00000000-0000-0000-0000-000000000010'); e1 := 'accepted'; exception when others then e1 := sqlerrm; end;
  begin perform fn_admin_set_room_license('00000000-0000-0000-0000-000000000100', 'FIN-1'); e2 := 'accepted'; exception when others then e2 := sqlerrm; end;
  perform ul_record('UL06 finance on the same branch can neither read nor set a licence', e1 like 'FORBIDDEN%' and e2 like 'FORBIDDEN%', e1 || ' | ' || e2);
end $$;
reset role;
select ul_login('a0000000-0000-0000-0000-000000000003');
set role authenticated;
do $$ declare e1 text; e2 text; begin
  begin perform fn_room_licenses('00000000-0000-0000-0000-000000000010'); e1 := 'accepted'; exception when others then e1 := sqlerrm; end;
  begin perform fn_admin_set_room_license('00000000-0000-0000-0000-000000000100', 'HK-1'); e2 := 'accepted'; exception when others then e2 := sqlerrm; end;
  perform ul_record('UL07 housekeeping on the same branch can neither read nor set a licence', e1 like 'FORBIDDEN%' and e2 like 'FORBIDDEN%', e1 || ' | ' || e2);
end $$;
reset role;

-- ---------------------------------------------------------------- UL08–UL09 another branch, another organisation
select ul_login('a0000000-0000-0000-0000-000000000006');
set role authenticated;
do $$ declare e1 text; own jsonb; begin
  begin perform fn_room_licenses('00000000-0000-0000-0000-000000000010'); e1 := 'accepted'; exception when others then e1 := sqlerrm; end;
  own := fn_room_licenses('00000000-0000-0000-0000-000000000012');
  perform ul_record('UL08 a supervisor of branch B reads branch B''s licences, not branch 10''s', e1 like 'FORBIDDEN%' and jsonb_typeof(own) = 'array' and own::text not like '%TL-2025%', e1 || ' | ' || own::text);
exception when others then perform ul_record('UL08 a supervisor of branch B reads branch B''s licences, not branch 10''s', false, sqlerrm);
end $$;
reset role;
select ul_login('a0000000-0000-0000-0000-000000000005');
set role authenticated;
do $$ declare e1 text; e2 text; begin
  begin perform fn_room_licenses('00000000-0000-0000-0000-000000000010'); e1 := 'accepted'; exception when others then e1 := sqlerrm; end;
  begin perform fn_admin_set_room_license('00000000-0000-0000-0000-000000000100', 'ORG2-1'); e2 := 'accepted'; exception when others then e2 := sqlerrm; end;
  perform ul_record('UL09 the owner of another organisation can neither read nor set this organisation''s licences', e1 like 'FORBIDDEN%' and e2 like 'FORBIDDEN%'
    and ul_stored('00000000-0000-0000-0000-000000000100') = 'TL-2025/0102', e1 || ' | ' || e2);
end $$;
reset role;

-- ---------------------------------------------------------------- UL10 the log: who and when, the last four characters only
do $$ declare e audit_events%rowtype; begin
  e := ul_last_log('00000000-0000-0000-0000-000000000100');
  perform ul_record('UL10 the change is in the log as «room.license_set» on the unit, by the manager, with the last four characters only, and reads in Arabic',
    e.actor_id = '10000000-0000-0000-0000-000000000008' and e.entity_type = 'room'
    and e.details->'before'->>'license_number' = '…0101' and e.details->'after'->>'license_number' = '…0102'
    and e.details::text not like '%TL-2025%' and fn_audit_action_label('room.license_set') = 'تعديل رقم ترخيص الوحدة'
    and (select count(*) from regexp_matches(pg_get_functiondef('fn_audit_action_label(text)'::regprocedure), 'fn_audit_unit_label\(p_action\)', 'g')) = 1,
    e.details::text);
end $$;

-- ---------------------------------------------------------------- UL11 no other way to it
select ul_login('a0000000-0000-0000-0000-000000000001');
set role authenticated;
do $$ declare e text; begin
  begin perform 1 from room_licenses limit 1; e := 'accepted'; exception when others then e := sqlerrm; end;
  perform ul_record('UL11 even the owner cannot select the table directly; only fn_room_licenses and fn_admin_set_room_license mention it',
    e like '%permission denied%'
    and not has_table_privilege('authenticated', 'public.room_licenses', 'select') and not has_table_privilege('anon', 'public.room_licenses', 'select')
    and (select string_agg(p.proname, ',' order by p.proname) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prosrc like '%room_licenses%' and p.proname !~ '^ul_')
        = 'fn_admin_set_room_license,fn_room_licenses',
    e);
end $$;
reset role;

-- ---------------------------------------------------------------- UL12 an empty number clears it
select ul_login('a0000000-0000-0000-0000-000000000001');
set role authenticated;
do $$ declare r jsonb; l jsonb; again jsonb; e audit_events%rowtype; begin
  r := fn_admin_set_room_license('00000000-0000-0000-0000-000000000100', '   ');
  l := fn_room_licenses('00000000-0000-0000-0000-000000000010');
  again := fn_admin_set_room_license('00000000-0000-0000-0000-000000000100', null);
  e := ul_last_log('00000000-0000-0000-0000-000000000100');
  perform ul_record('UL12 an empty number clears the licence, the list no longer shows it, clearing twice changes nothing, and the log says it was cleared',
    r->>'license_number' is null and ul_stored('00000000-0000-0000-0000-000000000100') is null and l::text not like '%00000000-0000-0000-0000-000000000100%'
    and (again->>'unchanged')::boolean and e.details->'before'->>'license_number' = '…0102' and e.details->'after'->>'license_number' is null,
    r::text || ' | ' || l::text || ' | ' || again::text);
exception when others then perform ul_record('UL12 an empty number clears the licence', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- UL13 the matrix opens editing to a reader role only
-- the owner ticks «definitions» for the supervisor and for finance: the supervisor may now set it; finance still may not
insert into role_permissions(organization_id, capability, role, allowed) values
 ('00000000-0000-0000-0000-000000000001', 'definitions', 'supervisor', true),
 ('00000000-0000-0000-0000-000000000001', 'definitions', 'finance', true)
on conflict (organization_id, capability, role) do update set allowed = excluded.allowed;
select ul_login('a0000000-0000-0000-0000-000000000002');
set role authenticated;
do $$ declare r jsonb; begin
  r := fn_admin_set_room_license('00000000-0000-0000-0000-000000000100', 'SUP-1');
  perform ul_record('UL13a with «definitions» ticked, the supervisor sets the licence', r->>'license_number' = 'SUP-1', r::text);
exception when others then perform ul_record('UL13a with «definitions» ticked, the supervisor sets the licence', false, sqlerrm);
end $$;
reset role;
select ul_login('a0000000-0000-0000-0000-000000000004');
set role authenticated;
do $$ declare e1 text; e2 text; begin
  begin perform fn_admin_set_room_license('00000000-0000-0000-0000-000000000100', 'FIN-2'); e1 := 'accepted'; exception when others then e1 := sqlerrm; end;
  begin perform fn_room_licenses('00000000-0000-0000-0000-000000000010'); e2 := 'accepted'; exception when others then e2 := sqlerrm; end;
  perform ul_record('UL13b with «definitions» ticked, finance still can neither set nor read a licence (only the three reader roles)',
    e1 like 'FORBIDDEN%' and e2 like 'FORBIDDEN%' and ul_stored('00000000-0000-0000-0000-000000000100') = 'SUP-1', e1 || ' | ' || e2);
end $$;
reset role;
-- the matrix as it was, and the unit without a licence, for the files after this one
delete from role_permissions where organization_id = '00000000-0000-0000-0000-000000000001' and capability = 'definitions' and role in ('supervisor', 'finance');
update room_licenses set license_number = null where room_id = '00000000-0000-0000-0000-000000000100';

select ul_login(null);
select case when ok then 'PASS' else 'FAIL' end as result, name, case when ok then null else detail end as detail from test_results order by name;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from test_results;
