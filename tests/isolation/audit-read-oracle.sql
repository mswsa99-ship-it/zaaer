-- Audit READ oracle for the non-owner actors (fn_audit_list). Local disposable DB only, using already qualified minimal fixtures. Never preload all rpc-fixtures.sql for this proof.
-- Execute inside BEGIN/ROLLBACK: setup toggles synthetic staff and ends their local synthetic sessions before restoration.
-- Scope: READ of fn_audit_list only. Audit create/update/delete stay the documented immutable N/A (owner-denial tests), never PASS here.
-- This file is evidence for the non-owner read oracle; it is NOT an acceptance verdict, and it does not decide the NULL-branch policy:
--   branch_id IS NULL rows are org-level by source (fn_audit_list: "e.branch_id is null or in own branches"); they are asserted as the SOURCE-INTENDED org-level positive,
--   flagged policy_pending, never as proof that cross-branch visibility of such rows is intended by the owner.
-- Every check raises on failure. The only caught errors are the expected capability/branch denials, whose exact message is asserted; any other error propagates.
create schema if not exists iso;
drop table if exists iso.audit_seed, iso.audit_oracle_result;
create table iso.audit_seed(class text not null, id uuid not null, org uuid not null, branch uuid, primary key (class, id));
create table iso.audit_oracle_result(actor text, hotel text, branch text, check_name text, detail text);

-- 1) seed the security class through the production path (owner toggles that branch's housekeeping actor off and on again: two staff.* events, branch_id NULL by source)
do $$ declare t record; own uuid; hk uuid; r jsonb; begin
  for t in select * from iso.target order by key loop
    select a.auth_user into own from iso.actor a where a.role = 'owner' and a.hotel = t.hotel;
    select s.id into hk from staff_profiles s join iso.actor a on a.auth_user = s.auth_user_id where a.role = 'housekeeping' and a.hotel = t.hotel and a.branch = split_part(t.key, '|', 2);
    if own is null or hk is null then raise exception 'AUDIT ORACLE SEED: owner/housekeeping actor missing for %', t.key; end if;
    perform iso.set_claims(own); set local role authenticated;
    r := fn_admin_set_staff_active(hk, false, 'iso-audit-oracle'); r := fn_admin_set_staff_active(hk, true, 'iso-audit-oracle');
    reset role;
    if (select is_active from staff_profiles where id = hk) is not true then raise exception 'AUDIT ORACLE SEED: actor % not restored active', t.key; end if;
  end loop;
end $$;

-- 2) classify EVERY existing event independently from the table (before any function call)
insert into iso.audit_seed(class, id, org, branch)
select case when e.category = 'security' then 'security' when e.branch_id is null then 'org_null_business' else 'branch_business' end, e.id, e.organization_id, e.branch_id from audit_events e;

do $$ declare t record; n int; begin
  -- named seeded classes must be non-empty, so zero rows can never look harmless
  for t in select * from iso.target loop
    select count(*) into n from iso.audit_seed where class = 'branch_business' and branch = t.branch_id; if n < 1 then raise exception 'AUDIT ORACLE: no seeded branch events for %', t.key; end if;
    select count(*) into n from iso.audit_seed where class = 'org_null_business' and org = t.org; if n < 1 then raise exception 'AUDIT ORACLE: no org-level (NULL branch) events for %', t.key; end if;
    select count(*) into n from iso.audit_seed where class = 'security' and org = t.org; if n < 4 then raise exception 'AUDIT ORACLE: security seed incomplete for % (%)', t.key, n; end if;
  end loop;
  -- named NULL-branch fixture actions that must be among the org-level positives (policy_pending)
  if not exists (select 1 from audit_events e join iso.audit_seed s on s.id = e.id and s.class = 'org_null_business' where e.action in ('organization.updated','expense_category.created','product.created')) then
    raise exception 'AUDIT ORACLE: expected named org-level fixture actions missing';
  end if;
end $$;

-- 3) owner positive control: sees its whole org incl. security, nothing of the other org
do $$ declare t record; own uuid; r jsonb; got uuid[]; want uuid[]; begin
  for t in select distinct on (hotel) * from iso.target order by hotel, key loop
    select a.auth_user into own from iso.actor a where a.role = 'owner' and a.hotel = t.hotel;
    perform iso.set_claims(own); set local role authenticated; r := fn_audit_list(jsonb_build_object('limit', 500)); reset role;
    select coalesce(array_agg((x->>'id')::uuid order by (x->>'id')::uuid), '{}') into got from jsonb_array_elements(r->'rows') x;
    select coalesce(array_agg(id order by id), '{}') into want from iso.audit_seed where org = t.org;
    if got is distinct from want or (r->>'total')::int <> cardinality(want) then raise exception 'AUDIT ORACLE owner control % : got % want % total %', t.hotel, cardinality(got), cardinality(want), r->>'total'; end if;
    insert into iso.audit_oracle_result values ('owner', t.hotel, null, 'owner_sees_full_org_set', cardinality(want)::text);
  end loop;
end $$;

-- 4) every non-owner actor
do $$ declare a record; t record; r jsonb; got uuid[]; want uuid[]; pg uuid[]; k int; msg text; st text; fb uuid; begin
  for a in select * from iso.actor where role not in ('owner', 'guest') order by role, hotel, branch loop
    select * into t from iso.target where hotel = a.hotel and key = a.hotel || '|' || a.branch;
    perform iso.set_claims(a.auth_user);
    if a.role in ('finance', 'housekeeping') then
      -- fail closed: exact capability denial, any other outcome (success or other error) is a failure
      msg := null; st := null;
      begin
        set local role authenticated; r := fn_audit_list(jsonb_build_object('limit', 500)); reset role;
      exception when others then get stacked diagnostics msg = message_text; st := sqlstate; reset role;
      end;
      if r is not null and msg is null then raise exception 'AUDIT ORACLE: % % % read SUCCEEDED, expected capability denial', a.role, a.hotel, a.branch; end if;
      if msg is distinct from 'FORBIDDEN: audit.log' then raise exception 'AUDIT ORACLE: % % % wrong error [% %]', a.role, a.hotel, a.branch, st, msg; end if;
      insert into iso.audit_oracle_result values (a.role, a.hotel, a.branch, 'capability_denied_exact', st || ' ' || msg);
    else
      -- expected set from the independent classification: own-org, (own branch or NULL branch), never security, never other org/branch
      select coalesce(array_agg(id order by id), '{}') into want from iso.audit_seed
        where org = t.org and class <> 'security' and (branch is null or branch = t.branch_id);
      set local role authenticated; r := fn_audit_list(jsonb_build_object('limit', 500)); reset role;
      select coalesce(array_agg((x->>'id')::uuid order by (x->>'id')::uuid), '{}') into got from jsonb_array_elements(r->'rows') x;
      if got is distinct from want then raise exception 'AUDIT ORACLE: % % % exact set differs got % want %', a.role, a.hotel, a.branch, cardinality(got), cardinality(want); end if;
      if (r->>'total')::int <> cardinality(want) then raise exception 'AUDIT ORACLE: % % % total % <> %', a.role, a.hotel, a.branch, r->>'total', cardinality(want); end if;
      -- named negatives: a foreign-branch id of the same org, a cross-org id, and every security id must be absent
      select id into fb from iso.audit_seed where org = t.org and class = 'branch_business' and branch <> t.branch_id order by id limit 1;
      if fb is null then raise exception 'AUDIT ORACLE: no same-org other-branch seed for %', a.hotel; end if;
      if fb = any(got) then raise exception 'AUDIT ORACLE: % % % sees other-branch event %', a.role, a.hotel, a.branch, fb; end if;
      if exists (select 1 from iso.audit_seed s where s.org <> t.org and s.id = any(got)) then raise exception 'AUDIT ORACLE: % % % sees cross-org events', a.role, a.hotel, a.branch; end if;
      if exists (select 1 from iso.audit_seed s where s.class = 'security' and s.id = any(got)) then raise exception 'AUDIT ORACLE: % % % sees security events', a.role, a.hotel, a.branch; end if;
      -- named positives: own-branch events and the source-intended org-level (NULL branch, policy_pending) events
      if not exists (select 1 from iso.audit_seed s where s.class = 'branch_business' and s.branch = t.branch_id and s.id = any(got)) then raise exception 'AUDIT ORACLE: % % % missing own-branch positives', a.role, a.hotel, a.branch; end if;
      if not exists (select 1 from iso.audit_seed s where s.class = 'org_null_business' and s.org = t.org and s.id = any(got)) then raise exception 'AUDIT ORACLE: % % % missing org-level positives', a.role, a.hotel, a.branch; end if;
      -- pagination: pages of 7 reassemble the exact set with no duplicate and no gap
      pg := '{}'; k := 0;
      loop
        set local role authenticated; r := fn_audit_list(jsonb_build_object('limit', 7, 'offset', k)); reset role;
        exit when jsonb_array_length(r->'rows') = 0;
        pg := pg || coalesce((select array_agg((x->>'id')::uuid) from jsonb_array_elements(r->'rows') x), '{}');
        k := k + 7; if k > 1000 then raise exception 'AUDIT ORACLE: pagination did not terminate'; end if;
      end loop;
      if cardinality(pg) <> cardinality(want) or (select array_agg(x order by x) from unnest(pg) x) is distinct from want then raise exception 'AUDIT ORACLE: % % % pagination mismatch (% vs %)', a.role, a.hotel, a.branch, cardinality(pg), cardinality(want); end if;
      -- branch filter: own branch narrows to own branch only; a foreign branch of the same org is an exact denial, not an empty list
      set local role authenticated; r := fn_audit_list(jsonb_build_object('limit', 500, 'branch_id', t.branch_id)); reset role;
      if (r->>'total')::int <> (select count(*) from iso.audit_seed where class = 'branch_business' and branch = t.branch_id) then raise exception 'AUDIT ORACLE: % % % own-branch filter total %', a.role, a.hotel, a.branch, r->>'total'; end if;
      select b.id into fb from branches b where b.organization_id = t.org and b.id <> t.branch_id order by b.id limit 1;
      msg := null; r := null;
      begin
        set local role authenticated; r := fn_audit_list(jsonb_build_object('limit', 500, 'branch_id', fb)); reset role;
      exception when others then get stacked diagnostics msg = message_text; st := sqlstate; reset role;
      end;
      if r is not null then raise exception 'AUDIT ORACLE: % % % foreign branch filter SUCCEEDED', a.role, a.hotel, a.branch; end if;
      if msg is null or msg !~ '^FORBIDDEN' then raise exception 'AUDIT ORACLE: % % % foreign branch filter wrong error [%]', a.role, a.hotel, a.branch, msg; end if;
      insert into iso.audit_oracle_result values (a.role, a.hotel, a.branch, 'exact_set_negatives_positives_pagination_branchfilter', cardinality(want)::text || ' rows; foreign filter: ' || msg);
    end if;
  end loop;
end $$;
select actor, count(*) checks from iso.audit_oracle_result group by 1 order by 1;
