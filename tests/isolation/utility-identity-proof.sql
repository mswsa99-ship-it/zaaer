-- Disposable DB only: production migrations, engine.sql, fixtures.sql (NO rpc-fixtures or broad preload).
-- Fixture additions rolled back. Helpers are not endpoint authorization substitutes.
\set ON_ERROR_STOP on
begin;
create temp table identity_result(id text primary key);
grant all on identity_result to authenticated;
create function pg_temp.identity_check(k text,ok boolean) returns void language plpgsql as $$begin if ok is distinct from true then raise exception 'IDENTITY_MISMATCH: %',k;end if;insert into identity_result values(k);end$$;
create function pg_temp.identity_denied(k text,q text) returns void language plpgsql as $$declare e text;begin begin execute q;exception when others then e:=sqlstate;end;if e is distinct from '42501' then raise exception 'IDENTITY_DENIAL_MISMATCH: % state=%',k,e;end if;insert into identity_result values(k);end$$;
-- Deterministic capabilities: local fixture only, preserve matrix/page logic unchanged.
insert into role_permissions(organization_id,role,capability,allowed)
select id,'manager','reports.finance',true from organizations where id in(iso.id('org-a'),iso.id('org-b'))
on conflict(organization_id,role,capability) do update set allowed=true;
create temp table identity_before as select iso.snap() s;
do $$declare a record;p staff_profiles%rowtype;bs uuid[];expected uuid[];prefix text;begin
 for a in select * from iso.actor where role<>'guest' order by key loop
  select * into strict p from staff_profiles where auth_user_id=a.auth_user;
  select array_agg(b.id order by b.id) into expected from branches b where b.organization_id=p.organization_id and
    (a.role='owner' or exists(select 1 from branch_memberships m where m.staff_id=p.id and m.branch_id=b.id and m.removed_at is null));
  perform iso.set_claims(null);perform set_config('request.headers','{}',true);perform iso.set_claims(a.auth_user);
  prefix:=a.key;
  set local role authenticated;
  perform pg_temp.identity_check(prefix||'/staff',fn_staff_id()=p.id);
  perform pg_temp.identity_check(prefix||'/role',fn_current_role()::text=a.role);
  perform pg_temp.identity_check(prefix||'/org',fn_user_org_id()=p.organization_id);
  select array_agg(x order by x) into bs from fn_user_branch_ids() x;
  perform pg_temp.identity_check(prefix||'/branches',bs is not distinct from expected);
  perform pg_temp.identity_check(prefix||'/isstaff',fn_is_staff());
  perform pg_temp.identity_check(prefix||'/hasrole',fn_has_role(variadic array[a.role::role_code]));
  perform pg_temp.identity_check(prefix||'/wrongrole',not fn_has_role('guest'::role_code));
  perform fn_require_role(variadic array[a.role::role_code]);
  perform pg_temp.identity_denied(prefix||'/wrongrole-deny',$q$select fn_require_role('guest'::role_code)$q$);
  perform pg_temp.identity_check(prefix||'/unknown-cap',not fn_can('utility.nonexistent'));
  perform pg_temp.identity_check(prefix||'/bad-write-action',not fn_can_write('reports.finance','view'));
  perform pg_temp.identity_check(prefix||'/invalid-page',not fn_user_page_can('/unknown','view'));
  perform pg_temp.identity_check(prefix||'/invalid-action',not fn_user_page_can('/staff/rooms','execute'));
  perform pg_temp.identity_denied(prefix||'/foreign-branch',format('select fn_require_branch(%L::uuid)',case when a.hotel='hotel-a' then iso.id('branch-b-1') else iso.id('branch-a-1') end));
  perform fn_require_branch(expected[1]);
  if a.role<>'owner' then
    perform pg_temp.identity_denied(prefix||'/same-org-other-branch',format('select fn_require_branch(%L::uuid)',
      case a.hotel when 'hotel-a' then case a.branch when 'branch-1' then iso.id('branch-a-2') else iso.id('branch-a-1') end
      else case a.branch when 'branch-1' then iso.id('branch-b-2') else iso.id('branch-b-1') end end));
  end if;
  reset role;
 end loop;
 if iso.snap() is distinct from (select s from identity_before) then raise exception 'IDENTITY_READS_WROTE';end if;
end$$;
-- Individual mode: empty grants deny; own matching row permits only exact requested actions. Foreign actors are repeated symmetrically.
do $$declare a record;p staff_profiles%rowtype;b jsonb;prefix text;begin
 for a in select * from iso.actor where role='manager' and branch='branch-1' order by key loop
  select * into strict p from staff_profiles where auth_user_id=a.auth_user;
  delete from staff_page_access where staff_id=p.id;
  insert into staff_page_access(staff_id,organization_id,enabled,page_grants) values(p.id,p.organization_id,true,'{}');
  perform iso.set_claims(null);perform set_config('request.headers','{}',true);perform iso.set_claims(a.auth_user);b:=iso.snap();prefix:=a.key;
  set local role authenticated;
  perform pg_temp.identity_check(prefix||'/individual',fn_user_access_mode()='individual');
  perform pg_temp.identity_check(prefix||'/empty-page',not fn_user_page_can('/admin/reports','view'));
  perform pg_temp.identity_check(prefix||'/read-gate-denied',not fn_page_read_gate(array['/admin/reports']));
  perform pg_temp.identity_check(prefix||'/read-grant-denied',not fn_page_read_grant(array['/admin/reports']));
  perform pg_temp.identity_check(prefix||'/write-gate-denied',not fn_page_write_gate(array['/admin/reports'],'edit'));
  perform pg_temp.identity_check(prefix||'/cap-empty',not fn_can('reports.finance'));
  perform pg_temp.identity_check(prefix||'/full-empty',not fn_cap_full('reports.finance'));
  perform pg_temp.identity_check(prefix||'/money-empty',not fn_sees_money());
  perform pg_temp.identity_denied(prefix||'/require-page-denied',$q$select fn_require_user_page('/admin/reports','view')$q$);
  perform pg_temp.identity_denied(prefix||'/require-cap-denied',$q$select fn_require_cap('reports.finance')$q$);
  perform pg_temp.identity_denied(prefix||'/require-full-denied',$q$select fn_require_cap_full('reports.finance')$q$);
  perform pg_temp.identity_denied(prefix||'/require-any-denied',$q$select fn_require_any_cap(array['reports.finance'])$q$);
  perform pg_temp.identity_denied(prefix||'/require-money-denied',$q$select fn_require_money()$q$);
  reset role;if iso.snap()<>b then raise exception 'DENIED_HELPER_WRITES';end if;
  update staff_page_access set page_grants='{"/admin/reports":{"view":true,"edit":false}}' where staff_id=p.id;
  b:=iso.snap();set local role authenticated;
  perform pg_temp.identity_check(prefix||'/page-positive',fn_user_page_can('/admin/reports','view'));
  perform pg_temp.identity_check(prefix||'/read-positive',fn_page_read_gate(array['/admin/reports']) and fn_page_read_grant(array['/admin/reports']));
  perform pg_temp.identity_check(prefix||'/exact-edit-denied',not fn_page_write_gate(array['/admin/reports'],'edit'));
  perform pg_temp.identity_check(prefix||'/cap-positive',fn_can('reports.finance'));
  perform pg_temp.identity_check(prefix||'/full-positive',fn_cap_full('reports.finance'));
  perform pg_temp.identity_check(prefix||'/money-positive',fn_sees_money());
  perform fn_require_user_page('/admin/reports','view');perform fn_require_cap('reports.finance');perform fn_require_cap_full('reports.finance');perform fn_require_any_cap(array['reports.finance']);perform fn_require_money();
  reset role;if iso.snap()<>b then raise exception 'ALLOWED_HELPER_WRITES';end if;
  -- any_write capability: view alone cannot grant editing; exact edit plus view can.
  update staff_page_access set page_grants='{"/admin/knowledge":{"view":true,"edit":true}}' where staff_id=p.id;
  b:=iso.snap();set local role authenticated;
  perform pg_temp.identity_check(prefix||'/can-write-positive',fn_can_write('knowledge','edit'));
  perform pg_temp.identity_check(prefix||'/can-write-delete-denied',not fn_can_write('knowledge','delete'));
  reset role;if iso.snap()<>b then raise exception 'WRITE_HELPER_WROTE';end if;
 end loop;
end$$;
-- No actor must not resolve a staff identity or self-grant a page/capability.
do $$declare b jsonb;begin
 perform iso.set_claims(null);perform set_config('request.headers','{}',true);b:=iso.snap();set local role authenticated;
 perform pg_temp.identity_check('no-actor/staff',fn_staff_id() is null);
 perform pg_temp.identity_check('no-actor/role',fn_current_role() is null);
 perform pg_temp.identity_check('no-actor/org',fn_user_org_id() is null);
 perform pg_temp.identity_check('no-actor/branches',not exists(select 1 from fn_user_branch_ids()));
 perform pg_temp.identity_check('no-actor/isstaff',not fn_is_staff());
 perform pg_temp.identity_check('no-actor/mode',fn_user_access_mode()='none');
 perform pg_temp.identity_check('no-actor/cap',not fn_can('reports.finance'));
 perform pg_temp.identity_check('no-actor/page',not fn_user_page_can('/staff/rooms','view'));
 perform pg_temp.identity_denied('no-actor/page-require',$q$select fn_require_user_page('/staff/rooms','view')$q$);
 reset role;if iso.snap()<>b then raise exception 'NO_ACTOR_WROTE';end if;
end$$;
-- Guest organisation resolver is a selector, not proof of guest access: exact public slug identity and invalid contrast.
do $$declare b jsonb;h text;org uuid;begin
 perform iso.set_claims(null);b:=iso.snap();
 for h,org in select 'iso-gate-a',iso.id('org-a') union all select 'iso-gate-b',iso.id('org-b') loop
  perform set_config('request.headers',jsonb_build_object('x-hotel-slug',h)::text,true);
  set local role anon;
  if fn_guest_org_id() is distinct from org then raise exception 'GUEST_ORG_SELECTOR_IDENTITY';end if;
  reset role;
 end loop;
 perform set_config('request.headers','{"x-hotel-slug":"missing-utility-hotel"}',true);set local role anon;
 if fn_guest_org_id() is not null then raise exception 'GUEST_ORG_INVALID';end if;reset role;
 perform set_config('request.headers','not json',true);set local role anon;
 if fn_guest_org_id() is not null then raise exception 'GUEST_ORG_MALFORMED';end if;reset role;
 if iso.snap()<>b then raise exception 'GUEST_ORG_WROTE';end if;
end$$;
select count(*) identity_assertions from identity_result;
rollback;
