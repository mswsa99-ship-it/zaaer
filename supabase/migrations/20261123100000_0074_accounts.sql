-- ============================================================================================================
-- 0074 — Accounts (owner, 23 Nov 2026): a complete user system on Supabase Auth — the forgotten password and the
-- change of password by an e-mailed link, the staff's invitation by e-mail with a password each sets for themself,
-- and a log of sign-ins and password events.
--
-- The passwords themselves live only in Supabase Auth (bcrypt, never readable); this migration adds what the app
-- needs around them:
--   fn_auth_event(action, target)        a signed-in staff member records a security event of their own (signed in,
--                                        signed out, password changed, a link or an invitation sent to a colleague).
--                                        The trigger fn_audit_enrich files every «security.*» action under the
--                                        «security» category, which only the owner reads. The IP and the browser
--                                        come from the request's own headers; a target must be in the caller's
--                                        organization and within what the caller may manage. At most 60 per hour.
--   fn_admin_staff_auth_status()         owner and manager: for each staff member whether an account exists, whether
--                                        its e-mail is confirmed and when it last signed in (from auth.users).
--   fn_admin_staff_invite_target(staff)  owner only: the e-mail and name the «staff-invite» edge function sends the
--                                        invitation to — the function asks the database as the caller, so the
--                                        database decides who may invite.
-- Password rules (at least 6 characters, letters and digits — owner's decision) are Supabase Auth settings, applied
-- by the screens as well. No row is changed by this migration.
-- ============================================================================================================

create or replace function fn_auth_event(p_action text, p_target uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me staff_profiles%rowtype; tgt staff_profiles%rowtype; recent int; v_ip text; v_ua text;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN: not signed in' using errcode = '42501'; end if;
  if p_action is null or p_action not in ('security.signed_in', 'security.signed_out', 'security.signed_out_everywhere',
      'security.password_changed', 'security.password_link_sent', 'security.invite_sent') then
    raise exception 'VALIDATION: action';
  end if;
  select * into me from staff_profiles where auth_user_id = auth.uid() and is_active;
  if not found then return jsonb_build_object('ok', false, 'skipped', 'no_profile'); end if;
  if p_target is not null and p_target <> me.id then
    if p_action not in ('security.password_link_sent', 'security.invite_sent') then raise exception 'VALIDATION: target'; end if;
    select * into tgt from staff_profiles where id = p_target and organization_id = me.organization_id;
    if not found then raise exception 'NOT_FOUND'; end if;
    -- the owner for anyone; a manager for the staff below managers (the same reach as «الموظفون», decisions 34/35)
    if not (me.role = 'owner' or (me.role = 'manager' and tgt.role not in ('owner', 'manager'))) then
      raise exception 'FORBIDDEN: staff' using errcode = '42501';
    end if;
  end if;
  select count(*) into recent from audit_events
   where actor_id = me.id and action like 'security.%' and created_at > now() - interval '1 hour';
  if recent >= 60 then return jsonb_build_object('ok', false, 'skipped', 'throttled'); end if;
  v_ip := nullif(trim(split_part(coalesce(fn_request_header('x-forwarded-for'), ''), ',', 1)), '');
  if v_ip is not null and v_ip !~ '^[0-9a-fA-F.:]{3,45}$' then v_ip := null; end if;
  v_ua := nullif(left(coalesce(fn_request_header('user-agent'), ''), 200), '');
  perform fn_audit(me.organization_id, null, me.id, p_action, 'staff_profile', coalesce(p_target, me.id),
    jsonb_strip_nulls(jsonb_build_object('ip', v_ip, 'user_agent', v_ua,
      'target_name', case when p_target is not null and p_target <> me.id then tgt.full_name end)));
  return jsonb_build_object('ok', true);
end $$;
revoke all on function fn_auth_event(text, uuid) from public, anon;
grant execute on function fn_auth_event(text, uuid) to authenticated;

create or replace function fn_admin_staff_auth_status() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (fn_has_role('owner') or fn_has_role('manager')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('staff_id', s.id, 'has_account', u.id is not null,
                                        'email_confirmed', u.email_confirmed_at is not null,
                                        'last_sign_in_at', u.last_sign_in_at) order by s.full_name)
      from staff_profiles s left join auth.users u on u.id = s.auth_user_id
     where s.organization_id = fn_user_org_id()), '[]'::jsonb);
end $$;
revoke all on function fn_admin_staff_auth_status() from public, anon;
grant execute on function fn_admin_staff_auth_status() to authenticated;

create or replace function fn_admin_staff_invite_target(p_staff uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s staff_profiles%rowtype;
begin
  if not fn_has_role('owner') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into s from staff_profiles where id = p_staff and organization_id = fn_user_org_id();
  if not found then raise exception 'NOT_FOUND'; end if;
  return jsonb_build_object('staff_id', s.id, 'email', s.email, 'full_name', s.full_name, 'is_active', s.is_active,
                            'linked', s.auth_user_id is not null);
end $$;
revoke all on function fn_admin_staff_invite_target(uuid) from public, anon;
grant execute on function fn_admin_staff_invite_target(uuid) to authenticated;

-- the log reads the account events in Arabic (src/lib/auditLabels.ts carries the same lines; tests/unit/audit_labels.test.ts AB09 diffs them)
create or replace function fn_audit_account_label(p_action text) returns text
language sql immutable set search_path = public as $$
  select case p_action
      when 'security.signed_in' then 'تسجيل دخول'
      when 'security.signed_out' then 'تسجيل خروج'
      when 'security.signed_out_everywhere' then 'تسجيل الخروج من كل الأجهزة'
      when 'security.password_changed' then 'تغيير كلمة المرور'
      when 'security.password_link_sent' then 'إرسال رابط تعيين كلمة المرور'
      when 'security.invite_sent' then 'إرسال دعوة دخول بالبريد'
      else null
    end;
$$;
revoke all on function fn_audit_account_label(text) from public, anon;
grant execute on function fn_audit_account_label(text) to authenticated, service_role;

-- fn_audit_action_label asks it after the accounting family (0063's way: one line added to the definition in force, once)
do $$
declare fn oid; def text; n int;
        old_p constant text := $a$    fn_audit_accounting_label(p_action),$a$;
        new_p constant text := $b$    fn_audit_accounting_label(p_action),
    fn_audit_account_label(p_action),$b$;
begin
  select p.oid into fn from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'fn_audit_action_label';
  def := pg_get_functiondef(fn);
  if position('fn_audit_account_label(p_action)' in def) > 0 then return; end if;
  n := (length(def) - length(replace(def, old_p, ''))) / length(old_p);
  if n <> 1 then raise exception '0074: the accounting line of fn_audit_action_label was found % times, not once', n; end if;
  execute replace(def, old_p, new_p);
end $$;
