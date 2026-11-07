import { DemoBanner } from "../components/DemoBanner";
import { Outlet, Link, useLocation } from "react-router-dom";
import { Hotel, ShieldCheck, Languages } from "lucide-react";
import { useOrganizationName } from "../lib/organization";
import { GuestLangProvider, useGuestLang } from "../lib/guestLang";

/** GUEST-10: the pages a foreign guest must complete read in English too; the others stay Arabic. */
const BILINGUAL = /^\/(booking\/(lookup|status|payment|registration)|checkin)(\/|$)/;

export default function GuestLayout() {
  const { pathname } = useLocation();
  const bilingual = BILINGUAL.test(pathname);
  return (
    <GuestLangProvider active={bilingual}>
      <GuestShell bilingual={bilingual} />
    </GuestLangProvider>
  );
}

function GuestShell({ bilingual }: { bilingual: boolean }) {
  const orgName = useOrganizationName();
  const { en, t, lang, setLang, dir } = useGuestLang();
  return (
    <div dir={dir} lang={lang} className="flex min-h-screen flex-col bg-gradient-to-b from-brand-50 via-ink-50 to-white">
      <DemoBanner />
      <header className="border-b border-ink-100 bg-white/80 backdrop-blur">
        <div className="mx-auto flex max-w-5xl items-center justify-between gap-3 px-4 py-3">
          <Link to="/" className="flex min-w-0 items-center gap-2.5">
            <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-xl bg-brand-600 text-white">
              <Hotel className="h-5 w-5" />
            </div>
            <div className="min-w-0 leading-tight">
              <p className="truncate text-sm font-semibold text-ink-800">{orgName}</p>
              <p className="text-[11px] text-ink-400">{t("مساعد الاستقبال الذكي", "Digital reception")}</p>
            </div>
          </Link>
          <div className="flex items-center gap-3 text-xs text-ink-400">
            <span className="hidden items-center gap-1 sm:inline-flex"><ShieldCheck className="h-4 w-4 text-accent-500" /> {t("اتصال آمن", "Secure connection")}</span>
            {bilingual && (
              <button type="button" onClick={() => setLang(en ? "ar" : "en")} data-testid="guest-lang"
                className="inline-flex min-h-[44px] items-center gap-1.5 rounded-xl border border-ink-200 bg-white px-3 text-sm font-medium text-ink-700 hover:border-brand-300"
                lang={en ? "ar" : "en"} aria-label={en ? "العربية" : "English"}>
                <Languages className="h-4 w-4" aria-hidden="true" /> {en ? "العربية" : "English"}
              </button>
            )}
          </div>
        </div>
      </header>
      <main className="flex-1">
        <Outlet />
      </main>
      <footer className="border-t border-ink-100 bg-white/60 py-4 text-center text-xs text-ink-400">
        {orgName} © {new Date().getFullYear()} — {t("جميع الحقوق محفوظة", "All rights reserved")} ·{" "}
        <Link to="/privacy" className="hover:text-ink-600">{t("سياسة الخصوصية", "Privacy policy")}{en ? " (Arabic)" : ""}</Link> ·{" "}
        <Link to="/terms" className="hover:text-ink-600">{t("شروط الاستخدام", "Terms of use")}{en ? " (Arabic)" : ""}</Link> ·{" "}
        <Link to="/staff/login" className="hover:text-ink-600">{t("بوابة الموظفين والإدارة", "Staff portal")}</Link>
      </footer>
    </div>
  );
}
