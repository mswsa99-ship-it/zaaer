import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { ArrowLeft, ExternalLink, MapPin, Phone, BookCheck } from "lucide-react";
import { guestApi, type PublicBranch } from "../../lib/api";
import { useBranch } from "../../lib/branch";
import { Card, Spinner } from "../../components/ui";

/**
 * «احجز» — decision 23: the property is not a direct booking point. The page shows no availability and no prices: a
 * visitor without a booking is sent to the branch's booking platform («رابط منصة الحجز», set by the owner); one with a
 * booking goes to «حجوزاتي». When the branch has no platform link yet, the reception's number is the way.
 */
export default function BookingNew() {
  const { branchId, branches, setBranchId } = useBranch();
  const [b, setB] = useState<PublicBranch | null>(null);
  const [image, setImage] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (!branchId) return;
    let alive = true;
    setLoading(true); setImage(null);
    guestApi.branch(branchId).then(async (p) => {
      if (!alive) return;
      setB(p);
      if (p?.image_version) { try { const img = await guestApi.branchMedia(branchId, "image"); if (alive) setImage(img); } catch { /* no image */ } }
    }).catch(() => { if (alive) setB(null); }).finally(() => { if (alive) setLoading(false); });
    return () => { alive = false; };
  }, [branchId]);

  return (
    <div className="mx-auto max-w-xl px-4 py-8 lg:py-12">
      <Link to="/reception" className="mb-4 inline-flex items-center gap-1.5 text-sm text-ink-400 hover:text-ink-600"><ArrowLeft className="h-4 w-4" /> رجوع</Link>
      <h1 className="mb-5 text-2xl font-bold text-ink-800">احجز إقامتك</h1>
      {branches.length > 1 && (
        <select value={branchId ?? ""} onChange={(e) => setBranchId(e.target.value)} className="input mb-4" aria-label="الفرع">
          {branches.map((x) => <option key={x.id} value={x.id}>{x.name_ar}</option>)}
        </select>
      )}
      {loading ? <Spinner className="mx-auto h-6 w-6" /> : (
        <Card className="space-y-4" data-testid="booking-platform-card">
          {image && <img src={image} alt="" className="max-h-56 w-full rounded-xl object-cover" />}
          <div>
            <h2 className="text-lg font-semibold text-ink-800">{b?.name_ar}</h2>
            {b?.address && <p className="mt-1 flex items-center gap-1.5 text-sm text-ink-500"><MapPin className="h-4 w-4 shrink-0" /> {b.city ? `${b.city} — ` : ""}{b.address}</p>}
          </div>
          <p className="text-sm text-ink-600">الحجوزات الجديدة والأسعار والتوفر عبر منصة الحجز المعتمدة فقط. بعد الحجز تجد حجزك في «حجوزاتي» برقم جوالك لإكمال إجراءات الوصول.</p>
          {b?.booking_platform_url ? (
            <a href={b.booking_platform_url} target="_blank" rel="noopener noreferrer" className="btn-primary w-full" data-testid="platform-link">احجز عبر المنصة <ExternalLink className="h-4 w-4" /></a>
          ) : (
            <div className="rounded-xl bg-ink-50 px-4 py-3 text-sm text-ink-600" data-testid="platform-missing">
              لم يُضبط رابط منصة الحجز لهذا الفرع بعد. تواصل مع الاستقبال ليوجّهك إلى الحجز{b?.phone ? <>: <a href={`tel:${b.phone}`} className="font-medium text-brand-700" dir="ltr">{b.phone}</a></> : "."}
            </div>
          )}
          <div className="flex flex-wrap gap-2 text-sm">
            <Link to="/booking/lookup" className="btn-outline"><BookCheck className="h-4 w-4" /> حجوزاتي</Link>
            {b?.map_url && <a href={b.map_url} target="_blank" rel="noopener noreferrer" className="btn-outline" data-testid="map-link"><MapPin className="h-4 w-4" /> الموقع على الخريطة</a>}
            {b?.phone && <a href={`tel:${b.phone}`} className="btn-outline"><Phone className="h-4 w-4" /> الاستقبال</a>}
          </div>
        </Card>
      )}
    </div>
  );
}
