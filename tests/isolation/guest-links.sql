-- Executed cross-guest phone-link probes. Independent of incomplete general RPC adapters.
\set ON_ERROR_STOP on
create table iso.guest_result(id text primary key, outcome text, detail text);
grant select on iso.guest to anon;
grant insert on iso.guest_result to anon;
create function iso.check_guest_links() returns void language plpgsql as $$
declare g record; t record; body jsonb; before jsonb; after jsonb; ref text; state text; msg text;
begin
 -- Positive controls first for every real guest capability. Each open must return a usable token.
 for g in select * from iso.guest order by key loop
  perform set_config('request.headers',jsonb_build_object('x-hotel-slug',case when g.org=iso.id('org-a') then 'iso-gate-a' else 'iso-gate-b' end)::text,true);
  before:=iso.snap();
  begin
   body:=public.fn_guest_phone_reservations(g.token);
   if jsonb_array_length(body->'reservations')<>1 then raise exception 'ISO_CONTROL_BAD_LIST'; end if;
   ref:=body->'reservations'->0->>'internal_ref';
   body:=public.fn_guest_phone_open(g.token,ref);
   if body->>'status'<>'ok' or body->>'token' is null then raise exception 'ISO_CONTROL_BAD_OPEN'; end if;
   raise exception 'ISO_CONTROL_OK';
  exception when others then
   state:=sqlstate; msg:=sqlerrm;
  end;
  after:=iso.snap();
  insert into iso.guest_result values('control|'||g.key,
   case when msg='ISO_CONTROL_OK' and before=after then 'pass' else 'fail' end,
   state||':'||msg||';rollback-clean='||(before=after));
 end loop;
 if exists(select 1 from iso.guest_result where outcome<>'pass') then return; end if;
 -- No selected target reference may be opened with another guest's phone capability,
 -- including same-hotel different-branch and cross-hotel combinations.
 for g in select * from iso.guest order by key loop
  perform set_config('request.headers',jsonb_build_object('x-hotel-slug',case when g.org=iso.id('org-a') then 'iso-gate-a' else 'iso-gate-b' end)::text,true);
  for t in select * from iso.guest where key<>g.key order by key loop
   -- Fetch public booking reference from the target's valid control list before restoring actor context.
   perform set_config('request.headers',jsonb_build_object('x-hotel-slug',case when t.org=iso.id('org-a') then 'iso-gate-a' else 'iso-gate-b' end)::text,true);
   body:=public.fn_guest_phone_reservations(t.token); ref:=body->'reservations'->0->>'internal_ref';
   perform set_config('request.headers',jsonb_build_object('x-hotel-slug',case when g.org=iso.id('org-a') then 'iso-gate-a' else 'iso-gate-b' end)::text,true);
   before:=iso.snap();
   begin
    body:=public.fn_guest_phone_open(g.token,ref);
    raise exception 'ISO_UNAUTHORIZED_OPEN';
   exception when others then state:=sqlstate; msg:=sqlerrm; end;
   after:=iso.snap();
   insert into iso.guest_result values('cross-link|'||g.key||'|'||t.key,
    case when msg='NOT_FOUND' and before=after then 'pass' else 'fail' end,
    state||':'||msg||';unchanged='||(before=after));
  end loop;
 end loop;
end $$;
grant select on iso.guest_result to anon;
set role anon;
select iso.set_claims(null);
select iso.check_guest_links();
reset role;
