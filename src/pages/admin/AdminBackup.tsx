import { CalendarClock, DatabaseBackup, FlaskConical, ShieldCheck, TriangleAlert } from "lucide-react";
import { SectionTitle, Card, Badge, DataState } from "../../components/ui";
import { formatDateTime } from "../../lib/utils";
import { useBackupStatus, type BackupStatus } from "../../lib/useBackupStatus";

/**
 * Item 7.1 (O4/T6): «النسخ الاحتياطي» — the owner sees the last successful backup from the recorded,
 * server-enforced state (migration 0103), the latest run whatever happened, and the last restore drill.
 * Read-only: backups are made by the scheduled tooling (scripts/backup/), never from the browser.
 */

const REASON_AR: Record<string, string> = {
  scheduled: "مجدولة",
  "pre-deploy": "قبل النشر",
  manual: "يدوية",
  drill: "تمرين",
};

function humanSize(bytes: number | null): string {
  if (bytes == null) return "—";
  if (bytes < 1024) return `${bytes} بايت`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} ك.ب`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} م.ب`;
}

function StatusBadge({ status }: { status: string }) {
  if (status === "success") return <Badge className="bg-green-100 text-green-800">ناجحة</Badge>;
  if (status === "failed") return <Badge className="bg-red-100 text-red-800">فاشلة</Badge>;
  return <Badge className="bg-amber-100 text-amber-800">جارية</Badge>;
}

/** Presentational half — the connected default export feeds it from fn_backup_status. */
export function BackupStatusView({ status, loading, error, reload }: {
  status: BackupStatus | null;
  loading: boolean;
  error: string | null;
  reload: () => void;
}) {
  const last = status?.last_success ?? null;
  const lastRun = status?.last_run ?? null;
  const drill = status?.last_restore_drill ?? null;
  const failures = status?.failures_since_last_success ?? 0;

  return (
    <div className="space-y-4">
      <SectionTitle
        title="النسخ الاحتياطي"
        subtitle="نسخة مشفّرة أسبوعية وقبل كل نشر، وتمرين استعادة شهري. تُدار النسخ من خادم النظام وتظهر هنا حالتها الموثّقة."
        action={<button type="button" className="btn-outline min-h-[44px]" onClick={reload}>تحديث</button>}
      />
      <DataState loading={loading} error={error} onRetry={reload} empty={!status && !!error} emptyTitle="" emptyDescription="">
        <>
          {failures > 0 && lastRun?.status === "failed" && (
            <Card className="border-red-200 bg-red-50/60 p-4">
              <div className="flex items-start gap-3">
                <TriangleAlert className="mt-0.5 h-5 w-5 shrink-0 text-red-600" />
                <div>
                  <p className="font-medium text-red-800">آخر محاولة نسخ فشلت</p>
                  <p className="mt-1 text-sm text-red-700">
                    {formatDateTime(lastRun.started_at)} — {lastRun.error ?? "فشل غير معروف"}.
                    {last ? " آخر نسخة ناجحة ما زالت محفوظة كما هي أدناه." : " ولا توجد نسخة ناجحة بعد."}
                  </p>
                </div>
              </div>
            </Card>
          )}

          <Card className="p-4">
            <div className="flex items-center gap-2">
              <DatabaseBackup className="h-5 w-5 text-ink-500" />
              <h2 className="text-lg font-semibold text-ink-900">آخر نسخة ناجحة</h2>
            </div>
            {last ? (
              <dl className="mt-3 grid grid-cols-1 gap-3 sm:grid-cols-2">
                <div>
                  <dt className="text-sm text-ink-500">التاريخ والوقت</dt>
                  <dd className="mt-0.5 font-medium text-ink-900" data-testid="backup-last-success-at">{formatDateTime(last.finished_at)}</dd>
                </div>
                <div>
                  <dt className="text-sm text-ink-500">السبب</dt>
                  <dd className="mt-0.5 font-medium text-ink-900">{REASON_AR[last.reason] ?? last.reason}</dd>
                </div>
                <div>
                  <dt className="text-sm text-ink-500">الحجم</dt>
                  <dd className="mt-0.5 font-medium text-ink-900">{humanSize(last.size_bytes)}</dd>
                </div>
                <div>
                  <dt className="text-sm text-ink-500">المحتوى</dt>
                  <dd className="mt-0.5 font-medium text-ink-900">
                    {last.tables_count != null ? `${last.tables_count} جدولًا` : "—"}
                    {last.rows_total != null ? `، ${last.rows_total.toLocaleString("ar-SA")} صفًّا` : ""}
                  </dd>
                </div>
                <div className="sm:col-span-2">
                  <dt className="text-sm text-ink-500">التحقق</dt>
                  <dd className="mt-0.5 flex flex-wrap items-center gap-2 text-sm text-ink-700">
                    <ShieldCheck className="h-4 w-4 text-green-600" />
                    <span>{last.verification ?? "—"}</span>
                    {last.sha256 && <code className="rounded bg-ink-100 px-1.5 py-0.5 text-xs" title={last.sha256}>sha256: {last.sha256.slice(0, 12)}…</code>}
                  </dd>
                </div>
              </dl>
            ) : (
              <p className="mt-3 text-sm text-amber-700" data-testid="backup-none">لا توجد نسخة ناجحة مسجّلة بعد. تُنشأ النسخة الأولى مع تفعيل الجدولة.</p>
            )}
          </Card>

          <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
            <Card className="p-4">
              <div className="flex items-center gap-2">
                <CalendarClock className="h-5 w-5 text-ink-500" />
                <h2 className="text-lg font-semibold text-ink-900">آخر محاولة نسخ</h2>
              </div>
              {lastRun ? (
                <div className="mt-3 space-y-2 text-sm">
                  <div className="flex items-center justify-between">
                    <span className="text-ink-500">{formatDateTime(lastRun.started_at)}</span>
                    <StatusBadge status={lastRun.status} />
                  </div>
                  <p className="text-ink-700">السبب: {REASON_AR[lastRun.reason] ?? lastRun.reason}</p>
                  {lastRun.error && <p className="text-red-700">الخطأ: {lastRun.error}</p>}
                </div>
              ) : (
                <p className="mt-3 text-sm text-ink-500">لم تُسجَّل أي محاولة بعد.</p>
              )}
            </Card>

            <Card className="p-4">
              <div className="flex items-center gap-2">
                <FlaskConical className="h-5 w-5 text-ink-500" />
                <h2 className="text-lg font-semibold text-ink-900">آخر تمرين استعادة</h2>
              </div>
              {drill ? (
                <div className="mt-3 space-y-2 text-sm">
                  <div className="flex items-center justify-between">
                    <span className="text-ink-500">{formatDateTime(drill.started_at)}</span>
                    <StatusBadge status={drill.status} />
                  </div>
                  {drill.verification && <p className="text-ink-700">الإثبات: {drill.verification}</p>}
                  {drill.error && <p className="text-red-700">الخطأ: {drill.error}</p>}
                </div>
              ) : (
                <p className="mt-3 text-sm text-ink-500">لم يُجرَ تمرين استعادة بعد. يُجرى شهريًا بعد التفعيل.</p>
              )}
            </Card>
          </div>
        </>
      </DataState>
    </div>
  );
}

export default function AdminBackup() {
  const { status, loading, error, reload } = useBackupStatus();
  return <BackupStatusView status={status} loading={loading} error={error} reload={reload} />;
}
