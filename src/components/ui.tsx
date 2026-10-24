import type { HTMLAttributes, ReactNode } from "react";
import { cn } from "../lib/utils";

/** A white card; other attributes (data-testid, role…) reach the element. */
export function Card({ className, children, ...rest }: { className?: string; children: ReactNode } & Omit<HTMLAttributes<HTMLDivElement>, "className" | "children">) {
  return <div className={cn("card p-5", className)} {...rest}>{children}</div>;
}

export function SectionTitle({ title, subtitle, action }: { title: string; subtitle?: string; action?: ReactNode }) {
  return (
    // on a phone the action (branch picker, buttons) moves under the title instead of squeezing it into a narrow column
    <div className="mb-5 flex flex-wrap items-start justify-between gap-x-4 gap-y-3">
      <div className="min-w-0 flex-1 basis-64">
        <h2 className="text-xl font-semibold text-ink-800">{title}</h2>
        {subtitle && <p className="mt-1 text-sm text-ink-500">{subtitle}</p>}
      </div>
      {action}
    </div>
  );
}

export function Badge({ children, className }: { children: ReactNode; className?: string }) {
  return <span className={cn("badge", className)}>{children}</span>;
}

export function EmptyState({ icon, title, description }: { icon?: ReactNode; title: string; description?: string }) {
  return (
    <div className="flex flex-col items-center justify-center rounded-2xl border border-dashed border-ink-200 bg-ink-50/50 px-6 py-16 text-center">
      {icon && <div className="mb-4 text-ink-300">{icon}</div>}
      <h3 className="text-base font-medium text-ink-700">{title}</h3>
      {description && <p className="mt-1.5 max-w-sm text-sm text-ink-400">{description}</p>}
    </div>
  );
}

export function Spinner({ className }: { className?: string }) {
  return (
    <div className={cn("inline-block h-5 w-5 animate-spin rounded-full border-2 border-ink-200 border-t-brand-500", className)} />
  );
}

export function LoadingScreen({ label = "جارٍ التحميل…" }: { label?: string }) {
  return (
    <div className="flex min-h-[40vh] flex-col items-center justify-center gap-3 text-ink-400">
      <Spinner className="h-8 w-8" />
      <p className="text-sm">{label}</p>
    </div>
  );
}

/** A failed load: says so and offers a retry — never looks like an empty list (decision 42, G23/U04). */
export function LoadErrorCard({ message, onRetry }: { message: string; onRetry?: () => void }) {
  return (
    <div role="alert" className="flex flex-col items-center justify-center gap-3 rounded-2xl border border-danger-500/30 bg-danger-500/5 px-6 py-12 text-center">
      <h3 className="text-base font-medium text-danger-600">تعذّر تحميل البيانات</h3>
      <p className="max-w-md text-sm text-ink-500">{message}</p>
      {onRetry && <button type="button" onClick={onRetry} className="btn-outline text-sm">إعادة المحاولة</button>}
    </div>
  );
}

/**
 * The four states of a list, in one place (decision 42): loading, failed (with retry), empty, or the content.
 * A failed reload while data is already shown keeps the data and puts the error above it.
 */
export function DataState({ loading, error, empty, onRetry, emptyIcon, emptyTitle, emptyDescription, children }: {
  loading: boolean; error: string | null; empty: boolean; onRetry?: () => void;
  emptyIcon?: ReactNode; emptyTitle: string; emptyDescription?: string; children: ReactNode;
}) {
  if (loading) return <LoadingScreen />;
  if (error && empty) return <LoadErrorCard message={error} onRetry={onRetry} />;
  if (empty) return <EmptyState icon={emptyIcon} title={emptyTitle} description={emptyDescription} />;
  return (
    <>
      {error && <div className="mb-4 flex flex-wrap items-center gap-3"><ErrorBanner message={error} />{onRetry && <button type="button" onClick={onRetry} className="btn-outline text-xs">إعادة المحاولة</button>}</div>}
      {children}
    </>
  );
}

export function ErrorBanner({ message }: { message: string }) {
  return (
    <div className="rounded-xl border border-danger-500/30 bg-danger-500/10 px-4 py-3 text-sm text-danger-600">
      {message}
    </div>
  );
}
