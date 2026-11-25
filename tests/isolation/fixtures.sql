-- =====================================================================
-- Plan item 2.11 isolation gate: fixtures.
-- Two hotels x two branches x six roles with real auth identities, two guests
-- per hotel with live phone sessions, and the column overrides the generic
-- seeder needs. Deterministic ids, all under the 'a*' uuid prefix family, so
-- Load into a new disposable database only, never a shared database.
-- =====================================================================
\set ON_ERROR_STOP on

-- ---------------------------------------------------------------- ids
insert into iso.ids values
 ('org-a','a1000000-0000-0000-0000-000000000001'), ('org-b','a1000000-0000-0000-0000-000000000002'),
 ('branch-a-1','a2000000-0000-0000-0000-000000000001'), ('branch-a-2','a2000000-0000-0000-0000-000000000002'),
 ('branch-b-1','a2000000-0000-0000-0000-000000000003'), ('branch-b-2','a2000000-0000-0000-0000-000000000004'),
 ('res-g-a1','a5000000-0000-0000-0000-000000000001'), ('res-g-a2','a5000000-0000-0000-0000-000000000002'),
 ('res-g-b1','a5000000-0000-0000-0000-000000000003'), ('res-g-b2','a5000000-0000-0000-0000-000000000004'),
 ('cat-a-1','a6000000-0000-0000-0000-000000000001'), ('cat-b-1','a6000000-0000-0000-0000-000000000003');

insert into iso.target values
 ('hotel-a|branch-1','hotel-a','branch-1',iso.id('org-a'),iso.id('branch-a-1')),
 ('hotel-a|branch-2','hotel-a','branch-2',iso.id('org-a'),iso.id('branch-a-2')),
 ('hotel-b|branch-1','hotel-b','branch-1',iso.id('org-b'),iso.id('branch-b-1')),
 ('hotel-b|branch-2','hotel-b','branch-2',iso.id('org-b'),iso.id('branch-b-2'));

-- ---------------------------------------------------------------- organizations and branches (hand-made; seeder skips)
insert into organizations(id, name_ar, guest_slug, platform_status, version) values
 (iso.id('org-a'),'فندق العزل أ','iso-gate-a','active',1),
 (iso.id('org-b'),'فندق العزل ب','iso-gate-b','active',1);
insert into iso.created(tbl, id, org, branch, purpose) values
 ('organizations', iso.id('org-a')::text, iso.id('org-a'), null, 'victim'),
 ('organizations', iso.id('org-b')::text, iso.id('org-b'), null, 'victim');

insert into branches(id, organization_id, name_ar, timezone, tax_rate_bp, prices_include_tax, default_deposit_halalas,
                     version, supervisor_max_discount_bp, country_code, default_language, day_close_edit_minutes,
                     tax_rent_enabled, tax_rent_rate_bp, tax_services_enabled, tax_services_rate_bp,
                     tax_products_enabled, tax_products_rate_bp, is_active) values
 (iso.id('branch-a-1'), iso.id('org-a'), 'فرع أ١', 'Asia/Riyadh', 0, false, 0, 1, 0, 'SA', 'ar', 60, false, 1500, false, 1500, false, 1500, true),
 (iso.id('branch-a-2'), iso.id('org-a'), 'فرع أ٢', 'Asia/Riyadh', 0, false, 0, 1, 0, 'SA', 'ar', 60, false, 1500, false, 1500, false, 1500, true),
 (iso.id('branch-b-1'), iso.id('org-b'), 'فرع ب١', 'Asia/Riyadh', 0, false, 0, 1, 0, 'SA', 'ar', 60, false, 1500, false, 1500, false, 1500, true),
 (iso.id('branch-b-2'), iso.id('org-b'), 'فرع ب٢', 'Asia/Riyadh', 0, false, 0, 1, 0, 'SA', 'ar', 60, false, 1500, false, 1500, false, 1500, true);
insert into iso.created(tbl, id, org, branch, purpose)
 select 'branches', id::text, organization_id, null, 'victim' from branches where organization_id in (iso.id('org-a'), iso.id('org-b'));

-- ---------------------------------------------------------------- staff identities (9 per hotel) + auth.users
-- suffix: 0H1 owner, 0H2 manager branch1, 0H3 manager branch2, 0H4 supervisor b1, 0H5 supervisor b2,
--         0H6 finance b1, 0H7 finance b2, 0H8 housekeeping b1, 0H9 housekeeping b2; H = a or b.
do $$
declare h text; org uuid; b1 uuid; b2 uuid; n int; sfx text;
        roles text[] := array['owner','manager','manager','supervisor','supervisor','finance','finance','housekeeping','housekeeping'];
        br_of int[] := array[0,1,2,1,2,1,2,1,2];
begin
  for h in select unnest(array['a','b']) loop
    org := iso.id('org-' || h); b1 := iso.id('branch-' || h || '-1'); b2 := iso.id('branch-' || h || '-2');
    for n in 1..9 loop
      sfx := h || n::text;
      insert into auth.users(id, email, email_confirmed_at, created_at)
        values (('a4000000-0000-0000-0000-0000000000' || sfx)::uuid, 'iso-' || sfx || '@gate.invalid', now(), now());
      insert into staff_profiles(id, auth_user_id, organization_id, full_name, email, role, is_active)
        values (('a3000000-0000-0000-0000-0000000000' || sfx)::uuid, ('a4000000-0000-0000-0000-0000000000' || sfx)::uuid,
                org, 'موظف العزل ' || sfx, 'iso-' || sfx || '@gate.invalid', roles[n]::role_code, true);
      if br_of[n] > 0 then
        insert into branch_memberships(staff_id, branch_id)
          values (('a3000000-0000-0000-0000-0000000000' || sfx)::uuid, case when br_of[n] = 1 then b1 else b2 end);
      end if;
      insert into iso.actor(key, role, hotel, branch, auth_user, db_role)
        values (roles[n] || '|hotel-' || h || '|' || case when roles[n] = 'owner' then '-' else 'branch-' || br_of[n]::text end,
                roles[n], 'hotel-' || h, case when roles[n] = 'owner' then null else 'branch-' || br_of[n]::text end,
                ('a4000000-0000-0000-0000-0000000000' || sfx)::uuid, 'authenticated');
    end loop;
  end loop;
  insert into iso.actor(key, role, hotel, branch, auth_user, db_role) values ('guest|-|-', 'guest', null, null, null, 'anon');
end $$;
insert into iso.created(tbl, id, org, branch, purpose)
 select 'staff_profiles', id::text, organization_id, null, 'victim' from staff_profiles where organization_id in (iso.id('org-a'), iso.id('org-b'));
insert into iso.created(tbl, id, org, branch, purpose)
 select 'branch_memberships', m.id::text, b.organization_id, m.branch_id, 'victim'
   from branch_memberships m join branches b on b.id = m.branch_id
  where b.organization_id in (iso.id('org-a'), iso.id('org-b'));

-- ---------------------------------------------------------------- guests: two per hotel, each with a reservation, a primary guest row and a live phone session
do $$
declare g text; org uuid; br uuid; res uuid; phone text;
begin
  for g in select unnest(array['a1','a2','b1','b2']) loop
    org := iso.id('org-' || substring(g,1,1)); br := iso.id('branch-' || substring(g,1,1) || '-' || substring(g,2,1));
    res := iso.id('res-g-' || g); phone := '966551700' || lpad((ascii(substring(g,1,1))-96)::text,2,'0') || substring(g,2,1);
    insert into reservations(id, organization_id, branch_id, external_ref, check_in, check_out)
      values (res, org, br, 'ISO-G-' || upper(g), current_date, current_date + 2);
    insert into reservation_guests(reservation_id, full_name, phone, is_primary)
      values (res, 'نزيل العزل ' || g, phone, true);
    insert into guest_phone_sessions(token, phone, method, expires_at, organization_id, branch_id)
      values ('iso-tok-g' || g, phone, 'whatsapp_code', now() + interval '1 hour', org, br);
    insert into iso.created(tbl, id, org, branch, purpose) values
      ('reservations', res::text, org, br, 'victim'),
      ('guest_phone_sessions', (select token from guest_phone_sessions where token = 'iso-tok-g' || g), org, br, 'victim');
  end loop;
end $$;
insert into iso.created(tbl, id, org, branch, purpose)
  select 'reservation_guests', g.id::text, r.organization_id, r.branch_id, 'victim'
    from reservation_guests g join reservations r on r.id = g.reservation_id
   where r.organization_id in (iso.id('org-a'), iso.id('org-b'));
-- guest phones as fixture facts (uuid column unused; store as ids with generated uuids is awkward: keep in a side table)
create table if not exists iso.guest(key text primary key, phone text, token text, org uuid, branch uuid, reservation uuid);
insert into iso.guest
 select 'g' || g, '966551700' || lpad((ascii(substring(g,1,1))-96)::text,2,'0') || substring(g,2,1), 'iso-tok-g' || g,
        iso.id('org-' || substring(g,1,1)), iso.id('branch-' || substring(g,1,1) || '-' || substring(g,2,1)), iso.id('res-g-' || g)
   from (select unnest(array['a1','a2','b1','b2']) g) s;

-- ---------------------------------------------------------------- tables the generic seeder must not touch (hand fixtures above)
insert into iso.seed_skip(tbl, reason) values
 ('organizations','platform registry: fixtures are hand-made; platform tables are exempt surfaces'),
 ('platform_operators','platform registry: exempt surface'),
 ('platform_events','platform registry: exempt surface'),
 ('platform_support_grants','platform registry: exempt surface'),
 ('branches','hand-made named branches are the matrix targets'),
 ('staff_profiles','hand-made staff identities are the matrix actors'),
 ('branch_memberships','hand-made memberships define who may reach which branch'),
 ('guest_phone_sessions','hand-made live session tokens for cross-guest probes'),
 ('reservation_guests','hand-made primary guests bind phones to reservations for cross-guest probes');

-- ---------------------------------------------------------------- column overrides for the generic seeder / create probes
insert into iso.col_override(tbl, col, expr) values
 ('reservations','check_in','current_date + 1'),
 ('reservations','check_out','current_date + 3'),
 ('reservations','external_ref','''ISO-'' || $SALT$'),
 ('reservations','created_by','null::uuid'),
 ('accounting_periods','month','(date_trunc(''month'', current_date)::date + (abs(hashtext($SALT$)) % 240) * interval ''1 month'')::date'),
 ('bank_movements','occurred_at','now()'),
 ('bank_movements','dedupe_key','''ISO-DK-'' || $SALT$'),
 ('financial_vouchers','number','''ISO-V-'' || $SALT$'),
 ('financial_vouchers','idempotency_key','''ISO-IK-'' || $SALT$'),
 ('financial_vouchers','content_hash','''ISO-CH-'' || $SALT$'),
 ('expense_vouchers','number','''ISO-E-'' || $SALT$'),
 ('invoices','number','''ISO-IN-'' || $SALT$'),
 ('product_orders','number','''ISO-PO-'' || $SALT$'),
 ('journal_entries','number','''ISO-JE-'' || $SALT$'),
 ('guest_reviews','token_hash','''ISO-TH-'' || $SALT$'),
 ('data_purge_requests','token_hash','''ISO-TH-'' || $SALT$'),
 ('guest_phone_challenges','code_hash','''ISO-CC-'' || $SALT$'),
 ('whatsapp_inbound_messages','wa_message_id','''ISO-WA-'' || $SALT$'),
 ('rooms','room_number','''ISO-'' || $SALT$'),
 ('document_sequences','year','2099'),
 ('document_sequences','kind','''ISO-'' || $SALT$'),
 ('day_closings','business_date','current_date'),
 ('rate_calendar','night','current_date + (abs(hashtext($SALT$)) % 700)'),
 ('released_slots','date','current_date + (abs(hashtext($SALT$)) % 700)'),
 ('inventory_periods','date','current_date + (abs(hashtext($SALT$)) % 700)'),
 ('reservation_nights','night','current_date + (abs(hashtext($SALT$)) % 700)'),
 ('platform_payouts','received_on','current_date'),
 ('journey_ticks','last_at','now()'),
 ('monitor_runs','last_run_at','now()'),
 ('ai_branch_usage_daily','day','current_date'),
 ('ai_guest_usage_daily','day','current_date'),
 ('ai_usage_daily','day','current_date'),
 ('alert_events','event','''deposit_overdue'''),
 ('alert_rules','event','''deposit_overdue'''),
 ('cash_accounts','kind','case abs(hashtext($SALT$)) % 2 when 0 then ''cash_box'' else ''bank_account'' end'),
 ('gl_accounts','code','''1'' || (abs(hashtext($SALT$)) % 9999999)'),
 ('reservation_allocations','from_date','current_date + 10 + abs(hashtext($SALT$)) % 5000'),
 ('reservation_allocations','to_date','current_date + 13 + abs(hashtext($SALT$)) % 5000'),
 ('branch_media_items','kind','''video'''),
 ('branch_media_items','url','''https://iso.invalid/'' || $SALT$'),
 ('housekeeping_tasks','room_id','(select c.id::uuid from iso.created c where c.tbl=''rooms'' and c.org=$ORG$::uuid order by c.id limit 1)');

-- Register rows created by initialization triggers, rather than attempting duplicate inserts.
do $$ declare t text; sc text; pk text; begin
 for t in select unnest(array['ai_settings','finance_control_settings','system_settings','branch_journey_settings','cash_accounts','alert_rules']) loop
  pk := iso.pk_col(t);
  select scope into sc from iso.scope where tbl=t;
  execute format('insert into iso.created(tbl,id,org,branch,purpose) select %L,%s,organization_id,%s,''victim'' from public.%I where organization_id in ($1,$2) on conflict do nothing',
   t,iso.pk_ret(t),case when sc='branch' then 'branch_id' else 'null::uuid' end,t) using iso.id('org-a'),iso.id('org-b');
 end loop;
end $$;
insert into iso.col_override values
 ('role_permissions','role','''manager''::role_code'),
 ('journal_lines','debit_halalas','100'),
 ('journal_lines','credit_halalas','0'),
 ('expense_attachments','mime','''image/png'''),
 ('expense_attachments','bytes','decode(''01'',''hex'')'),
 ('expense_attachments','sha256','encode(digest(decode(''01'',''hex''),''sha256''),''hex'')');
insert into iso.seed_skip values ('journal_lines','hand-made balanced debit/credit pair per target (deferred balance trigger), see end of file');
-- Every failure is retained in iso.seed_error; absence never counts as isolation.
select iso.seed_all() as seeded;

-- Balanced journal lines: the deferred balance trigger checks each entry at commit, so every victim entry gets a
-- debit and a matching credit. The debit line is registered as the victim row.
do $$
declare tg record; e record; a uuid; l uuid;
begin
  for tg in select * from iso.target loop
    select c.id::uuid as id into e from iso.created c where c.tbl = 'journal_entries' and c.org = tg.org and c.purpose = 'victim'
      order by (c.branch is distinct from tg.branch_id), c.id limit 1;
    select c.id::uuid into a from iso.created c where c.tbl = 'gl_accounts' and c.org = tg.org and c.purpose = 'victim' order by c.id limit 1;
    if e.id is null or a is null then
      insert into iso.seed_error values ('journal_lines', tg.key, 'ISO_FIXTURE', 'no victim journal entry or account to attach lines to');
      continue;
    end if;
    insert into journal_lines(entry_id, account_id, debit_halalas, credit_halalas, organization_id, branch_id)
      values (e.id, a, 100, 0, tg.org, tg.branch_id) returning id into l;
    insert into journal_lines(entry_id, account_id, debit_halalas, credit_halalas, organization_id, branch_id)
      values (e.id, a, 0, 100, tg.org, tg.branch_id);
    insert into iso.created(tbl, id, org, branch, purpose) values ('journal_lines', l::text, tg.org, tg.branch_id, 'victim');
  end loop;
end $$;

-- Non-owner delete victim for staff_profiles: the last-owner guard blocks deleting the hand-made owners, so the delete
-- control and attacks aim at a separate housekeeping staff row per hotel (no auth identity, no children).
do $$
declare tg record; sid uuid; sc text;
begin
  select scope into sc from iso.scope where tbl = 'staff_profiles';
  for tg in select * from iso.target loop
    if exists (select 1 from iso.created where tbl = 'staff_profiles' and purpose = 'delvictim' and org = tg.org and branch is not distinct from case when sc = 'branch' then tg.branch_id end) then continue; end if;
    insert into staff_profiles(organization_id, full_name, email, role, is_active)
      values (tg.org, 'ضحية الحذف ' || tg.key, 'iso-del-' || replace(tg.key, '|', '-') || '@gate.invalid', 'housekeeping'::role_code, true)
      returning id into sid;
    insert into iso.created(tbl, id, org, branch, purpose)
      values ('staff_profiles', sid::text, tg.org, case when sc = 'branch' then tg.branch_id end, 'delvictim');
  end loop;
end $$;

insert into iso.immutable_op values
 ('audit_events','update','AUDIT_IMMUTABLE','supabase/migrations/20261124070000_0088_audit_log_hardening.sql: trg_audit_immutable (before update or delete, errcode 42501)'),
 ('audit_events','delete','AUDIT_IMMUTABLE','supabase/migrations/20261124070000_0088_audit_log_hardening.sql: trg_audit_immutable (before update or delete, errcode 42501)');
