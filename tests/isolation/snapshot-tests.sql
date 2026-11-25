\set ON_ERROR_STOP on
-- Regression checks for whole-catalog coverage and additions/deletions, not only existing slices.
do $$ declare before jsonb; after jsonb; n int; begin
 before:=iso.snap();
 select count(*) into n from pg_tables where schemaname='public';
 if (select count(*) from jsonb_object_keys(before))<>n then raise exception 'snapshot omitted tables'; end if;
 begin
  insert into public.notifications(organization_id,branch_id,title)
   values(iso.id('org-a'),iso.id('branch-a-1'),'ISO-SNAPSHOT-REGRESSION');
  after:=iso.snap();
  if before->'notifications'=after->'notifications' then raise exception 'snapshot missed mutation'; end if;
  if iso.snap_diff(before,after)='{}'::jsonb then raise exception 'diff missed mutation'; end if;
  raise exception 'ISO_EXPECTED_ROLLBACK';
 exception when others then
  if sqlerrm<>'ISO_EXPECTED_ROLLBACK' then raise; end if;
 end;
 if iso.snap()<>before then raise exception 'probe rollback leaked side effect'; end if;
 if iso.snap_diff('{}','{"new":{"new-org":[1,"x"]}}')='{}'::jsonb then raise exception 'diff missed addition'; end if;
 if iso.snap_diff('{"old":{"org":[1,"x"]}}','{}')='{}'::jsonb then raise exception 'diff missed deletion'; end if;
end $$;
