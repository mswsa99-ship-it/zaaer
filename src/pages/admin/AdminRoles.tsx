/**
 * «مصفوفة الصلاحيات» (decision 71): the matrix the owner approved, editable by the owner — tick or untick a cell, save
 * with a reason. One matrix for the whole organisation; the owner's column is always allowed; «تعديل مصفوفة الصلاحيات»
 * stays the owner's. A cell that carries a condition keeps it when ticked (shown as «بقيد»). A change takes effect on
 * each person's next operation: the server decides every operation by this matrix (fn_can), and the screens follow
 * within a minute. Every save writes one audit row with each changed cell before and after and the reason;
 * «استعادة المصفوفة المعتمدة» returns every cell to the approved matrix.
 */
import { useCallback, useEffect, useMemo, useState } from "react";
import { Lock, RotateCcw, Save, Undo2, Info } from "lucide-react";
import { permissionsApi, toArabicError, type PermissionMatrix, type PermissionChange } from "../../lib/api";
import { useAuth } from "../../lib/auth";
import { SectionTitle, Card, Badge, LoadingScreen, LoadErrorCard } from "../../components/ui";
import { Modal, ActionForm, Submit, ReasonInput } from "../../components/forms";
import { ExportMenu } from "../../components/ExportMenu";
import { ROLE_LABELS, type Role } from "../../lib/types";
import { formatDateTime } from "../../lib/utils";
import type { ExportScope, ExportStatement, ExportTable } from "../../lib/exports";

const key = (code: string, role: string) => `${code}|${role}`;

export default function AdminRoles() {
  const { profile } = useAuth();
  const [m, setM] = useState<PermissionMatrix | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [draft, setDraft] = useState<Record<string, boolean>>({});
  const [saving, setSaving] = useState<"save" | "reset" | null>(null);
  const [reason, setReason] = useState("");
  const [notice, setNotice] = useState<string | null>(null);

  const load = useCallback(async () => {
    try { setM(await permissionsApi.matrix()); setError(null); } catch (e) { setError(toArabicError(e)); }
  }, []);
  useEffect(() => { void load(); }, [load]);

  const value = (code: string, role: string) => {
    const k = key(code, role);
    return k in draft ? draft[k] : !!m?.rows.find((r) => r.code === code)?.cells[role]?.allowed;
  };
  const changes: PermissionChange[] = useMemo(() => Object.entries(draft).map(([k, allowed]) => { const [code, role] = k.split("|"); return { code, role, allowed }; }), [draft]);
  const toggle = (code: string, role: string) => {
    if (!m) return;
    const saved = !!m.rows.find((r) => r.code === code)?.cells[role]?.allowed;
    const next = !value(code, role);
    setDraft((d) => { const n = { ...d }; if (next === saved) delete n[key(code, role)]; else n[key(code, role)] = next; return n; });
    setNotice(null);
  };
  const areas = useMemo(() => [...new Set((m?.rows ?? []).map((r) => r.area))], [m]);

  const statement = (scope: ExportScope): ExportStatement => ({ title: "مصفوفة الصلاحيات", branch: "كل الفروع", period: null,
    filters: [m && m.changed > 0 ? `${m.changed} خانة تختلف عن المصفوفة المعتمدة` : "مطابقة للمصفوفة المعتمدة"], scope, generatedAt: formatDateTime(new Date().toISOString()), by: profile?.full_name ?? null });
  const table = async (): Promise<ExportTable> => ({
    columns: ["المجال", "العملية", ...(m?.roles ?? []).map((r) => ROLE_LABELS[r as Role] ?? r), "القيد"],
    rows: (m?.rows ?? []).map((r) => [r.area, r.label, ...(m?.roles ?? []).map((role) => (r.cells[role]?.allowed ? (r.cells[role]?.limited ? "✓ بقيد" : "✓") : "—")), r.limit_note ?? ""]),
    widths: [14, 48, 10, 10, 10, 10, 10, 24],
  });

  if (error && !m) return <LoadErrorCard message={error} onRetry={load} />;
  if (!m) return <LoadingScreen />;

  return (
    <div className="pb-24">
      <SectionTitle title="مصفوفة الصلاحيات" subtitle="ما يستطيع كل دور فعله في كل الفروع. عمود المالك ثابت. التغيير يسري من العملية التالية لكل موظف." action={<ExportMenu allOnly source={{ statement, table, pageCount: m.rows.length, total: m.rows.length }} />} />

      <Card className="mb-4 flex flex-wrap items-center gap-3 p-3 text-xs text-ink-600">
        <Info className="h-4 w-4 shrink-0 text-ink-400" />
        <span data-testid="perm-changed-count">{m.changed === 0 ? "مطابقة للمصفوفة المعتمدة" : `${m.changed} خانة تختلف عن المصفوفة المعتمدة`}</span>
        {m.last_change && <span className="text-ink-400" data-testid="perm-last-change">آخر تعديل {formatDateTime(m.last_change.at)}{m.last_change.by ? ` · ${m.last_change.by}` : ""}{m.last_change.reason ? ` · «${m.last_change.reason}»` : ""}</span>}
        <button type="button" className="btn-ghost mr-auto px-2 py-1 text-xs" disabled={m.changed === 0} onClick={() => { setReason(""); setSaving("reset"); }} data-testid="perm-reset"><RotateCcw className="h-3 w-3" /> استعادة المصفوفة المعتمدة</button>
      </Card>
      {notice && <div className="mb-4 rounded-xl border border-success-500/30 bg-success-500/5 p-3 text-sm text-success-700" data-testid="perm-notice">{notice}</div>}

      <Card className="overflow-x-auto p-0">
        <table className="w-full text-sm" data-testid="perm-matrix">
          <thead className="bg-ink-50 text-xs text-ink-500">
            <tr>
              <th className="px-3 py-2 text-right font-medium">العملية</th>
              {m.roles.map((r) => <th key={r} className="whitespace-nowrap px-2 py-2 text-center font-medium">{ROLE_LABELS[r as Role] ?? r}</th>)}
            </tr>
          </thead>
          <tbody>
            {areas.map((area) => (
              <AreaRows key={area} area={area} m={m} value={value} draft={draft} toggle={toggle} />
            ))}
          </tbody>
        </table>
      </Card>
      <p className="mt-2 text-[11px] text-ink-400">«بقيد»: الدور يملك العملية بقيدها المكتوب تحت اسمها. النقطة: خانة تختلف عن المصفوفة المعتمدة. التصدير يتبع صلاحية القائمة نفسها. العمليات غير المذكورة هنا تبقى بأدوارها الثابتة.</p>

      {changes.length > 0 && (
        <div className="fixed inset-x-0 bottom-0 z-40 border-t border-ink-100 bg-white/95 px-4 py-3 shadow-lg backdrop-blur" style={{ paddingBottom: "max(12px, env(safe-area-inset-bottom, 0px))" }}>
          <div className="mx-auto flex max-w-5xl flex-wrap items-center gap-3">
            <span className="text-sm font-medium text-ink-700" data-testid="perm-draft-count">{changes.length} تغيير غير محفوظ</span>
            <button type="button" className="btn-primary text-sm" onClick={() => { setReason(""); setSaving("save"); }} data-testid="perm-save"><Save className="h-4 w-4" /> حفظ التغييرات</button>
            <button type="button" className="btn-outline text-sm" onClick={() => setDraft({})} data-testid="perm-discard"><Undo2 className="h-4 w-4" /> تراجع</button>
          </div>
        </div>
      )}

      <Modal open={saving !== null} title={saving === "reset" ? "استعادة المصفوفة المعتمدة" : "حفظ تغييرات الصلاحيات"} onClose={() => setSaving(null)}>
        {saving && (
          <ActionForm onSubmit={async () => {
            if (!reason.trim()) throw new Error("VALIDATION: reason");
            const r = saving === "reset" ? await permissionsApi.reset(reason.trim()) : await permissionsApi.save(changes, reason.trim());
            setSaving(null); setDraft({});
            setNotice(r.unchanged ? "لا تغيير." : saving === "reset" ? `عادت ${r.changed} خانة إلى المصفوفة المعتمدة. يسري ذلك من العملية التالية لكل موظف.` : `حُفظ ${r.changed} تغيير. يسري من العملية التالية لكل موظف.`);
            await load();
          }}>
            {saving === "save" ? (
              <ul className="mb-3 max-h-48 space-y-1 overflow-y-auto text-xs text-ink-600" data-testid="perm-review">
                {changes.map((c) => (
                  <li key={key(c.code, c.role)}>{c.allowed ? "✓ يُسمح" : "✗ يُمنع"} لـ{ROLE_LABELS[c.role as Role] ?? c.role}: {m.rows.find((r) => r.code === c.code)?.label}</li>
                ))}
              </ul>
            ) : <p className="mb-3 text-sm text-ink-600">تعود كل الخانات إلى المصفوفة التي اعتمدتها؛ يُسجَّل ما تغيّر في سجل الإجراءات.</p>}
            <ReasonInput value={reason} onChange={setReason} placeholder="مثال: المالية تتابع البلاغات" />
            <Submit label={saving === "reset" ? "استعادة" : "حفظ"} onCancel={() => setSaving(null)} />
          </ActionForm>
        )}
      </Modal>
    </div>
  );
}

function AreaRows({ area, m, value, draft, toggle }: { area: string; m: PermissionMatrix; value: (c: string, r: string) => boolean; draft: Record<string, boolean>; toggle: (c: string, r: string) => void }) {
  const rows = m.rows.filter((r) => r.area === area);
  return (
    <>
      <tr className="border-t border-ink-100 bg-ink-50/60"><td colSpan={m.roles.length + 1} className="px-3 py-1.5 text-xs font-semibold text-ink-600">{area}</td></tr>
      {rows.map((r) => (
        <tr key={r.code} className="border-t border-ink-50" data-testid="perm-row" data-code={r.code}>
          <td className="px-3 py-2 text-ink-800">
            <span className="flex items-center gap-1.5">{r.locked && <Lock className="h-3.5 w-3.5 text-ink-400" />}{r.label}</span>
            {r.limit_note && <span className="mt-0.5 block text-[11px] text-ink-400">القيد لمن ليس له العملية كاملة: {r.limit_note}</span>}
            {r.locked && <span className="mt-0.5 block text-[11px] text-ink-400">للمالك وحده، لا تُمنح لدور آخر</span>}
          </td>
          {m.roles.map((role) => {
            const cell = r.cells[role];
            const fixed = role === "owner" || r.locked;
            const v = value(r.code, role);
            const pending = key(r.code, role) in draft;
            const differs = !fixed && v !== cell?.default;
            const limited = v && role !== "owner" && !!r.full_roles && !r.full_roles.includes(role);
            return (
              <td key={role} className={`px-2 py-2 text-center ${pending ? "bg-brand-50" : ""}`}>
                <label className="inline-flex flex-col items-center gap-0.5">
                  <input type="checkbox" className="h-4 w-4 accent-brand-600" checked={v} disabled={fixed} onChange={() => toggle(r.code, role)}
                    aria-label={`${r.label} — ${ROLE_LABELS[role as Role] ?? role}`} data-testid="perm-cell" data-code={r.code} data-role={role} data-default={cell?.default ? "yes" : "no"} />
                  <span className="flex h-3 items-center gap-0.5">
                    {limited && <Badge className="bg-warning-500/10 px-1 py-0 text-[9px] text-warning-700" title={r.limit_note ?? ""}>بقيد</Badge>}
                    {differs && <span className="h-1.5 w-1.5 rounded-full bg-brand-500" title={cell?.default ? "مسموحة في المصفوفة المعتمدة" : "غير مسموحة في المصفوفة المعتمدة"} />}
                  </span>
                </label>
              </td>
            );
          })}
        </tr>
      ))}
    </>
  );
}

