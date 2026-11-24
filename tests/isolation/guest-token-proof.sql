-- Guest bearer-token scenarios for the data-returning token reads fn_guest_session and fn_guest_stay_summary (source: fn_token_reservation, fn_guest_org_id).
-- Scope: these two read functions only, 2 hotels, anon role. NOT a proof for mutators, not for the other token functions, not a call-graph proof.
-- Rolled back, local synthetic DB only.
\set ON_ERROR_STOP on
begin;
-- Optional fresh-database setup: invoke psql with -v guest_token_standalone=1.
\if :{?guest_token_standalone}
\ir guest-token-proof-fixtures.sql
\endif
create temp table gtp(name text not null, ok boolean not null);
grant all on gtp to anon;
create temp table gtk as
  select o.guest_slug as slug, s.token, s.reservation_id, s.organization_id as org
    from registration_sessions s join organizations o on o.id = s.organization_id
   where o.guest_slug in ('iso-gate-a','iso-gate-b') and o.platform_status='active' and s.expires_at>now();
create temp table gt1 as
  select distinct on (slug) slug, token, reservation_id, org from gtk order by slug, token;
do $$ begin assert (select count(*) from gt1)=2 and (select count(distinct reservation_id) from gt1)=2, 'two distinct live hotel capability fixtures required'; end $$;
grant all on gtk, gt1 to anon;
set role anon;
do $$ declare a record; b record; r jsonb; err text; fn text;
begin
  for a in select * from gt1 order by slug loop
  select * into b from gt1 where slug<>a.slug;
  foreach fn in array array['fn_guest_session','fn_guest_stay_summary'] loop
    -- matching header + own token
    perform set_config('request.headers', json_build_object('x-hotel-slug', a.slug)::text, true);
    execute format('select %I($1)', fn) into r using a.token;
    insert into gtp values (fn||'/'||a.slug||': matching header + own token returns data', r is not null and r::text <> 'null');
    insert into gtp values (fn||'/'||a.slug||': returned reservation is the token''s own', r->'reservation'->>'id'=a.reservation_id::text and r->'reservation'->>'id'<>b.reservation_id::text);
    -- foreign hotel header + token of the other hotel
    perform set_config('request.headers', json_build_object('x-hotel-slug', b.slug)::text, true);
    err := null; begin execute format('select %I($1)', fn) into r using a.token; exception when others then err := sqlerrm; end;
    insert into gtp values (fn||'/'||a.slug||': foreign header + token -> TOKEN_INVALID', err = 'TOKEN_INVALID');
    -- invalid token with matching header
    perform set_config('request.headers', json_build_object('x-hotel-slug', a.slug)::text, true);
    err := null; begin execute format('select %I($1)', fn) into r using 'not-a-token-xb'; exception when others then err := sqlerrm; end;
    insert into gtp values (fn||'/'||a.slug||': invalid token -> TOKEN_INVALID', err = 'TOKEN_INVALID');
    -- absent header: bearer capability by source (token alone resolves its own reservation, never another hotel's)
    perform set_config('request.headers', '{}', true);
    err := null; begin execute format('select %I($1)', fn) into r using a.token; exception when others then err := sqlerrm; end;
    insert into gtp values (fn||'/'||a.slug||': absent header + valid token is accepted (bearer contract, own reservation only)', err is null and r->'reservation'->>'id'=a.reservation_id::text and r->'reservation'->>'id'<>b.reservation_id::text);
  end loop;
  end loop;
end $$;
reset role;
-- expired token and suspended org (superuser edits, rolled back)
update registration_sessions set expires_at = now() - interval '1 minute' where token = (select token from gt1 where slug = 'iso-gate-a');
set role anon;
do $$ declare a record; err text; r jsonb; begin
  select * into a from gt1 where slug = 'iso-gate-a';
  perform set_config('request.headers', json_build_object('x-hotel-slug', a.slug)::text, true);
  begin perform fn_guest_session(a.token); exception when others then err := sqlerrm; end;
  insert into gtp values ('fn_guest_session: expired token -> TOKEN_INVALID', err = 'TOKEN_INVALID');
end $$;
reset role;
update registration_sessions set expires_at = now() + interval '1 day' where token = (select token from gt1 where slug = 'iso-gate-a');
update organizations set platform_status = 'suspended' where guest_slug = 'iso-gate-a';
set role anon;
do $$ declare a record; err text; begin
  select * into a from gt1 where slug = 'iso-gate-a';
  perform set_config('request.headers', '{}', true);
  begin perform fn_guest_session(a.token); exception when others then err := sqlerrm; end;
  insert into gtp values ('fn_guest_session: suspended org token -> TOKEN_INVALID', err = 'TOKEN_INVALID');
end $$;
reset role;
select count(*) as assertion_count, count(*) filter(where ok is distinct from true) as failed from gtp;
select case when ok then 'proof-ok' else 'proof-FAILED' end as result, name from gtp order by name;
do $$ begin assert (select count(*) from gtp)=22, 'exact scoped assertion count'; if exists (select 1 from gtp where ok is distinct from true) then raise exception 'guest token proof failed'; end if; end $$;
rollback;
