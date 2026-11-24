-- =====================================================================
-- Plan 5.3 (finding S4, migration 0082): the audit log's source derives in the server, a trigger refuses any
-- change or deletion of a row from any role (the owner and even the superuser), and the hotel's hash chain
-- reveals a row removed later. Uncodified descriptive names (worker patch; no prefix registered yet).
-- Runs after audit_trace_tests.sql on the same database (uses its synthetic hotel and staff).
-- =====================================================================
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create temp table ids(k text primary key, v uuid);
grant all on ids to public;
create or replace function t_login(p_uid uuid, p_email text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email)::text, false);
end $$;
create or replace function t_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;

set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
do $$ declare r jsonb; begin
  r := fn_staff_create_reservation(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','category_id','00000000-0000-0000-0000-000000000030',
         'check_in', (current_date + 50)::text, 'check_out', (current_date + 51)::text, 'guest_phone', '0551000099', 'guest_name', 'ضيف السلسلة', 'source_id', '00000000-0000-0000-0000-000000000021'));
  insert into ids values ('res', (r->>'id')::uuid);
end $$;

-- every new row carries the chain, linked to the row before it in the same hotel
do $$ declare a audit_events; b audit_events; begin
  select * into a from audit_events where organization_id = '00000000-0000-0000-0000-000000000001' order by chain_seq desc limit 1;
  select * into b from audit_events where organization_id = '00000000-0000-0000-0000-000000000001' and chain_seq = a.chain_seq - 1;
  perform t_record('a new audit row is chained to the row before it in its hotel',
    a.chain_seq is not null and a.row_hash is not null and length(a.row_hash) = 64 and a.prev_hash is not null and a.prev_hash = b.row_hash,
    'seq ' || a.chain_seq);
exception when others then perform t_record('a new audit row is chained to the row before it in its hotel', false, sqlerrm); end $$;

-- the whole hotel chain verifies after ordinary work
do $$ declare v jsonb; begin
  v := fn_audit_chain_verify();
  perform t_record('the hotel chain verifies after ordinary work', (v->>'ok')::boolean and (v->>'checked')::int > 10, v::text);
exception when others then perform t_record('the hotel chain verifies after ordinary work', false, sqlerrm); end $$;

-- a manager (no security capability) cannot verify the chain
select t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
do $$ declare msg text := 'accepted'; begin
  begin perform fn_audit_chain_verify(); exception when others then msg := sqlerrm; end;
  perform t_record('verifying the chain is the owner''s alone', msg like 'FORBIDDEN%', msg);
exception when others then perform t_record('verifying the chain is the owner''s alone', false, sqlerrm); end $$;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');

-- the source derives in the server: a client header no longer writes it; the trusted in-database setting does
select set_config('request.headers', '{"x-client-source":"staff-app"}', false);
do $$ declare r jsonb; a audit_events; begin
  r := fn_create_voucher(jsonb_build_object('reservation_id', (select v from ids where k = 'res'), 'kind','receipt', 'received_confirmed',true, 'amount_halalas', 100, 'method','cash', 'idempotency_key','n7-src-1'));
  select * into a from audit_events where entity_id = (r->>'voucher_id')::uuid order by chain_seq desc limit 1;
  perform t_record('the client source header no longer writes the log''s source', a.source = 'screen', a.source);
exception when others then perform t_record('the client source header no longer writes the log''s source', false, sqlerrm); end $$;
select set_config('request.headers', '', false);
select set_config('app.source', 'ops_assistant', false);
do $$ declare r jsonb; a audit_events; begin
  r := fn_create_voucher(jsonb_build_object('reservation_id', (select v from ids where k = 'res'), 'kind','receipt', 'received_confirmed',true, 'amount_halalas', 100, 'method','cash', 'idempotency_key','n7-src-2'));
  select * into a from audit_events where entity_id = (r->>'voucher_id')::uuid order by chain_seq desc limit 1;
  perform t_record('a trusted in-database source is still recorded', a.source = 'ops_assistant', a.source);
exception when others then perform t_record('a trusted in-database source is still recorded', false, sqlerrm); end $$;
select set_config('app.source', '', false);

-- the plan's acceptance: changing or deleting a row is refused even for the owner (a trigger, not only a policy)
do $$ declare msg text := 'accepted'; changed boolean; begin
  begin
    update audit_events set action = 'tampered' where organization_id = '00000000-0000-0000-0000-000000000001';
  exception when others then msg := sqlerrm; end;
  select exists(select 1 from audit_events where organization_id = '00000000-0000-0000-0000-000000000001' and action = 'tampered') into changed;
  perform t_record('the owner cannot change an audit row — the trigger refuses', not changed, coalesce(nullif(msg, 'accepted'), 'no row was changed'));
exception when others then perform t_record('the owner cannot change an audit row — the trigger refuses', false, sqlerrm); end $$;
do $$ declare msg text := 'accepted'; before int; after int; begin
  select count(*) into before from audit_events where organization_id = '00000000-0000-0000-0000-000000000001';
  begin
    delete from audit_events where organization_id = '00000000-0000-0000-0000-000000000001';
  exception when others then msg := sqlerrm; end;
  select count(*) into after from audit_events where organization_id = '00000000-0000-0000-0000-000000000001';
  perform t_record('the owner cannot delete an audit row — the trigger refuses', before = after, coalesce(nullif(msg, 'accepted'), 'count ' || before || ' -> ' || after));
exception when others then perform t_record('the owner cannot delete an audit row — the trigger refuses', false, sqlerrm); end $$;
reset role;
do $$ declare msg text := 'accepted'; begin
  begin
    delete from audit_events where organization_id = '00000000-0000-0000-0000-000000000001';
  exception when others then msg := sqlerrm; end;
  perform t_record('no role deletes from the log — even the superuser is refused', msg like 'AUDIT_IMMUTABLE%', msg);
exception when others then perform t_record('no role deletes from the log — even the superuser is refused', false, sqlerrm); end $$;

-- a row removed through the one sanctioned path (the purge's transaction-local setting) breaks the chain loudly
do $$ declare target uuid; begin
  select id into target from audit_events where organization_id = '00000000-0000-0000-0000-000000000001' order by chain_seq desc limit 1 offset 1;
  perform set_config('app.audit_purge', 'on', false);
  delete from audit_events where id = target;
  perform set_config('app.audit_purge', '', false);
end $$;
set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
do $$ declare v jsonb; begin
  v := fn_audit_chain_verify();
  perform t_record('a row removed later shows up at the next verification', not (v->>'ok')::boolean and v->>'reason' = 'link', v::text);
exception when others then perform t_record('a row removed later shows up at the next verification', false, sqlerrm); end $$;
reset role;

select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),110) as detail from test_results order by ok, name;
