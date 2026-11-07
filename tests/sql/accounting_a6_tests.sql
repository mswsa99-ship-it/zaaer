-- =====================================================================
-- Accounting stage, tasks A6 and A7 (BK*; migration 0066): the bank's messages by mail. The raw text is kept first; the
-- same message twice is one message and one movement; only the app's mail, signed with its key, from an allowed bank
-- sender, is read; every kind of movement is read with its amount, direction and the branch account its digits fit.
-- Tried from outside the screens. The messages are invented for the test (no real account or person).
-- =====================================================================
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create temp table ids(k text primary key, v uuid);
grant all on ids to public;
create temp table keys(k text primary key, v text);
grant all on keys to public;
create or replace function t_login(p_uid uuid, p_email text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email)::text, false);
end $$;
create or replace function t_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;
create or replace function t_id(p_k text) returns uuid language sql security definer as $$ select v from ids where k = p_k $$;
create or replace function t_fails(p_sql text, p_like text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'accepted';
exception when others then
  return case when sqlerrm like p_like then 'ok' else sqlerrm end;
end $$;
create or replace function t_count(p_sql text) returns bigint language plpgsql security definer as $$ declare n bigint; begin execute p_sql into n; return n; end $$;
create or replace function t_accid(p_branch uuid, p_kind text) returns uuid language sql security definer as $$
  select id from cash_accounts where branch_id = p_branch and kind = p_kind and archived_at is null $$;
-- the email the phone app sends: its header, its signature with the relay key, the text
create or replace function t_relay(p_text text, p_sender text default 'AlRajhiBank', p_channel text default 'sms', p_received text default '2026-11-07T21:00:00+03:00', p_key text default null)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare k text := coalesce(p_key, (select v from keys where k = 'relay'));
begin
  return 'FIVEHOURS-RELAY 1' || E'\n' || 'sender: ' || p_sender || E'\n' || 'received: ' || p_received || E'\n' || 'channel: ' || p_channel || E'\n' ||
         'signature: ' || encode(hmac(convert_to(p_sender || E'\n' || p_received || E'\n' || p_channel || E'\n' || p_text, 'UTF8'), convert_to(k, 'UTF8'), 'sha256'), 'hex') ||
         E'\n---\n' || p_text;
end $$;
-- one email as the edge function hands it over (service role)
create or replace function t_ingest(p_body text, p_from text default 'Bank Relay <relay.test@example.com>') returns jsonb language plpgsql as $$
declare r jsonb;
begin
  set local role service_role;
  r := fn_bank_ingest(jsonb_build_object('message_id', '<' || md5(p_body || clock_timestamp()::text) || '@example.com>', 'from', p_from, 'date', '2026-11-07T18:00:00Z', 'subject', 'relay', 'body', p_body));
  reset role;
  return r;
end $$;
create or replace function t_mv(p jsonb) returns bank_movements language sql security definer as $$ select * from bank_movements where id = (p->>'movement_id')::uuid $$;

-- ---------------------------------------------------------------- BK01 the matrix
select t_record('BK01 the permissions matrix has «bank.view» (owner, manager, finance) and «bank.manage» (owner)',
  (select count(*) from fn_permission_catalog()) = 64
  and exists (select 1 from fn_permission_catalog() c where c.code = 'bank.view' and c.default_roles = '{owner,manager,finance}')
  and exists (select 1 from fn_permission_catalog() c where c.code = 'bank.manage' and c.default_roles = '{owner}'));

-- ---------------------------------------------------------------- two branches whose bank accounts share an ending
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; b1 uuid; b2 uuid; begin
  r := fn_admin_upsert_branch('{"name_ar":"فرع البنك أ","name_en":"Bank A","tax_rate_bp":0}'); b1 := (r->>'id')::uuid;
  r := fn_admin_upsert_branch('{"name_ar":"فرع البنك ب","name_en":"Bank B","tax_rate_bp":0}'); b2 := (r->>'id')::uuid;
  insert into ids values ('b1', b1), ('b2', b2);
exception when others then perform t_record('BK00 the branches are set up', false, sqlerrm);
end $$;
reset role;
update cash_accounts set account_prefix = '605', account_suffix = '192' where id = t_accid(t_id('b1'), 'bank_account');
update cash_accounts set account_prefix = '346', account_suffix = '192' where id = t_accid(t_id('b2'), 'bank_account');

-- ---------------------------------------------------------------- BK02 the settings: the owner's, no secret leaves
select t_login('a0000000-0000-0000-0000-000000000008', 'manager@test.local');
set role authenticated;
select t_record('BK02a the manager cannot read or change the bank mailbox', t_fails('select fn_admin_bank_mail_get()', 'FORBIDDEN%') = 'ok'
  and t_fails('select fn_admin_bank_mail_set(''{"version":1,"enabled":false}''::jsonb)', 'FORBIDDEN%') = 'ok');
reset role;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare g jsonb; r jsonb; early text; bad text; again jsonb; begin
  g := fn_admin_bank_mail_get();
  early := t_fails(format('select fn_admin_bank_mail_set(%L::jsonb)', jsonb_build_object('version', (g->>'version')::int, 'enabled', true)), 'VALIDATION: bank_mail_incomplete%');
  bad := t_fails(format('select fn_admin_bank_mail_set(%L::jsonb)', jsonb_build_object('version', (g->>'version')::int, 'mailbox_address', 'not-an-address')), 'VALIDATION: mailbox_address%');
  r := fn_admin_bank_mail_set(jsonb_build_object('version', (g->>'version')::int, 'mailbox_address', 'Relay.Test@example.com', 'imap_user', 'relay.test@example.com',
         'password', 'app-password-for-test', 'new_relay_key', true));
  insert into keys values ('relay', r->>'relay_key');
  again := fn_admin_bank_mail_get();
  r := fn_admin_bank_mail_set(jsonb_build_object('version', (again->>'version')::int, 'enabled', true));
  g := fn_admin_bank_mail_get();
  perform t_record('BK02 the owner sets the mailbox, its password and a relay key (shown once); the settings never show the password or the key, the log names the fields only; it cannot be switched on incomplete',
    early = 'ok' and bad = 'ok' and length((select v from keys where k = 'relay')) = 48 and g->>'state' = 'on' and (g->>'has_password')::boolean
    and g->>'mailbox_address' = 'relay.test@example.com' and g::text not like '%app-password-for-test%' and g::text not like '%' || (select v from keys where k = 'relay') || '%'
    and t_count('select count(*) from audit_events where action = ''bank_mail.settings_changed'' and (details::text like ''%app-password-for-test%'' or details::text like ''%' || (select v from keys where k = 'relay') || '%'')') = 0
    and t_count('select count(*) from audit_events where action = ''bank_mail.settings_changed''') >= 2,
    concat_ws(' / ', early, bad, g->>'state'));
exception when others then perform t_record('BK02 the owner sets the mailbox, its password and a relay key (shown once); the settings never show the password or the key, the log names the fields only; it cannot be switched on incomplete', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- BK03 raw first; the same message twice is one
do $$ declare txt text := E'حوالة واردة\nمبلغ: 1,250.50 SAR\nإلى: 605*****192\nمن: عميل\nالرصيد: 9,000 SAR\nرقم المرجع: TR77001\n07/11/26 20:15';
              r1 jsonb; r2 jsonb; m bank_movements; begin
  r1 := t_ingest(t_relay(txt));
  r2 := t_ingest(t_relay(txt));
  m := t_mv(r1);
  insert into ids values ('mv1', m.id);
  perform t_record('BK03 a relayed message is kept raw, read once into one movement (amount, direction, account, reference, balance, time); the same message again is the same message, no second movement',
    r1->>'status' = 'parsed' and (r2->>'duplicate')::boolean
    and m.kind = 'transfer_in' and m.direction = 'in' and m.amount_halalas = 125050 and m.cash_account_id = t_accid(t_id('b1'), 'bank_account') and m.branch_id = t_id('b1')
    and m.reference = 'TR77001' and m.balance_halalas = 900000 and m.occurred_at = '2026-11-07 20:15:00+03'::timestamptz
    and t_count(format('select count(*) from bank_messages where sms_text = %L', txt)) = 1 and t_count('select count(*) from bank_movements where reference = ''TR77001''') = 1
    and (select raw_body from bank_messages where id = (r1->>'message_id')::uuid) like 'FIVEHOURS-RELAY 1%',
    concat_ws(' / ', r1::text, r2::text));
exception when others then perform t_record('BK03 a relayed message is kept raw, read once into one movement (amount, direction, account, reference, balance, time); the same message again is the same message, no second movement', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- BK04 only the app's mail
do $$ declare txt text := E'إيداع\nمبلغ: 300 SAR\nحساب: 605*****192\n07/11/26 19:00'; a jsonb; b jsonb; c jsonb; d jsonb; e jsonb; begin
  a := t_ingest(t_relay(txt), 'Someone <someone@example.org>');
  b := t_ingest(t_relay(txt || E'\n') || 'x');            -- a line added after signing: the signature no longer fits
  c := t_ingest(t_relay(txt || E'\nرسالة ثانية', 'FakeBank'));
  d := t_ingest(E'إيداع\nمبلغ: 300 SAR', 'relay.test@example.com');
  e := t_ingest(t_relay(txt || E'\nمفتاح آخر', 'AlRajhiBank', 'sms', '2026-11-07T21:00:00+03:00', 'not-the-key'));
  perform t_record('BK04 mail from another address, without the app''s format, with a wrong signature or from a sender not allowed is kept raw as «rejected» with its reason, and makes no movement',
    a->>'status' = 'rejected' and a->>'reason' = 'ليست من بريد التطبيق' and c->>'reason' like 'مرسل غير مسموح%' and d->>'reason' = 'ليست بصيغة تطبيق الجوال'
    and e->>'reason' = 'توقيع التطبيق غير صحيح' and b->>'status' = 'rejected'
    and t_count('select count(*) from bank_movements where amount_halalas = 30000') = 0
    and t_count('select count(*) from bank_messages where status = ''rejected''') >= 5,
    concat_ws(' / ', a->>'reason', b->>'reason', c->>'reason', d->>'reason', e->>'reason'));
exception when others then perform t_record('BK04 mail from another address, without the app''s format, with a wrong signature or from a sender not allowed is kept raw as «rejected» with its reason, and makes no movement', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- BK05 every kind of movement
do $$ declare k text; r jsonb; m bank_movements; bad text := ''; n int := 0;
  cases text[][] := array[
    array[E'إيداع نقدي\nمبلغ: 2000 SAR\nحساب: 605*****192\n07/11/26 10:01', 'deposit', 'in', '200000'],
    array[E'حوالة صادرة\nمبلغ: 450 SAR\nمن: 605*****192\nإلى: مورد\n07/11/26 10:02', 'transfer_out', 'out', '45000'],
    array[E'سحب صراف\nمبلغ: ٥٠٠ ر.س\nحساب: 605*****192\n07/11/26 10:03', 'withdrawal', 'out', '50000'],
    array[E'خصم رسوم\nمبلغ: 5.75 SAR\nحساب: 605*****192\n07/11/26 10:04', 'fee', 'out', '575'],
    array[E'رسوم نقاط البيع\nمبلغ: 12.30 SAR\nحساب: 605*****192\n07/11/26 10:05', 'pos_fee', 'out', '1230'],
    array[E'تسوية نقاط البيع\nمبلغ: 3,410.00 SAR\nحساب: 605*****192\nالرصيد: 20,000 SAR\n07/11/26 10:06', 'pos_settlement', 'in', '341000'],
    array[E'Incoming transfer\nAmount: SAR 99.90\nTo: 605*****192\nRef: INC5521\n07/11/26 10:07', 'transfer_in', 'in', '9990']];
  i int; begin
  for i in 1 .. array_length(cases, 1) loop
    r := t_ingest(t_relay(cases[i][1]));
    m := t_mv(r); n := n + 1;
    if m.kind is distinct from cases[i][2] or m.direction is distinct from cases[i][3] or m.amount_halalas::text is distinct from cases[i][4] or m.branch_id is distinct from t_id('b1') then
      bad := bad || cases[i][2] || '→' || coalesce(m.kind, r->>'status') || ':' || coalesce(m.amount_halalas::text, '-') || ' ';
    end if;
  end loop;
  perform t_record('BK05 every kind is read with its amount and direction and its branch: deposit, outgoing transfer, withdrawal (Arabic digits), fees, POS fees, POS settlement (its balance not taken for the amount), incoming transfer in English',
    bad = '' and n = 7, bad);
exception when others then perform t_record('BK05 every kind is read with its amount and direction and its branch: deposit, outgoing transfer, withdrawal (Arabic digits), fees, POS fees, POS settlement (its balance not taken for the amount), incoming transfer in English', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- BK06 the account rule; BK07 SMS + notification once
do $$ declare a jsonb; b jsonb; c jsonb; begin
  a := t_ingest(t_relay(E'إيداع\nمبلغ: 610 SAR\nحساب: 346****0192\n07/11/26 11:00'));
  b := t_ingest(t_relay(E'إيداع\nمبلغ: 620 SAR\nحساب: **192\n07/11/26 11:01'));
  c := t_ingest(t_relay(E'إيداع\nمبلغ: 630 SAR\nحساب: 777****555\n07/11/26 11:02'));
  perform t_record('BK06 the digits are matched with each branch''s rule (starts with … ends with …): 346…0192 is the second branch (and not an account ending 1192); an ending two accounts share (…192) or digits of no account stay unassigned for the owner',
    (t_mv(a)).branch_id = t_id('b2') and (t_mv(a)).cash_account_id = t_accid(t_id('b2'), 'bank_account')
    and (t_mv(b)).branch_id is null and (t_mv(b)).account_hint = '**192' and (t_mv(c)).branch_id is null and (t_mv(c)).status = 'pending',
    concat_ws(' / ', (t_mv(a)).branch_id::text, (t_mv(b)).account_hint, (t_mv(c)).account_hint));
exception when others then perform t_record('BK06 the digits are matched with each branch''s rule (starts with … ends with …): 346…0192 is the second branch (and not an account ending 1192); an ending two accounts share (…192) or digits of no account stay unassigned for the owner', false, sqlerrm);
end $$;
do $$ declare s jsonb; n jsonb; begin
  s := t_ingest(t_relay(E'حوالة واردة\nمبلغ: 875 SAR\nإلى: 605*****192\nرقم المرجع: TR88002\n07/11/26 12:30'));
  n := t_ingest(t_relay(E'الراجحي: حوالة واردة بمبلغ 875.00 ر.س إلى حسابك 605*****192 المرجع TR88002', 'AlRajhiBank', 'notification', '2026-11-07T12:30:40+03:00'));
  perform t_record('BK07 the SMS and the notification of the same movement (another wording, the same account, amount and reference) make one movement; the second message points to it',
    s->>'status' = 'parsed' and n->>'status' = 'duplicate_movement' and n->>'movement_id' = s->>'movement_id'
    and t_count('select count(*) from bank_movements where reference = ''TR88002''') = 1, concat_ws(' / ', s::text, n::text));
exception when others then perform t_record('BK07 the SMS and the notification of the same movement (another wording, the same account, amount and reference) make one movement; the second message points to it', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- BK08 unread → a rule → read again
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
do $$ declare u jsonb; r jsonb; again text; mid uuid; begin
  u := t_ingest(t_relay(E'قيد عكسي\nمبلغ: 40 SAR\nحساب: 605*****192\n07/11/26 13:00'));
  mid := (u->>'message_id')::uuid;
  set local role authenticated;
  perform fn_admin_upsert_bank_rule(jsonb_build_object('keyword', 'قيد عكسي', 'kind', 'other_in', 'priority', 5));
  r := fn_bank_reparse(mid);
  again := t_fails(format('select fn_bank_reparse(%L)', mid), 'VALIDATION: message_status%');
  reset role;
  perform t_record('BK08 a message no rule reads stays «unparsed» (kept, no movement); after the owner adds a word it is read again into its movement, once',
    u->>'status' = 'unparsed' and r->>'status' = 'parsed' and again = 'ok' and (select kind from bank_movements where id = (r->>'movement_id')::uuid) = 'other_in',
    concat_ws(' / ', u::text, r::text, again));
exception when others then perform t_record('BK08 a message no rule reads stays «unparsed» (kept, no movement); after the owner adds a word it is read again into its movement, once', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- BK09 who reads what
insert into branch_memberships(staff_id, branch_id) select s, t_id('b1') from unnest(array['10000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000004']::uuid[]) s
  where not exists (select 1 from branch_memberships where staff_id = s and branch_id = t_id('b1'));
select t_login('a0000000-0000-0000-0000-000000000004', 'fin@test.local');
set role authenticated;
do $$ declare l jsonb; r1 text; r2 text; r3 text; begin
  l := fn_bank_movements(t_id('b1'), '2026-11-01', '2026-11-30');
  r1 := t_fails(format('select fn_bank_movements(null, %L, %L)', '2026-11-01', '2026-11-30'), 'FORBIDDEN%');
  r2 := t_fails('select fn_bank_messages(null, 10)', 'FORBIDDEN%');
  r3 := t_fails(format('select fn_bank_ingest(%L::jsonb)', jsonb_build_object('body', 'x')), '%permission denied%');
  perform t_record('BK09 finance reads its branch''s movements, not the unassigned ones, not the raw messages, and cannot hand in a message itself',
    jsonb_array_length(l) >= 8 and r1 = 'ok' and r2 = 'ok' and r3 = 'ok' and (select count(*) from bank_messages) = 0
    and (select count(*) from bank_movements where branch_id is null) = 0, concat_ws(' / ', jsonb_array_length(l), r1, r2, r3));
exception when others then perform t_record('BK09 finance reads its branch''s movements, not the unassigned ones, not the raw messages, and cannot hand in a message itself', false, sqlerrm);
end $$;
reset role;
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
set role authenticated;
select t_record('BK10 the supervisor reads no bank movement', t_fails(format('select fn_bank_movements(%L, %L, %L)', t_id('b1'), '2026-11-01', '2026-11-30'), 'FORBIDDEN%') = 'ok'
  and (select count(*) from bank_movements) = 0);
reset role;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
select t_record('BK11 anyone signed in cannot read the mailbox''s password through the poll config or record a poll',
  t_fails('select fn_bank_mail_poll_config()', '%permission denied%') = 'ok' and t_fails('select fn_bank_mail_poll_done(5, 1, null)', '%permission denied%') = 'ok');
reset role;
do $$ declare c jsonb; begin
  set local role service_role;
  c := fn_bank_mail_poll_config();
  perform fn_bank_mail_poll_done(42, 7, null);
  reset role;
  perform t_record('BK12 the edge function (service role) reads the mailbox settings with the password, and the poll moves the last message read forward',
    (c->>'configured')::boolean and c->>'password' = 'app-password-for-test' and c->>'user' = 'relay.test@example.com'
    and (select last_uid from bank_mail_settings limit 1) = 42 and (select uid_validity from bank_mail_settings limit 1) = 7, c->>'configured');
exception when others then perform t_record('BK12 the edge function (service role) reads the mailbox settings with the password, and the poll moves the last message read forward', false, sqlerrm);
end $$;
-- ---------------------------------------------------------------- BK14–BK19 what the review found
do $$ declare a jsonb; b jsonb; c jsonb; d jsonb; e jsonb; f jsonb; begin
  a := t_ingest(t_relay(E'حوالة داخلية واردة\nمبلغ: 500 SAR\nإلى: 605*****192\nالرسوم: 0\n2026-11-07 14:30'));
  b := t_ingest(t_relay(E'استرداد عملية شراء\nمبلغ: 75 SAR\nحساب: 605*****192\n07/11/26 15:00'));
  c := t_ingest(t_relay(E'إيداع\nرصيدك 9,000 SAR\nأُودع 100 SAR في 605*****192\n07/11/26 15:10'));
  d := t_ingest(t_relay(E'إيداع\nمبلغ: 130 SAR\nللاستفسار 0551234567\n07/11/26 15:20'));
  e := t_ingest(t_relay(E'Deposit preferred customer\nAmount: SAR 140\nAcc: 605*****192\n07/11/26 15:30'));
  f := t_ingest(t_relay(E'إيداع\nمبلغ: 150 SAR\nحساب: 605*****192\n01/01/20 10:00'));
  perform t_record('BK14 the review''s messages: a «حوالة داخلية واردة» with a zero fee is an incoming transfer; a refund of a purchase is money in; the balance (رصيدك) is not the amount; a phone number is not an account; «preferred» is no reference; a year-first date is read as such; a date far from the phone''s is not trusted',
    (t_mv(a)).kind = 'transfer_in' and (t_mv(a)).amount_halalas = 50000 and (t_mv(a)).occurred_at = '2026-11-07 14:30:00+03'::timestamptz
    and (t_mv(b)).direction = 'in' and (t_mv(c)).amount_halalas = 10000 and (t_mv(c)).balance_halalas = 900000
    and (t_mv(d)).account_hint is null and (t_mv(e)).reference is null and (t_mv(f)).occurred_at = '2026-11-07 21:00:00+03'::timestamptz,
    concat_ws(' / ', (t_mv(a)).kind, (t_mv(b)).kind, (t_mv(c)).amount_halalas, (t_mv(d)).account_hint, (t_mv(e)).reference, (t_mv(f)).occurred_at));
exception when others then perform t_record('BK14 the review''s messages: a «حوالة داخلية واردة» with a zero fee is an incoming transfer; a refund of a purchase is money in; the balance (رصيدك) is not the amount; a phone number is not an account; «preferred» is no reference; a year-first date is read as such; a date far from the phone''s is not trusted', false, sqlerrm);
end $$;
do $$ declare s1 jsonb; n1 jsonb; u1 jsonb; u2 jsonb; k1 jsonb; k2 jsonb; begin
  s1 := t_ingest(t_relay(E'حوالة واردة\nمبلغ: 333 SAR\nإلى: 605*****192\nرقم المرجع: TR99003\n07/11/26 16:00'));
  n1 := t_ingest(t_relay(E'حوالة واردة بمبلغ 333 ر.س إلى حسابك 605*****192', 'AlRajhiBank', 'notification', '2026-11-07T16:01:10+03:00'));
  u1 := t_ingest(t_relay(E'رسوم\nمبلغ: 3 SAR\nحساب: **192\n07/11/26 16:10'));
  u2 := t_ingest(t_relay(E'رسوم خدمة\nمبلغ: 3 SAR\nحساب: **192\n07/11/26 16:10'));
  k1 := t_ingest(t_relay(E'رسوم\nمبلغ: 4 SAR\nحساب: 605*****192\n07/11/26 16:20'));
  k2 := t_ingest(t_relay(E'شراء\nمبلغ: 4 SAR\nحساب: 605*****192\n07/11/26 16:20'));
  perform t_record('BK15 one movement told twice: the SMS with a reference and the notification without one a minute later are one; two unassigned movements (they could be two branches'') are never merged; a fee and a purchase of the same amount and minute are two',
    n1->>'status' = 'duplicate_movement' and n1->>'movement_id' = s1->>'movement_id'
    and u1->>'status' = 'parsed' and u2->>'status' = 'parsed' and u1->>'movement_id' <> u2->>'movement_id'
    and k1->>'status' = 'parsed' and k2->>'status' = 'parsed', concat_ws(' / ', n1->>'status', u2->>'status', k2->>'status'));
exception when others then perform t_record('BK15 one movement told twice: the SMS with a reference and the notification without one a minute later are one; two unassigned movements (they could be two branches'') are never merged; a fee and a purchase of the same amount and minute are two', false, sqlerrm);
end $$;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
do $$ declare r jsonb; g jsonb; mv uuid; asg text; again text; begin
  r := t_ingest(t_relay(E'إيداع\nمبلغ: 210 SAR\nحساب: 605*****192\n07/11/26 17:00', 'NewBankSender'));
  set local role authenticated;
  g := fn_admin_bank_mail_get();
  perform fn_admin_bank_mail_set(jsonb_build_object('version', (g->>'version')::int, 'allowed_senders', jsonb_build_array('AlRajhiBank', 'NewBankSender')));
  r := fn_bank_reparse((r->>'message_id')::uuid);
  select id into mv from bank_movements where account_hint = '**192' and amount_halalas = 300 limit 1;
  asg := t_fails(format('select fn_bank_assign_account(%L, %L, %L)', mv, t_accid(t_id('b2'), 'bank_account'), ''), 'VALIDATION: reason%');
  perform fn_bank_assign_account(mv, t_accid(t_id('b2'), 'bank_account'), 'نهاية مشتركة: الحركة لفرع بريدة');
  again := t_fails(format('select fn_bank_assign_account(%L, %L, %L)', mv, t_accid(t_id('b1'), 'bank_account'), 'مرة ثانية'), 'VALIDATION: movement_assigned%');
  reset role;
  perform t_record('BK16 a message refused for its sender is read again once the owner allows that sender; an unassigned movement is given its branch account by the owner with a reason, once',
    r->>'status' = 'parsed' and asg = 'ok' and again = 'ok' and (select branch_id from bank_movements where id = mv) = t_id('b2'), concat_ws(' / ', r::text, asg, again));
exception when others then perform t_record('BK16 a message refused for its sender is read again once the owner allows that sender; an unassigned movement is given its branch account by the owner with a reason, once', false, sqlerrm);
end $$;
reset role;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare g jsonb; h jsonb; bad text; begin
  g := fn_admin_bank_mail_get();
  bad := t_fails(format('select fn_admin_bank_mail_set(%L::jsonb)', jsonb_build_object('version', (g->>'version')::int, 'enabled', null)), 'VALIDATION: enabled%');
  perform fn_admin_bank_mail_set(jsonb_build_object('version', (g->>'version')::int, 'imap_host', 'imap.attacker.example'));
  h := fn_admin_bank_mail_get();
  perform t_record('BK17 the mailbox password goes with its server: pointing the reading at another server without typing the password again clears it (and stops the reading)',
    bad = 'ok' and not (h->>'has_password')::boolean and h->>'state' = 'not_configured' and not (h->>'enabled')::boolean, concat_ws(' / ', bad, h->>'state'));
exception when others then perform t_record('BK17 the mailbox password goes with its server: pointing the reading at another server without typing the password again clears it (and stops the reading)', false, sqlerrm);
end $$;
reset role;
do $$ declare r jsonb; begin
  r := t_ingest(E'نص فيه' || chr(1) || ' رمز غريب', 'x@example.org');
  set local role service_role;
  perform fn_bank_ingest_failed(77, 'too large');
  reset role;
  perform t_record('BK18 whatever arrives is kept raw, and an email the reader could not hand over is kept as a placeholder so the reading moves on',
    r->>'status' = 'rejected' and t_count('select count(*) from bank_messages where raw_body like ''%رقمها في البريد 77%'' and status = ''rejected''') = 1, r::text);
exception when others then perform t_record('BK18 whatever arrives is kept raw, and an email the reader could not hand over is kept as a placeholder so the reading moves on', false, sqlerrm);
end $$;

select t_record('BK13 the bank''s log lines read in Arabic', fn_audit_action_label('bank_mail.settings_changed') = 'تعديل بريد البنك' and fn_audit_entity_label('bank_rule') = 'قاعدة قراءة رسائل البنك');

select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),200) as detail from test_results order by ok nulls first, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from test_results where ok is not true) then raise exception 'ACCOUNTING A6 TESTS FAILED'; end if;
  if (select count(*) from test_results) < 19 then raise exception 'ACCOUNTING A6 TESTS INCOMPLETE: % of 19 checks ran', (select count(*) from test_results); end if;
end $$;
