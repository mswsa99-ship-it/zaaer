-- read-data lane, batch 2: fn_definition_dependencies (entity=branch) and fn_quote_stay. Load after fixtures.sql only (base). One transaction, rolled back.
-- Run: psql -X -d iso_* -v ON_ERROR_STOP=1 -v strict=1 -f tests/isolation/read-data-batch2-proof.sql
-- Markers: blocks added per branch (topped up to 21, 22, 23, 24 blocks => distinct counts), category base price distinct per category.
-- Oracles are direct counts / base_price arithmetic computed outside the function (no rate_calendar rows exist in the probed 2031 window, asserted).
-- Role expectation for definition_dependencies (cap 'definitions' = owner, manager) is the legacy matrix observed via fn_can; quote_stay is gated by branch access only (source: fn_require_branch).
\set ON_ERROR_STOP on
begin;
create temp table res(spec text, actor text, target text, expect text, got text, ok boolean, detail text);
grant all on res to public;
create temp table mk as select t.branch_id, t.org, t.hotel, right(t.branch,1) br,
   (case when t.hotel='hotel-a' then 'A' else 'B' end)||right(t.branch,1) code, row_number() over (order by t.hotel, t.branch) n from iso.target t;
grant all on mk to public;
insert into blocks(organization_id, branch_id, name) select m.org, m.branch_id, 'MK-BLK-'||m.code||'-'||g from mk m, generate_series(1, 20+m.n-(select count(*) from blocks x where x.branch_id=m.branch_id)::int) g;
update room_categories c set base_price_halalas = 40000 + 100*x.n from (select id, row_number() over (order by id) n from room_categories) x where x.id=c.id;
create temp table probe as select m.branch_id, m.code, m.org,
  (select c.id from room_categories c where c.branch_id=m.branch_id and c.archived_at is null order by c.id limit 1) cat from mk m;
grant all on probe to public;
do $$ begin
  if exists (select 1 from rate_calendar rc join probe p on p.cat=rc.category_id where rc.night between date '2031-03-01' and date '2031-03-03') then raise exception 'oracle precondition: rate_calendar rows in probe window'; end if;
  if (select count(distinct (select count(*) from blocks b where b.branch_id=m.branch_id)) from mk m) <> 4 then raise exception 'marker precondition: block counts not distinct'; end if;
  if exists (select 1 from probe where cat is null) then raise exception 'no category'; end if;
end $$;
create temp table exp_deps as select m.branch_id, jsonb_build_object('blocks',(select count(*) from blocks b where b.branch_id=m.branch_id),'rooms',(select count(*) from rooms b where b.branch_id=m.branch_id),
  'floors',(select count(*) from floors b where b.branch_id=m.branch_id),'reservations',(select count(*) from reservations b where b.branch_id=m.branch_id),'invoices',(select count(*) from invoices b where b.branch_id=m.branch_id),
  'staff',(select count(*) from branch_memberships b where b.branch_id=m.branch_id)) e from mk m;
grant all on exp_deps to public;
create temp table exp_cat as select p.branch_id, (select base_price_halalas from room_categories where id=p.cat) bp from probe p;
grant all on exp_cat to public;
do $$
declare a record; t record; msg text; r jsonb; exp_c text; got_c text; ok boolean; det text; sid uuid; b_before jsonb; b_after jsonb; accessible boolean; role_ok boolean; ex jsonb; bp bigint; k text; foreign_cat uuid;
begin
 for a in select * from iso.actor where role <> 'guest' order by hotel, role, branch loop
  b_before := iso.snap();
  for t in select m.*, p.cat from mk m join probe p on p.branch_id=m.branch_id order by m.n loop
   select (m.org = (select organization_id from staff_profiles where auth_user_id=a.auth_user) and (a.role='owner' or m.br = right(a.branch,1))) into accessible from mk m where m.branch_id=t.branch_id;
   -- definition_dependencies
   role_ok := a.role in ('owner','manager');
   exp_c := case when accessible and role_ok then 'allow' else 'deny' end;
   msg := null; r := null;
   perform iso.set_claims(a.auth_user); set local role authenticated;
   begin r := fn_definition_dependencies('branch', t.branch_id); exception when others then msg := sqlerrm; end;
   reset role;
   got_c := case when msg is null then 'allow' when msg like 'FORBIDDEN%' then 'deny' else 'error' end; det := msg;
   ok := got_c = exp_c;
   if ok and got_c='allow' then
     select e into ex from exp_deps where branch_id=t.branch_id;
     if (r @> ex) is not true then ok := false; det := 'EXACT mismatch exp='||ex::text||' got='||left(r::text,200); end if;
     if (ex->>'blocks')::int < 21 then ok := false; det := 'ORACLE weak'; end if;
   end if;
   insert into res values ('fn_definition_dependencies', a.key, t.code, exp_c, got_c, ok, det);
   -- quote_stay own category, 3 nights, periods off => nightly base price
   exp_c := case when accessible then 'allow' else 'deny' end;
   msg := null; r := null;
   perform iso.set_claims(a.auth_user); set local role authenticated;
   begin r := fn_quote_stay(jsonb_build_object('branch_id', t.branch_id, 'category_id', t.cat, 'check_in','2031-03-01','check_out','2031-03-04','periods',false)); exception when others then msg := sqlerrm; end;
   reset role;
   got_c := case when msg is null then 'allow' when msg like 'FORBIDDEN%' then 'deny' else 'error' end; det := msg;
   ok := got_c = exp_c;
   if ok and got_c='allow' then
     select e.bp into bp from exp_cat e where branch_id=t.branch_id;
     if (r->>'nights')::int <> 3 or (r->>'rent_gross')::bigint <> 3*bp or (r->>'nightly_rate')::bigint <> bp or r->>'basis' <> 'daily' then ok := false; det := 'EXACT mismatch bp='||bp||' got='||left(r::text,200); end if;
   end if;
   insert into res values ('fn_quote_stay', a.key, t.code, exp_c, got_c, ok, det);
   -- quote_stay own branch but another branch's category (same-hotel cross-branch and foreign hotel): must be BRANCH_MISMATCH, never a price
   if accessible then
     select p.cat into foreign_cat from probe p where p.branch_id <> t.branch_id order by (p.org = t.org) desc, p.code limit 1;
     msg := null; r := null;
     perform iso.set_claims(a.auth_user); set local role authenticated;
     begin r := fn_quote_stay(jsonb_build_object('branch_id', t.branch_id, 'category_id', foreign_cat, 'check_in','2031-03-01','check_out','2031-03-04','periods',false)); exception when others then msg := sqlerrm; end;
     reset role;
     insert into res values ('fn_quote_stay/foreign-category', a.key, t.code, 'deny', case when msg like 'BRANCH_MISMATCH%' then 'deny' when msg is null then 'allow' else 'error' end, msg like 'BRANCH_MISMATCH%', coalesce(msg, left(r::text,100)));
   end if;
  end loop;
  b_after := iso.snap();
  insert into res values ('SNAPSHOT', a.key, '-', 'no-write', case when iso.snap_diff(b_before,b_after)='{}'::jsonb then 'no-write' else 'WROTE' end, iso.snap_diff(b_before,b_after)='{}'::jsonb, null);
 end loop;
end $$;
select spec, count(*) calls, count(*) filter (where expect='allow' and got='allow' and ok) allow_ok, count(*) filter (where expect='deny' and got='deny' and ok) deny_ok, count(*) filter (where not ok) failures from res group by 1 order by 1;
select * from res where not ok limit 40;
select count(*) total_calls, count(*) filter (where not ok) failures from res;
select (:strict = 1 and exists (select 1 from res where not ok)) as fail \gset
\if :fail
  select 1/0 as read_data_batch2_strict_failure;
\endif
rollback;
