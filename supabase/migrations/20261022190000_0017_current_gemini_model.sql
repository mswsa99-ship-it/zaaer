/*
# 0017 — A Gemini model a new API key can actually call

Google shut the Gemini 2.0 models down in June 2026 and limited the 2.5 models to accounts that were already using
them (September 2026). A key created today gets an error for 'gemini-2.5-flash', so a new install with that default
would quietly answer every guest from the scripted path. The default becomes 'gemini-3.8-flash' (GA September 2026);
_shared/llm.ts handles what the 3.x generation needs (thinking level, thought signatures on tool steps).

Settings still pointing at a 1.x / 2.x model are moved once, with an audit event per organization. Any other model —
one an owner picked on purpose — is left as it is.
*/
alter table ai_settings alter column model set default 'gemini-3.8-flash';

do $$
declare r record;
begin
  for r in select organization_id, model from ai_settings where model ~ '^gemini-[12][.]' loop
    update ai_settings set model = 'gemini-3.8-flash', updated_at = now() where organization_id = r.organization_id;
    perform fn_audit(r.organization_id, null, null, 'ai_settings_updated', 'ai_settings', r.organization_id,
      jsonb_build_object('model', 'gemini-3.8-flash', 'previous_model', r.model,
                         'reason', 'migration 0017: Gemini 1.x/2.x models are not available to new API keys'));
  end loop;
end $$;
