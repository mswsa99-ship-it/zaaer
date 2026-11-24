-- read-data lane, batch 3: fn_authorize_export, fn_invoice_preview, fn_reports_capability_usage, and the public/anon reads
-- fn_branch_media, fn_branch_photo, fn_public_review. Base fixtures.sql only. One transaction, rolled back, strict gate.
-- Run: psql -X -d iso_* -v ON_ERROR_STOP=1 -v strict=1 -f tests/isolation/read-data-batch3-proof.sql
-- Role expectations come from the permission seed (0043/0065): invoice.issue = owner,manager,supervisor,finance; reports.identities_usage = owner.
-- Public context is built per call with request.headers (x-hotel-slug / x-guest-token) and role anon / service_role, reset after each call.
\set ON_ERROR_STOP on
begin;
create temp table res(spec text, actor text, ctx text, target text, expect text, got text, ok boolean, detail text);
grant all on res to public;
create temp table mk as select t.branch_id, t.org, t.hotel, right(t.branch,1) br, (case when t.hotel='hotel-a' then 'A' else 'B' end)||right(t.branch,1) code,
  case when t.hotel='hotel-a' then 'iso-gate-a' else 'iso-gate-b' end slug from iso.target t;
grant all on mk to public;
-- markers
update branches b set name_ar='MK-BR-'||m.code from mk m where m.branch_id=b.id;
update branch_media i set bytes='\x01'::bytea, size_bytes=1, mime='image/mk-'||lower(m.code) from mk m where m.branch_id=i.branch_id and i.kind='logo';
insert into branch_media(branch_id, organization_id, kind, mime, bytes, size_bytes) select m.branch_id, m.org, 'logo', 'image/mk-'||lower(m.code), '\x01'::bytea, 1 from mk m
  where not exists (select 1 from branch_media x where x.branch_id=m.branch_id and x.kind='logo');
-- photo items: per branch the lowest id is live (public), the next is archived (never public)
create temp table ph as select i.id, m.code, m.branch_id, row_number() over (partition by i.branch_id order by i.id) rn from branch_media_items i join mk m on m.branch_id=i.branch_id;
grant all on ph to public;
update branch_media_items i set kind='photo', url=null, bytes='\x01'::bytea, mime='image/mk-'||lower(p.code), archived_at = case when p.rn=2 then now() end, archive_reason = case when p.rn=2 then 'mk' end
  from ph p where p.id=i.id and p.rn in (1,2);
-- reviews: one per branch on a reservation of that branch, token MKTOK-<code>; one expired per branch tokens MKEXP-<code>
create temp table rv as select m.code, m.org, m.branch_id, (select r.id from reservations r where r.branch_id=m.branch_id order by r.id limit 1) res_id,
  (select r.id from reservations r where r.branch_id=m.branch_id order by r.id desc limit 1) res2_id from mk m;
grant all on rv to public;
do $$ begin if exists (select 1 from rv where res_id=res2_id) then raise exception 'need 2 reservations per branch'; end if; end $$;
delete from guest_reviews where reservation_id in (select res_id from rv union select res2_id from rv);
insert into guest_reviews(organization_id, branch_id, reservation_id, token_hash, invited_at) select org, branch_id, res_id, encode(extensions.digest('MKTOK-'||code,'sha256'),'hex'), now() from rv;
insert into guest_reviews(organization_id, branch_id, reservation_id, token_hash, invited_at) select org, branch_id, res2_id, encode(extensions.digest('MKEXP-'||code,'sha256'),'hex'), now()-interval '15 days' from rv;
-- audit markers for the usage report (other_actions lists actions outside the catalog)
insert into audit_events(organization_id, action, result, created_at) select m.org, 'mk_act_'||left(m.code,1), 'success', now() from (select distinct org, code from mk where right(code,1)='1') m;
insert into audit_events(organization_id, action, result, created_at) values ('00000000-0000-0000-0000-000000000001', 'mk_act_O', 'success', now());
-- reservation identity marker for invoice preview
create temp table rs as select r.id, m.code, m.branch_id, r.internal_ref from reservations r join mk m on m.branch_id=r.branch_id;
grant all on rs to public;

create temp table spa_orig as select * from staff_page_access;
grant all on spa_orig to public;

-- ---------------------------------------------------------------- A. authenticated reads (export gate, invoice preview, usage report)
do $$
declare a record; t record; msg text; r jsonb; exp_c text; got_c text; ok boolean; det text; accessible boolean; pg text; st text; sid uuid; v_org uuid; b_before jsonb; b_after jsonb;
        rid uuid; iid uuid; ex_ref text; bad int; exp_codes text[];
begin
 for a in select * from iso.actor order by hotel nulls first, role, branch loop
  b_before := iso.snap();
  select organization_id, id into v_org, sid from staff_profiles where auth_user_id = a.auth_user;
  -- fn_authorize_export: listed pages need view+export; unlisted pages never pass; page grants decide in individual mode, owner always passes on listed pages
  for pg, st in select * from (values ('/staff/reservations','legacy'),('/admin/reports','legacy'),('/admin/reports','ind-full'),('/admin/reports','ind-view'),('/staff/dashboard','ind-full'),('/staff/reservations','ind-none')) v(p,s) loop
    if sid is not null then
      delete from staff_page_access where staff_id = sid;
      if st = 'ind-full' then insert into staff_page_access(staff_id, organization_id, enabled, page_grants) values (sid, v_org, true, jsonb_build_object(pg, jsonb_build_object('view', true, 'export', true))); end if;
      if st = 'ind-view' then insert into staff_page_access(staff_id, organization_id, enabled, page_grants) values (sid, v_org, true, jsonb_build_object(pg, jsonb_build_object('view', true))); end if;
      if st = 'ind-none' then insert into staff_page_access(staff_id, organization_id, enabled, page_grants) values (sid, v_org, true, '{}'::jsonb); end if;
    end if;
    exp_c := case when sid is null then 'deny' when pg = '/staff/dashboard' then 'deny' when a.role = 'owner' then 'allow' when st in ('legacy','ind-full') then 'allow' else 'deny' end;
    msg := null; perform iso.set_claims(a.auth_user); set local role authenticated;
    begin perform fn_authorize_export(pg); exception when others then msg := sqlerrm; end; reset role;
    got_c := case when msg is null then 'allow' when msg like 'FORBIDDEN%' or msg like 'permission denied%' then 'deny' else 'error' end;
    insert into res values ('fn_authorize_export', a.key, st, pg, exp_c, got_c, got_c = exp_c, msg);
  end loop;
  if sid is not null then delete from staff_page_access where staff_id = sid; insert into staff_page_access select * from spa_orig where staff_id = sid; end if;

  for t in select * from mk order by code loop
    accessible := sid is not null and t.org = v_org and (a.role = 'owner' or t.br = right(a.branch, 1));
    -- fn_invoice_preview: every reservation of the target branch (reservation_id path)
    for rid, ex_ref in select id, internal_ref from rs where branch_id = t.branch_id order by id loop
      exp_c := case when accessible and a.role in ('owner','manager','supervisor','finance') then 'allow' else 'deny' end;
      msg := null; r := null; perform iso.set_claims(a.auth_user); set local role authenticated;
      begin r := fn_invoice_preview(jsonb_build_object('reservation_id', rid)); exception when others then msg := sqlerrm; end; reset role;
      got_c := case when msg is null then 'allow' when msg like 'FORBIDDEN%' then 'deny' else 'error' end; det := msg; ok := got_c = exp_c;
      if ok and got_c = 'allow' then
        if r->'reservation'->>'id' <> rid::text or r->'reservation'->>'internal_ref' <> ex_ref then ok := false; det := 'IDENTITY mismatch ' || left(r::text, 160); end if;
        select count(*) into bad from jsonb_array_elements(r->'lines') l where not exists (select 1 from reservation_charges c where c.id = (l->>'charge_id')::uuid and c.reservation_id = rid and c.branch_id = t.branch_id);
        if bad > 0 then ok := false; det := 'LEAK charge not of this reservation: ' || bad; end if;
        if (r->>'total_halalas')::bigint <> (r->>'subtotal_halalas')::bigint + (r->>'tax_halalas')::bigint then ok := false; det := 'TOTAL inconsistent'; end if;
        if (select coalesce(sum((l->>'amount_halalas')::bigint),0) from jsonb_array_elements(r->'lines') l) <> (r->>'total_halalas')::bigint then ok := false; det := 'LINE SUM <> total'; end if;
        if (select count(*) from reservation_charges c where c.reservation_id = rid and c.invoice_id is null) > 0 and jsonb_array_length(r->'lines') = 0 then ok := false; det := 'ORACLE-EMPTY: open charges but no lines'; end if;
      end if;
      insert into res values ('fn_invoice_preview', a.key, 'reservation_id', t.code, exp_c, got_c, ok, det);
    end loop;
    -- fn_invoice_preview via invoice_id (existing invoices of the branch)
    for iid in select i.id from invoices i where i.branch_id = t.branch_id order by i.id loop
      exp_c := case when accessible and a.role in ('owner','manager','supervisor','finance') then 'allow' else 'deny' end;
      msg := null; r := null; perform iso.set_claims(a.auth_user); set local role authenticated;
      begin r := fn_invoice_preview(jsonb_build_object('invoice_id', iid)); exception when others then msg := sqlerrm; end; reset role;
      got_c := case when msg is null then 'allow' when msg like 'FORBIDDEN%' then 'deny' else 'error' end; det := msg; ok := got_c = exp_c;
      if ok and got_c = 'allow' and (r->'reservation'->>'id')::uuid <> (select reservation_id from invoices where id = iid) then ok := false; det := 'IDENTITY mismatch invoice->reservation'; end if;
      insert into res values ('fn_invoice_preview', a.key, 'invoice_id', t.code, exp_c, got_c, ok, det);
    end loop;
  end loop;

  -- fn_reports_capability_usage: owner only; other_actions shows only the caller's org markers
  msg := null; r := null; perform iso.set_claims(a.auth_user); set local role authenticated;
  begin r := fn_reports_capability_usage('{}'::jsonb); exception when others then msg := sqlerrm; end; reset role;
  exp_c := case when a.role = 'owner' then 'allow' else 'deny' end;
  got_c := case when msg is null then 'allow' when msg like 'FORBIDDEN%' then 'deny' else 'error' end; det := msg; ok := got_c = exp_c;
  if ok and got_c = 'allow' then
    exp_codes := array['mk_act_' || case when a.hotel = 'hotel-a' then 'A' else 'B' end];
    if not (select coalesce(array_agg(o->>'action') filter (where o->>'action' like 'mk_act_%'), '{}') = exp_codes from jsonb_array_elements(r->'other_actions') o) then
      ok := false; det := 'MARKER set mismatch ' || left((r->'other_actions')::text, 200); end if;
    if jsonb_array_length(r->'rows') = 0 then ok := false; det := 'ORACLE-EMPTY rows'; end if;
  end if;
  insert into res values ('fn_reports_capability_usage', a.key, '-', a.hotel, exp_c, got_c, ok, det);

  b_after := iso.snap();
  insert into res values ('SNAPSHOT', a.key, 'A', '-', 'no-write', case when iso.snap_diff(b_before, b_after) = '{}'::jsonb then 'no-write' else 'WROTE' end, iso.snap_diff(b_before, b_after) = '{}'::jsonb, null);
 end loop;
 perform iso.set_claims(null);
 -- unauthenticated (anon) cannot execute these at all
 perform set_config('request.headers', '', false);
 foreach pg in array array['export','invoice','usage'] loop
   msg := null; set local role anon;
   begin
     if pg = 'export' then perform fn_authorize_export('/admin/reports');
     elsif pg = 'invoice' then perform fn_invoice_preview(jsonb_build_object('reservation_id', (select id from rs limit 1)));
     else perform fn_reports_capability_usage('{}'::jsonb); end if;
   exception when others then msg := sqlerrm; end; reset role;
   insert into res values ('anon-denied-' || pg, 'anon', '-', '-', 'deny', case when msg is not null then 'deny' else 'allow' end, msg is not null, msg);
 end loop;
end $$;

-- ---------------------------------------------------------------- B. public / anon reads with header and token contexts
do $$
declare t record; c record; msg text; r text; rj jsonb; exp_s text; got_s text; ok boolean; det text; want text; i record; tok text; rl text; hdr text; hits int; b_before jsonb; b_after jsonb; rvw record;
begin
 perform iso.set_claims(null);
 b_before := iso.snap();
 -- contexts: (name, header json, db role)
 create temp table ctxs(name text, hdr text, rl text, slug text) on commit drop;
 insert into ctxs values ('slug-a', '{"x-hotel-slug":"iso-gate-a"}', 'anon', 'iso-gate-a'), ('slug-b', '{"x-hotel-slug":"iso-gate-b"}', 'anon', 'iso-gate-b'),
   ('slug-unknown', '{"x-hotel-slug":"no-such-hotel"}', 'anon', null), ('no-header', '', 'anon', null), ('service-role', '', 'service_role', 'ALL');
 grant all on ctxs to public;
 for c in select * from ctxs loop
  for t in select * from mk order by code loop
    -- fn_branch_media(branch,'logo')
    exp_s := case when c.slug = 'ALL' or c.slug = t.slug then 'data:image/mk-' || lower(t.code) || ';base64,AQ==' else null end;
    perform set_config('request.headers', c.hdr, false); msg := null; r := null; execute 'set local role ' || c.rl;
    begin r := fn_branch_media(t.branch_id, 'logo'); exception when others then msg := sqlerrm; end; reset role;
    insert into res values ('fn_branch_media', c.rl, c.name, t.code, coalesce(exp_s, 'null'), coalesce(r, 'null'), msg is null and r is not distinct from exp_s, msg);
    -- fn_branch_photo: live item (rn1) and archived item (rn2)
    for i in select * from ph where branch_id = t.branch_id and rn in (1,2) order by rn loop
      exp_s := case when i.rn = 1 and (c.slug = 'ALL' or c.slug = t.slug) then 'data:image/mk-' || lower(t.code) || ';base64,AQ==' else null end;  -- archived items are never public, service_role included
      perform set_config('request.headers', c.hdr, false); msg := null; r := null; execute 'set local role ' || c.rl;
      begin r := fn_branch_photo(i.id); exception when others then msg := sqlerrm; end; reset role;
      insert into res values ('fn_branch_photo', c.rl, c.name, t.code || (case i.rn when 1 then ':live' else ':archived' end), coalesce(exp_s, 'null'), coalesce(r, 'null'), msg is null and r is not distinct from exp_s, msg);
    end loop;
    -- fn_public_review: valid, expired, wrong token
    for tok, want in select * from (values ('MKTOK-' || t.code, 'valid'), ('MKEXP-' || t.code, 'expired'), ('MKTOK-' || t.code || 'x', 'garbage')) v(a, b) loop
      exp_s := case when want = 'valid' and (c.slug is null and c.name = 'no-header' or c.slug = t.slug or c.slug = 'ALL') then 'MK-BR-' || t.code else 'TOKEN_INVALID' end;
      perform set_config('request.headers', c.hdr, false); msg := null; rj := null; execute 'set local role ' || c.rl;
      begin rj := fn_public_review(tok); exception when others then msg := sqlerrm; end; reset role;
      got_s := coalesce(rj->>'branch_name', msg);
      insert into res values ('fn_public_review', c.rl, c.name, t.code || ':' || want, exp_s, got_s, got_s = exp_s and (rj is null or rj->>'check_in' = (select check_in::text from reservations where id = (select res_id from rv where code = t.code))), null);
    end loop;
  end loop;
 end loop;
 -- guest token header (no slug) resolves the org of the token: reading with x-guest-token of the matching review passes, of the foreign review is rejected for a foreign branch media call
 for t in select * from mk order by code loop
   perform set_config('request.headers', jsonb_build_object('x-guest-token', 'MKTOK-' || t.code)::text, false); msg := null; r := null; set local role anon;
   begin r := fn_branch_media(t.branch_id, 'logo'); exception when others then msg := sqlerrm; end; reset role;
   insert into res values ('fn_branch_media', 'anon', 'guest-token-own', t.code, 'data:image/mk-' || lower(t.code) || ';base64,AQ==', coalesce(r, 'null'), r = 'data:image/mk-' || lower(t.code) || ';base64,AQ==', msg);
   perform set_config('request.headers', jsonb_build_object('x-guest-token', 'MKTOK-' || (case when t.hotel = 'hotel-a' then 'B' else 'A' end) || '1')::text, false); msg := null; r := null; set local role anon;
   begin r := fn_branch_media(t.branch_id, 'logo'); exception when others then msg := sqlerrm; end; reset role;
   insert into res values ('fn_branch_media', 'anon', 'guest-token-foreign', t.code, 'null', coalesce(r, 'null'), r is null and msg is null, msg);
 end loop;
 -- inactive branch is hidden from the public even with the right slug (hotel keeps another active branch)
 update branches set is_active = false where id = (select branch_id from mk where code = 'A2');
 perform set_config('request.headers', '{"x-hotel-slug":"iso-gate-a"}', false); set local role anon; r := fn_branch_media((select branch_id from mk where code = 'A2'), 'logo'); reset role;
 insert into res values ('fn_branch_media', 'anon', 'slug-a-inactive-branch', 'A2', 'null', coalesce(r, 'null'), r is null, null);
 set local role anon; r := fn_branch_photo((select id from ph where code = 'A2' and rn = 1)); reset role;
 insert into res values ('fn_branch_photo', 'anon', 'slug-a-inactive-branch', 'A2', 'null', coalesce(r, 'null'), r is null, null);
 update branches set is_active = true where id = (select branch_id from mk where code = 'A2');
 perform set_config('request.headers', '', false);
 b_after := iso.snap();
 insert into res values ('SNAPSHOT', 'public', 'B', '-', 'no-write', case when iso.snap_diff(b_before, b_after) = '{}'::jsonb then 'no-write' else 'WROTE' end, iso.snap_diff(b_before, b_after) = '{}'::jsonb, null);
end $$;

select spec, count(*) calls, count(*) filter (where expect not in ('null','deny','no-write','TOKEN_INVALID') ) positive, count(*) filter (where expect in ('null','deny','TOKEN_INVALID')) negative, count(*) filter (where not ok) failures from res group by 1 order by 1;
select * from res where not ok or detail like 'ORACLE%' order by spec, actor, ctx, target limit 60;
select count(*) total_calls, count(*) filter (where not ok) failures from res;
select (:strict = 1 and exists (select 1 from res where not ok)) as fail \gset
\if :fail
  select 1/0 as read_data_batch3_strict_failure;
\endif
rollback;
