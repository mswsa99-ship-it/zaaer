-- 0056 — Phase 2b of the 31 October review: the branch's real-life data and the lists, as the owner decided them
-- (1 November 2026).
--
-- SETUP-05 (owner's decision «أضف الكل»): a branch holds a photo gallery (ordered, with captions), entry videos (a link,
--   for the branch, a block or a unit), arrival instructions and the bank transfer details a guest may use (bank,
--   beneficiary, IBAN, checked). Each is edited in the settings and stays empty until supplied. The guest pages read them
--   through fn_public_branch_guide.
-- SETUP-14 (recommended): a booking source can be added (name, kind, whether the platform's number is required,
--   commission) and edited; switching one off takes a reason. A policy of topic «أخرى» carries its own label.
-- SETUP-10 (recommended): a policy is archived with a reason, not erased, and restored; an archived policy is never public.
-- SETUP-02 (recommended): the payment provider and the POS terminal of a branch are set in the settings: the provider,
--   the merchant and terminal numbers, a publishable key and a secret key (kept encrypted, never shown again).

-- ---------------------------------------------------------------------------------------------- SETUP-05 the branch
alter table branches add column if not exists arrival_instructions text;
alter table branches add column if not exists bank_name text;
alter table branches add column if not exists bank_beneficiary text;
alter table branches add column if not exists bank_iban text;

-- a Saudi IBAN: SA, two check digits, 20 more characters; the ISO 13616 check (mod 97 = 1)
create or replace function fn_valid_iban(p text) returns boolean
language plpgsql immutable set search_path = public as $$
declare s text; d text := ''; i int; c text; r int := 0;
begin
  if p is null then return false; end if;
  s := upper(regexp_replace(p, '\s', '', 'g'));
  if s !~ '^SA[0-9]{2}[0-9A-Z]{20}$' then return false; end if;
  s := substr(s, 5) || substr(s, 1, 4);
  for i in 1..length(s) loop
    c := substr(s, i, 1);
    d := d || case when c ~ '[0-9]' then c else (ascii(c) - 55)::text end;
  end loop;
  for i in 1..length(d) loop r := (r * 10 + substr(d, i, 1)::int) % 97; end loop;
  return r = 1;
end $$;
revoke all on function fn_valid_iban(text) from public, anon, authenticated;

-- the arrival instructions and the bank details of a branch (owner, or a manager of the branch); empty clears
create or replace function fn_admin_set_branch_guide(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b branches%rowtype; v_branch uuid := (p->>'branch_id')::uuid; before jsonb; after jsonb; v text;
begin
  perform fn_require_cap('branch.settings');
  perform fn_require_branch(v_branch);
  select * into b from branches where id = v_branch for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  before := jsonb_build_object('arrival_instructions', b.arrival_instructions, 'bank_name', b.bank_name, 'bank_beneficiary', b.bank_beneficiary, 'bank_iban', b.bank_iban);
  if p ? 'arrival_instructions' then
    v := nullif(trim(coalesce(p->>'arrival_instructions', '')), '');
    if v is not null and char_length(v) > 4000 then raise exception 'VALIDATION: arrival_instructions'; end if;
    b.arrival_instructions := v;
  end if;
  if p ? 'bank_name' then
    v := nullif(trim(coalesce(p->>'bank_name', '')), '');
    if v is not null and char_length(v) > 80 then raise exception 'VALIDATION: bank_name'; end if;
    b.bank_name := v;
  end if;
  if p ? 'bank_beneficiary' then
    v := nullif(trim(coalesce(p->>'bank_beneficiary', '')), '');
    if v is not null and char_length(v) > 120 then raise exception 'VALIDATION: bank_beneficiary'; end if;
    b.bank_beneficiary := v;
  end if;
  if p ? 'bank_iban' then
    v := nullif(upper(regexp_replace(fn_latin_digits(coalesce(p->>'bank_iban', '')), '\s', '', 'g')), '');
    if v is not null and not fn_valid_iban(v) then raise exception 'VALIDATION: iban'; end if;
    b.bank_iban := v;
  end if;
  -- the IBAN is shown to guests with the bank and the beneficiary, never alone
  if b.bank_iban is not null and (b.bank_name is null or b.bank_beneficiary is null) then raise exception 'VALIDATION: bank_details'; end if;
  update branches set arrival_instructions = b.arrival_instructions, bank_name = b.bank_name, bank_beneficiary = b.bank_beneficiary,
                      bank_iban = b.bank_iban, version = version + 1, updated_at = now()
  where id = b.id;
  after := jsonb_build_object('arrival_instructions', b.arrival_instructions, 'bank_name', b.bank_name, 'bank_beneficiary', b.bank_beneficiary, 'bank_iban', b.bank_iban);
  if after is distinct from before then
    perform fn_audit_change(b.id, 'branch.guide_changed', 'branch', b.id, before, after, null);
  end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function fn_admin_set_branch_guide(jsonb) from public, anon;
grant execute on function fn_admin_set_branch_guide(jsonb) to authenticated;

-- the gallery and the entry videos: photos are kept as files (PNG, JPG, WebP up to 1 MB), videos as https links
create table if not exists branch_media_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  branch_id uuid not null references branches(id),
  kind text not null check (kind in ('photo', 'video')),
  block_id uuid references blocks(id),
  room_id uuid references rooms(id),
  caption text,
  url text,
  mime text,
  bytes bytea,
  size_bytes int not null default 0,
  sha256 text,
  sort_order int not null default 0,
  archived_at timestamptz,
  archived_by uuid references staff_profiles(id),
  archive_reason text,
  created_at timestamptz not null default now(),
  created_by uuid references staff_profiles(id),
  updated_at timestamptz,
  check ((kind = 'photo' and bytes is not null and url is null) or (kind = 'video' and url is not null and bytes is null))
);
create index if not exists idx_branch_media_items_branch on branch_media_items(branch_id, kind, sort_order) where archived_at is null;
alter table branch_media_items enable row level security;
revoke all on branch_media_items from anon, authenticated;

create or replace function fn_admin_upsert_media_item(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare m branch_media_items%rowtype; v_branch uuid; v_kind text; raw text; bin bytea; v_mime text; v_url text; v_caption text; before jsonb;
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
    insert into branch_media_items(organization_id, branch_id, kind, block_id, room_id, caption, url, mime, bytes, size_bytes, sha256, sort_order, created_by)
    values (fn_user_org_id(), v_branch, v_kind, nullif(p->>'block_id', '')::uuid, nullif(p->>'room_id', '')::uuid, v_caption, v_url, v_mime, bin,
            coalesce(length(bin), 0), case when bin is not null then encode(digest(bin, 'sha256'), 'hex') end,
            coalesce((p->>'sort_order')::int, (select coalesce(max(sort_order), 0) + 1 from branch_media_items where branch_id = v_branch and kind = v_kind)), fn_staff_id())
    returning * into m;
    perform fn_audit_change(v_branch, 'branch.media_added', 'branch_media_item', m.id, null,
      jsonb_build_object('kind', m.kind, 'caption', m.caption, 'url', m.url, 'size_bytes', m.size_bytes, 'block_id', m.block_id, 'room_id', m.room_id), null);
  else
    before := jsonb_build_object('caption', m.caption, 'sort_order', m.sort_order, 'url', m.url, 'block_id', m.block_id, 'room_id', m.room_id);
    if v_kind = 'video' and p ? 'url' then
      v_url := trim(coalesce(p->>'url', ''));
      if not fn_valid_https_url(v_url) or char_length(v_url) > 500 then raise exception 'VALIDATION: video_url'; end if;
    end if;
    update branch_media_items set caption = v_caption, url = case when v_kind = 'video' and p ? 'url' then v_url else url end,
      sort_order = coalesce((p->>'sort_order')::int, sort_order),
      block_id = case when p ? 'block_id' then nullif(p->>'block_id', '')::uuid else block_id end,
      room_id = case when p ? 'room_id' then nullif(p->>'room_id', '')::uuid else room_id end, updated_at = now()
    where id = m.id returning * into m;
    perform fn_audit_change(v_branch, 'branch.media_changed', 'branch_media_item', m.id, before,
      jsonb_build_object('caption', m.caption, 'sort_order', m.sort_order, 'url', m.url, 'block_id', m.block_id, 'room_id', m.room_id), null);
  end if;
  return jsonb_build_object('ok', true, 'id', m.id);
end $$;
revoke all on function fn_admin_upsert_media_item(jsonb) from public, anon;
grant execute on function fn_admin_upsert_media_item(jsonb) to authenticated;

-- archived with a reason (never erased), and restored
create or replace function fn_admin_archive_media_item(p_id uuid, p_reason text, p_archive boolean default true) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m branch_media_items%rowtype;
begin
  perform fn_require_cap('branch.settings');
  select * into m from branch_media_items where id = p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(m.branch_id);
  if p_archive then
    if coalesce(trim(p_reason), '') = '' then raise exception 'VALIDATION: reason'; end if;
    update branch_media_items set archived_at = now(), archived_by = fn_staff_id(), archive_reason = trim(p_reason) where id = m.id;
  else
    update branch_media_items set archived_at = null, archived_by = null, archive_reason = null where id = m.id;
  end if;
  perform fn_audit_change(m.branch_id, case when p_archive then 'branch.media_archived' else 'branch.media_restored' end, 'branch_media_item', m.id,
    null, jsonb_build_object('kind', m.kind, 'caption', m.caption), nullif(trim(coalesce(p_reason, '')), ''));
  return jsonb_build_object('ok', true);
end $$;
revoke all on function fn_admin_archive_media_item(uuid, text, boolean) from public, anon;
grant execute on function fn_admin_archive_media_item(uuid, text, boolean) to authenticated;

-- the staff's list of a branch's media (archived ones on request)
create or replace function fn_admin_media_items(p_branch uuid, p_archived boolean default false) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform fn_require_cap('branch.settings');
  perform fn_require_branch(p_branch);
  return coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'kind', m.kind, 'caption', m.caption, 'url', m.url, 'size_bytes', m.size_bytes,
           'sort_order', m.sort_order, 'block_id', m.block_id, 'room_id', m.room_id, 'archived_at', m.archived_at, 'archive_reason', m.archive_reason,
           'version', left(coalesce(m.sha256, md5(coalesce(m.url, ''))), 12)) order by m.kind, m.sort_order, m.created_at)
    from branch_media_items m where m.branch_id = p_branch and (p_archived or m.archived_at is null)), '[]'::jsonb);
end $$;
revoke all on function fn_admin_media_items(uuid, boolean) from public, anon;
grant execute on function fn_admin_media_items(uuid, boolean) to authenticated;

-- a photo as a data URL: public for an active branch, staff of the branch otherwise
create or replace function fn_branch_photo(p_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select 'data:' || m.mime || ';base64,' || replace(encode(m.bytes, 'base64'), E'\n', '')
  from branch_media_items m join branches b on b.id = m.branch_id
  where m.id = p_id and m.kind = 'photo' and m.bytes is not null
    and ((m.archived_at is null and b.is_active) or m.branch_id in (select fn_user_branch_ids()));
$$;
revoke all on function fn_branch_photo(uuid) from public;
grant execute on function fn_branch_photo(uuid) to anon, authenticated;

-- what a guest page shows of a branch beyond fn_public_branch: arrival instructions, the bank details (all three or
-- none), the gallery (ids and captions; the photo itself through fn_branch_photo) and the entry videos
create or replace function fn_public_branch_guide(p_branch uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'arrival_instructions', b.arrival_instructions,
    'bank', case when b.bank_iban is not null then jsonb_build_object('bank_name', b.bank_name, 'beneficiary', b.bank_beneficiary, 'iban', b.bank_iban) end,
    'photos', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'caption', m.caption, 'version', left(m.sha256, 12)) order by m.sort_order, m.created_at)
                        from branch_media_items m where m.branch_id = b.id and m.kind = 'photo' and m.archived_at is null and m.room_id is null), '[]'::jsonb),
    'videos', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'caption', m.caption, 'url', m.url, 'block_id', m.block_id, 'room_id', m.room_id) order by m.sort_order, m.created_at)
                        from branch_media_items m where m.branch_id = b.id and m.kind = 'video' and m.archived_at is null), '[]'::jsonb))
  from branches b where b.id = p_branch and (b.is_active or b.id in (select fn_user_branch_ids()));
$$;
revoke all on function fn_public_branch_guide(uuid) from public;
grant execute on function fn_public_branch_guide(uuid) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------- SETUP-14 booking sources
create or replace function fn_admin_upsert_source(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s booking_sources%rowtype; v_name text := trim(coalesce(p->>'name', '')); v_kind text; v_ref boolean; v_bp int; before jsonb; used boolean;
begin
  perform fn_require_cap('definitions');
  if (p->>'id') is not null then
    select * into s from booking_sources where id = (p->>'id')::uuid and organization_id = fn_user_org_id() for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    if not (p ? 'name') then v_name := s.name; end if;
  end if;
  if v_name = '' or char_length(v_name) > 80 then raise exception 'VALIDATION: name'; end if;
  if exists (select 1 from booking_sources x where x.organization_id = fn_user_org_id() and x.archived_at is null and x.id is distinct from s.id
               and fn_normalize_ar(trim(x.name)) = fn_normalize_ar(v_name)) then
    raise exception 'DUPLICATE_SOURCE_NAME';
  end if;
  v_kind := coalesce(nullif(p->>'kind', ''), s.kind, 'external');
  if v_kind not in ('direct', 'external') then raise exception 'VALIDATION: source_kind'; end if;
  v_ref := coalesce((p->>'external_reference_required')::boolean, s.external_reference_required, v_kind = 'external');
  if (p ? 'commission_bp') and coalesce(p->>'commission_bp', '') !~ '^[0-9]{1,5}$' then raise exception 'VALIDATION: commission'; end if;
  v_bp := coalesce((p->>'commission_bp')::int, s.commission_bp, 0);
  if v_bp > 10000 then raise exception 'VALIDATION: commission'; end if;
  if v_kind = 'direct' then v_bp := 0; end if;
  if s.id is null then
    insert into booking_sources(organization_id, name, code, kind, external_reference_required, commission_bp, is_active)
    values (fn_user_org_id(), v_name, 'custom_' || substr(md5(gen_random_uuid()::text), 1, 10), v_kind, v_ref, v_bp, true)
    returning * into s;
    perform fn_audit_change(null, 'source.created', 'booking_source', s.id, null,
      jsonb_build_object('name', s.name, 'code', s.code, 'kind', s.kind, 'external_reference_required', s.external_reference_required, 'commission_bp', s.commission_bp), null);
  else
    -- a source already used by a booking keeps its kind (a platform's bookings stay platform bookings)
    select exists (select 1 from reservations where source_id = s.id) into used;
    if used and v_kind <> s.kind then raise exception 'SOURCE_IN_USE: kind'; end if;
    before := jsonb_build_object('name', s.name, 'kind', s.kind, 'external_reference_required', s.external_reference_required, 'commission_bp', s.commission_bp);
    update booking_sources set name = v_name, kind = v_kind, external_reference_required = v_ref, commission_bp = v_bp where id = s.id returning * into s;
    if jsonb_build_object('name', s.name, 'kind', s.kind, 'external_reference_required', s.external_reference_required, 'commission_bp', s.commission_bp) is distinct from before then
      perform fn_audit_change(null, 'source.updated', 'booking_source', s.id, before,
        jsonb_build_object('name', s.name, 'kind', s.kind, 'external_reference_required', s.external_reference_required, 'commission_bp', s.commission_bp),
        nullif(trim(coalesce(p->>'reason', '')), ''));
    end if;
  end if;
  return jsonb_build_object('ok', true, 'id', s.id, 'code', s.code);
end $$;
revoke all on function fn_admin_upsert_source(jsonb) from public, anon;
grant execute on function fn_admin_upsert_source(jsonb) to authenticated;

-- switching a source off takes a reason (switching it back on does not)
create or replace function public.fn_admin_set_source_active(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare s booking_sources%rowtype; v_active boolean := (p->>'is_active')::boolean; v_reason text := nullif(trim(coalesce(p->>'reason', '')), '');
begin
  perform fn_require_cap('definitions');
  if v_active is null then raise exception 'VALIDATION: is_active'; end if;
  select * into s from booking_sources where id = (p->>'id')::uuid and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if s.is_active = v_active then return jsonb_build_object('ok', true, 'changed', false); end if;
  if not v_active and v_reason is null then raise exception 'VALIDATION: reason'; end if;
  update booking_sources set is_active = v_active where id = s.id;
  perform fn_audit_change(null, case when v_active then 'source.enabled' else 'source.disabled' end, 'booking_source', s.id,
    jsonb_build_object('code', s.code, 'is_active', s.is_active), jsonb_build_object('code', s.code, 'is_active', v_active), v_reason);
  return jsonb_build_object('ok', true, 'changed', true);
end $function$;

-- ---------------------------------------------------------------------------------------------- SETUP-10/14 policies
alter table property_policies add column if not exists topic_label text;
alter table property_policies add column if not exists archived_at timestamptz;
alter table property_policies add column if not exists archived_by uuid references staff_profiles(id);
alter table property_policies add column if not exists archive_reason text;

-- an archived policy is never public; «أخرى» carries its own label; a title and content within bounds
create or replace function fn_trg_policy_rules() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.title := trim(coalesce(new.title, ''));
  new.content_ar := trim(coalesce(new.content_ar, ''));
  if new.title = '' or new.content_ar = '' then raise exception 'VALIDATION: policy_required'; end if;
  if char_length(new.title) > 120 or char_length(new.content_ar) > 4000 then raise exception 'VALIDATION: policy_length'; end if;
  new.topic_label := nullif(trim(coalesce(new.topic_label, '')), '');
  if new.topic <> 'other' then new.topic_label := null; end if;
  if new.topic_label is not null and char_length(new.topic_label) > 60 then raise exception 'VALIDATION: topic_label'; end if;
  if new.archived_at is not null then
    new.is_public := false;
    if tg_op = 'UPDATE' and old.archived_at is null and coalesce(trim(new.archive_reason), '') = '' then raise exception 'VALIDATION: reason'; end if;
  else
    new.archive_reason := null; new.archived_by := null;
  end if;
  return new;
end $$;
revoke all on function fn_trg_policy_rules() from public, anon, authenticated;
create or replace trigger trg_policy_rules before insert or update on property_policies
  for each row execute function fn_trg_policy_rules();

-- a policy is archived, not erased (the screen's «حذف» is gone); the write policy covers inserts and updates
revoke all on property_policies from anon, authenticated;
grant select on property_policies to anon, authenticated;
grant insert, update on property_policies to authenticated;

-- ---------------------------------------------------------------------------------------------- SETUP-02 payments
create table if not exists branch_payment_settings (
  branch_id uuid primary key references branches(id),
  organization_id uuid not null references organizations(id),
  provider text check (provider in ('moyasar', 'tap', 'hyperpay', 'paytabs', 'other')),
  provider_label text,
  merchant_id text,
  publishable_key text,
  secret_key_encrypted bytea,
  secret_last4 text,
  pos_terminal_id text,
  online_enabled boolean not null default false,
  updated_at timestamptz,
  updated_by uuid references staff_profiles(id)
);
alter table branch_payment_settings enable row level security;
revoke all on branch_payment_settings from anon, authenticated;

create or replace function fn_admin_payment_settings(p_branch uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s branch_payment_settings%rowtype;
begin
  perform fn_require_cap('security');
  perform fn_require_branch(p_branch);
  select * into s from branch_payment_settings where branch_id = p_branch;
  return jsonb_build_object('branch_id', p_branch, 'provider', s.provider, 'provider_label', s.provider_label, 'merchant_id', s.merchant_id,
    'publishable_key', s.publishable_key, 'has_secret', s.secret_key_encrypted is not null, 'secret_last4', s.secret_last4,
    'pos_terminal_id', s.pos_terminal_id, 'online_enabled', coalesce(s.online_enabled, false), 'updated_at', s.updated_at,
    'updated_by', (select full_name from staff_profiles where id = s.updated_by),
    'complete', s.provider is not null and s.merchant_id is not null and s.publishable_key is not null and s.secret_key_encrypted is not null);
end $$;
revoke all on function fn_admin_payment_settings(uuid) from public, anon;
grant execute on function fn_admin_payment_settings(uuid) to authenticated;

create or replace function fn_admin_save_payment_settings(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare s branch_payment_settings%rowtype; v_branch uuid := (p->>'branch_id')::uuid; v text; changed text[] := '{}'; was boolean;
begin
  perform fn_require_cap('security');
  perform fn_require_branch(v_branch);
  select * into s from branch_payment_settings where branch_id = v_branch for update;
  was := found;
  if not was then s.branch_id := v_branch; s.organization_id := (select organization_id from branches where id = v_branch); s.online_enabled := false; end if;
  if p ? 'provider' then
    v := nullif(trim(coalesce(p->>'provider', '')), '');
    if v is not null and v not in ('moyasar', 'tap', 'hyperpay', 'paytabs', 'other') then raise exception 'VALIDATION: provider'; end if;
    if v is distinct from s.provider then s.provider := v; changed := array_append(changed, 'provider'); end if;
  end if;
  if p ? 'provider_label' then
    v := nullif(trim(coalesce(p->>'provider_label', '')), '');
    if v is not null and char_length(v) > 60 then raise exception 'VALIDATION: provider_label'; end if;
    s.provider_label := v;
  end if;
  if s.provider is distinct from 'other' then s.provider_label := null; end if;
  if p ? 'merchant_id' then
    v := nullif(trim(coalesce(p->>'merchant_id', '')), '');
    if v is not null and (char_length(v) > 80 or v !~ '^[A-Za-z0-9._:-]+$') then raise exception 'VALIDATION: merchant_id'; end if;
    if v is distinct from s.merchant_id then s.merchant_id := v; changed := array_append(changed, 'merchant_id'); end if;
  end if;
  if p ? 'publishable_key' then
    v := nullif(trim(coalesce(p->>'publishable_key', '')), '');
    if v is not null and (char_length(v) > 200 or v ~ '\s') then raise exception 'VALIDATION: publishable_key'; end if;
    if v is distinct from s.publishable_key then s.publishable_key := v; changed := array_append(changed, 'publishable_key'); end if;
  end if;
  -- the secret key is kept encrypted and never returned; an empty value leaves it, «clear_secret» removes it
  if nullif(trim(coalesce(p->>'secret_key', '')), '') is not null then
    v := trim(p->>'secret_key');
    if char_length(v) < 8 or char_length(v) > 300 or v ~ '\s' then raise exception 'VALIDATION: secret_key'; end if;
    s.secret_key_encrypted := pgp_sym_encrypt(v, fn_secret('keybox_key')); s.secret_last4 := right(v, 4); changed := array_append(changed, 'secret_key');
  elsif coalesce((p->>'clear_secret')::boolean, false) and s.secret_key_encrypted is not null then
    s.secret_key_encrypted := null; s.secret_last4 := null; changed := array_append(changed, 'secret_key');
  end if;
  if p ? 'pos_terminal_id' then
    v := nullif(fn_latin_digits(trim(coalesce(p->>'pos_terminal_id', ''))), '');
    if v is not null and (char_length(v) > 40 or v !~ '^[A-Za-z0-9-]+$') then raise exception 'VALIDATION: pos_terminal_id'; end if;
    if v is distinct from s.pos_terminal_id then s.pos_terminal_id := v; changed := array_append(changed, 'pos_terminal_id'); end if;
  end if;
  if p ? 'online_enabled' then
    if (p->>'online_enabled')::boolean and (s.provider is null or s.merchant_id is null or s.publishable_key is null or s.secret_key_encrypted is null) then
      raise exception 'VALIDATION: payment_incomplete';
    end if;
    if (p->>'online_enabled')::boolean is distinct from s.online_enabled then s.online_enabled := (p->>'online_enabled')::boolean; changed := array_append(changed, 'online_enabled'); end if;
  end if;
  if s.online_enabled and (s.provider is null or s.merchant_id is null or s.publishable_key is null or s.secret_key_encrypted is null) then s.online_enabled := false; end if;
  insert into branch_payment_settings(branch_id, organization_id, provider, provider_label, merchant_id, publishable_key, secret_key_encrypted, secret_last4,
                                      pos_terminal_id, online_enabled, updated_at, updated_by)
  values (s.branch_id, s.organization_id, s.provider, s.provider_label, s.merchant_id, s.publishable_key, s.secret_key_encrypted, s.secret_last4,
          s.pos_terminal_id, s.online_enabled, now(), fn_staff_id())
  on conflict (branch_id) do update set provider = excluded.provider, provider_label = excluded.provider_label, merchant_id = excluded.merchant_id,
    publishable_key = excluded.publishable_key, secret_key_encrypted = excluded.secret_key_encrypted, secret_last4 = excluded.secret_last4,
    pos_terminal_id = excluded.pos_terminal_id, online_enabled = excluded.online_enabled, updated_at = excluded.updated_at, updated_by = excluded.updated_by;
  if cardinality(changed) > 0 then
    perform fn_audit_change(v_branch, 'payment_settings.updated', 'branch', v_branch, null,
      jsonb_build_object('changed', to_jsonb(changed), 'provider', s.provider, 'secret_last4', s.secret_last4, 'online_enabled', s.online_enabled), null);
  end if;
  return jsonb_build_object('ok', true, 'changed', to_jsonb(changed));
end $$;
revoke all on function fn_admin_save_payment_settings(jsonb) from public, anon;
grant execute on function fn_admin_save_payment_settings(jsonb) to authenticated;
