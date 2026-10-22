import { DemoBanner } from "../components/DemoBanner";
import { Outlet, Link } from "react-router-dom";
import { Hotel, ShieldCheck, LogIn } from "lucide-react";

export default function GuestLayout() {
  return (
    <div className="flex min-h-screen flex-col bg-gradient-to-b from-brand-50 via-ink-50 to-white">
      <DemoBanner />
      <header className="border-b border-ink-100 bg-white/80 backdrop-blur">
        <div className="mx-auto flex max-w-5xl items-center justify-between px-4 py-3">
          <Link to="/" className="flex items-center gap-2.5">
            <div className="flex h-9 w-9 items-center justify-center rounded-xl bg-brand-600 text-white">
              <Hotel className="h-5 w-5" />
            </div>
            <div className="leading-tight">
              <p className="text-sm font-semibold text-ink-800">منازل الراحة</p>
              <p className="text-[11px] text-ink-400">مساعد الاستقبال الذكي</p>
            </div>
          </Link>
          <div className="flex items-center gap-4 text-xs text-ink-400">
            <span className="inline-flex items-center gap-1"><ShieldCheck className="h-4 w-4 text-accent-500" /> اتصال آمن</span>
            <Link to="/staff/login" className="inline-flex items-center gap-1 rounded-lg border border-ink-200 px-2.5 py-1.5 font-medium text-ink-600 hover:border-brand-300 hover:text-brand-700"><LogIn className="h-3.5 w-3.5" /> دخول الموظفين</Link>
          </div>
        </div>
      </header>
      <main className="flex-1">
        <Outlet />
      </main>
      <footer className="border-t border-ink-100 bg-white/60 py-4 text-center text-xs text-ink-400">
        منازل الراحة © {new Date().getFullYear()} — جميع الحقوق محفوظة ·{" "}
        <Link to="/privacy" className="hover:text-ink-600">سياسة الخصوصية</Link> ·{" "}
        <Link to="/terms" className="hover:text-ink-600">شروط الاستخدام</Link> ·{" "}
        <Link to="/staff/login" className="hover:text-ink-600">بوابة الموظفين والإدارة</Link>
      </footer>
    </div>
  );
}
