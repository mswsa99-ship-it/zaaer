/**
 * IX-09: a failure while drawing a page never leaves a blank screen. A page file that failed to load (a new version
 * was published while the tab was open, or the network dropped) reloads once by itself; anything else shows what
 * happened and a reload button. And while the device is offline, a line at the top says that nothing is saved.
 */
import { Component, useEffect, useState, type ReactNode } from "react";

const RELOADED = "zaaer:chunk-reloaded";
const isChunkError = (e: unknown) => /dynamically imported module|Loading chunk|Importing a module script failed|error loading dynamically/i.test(String((e as Error)?.message ?? e));

export class AppErrorBoundary extends Component<{ children: ReactNode }, { error: unknown }> {
  state = { error: null as unknown };
  static getDerivedStateFromError(error: unknown) { return { error }; }
  componentDidCatch(error: unknown) {
    if (isChunkError(error)) {
      let again = false;
      try { again = sessionStorage.getItem(RELOADED) === "1"; sessionStorage.setItem(RELOADED, "1"); } catch { /* storage off */ }
      if (!again) window.location.reload();
    }
  }
  render() {
    if (!this.state.error) return this.props.children;
    const chunk = isChunkError(this.state.error);
    return (
      <div className="flex min-h-screen items-center justify-center bg-ink-50 px-4" role="alert" data-testid="app-error">
        <div className="card max-w-md p-6 text-center">
          <h1 className="text-lg font-semibold text-ink-800">{chunk ? "تعذّر تحميل الصفحة" : "حدث خطأ غير متوقع"}</h1>
          <p className="mt-2 text-sm text-ink-600">{chunk ? "تحقق من الاتصال بالإنترنت، ثم أعد التحميل." : "أعد تحميل الصفحة. إن تكرر الخطأ فأبلغ المشرف."}</p>
          <button type="button" className="btn-primary mt-4" onClick={() => { try { sessionStorage.removeItem(RELOADED); } catch { /* storage off */ } window.location.reload(); }}>إعادة التحميل</button>
        </div>
      </div>
    );
  }
}

export function OfflineBanner() {
  const [offline, setOffline] = useState(typeof navigator !== "undefined" && navigator.onLine === false);
  useEffect(() => {
    const on = () => setOffline(false), off = () => setOffline(true);
    window.addEventListener("online", on); window.addEventListener("offline", off);
    return () => { window.removeEventListener("online", on); window.removeEventListener("offline", off); };
  }, []);
  if (!offline) return null;
  return (
    <div role="status" className="sticky top-0 z-[60] bg-ink-800 px-4 py-2 text-center text-sm text-white" data-testid="offline-banner">
      لا يوجد اتصال بالإنترنت — لن تُحفظ العمليات حتى يعود الاتصال.
    </div>
  );
}
