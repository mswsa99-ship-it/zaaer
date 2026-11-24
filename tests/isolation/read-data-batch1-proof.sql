-- read-data lane, batch 1 identity proof (local disposable PG16 only, one transaction, rolled back).
-- Load AFTER fixtures.sql ONLY (no rpc-fixtures preload required). Run: psql -X -d iso_* -v ON_ERROR_STOP=1 -v strict=1 -f tests/isolation/read-data-batch1-proof.sql
-- Contract (docs/acceptance-lanes/README.md, read-data): two hotels / two branches, real authenticated actor positives,
-- wrong-hotel / wrong-branch / no-capability / no-page-grant denials, result CONTENT checked against synthetic identity markers
-- (never "success with an empty array"), foreign + legacy-org decoys, and a whole-catalog no-write snapshot after every actor.
-- Markers are stamped on existing fixture rows inside the transaction and vanish on rollback. No shared fixture file is edited.
-- Not covered here (see docs/acceptance-lanes/read-data-batch1-status.md): platform/exit/status reads, fn_admin_products (reserved),
-- definition_dependencies, invoice_preview, quote_stay, reports_capability_usage, the three public/anon reads, constant helpers.
\set ON_ERROR_STOP on
begin;

-- ---------------------------------------------------------------- 1. synthetic identity markers
-- code: A1 A2 B1 B2 per branch; A B per hotel (org-wide rows); O = the legacy default org (third decoy org).
create temp table mk_branch as
  select t.branch_id, t.org, case when t.hotel = 'hotel-a' then 'A' else 'B' end || right(t.branch, 1) as code, case when t.hotel = 'hotel-a' then 'A' else 'B' end as org_code
    from iso.target t;
grant all on mk_branch to public;
create temp table mk_org as select distinct org, org_code from mk_branch union all select '00000000-0000-0000-0000-000000000001'::uuid, 'O';
grant all on mk_org to public;

update alert_rules r set delay_minutes = case m.org_code when 'A' then 111 when 'B' then 222 else 333 end from mk_org m where m.org = r.organization_id;
insert into room_licenses(room_id, organization_id, branch_id, license_number)
  select rm.id, b.organization_id, rm.branch_id, 'MK-LIC-' || m.code from rooms rm join branches b on b.id = rm.branch_id join mk_branch m on m.branch_id = rm.branch_id
  on conflict (room_id) do update set license_number = excluded.license_number;
update room_categories c set base_price_halalas = 30000 + 100 * x.n from (select id, row_number() over (order by id) n from room_categories) x where x.id = c.id;
update organizations o set name_ar = 'MK-ORG-' || m.org_code from mk_org m where m.org = o.id;
update branches b set name_ar = 'MK-BR-' || m.code from mk_branch m where m.branch_id = b.id;
update branch_payment_settings s set merchant_id = 'MK-PAY-' || m.code from mk_branch m where m.branch_id = s.branch_id;
update branch_journey_settings s set checkout_instructions = 'MK-JRN-' || m.code from mk_branch m where m.branch_id = s.branch_id;
update branch_media_items i set caption = 'MK-MED-' || m.code from mk_branch m where m.branch_id = i.branch_id and i.archived_at is null;
update branch_media i set bytes = '\x01'::bytea, size_bytes = 1, mime = 'image/mk-' || lower(m.code) from mk_branch m where m.branch_id = i.branch_id;
update branch_whatsapp_channels c set bridge_name = 'MK-WA-' || m.code from mk_branch m where m.branch_id = c.branch_id;
update bank_mail_settings s set mailbox_address = 'MK-MAIL-' || m.org_code || '@iso.invalid' from mk_org m where m.org = s.organization_id;
update cash_accounts a set name = 'MK-ACC-' || m.code from mk_branch m where m.branch_id = a.branch_id and a.kind = 'bank_account';
-- one executed purge per hotel (listed) plus the remaining pending requests carrying a different tag (must never be listed)
update data_purge_requests q set result = jsonb_build_object('mk', 'MK-PND-' || m.org_code) from mk_org m where m.org = q.organization_id;
update data_purge_requests q set status = 'done', executed_at = now(), result = jsonb_build_object('mk', 'MK-PRG-' || m.org_code)
  from mk_org m where m.org = q.organization_id and q.id = (select min(x.id::text)::uuid from data_purge_requests x where x.organization_id = q.organization_id);
update knowledge_entries k set question = 'MK-KN-' || coalesce(b.code, o.org_code) || '_' || left(k.id::text, 4) || ' marker'
  from mk_org o left join mk_branch b on true
 where o.org = k.organization_id and (k.branch_id is null and b.code is null or b.branch_id = k.branch_id) and k.question is not null;
update staff_saved_views v set name = 'MK-SV-' || m.org_code || '_' || left(v.staff_id::text, 6) from mk_org m where m.org = v.organization_id;
insert into staff_saved_views(organization_id, staff_id, screen, name)
  select p.organization_id, p.id, 'reservations', 'MK-SV-' || m.org_code || '_' || left(p.id::text, 6) from staff_profiles p join mk_org m on m.org = p.organization_id
   where p.is_active and not exists (select 1 from staff_saved_views x where x.staff_id = p.id and x.screen = 'reservations');
create temp table spa_orig as select * from staff_page_access;
grant all on spa_orig to public;

-- ---------------------------------------------------------------- 2. spec table
-- legacy_roles: roles that pass in legacy (no staff_page_access row) mode. page: page gate (individual mode applies). ind_roles: roles that
-- pass the inner role gate once the page is granted (null = same as legacy_roles). deny_mode: how a denial looks (error 42501 / null result).
-- req: tag:where tokens that MUST appear in an allowed response (target = the branch asked for, each = every accessible branch, org = hotel-wide).
create temp table spec(id text primary key, call_sql text not null, scope text not null, legacy_roles text[] not null, page text, ind_roles text[], deny_mode text not null default 'error',
  req text[] not null default '{}', exp_eq text, exp_ids_sql text, act_ids text, note text);
grant all on spec to public;
insert into spec(id, call_sql, scope, legacy_roles, req, note) values
 ('fn_admin_payment_settings', $q$select fn_admin_payment_settings({b}::uuid)$q$, 'branch', '{owner}', '{PAY:target}', 'cap security'),
 ('fn_admin_journey_settings', $q$select fn_admin_journey_settings({b}::uuid)$q$, 'branch', '{owner,manager}', '{JRN:target}', 'cap branch.settings'),
 ('fn_admin_media_items', $q$select fn_admin_media_items({b}::uuid, true)$q$, 'branch', '{owner,manager}', '{MED:target}', 'cap branch.settings'),
 ('fn_admin_branch_media_info', $q$select fn_admin_branch_media_info({b}::uuid)$q$, 'branch', '{owner,manager}', '{}', 'mime marker lowercase, checked via exp_eq on mime set'),
 ('fn_admin_unit_guides', $q$select fn_admin_unit_guides({b}::uuid)$q$, 'branch', '{owner,manager}', '{}', 'room id set oracle'),
 ('fn_staff_knowledge', $q$select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from fn_staff_knowledge({b}::uuid) t$q$, 'branch', '{owner,manager,supervisor,finance,housekeeping}', '{KN:target}', 'no cap, branch membership is the gate; denial = empty array'),
 ('fn_staff_product_menu', $q$select fn_staff_product_menu({b}::uuid)$q$, 'branch', '{owner,manager,supervisor,finance}', '{}', 'cap voucher.receipt; stays id oracle'),
 ('fn_room_licenses', $q$select fn_room_licenses({b}::uuid)$q$, 'branch', '{owner,manager,supervisor}', '{LIC:target}', 'page /admin/rooms + role + branch'),
 ('fn_report_filter_options', $q$select fn_report_filter_options({b}::uuid)$q$, 'branch', '{owner,manager,supervisor,finance}', '{ACC:target}', 'fn_sees_money + branch; denial = {}'),
 ('fn_category_capacity_impact', $q$select fn_category_capacity_impact({cat}::uuid, 0)$q$, 'cat', '{owner,manager}', '{}', 'cap definitions; reservation id set oracle'),
 ('fn_price_limits', $q$select fn_price_limits({cat}::uuid)$q$, 'cat', '{owner,manager,supervisor,finance,housekeeping}', '{}', 'page /admin/rates; foreign category = null'),
 ('fn_admin_alert_rules', $q$select fn_admin_alert_rules()$q$, 'org', '{owner,manager}', '{}', 'legacy cap branch.settings; individual mode page /admin/journey only'),
 ('fn_admin_bank_mail_get', $q$select fn_admin_bank_mail_get()$q$, 'org', '{owner}', '{MAIL:org,ACC:each}', 'cap bank.manage'),
 ('fn_admin_purge_history', $q$select fn_admin_purge_history()$q$, 'org', '{owner}', '{PRG:org}', 'cap security'),
 ('fn_admin_trial_overview', $q$select fn_admin_trial_overview()$q$, 'org', '{owner}', '{}', 'cap security; counts oracle'),
 ('fn_admin_whatsapp_channels', $q$select fn_admin_whatsapp_channels()$q$, 'org', '{owner}', '{WA:each,BR:each}', 'cap security'),
 ('fn_audit_chain_verify', $q$select fn_audit_chain_verify()$q$, 'org', '{owner}', '{}', 'cap security; checked count oracle'),
 ('fn_organization_info', $q$select fn_organization_info()$q$, 'org', '{owner,manager,supervisor,finance,housekeeping}', '{ORG:org}', 'own org only'),
 ('fn_my_page_access', $q$select fn_my_page_access()$q$, 'org', '{owner,manager,supervisor,finance,housekeeping}', '{}', 'self'),
 ('fn_saved_views_list', $q$select fn_saved_views_list('reservations')$q$, 'org', '{owner,manager,supervisor,finance,housekeeping}', '{}', 'own staff views only; name oracle'),
 ('fn_review_summary', $q$select fn_review_summary()$q$, 'org', '{owner}', '{}', 'cap review.list; denial = null; open count oracle'),
 ('fn_review_list', $q$select fn_review_list('{}'::jsonb)$q$, 'org', '{owner}', '{}', 'page /admin/review + owner; open_count oracle'),
 ('fn_lookup_trace', $q$select fn_lookup_trace('MKTRACE01')$q$, 'org', '{owner,manager}', '{TRC:org}', 'page /admin/audit-logs + owner/manager; trace row stamped per org'),
 ('fn_bank_poll_allowed', $q$select to_jsonb(fn_bank_poll_allowed())$q$, 'org', '{owner,manager,supervisor,finance,housekeeping}', '{}', 'boolean; true only for bank.manage');
update spec set page = '/admin/rooms', ind_roles = '{owner,manager,supervisor}' where id = 'fn_room_licenses';
update spec set page = '/admin/rates', ind_roles = '{owner,manager,supervisor,finance,housekeeping}', deny_mode = 'null' where id = 'fn_price_limits';
update spec set page = '/admin/journey', ind_roles = '{owner,manager,supervisor,finance,housekeeping}' where id = 'fn_admin_alert_rules';
update spec set page = '/admin/review', ind_roles = '{owner}' where id = 'fn_review_list';
update spec set page = '/admin/audit-logs', ind_roles = '{owner,manager}' where id = 'fn_lookup_trace';
update spec set deny_mode = 'null' where id = 'fn_review_summary';
update spec set exp_ids_sql = $q$select array_agg(delay_minutes::text order by delay_minutes::text) from alert_rules where organization_id = {org}::uuid and delay_minutes = case (select m.org_code from mk_org m where m.org = {org}::uuid) when 'A' then 111 when 'B' then 222 else 333 end$q$, act_ids = '$[*].delay_minutes' where id = 'fn_admin_alert_rules';
update spec set exp_eq = $q$select jsonb_build_object('base', base_price_halalas) from room_categories where id = {cat}::uuid$q$ where id = 'fn_price_limits';
update spec set exp_eq = $q$select jsonb_build_object('mode', 'legacy')$q$ where id = 'fn_my_page_access';
update spec set deny_mode = 'empty' where id in ('fn_staff_knowledge');
update spec set deny_mode = 'emptyobj' where id = 'fn_report_filter_options';
-- exact oracles ({org}/{b}/{cat}/{acc}/{role}/{staff} are substituted by the driver; evaluated as superuser)
update spec set exp_ids_sql = $q$select coalesce(array_agg(id::text order by id), '{}') from rooms where branch_id = {b}::uuid$q$, act_ids = '$[*].room_id' where id = 'fn_admin_unit_guides';
update spec set exp_ids_sql = $q$select coalesce(array_agg(r.id::text order by r.id), '{}') from reservations r where r.branch_id = {b}::uuid and r.status = 'checked_in'$q$, act_ids = '$.stays[*].id' where id = 'fn_staff_product_menu';
update spec set exp_ids_sql = $q$select coalesce(array_agg(r.id::text order by r.id), '{}') from reservations r where r.room_category_id = {cat}::uuid and r.status in ('pending_verification','confirmed','checked_in') and r.check_out > fn_branch_today(r.branch_id) and r.adults + r.companions > 0$q$, act_ids = '$[*].id' where id = 'fn_category_capacity_impact';
update spec set exp_ids_sql = $q$select coalesce(array_agg(ri.id::text order by ri.id), '{}') from review_items ri where ri.organization_id = {org}::uuid and ri.reviewed_at is null and (ri.branch_id is null or ri.branch_id = any({acc}::uuid[]))$q$, act_ids = '$.items[*].id' where id = 'fn_review_list';
update spec set exp_eq = $q$select jsonb_build_object('open', count(*)) from review_items ri where ri.organization_id = {org}::uuid and ri.reviewed_at is null and (ri.branch_id is null or ri.branch_id = any({acc}::uuid[]))$q$ where id = 'fn_review_summary';
update spec set exp_eq = $q$select to_jsonb({role} = 'owner')$q$ where id = 'fn_bank_poll_allowed';
update spec set exp_ids_sql = $q$select coalesce(array_agg(v.name order by v.name), '{}') from staff_saved_views v where v.staff_id = {staff}::uuid and v.screen = 'reservations' and v.archived_at is null$q$, act_ids = '$[*].name' where id = 'fn_saved_views_list';
update spec set exp_eq = $q$select jsonb_build_object('ok', true, 'checked', count(*)) from audit_events where organization_id = {org}::uuid and chain_seq is not null$q$ where id = 'fn_audit_chain_verify';
update spec set exp_eq = $q$select jsonb_build_object('reservations', count(*), 'product_orders', (select count(*) from product_orders where organization_id = {org}::uuid), 'vouchers', (select count(*) from financial_vouchers where organization_id = {org}::uuid), 'guests_trial', (select count(*) from guest_profiles where organization_id = {org}::uuid and imported_at is null)) from reservations where organization_id = {org}::uuid$q$ where id = 'fn_admin_trial_overview';
update spec set exp_ids_sql = $q$select coalesce(array_agg(distinct m order by m), '{}') from (select lower(replace(mime,'image/mk-','')) m from branch_media where branch_id = {b}::uuid and bytes is not null) x$q$, act_ids = '$.*.mime' where id = 'fn_admin_branch_media_info';

-- trace rows so fn_lookup_trace has same-trace decoys in every org (same trace id, different org marker)
insert into client_errors(organization_id, trace_id, error_code, context)
  select o.org, 'MKTRACE01', 'E_MK', 'MK-TRC-' || o.org_code from mk_org o;

-- ---------------------------------------------------------------- 3. result table and the driver
create temp table res(spec text, actor text, state text, target text, expect text, got text, ok boolean, detail text);
grant all on res to public;
create temp table before_snap(k text primary key, v jsonb);
grant all on before_snap to public;

create or replace function pg_temp.tokens(j jsonb) returns text[] language sql as $$
  select coalesce(array_agg(distinct (m)[1] || ':' || (m)[2]), '{}') from regexp_matches(coalesce(j::text, ''), 'MK-([A-Z]+)-([ABO][12]?)', 'g') m
$$;

do $$
declare a record; sp record; tg record; st record; sid uuid; v_org uuid; accessible uuid[]; acc_codes text[]; own_code text; v_ocode text;
  call text; r jsonb; msg text; state_name text; pg jsonb; exp_class text; got_class text; ok boolean; detail text; toks text[]; tk text; allowed_codes text[];
  role_ok boolean; page_ok boolean; branch_ok boolean; target_codes text[]; tgt_branch uuid; tgt_cat uuid; b_before jsonb; b_after jsonb; n int; exp_ids text[]; act_ids text[]; exp_j jsonb; rq text;
  t_label text; targets text[]; i int;
begin
  for a in select * from iso.actor
           where role <> 'guest' and ((hotel = 'hotel-a' and (branch = 'branch-1' or role = 'owner' or (role = 'manager' and branch = 'branch-2'))) or (hotel = 'hotel-b' and (role = 'owner' or (role = 'manager' and branch = 'branch-1'))))
           order by hotel, role, branch loop
    select p.id, p.organization_id into sid, v_org from staff_profiles p where p.auth_user_id = a.auth_user;
    v_ocode := case when a.hotel = 'hotel-a' then 'A' else 'B' end;
    select coalesce(array_agg(m.branch_id), '{}'), coalesce(array_agg(m.code), '{}') into accessible, acc_codes
      from mk_branch m where m.org = v_org and (a.role = 'owner' or m.code = v_ocode || right(a.branch, 1));
    b_before := iso.snap();
    for st in select * from (values ('legacy', null::jsonb, 'legacy'), ('ind-empty', '{}'::jsonb, 'ind'), ('ind-page', '{}'::jsonb, 'ind'), ('ind-other', '{"/admin/staff":{"view":true}}'::jsonb, 'ind')) v(name, pg, kind) loop
      -- individual states are only meaningful for page-gated specs; 'ind-page' grants view on each spec's own page (built per spec below)
      for sp in select * from spec where (st.kind = 'legacy' or page is not null) order by id loop
        delete from staff_page_access where staff_id = sid;
        pg := case st.name when 'legacy' then null when 'ind-page' then jsonb_build_object(sp.page, jsonb_build_object('view', true)) else st.pg end;
        if pg is not null then insert into staff_page_access(staff_id, organization_id, enabled, page_grants) values (sid, v_org, true, pg); end if;
        targets := case sp.scope when 'branch' then array['own-b1','own-b2','foreign-b1'] when 'cat' then array['own-b1','own-b2','foreign-b1'] else array['self'] end;
        foreach t_label in array targets loop
          tgt_branch := null; tgt_cat := null; target_codes := '{}';
          if t_label <> 'self' then
            select m.branch_id, m.code into tgt_branch, own_code from mk_branch m
             where case t_label when 'own-b1' then m.code = v_ocode || '1' when 'own-b2' then m.code = v_ocode || '2'
                                when 'foreign-b1' then m.code = (case when v_ocode = 'A' then 'B' else 'A' end) || '1' end;
            target_codes := array[own_code];
            if sp.scope = 'cat' then select c.id into tgt_cat from room_categories c where c.branch_id = tgt_branch and c.archived_at is null order by c.id limit 1; end if;
          end if;
          -- expected allow: role gate (legacy or individual), page gate, branch gate
          role_ok := a.role = any (case when st.kind = 'legacy' then sp.legacy_roles else coalesce(sp.ind_roles, sp.legacy_roles) end);
          page_ok := st.kind = 'legacy' or a.role = 'owner' or st.name = 'ind-page';
          if a.role = 'owner' and st.kind = 'ind' then page_ok := true; end if;
          branch_ok := t_label = 'self' or (tgt_branch = any (accessible));
          -- legacy_roles fn_price_limits/fn_staff_knowledge: a wrong branch yields null/empty rather than an error (see deny_mode)
          exp_class := case when role_ok and page_ok and branch_ok then 'allow' else 'deny' end;
          -- fn_admin_alert_rules in individual mode is gated by the page only (inner cap not applied): ind_roles lists all roles
          call := replace(replace(replace(replace(replace(sp.call_sql, '{b}', quote_literal(coalesce(tgt_branch::text, ''))), '{cat}', quote_literal(coalesce(tgt_cat::text, ''))),
                  '{org}', quote_literal(v_org::text)), '{acc}', quote_literal(accessible::text)), '{role}', quote_literal(a.role));
          msg := null; r := null;
          perform iso.set_claims(a.auth_user); set local role authenticated;
          begin execute 'select to_jsonb(x) from (' || call || ') x(v)' into r; r := r->'v';
          exception when others then msg := sqlerrm; end;
          reset role;
          detail := null; ok := true;
          if msg is not null then got_class := case when msg like 'FORBIDDEN%' then 'deny' else 'error' end;
          elsif sp.deny_mode = 'null' and r is null or sp.deny_mode = 'null' and r = 'null'::jsonb then got_class := 'deny';
          elsif sp.deny_mode = 'empty' and r = '[]'::jsonb then got_class := 'deny';
          elsif sp.deny_mode = 'emptyobj' and r = '{}'::jsonb then got_class := 'deny';
          else got_class := 'allow'; end if;
          if got_class <> exp_class then ok := false; detail := coalesce(msg, left(r::text, 120)); end if;
          -- content identity for an allowed response
          if ok and got_class = 'allow' then
            toks := pg_temp.tokens(r);
            allowed_codes := case when sp.scope = 'org' then acc_codes || array[v_ocode] else target_codes || array[v_ocode] end;
            foreach tk in array toks loop
              if tk like 'PND:%' then ok := false; detail := coalesce(detail || '; ', '') || 'LEAK non-listed row ' || tk; end if;
              if split_part(tk, ':', 2) <> all (allowed_codes) and split_part(tk, ':', 2) <> v_ocode then
                ok := false; detail := coalesce(detail || '; ', '') || 'LEAK marker ' || tk; end if;
            end loop;
            foreach rq in array sp.req loop
              if rq like '%:target' then if not (split_part(rq, ':', 1) || ':' || target_codes[1]) = any (toks) then ok := false; detail := coalesce(detail || '; ', '') || 'MISSING ' || rq; end if;
              elsif rq like '%:each' then
                foreach tk in array acc_codes loop if not (split_part(rq, ':', 1) || ':' || tk) = any (toks) then ok := false; detail := coalesce(detail || '; ', '') || 'MISSING ' || split_part(rq, ':', 1) || ':' || tk; end if; end loop;
              elsif rq like '%:org' then if not (split_part(rq, ':', 1) || ':' || v_ocode) = any (toks) then ok := false; detail := coalesce(detail || '; ', '') || 'MISSING ' || rq; end if;
              end if;
            end loop;
            if sp.exp_eq is not null then
              execute replace(replace(replace(replace(replace(sp.exp_eq, '{org}', quote_literal(v_org::text)), '{acc}', quote_literal(accessible::text)), '{role}', quote_literal(a.role)), '{b}', quote_literal(coalesce(tgt_branch::text, ''))), '{cat}', quote_literal(coalesce(tgt_cat::text, ''))) into exp_j;
              if not (r @> exp_j) then ok := false; detail := coalesce(detail || '; ', '') || 'EXACT mismatch exp=' || left(exp_j::text, 100) || ' got=' || left(r::text, 100); end if;
            end if;
            if sp.exp_ids_sql is not null then
              execute replace(replace(replace(replace(replace(replace(sp.exp_ids_sql, '{b}', quote_literal(coalesce(tgt_branch::text, ''))), '{cat}', quote_literal(coalesce(tgt_cat::text, ''))), '{org}', quote_literal(v_org::text)),
                      '{acc}', quote_literal(accessible::text)), '{staff}', quote_literal(sid::text)), '{role}', quote_literal(a.role)) into exp_ids;
              select coalesce(array_agg(x order by x), '{}') into act_ids from jsonb_path_query(r, sp.act_ids::jsonpath) x2, lateral (select trim(both '"' from x2::text)) y(x);
              if sp.id = 'fn_admin_branch_media_info' then
                select coalesce(array_agg(distinct replace(lower(m), 'image/mk-', '') order by replace(lower(m), 'image/mk-', '')), '{}') into act_ids from (select trim(both '"' from x2::text) m from jsonb_path_query(r, sp.act_ids::jsonpath) x2) q;
              end if;
              if exp_ids is distinct from act_ids then ok := false; detail := coalesce(detail || '; ', '') || 'ID SET mismatch exp=' || coalesce(array_length(exp_ids, 1), 0) || ' got=' || coalesce(array_length(act_ids, 1), 0); end if;
              -- a data-bearing positive must not be vacuous: the oracle set is non-empty for the first own branch / own org except where the fixture has none
              if ok and coalesce(array_length(exp_ids, 1), 0) = 0 then detail := coalesce(detail || '; ', '') || 'ORACLE-EMPTY'; end if;
            end if;
          end if;
          insert into res values (sp.id, a.hotel || '/' || coalesce(a.branch, 'all') || '/' || a.role, st.name, t_label, exp_class, got_class, ok, detail);
        end loop;
      end loop;
    end loop;
    delete from staff_page_access where staff_id = sid;
    insert into staff_page_access select * from spa_orig where staff_id = sid;
    b_after := iso.snap();
    if iso.snap_diff(b_before, b_after) <> '{}'::jsonb then
      insert into res values ('SNAPSHOT', a.hotel || '/' || coalesce(a.branch, 'all') || '/' || a.role, '-', '-', 'no-write', 'WROTE', false, left(iso.snap_diff(b_before, b_after)::text, 300));
    else
      insert into res values ('SNAPSHOT', a.hotel || '/' || coalesce(a.branch, 'all') || '/' || a.role, '-', '-', 'no-write', 'no-write', true, null);
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------- 4. report + strict gate
select spec, count(*) calls, count(*) filter (where expect = 'allow' and got = 'allow' and ok) allow_ok, count(*) filter (where expect = 'deny' and got = 'deny' and ok) deny_ok,
       count(*) filter (where not ok) failures, count(*) filter (where detail like '%ORACLE-EMPTY%') oracle_empty
  from res group by 1 order by 1;
select spec, actor, state, target, expect, got, detail from res where not ok or detail is not null order by 1, 2, 3, 4 limit 120;
select count(*) total_calls, count(*) filter (where not ok) failures, count(*) filter (where expect = 'allow' and got = 'allow') allow_ok_calls,
       count(*) filter (where expect = 'deny' and got = 'deny') deny_ok_calls, count(*) filter (where target like 'foreign%') foreign_hotel_calls from res;
select (:strict = 1 and exists (select 1 from res where not ok)) as fail \gset
\if :fail
  select 1/0 as read_data_batch1_strict_failure;
\endif
rollback;
