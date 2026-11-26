-- 0149 rollback. Policy links and overrides go away (branch texts stay as they are: each row already holds its own text);
-- the knowledge functions return to their 0010 / 0055 definitions. Branch overrides of shared entries become ordinary
-- branch entries (the shared entry shows again beside them, as before 0149).
drop function if exists fn_policy_masters_list(), fn_policy_master_preview(jsonb), fn_policy_master_apply(jsonb), fn_policy_branch_revert(uuid, text[], text),
  fn_policy_plan(uuid, jsonb), fn_policy_master_input(jsonb, uuid), fn_policy_gate(uuid), fn_policy_masters_of(uuid),
  fn_knowledge_main_preview(uuid, jsonb), fn_knowledge_main_apply(uuid, jsonb), fn_knowledge_plan(uuid, uuid, jsonb), fn_knowledge_gate(uuid),
  fn_knowledge_branch_override(uuid, uuid, jsonb), fn_knowledge_revert_override(uuid, text), fn_knowledge_effective(uuid);
drop trigger if exists trg_policy_inherit on property_policies;
drop function if exists fn_trg_policy_inherit();
create or replace function fn_public_knowledge(p_branch uuid)
returns table (id uuid, category text, question text, keywords text[], answer text, priority int)
language sql stable security definer set search_path = public as $$
  select k.id, k.category, k.question, k.keywords, k.answer, k.priority
  from knowledge_entries k
  join branches b on b.id = p_branch and b.organization_id = k.organization_id
  where k.is_public and k.is_active and k.archived_at is null
    and (k.branch_id is null or k.branch_id = p_branch)
  order by k.priority desc, k.used_count desc, k.created_at;
$$;
create or replace function fn_staff_knowledge(p_branch uuid)
returns table (id uuid, category text, question text, keywords text[], answer text, priority int, is_public boolean)
language sql stable security definer set search_path = public as $$
  select k.id, k.category, k.question, k.keywords, k.answer, k.priority, k.is_public
  from knowledge_entries k
  where k.organization_id = fn_user_org_id() and p_branch in (select fn_user_branch_ids())
    and k.is_active and k.archived_at is null and (k.branch_id is null or k.branch_id = p_branch)
  order by k.priority desc, k.used_count desc, k.created_at;
$$;
create or replace function public.fn_admin_upsert_knowledge(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $function$
declare k knowledge_entries%rowtype; v_org uuid; v_branch uuid; v_kw text[]; v_before jsonb; v_q text; v_a text; v_other uuid; v_active boolean;
begin
  perform fn_require_cap('knowledge');
  v_org := fn_user_org_id();
  v_branch := nullif(p->>'branch_id','')::uuid;
  if v_branch is not null then perform fn_require_branch(v_branch);
  elsif not fn_has_role('owner','manager') then raise exception 'FORBIDDEN: org-wide entries require manager' using errcode = '42501'; end if;
  v_q := trim(coalesce(p->>'question',''));  v_a := trim(coalesce(p->>'answer',''));
  if char_length(v_q) < 3 then raise exception 'VALIDATION: question'; end if;
  if char_length(v_a) < 2 then raise exception 'VALIDATION: answer'; end if;
  if (p->>'id') is not null then
    select * into k from knowledge_entries where id = (p->>'id')::uuid and organization_id = v_org for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    if not (p ? 'branch_id') then v_branch := k.branch_id; end if;
  end if;
  v_active := coalesce((p->>'is_active')::boolean, k.is_active, true);
  -- SETUP-13 (owner's decision): another active answer to the same question, for the same guests, is not added beside it;
  -- the existing one is edited instead
  if v_active then
    select x.id into v_other from knowledge_entries x
    where x.organization_id = v_org and x.archived_at is null and x.is_active and x.id is distinct from k.id
      and (x.branch_id is null or v_branch is null or x.branch_id = v_branch)
      and fn_knowledge_question_key(x.question) = fn_knowledge_question_key(v_q)
    limit 1;
    if v_other is not null then raise exception 'KNOWLEDGE_CONFLICT: %', v_other; end if;
  end if;
  -- normalized, de-duplicated, non-empty keywords; the question's own words are matched separately
  select coalesce(array_agg(distinct w order by w), '{}') into v_kw
  from (select fn_normalize_ar(x) w from jsonb_array_elements_text(coalesce(p->'keywords','[]'::jsonb)) x) s
  where char_length(w) >= 2;
  if (p->>'id') is null then
    insert into knowledge_entries(organization_id, branch_id, category, question, keywords, answer, answer_en, is_public, is_active, priority, created_by, updated_by)
    values (v_org, v_branch, coalesce(p->>'category','general'), v_q, v_kw, v_a, nullif(trim(coalesce(p->>'answer_en','')),''),
            coalesce((p->>'is_public')::boolean, true), coalesce((p->>'is_active')::boolean, true), coalesce((p->>'priority')::int, 0), fn_staff_id(), fn_staff_id())
    returning * into k;
    perform fn_audit(v_org, v_branch, fn_staff_id(), 'knowledge.created', 'knowledge_entry', k.id, jsonb_build_object('after', jsonb_build_object('question', k.question, 'keywords', k.keywords, 'is_public', k.is_public)));
  else
    if k.branch_id is not null then perform fn_require_branch(k.branch_id); end if;
    if (p->>'version') is null then raise exception 'VERSION_REQUIRED'; end if;
    perform fn_check_version(k.version, (p->>'version')::int);
    v_before := jsonb_build_object('question', k.question, 'answer', k.answer, 'keywords', k.keywords, 'is_public', k.is_public, 'is_active', k.is_active, 'category', k.category, 'branch_id', k.branch_id);
    update knowledge_entries set
      branch_id = case when p ? 'branch_id' then v_branch else branch_id end,
      category = coalesce(p->>'category', category), question = v_q, keywords = v_kw, answer = v_a,
      answer_en = case when p ? 'answer_en' then nullif(trim(coalesce(p->>'answer_en','')),'') else answer_en end,
      is_public = coalesce((p->>'is_public')::boolean, is_public), is_active = coalesce((p->>'is_active')::boolean, is_active),
      priority = coalesce((p->>'priority')::int, priority), version = version + 1, updated_by = fn_staff_id(), updated_at = now()
    where id = k.id returning * into k;
    perform fn_audit(v_org, k.branch_id, fn_staff_id(), 'knowledge.updated', 'knowledge_entry', k.id,
      jsonb_build_object('before', v_before, 'after', jsonb_build_object('question', k.question, 'answer', k.answer, 'keywords', k.keywords, 'is_public', k.is_public, 'is_active', k.is_active, 'category', k.category, 'branch_id', k.branch_id), 'reason', p->>'reason'));
  end if;
  -- an unanswered question linked to this entry is now answered
  if (p->>'unanswered_id') is not null then
    update unanswered_questions set status = 'answered', knowledge_entry_id = k.id, resolved_by = fn_staff_id(), resolved_at = now()
    where id = (p->>'unanswered_id')::uuid and organization_id = v_org;
  end if;
  return jsonb_build_object('ok', true, 'id', k.id, 'version', k.version);
end $function$;
alter table knowledge_entries drop column if exists overrides_entry_id;
alter table property_policies drop column if exists override_fields, drop column if exists master_version, drop column if exists master_id;
alter table system_settings drop constraint if exists system_settings_policy_masters_array;
alter table system_settings drop column if exists policy_masters;
