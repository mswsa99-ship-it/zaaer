\set ON_ERROR_STOP on
begin;
insert into auth.users(id,email,email_confirmed_at) values('98000000-0000-0000-0000-000000000100','branch-owner@example.test',now());
select t_login('98000000-0000-0000-0000-000000000100','branch-owner@example.test');
do $$declare r jsonb;bad boolean;v uuid;begin
begin perform fn_owner_create_hotel('{"name_ar":"فندق فروع","full_name":"مالك الفروع","slug":"branches-bad","branches":[{"name_ar":"فرع","city":"مدينة","address":"عنوان","map_url":"javascript:alert(1)"}]}');bad:=false;exception when others then bad:=sqlerrm='VALIDATION: branch_location';end;if not bad then raise exception 'unsafe map accepted';end if;
r:=fn_owner_create_hotel('{"name_ar":"فندق فروع","full_name":"مالك الفروع","slug":"branches-new-owner","branches":[{"name_ar":"فرع أول","city":"الرياض","address":"عنوان أول","map_url":"https://maps.google.com/"},{"name_ar":"فرع ثان","city":"بريدة","address":"عنوان ثان","organization_id":"00000000-0000-0000-0000-000000000001"}]}');v:=(r->>'id')::uuid;
if (select count(*) from branches where organization_id=v)<>2 or (select count(*) from branch_memberships m join branches b on b.id=m.branch_id where b.organization_id=v)<>2 then raise exception 'branch membership missing';end if;
if not exists(select 1 from branches where organization_id=v and city='بريدة' and address='عنوان ثان')then raise exception 'location missing';end if;
raise notice 'PASS two branches and memberships with locations atomically created; unsafe map rejected; client hotel ignored';
end$$;
rollback;
