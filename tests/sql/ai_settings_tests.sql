-- =====================================================================
-- AI settings tests (AS01–AS10): fallback models (migration 0018) and who may change them.
-- Runs after the other files on the same DB (reuses org 1: owner a…01, supervisor a…02).
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
create or replace function t_fallbacks() returns text[] language sql security definer as $$
  select fallback_models from ai_settings where organization_id = '00000000-0000-0000-0000-000000000001'
$$;
create or replace function t_last_ai_audit() returns jsonb language sql security definer as $$
  select details from audit_events where action = 'ai_settings_updated' and organization_id = '00000000-0000-0000-0000-000000000001'
  order by created_at desc, id desc limit 1
$$;

-- AS01 the column default: current models only (Gemini 1.x/2.x cannot be called by new keys — 0017)
select t_record('AS01 settings get two current fallback models by default, none of them 1.x/2.x',
  t_fallbacks() = '{gemini-3.6-flash,gemini-3.5-flash-lite}'
  and not exists (select 1 from ai_settings, unnest(fallback_models) m where m ~ '^gemini-[12][.]')
  and (select column_default from information_schema.columns where table_schema = 'public' and table_name = 'ai_settings' and column_name = 'fallback_models') !~ 'gemini-[12][.]',
  array_to_string(t_fallbacks(), ','));

select t_login('a0000000-0000-0000-0000-000000000001','owner@test.local');
set role authenticated;

do $$ begin
  perform fn_admin_update_ai_settings(jsonb_build_object('fallback_models', jsonb_build_array('gemini-3.5-flash-lite', ' Gemini-3.8-Flash ', 'gemini-3.5-flash-lite', '')));
  perform t_record('AS02 owner sets the list: trimmed, lower-cased, blanks and repeats dropped, order kept',
    t_fallbacks() = '{gemini-3.5-flash-lite,gemini-3.8-flash}', array_to_string(t_fallbacks(), ','));
  perform t_record('AS03 the change is audited with the stored list and the previous one',
    t_last_ai_audit()->'fallback_models' = '["gemini-3.5-flash-lite","gemini-3.8-flash"]'::jsonb
    and t_last_ai_audit()->'previous_fallback_models' = '["gemini-3.6-flash","gemini-3.5-flash-lite"]'::jsonb,
    t_last_ai_audit()::text);

  perform fn_admin_update_ai_settings('{"temperature": 0.3}'::jsonb);
  perform t_record('AS04 a save without the list keeps it', t_fallbacks() = '{gemini-3.5-flash-lite,gemini-3.8-flash}', array_to_string(t_fallbacks(), ','));

  begin
    perform fn_admin_update_ai_settings('{"fallback_models": ["gemini-3.6-flash; select 1"]}'::jsonb);
    perform t_record('AS05 something that is not a model id is rejected', false, 'accepted');
  exception when others then
    perform t_record('AS05 something that is not a model id is rejected', sqlerrm like 'VALIDATION%' and t_fallbacks() = '{gemini-3.5-flash-lite,gemini-3.8-flash}', sqlerrm);
  end;
  begin
    perform fn_admin_update_ai_settings('{"fallback_models": ["m-1", "m-2", "m-3", "m-4"]}'::jsonb);
    perform t_record('AS06 more than three fallback models are rejected', false, 'accepted');
  exception when others then perform t_record('AS06 more than three fallback models are rejected', sqlerrm like 'VALIDATION%', sqlerrm); end;
  begin
    perform fn_admin_update_ai_settings('{"fallback_models": "gemini-3.6-flash"}'::jsonb);
    perform t_record('AS07 a value that is not a list is rejected', false, 'accepted');
  exception when others then perform t_record('AS07 a value that is not a list is rejected', sqlerrm like 'VALIDATION%', sqlerrm); end;

  perform fn_admin_update_ai_settings('{"fallback_models": []}'::jsonb);
  perform t_record('AS08 an empty list turns fallback off', cardinality(t_fallbacks()) = 0, array_to_string(t_fallbacks(), ','));
end $$;
reset role;

select t_login('a0000000-0000-0000-0000-000000000002','sup@test.local');
set role authenticated;
do $$ begin
  begin
    perform fn_admin_update_ai_settings('{"fallback_models": ["gemini-3.6-flash"]}'::jsonb);
    perform t_record('AS09 a supervisor cannot change the AI settings', false, 'accepted');
  exception when others then perform t_record('AS09 a supervisor cannot change the AI settings', sqlerrm like 'FORBIDDEN%', sqlerrm); end;
end $$;
reset role;

-- AS10 writes that bypass the RPC (SQL editor, service role) meet the same shape in the table itself
do $$
declare c text;
begin
  foreach c in array array['{"Gemini 3"}', '{"a,b",c}', '{m-1,""}', '{m-1,NULL}', '{m-1,m-2,m-3,m-4}'] loop
    begin
      update ai_settings set fallback_models = c::text[] where organization_id = '00000000-0000-0000-0000-000000000001';
      perform t_record('AS10 the table itself rejects ' || c, false, 'accepted');
    exception when check_violation then perform t_record('AS10 the table itself rejects ' || c, true, sqlerrm); end;
  end loop;
  update ai_settings set fallback_models = '{gemini-3.6-flash,gemini-4-argon}' where organization_id = '00000000-0000-0000-0000-000000000001';
  perform t_record('AS10b and accepts a well-formed one', t_fallbacks() = '{gemini-3.6-flash,gemini-4-argon}', array_to_string(t_fallbacks(), ','));
end $$;

-- leave org 1 as a fresh install would have it
update ai_settings set fallback_models = default where organization_id = '00000000-0000-0000-0000-000000000001';

reset role;
select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),110) as detail from test_results order by ok, name;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from test_results where not ok) then raise exception 'AI SETTINGS TESTS FAILED'; end if;
end $$;
