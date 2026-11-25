-- Repeat the same tenant and branch boundary for objection notifications as for the reviewed-row update.
begin;
do $$declare d text;n text;begin
 d:=pg_get_functiondef('public.fn_review_mark__impl(jsonb)'::regprocedure);
 n:=replace(d,'where ri.id = any(ids) and ri.objection_at is not null and ri.reviewed_at is null loop',
 'where ri.id = any(ids) and ri.objection_at is not null and ri.reviewed_at is null and ri.organization_id = fn_user_org_id() and (ri.branch_id is null or ri.branch_id in (select fn_user_branch_ids())) loop');
 if n=d then raise exception 'Review objection source guard not found';end if;
 execute n;
end $$;
commit;
