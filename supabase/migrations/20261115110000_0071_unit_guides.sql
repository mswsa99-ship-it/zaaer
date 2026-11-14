-- 0071 — W7 of the guest journey (plan «خطة تصحيح ملاحظات التجربة», stage م٤, «الشرح المصوّر والمساعد»): the photos
-- that show a guest how to enter their unit and how to leave it, one set per unit, uploaded by the owner from the
-- branch's guide (the photos of the branch, 0056) and shown to a guest only once the owner or the manager approved
-- them: a unit with no approved photos is explained by the reception, never by a page or a message.

-- ---------------------------------------------------------------------------------------------------------------
-- 1. A photo's purpose (the branch's gallery, the unit's way in, the unit's way out) and its approval
-- ---------------------------------------------------------------------------------------------------------------
alter table branch_media_items add column if not exists purpose text not null default 'gallery';
alter table branch_media_items add column if not exists approved_at timestamptz;
alter table branch_media_items add column if not exists approved_by uuid references staff_profiles(id);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'branch_media_purpose_valid') then
    alter table branch_media_items add constraint branch_media_purpose_valid check (purpose in ('gallery', 'checkin', 'checkout'));
  end if;
  -- a unit's way in or out is a photo of that unit
  if not exists (select 1 from pg_constraint where conname = 'branch_media_guide_is_unit_photo') then
    alter table branch_media_items add constraint branch_media_guide_is_unit_photo check (purpose = 'gallery' or (kind = 'photo' and room_id is not null));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'branch_media_approval_is_guide') then
    alter table branch_media_items add constraint branch_media_approval_is_guide check (approved_at is null or purpose <> 'gallery');
  end if;
end $$;
create index if not exists idx_media_unit_guide on branch_media_items(room_id, purpose) where purpose <> 'gallery' and archived_at is null;

create or replace function fn_admin_upsert_media_item(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare m branch_media_items%rowtype; v_branch uuid; v_kind text; raw text; bin bytea; v_mime text; v_url text; v_caption text; before jsonb;
        v_purpose text; v_room uuid;
begin
  perform fn_require_cap('branch.settings');
  if (p->>'id') is not null then
    select * into m from branch_media_items where id = (p->>'id')::uuid for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    v_branch := m.branch_id; v_kind := m.kind;
  else
    v_branch := (p->>'branch_id')::uuid; v_kind := p->>'kind';
    if v_kind not in ('photo', 'video') then raise exception 'VALIDATION: kind'; end if;
  end if;
  perform fn_require_branch(v_branch);
  v_caption := case when p ? 'caption' then nullif(trim(coalesce(p->>'caption', '')), '') else m.caption end;
  if v_caption is not null and char_length(v_caption) > 160 then raise exception 'VALIDATION: caption'; end if;
  if p ? 'block_id' and nullif(p->>'block_id', '') is not null and not exists (select 1 from blocks where id = (p->>'block_id')::uuid and branch_id = v_branch) then raise exception 'BRANCH_MISMATCH: block'; end if;
  if p ? 'room_id' and nullif(p->>'room_id', '') is not null and not exists (select 1 from rooms where id = (p->>'room_id')::uuid and branch_id = v_branch) then raise exception 'BRANCH_MISMATCH: room'; end if;
  if (p ? 'sort_order') and coalesce(p->>'sort_order', '') !~ '^[0-9]{1,4}$' then raise exception 'VALIDATION: sort_order'; end if;
  -- W7: the way in or out of a unit is a photo of that unit
  v_purpose := case when p ? 'purpose' then coalesce(nullif(p->>'purpose', ''), 'gallery') else coalesce(m.purpose, 'gallery') end;
  if v_purpose not in ('gallery', 'checkin', 'checkout') then raise exception 'VALIDATION: purpose'; end if;
  v_room := case when p ? 'room_id' then nullif(p->>'room_id', '')::uuid else m.room_id end;
  if v_purpose <> 'gallery' and (v_kind <> 'photo' or v_room is null) then raise exception 'VALIDATION: guide_photo'; end if;
  if m.id is null then
    if v_kind = 'photo' then
      raw := regexp_replace(coalesce(p->>'data_base64', ''), '^data:[^,]*,', '');
      begin bin := decode(regexp_replace(raw, '\s', '', 'g'), 'base64'); exception when others then raise exception 'VALIDATION: image'; end;
      if bin is null or length(bin) = 0 then raise exception 'VALIDATION: image'; end if;
      if length(bin) > 1048576 then raise exception 'VALIDATION: image_too_large'; end if;
      v_mime := case when substring(bin from 1 for 8) = '\x89504e470d0a1a0a'::bytea then 'image/png'
                     when substring(bin from 1 for 3) = '\xffd8ff'::bytea then 'image/jpeg'
                     when substring(bin from 1 for 4) = '\x52494646'::bytea and substring(bin from 9 for 4) = '\x57454250'::bytea then 'image/webp' end;
      if v_mime is null then raise exception 'VALIDATION: image_type'; end if;
    else
      v_url := trim(coalesce(p->>'url', ''));
      if not fn_valid_https_url(v_url) or char_length(v_url) > 500 then raise exception 'VALIDATION: video_url'; end if;
    end if;
    insert into branch_media_items(organization_id, branch_id, kind, block_id, room_id, caption, url, mime, bytes, size_bytes, sha256, sort_order, created_by, purpose)
    values (fn_user_org_id(), v_branch, v_kind, nullif(p->>'block_id', '')::uuid, v_room, v_caption, v_url, v_mime, bin,
            coalesce(length(bin), 0), case when bin is not null then encode(digest(bin, 'sha256'), 'hex') end,
            coalesce((p->>'sort_order')::int, (select coalesce(max(sort_order), 0) + 1 from branch_media_items where branch_id = v_branch and kind = v_kind)), fn_staff_id(), v_purpose)
    returning * into m;
    perform fn_audit_change(v_branch, 'branch.media_added', 'branch_media_item', m.id, null,
      jsonb_build_object('kind', m.kind, 'caption', m.caption, 'url', m.url, 'size_bytes', m.size_bytes, 'block_id', m.block_id, 'room_id', m.room_id, 'purpose', m.purpose), null);
  else
    before := jsonb_build_object('caption', m.caption, 'sort_order', m.sort_order, 'url', m.url, 'block_id', m.block_id, 'room_id', m.room_id, 'purpose', m.purpose,
                                 'approved', m.approved_at is not null);
    if v_kind = 'video' and p ? 'url' then
      v_url := trim(coalesce(p->>'url', ''));
      if not fn_valid_https_url(v_url) or char_length(v_url) > 500 then raise exception 'VALIDATION: video_url'; end if;
    end if;
    update branch_media_items set caption = v_caption, url = case when v_kind = 'video' and p ? 'url' then v_url else url end,
      sort_order = coalesce((p->>'sort_order')::int, sort_order),
      block_id = case when p ? 'block_id' then nullif(p->>'block_id', '')::uuid else block_id end,
      room_id = v_room, purpose = v_purpose,
      -- what a guest is shown changed: it waits for its approval again
      approved_at = case when v_purpose = 'gallery' or v_caption is distinct from m.caption or v_room is distinct from m.room_id or v_purpose is distinct from m.purpose then null else approved_at end,
      approved_by = case when v_purpose = 'gallery' or v_caption is distinct from m.caption or v_room is distinct from m.room_id or v_purpose is distinct from m.purpose then null else approved_by end,
      updated_at = now()
    where id = m.id returning * into m;
    perform fn_audit_change(v_branch, 'branch.media_changed', 'branch_media_item', m.id, before,
      jsonb_build_object('caption', m.caption, 'sort_order', m.sort_order, 'url', m.url, 'block_id', m.block_id, 'room_id', m.room_id, 'purpose', m.purpose,
                         'approved', m.approved_at is not null), null);
  end if;
  return jsonb_build_object('ok', true, 'id', m.id);
end $$;
revoke all on function fn_admin_upsert_media_item(jsonb) from public, anon;
grant execute on function fn_admin_upsert_media_item(jsonb) to authenticated;

-- the owner or the manager approves a unit's photo (or takes the approval back): only then a guest sees it
create or replace function fn_admin_approve_media_item(p_id uuid, p_approve boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m branch_media_items%rowtype;
begin
  perform fn_require_cap('branch.settings');
  if not fn_has_role('owner', 'manager') then raise exception 'FORBIDDEN: approval is the owner''s or the manager''s' using errcode = '42501'; end if;
  select * into m from branch_media_items where id = p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(m.branch_id);
  if m.purpose = 'gallery' then raise exception 'VALIDATION: guide_photo'; end if;
  if p_approve is null then raise exception 'VALIDATION: approve'; end if;
  if p_approve and m.archived_at is not null then raise exception 'VALIDATION: archived'; end if;
  if (m.approved_at is not null) = p_approve then return jsonb_build_object('ok', true, 'unchanged', true); end if;
  update branch_media_items set approved_at = case when p_approve then now() end, approved_by = case when p_approve then fn_staff_id() end where id = m.id;
  perform fn_audit_change(m.branch_id, case when p_approve then 'branch.media_approved' else 'branch.media_unapproved' end, 'branch_media_item', m.id,
    null, jsonb_build_object('purpose', m.purpose, 'room_id', m.room_id, 'caption', m.caption));
  return jsonb_build_object('ok', true, 'unchanged', false);
end $$;
revoke all on function fn_admin_approve_media_item(uuid, boolean) from public, anon;
grant execute on function fn_admin_approve_media_item(uuid, boolean) to authenticated;

create or replace function fn_admin_media_items(p_branch uuid, p_archived boolean default false) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform fn_require_cap('branch.settings');
  perform fn_require_branch(p_branch);
  return coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'kind', m.kind, 'caption', m.caption, 'url', m.url, 'size_bytes', m.size_bytes,
           'sort_order', m.sort_order, 'block_id', m.block_id, 'room_id', m.room_id, 'archived_at', m.archived_at, 'archive_reason', m.archive_reason,
           'purpose', m.purpose, 'approved_at', m.approved_at, 'approved_by_name', (select full_name from staff_profiles where id = m.approved_by),
           'version', left(coalesce(m.sha256, md5(coalesce(m.url, ''))), 12)) order by m.kind, m.purpose, m.sort_order, m.created_at)
    from branch_media_items m where m.branch_id = p_branch and (p_archived or m.archived_at is null)), '[]'::jsonb);
end $$;
revoke all on function fn_admin_media_items(uuid, boolean) from public, anon;
grant execute on function fn_admin_media_items(uuid, boolean) to authenticated;

-- a photo by its id: the branch's gallery to anyone, a unit's way in or out only once approved (the branch's staff
-- see their own photos whatever their state)
create or replace function fn_branch_photo(p_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select 'data:' || m.mime || ';base64,' || replace(encode(m.bytes, 'base64'), E'\n', '')
  from branch_media_items m join branches b on b.id = m.branch_id
  where m.id = p_id and m.kind = 'photo' and m.bytes is not null
    and ((m.archived_at is null and b.is_active and (m.purpose = 'gallery' or m.approved_at is not null)) or m.branch_id in (select fn_user_branch_ids()));
$$;
revoke all on function fn_branch_photo(uuid) from public;
grant execute on function fn_branch_photo(uuid) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------------------------
-- 2. The guest's explanation of their unit: only approved photos; none → the reception explains
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_unit_guide(p_room uuid, p_purpose text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'caption', m.caption, 'version', left(m.sha256, 12)) order by m.sort_order, m.created_at), '[]'::jsonb)
  from branch_media_items m
  where m.room_id = p_room and m.purpose = p_purpose and m.kind = 'photo' and m.archived_at is null and m.approved_at is not null
$$;
revoke all on function fn_unit_guide(uuid, text) from public, anon, authenticated;

create or replace function fn_guest_unit_guide(p_token text, p_purpose text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r reservations%rowtype; photos jsonb;
begin
  select * into r from reservations where id = fn_token_reservation(p_token);
  if p_purpose is null or p_purpose not in ('checkin', 'checkout') then raise exception 'VALIDATION: purpose'; end if;
  -- the unit's photos are the stay's own: shown once a unit is assigned, and never after the stay ended
  if r.room_id is null or r.status not in ('confirmed', 'checked_in') then
    return jsonb_build_object('ready', false, 'purpose', p_purpose);
  end if;
  photos := fn_unit_guide(r.room_id, p_purpose);
  return jsonb_build_object('ready', jsonb_array_length(photos) > 0, 'purpose', p_purpose, 'room_number', (select room_number from rooms where id = r.room_id),
                            'photos', case when jsonb_array_length(photos) > 0 then photos else '[]'::jsonb end);
end $$;
revoke all on function fn_guest_unit_guide(text, text) from public;
grant execute on function fn_guest_unit_guide(text, text) to anon, authenticated, service_role;

-- the check-out options say whether the unit's way out is ready to be shown (W3's page and messages)
do $$
declare fn oid; def text; n int;
        old_e constant text := $a$    'instructions', s.checkout_instructions, 'departed_at', r.guest_departed_at,$a$;
        new_e constant text := $b$    'instructions', s.checkout_instructions, 'departed_at', r.guest_departed_at,
    'guide_checkout', r.room_id is not null and jsonb_array_length(fn_unit_guide(r.room_id, 'checkout')) > 0,$b$;
begin
  select p.oid into fn from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'fn_checkout_offer';
  def := pg_get_functiondef(fn);
  if position('guide_checkout' in def) > 0 then return; end if;
  n := (length(def) - length(replace(def, old_e, ''))) / length(old_e);
  if n <> 1 then raise exception '0071: the instructions line of fn_checkout_offer was found % times, not once', n; end if;
  execute replace(def, old_e, new_e);
end $$;

-- the units of a branch and whether each has its approved way in and way out (the settings and the reception)
create or replace function fn_admin_unit_guides(p_branch uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform fn_require_cap('branch.settings');
  perform fn_require_branch(p_branch);
  return coalesce((select jsonb_agg(jsonb_build_object('room_id', rm.id, 'room_number', rm.room_number,
            'checkin', (select count(*) from branch_media_items m where m.room_id = rm.id and m.purpose = 'checkin' and m.archived_at is null),
            'checkin_approved', (select count(*) from branch_media_items m where m.room_id = rm.id and m.purpose = 'checkin' and m.archived_at is null and m.approved_at is not null),
            'checkout', (select count(*) from branch_media_items m where m.room_id = rm.id and m.purpose = 'checkout' and m.archived_at is null),
            'checkout_approved', (select count(*) from branch_media_items m where m.room_id = rm.id and m.purpose = 'checkout' and m.archived_at is null and m.approved_at is not null))
          order by rm.room_number)
    from rooms rm where rm.branch_id = p_branch), '[]'::jsonb);
end $$;
revoke all on function fn_admin_unit_guides(uuid) from public, anon;
grant execute on function fn_admin_unit_guides(uuid) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 3. The log lines
-- ---------------------------------------------------------------------------------------------------------------
do $$
declare fn oid; def text; n int;
        old_e constant text := $a$      when 'review.replied' then 'الرد على تقييم'$a$;
        new_e constant text := $b$      when 'review.replied' then 'الرد على تقييم'
      when 'branch.media_approved' then 'اعتماد صورة شرح وحدة'
      when 'branch.media_unapproved' then 'سحب اعتماد صورة شرح وحدة'$b$;
begin
  select p.oid into fn from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'fn_audit_accounting_label';
  def := pg_get_functiondef(fn);
  if position('branch.media_approved' in def) > 0 then return; end if;
  n := (length(def) - length(replace(def, old_e, ''))) / length(old_e);
  if n <> 1 then raise exception '0071: the last line of fn_audit_accounting_label was found % times, not once', n; end if;
  execute replace(def, old_e, new_e);
end $$;
