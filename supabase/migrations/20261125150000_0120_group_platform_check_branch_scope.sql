-- Grouped platform verification must respect each row's branch, not only the selected reservation.
begin;
do $$declare d text;n text;begin
 d:=pg_get_functiondef('public.fn_platform_mark_checked__impl(jsonb)'::regprocedure);
 n:=replace(d,'where organization_id = r.organization_id and (id = r.id or (r.group_ref is not null and group_ref = r.group_ref))',
 'where organization_id = r.organization_id and branch_id in (select fn_user_branch_ids()) and (id = r.id or (r.group_ref is not null and group_ref = r.group_ref))');
 if n=d then raise exception 'Platform checked group source guard not found';end if;
 execute n;
end $$;
commit;
