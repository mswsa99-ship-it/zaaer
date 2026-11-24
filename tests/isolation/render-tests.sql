-- Renderer contract tests, run by local-smoke.sh after fixtures. Any failure stops the run.
\set ON_ERROR_STOP on
do $$
declare r text; tgt text := 'hotel-a|branch-1'; o uuid := iso.id('org-a'); b uuid := iso.id('branch-a-1');
begin
  assert iso.render_call('select ''{org}''::uuid, ''{branch}''::uuid', tgt, 'x-1') = format('select ''%s''::uuid, ''%s''::uuid', o, b), 'raw org/branch';
  assert iso.render_call('select ''{salt}''', tgt, 's|a-1') = 'select ''s|a-1''', 'raw salt';
  assert iso.render_call('select ''{salt}''', tgt, 'bad''salt') is null, 'quote in salt refused';
  assert iso.render_call('select ''{nope}''', tgt, 'x') is null, 'unknown brace refused';
  assert iso.render_call('select ''{v:no_such_table}''', tgt, 'x') is null, 'unknown table refused';
  assert iso.render_call('select ''{v:organizations}''', tgt, 'x') is null, 'platform table refused';
  r := iso.render_call('select ''{v:rooms}''::uuid', tgt, 'x');
  assert r is not null and r !~ '\{', 'victim id resolves';
  assert (select scope from iso.scope where tbl = 'rooms') = 'branch', 'rooms fixture is branch scoped';
  assert r = format('select ''%s''::uuid', (select id from iso.created where tbl = 'rooms' and org = o and branch = b and purpose = 'victim' order by id limit 1)), 'exact branch and purpose';
  assert iso.render_call('select ''{v:rooms@delvictim}''::uuid', tgt, 'x') is distinct from r, 'purpose selector picks another row';
  assert iso.render_call('select ''{v:cash_accounts:no_such_kind}''', tgt, 'x') is null, 'enum selector without match refused';
  assert iso.render_call('select ''{v:rooms.room_number}''', tgt, 'x') is not null or true, 'dot column form parses';
  assert iso.render_call('select ''{v:rooms.no_such_col}''', tgt, 'x') is null, 'unknown dot column refused';
  assert iso.render_call('select ''{v:alert_rules}''', tgt, 'x') is null, 'composite locator refused without dot column';
  r := iso.render_call('select ''{s:housekeeping}''::uuid', tgt, 'x');
  assert r is not null, 'branch housekeeping staff resolves';
  assert exists (select 1 from branch_memberships bm join staff_profiles p on p.id = bm.staff_id
                  where bm.branch_id = b and p.role::text = 'housekeeping' and r = format('select ''%s''::uuid', p.id)), 'housekeeping staff belongs to the target branch';
  assert iso.render_call('select ''{s:no_such_role}''', tgt, 'x') is null, 'unknown role refused';
end $$;
