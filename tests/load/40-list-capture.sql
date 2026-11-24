-- =====================================================================
-- fn_reservation_list equivalence capture (item 2.10 / migration 0106).
-- Runs the same call matrix under staff contexts of every role, twice by
-- the driver (scripts/load-roomai-equivalence.sh): once with the 0040
-- body, once with the 0106 body. The two outputs must be byte-identical.
-- Needs two fixture hotels: 90 and 91 (tests/load/10-fixture-hotel.sql).
-- =====================================================================
\set ON_ERROR_STOP on

-- extra roles for the matrix (test-only staff on hotel 90)
insert into auth.users(id, email, email_confirmed_at, created_at) values
  (md5('auth:90:finance')::uuid, 'load-fin-90@test.invalid', now(), now()),
  (md5('auth:90:hk')::uuid, 'load-hk-90@test.invalid', now(), now())
on conflict do nothing;
insert into staff_profiles(id, auth_user_id, organization_id, full_name, email, role) values
  (md5('staff:90:finance')::uuid, md5('auth:90:finance')::uuid, md5('org:90')::uuid, 'مالي اختبار 90', 'load-fin-90@test.invalid', 'finance'),
  (md5('staff:90:hk')::uuid, md5('auth:90:hk')::uuid, md5('org:90')::uuid, 'نظافة اختبار 90', 'load-hk-90@test.invalid', 'housekeeping')
on conflict do nothing;
insert into branch_memberships(staff_id, branch_id, organization_id) values
  (md5('staff:90:finance')::uuid, md5('branch:90:3')::uuid, md5('org:90')::uuid),
  (md5('staff:90:hk')::uuid, md5('branch:90:3')::uuid, md5('org:90')::uuid),
  (md5('staff:90:hk')::uuid, md5('branch:90:4')::uuid, md5('org:90')::uuid)
on conflict do nothing;

-- one call under one context: the jsonb result, or ERR:<sqlstate>
create or replace function load_capture_call(p_auth uuid, p_branch uuid, p_filters jsonb, p_limit int, p_offset int)
returns text language plpgsql as $cap$
declare r jsonb;
begin
  perform set_config('request.jwt.claim.sub', p_auth::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_auth)::text, true);
  r := fn_reservation_list(p_branch, p_filters, p_limit, p_offset);
  return r::text;
exception when others then
  return 'ERR:'||sqlstate;
end
$cap$;

-- the matrix: case | result (same order every run)
with cases(ord, name, auth, branch, filters, lim, off) as (
  values
  -- owner of hotel 90 on his branch 3: pages, filters, sorts
  ( 1, 'owner_default',        'auth:90:owner', 'branch:90:3', '{}'::jsonb, 50, 0),
  ( 2, 'owner_page2',          'auth:90:owner', 'branch:90:3', '{}'::jsonb, 50, 50),
  ( 3, 'owner_dates_sorted',   'auth:90:owner', 'branch:90:3', jsonb_build_object('check_in_from', (current_date-30)::text, 'check_in_to', (current_date+30)::text, 'sort', 'check_in_asc'), 50, 0),
  ( 4, 'owner_stay_today',     'auth:90:owner', 'branch:90:3', jsonb_build_object('stay_on', current_date::text), 50, 0),
  ( 5, 'owner_status_open',    'auth:90:owner', 'branch:90:3', jsonb_build_object('status', 'confirmed,checked_in', 'open_only', 'true'), 50, 0),
  ( 6, 'owner_q_phone',        'auth:90:owner', 'branch:90:3', jsonb_build_object('q', '0550'), 50, 0),
  ( 7, 'owner_has_balance',    'auth:90:owner', 'branch:90:3', jsonb_build_object('has_balance', 'true'), 50, 0),
  ( 8, 'owner_company',        'auth:90:owner', 'branch:90:3', jsonb_build_object('company', 'شركة'), 50, 0),
  ( 9, 'owner_sort_created',   'auth:90:owner', 'branch:90:3', jsonb_build_object('sort', 'created'), 10, 0),
  (10, 'owner_sort_ref',       'auth:90:owner', 'branch:90:3', jsonb_build_object('sort', 'ref'), 10, 0),
  (11, 'owner_platform',       'auth:90:owner', 'branch:90:3', jsonb_build_object('platform_collects', 'true'), 50, 0),
  (12, 'owner_group',          'auth:90:owner', 'branch:90:3', jsonb_build_object('group_ref', 'G90-3-1'), 50, 0),
  -- other roles, same branch: money visibility and row shape per role
  (13, 'manager_default',      'auth:90:manager', 'branch:90:3', '{}'::jsonb, 50, 0),
  (14, 'supervisor_default',   'auth:90:supervisor', 'branch:90:3', '{}'::jsonb, 50, 0),
  (15, 'finance_default',      'auth:90:finance', 'branch:90:3', '{}'::jsonb, 50, 0),
  (16, 'finance_has_balance',  'auth:90:finance', 'branch:90:3', jsonb_build_object('has_balance', 'true'), 50, 0),
  (17, 'housekeeping_default', 'auth:90:hk', 'branch:90:3', '{}'::jsonb, 50, 0),
  (18, 'housekeeping_dates',   'auth:90:hk', 'branch:90:3', jsonb_build_object('check_in_from', (current_date-7)::text, 'check_in_to', (current_date+7)::text), 50, 0),
  -- membership and cross-hotel isolation
  (19, 'hk_nonmember_branch5', 'auth:90:hk', 'branch:90:5', '{}'::jsonb, 50, 0),
  (20, 'hk_member_branch4',    'auth:90:hk', 'branch:90:4', '{}'::jsonb, 50, 0),
  (21, 'owner_cross_hotel',    'auth:90:owner', 'branch:91:5', '{}'::jsonb, 50, 0),
  (22, 'manager_cross_hotel',  'auth:90:manager', 'branch:91:5', '{}'::jsonb, 50, 0),
  (23, 'owner91_own_branch',   'auth:91:owner', 'branch:91:5', '{}'::jsonb, 50, 0)
)
select ord||'|'||name||'|'||load_capture_call(md5(auth)::uuid, md5(branch)::uuid, filters, lim, off)
from cases order by ord;
