-- Focused additive-provenance contract. Run after loading iso.branch_fields in a disposable local PG database.
-- Counts are matching JSON object occurrences, not unique rows or people. No application RPC is executed.
\set ON_ERROR_STOP on
begin;
do $$
begin
  assert iso.branch_fields(null, 'B2') = array[0,0], 'null input';
  assert iso.branch_fields('not json', 'B2') = array[0,0], 'malformed input';
  assert iso.branch_fields('42', 'B2') = array[0,0], 'scalar input';
  assert iso.branch_fields('{"branch_id":"B2"}', null) = array[0,0], 'missing target';
  assert iso.branch_fields('{"branch_id":"B2","branch_ids":["B2","B2"]}', 'B2') = array[1,0], 'one matching object, not three fields/elements';
  assert iso.branch_fields('[[{"branch_id":"B2"},[null,42,{"branch_ids":["B2"]}]]]', 'B2') = array[2,0], 'nested arrays traversed';
  assert iso.branch_fields('{"other_branch_id":"B2","branch_id":"B20","branch_ids":["B20"],"label":"B2"}', 'B2') = array[0,0], 'exact keys and values only';
  assert iso.branch_fields('[{"branch_id":null},{"branch_ids":[]},{"branch_ids":null},{"branch_ids":"B2"},{"branch_ids":7},{"branch_ids":{}},{"branch_ids":true}]', 'B2') = array[0,2], 'all nonarray branch_ids safe, only defined nullish shapes counted';
  assert iso.branch_fields('[{"id":1,"branch_id":"B2"},{"id":1,"branch_id":"B2"}]', 'B2') = array[2,0], 'duplicate object occurrence is not a unique row';
  assert iso.branch_fields('{"branch_id":null,"branch_ids":["B2"],"child":{"branch_ids":[]}}', 'B2') = array[1,2], 'structured and nullish signals can overlap';
end $$;
-- The additional JSON aggregate must not cause a second read execution, including for volatile reads.
create temporary sequence provenance_calls;
do $$
declare raw_text text; structured text; n bigint;
begin
  select coalesce(string_agg(x::text, ','), ''), coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb)::text
    into raw_text, structured
    from (select nextval('provenance_calls') as ordinal, 'B2'::text as branch_id from generate_series(1,3)) x;
  select last_value into n from provenance_calls;
  assert n = 3, 'one execution, not six calls';
  assert raw_text = '(1,B2),(2,B2),(3,B2)', 'raw composite marker representation unchanged';
  assert iso.branch_fields(structured, 'B2') = array[3,0], 'same execution structured results';
end $$;
rollback;
