-- Individual users have no notification page/permission mapping yet.
-- Keep legacy scope and owner access; close direct reads/writes for individual accounts.
begin;
alter policy staff_notif_select on public.notifications using (
 organization_id=(select fn_user_org_id())
 and (branch_id in (select fn_user_branch_ids()) or branch_id is null)
 and (select fn_current_role()='owner' or fn_user_access_mode()<>'individual')
);
alter policy staff_notif_update on public.notifications using (
 organization_id=(select fn_user_org_id())
 and branch_id in (select fn_user_branch_ids())
 and (select fn_current_role()='owner' or fn_user_access_mode()<>'individual')
) with check (
 organization_id=(select fn_user_org_id())
 and branch_id in (select fn_user_branch_ids())
 and (select fn_current_role()='owner' or fn_user_access_mode()<>'individual')
);
commit;
