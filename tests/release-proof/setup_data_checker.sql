-- =====================================================================
-- Release proof 7.7 (بيانات الإعداد للفرعين): READ-ONLY completeness checker.
-- Acceptance: a key box for each of the 23 units (today: none), the top 20 guest questions in the knowledge base
-- (today: empty), and the platform availability settings if platforms are used.
-- Run against any environment (production read-only session included): it writes nothing, creates nothing.
--   psql "$DATABASE_URL" -f tests/release-proof/setup_data_checker.sql
-- The output is one row per check: OK / MISSING / INFO with the live count. Fill instructions (no fabricated
-- operating data) are in acceptance/release-proof/fill-plan-7.7.md.
-- =====================================================================
\set ON_ERROR_STOP off
\pset footer off

-- 1) units and their key boxes (active rooms only; a unit without a key box is listed by name)
select 'units_total' as check_name, count(*)::text as live_count, 'INFO' as state
from rooms where is_active and archived_at is null;
select 'units_with_keybox' as check_name, count(distinct k.room_id)::text as live_count,
       case when count(distinct k.room_id) >= 23 then 'OK' else 'MISSING' end as state
from keyboxes k join rooms r on r.id = k.room_id
where r.is_active and r.archived_at is null;
select 'units_without_keybox' as check_name, r.room_number as live_count, 'MISSING' as state
from rooms r
where r.is_active and r.archived_at is null
  and not exists (select 1 from keyboxes k where k.room_id = r.id)
order by r.room_number;

-- 2) the guest knowledge base: public, active entries (the 20 top questions the reception answers)
select 'knowledge_public_active' as check_name, count(*)::text as live_count,
       case when count(*) >= 20 then 'OK' else 'MISSING' end as state
from knowledge_entries
where is_public and is_active;
select 'knowledge_public_active_by_branch' as check_name, b.name_ar || ': ' || count(k.id) as live_count,
       case when count(k.id) >= 20 then 'OK' else 'MISSING' end as state
from branches b left join knowledge_entries k
  on k.branch_id = b.id and k.is_public and k.is_active
group by b.id, b.name_ar
order by b.name_ar;

-- 3) platform availability settings, only where the branch uses booking platforms (decision 23: the public
--    availability function is staff-only; what matters is the platform link every new booking goes to)
select 'branch_booking_platform_url' as check_name,
       b.name_ar || ': ' || coalesce(nullif(b.booking_platform_url, ''), '(none)') as live_count,
       case when b.booking_platform_url is null or b.booking_platform_url = '' then 'MISSING' else 'OK' end as state
from branches b
order by b.name_ar;

-- summary: one row, the release answer
select case
         when (select count(distinct k.room_id) from keyboxes k join rooms r on r.id = k.room_id where r.is_active and r.archived_at is null) >= 23
          and (select count(*) from knowledge_entries where is_public and is_active) >= 20
         then 'OK: setup data complete'
         else 'MISSING: setup data incomplete — see the rows above and acceptance/release-proof/fill-plan-7.7.md'
       end as release_proof_7_7;
