-- Rollback of 0145 (additive): drops the four role-aware read functions. Run only after the app no longer calls them.
drop function if exists public.fn_reservation_cards(uuid, text[], boolean);
drop function if exists public.fn_branch_iban(uuid);
drop function if exists public.fn_my_profile();
drop function if exists public.fn_staff_directory();
