-- 0155: least privilege for two direct column readers. branches.bank_iban and staff_profiles.email were readable by every signed-in
-- member of the organization through plain table SELECT. No client code reads either column directly (the IBAN goes out through
-- SECURITY DEFINER functions; staff emails through definer RPCs gated by permission). Staff phone is NOT changed.
-- Own-org RLS is unchanged. Side effect: select * on these two tables is denied for authenticated; a column added later needs its own grant.
do $$ declare cols text;
begin
  -- branches: keep every column except bank_iban for authenticated
  revoke select on public.branches from authenticated;
  select string_agg(quote_ident(column_name), ',' order by ordinal_position) into cols from information_schema.columns
   where table_schema='public' and table_name='branches' and column_name <> 'bank_iban';
  execute 'grant select (' || cols || ') on public.branches to authenticated';
  -- staff_profiles: keep every column except email for authenticated and anon
  revoke select on public.staff_profiles from authenticated, anon;
  select string_agg(quote_ident(column_name), ',' order by ordinal_position) into cols from information_schema.columns
   where table_schema='public' and table_name='staff_profiles' and column_name <> 'email';
  execute 'grant select (' || cols || ') on public.staff_profiles to authenticated';
end $$;
