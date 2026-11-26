/*
# 0149 — Policies and knowledge base: entered once at the hotel level, inherited by the branches

Owner's decision (WhatsApp 26 Nov 2026, 13:52 request, 14:06 approval): the hotel's policies and the assistant's
knowledge base are entered once, copied to every branch, and a branch may change its own copy (e.g. a different check-in
time in one branch). Changing the hotel-level text never silently erases a branch's own change: by default a branch's
customised fields are kept; the hotel-level change overwrites a branch only when that branch is chosen explicitly, and
before anything is written a preview names the branches and the fields it will change.

Policies (property_policies is one row per branch, kept as it is):
  - the hotel-level texts live in policy_masters (one row per hotel and topic; no direct client access, RPCs only).
  - property_policies gets master_id / master_version / override_fields. A row with master_id null is a branch's own
    policy exactly as before (every existing row stays that way: existing texts are preserved untouched).
  - a branch row linked to a master inherits title, content_ar, content_en, is_public except the fields listed in
    override_fields. Editing a linked row directly (the existing screen) marks the changed fields as overrides (trigger).
Knowledge base (knowledge_entries already has branch_id null = shared by every branch):
  - overrides_entry_id: a branch's own version of a shared entry; the shared entry is hidden for that branch while the
    override is active and not archived. Reverting = archiving the override (nothing is erased).
Scope: policies and knowledge only. No tax, deposit, legal or language fields. Additive only.
*/

create table if not exists policy_masters (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  topic text not null check (topic in ('checkin','cancellation','wifi','parking','location','children','contact','stay','privacy','other')),
  topic_label text,
  title text not null,
  content_ar text not null,
  content_en text,
  is_public boolean not null default true,
  sort_order int not null default 0,
  version int not null default 1,
  archived_at timestamptz,
  created_by uuid, updated_by uuid,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  constraint policy_masters_len check (char_length(title) between 1 and 120 and char_length(content_ar) between 1 and 4000)
);
create unique index if not exists uq_policy_masters_topic on policy_masters(organization_id, topic) where topic <> 'other' and archived_at is null;
alter table policy_masters enable row level security;
revoke all on policy_masters from anon, authenticated;   -- read and written only through the RPCs below

alter table property_policies add column if not exists master_id uuid references policy_masters(id);
alter table property_policies add column if not exists master_version int;
alter table property_policies add column if not exists override_fields text[] not null default '{}';
create index if not exists idx_policies_master on property_policies(master_id) where master_id is not null;

alter table knowledge_entries add column if not exists overrides_entry_id uuid references knowledge_entries(id) on delete set null;
create index if not exists idx_knowledge_overrides on knowledge_entries(overrides_entry_id) where overrides_entry_id is not null;

-- the new pointers are checked to stay inside the hotel, as every other pointer between hotel tables is (0078)
create or replace trigger zz_hotel_pointers after insert or update of branch_id, overrides_entry_id, organization_id on public.knowledge_entries
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'overrides_entry_id', 'knowledge_entries');
create or replace trigger zz_hotel_pointers after insert or update of archived_by, branch_id, master_id, organization_id on public.property_policies
  for each row execute function fn_hotel_pointers('archived_by', 'staff_profiles', 'branch_id', 'branches', 'master_id', 'policy_masters');

-- ---------------------------------------------------------------------------------------------- policies: row trigger
-- a direct edit of a linked row (the existing screen) keeps the link and records which fields the branch now owns;
-- a client cannot set or move the link itself (only the RPCs below, which set app.policy_sync, may)
create or replace function fn_trg_policy_inherit() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_changed text[] := '{}';
begin
  if current_setting('app.policy_sync', true) = '1' then return new; end if;
  if tg_op = 'INSERT' then
    new.master_id := null; new.master_version := null; new.override_fields := '{}';
    return new;
  end if;
  new.master_id := old.master_id; new.master_version := old.master_version;
  if old.master_id is null then new.override_fields := '{}'; return new; end if;
  if new.title is distinct from old.title then v_changed := v_changed || 'title'::text; end if;
  if new.content_ar is distinct from old.content_ar then v_changed := v_changed || 'content_ar'::text; end if;
  if new.content_en is distinct from old.content_en then v_changed := v_changed || 'content_en'::text; end if;
  if new.is_public is distinct from old.is_public then v_changed := v_changed || 'is_public'::text; end if;
  new.override_fields := (select coalesce(array_agg(distinct f order by f), '{}') from unnest(old.override_fields || v_changed) f);
  return new;
end $$;
revoke all on function fn_trg_policy_inherit() from public, anon, authenticated;
drop trigger if exists trg_policy_inherit on property_policies;
create trigger trg_policy_inherit before insert or update on property_policies
  for each row execute function fn_trg_policy_inherit();

-- ---------------------------------------------------------------------------------------------- policies: helpers
create or replace function fn_policy_masters_of(p_org uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'topic', m.topic, 'topic_label', m.topic_label, 'title', m.title,
    'content_ar', m.content_ar, 'content_en', m.content_en, 'is_public', m.is_public, 'sort_order', m.sort_order, 'version', m.version,
    'archived_at', m.archived_at) order by m.sort_order, m.title, m.id), '[]'::jsonb)
  from policy_masters m where m.organization_id = p_org;
$$;
revoke all on function fn_policy_masters_of(uuid) from public, anon, authenticated;

-- the plan of a hotel-level policy save: for every branch of the hotel, what would happen. Internal; the preview and the
-- apply both call it so what the owner sees is what is written.
create or replace function fn_policy_plan(p_org uuid, p_master jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  b record; r property_policies%rowtype; v_out jsonb := '[]'::jsonb; f text;
  v_fields constant text[] := array['title','content_ar','content_en','is_public'];
  v_upd text[]; v_keep text[]; v_over text[]; v_action text; v_topic text := p_master->>'topic';
  v_mid uuid := nullif(p_master->>'id','')::uuid; v_new jsonb;
begin
  for b in select id, name_ar from branches where organization_id = p_org and archived_at is null order by name_ar, id loop
    v_upd := '{}'; v_keep := '{}'; v_over := '{}'; r := null;
    if v_mid is not null then
      select * into r from property_policies where branch_id = b.id and master_id = v_mid order by created_at limit 1;
    end if;
    if r.id is not null then
      if r.archived_at is not null then v_action := 'skip_archived';
      else
        foreach f in array v_fields loop
          if (to_jsonb(r)->f) is distinct from (p_master->f) then
            if f = any(r.override_fields) then v_keep := v_keep || f; v_over := v_over || f; else v_upd := v_upd || f; end if;
          end if;
        end loop;
        v_action := case when cardinality(v_upd) > 0 then 'update' when cardinality(v_keep) > 0 then 'keep_override' else 'unchanged' end;
      end if;
    else
      -- not linked yet: an existing policy of the same topic is kept as it is (its differing fields become overrides);
      -- otherwise the branch gets a copy
      if v_topic <> 'other' then
        select * into r from property_policies where branch_id = b.id and master_id is null and topic = v_topic and archived_at is null order by created_at limit 1;
      end if;
      if r.id is not null then
        foreach f in array v_fields loop
          if (to_jsonb(r)->f) is distinct from (p_master->f) then v_keep := v_keep || f; v_over := v_over || f; end if;
        end loop;
        v_action := 'link_existing';
      else v_action := 'create'; v_upd := v_fields; end if;
    end if;
    v_new := jsonb_build_object('branch_id', b.id, 'branch_name', b.name_ar, 'policy_id', r.id, 'action', v_action,
               'update_fields', to_jsonb(v_upd), 'kept_fields', to_jsonb(v_keep), 'overwritable_fields', to_jsonb(v_over));
    v_out := v_out || v_new;
  end loop;
  return v_out;
end $$;
revoke all on function fn_policy_plan(uuid, jsonb) from public, anon, authenticated;

create or replace function fn_policy_master_input(p jsonb, p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id','')::uuid; old jsonb; v_topic text; v_title text; v_ar text; v_en text; v_label text;
begin
  if v_id is not null then
    select m into old from jsonb_array_elements(fn_policy_masters_of(p_org)) m where (m->>'id')::uuid = v_id;
    -- an id with no stored text and no version is the id the preview handed out for a new policy
    if old is null and (p->>'version') is not null then raise exception 'NOT_FOUND'; end if;
  end if;
  v_topic := coalesce(old->>'topic', p->>'topic');
  if v_topic is null or v_topic not in ('checkin','cancellation','wifi','parking','location','children','contact','stay','privacy','other') then
    raise exception 'VALIDATION: policy_topic'; end if;
  v_title := trim(coalesce(p->>'title','')); v_ar := trim(coalesce(p->>'content_ar',''));
  v_en := nullif(trim(coalesce(p->>'content_en','')),''); v_label := nullif(trim(coalesce(p->>'topic_label','')),'');
  if v_title = '' or v_ar = '' then raise exception 'VALIDATION: policy_required'; end if;
  if char_length(v_title) > 120 or char_length(v_ar) > 4000 then raise exception 'VALIDATION: policy_length'; end if;
  if v_topic <> 'other' then v_label := null; end if;
  if v_label is not null and char_length(v_label) > 60 then raise exception 'VALIDATION: topic_label'; end if;
  if v_topic <> 'other' and old is null and exists (select 1 from jsonb_array_elements(fn_policy_masters_of(p_org)) m
       where m->>'topic' = v_topic and m->>'archived_at' is null) then raise exception 'VALIDATION: policy_topic_exists'; end if;
  return jsonb_build_object('id', coalesce(v_id, extensions.gen_random_uuid()), 'topic', v_topic, 'topic_label', v_label, 'title', v_title,
    'content_ar', v_ar, 'content_en', v_en, 'is_public', coalesce((p->>'is_public')::boolean, (old->>'is_public')::boolean, true),
    'sort_order', coalesce((p->>'sort_order')::int, (old->>'sort_order')::int, 0),
    'version', coalesce((old->>'version')::int, 0) + 1, 'archived_at', null);
end $$;
revoke all on function fn_policy_master_input(jsonb, uuid) from public, anon, authenticated;

-- hotel-level policy writes: what the policies page already requires of a write (cap and page gate, owner or manager only
-- because the change is hotel-wide), and access to every branch because the change reaches all of them
create or replace function fn_policy_gate(p_org uuid, p_action text) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not fn_has_role('owner','manager') then raise exception 'FORBIDDEN: hotel-level policies are for the owner or manager' using errcode = '42501'; end if;
  if not fn_can_write('policies', p_action) or not (select fn_page_write_gate(array['/admin/policies'], p_action)) then
    raise exception 'FORBIDDEN: policies' using errcode = '42501'; end if;
  if exists (select 1 from branches where organization_id = p_org and archived_at is null and id not in (select fn_user_branch_ids())) then
    raise exception 'FORBIDDEN: hotel-level policies need access to every branch' using errcode = '42501';
  end if;
end $$;
revoke all on function fn_policy_gate(uuid, text) from public, anon, authenticated;


-- a preview token: <expiry epoch>.<hmac of actor, hotel, expiry and everything the apply will do>; an apply recomputes it, so a
-- changed input, plan, master version, actor or hotel, a replay after the change, or an expired token is refused
create or replace function fn_preview_token(p_kind text, p_org uuid, p_expiry bigint, p_body text) returns text
language sql stable security definer set search_path = public, extensions as $$
  select p_expiry::text || '.' || encode(hmac(p_kind || '|' || p_org::text || '|' || coalesce(fn_staff_id()::text,'') || '|' || p_expiry::text || '|' || p_body,
                                              coalesce(nullif(current_setting('app.identity_key', true), ''), 'preview-token'), 'sha256'), 'hex');
$$;
revoke all on function fn_preview_token(text, uuid, bigint, text) from public, anon, authenticated;
create or replace function fn_preview_token_ok(p_kind text, p_org uuid, p_token text, p_body text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v_exp bigint;
begin
  if p_token is null or p_token !~ '^[0-9]{1,12}\.[0-9a-f]{64}$' then return false; end if;
  v_exp := split_part(p_token, '.', 1)::bigint;
  if v_exp < extract(epoch from now())::bigint then raise exception 'PREVIEW_EXPIRED'; end if;
  return fn_preview_token(p_kind, p_org, v_exp, p_body) = p_token;
end $$;
revoke all on function fn_preview_token_ok(text, uuid, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------- policies: public RPCs
-- list: the hotel-level texts and, per text, how each branch stands (inherited / own fields)
create or replace function fn_policy_masters_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_org uuid := fn_user_org_id();
begin
  if not (select fn_page_read_gate(array['/admin/policies'])) then raise exception 'FORBIDDEN: policies' using errcode = '42501'; end if;
  return jsonb_build_object('masters', (
    select coalesce(jsonb_agg(m || jsonb_build_object('branches', (
      select coalesce(jsonb_agg(jsonb_build_object('branch_id', p.branch_id, 'policy_id', p.id, 'override_fields', to_jsonb(p.override_fields),
               'master_version', p.master_version, 'archived', p.archived_at is not null) order by p.branch_id), '[]'::jsonb)
      from property_policies p where p.master_id = (m->>'id')::uuid and p.branch_id in (select fn_user_branch_ids())))
      order by (m->>'sort_order')::int, m->>'title'), '[]'::jsonb)
    from jsonb_array_elements(fn_policy_masters_of(v_org)) m where m->>'archived_at' is null));
end $$;
revoke all on function fn_policy_masters_list() from public, anon;
grant execute on function fn_policy_masters_list() to authenticated;

-- preview: nothing is written. The token proves the apply is for exactly this preview.
create or replace function fn_policy_master_preview(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_org uuid := fn_user_org_id(); v_m jsonb; v_plan jsonb;
begin
  perform fn_policy_gate(v_org, case when nullif(p->>'version','') is null then 'add' else 'edit' end);
  v_m := fn_policy_master_input(p, v_org);
  v_plan := fn_policy_plan(v_org, v_m);
  return jsonb_build_object('master', v_m - 'version', 'is_new', (p->>'version') is null, 'branches', v_plan,
    'token', fn_preview_token('policy', v_org, extract(epoch from now())::bigint + 900,
             (v_m - 'version')::text || v_plan::text || coalesce((select m->>'version' from jsonb_array_elements(fn_policy_masters_of(v_org)) m where m->>'id' = v_m->>'id'), '0')));
end $$;
revoke all on function fn_policy_master_preview(jsonb) from public, anon;
grant execute on function fn_policy_master_preview(jsonb) to authenticated;

-- apply: p = the preview's input + token + expected version (when editing) + overwrite_branches (branch ids chosen explicitly)
create or replace function fn_policy_master_apply(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := fn_user_org_id(); v_m jsonb; v_plan jsonb; v_cur jsonb; v_mid uuid; v_ow uuid[] := '{}'; x jsonb; r property_policies%rowtype;
  v_fields text[]; f text; v_n_upd int := 0; v_n_new int := 0; v_n_ow int := 0; v_n_keep int := 0; v_ver int;
  v_before jsonb; v_branch uuid;
begin
  perform fn_policy_gate(v_org, case when nullif(p->>'version','') is null then 'add' else 'edit' end);
  -- one hotel-level policy save at a time per hotel (two owners saving together are not both applied to the same preview)
  perform pg_advisory_xact_lock(hashtextextended('policy_masters:' || v_org::text, 0));
  v_m := fn_policy_master_input(p, v_org);
  v_mid := (v_m->>'id')::uuid;
  v_plan := fn_policy_plan(v_org, v_m);
  if not fn_preview_token_ok('policy', v_org, p->>'token',
       (v_m - 'version')::text || v_plan::text || coalesce((select m->>'version' from jsonb_array_elements(fn_policy_masters_of(v_org)) m where m->>'id' = v_m->>'id'), '0'))
  then raise exception 'PREVIEW_STALE'; end if;
  select m into v_cur from jsonb_array_elements(fn_policy_masters_of(v_org)) m where (m->>'id')::uuid = v_mid;
  if v_cur is not null then
    if (p->>'version') is null then raise exception 'VERSION_REQUIRED'; end if;
    perform fn_check_version((v_cur->>'version')::int, (p->>'version')::int);
  end if;
  if p ? 'overwrite_branches' then
    select coalesce(array_agg(value::uuid), '{}') into v_ow from jsonb_array_elements_text(p->'overwrite_branches');
  end if;
  -- only a branch that actually keeps its own text can be overwritten, and only a branch listed in the preview
  if exists (select 1 from unnest(v_ow) o where not exists (select 1 from jsonb_array_elements(v_plan) e
       where (e->>'branch_id')::uuid = o and cardinality(array(select jsonb_array_elements_text(e->'overwritable_fields'))) > 0)) then
    raise exception 'VALIDATION: overwrite_not_overridden';
  end if;
  v_ver := (v_m->>'version')::int;
  perform set_config('app.policy_sync', '1', true);
  if v_cur is null then
    insert into policy_masters(id, organization_id, topic, topic_label, title, content_ar, content_en, is_public, sort_order, version, created_by, updated_by)
    values (v_mid, v_org, v_m->>'topic', v_m->>'topic_label', v_m->>'title', v_m->>'content_ar', v_m->>'content_en', (v_m->>'is_public')::boolean,
            (v_m->>'sort_order')::int, v_ver, fn_staff_id(), fn_staff_id());
  else
    update policy_masters set title = v_m->>'title', content_ar = v_m->>'content_ar', content_en = v_m->>'content_en', topic_label = v_m->>'topic_label',
           is_public = (v_m->>'is_public')::boolean, sort_order = (v_m->>'sort_order')::int, version = v_ver, updated_by = fn_staff_id(), updated_at = now()
    where id = v_mid and organization_id = v_org;
  end if;
  for x in select * from jsonb_array_elements(v_plan) loop
    v_branch := (x->>'branch_id')::uuid;
    v_fields := array(select jsonb_array_elements_text(x->'update_fields'));
    if x->>'action' = 'create' then
      insert into property_policies(organization_id, branch_id, topic, topic_label, title, content_ar, content_en, is_public, sort_order,
                                    master_id, master_version, override_fields, updated_by)
      values (v_org, v_branch, v_m->>'topic', v_m->>'topic_label', v_m->>'title', v_m->>'content_ar', v_m->>'content_en',
              (v_m->>'is_public')::boolean, (v_m->>'sort_order')::int, v_mid, v_ver, '{}', fn_staff_id())
      returning * into r;
      perform fn_audit(v_org, v_branch, fn_staff_id(), 'policy.inherited_created', 'property_policy', r.id,
        jsonb_build_object('master_id', v_mid, 'after', jsonb_build_object('title', r.title, 'content_ar', r.content_ar, 'is_public', r.is_public)));
      v_n_new := v_n_new + 1;
    elsif x->>'action' = 'link_existing' then
      update property_policies set master_id = v_mid, master_version = v_ver,
             override_fields = array(select jsonb_array_elements_text(x->'kept_fields'))
      where id = (x->>'policy_id')::uuid;
      perform fn_audit(v_org, v_branch, fn_staff_id(), 'policy.linked_to_master', 'property_policy', (x->>'policy_id')::uuid,
        jsonb_build_object('master_id', v_mid, 'kept_own_fields', x->'kept_fields'));
      v_n_keep := v_n_keep + case when cardinality(array(select jsonb_array_elements_text(x->'kept_fields'))) > 0 then 1 else 0 end;
    elsif x->>'action' in ('update','keep_override','unchanged') then
      select * into r from property_policies where id = (x->>'policy_id')::uuid for update;
      v_before := jsonb_build_object('title', r.title, 'content_ar', r.content_ar, 'content_en', r.content_en, 'is_public', r.is_public, 'override_fields', r.override_fields);
      if v_branch = any(v_ow) then v_fields := v_fields || array(select jsonb_array_elements_text(x->'overwritable_fields')); end if;
      if cardinality(v_fields) > 0 then
        update property_policies set
          title = case when 'title' = any(v_fields) then v_m->>'title' else title end,
          content_ar = case when 'content_ar' = any(v_fields) then v_m->>'content_ar' else content_ar end,
          content_en = case when 'content_en' = any(v_fields) then v_m->>'content_en' else content_en end,
          is_public = case when 'is_public' = any(v_fields) then (v_m->>'is_public')::boolean else is_public end,
          override_fields = array(select f2 from unnest(override_fields) f2 where f2 <> all(v_fields)),
          master_version = v_ver, updated_by = fn_staff_id(), updated_at = now()
        where id = r.id returning * into r;
        perform fn_audit(v_org, v_branch, fn_staff_id(), case when v_branch = any(v_ow) and x->>'action' <> 'update' or (v_branch = any(v_ow) and cardinality(array(select jsonb_array_elements_text(x->'overwritable_fields'))) > 0)
                                                              then 'policy.master_overwrote_branch' else 'policy.master_broadcast' end,
          'property_policy', r.id, jsonb_build_object('master_id', v_mid, 'fields', to_jsonb(v_fields), 'before', v_before,
            'after', jsonb_build_object('title', r.title, 'content_ar', r.content_ar, 'content_en', r.content_en, 'is_public', r.is_public), 'reason', p->>'reason'));
        if v_branch = any(v_ow) then v_n_ow := v_n_ow + 1; else v_n_upd := v_n_upd + 1; end if;
      else
        -- nothing to change: the row is not touched at all (a branch's own text stays byte for byte as it was)
        if cardinality(array(select jsonb_array_elements_text(x->'kept_fields'))) > 0 then v_n_keep := v_n_keep + 1; end if;
      end if;
    end if;
  end loop;
  perform fn_audit(v_org, null, fn_staff_id(), case when v_cur is null then 'policy.master_created' else 'policy.master_updated' end, 'organization', v_org,
    jsonb_build_object('master_id', v_mid, 'before', v_cur, 'after', v_m, 'reason', p->>'reason',
                       'branches_created', v_n_new, 'branches_updated', v_n_upd, 'branches_overwritten', v_n_ow, 'branches_kept_own', v_n_keep));
  perform set_config('app.policy_sync', '', true);
  return jsonb_build_object('ok', true, 'id', v_mid, 'version', v_ver, 'created', v_n_new, 'updated', v_n_upd, 'overwritten', v_n_ow, 'kept_own', v_n_keep);
end $$;
revoke all on function fn_policy_master_apply(jsonb) from public, anon;
grant execute on function fn_policy_master_apply(jsonb) to authenticated;

-- revert: a branch gives up its own text(s) and follows the hotel-level text again (p_fields null = all of them)
create or replace function fn_policy_branch_revert(p_policy_id uuid, p_fields text[] default null, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r property_policies%rowtype; v_org uuid := fn_user_org_id(); m jsonb; v_f text[]; v_before jsonb;
begin
  select * into r from property_policies where id = p_policy_id and organization_id = v_org for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  -- the same authority a direct edit of that branch's policy needs
  if r.branch_id not in (select fn_user_branch_ids()) or not fn_can_write('policies', 'edit') or not (select fn_page_write_gate(array['/admin/policies'], 'edit')) then
    raise exception 'FORBIDDEN: policies' using errcode = '42501'; end if;
  if r.master_id is null then raise exception 'VALIDATION: not_inherited'; end if;
  select x into m from jsonb_array_elements(fn_policy_masters_of(v_org)) x where (x->>'id')::uuid = r.master_id and x->>'archived_at' is null;
  if m is null then raise exception 'NOT_FOUND'; end if;
  v_f := coalesce(p_fields, r.override_fields);
  v_f := array(select f from unnest(v_f) f where f = any(r.override_fields));
  if cardinality(v_f) = 0 then return jsonb_build_object('ok', true, 'reverted', '[]'::jsonb); end if;
  v_before := jsonb_build_object('title', r.title, 'content_ar', r.content_ar, 'content_en', r.content_en, 'is_public', r.is_public, 'override_fields', r.override_fields);
  perform set_config('app.policy_sync', '1', true);
  update property_policies set
    title = case when 'title' = any(v_f) then m->>'title' else title end,
    content_ar = case when 'content_ar' = any(v_f) then m->>'content_ar' else content_ar end,
    content_en = case when 'content_en' = any(v_f) then m->>'content_en' else content_en end,
    is_public = case when 'is_public' = any(v_f) then (m->>'is_public')::boolean else is_public end,
    override_fields = array(select f2 from unnest(override_fields) f2 where f2 <> all(v_f)),
    master_version = (m->>'version')::int, updated_by = fn_staff_id(), updated_at = now()
  where id = r.id returning * into r;
  perform fn_audit(v_org, r.branch_id, fn_staff_id(), 'policy.branch_reverted', 'property_policy', r.id,
    jsonb_build_object('master_id', r.master_id, 'fields', to_jsonb(v_f), 'before', v_before, 'reason', p_reason));
  perform set_config('app.policy_sync', '', true);
  return jsonb_build_object('ok', true, 'reverted', to_jsonb(v_f));
end $$;
revoke all on function fn_policy_branch_revert(uuid, text[], text) from public, anon;
grant execute on function fn_policy_branch_revert(uuid, text[], text) to authenticated;

-- ---------------------------------------------------------------------------------------------- knowledge
-- a branch's own version of a shared entry hides the shared entry for that branch
create or replace function fn_public_knowledge(p_branch uuid)
returns table (id uuid, category text, question text, keywords text[], answer text, priority int)
language sql stable security definer set search_path = public as $$
  select k.id, k.category, k.question, k.keywords, k.answer, k.priority
  from knowledge_entries k
  join branches b on b.id = p_branch and b.organization_id = k.organization_id
  where k.is_public and k.is_active and k.archived_at is null
    and (k.branch_id is null or k.branch_id = p_branch)
    and not (k.branch_id is null and exists (select 1 from knowledge_entries o where o.overrides_entry_id = k.id and o.branch_id = p_branch and o.archived_at is null))
  order by k.priority desc, k.used_count desc, k.created_at;
$$;
create or replace function fn_staff_knowledge(p_branch uuid)
returns table (id uuid, category text, question text, keywords text[], answer text, priority int, is_public boolean)
language sql stable security definer set search_path = public as $$
  select k.id, k.category, k.question, k.keywords, k.answer, k.priority, k.is_public
  from knowledge_entries k
  where k.organization_id = fn_user_org_id() and p_branch in (select fn_user_branch_ids())
    and k.is_active and k.archived_at is null and (k.branch_id is null or k.branch_id = p_branch)
    and not (k.branch_id is null and exists (select 1 from knowledge_entries o where o.overrides_entry_id = k.id and o.branch_id = p_branch and o.archived_at is null))
  order by k.priority desc, k.used_count desc, k.created_at;
$$;

-- the upsert (0055) refuses a second active answer to the same question; a branch's override of a shared entry is that
-- second answer by design, so it is not a conflict with the entry it overrides (nor that entry with its override)
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
  if v_active then
    select x.id into v_other from knowledge_entries x
    where x.organization_id = v_org and x.archived_at is null and x.is_active and x.id is distinct from k.id
      and (x.branch_id is null or v_branch is null or x.branch_id = v_branch)
      and not (k.overrides_entry_id is not null and x.id = k.overrides_entry_id)
      and not (x.overrides_entry_id is not null and x.overrides_entry_id = k.id)
      and fn_knowledge_question_key(x.question) = fn_knowledge_question_key(v_q)
    limit 1;
    if v_other is not null then raise exception 'KNOWLEDGE_CONFLICT: %', v_other; end if;
  end if;
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
  if (p->>'unanswered_id') is not null then
    update unanswered_questions set status = 'answered', knowledge_entry_id = k.id, resolved_by = fn_staff_id(), resolved_at = now()
    where id = (p->>'unanswered_id')::uuid and organization_id = v_org;
  end if;
  return jsonb_build_object('ok', true, 'id', k.id, 'version', k.version);
end $function$;

-- exactly what fn_admin_upsert_knowledge already asks for an entry that belongs to every branch: the knowledge capability and
-- owner or manager (no branch list: that function never asked for one for a hotel-level entry)
create or replace function fn_knowledge_gate(p_org uuid) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  perform fn_require_cap('knowledge');
  if not fn_has_role('owner','manager') then raise exception 'FORBIDDEN: org-wide entries require manager' using errcode = '42501'; end if;
end $$;
revoke all on function fn_knowledge_gate(uuid) from public, anon, authenticated;

create or replace function fn_knowledge_plan(p_org uuid, p_entry uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare k knowledge_entries%rowtype; b record; o knowledge_entries%rowtype; v_out jsonb := '[]'::jsonb; v_changed text[] := '{}'; v_kw text[];
begin
  select * into k from knowledge_entries where id = p_entry and organization_id = p_org and branch_id is null and archived_at is null;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p ? 'question' and trim(p->>'question') is distinct from k.question then v_changed := v_changed || 'question'::text; end if;
  if p ? 'answer' and trim(p->>'answer') is distinct from k.answer then v_changed := v_changed || 'answer'::text; end if;
  if p ? 'answer_en' and nullif(trim(coalesce(p->>'answer_en','')),'') is distinct from k.answer_en then v_changed := v_changed || 'answer_en'::text; end if;
  if p ? 'category' and p->>'category' is distinct from k.category then v_changed := v_changed || 'category'::text; end if;
  if p ? 'is_public' and (p->>'is_public')::boolean is distinct from k.is_public then v_changed := v_changed || 'is_public'::text; end if;
  if p ? 'is_active' and (p->>'is_active')::boolean is distinct from k.is_active then v_changed := v_changed || 'is_active'::text; end if;
  if p ? 'priority' and (p->>'priority')::int is distinct from k.priority then v_changed := v_changed || 'priority'::text; end if;
  if p ? 'keywords' then
    select coalesce(array_agg(distinct w order by w), '{}') into v_kw from (select fn_normalize_ar(x) w from jsonb_array_elements_text(p->'keywords') x) s where char_length(w) >= 2;
    if v_kw is distinct from k.keywords then v_changed := v_changed || 'keywords'::text; end if;
  end if;
  for b in select id, name_ar from branches where organization_id = p_org and archived_at is null order by name_ar, id loop
    select * into o from knowledge_entries where overrides_entry_id = k.id and branch_id = b.id and archived_at is null limit 1;
    v_out := v_out || jsonb_build_object('branch_id', b.id, 'branch_name', b.name_ar, 'override_id', o.id,
      'action', case when cardinality(v_changed) = 0 then 'unchanged' when o.id is not null then 'keep_override' else 'inherits' end,
      'changed_fields', case when o.id is null then to_jsonb(v_changed) else '[]'::jsonb end,
      'overwritable_fields', case when o.id is not null then to_jsonb(v_changed) else '[]'::jsonb end);
  end loop;
  return jsonb_build_object('entry_id', k.id, 'version', k.version, 'changed_fields', to_jsonb(v_changed), 'branches', v_out);
end $$;
revoke all on function fn_knowledge_plan(uuid, uuid, jsonb) from public, anon, authenticated;

create or replace function fn_knowledge_main_preview(p_entry uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_org uuid := fn_user_org_id(); v_plan jsonb;
begin
  perform fn_knowledge_gate(v_org);
  v_plan := fn_knowledge_plan(v_org, p_entry, p);
  return v_plan || jsonb_build_object('token', fn_preview_token('knowledge', v_org, extract(epoch from now())::bigint + 900, p_entry::text || v_plan::text || coalesce(p::text, '')));
end $$;
revoke all on function fn_knowledge_main_preview(uuid, jsonb) from public, anon;
grant execute on function fn_knowledge_main_preview(uuid, jsonb) to authenticated;

-- apply a hotel-level edit: branches with their own version keep it; overwrite_branches (explicit) lose theirs.
-- Overwriting = archiving that branch's override with a reason (its text stays in the archive and in the audit trail)
create or replace function fn_knowledge_main_apply(p_entry uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_org uuid := fn_user_org_id(); v_plan jsonb; v_ow uuid[] := '{}'; x jsonb; o knowledge_entries%rowtype; k knowledge_entries%rowtype; v_res jsonb; v_n int := 0;
begin
  perform fn_knowledge_gate(v_org);
  perform pg_advisory_xact_lock(hashtextextended('knowledge_entry:' || p_entry::text, 0));
  v_plan := fn_knowledge_plan(v_org, p_entry, p);
  if not fn_preview_token_ok('knowledge', v_org, p->>'token', p_entry::text || v_plan::text || coalesce((p - 'token' - 'overwrite_branches')::text, '')) then raise exception 'PREVIEW_STALE'; end if;
  if p ? 'overwrite_branches' then select coalesce(array_agg(value::uuid), '{}') into v_ow from jsonb_array_elements_text(p->'overwrite_branches'); end if;
  if exists (select 1 from unnest(v_ow) w where not exists (select 1 from jsonb_array_elements(v_plan->'branches') e
       where (e->>'branch_id')::uuid = w and e->>'action' = 'keep_override')) then raise exception 'VALIDATION: overwrite_not_overridden'; end if;
  select * into k from knowledge_entries where id = p_entry;
  -- a partial edit keeps every field it does not mention
  v_res := fn_admin_upsert_knowledge(jsonb_build_object('question', k.question, 'answer', k.answer, 'answer_en', k.answer_en, 'keywords', to_jsonb(k.keywords),
      'category', k.category, 'is_public', k.is_public, 'is_active', k.is_active, 'priority', k.priority)
    || (p - 'token' - 'overwrite_branches') || jsonb_build_object('id', p_entry, 'branch_id', null));
  for x in select * from jsonb_array_elements(v_plan->'branches') loop
    if (x->>'branch_id')::uuid = any(v_ow) then
      perform fn_require_branch((x->>'branch_id')::uuid);   -- overwriting a branch's own text needs that branch
      select * into o from knowledge_entries where id = (x->>'override_id')::uuid for update;
      update knowledge_entries set archived_at = now(), archived_by = fn_staff_id(), archive_reason = 'overwritten by hotel-level update', updated_at = now(), version = version + 1
      where id = o.id;
      perform fn_audit(v_org, o.branch_id, fn_staff_id(), 'knowledge.master_overwrote_branch', 'knowledge_entry', o.id,
        jsonb_build_object('master_id', p_entry, 'before', jsonb_build_object('question', o.question, 'answer', o.answer, 'keywords', o.keywords, 'is_public', o.is_public, 'is_active', o.is_active), 'fields', x->'overwritable_fields', 'reason', p->>'reason'));
      v_n := v_n + 1;
    end if;
  end loop;
  perform fn_audit(v_org, null, fn_staff_id(), 'knowledge.master_broadcast', 'knowledge_entry', p_entry,
    jsonb_build_object('fields', v_plan->'changed_fields', 'branches', v_plan->'branches', 'overwritten', v_n, 'reason', p->>'reason'));
  return v_res || jsonb_build_object('overwritten', v_n);
end $$;
revoke all on function fn_knowledge_main_apply(uuid, jsonb) from public, anon;
grant execute on function fn_knowledge_main_apply(uuid, jsonb) to authenticated;

-- a branch makes its own version of a shared entry (a copy it may then edit through the normal upsert)
create or replace function fn_knowledge_branch_override(p_entry uuid, p_branch uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_org uuid := fn_user_org_id(); k knowledge_entries%rowtype; o knowledge_entries%rowtype; v_kw text[];
begin
  perform fn_require_cap('knowledge');
  perform fn_require_branch(p_branch);
  select * into k from knowledge_entries where id = p_entry and organization_id = v_org and branch_id is null and archived_at is null;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not exists (select 1 from branches where id = p_branch and organization_id = v_org and archived_at is null) then raise exception 'NOT_FOUND'; end if;
  select * into o from knowledge_entries where overrides_entry_id = k.id and branch_id = p_branch and archived_at is null;
  if found then return jsonb_build_object('ok', true, 'id', o.id, 'version', o.version, 'existing', true); end if;
  select coalesce(array_agg(distinct w order by w), '{}') into v_kw
  from (select fn_normalize_ar(x) w from jsonb_array_elements_text(coalesce(p->'keywords', to_jsonb(k.keywords))) x) s where char_length(w) >= 2;
  insert into knowledge_entries(organization_id, branch_id, category, question, keywords, answer, answer_en, is_public, is_active, priority, overrides_entry_id, created_by, updated_by)
  values (v_org, p_branch, k.category, coalesce(nullif(trim(p->>'question'),''), k.question), v_kw, coalesce(nullif(trim(p->>'answer'),''), k.answer),
          case when p ? 'answer_en' then nullif(trim(coalesce(p->>'answer_en','')),'') else k.answer_en end,
          coalesce((p->>'is_public')::boolean, k.is_public), k.is_active, k.priority, k.id, fn_staff_id(), fn_staff_id())
  returning * into o;
  perform fn_audit(v_org, p_branch, fn_staff_id(), 'knowledge.branch_override_created', 'knowledge_entry', o.id,
    jsonb_build_object('overrides', k.id, 'after', jsonb_build_object('question', o.question, 'answer', o.answer)));
  return jsonb_build_object('ok', true, 'id', o.id, 'version', o.version, 'existing', false);
end $$;
revoke all on function fn_knowledge_branch_override(uuid, uuid, jsonb) from public, anon;
grant execute on function fn_knowledge_branch_override(uuid, uuid, jsonb) to authenticated;

-- revert: the branch follows the shared entry again (its own version is archived, not erased)
create or replace function fn_knowledge_revert_override(p_override uuid, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_org uuid := fn_user_org_id(); o knowledge_entries%rowtype;
begin
  perform fn_require_cap('knowledge');
  select * into o from knowledge_entries where id = p_override and organization_id = v_org and overrides_entry_id is not null and archived_at is null for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(o.branch_id);
  update knowledge_entries set archived_at = now(), archived_by = fn_staff_id(), archive_reason = coalesce(nullif(trim(p_reason),''), 'reverted to the hotel-level entry'), updated_at = now(), version = version + 1 where id = o.id;
  perform fn_audit(v_org, o.branch_id, fn_staff_id(), 'knowledge.branch_override_reverted', 'knowledge_entry', o.id,
    jsonb_build_object('overrides', o.overrides_entry_id, 'before', jsonb_build_object('question', o.question, 'answer', o.answer, 'keywords', o.keywords), 'reason', p_reason));
  return jsonb_build_object('ok', true);
end $$;
revoke all on function fn_knowledge_revert_override(uuid, text) from public, anon;
grant execute on function fn_knowledge_revert_override(uuid, text) to authenticated;

-- what a branch's screen shows: its effective entries, each with where it comes from
create or replace function fn_knowledge_effective(p_branch uuid) returns table (
  id uuid, branch_id uuid, origin text, overrides_entry_id uuid, category text, question text, keywords text[], answer text, answer_en text,
  is_public boolean, is_active boolean, priority int, version int)
language plpgsql stable security definer set search_path = public as $$
begin
  perform fn_require_cap('knowledge');
  perform fn_require_branch(p_branch);
  return query
  select k.id, k.branch_id, case when k.branch_id is null then 'hotel' when k.overrides_entry_id is not null then 'branch_override' else 'branch_only' end,
         k.overrides_entry_id, k.category, k.question, k.keywords, k.answer, k.answer_en, k.is_public, k.is_active, k.priority, k.version
  from knowledge_entries k
  where k.organization_id = fn_user_org_id() and k.archived_at is null and (k.branch_id is null or k.branch_id = p_branch)
    and not (k.branch_id is null and exists (select 1 from knowledge_entries o where o.overrides_entry_id = k.id and o.branch_id = p_branch and o.archived_at is null))
  order by k.priority desc, k.used_count desc, k.created_at;
end $$;
revoke all on function fn_knowledge_effective(uuid) from public, anon;
grant execute on function fn_knowledge_effective(uuid) to authenticated;
