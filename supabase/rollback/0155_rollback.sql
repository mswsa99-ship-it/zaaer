-- Restores the previous table-level SELECT (authenticated on branches and staff_profiles; anon on staff_profiles as before).
GRANT SELECT ON public.branches TO authenticated;
GRANT SELECT ON public.staff_profiles TO authenticated, anon;
