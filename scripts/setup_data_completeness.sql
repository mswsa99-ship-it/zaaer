-- =====================================================================
-- Plan 7.7: setup-data completeness proof for the two working branches (استعلام قراءة يُثبت الاكتمال).
-- Read-only: temp table only, no writes to any real table. Runs as the owner role or in SQL Editor.
--   A  key boxes (صناديق المفاتيح): every working unit of every active branch has a key box
--      (the plan: boxes for the 23 units; none today — the FAIL rows say which unit lacks one).
--   B  knowledge base (قاعدة المعرفة): at least 20 active, public Q&A entries answer guests of each
--      branch (its own entries plus the organization-wide ones); empty today.
--   C  availability settings (إعدادات الإتاحة), only when platforms are used (إن استُعملت المنصات):
--      a platform is an active booking source with a booking URL; when one exists, every active public
--      category of the branch must have availability settings — a release rule, or inventory periods
--      covering each of the next 30 days (the two sources fn_get_public_availability reads).
-- Exit: prints PASS/FAIL rows, then raises SETUP DATA INCOMPLETE when any row fails, so psql exits
-- non-zero and the query can gate a release. Names carry no test code: the SQ prefix («إثبات اكتمال
-- بيانات الإعداد») is proposed for tests/acceptance-library.json at integration.
-- =====================================================================
\set ON_ERROR_STOP off
create temp table sd_results(check_name text, branch text, ok boolean, detail text);

-- A: key boxes
insert into sd_results
select 'صناديق المفاتيح لكل وحدة عاملة', b.name_ar,
       count(rm.id) > 0 and count(rm.id) filter (where kb.id is null) = 0,
       'units=' || count(rm.id) || ', without_box=' || coalesce(nullif(string_agg(rm.room_number, ', ') filter (where kb.id is null), ''), 'none')
  from branches b
  left join rooms rm on rm.branch_id = b.id and rm.is_active and rm.archived_at is null
  left join keyboxes kb on kb.room_id = rm.id
 where b.is_active and b.archived_at is null
 group by b.id, b.name_ar;

-- B: twenty guest questions in the knowledge base
insert into sd_results
select 'عشرون سؤالًا للنزيل في قاعدة المعرفة', b.name_ar,
       count(ke.id) >= 20,
       'public_active_entries=' || count(ke.id)
  from branches b
  left join knowledge_entries ke on ke.organization_id = b.organization_id
     and (ke.branch_id is null or ke.branch_id = b.id)
     and ke.is_active and ke.archived_at is null and ke.is_public
 where b.is_active and b.archived_at is null
 group by b.id, b.name_ar;

-- C: availability settings when platforms are used
with platforms as (
  select bs.organization_id, true as used
    from booking_sources bs
   where bs.is_active and nullif(btrim(coalesce(bs.booking_url, '')), '') is not null
   group by bs.organization_id
), coverage as (
  select rc.branch_id, rc.id as category_id, rc.name_ar,
         (rr.id is not null) as has_rule,
         (select count(*) from generate_series(0, 29) g
           where exists (select 1 from inventory_periods ip
                          where ip.branch_id = rc.branch_id and ip.category_id = rc.id
                            and ip.date = fn_branch_today(rc.branch_id) + g and ip.total_units > 0)) as days_covered
    from room_categories rc
    left join release_rules rr on rr.branch_id = rc.branch_id and rr.category_id = rc.id
   where rc.is_active and rc.archived_at is null and rc.is_public
)
insert into sd_results
select 'إعدادات الإتاحة حيث تُستعمل المنصات', b.name_ar,
       case when p.used is null then true
            else count(c.category_id) > 0 and count(c.category_id) filter (where not (c.has_rule or c.days_covered = 30)) = 0 end,
       case when p.used is null then 'no platform in use'
            else 'public_categories=' || count(c.category_id) || ', without_settings='
                 || coalesce(nullif(string_agg(c.name_ar || ' (rule:' || c.has_rule || ', days:' || c.days_covered || ')', ', ')
                                    filter (where not (c.has_rule or c.days_covered = 30)), ''), 'none') end
  from branches b
  left join platforms p on p.organization_id = b.organization_id
  left join coverage c on c.branch_id = b.id
 where b.is_active and b.archived_at is null
 group by b.id, b.name_ar, p.used;

select case when ok then 'PASS' else 'FAIL' end as result, check_name, branch, detail from sd_results order by check_name, branch;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from sd_results;

\set ON_ERROR_STOP on
do $$ begin
  if (select count(*) from sd_results) = 0 then raise exception 'SETUP DATA CHECK RAN NOTHING: no active branch found'; end if;
  if exists (select 1 from sd_results where not ok) then raise exception 'SETUP DATA INCOMPLETE: see the FAIL rows above'; end if;
end $$;
