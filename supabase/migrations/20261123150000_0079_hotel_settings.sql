-- 0079, plan 2.5: hotel settings are already keyed by organization. Complete their initialization.
-- Reuse code defaults, never another hotel's choices, credentials, counters or live bank data.
-- Existing choices stay unchanged. Missing defaults are inserted once, including for existing hotels.
create or replace function public.fn_hotel_settings_seed(p_org uuid) returns void
language plpgsql security definer set search_path to 'public', 'extensions' as $$
begin
  if not exists(select 1 from organizations where id=p_org) then raise exception 'HOTEL_NOT_FOUND'; end if;
  perform pg_advisory_xact_lock(hashtext('hotel_settings_seed:' || p_org::text));
  insert into ai_settings(organization_id) values(p_org) on conflict do nothing;
  insert into system_settings(organization_id) values(p_org) on conflict do nothing;
  perform fn_alert_rules_seed(p_org);
  perform fn_gl_seed(p_org);
  insert into bank_parse_rules(organization_id,keyword,kind,direction,priority)
  select p_org,r.k,r.kind,r.dir,r.p from (values ('استرداد', 'other_in', 'in', 5), ('رسوم نقاط البيع', 'pos_fee', 'out', 10), ('عمولة نقاط البيع', 'pos_fee', 'out', 11), ('POS fee', 'pos_fee', 'out', 12),
                   ('تسوية نقاط البيع', 'pos_settlement', 'in', 20), ('مبيعات نقاط البيع', 'pos_settlement', 'in', 21), ('تسوية مدى', 'pos_settlement', 'in', 22), ('POS settlement', 'pos_settlement', 'in', 23),
                   ('حوالة واردة', 'transfer_in', 'in', 30), ('تحويل وارد', 'transfer_in', 'in', 31), ('Incoming transfer', 'transfer_in', 'in', 32), ('واردة', 'transfer_in', 'in', 35),
                   ('حوالة صادرة', 'transfer_out', 'out', 40), ('تحويل صادر', 'transfer_out', 'out', 41), ('Outgoing transfer', 'transfer_out', 'out', 42), ('صادرة', 'transfer_out', 'out', 45),
                   ('إيداع', 'deposit', 'in', 50), ('ايداع', 'deposit', 'in', 51), ('Deposit', 'deposit', 'in', 52),
                   ('سحب', 'withdrawal', 'out', 60), ('Withdrawal', 'withdrawal', 'out', 61),
                   ('رسوم', 'fee', 'out', 70), ('Fees', 'fee', 'out', 71),
                   ('شراء', 'purchase', 'out', 80), ('Purchase', 'purchase', 'out', 81)) r(k, kind, dir, p)
  where not exists(select 1 from bank_parse_rules x where x.organization_id=p_org)
  on conflict do nothing;
end $$;
revoke all on function public.fn_hotel_settings_seed(uuid) from public,anon,authenticated;

create or replace function public.fn_trg_hotel_settings_seed() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin perform fn_hotel_settings_seed(new.id); return new; end $$;
revoke all on function public.fn_trg_hotel_settings_seed() from public,anon,authenticated;
create or replace trigger trg_hotel_settings_seed after insert on public.organizations
for each row execute function public.fn_trg_hotel_settings_seed();

select fn_hotel_settings_seed(id) from public.organizations order by id;
