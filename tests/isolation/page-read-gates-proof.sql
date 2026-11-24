-- Individual-mode page-gate probe (local disposable DB, rolled back). :strict=1 raises on any mismatch (green run), 0 only counts (red run on the unfixed source).
-- Surfaces: direct SELECT on finance_control_settings, system_settings (page /admin/finance-controls), alert_rules (page /admin/journey), and rpc fn_finance_controls_get (page /admin/finance-controls, view).
\set ON_ERROR_STOP on
begin;
create temp table r(surface text, role text, state text, expect_allow boolean, got_allow boolean, detail text);
grant all on r to public;
do $$
declare a record; st record; s record; sid uuid; org uuid; n int; ok boolean; msg text; foreign_rows int;
begin
 for a in select * from iso.actor where role not in ('guest') and ((hotel='hotel-a' and (branch='branch-1' or role='owner')) or (hotel='hotel-b' and role='manager' and branch='branch-1')) order by hotel, role loop
  select p.id, p.organization_id into sid, org from staff_profiles p where p.auth_user_id=a.auth_user;
  for st in select * from (values
     ('legacy-no-row', null::jsonb, 'any'), ('indiv-empty', '{}'::jsonb, 'any'),
     ('indiv-view-matching', '{"/admin/finance-controls":{"view":true},"/admin/journey":{"view":true}}'::jsonb, 'match'),
     ('indiv-view-other-page-only', '{"/admin/ai-settings":{"view":true},"/admin/staff":{"view":true}}'::jsonb, 'none'),
     ('indiv-edit-without-view', '{"/admin/finance-controls":{"edit":true},"/admin/journey":{"edit":true}}'::jsonb, 'none'),
     ('indiv-view+edit-matching', '{"/admin/finance-controls":{"view":true,"edit":true},"/admin/journey":{"view":true,"edit":true}}'::jsonb, 'match')) v(name,pg,kind) loop
    delete from staff_page_access where staff_id=sid;
    if st.pg is not null then insert into staff_page_access(staff_id, organization_id, enabled, page_grants) values (sid, org, true, st.pg); end if;
    perform iso.set_claims(a.auth_user); set local role authenticated;
    for s in select * from (values ('direct finance_control_settings','finance_control_settings'),('direct system_settings','system_settings'),('direct alert_rules','alert_rules'),('rpc fn_finance_controls_get','rpc'),('rpc fn_admin_alert_rules','journey-rpc')) x(surface,tbl) loop
      msg := null;
      if s.tbl in ('rpc','journey-rpc') then
        begin if s.tbl='rpc' then perform fn_finance_controls_get(); else perform fn_admin_alert_rules(); end if; ok := true; exception when others then ok := false; msg := sqlerrm; end;
      else
        execute format('select count(*) from %I', s.tbl) into n; ok := n > 0; msg := n::text || ' rows';
        execute format('select count(*) from %I where organization_id <> %L', s.tbl, org) into foreign_rows;
        if foreign_rows <> 0 then raise exception 'FOREIGN ORG ROWS visible in % for % %', s.tbl, a.role, a.hotel; end if;
      end if;
      insert into r values (s.surface, a.hotel||'/'||a.role, st.name,
        case when s.tbl='journey-rpc' and st.pg is null then a.role in ('owner','manager') when a.role='owner' then true when st.kind='any' and st.pg is null then true when st.kind='match' then true else false end, ok, msg);
    end loop;
    reset role;
   end loop;
  end loop;
end $$;
select count(*) mismatches from r where expect_allow is distinct from got_allow;
select surface, state, string_agg(role||':'||case when got_allow then 'allow' else 'deny' end, ' ' order by role) from r where expect_allow is distinct from got_allow group by 1,2 order by 1,2;
select count(*) filter (where role like 'hotel-b%') foreign_hotel_probes, count(*) total from r;
select (:strict = 1 and exists (select 1 from r where expect_allow is distinct from got_allow)) as fail \gset
\if :fail
  select 1/0 as page_gate_mismatches_strict_failure;
\endif
rollback;
