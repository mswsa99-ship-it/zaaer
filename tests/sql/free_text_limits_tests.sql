-- =====================================================================
-- Plan 5.7 (finding S8, migration 0083): every free text has a server limit — the plan's acceptance is that a
-- text of 10,093 characters is refused, here on notes, reasons and names, through column constraints that hold
-- for every write path. Uncodified descriptive names (worker patch; no prefix registered yet).
-- Runs on the suite's database; writes are attempted as the superuser to prove the constraint itself.
-- =====================================================================
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create or replace function t_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;
-- tries the write, expecting the named free-text constraint to refuse it
create or replace function t_refused(p_sql text, p_constraint text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'accepted';
exception when check_violation then
  if sqlerrm like '%' || p_constraint || '%' then return 'refused'; end if;
  return 'other: ' || sqlerrm;
when others then return 'other: ' || sqlerrm;
end $$;

insert into conversations(organization_id,branch_id,channel,status) values ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010','screen','active');
insert into conversation_messages(conversation_id,sender,content) select id,'guest','synthetic boundary fixture' from conversations order by created_at desc limit 1;

do $$ declare r text; begin
  r := t_refused('update reservations set notes = repeat(''ن'', 10093) where id = (select id from reservations limit 1)', 'ft_reservations_notes_len');
  perform t_record('a note of 10,093 characters is refused', r = 'refused', r);
  r := t_refused('update reservations set cancel_reason = repeat(''x'', 10093) where id = (select id from reservations limit 1)', 'ft_reservations_cancel_reason_len');
  perform t_record('a reason of 10,093 characters is refused', r = 'refused', r);
  r := t_refused('update staff_profiles set full_name = repeat(''س'', 10093) where id = (select id from staff_profiles limit 1)', 'ft_staff_profiles_full_name_len');
  perform t_record('a staff name of 10,093 characters is refused', r = 'refused', r);
  r := t_refused('update reservation_guests set full_name = repeat(''س'', 101) where id = (select id from reservation_guests limit 1)', 'ft_reservation_guests_full_name_len');
  perform t_record('a guest name over 100 characters is refused', r = 'refused', r);
  r := t_refused('update financial_vouchers set reason = repeat(''x'', 1001) where id = (select id from financial_vouchers limit 1)', 'ft_financial_vouchers_reason_len');
  perform t_record('a voucher reason over 1,000 characters is refused', r = 'refused', r);
  r := t_refused('update conversation_messages set content = repeat(''x'', 2001) where id = (select id from conversation_messages limit 1)', 'ft_conversation_messages_content_len');
  perform t_record('a chat message over 2,000 characters is refused', r = 'refused', r);
  r := t_refused('update branches set name_ar = repeat(''س'', 101) where id = (select id from branches limit 1)', 'ft_branches_name_ar_len');
  perform t_record('a branch name over 100 characters is refused', r = 'refused', r);
end $$;

-- ordinary Arabic text still saves, at the lengths the product actually uses
do $$ declare msg text := 'saved'; begin
  begin
    update reservations set notes = 'طلب سرير إضافي ووجبة سحور. ' || repeat('ملاحظة تجريبية. ', 8) where id = (select id from reservations limit 1);
  exception when others then msg := sqlerrm; end;
  perform t_record('an ordinary Arabic note still saves', msg = 'saved', msg);
exception when others then perform t_record('an ordinary Arabic note still saves', false, sqlerrm); end $$;

-- the coverage itself: every capped column of 0083 is in place
do $$ declare n int; begin
  select count(*) into n from pg_constraint where conname like 'ft\_%\_len' and connamespace = 'public'::regnamespace;
  perform t_record('the free-text limits cover the notes, reasons, names, titles, descriptions and bodies', n >= 110, n || ' constraints');
exception when others then perform t_record('the free-text limits cover the notes, reasons, names, titles, descriptions and bodies', false, sqlerrm); end $$;

select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),110) as detail from test_results order by ok, name;
