\set ON_ERROR_STOP on
begin;
insert into auth.users(id,email,email_confirmed_at) values('98000000-0000-0000-0000-000000000104','hotel-only@example.test',now());
select t_login('98000000-0000-0000-0000-000000000104','hotel-only@example.test');
set local role authenticated;
select fn_owner_register_hotel('{"name_ar":"فندق بلا فروع","full_name":"مالك الفندق","slug":"forged"}');
reset role;
do $$begin if not exists(select 1 from organizations o join staff_profiles s on s.organization_id=o.id where s.auth_user_id='98000000-0000-0000-0000-000000000104' and o.guest_slug='hotel-98000000000000000000000000000104' and not exists(select 1 from branches b where b.organization_id=o.id)) then raise exception 'hotel-only failed';end if;end$$;
rollback;
