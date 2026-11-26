import { roomaiAsset } from "../lib/brand";
import { DemoBanner } from "../components/DemoBanner";
import { useState } from "react";
import { Outlet, Link, useLocation } from "react-router-dom";
import { Hotel, ShieldCheck, Languages } from "lucide-react";
import { useOrganization } from "../lib/organization";
import { guestLogoSource } from "../lib/guestBranding";
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
  const org = useOrganization();
  const orgName = org?.name_ar ?? "";
  const logo = guestLogoSource(org?.logo);
  const [failedLogo, setFailedLogo] = useState<string | null>(null);
  const { en, t, lang, setLang, dir } = useGuestLang();
  return (
    <div dir={dir} lang={lang} className="flex min-h-screen flex-col bg-rai-canvas text-rai-ink">
      <DemoBanner />
      <header className="border-b border-rai-line bg-rai-shell backdrop-blur">
        <div className="mx-auto flex max-w-5xl items-center justify-between gap-3 px-4 py-3">
          <Link to="/" className="flex min-w-0 items-center gap-2.5">
            {logo && failedLogo !== logo ? (
              <img src={logo} alt={`${t("شعار", "Logo of")} ${orgName}`}
                className="h-10 max-w-[100px] shrink-0 object-contain" referrerPolicy="no-referrer"
                onError={() => setFailedLogo(logo)} />
            ) : <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-xl bg-rai-action text-rai-action-ink">
              <Hotel className="h-5 w-5" aria-hidden="true" />
            </div>}
            <div className="min-w-0 leading-tight">
              <p className="truncate text-sm font-semibold text-rai-ink">{orgName}</p>
            </div>
          </Link>
          <div className="flex items-center gap-3 text-xs text-rai-ink-muted">
            {typeof window !== "undefined" && window.location.protocol === "https:" && <span className="hidden items-center gap-1 sm:inline-flex"><ShieldCheck className="h-4 w-4 text-rai-spark-text" /> {t("اتصال آمن", "Secure connection")}</span>}
            {bilingual && (
              <button type="button" onClick={() => setLang(en ? "ar" : "en")} data-testid="guest-lang"
                className="inline-flex min-h-[44px] items-center gap-1.5 rounded-xl border border-rai-line bg-rai-shell px-3 text-sm font-medium text-rai-ink hover:border-rai-line"
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
      <footer className="border-t border-rai-line bg-rai-shell py-4 text-center text-xs text-rai-ink-muted">
        {orgName} © {new Date().getFullYear()} — {t("جميع الحقوق محفوظة", "All rights reserved")} ·{" "}
        <Link to="/privacy" className="hover:text-rai-ink-muted">{t("سياسة الخصوصية", "Privacy policy")}{en ? " (Arabic)" : ""}</Link> ·{" "}
        <Link to="/terms" className="hover:text-rai-ink-muted">{t("شروط الاستخدام", "Terms of use")}{en ? " (Arabic)" : ""}</Link> ·{" "}
        <Link to="/staff/login" className="hover:text-rai-ink-muted">{t("بوابة الموظفين والإدارة", "Staff portal")}</Link>
        {/* plan 3.5 + approved identity (GuestBrand): the platform's name lives in the footer only, at caption
            size with the 16px mark — the arch in the text colour, the spark in the approved spark value #0FA3B1 */}
        <p className="mt-2 flex items-center justify-center gap-1.5" data-testid="powered-by-roomai"><span className="flex items-center gap-1.5" data-testid="guest-powered-by">
          <img src={roomaiAsset("roomai-mark.svg")} alt="" width="16" height="16" className="owner-logo-day shrink-0" />
          <img src={roomaiAsset("roomai-mark-reversed.svg")} alt="" width="16" height="16" className="owner-logo-night shrink-0" />
          {t("يعمل بـ RoomAI", "Powered by RoomAI")}
        </span></p>
      </footer>
    </div>
  );
}
