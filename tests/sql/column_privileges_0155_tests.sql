-- 0155: bank_iban and staff email are not directly readable by signed-in members or anon; every other column still is; the definer paths still work. Synthetic, rolled back.
begin;
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
insert into test_results
select 'CP01 authenticated cannot read branches.bank_iban', not has_column_privilege('authenticated','public.branches','bank_iban','SELECT'), null
union all select 'CP02 anon cannot read branches.bank_iban', not has_column_privilege('anon','public.branches','bank_iban','SELECT'), null
union all select 'CP03 authenticated cannot read staff_profiles.email', not has_column_privilege('authenticated','public.staff_profiles','email','SELECT'), null
union all select 'CP04 anon cannot read staff_profiles.email', not has_column_privilege('anon','public.staff_profiles','email','SELECT'), null
union all select 'CP05 authenticated still reads every other branches column',
  (select coalesce(bool_and(has_column_privilege('authenticated','public.branches',column_name,'SELECT')),false) from information_schema.columns where table_schema='public' and table_name='branches' and column_name <> 'bank_iban'), null
union all select 'CP06 authenticated still reads every other staff_profiles column (phone unchanged)',
  (select coalesce(bool_and(has_column_privilege('authenticated','public.staff_profiles',column_name,'SELECT')),false) from information_schema.columns where table_schema='public' and table_name='staff_profiles' and column_name <> 'email'), null
union all select 'CP07 anon has no staff_profiles column at all',
  (select not coalesce(bool_or(has_column_privilege('anon','public.staff_profiles',column_name,'SELECT')),false) from information_schema.columns where table_schema='public' and table_name='staff_profiles'), null
union all select 'CP08 the IBAN definer functions still exist and are not callable-broken',
  (select count(*) = 2 from pg_proc where proname in ('fn_branch_iban','fn_public_branch_guide') and prosecdef), null;
set role authenticated;
do $$ declare e text; begin
  begin perform bank_iban from branches limit 1; e := 'accepted'; exception when others then e := sqlerrm; end;
  insert into test_results values ('CP09 a direct select of bank_iban is refused', e like '%permission denied%', e);
  begin perform email from staff_profiles limit 1; e := 'accepted'; exception when others then e := sqlerrm; end;
  insert into test_results values ('CP10 a direct select of staff email is refused', e like '%permission denied%', e);
  begin perform id, full_name, role, organization_id, auth_user_id from staff_profiles limit 1; perform id, name_ar from branches limit 1; e := 'ok'; exception when others then e := sqlerrm; end;
  insert into test_results values ('CP11 the columns the app reads still work', e = 'ok', e);
end $$;
reset role;
select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),160) as detail from test_results order by name;
rollback;
