import { emptyStaffBranchesLabel, changedStaffBranches } from "../../lib/staffBranchMetadata";
import { IndividualPermissionDraft } from "../../components/IndividualPermissionDraft";
/**
 * «الموظفون» (decisions 34, 35): the list from fn_admin_staff_list; «تعديل موظف» for the owner only — name, phone, role
 * and branches, with a reason, before and after in the log (the email is the login identity: corrected only until the
 * person first signs in, 0055; no one
 * changes their own role or branches; the last owner is never demoted); activation with a reason (deactivation ends the
 * person's sessions); «تسجيل خروج إجباري» for the owner and the manager, with a reason — every session on every device
 * ends at once and the account stays active; the manager signs out neither an owner nor a manager.
 */
import { useEffect, useState, useCallback } from "react";
import { staffAdminApi, accountsApi, INVITE_ERROR_AR, toArabicError, VALIDATION_AR, type StaffListRow, type StaffAuthStatus } from "../../lib/api";
import { normalizePhone, validEmail } from "../../lib/validation";
import { useAuth, logAuthEvent } from "../../lib/auth";
import { useBranch } from "../../lib/branch";
import { SectionTitle, LoadingScreen, Card, EmptyState, Badge, Spinner, ErrorBanner, LoadErrorCard } from "../../components/ui";
import { Modal, Field, ActionForm, Submit, ReasonInput } from "../../components/forms";
import { UserCog, UserPlus, Pencil, LogOut, Power, KeyRound, Mail } from "lucide-react";
import { ROLE_LABELS } from "../../lib/types";
import { formatDateTime, COUNT } from "../../lib/utils";

const INVITE_ROLES = ["manager", "supervisor", "finance", "housekeeping"] as const;

export default function AdminStaff() {
  const { profile, can, canFull, requestPasswordReset } = useAuth();
  const isOwner = profile?.role === "owner";
  // the permissions matrix decides (decision 71): «دعوة موظف وتعديله…» and «خروج إجباري»; no one but the owner touches an owner (decision 44)
  const canManage = can("staff.manage");
  const touches = (s: StaffListRow) => isOwner || s.role !== "owner";
  const roleChoices = INVITE_ROLES;
  const { branches } = useBranch();
  const [grantTarget, setGrantTarget] = useState<{id:string;name:string}|null>(null);
  const [staff, setStaff] = useState<StaffListRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [inviteErr, setInviteErr] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  // invite form
  const [email, setEmail] = useState("");
  const [fullName, setFullName] = useState("");
  const [role, setRole] = useState<string>("supervisor");
  const [branchIds, setBranchIds] = useState<string[]>([]);
  const [phone, setPhone] = useState("");
  const [inviting, setInviting] = useState(false);
  const [invited, setInvited] = useState<string | null>(null);

  // dialogs
  const [edit, setEdit] = useState<null | { s: StaffListRow; email: string; full_name: string; phone: string; role: string; branch_ids: string[]; reason: string }>(null);
  const [activate, setActivate] = useState<null | { s: StaffListRow; reason: string }>(null);
  const [signOut, setSignOut] = useState<null | { s: StaffListRow; reason: string }>(null);

  // 0074: who has an account and when they last signed in; the e-mailed links and invitations
  const [authStatus, setAuthStatus] = useState<Record<string, StaffAuthStatus>>({});
  const [sending, setSending] = useState<string | null>(null);
  const load = useCallback(async () => {
    try { setStaff(await staffAdminApi.list()); setError(null); } catch (e) { setError(toArabicError(e)); }
    try { const st = await accountsApi.staffAuthStatus(); setAuthStatus(Object.fromEntries(st.map((x) => [x.staff_id, x]))); } catch { /* the list works without it */ }
    setLoading(false);
  }, []);
  useEffect(() => { load(); }, [load]);

  async function invite() {
    setInviteErr(null); setInvited(null);
    // 0055 (SETUP-08): the same checks as the server, before sending
    if (!email.trim() || !fullName.trim()) { setInviteErr("البريد والاسم مطلوبان."); return; }
    if (!validEmail(email)) { setInviteErr(VALIDATION_AR.email); return; }
    if (role !== "owner" && branchIds.length === 0) { setInviteErr(VALIDATION_AR.branch_required); return; }
    if (phone.trim() && !normalizePhone(phone)) { setInviteErr(VALIDATION_AR.phone); return; }
    setInviting(true);
    try {
      const r = await staffAdminApi.invite({ email: email.trim(), full_name: fullName.trim(), role, branch_ids: branchIds, phone: phone.trim() || null });
      setInvited(email.trim());
      // 0074: the invitation e-mail follows at once (the owner); the person sets their own password from its link
      if (isOwner && r?.staff_id) {
        const sent = await accountsApi.invite(r.staff_id);
        setNotice(sent.ok ? `أُرسلت الدعوة إلى ${email.trim()}: يفتح الرابط ويختار كلمة مروره بنفسه.` : `أُضيف الموظف. ${INVITE_ERROR_AR[sent.error ?? "failed"] ?? INVITE_ERROR_AR.failed}`);
      }
      setEmail(""); setFullName(""); setBranchIds([]); setPhone("");
      await load();
    } catch (e) { setInviteErr(toArabicError(e)); }
    setInviting(false);
  }

  const branchName = (id: string) => branches.find((b) => b.id === id)?.name_ar ?? "فرع آخر";
  // 0074: a reset link to a colleague's own e-mail (the owner for anyone, a manager for those below managers); an invitation (the owner) for one with no account yet
  const canSendLink = (s: StaffListRow) => s.linked && s.is_active && !s.is_me && (isOwner || (profile?.role === "manager" && !["owner", "manager"].includes(s.role)));
  const canInviteByMail = (s: StaffListRow) => isOwner && !s.linked && s.is_active;
  async function sendLink(s: StaffListRow) {
    setSending(s.id); setError(null); setNotice(null);
    const { error } = await requestPasswordReset(s.email);
    if (error) setError(error);
    else { await logAuthEvent("security.password_link_sent", s.id); setNotice(`أُرسل رابط تعيين كلمة المرور إلى ${s.email}.`); }
    setSending(null);
  }
  async function sendInvite(s: StaffListRow) {
    setSending(s.id); setError(null); setNotice(null);
    const r = await accountsApi.invite(s.id);
    if (r.ok) setNotice(`أُرسلت الدعوة إلى ${s.email}.`); else setError(INVITE_ERROR_AR[r.error ?? "failed"] ?? INVITE_ERROR_AR.failed);
    setSending(null);
  }
  const canSignOut = (s: StaffListRow) => !s.is_me && s.is_active && can("staff.force_logout") && (canFull("staff.force_logout") || !["owner", "manager"].includes(s.role));

  if (loading) return <LoadingScreen />;
  if (error && staff.length === 0) return <div><SectionTitle title="الموظفون" /><LoadErrorCard message={error} onRetry={() => { setLoading(true); load(); }} /></div>;

  return (
    <div>
      <SectionTitle title="الموظفون" subtitle={`${COUNT.staff(staff.length)} · النشطون ${staff.filter((s) => s.is_active).length}`} />
      {error && <div className="mb-4"><ErrorBanner message={error} /></div>}
      {notice && <div role="status" className="mb-4 rounded-xl border border-success-500/30 bg-success-500/10 px-4 py-3 text-sm text-success-600" data-testid="staff-notice">{notice}</div>}

      {canManage && (
        <Card className="mb-5">
          <h2 className="mb-3 flex items-center gap-2 text-sm font-semibold text-ink-700"><UserPlus className="h-4 w-4 text-brand-600" /> دعوة موظف</h2>
          <p className="mb-3 text-xs text-ink-400">يُنشأ ملف الموظف الآن ويرتبط تلقائيًا بحسابه عند أول تسجيل دخول بنفس البريد. لا يمكن للموظف اختيار دوره بنفسه.</p>
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
            <div><label className="label">البريد الإلكتروني</label><input className="input" dir="ltr" type="email" value={email} onChange={(e) => setEmail(e.target.value)} /></div>
            <div><label className="label">الاسم الكامل</label><input className="input" value={fullName} maxLength={120} onChange={(e) => setFullName(e.target.value)} /></div>
            <div><label className="label">الهاتف (اختياري)</label><input className="input" dir="ltr" inputMode="tel" value={phone} onChange={(e) => setPhone(e.target.value)} placeholder="05xxxxxxxx" data-testid="invite-phone" /></div>
            <div>
              <label className="label">الدور</label>
              <select className="input" value={role} onChange={(e) => setRole(e.target.value)}>
                {roleChoices.map((r) => <option key={r} value={r}>{ROLE_LABELS[r]}</option>)}
              </select>
            </div>
            <div>
              <label className="label">الفروع{role !== "owner" ? " (فرع واحد على الأقل)" : ""}</label>
              <div className="flex flex-wrap gap-2 rounded-xl border border-ink-100 p-2">
                {branches.map((b) => (
                  <label key={b.id} className="flex items-center gap-1.5 text-xs text-ink-700">
                    <input type="checkbox" className="accent-brand-600" checked={branchIds.includes(b.id)} onChange={(e) => setBranchIds((ids) => e.target.checked ? [...ids, b.id] : ids.filter((x) => x !== b.id))} />
                    {b.name_ar}
                  </label>
                ))}
                {branches.length === 0 && <span className="text-xs text-ink-400">لا توجد فروع</span>}
              </div>
            </div>
          </div>
          <div className="mt-3 flex items-center gap-3">
            <button onClick={invite} disabled={inviting} className="btn-primary text-sm">{inviting ? <Spinner className="h-4 w-4" /> : "إرسال الدعوة"}</button>
            {invited && <Badge className="bg-success-500/10 text-success-600">تمت دعوة {invited}</Badge>}
          </div>
          {inviteErr && <div className="mt-3" role="alert" data-testid="invite-error"><ErrorBanner message={inviteErr} /></div>}
        </Card>
      )}

      {isOwner && grantTarget && <IndividualPermissionDraft key={grantTarget.id} staffId={grantTarget.id} name={grantTarget.name} />}
      {staff.length === 0 ? (
        <EmptyState icon={<UserCog className="h-10 w-10" />} title="لا يوجد موظفون" />
      ) : (
        <div className="grid gap-3 sm:grid-cols-2" data-testid="staff-list">
          {staff.map((s) => (
            <Card key={s.id} className={`flex flex-col gap-2 ${s.is_active ? "" : "opacity-70"}`} data-testid="staff-card" data-email={s.email}>
              <div className="flex items-start justify-between gap-3">
              <div className="min-w-0">
                {isOwner && s.role !== "owner" && <button type="button" className="btn-outline mb-2 text-xs" onClick={() => setGrantTarget({id:s.id,name:s.full_name})}>مسودة صلاحيات فردية</button>}
                <p className="text-sm font-semibold text-ink-800">{s.full_name}{s.is_me && <span className="mr-1 text-xs font-normal text-ink-400">(أنا)</span>}</p>
                <p className="truncate text-xs text-ink-400" dir="ltr">{s.email}</p>
                {s.phone && <p className="text-xs text-ink-500" dir="ltr">{s.phone}</p>}
                <div className="mt-1 flex flex-wrap gap-1">
                  <Badge className={s.linked ? "bg-success-500/10 text-success-600" : "bg-warning-500/10 text-warning-700"}>{s.linked ? "مرتبط" : "بانتظار تسجيل الدخول"}</Badge>
                  {s.role === "owner" ? <Badge className="bg-ink-100 text-ink-600">كل الفروع</Badge> : s.branch_ids.length === 0 ? <Badge className="bg-rai-surface-sunken text-rai-ink-muted">{emptyStaffBranchesLabel(isOwner)}</Badge> : s.branch_ids.map((b) => <Badge key={b} className="bg-ink-100 text-ink-600">{branchName(b)}</Badge>)}
                </div>
                {s.sessions_ended_at && <p className="mt-1 text-[11px] text-ink-400">أُنهيت جلساته {formatDateTime(s.sessions_ended_at)}</p>}
                {authStatus[s.id] && (
                  <p className="mt-1 text-[11px] text-ink-400" data-testid="staff-last-sign-in">
                    {!authStatus[s.id].has_account ? "لم يُنشئ حسابه بعد" : authStatus[s.id].last_sign_in_at ? `آخر دخول ${formatDateTime(authStatus[s.id].last_sign_in_at!)}` : "لم يسجّل الدخول بعد"}
                  </p>
                )}
              </div>
              <div className="flex shrink-0 flex-col items-end gap-1">
                <Badge className="bg-brand-50 text-brand-700">{ROLE_LABELS[s.role as keyof typeof ROLE_LABELS] ?? s.role}</Badge>
                <Badge className={s.is_active ? "bg-success-500/10 text-success-600" : "bg-ink-100 text-ink-400"}>{s.is_active ? "نشط" : "موقوف"}</Badge>
              </div>
              </div>
              {/* the actions on their own row, wrapping: a phone keeps the card inside the screen (MW01) */}
              {((canManage && touches(s)) || canSendLink(s) || canInviteByMail(s) || canSignOut(s)) && (
                <div className="flex flex-wrap gap-1 border-t border-ink-100 pt-2">
                  {canManage && touches(s) && <button onClick={() => setEdit({ s, email: s.email, full_name: s.full_name, phone: s.phone ?? "", role: s.role, branch_ids: s.branch_ids, reason: "" })} className="btn-ghost px-2 py-1 text-xs" data-testid="staff-edit"><Pencil className="h-3 w-3" /> تعديل</button>}
                  {canManage && touches(s) && !s.is_me && <button onClick={() => setActivate({ s, reason: "" })} className={`btn-ghost px-2 py-1 text-xs ${s.is_active ? "text-danger-600" : "text-success-600"}`} data-testid="staff-toggle-active"><Power className="h-3 w-3" /> {s.is_active ? "إيقاف" : "تفعيل"}</button>}
                  {canSendLink(s) && <button onClick={() => sendLink(s)} disabled={sending === s.id} className="btn-ghost px-2 py-1 text-xs" data-testid="staff-reset-link"><KeyRound className="h-3 w-3" /> رابط كلمة المرور</button>}
                  {canInviteByMail(s) && <button onClick={() => sendInvite(s)} disabled={sending === s.id} className="btn-ghost px-2 py-1 text-xs" data-testid="staff-invite-email"><Mail className="h-3 w-3" /> دعوة بالبريد</button>}
                  {canSignOut(s) && <button onClick={() => setSignOut({ s, reason: "" })} className="btn-ghost px-2 py-1 text-xs text-warning-700" data-testid="staff-force-logout"><LogOut className="h-3 w-3" /> تسجيل خروج إجباري</button>}
                </div>
              )}
            </Card>
          ))}
        </div>
      )}

      {/* edit (owner) */}
      <Modal open={!!edit} title={`تعديل موظف · ${edit?.s.full_name ?? ""}`} onClose={() => setEdit(null)}>
        {edit && (
          <ActionForm onSubmit={async () => {
            if (!edit.reason.trim()) throw new Error("VALIDATION: reason");
            if (edit.phone.trim() && !normalizePhone(edit.phone)) throw new Error("VALIDATION: phone");
            const emailChanged = !edit.s.linked && edit.email.trim().toLowerCase() !== edit.s.email;
            if (emailChanged && !validEmail(edit.email)) throw new Error("VALIDATION: email");
            const r = await staffAdminApi.update({ staff_id: edit.s.id, reason: edit.reason.trim(), ...(emailChanged ? { email: edit.email.trim() } : {}), full_name: edit.full_name.trim(), phone: edit.phone.trim() || null, ...(edit.s.is_me ? {} : edit.role === "owner" ? { role: edit.role } : { role: edit.role, ...changedStaffBranches(edit.s.branch_ids, edit.branch_ids) }) });
            setEdit(null); setNotice(r.unchanged ? "لا تغيير." : `حُفظ التعديل (${(r.changed ?? []).map((c) => ({ email: "البريد", full_name: "الاسم", phone: "الهاتف", role: "الدور", branches: "الفروع" })[c] ?? c).join("، ")}). يسري تغيير الدور أو الفروع من العملية التالية للموظف.`); await load();
          }}>
            <div className="space-y-3">
              {edit.s.linked
                ? <Field label="البريد الإلكتروني" hint="سجّل الموظف دخوله بهذا البريد، فلا يُعدَّل الآن. لبريد جديد ادعُ الموظف من جديد."><input className="input" dir="ltr" value={edit.s.email} disabled /></Field>
                : <Field label="البريد الإلكتروني" hint="يُصحَّح البريد ما دام الموظف لم يسجّل دخوله بعد."><input className="input" dir="ltr" type="email" value={edit.email} onChange={(e) => setEdit({ ...edit, email: e.target.value })} data-testid="edit-email" /></Field>}
              <div className="grid grid-cols-2 gap-3">
                <Field label="الاسم الكامل"><input className="input" value={edit.full_name} onChange={(e) => setEdit({ ...edit, full_name: e.target.value })} data-testid="edit-name" /></Field>
                <Field label="الهاتف"><input className="input" dir="ltr" inputMode="tel" value={edit.phone} onChange={(e) => setEdit({ ...edit, phone: e.target.value })} placeholder="05xxxxxxxx" data-testid="edit-phone" /></Field>
              </div>
              <Field label="الدور" hint={edit.s.is_me ? "لا يغيّر أحد دوره بنفسه." : undefined}>
                <select className="input" value={edit.role} disabled={edit.s.is_me} onChange={(e) => setEdit({ ...edit, role: e.target.value })} data-testid="edit-role">{roleChoices.map((r) => <option key={r} value={r}>{ROLE_LABELS[r]}</option>)}</select>
              </Field>
              {edit.role !== "owner" && (
                <Field label="الفروع" hint={edit.s.is_me ? "لا يغيّر أحد فروعه بنفسه." : isOwner ? "إزالة فرع تسري من العملية التالية للموظف؛ تاريخ عضويته يبقى." : "تعرض القائمة الفروع المسموحة لك فقط، ولا تعني القائمة الفارغة أن الموظف بلا فرع. لا يُستبدل ارتباطه بالفروع دون تغيير صريح ومسموح."}>
                  <div className="flex flex-wrap gap-2 rounded-xl border border-ink-100 p-2" data-testid="edit-branches">
                    {branches.map((b) => (
                      <label key={b.id} className="flex items-center gap-1.5 text-xs text-ink-700">
                        <input type="checkbox" className="accent-brand-600" disabled={edit.s.is_me} checked={edit.branch_ids.includes(b.id)} onChange={(e) => setEdit({ ...edit, branch_ids: e.target.checked ? [...edit.branch_ids, b.id] : edit.branch_ids.filter((x) => x !== b.id) })} />
                        {b.name_ar}
                      </label>
                    ))}
                  </div>
                </Field>
              )}
              <ReasonInput value={edit.reason} onChange={(v) => setEdit({ ...edit, reason: v })} placeholder="مثال: نُقل إلى فرع آخر" />
              <p className="text-[11px] text-ink-400">يُسجَّل التعديل بما قبله وما بعده واسم من عدّل ووقته والسبب في سجل الإجراءات (الهاتف مقنّع فيه).</p>
            </div>
            <Submit label="حفظ التعديل" onCancel={() => setEdit(null)} />
          </ActionForm>
        )}
      </Modal>

      {/* activate / deactivate (owner) */}
      <Modal open={!!activate} title={activate?.s.is_active ? `إيقاف · ${activate.s.full_name}` : `تفعيل · ${activate?.s.full_name ?? ""}`} onClose={() => setActivate(null)}>
        {activate && (
          <ActionForm onSubmit={async () => {
            if (!activate.reason.trim()) throw new Error("VALIDATION: reason");
            const r = await staffAdminApi.setActive(activate.s.id, !activate.s.is_active, activate.reason.trim());
            setActivate(null); setNotice(activate.s.is_active ? `أُوقف الحساب${r.sessions_ended ? ` وأُنهيت ${r.sessions_ended} جلسة` : ""}.` : "فُعّل الحساب."); await load();
          }}>
            <p className="mb-3 text-sm text-ink-600">{activate.s.is_active ? "يُوقف الحساب ويُنهى كل جلساته على كل الأجهزة فورًا؛ يبقى ملفه وتاريخه." : "يعود الحساب فعّالًا ويدخل الموظف من جديد؛ الجلسات القديمة لا تعود."}</p>
            <ReasonInput value={activate.reason} onChange={(v) => setActivate({ ...activate, reason: v })} />
            <Submit label={activate.s.is_active ? "إيقاف الحساب" : "تفعيل الحساب"} onCancel={() => setActivate(null)} danger={activate.s.is_active} />
          </ActionForm>
        )}
      </Modal>

      {/* forced sign-out (owner, manager) */}
      <Modal open={!!signOut} title={`تسجيل خروج إجباري · ${signOut?.s.full_name ?? ""}`} onClose={() => setSignOut(null)}>
        {signOut && (
          <ActionForm onSubmit={async () => {
            if (!signOut.reason.trim()) throw new Error("VALIDATION: reason");
            const r = await staffAdminApi.forceLogout(signOut.s.id, signOut.reason.trim());
            setSignOut(null); setNotice(`أُنهيت جلسات ${signOut.s.full_name} (${r.sessions_ended}). حسابه فعّال ويدخل من جديد بكلمة مروره.`); await load();
          }}>
            <p className="mb-3 text-sm text-ink-600">تُنهى كل جلسات الموظف على كل الأجهزة الآن؛ أي طلب تالٍ منها يُرفض. الحساب يبقى فعّالًا ويستطيع الدخول من جديد. يُسجَّل باسمك ووقته والسبب.</p>
            <ReasonInput value={signOut.reason} onChange={(v) => setSignOut({ ...signOut, reason: v })} placeholder="مثال: جهاز مفقود" />
            <Submit label="إنهاء الجلسات" onCancel={() => setSignOut(null)} danger />
          </ActionForm>
        )}
      </Modal>
    </div>
  );
}
