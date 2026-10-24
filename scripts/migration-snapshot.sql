-- Snapshot of what a migration must not lose or change (decision 41, X10). Run with: -v phase=before|after|restored
-- Rows of every table, money by kind and status, reservation states and references, allocations.
select set_config('mig.phase', :'phase', false);
create table if not exists _mig_snapshot(phase text, k text, v text, primary key (phase, k));
do $$ declare t record; n bigint; begin
  for t in select c.relname from pg_class c join pg_namespace s on s.oid = c.relnamespace
            where s.nspname = 'public' and c.relkind = 'r' and c.relname not in ('_mig_snapshot', '_hist_ids') order by 1 loop
    execute format('select count(*) from public.%I', t.relname) into n;
    insert into _mig_snapshot values (current_setting('mig.phase'), 'rows:' || t.relname, n::text)
      on conflict (phase, k) do update set v = excluded.v;
  end loop;
end $$;
insert into _mig_snapshot
select current_setting('mig.phase'), k, v from (
  select 'money:voucher:' || kind || ':' || status as k, sum(amount_halalas)::text as v from financial_vouchers group by kind, status
  union all select 'money:charge:' || kind, sum(total_halalas)::text from reservation_charges group by kind
  union all select 'money:invoice:' || status, sum(total_halalas)::text from invoices group by status
  union all select 'money:reservations_paid', coalesce(sum(paid_halalas), 0)::text from reservations
  union all select 'reservations:status:' || status, count(*)::text from reservations group by status
  union all select 'reservations:refs', md5(coalesce(string_agg(internal_ref || ':' || coalesce(external_ref, ''), ',' order by internal_ref), '')) from reservations
  union all select 'allocations:status:' || status, count(*)::text from reservation_allocations group by status
  union all select 'vouchers:numbers', md5(coalesce(string_agg(number, ',' order by number), '')) from financial_vouchers
) s
on conflict (phase, k) do update set v = excluded.v;
