/*
# 0018 — Fallback models for the AI assistants

Google answers "503: This model is currently experiencing high demand" for a single model for hours at a time,
sometimes for one key only, while other current models keep answering. With one model configured, every guest
then gets the scripted path. ai_settings.fallback_models lists up to three models to try, in order, after the
configured one (same time budget; _shared/llm.ts). The owner edits it on /admin/ai-settings; an empty list turns
fallback off. Defaults: two current GA models with their own capacity (gemini-3.6-flash, gemini-3.5-flash-lite).

fn_admin_update_ai_settings accepts the list (JSON array), normalizes it (trimmed, lower-case, no blanks or
repeats, order kept), rejects anything that is not a model id, and audits the stored value with the previous one.
The CHECK constraint holds the same shape for writes that do not go through the RPC.
*/
alter table ai_settings add column if not exists fallback_models text[] not null default '{gemini-3.6-flash,gemini-3.5-flash-lite}';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'ai_settings_fallback_models_valid' and conrelid = 'ai_settings'::regclass) then
    -- every element a model id: the joined list matches id(,id)* AND has exactly one comma per separator
    -- (so no single element can smuggle a comma, a blank or anything else into the list)
    alter table ai_settings add constraint ai_settings_fallback_models_valid check (
      cardinality(fallback_models) <= 3
      and array_position(fallback_models, null) is null
      and (cardinality(fallback_models) = 0
           or (array_to_string(fallback_models, ',') ~ '^[a-z0-9][a-z0-9.-]{0,62}(,[a-z0-9][a-z0-9.-]{0,62}){0,2}$'
               and length(array_to_string(fallback_models, ',')) - length(replace(array_to_string(fallback_models, ','), ',', ''))
                   = cardinality(fallback_models) - 1)));
  end if;
end $$;

create or replace function fn_admin_update_ai_settings(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_fallbacks text[]; v_previous text[];
begin
  perform fn_require_role('owner');
  if p ? 'fallback_models' then
    if jsonb_typeof(p->'fallback_models') <> 'array' then raise exception 'VALIDATION: fallback_models must be a list'; end if;
    select coalesce(array_agg(m order by i), '{}') into v_fallbacks
    from (select lower(btrim(e.v)) as m, min(e.i) as i
          from jsonb_array_elements_text(p->'fallback_models') with ordinality as e(v, i)
          where btrim(e.v) <> ''
          group by 1) s;
    if cardinality(v_fallbacks) > 3 then raise exception 'VALIDATION: at most 3 fallback models'; end if;
    if exists (select 1 from unnest(v_fallbacks) m where m !~ '^[a-z0-9][a-z0-9.-]{0,62}$') then
      raise exception 'VALIDATION: fallback_models must be model ids (a-z 0-9 . -)';
    end if;
  end if;
  insert into ai_settings(organization_id) values (fn_user_org_id()) on conflict do nothing;
  select fallback_models into v_previous from ai_settings where organization_id = fn_user_org_id();
  update ai_settings set
    enabled = coalesce((p->>'enabled')::boolean, enabled),
    provider = coalesce(p->>'provider', provider),
    model = coalesce(nullif(trim(p->>'model'),''), model),
    fallback_models = coalesce(v_fallbacks, fallback_models),
    temperature = coalesce((p->>'temperature')::numeric, temperature),
    max_output_tokens = coalesce((p->>'max_output_tokens')::int, max_output_tokens),
    timeout_ms = coalesce((p->>'timeout_ms')::int, timeout_ms),
    daily_request_limit = coalesce((p->>'daily_request_limit')::int, daily_request_limit),
    daily_token_budget = coalesce((p->>'daily_token_budget')::int, daily_token_budget),
    per_session_message_limit = coalesce((p->>'per_session_message_limit')::int, per_session_message_limit),
    strict_scope = coalesce((p->>'strict_scope')::boolean, strict_scope),
    extra_instructions = coalesce(p->>'extra_instructions', extra_instructions),
    ops_enabled = coalesce((p->>'ops_enabled')::boolean, ops_enabled),
    ops_daily_request_limit = coalesce((p->>'ops_daily_request_limit')::int, ops_daily_request_limit),
    briefing_with_insights = coalesce((p->>'briefing_with_insights')::boolean, briefing_with_insights),
    updated_by = fn_staff_id(), updated_at = now()
  where organization_id = fn_user_org_id();
  perform fn_audit(fn_user_org_id(), null, fn_staff_id(), 'ai_settings_updated', 'ai_settings', fn_user_org_id(),
    (p - 'extra_instructions' - 'fallback_models')
    || case when v_fallbacks is null then '{}'::jsonb
            else jsonb_build_object('fallback_models', to_jsonb(v_fallbacks), 'previous_fallback_models', to_jsonb(v_previous)) end);
  return jsonb_build_object('ok', true);
end $$;
grant execute on function fn_admin_update_ai_settings(jsonb) to authenticated;
