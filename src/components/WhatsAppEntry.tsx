import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import QRCode from "qrcode";
import { MessageCircle, Phone, Clock, MapPin, PlayCircle } from "lucide-react";
import { whatsappApi, type PublicWhatsapp } from "../lib/api";
import { isDemo } from "../lib/supabase";
import { useBranch } from "../lib/branch";
import { Spinner } from "./ui";

/**
 * The guest's whole entry to the property: the QR code of the branch's WhatsApp number. Scanning it opens a chat
 * with the reception bot, which does everything there (bookings, registration link, payment status, arrival, key
 * code page, a human when needed). Until the owner connects the branch's number the page says so and shows the
 * branch phone — never a pretend chat.
 */
export function waLink(phone: string, text = "مرحبًا") {
  return `https://wa.me/${phone}?text=${encodeURIComponent(text)}`;
}

export default function WhatsAppEntry({ large = false }: { large?: boolean }) {
  const { branch, branches, branchId, setBranchId } = useBranch();
  const [info, setInfo] = useState<PublicWhatsapp | null>(null);
  const [qr, setQr] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (!branchId) return;
    let alive = true;
    setLoading(true); setQr(null);
    whatsappApi.publicInfo(branchId)
      .then(async (p) => {
        if (!alive) return;
        setInfo(p);
        if (p?.active && p.wa_phone) {
          const url = await QRCode.toDataURL(waLink(p.wa_phone), { margin: 1, width: 512, errorCorrectionLevel: "M", color: { dark: "#0f172a", light: "#ffffff" } });
          if (alive) setQr(url);
        }
      })
      .catch(() => { if (alive) setInfo(null); })
      .finally(() => { if (alive) setLoading(false); });
    return () => { alive = false; };
  }, [branchId]);

  const name = info?.branch_name ?? branch?.name_ar;
  const phone = info?.branch_phone ?? null;

  return (
    <div className={`mx-auto px-4 text-center ${large ? "max-w-lg py-6" : "max-w-md py-10 lg:py-14"}`}>
      {branches.length > 1 && (
        <select value={branchId ?? ""} onChange={(e) => setBranchId(e.target.value)} className="input mx-auto mb-6 max-w-xs" aria-label="الفرع">
          {branches.map((b) => <option key={b.id} value={b.id}>{b.name_ar}</option>)}
        </select>
      )}

      {loading ? (
        <Spinner className="mx-auto h-8 w-8" />
      ) : info?.active && info.wa_phone ? (
        <>
          <h1 className={`${large ? "text-4xl" : "text-3xl"} font-bold text-ink-800`}>امسح الرمز وتحدث معنا عبر واتساب</h1>
          <p className="mt-3 text-ink-500">الاستقبال كله في محادثة واحدة: حجوزاتك، تسجيل النزلاء، السداد، الوصول ورمز الدخول.</p>
          <div className="mx-auto mt-8 w-fit rounded-3xl border border-ink-100 bg-white p-4 shadow-sm">
            {qr ? <img src={qr} alt="رمز QR لمحادثة واتساب الاستقبال" className={large ? "h-80 w-80" : "h-64 w-64"} data-testid="wa-qr" /> : <Spinner className="m-24 h-6 w-6" />}
          </div>
          <a href={waLink(info.wa_phone)} target="_blank" rel="noopener noreferrer" className="btn-primary mx-auto mt-6 inline-flex w-full max-w-xs justify-center bg-[#25D366] hover:bg-[#1ebe5b]" data-testid="wa-open">
            <MessageCircle className="h-5 w-5" /> افتح واتساب
          </a>
          <p className="mt-3 text-sm text-ink-400" dir="ltr">+{info.wa_phone}</p>
          {isDemo && (
            <Link to="/whatsapp-demo" className="btn-outline mx-auto mt-4 inline-flex w-full max-w-xs justify-center text-sm" data-testid="wa-sim-link">
              <PlayCircle className="h-4 w-4" /> جرّب المحادثة هنا (محاكاة العرض)
            </Link>
          )}
        </>
      ) : (
        <>
          <div className="mx-auto mb-4 flex h-14 w-14 items-center justify-center rounded-2xl bg-brand-50 text-brand-600"><Clock className="h-7 w-7" /></div>
          <h1 className="text-2xl font-bold text-ink-800" data-testid="wa-soon">خدمة الاستقبال عبر واتساب قريبًا</h1>
          <p className="mt-3 text-ink-500">نجهّز رقم واتساب الاستقبال لهذا الفرع. للتواصل الآن اتصل بنا:</p>
          {phone && (
            <p className="mt-4 inline-flex items-center gap-2 rounded-2xl border border-ink-100 bg-white px-5 py-3 text-lg font-semibold text-ink-800 shadow-sm" dir="ltr">
              <Phone className="h-5 w-5 text-brand-600" /> {phone}
            </p>
          )}
        </>
      )}

      {name && <p className="mt-8 inline-flex items-center gap-1 text-xs text-ink-400"><MapPin className="h-3.5 w-3.5" /> {name}</p>}
    </div>
  );
}
