-- 0128 candidate: inbox reply = view + add; take / reviews / review-reply / conversation update stay view + edit.
-- Run after the other suites on the same database (psql -d DB -f). Raises at the end on any failure or a wrong count.
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create or replace function t_login(p_uid uuid, p_email text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email)::text, false);
end $$;
create or replace function t_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;
-- tries to insert a supervisor reply; returns ok / the error text
create or replace function t_reply(p_conv uuid) returns text language plpgsql as $$
begin
  insert into conversation_messages(conversation_id, organization_id, sender, content) values (p_conv, '00000000-0000-0000-0000-000000000001', 'supervisor', 'O2 test');
  return 'ok';
exception when others then return left(sqlerrm, 60); end $$;
create or replace function t_take(p_conv uuid) returns text language plpgsql as $$
begin perform fn_conversation_take(p_conv, true); return 'ok'; exception when others then return left(sqlerrm, 60); end $$;
-- the review functions: FORBIDDEN means the capability gate refused; anything else means it passed
create or replace function t_reviews() returns text language plpgsql as $$
begin perform fn_staff_reviews('00000000-0000-0000-0000-000000000010', 30); return 'ok'; exception when others then return left(sqlerrm, 60); end $$;
create or replace function t_rreply() returns text language plpgsql as $$
begin perform fn_staff_review_reply('2b000000-0000-0000-0000-0000000000ff', 'x', 1); return 'ok'; exception when others then return left(sqlerrm, 60); end $$;
-- (staff_conv_update is not exercisable directly: authenticated holds UPDATE only on conversations.id, and the policy reads organization_id; the update path is fn_conversation_take, tested below)
create or replace function t_upd(p_conv uuid) returns int language plpgsql as $$
declare n int; begin update conversations set id = id where id = p_conv; get diagnostics n = row_count; return n; end $$;
create or replace function t_msgs(p_conv uuid) returns int language sql security definer as $$ select count(*)::int from conversation_messages where conversation_id = p_conv and content = 'O2 test' $$;

create or replace function t_rreply_real(p_expected int) returns text language plpgsql as $$
begin perform fn_staff_review_reply('2c000000-0000-0000-0000-000000000001', 'شكرا O2', p_expected); return 'ok'; exception when others then return left(sqlerrm, 60); end $$;
create or replace function t_review_state() returns table(reply text, version int) language sql security definer as $$ select g.reply, g.version from guest_reviews g where g.id = '2c000000-0000-0000-0000-000000000001' $$;
insert into staff_profiles(id, auth_user_id, organization_id, full_name, email, role) values
 ('2a000000-0000-0000-0000-000000000001','cb000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','o2 legacy manager','o2lm@test.local','manager'),
 ('2a000000-0000-0000-0000-000000000002','cb000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001','o2 legacy housekeeping','o2lh@test.local','housekeeping'),
 ('2a000000-0000-0000-0000-000000000003','cb000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000001','o2 view','o2v@test.local','manager'),
 ('2a000000-0000-0000-0000-000000000004','cb000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000001','o2 view add','o2va@test.local','manager'),
 ('2a000000-0000-0000-0000-000000000005','cb000000-0000-0000-0000-000000000005','00000000-0000-0000-0000-000000000001','o2 view edit','o2ve@test.local','manager'),
 ('2a000000-0000-0000-0000-000000000006','cb000000-0000-0000-0000-000000000006','00000000-0000-0000-0000-000000000001','o2 view add edit','o2vae@test.local','manager'),
 ('2a000000-0000-0000-0000-000000000007','cb000000-0000-0000-0000-000000000007','00000000-0000-0000-0000-000000000001','o2 add edit no view','o2ae@test.local','manager'),
 ('2a000000-0000-0000-0000-000000000008','cb000000-0000-0000-0000-000000000008','00000000-0000-0000-0000-000000000001','o2 hk view add','o2hva@test.local','housekeeping'),
 ('2a000000-0000-0000-0000-000000000009','cb000000-0000-0000-0000-000000000009','00000000-0000-0000-0000-000000000001','o2 disabled row hk','o2dis@test.local','housekeeping'),
 ('2a000000-0000-0000-0000-00000000000a','cb000000-0000-0000-0000-00000000000a','00000000-0000-0000-0000-000000000001','o2 other branch view add edit','o2ob@test.local','manager')
on conflict (id) do nothing;
insert into branch_memberships(staff_id, branch_id, organization_id)
 select s, '00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001'
 from unnest(array['2a000000-0000-0000-0000-000000000001','2a000000-0000-0000-0000-000000000002','2a000000-0000-0000-0000-000000000003','2a000000-0000-0000-0000-000000000004','2a000000-0000-0000-0000-000000000005','2a000000-0000-0000-0000-000000000006','2a000000-0000-0000-0000-000000000007','2a000000-0000-0000-0000-000000000008','2a000000-0000-0000-0000-000000000009']::uuid[]) s;
insert into staff_page_access(staff_id, organization_id, enabled, page_grants) values
 ('2a000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000001',true,'{"/staff/inbox":{"view":true,"add":false,"edit":false,"delete":false}}'),
 ('2a000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000001',true,'{"/staff/inbox":{"view":true,"add":true,"edit":false,"delete":false}}'),
 ('2a000000-0000-0000-0000-000000000005','00000000-0000-0000-0000-000000000001',true,'{"/staff/inbox":{"view":true,"add":false,"edit":true,"delete":false}}'),
 ('2a000000-0000-0000-0000-000000000006','00000000-0000-0000-0000-000000000001',true,'{"/staff/inbox":{"view":true,"add":true,"edit":true,"delete":false}}'),
 ('2a000000-0000-0000-0000-000000000007','00000000-0000-0000-0000-000000000001',true,'{"/staff/inbox":{"view":false,"add":true,"edit":true,"delete":false}}'),
 ('2a000000-0000-0000-0000-000000000008','00000000-0000-0000-0000-000000000001',true,'{"/staff/inbox":{"view":true,"add":true,"edit":false,"delete":false}}'),
 ('2a000000-0000-0000-0000-000000000009','00000000-0000-0000-0000-000000000001',false,'{"/staff/inbox":{"view":true,"add":true,"edit":true,"delete":false}}'),
 ('2a000000-0000-0000-0000-00000000000a','00000000-0000-0000-0000-000000000001',true,'{"/staff/inbox":{"view":true,"add":true,"edit":true,"delete":false}}')
on conflict do nothing;
insert into conversations(id, organization_id, branch_id) values
 ('2b000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010'),
 ('2b000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010'),
 ('2b000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010') on conflict do nothing;
-- the conversation of a branch the "other branch" account does not belong to is conversation 1 (account 0a has no membership)

insert into staff_profiles(id, auth_user_id, organization_id, full_name, email, role) values
 ('2a000000-0000-0000-0000-00000000000b','cb00000b-0000-0000-0000-00000000000b','00000000-0000-0000-0000-000000000001','o2 owner','o2own@test.local','owner')
on conflict (id) do nothing;
insert into conversations(id, organization_id, branch_id) values
 ('2b000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000011') on conflict do nothing;
insert into guest_reviews(id, organization_id, branch_id, reservation_id, token_hash, submitted_at, overall, staff, cleanliness, comfort, facilities, value, location)
 values ('2c000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010','8b66382d-e0cb-477b-989b-e5100c5527a8','o2-review-token-hash-1', now(), 4,4,4,4,4,4,4) on conflict do nothing;

set role authenticated;
do $$
declare
  c uuid := '2b000000-0000-0000-0000-000000000001';
  -- (login, label, expected reply, expected take, expected reviews/reply gate passes, expected update rows)
  r record; got text; n int := 0;
begin
  for r in select * from (values
    ('cb000000-0000-0000-0000-000000000001','o2lm@test.local','legacy manager','ok','ok',true),
    ('cb000000-0000-0000-0000-000000000002','o2lh@test.local','legacy housekeeping','denied','denied',false),
    ('cb000000-0000-0000-0000-000000000009','o2dis@test.local','disabled row housekeeping = legacy','denied','denied',false),
    ('cb000000-0000-0000-0000-000000000003','o2v@test.local','individual view only','denied','denied',false),
    ('cb000000-0000-0000-0000-000000000004','o2va@test.local','individual view+add','ok','denied',false),
    ('cb000000-0000-0000-0000-000000000005','o2ve@test.local','individual view+edit','denied','ok',true),
    ('cb000000-0000-0000-0000-000000000006','o2vae@test.local','individual view+add+edit','ok','ok',true),
    ('cb000000-0000-0000-0000-000000000007','o2ae@test.local','individual add+edit, no view','denied','denied',false),
    ('cb000000-0000-0000-0000-000000000008','o2hva@test.local','individual housekeeping view+add','ok','denied',false)
  ) v(uid,mail,lbl,exp_reply,exp_take,exp_upd) loop
    perform t_login(r.uid::uuid, r.mail);
    got := t_reply(c);
    n := n + 1;
    perform t_record('O2-' || n || ' reply insert: ' || r.lbl || ' expects ' || r.exp_reply, (got = 'ok') = (r.exp_reply = 'ok'), got);
    got := t_take(c);
    n := n + 1;
    perform t_record('O2-' || n || ' take: ' || r.lbl || ' expects ' || r.exp_take, (got = 'ok') = (r.exp_take = 'ok'), got);
    got := t_reviews();
    n := n + 1;
    perform t_record('O2-' || n || ' reviews read gate: ' || r.lbl || ' expects ' || r.exp_take, (got like 'FORBIDDEN%') = (r.exp_take = 'denied'), got);
    got := t_rreply();
    n := n + 1;
    perform t_record('O2-' || n || ' review reply gate: ' || r.lbl || ' expects ' || r.exp_take, (got like 'FORBIDDEN%') = (r.exp_take = 'denied'), got);
  end loop;
end $$;
-- the other-branch account (no membership in the conversation's branch): branch check holds even with full grants
select t_login('cb000000-0000-0000-0000-00000000000a'::uuid, 'o2ob@test.local');
do $$ begin
  perform t_record('O2-b1 individual view+add+edit without membership in the conversation branch: reply refused',
    t_reply('2b000000-0000-0000-0000-000000000003') <> 'ok', t_reply('2b000000-0000-0000-0000-000000000003'));
end $$;
-- sender stays fixed to supervisor: an add-only account cannot write a guest/assistant message
select t_login('cb000000-0000-0000-0000-000000000004'::uuid, 'o2va@test.local');
do $$ declare g text; begin
  begin insert into conversation_messages(conversation_id, organization_id, sender, content) values ('2b000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','guest','O2 test guest'); g := 'ok';
  exception when others then g := left(sqlerrm,60); end;
  perform t_record('O2-s1 add-only account cannot insert sender=guest', g <> 'ok', g);
end $$;
-- owner control (legacy-style owner row with no page grants) and cross-org / org-mismatch controls
select t_login('cb00000b-0000-0000-0000-00000000000b'::uuid, 'o2own@test.local');
do $$ declare g text; begin
  g := t_reply('2b000000-0000-0000-0000-000000000001'); perform t_record('O2-o1 owner: reply insert ok', g = 'ok', g);
  g := t_take('2b000000-0000-0000-0000-000000000001'); perform t_record('O2-o2 owner: take ok', g = 'ok', g);
  g := t_reply('2b000000-0000-0000-0000-000000000004'); perform t_record('O2-o3 owner: reply to a conversation of another organization refused (TENANT trigger fires before the policy check, so this refusal is attributed to the trigger)', g <> 'ok', g);
end $$;
select t_login('cb000000-0000-0000-0000-000000000006'::uuid, 'o2vae@test.local');
do $$ declare g text; begin
  perform t_record('O2-x1 individual view+add+edit: reply to a conversation of another organization refused', t_reply('2b000000-0000-0000-0000-000000000004') <> 'ok', t_reply('2b000000-0000-0000-0000-000000000004'));
  begin insert into conversation_messages(conversation_id, organization_id, sender, content) values ('2b000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002','supervisor','O2 test'); g := 'ok';
  exception when others then g := left(sqlerrm,60); end;
  perform t_record('O2-x2 individual view+add+edit: row stamped with another organization on an own conversation refused', g <> 'ok', g);
  perform t_record('O2-x3 individual view+add+edit: take on a conversation of another organization refused', t_take('2b000000-0000-0000-0000-000000000004') <> 'ok', t_take('2b000000-0000-0000-0000-000000000004'));
end $$;
-- positive review reply write (view+edit account) and the add-only refusal at the same gate
select t_login('cb000000-0000-0000-0000-000000000004'::uuid, 'o2va@test.local');
do $$ begin
  perform t_record('O2-r1 review reply by a view+add (no edit) account is refused FORBIDDEN and writes nothing', t_rreply_real(1) like 'FORBIDDEN%' and (select reply from t_review_state()) is null, t_rreply_real(1));
end $$;
select t_login('cb000000-0000-0000-0000-000000000005'::uuid, 'o2ve@test.local');
do $$ declare r text; begin
  r := t_rreply_real(1);
  perform t_record('O2-r2 review reply by a view+edit account succeeds', r = 'ok', r);
  perform t_record('O2-r3 the reply and its version bump are stored', (select reply from t_review_state()) = 'شكرا O2' and (select version from t_review_state()) = 2, (select reply || ' v' || version from t_review_state()));
end $$;
reset role;
do $$ begin
  perform t_record('O2-m1 stored replies: exactly the accounts that expected ok left one row each on conversation 1 (4 accounts expect ok, plus the owner)', t_msgs('2b000000-0000-0000-0000-000000000001') = 5, t_msgs('2b000000-0000-0000-0000-000000000001')::text);
end $$;
-- recorded (not asserted): the grants and policies the checks above ran against
select 'GRANTS conversations UPDATE columns' as what, coalesce(string_agg(column_name, ',' order by column_name), '') as value from information_schema.column_privileges where table_name = 'conversations' and grantee = 'authenticated' and privilege_type = 'UPDATE'
union all select 'GRANTS conversation_messages INSERT columns', string_agg(column_name, ',' order by column_name) from information_schema.column_privileges where table_name = 'conversation_messages' and grantee = 'authenticated' and privilege_type = 'INSERT'
union all select 'POLICY ' || policyname || ' ' || cmd, coalesce(qual, '') || ' || ' || coalesce(with_check, '') from pg_policies where tablename in ('conversations','conversation_messages');
select name, case when ok then 'PASS' else 'FAIL' end as result, coalesce(detail,'') as detail from test_results order by ctid;
\set ON_ERROR_STOP on
do $$ begin
  if (select count(*) from test_results where ok) <> 48 or exists (select 1 from test_results where ok is not true) then raise exception 'INBOX 0128 TESTS FAILED OR INCOMPLETE'; end if;
end $$;
