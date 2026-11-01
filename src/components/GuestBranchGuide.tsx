/**
 * The branch's guide on the guest's booking page (0056, SETUP-05): how to arrive, the photos, the entry videos (links),
 * and — while something is still due — the bank details for a transfer. Everything comes from the branch's settings.
 */
import { useEffect, useState } from "react";
import { Navigation, Video, Landmark, Copy, Check } from "lucide-react";
import { Card } from "./ui";
import { branchGuideApi, type BranchGuide } from "../lib/api";

export function GuestBranchGuide({ branchId, showBank }: { branchId: string; showBank: boolean }) {
  const [g, setG] = useState<BranchGuide | null>(null);
  const [photos, setPhotos] = useState<Record<string, string>>({});
  const [copied, setCopied] = useState(false);
  useEffect(() => {
    let live = true;
    branchGuideApi.publicGuide(branchId).then(async (x) => {
      if (!live) return; setG(x);
      const out: Record<string, string> = {};
      for (const p of (x?.photos ?? []).slice(0, 12)) { const d = await branchGuideApi.photo(p.id).catch(() => null); if (d) out[p.id] = d; }
      if (live) setPhotos(out);
    }).catch(() => setG(null));
    return () => { live = false; };
  }, [branchId]);
  if (!g) return null;
  const videos = g.videos.filter((v) => !v.room_id);
  const bank = showBank ? g.bank : null;
  if (!g.arrival_instructions && !videos.length && !g.photos.length && !bank) return null;

  const copy = async (t: string) => { try { await navigator.clipboard.writeText(t); setCopied(true); setTimeout(() => setCopied(false), 2000); } catch { /* the IBAN stays selectable */ } };

  return (
    <Card className="mt-6 space-y-4" data-testid="guest-branch-guide">
      {g.arrival_instructions && (
        <section>
          <h2 className="mb-1 flex items-center gap-2 text-base font-semibold text-ink-800"><Navigation className="h-4 w-4 text-brand-600" /> الوصول</h2>
          <p className="whitespace-pre-line text-sm leading-7 text-ink-600">{g.arrival_instructions}</p>
        </section>
      )}
      {videos.length > 0 && (
        <section>
          <h2 className="mb-2 flex items-center gap-2 text-base font-semibold text-ink-800"><Video className="h-4 w-4 text-brand-600" /> فيديو الدخول</h2>
          <ul className="space-y-2">{videos.map((v) => <li key={v.id}><a href={v.url} target="_blank" rel="noopener noreferrer" className="btn-outline w-full justify-start text-sm"><Video className="h-4 w-4" /> {v.caption || "مشاهدة الفيديو"}</a></li>)}</ul>
        </section>
      )}
      {g.photos.length > 0 && Object.keys(photos).length > 0 && (
        <section>
          <h2 className="mb-2 text-base font-semibold text-ink-800">صور المكان</h2>
          <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
            {g.photos.filter((p) => photos[p.id]).map((p) => <figure key={p.id}><img src={photos[p.id]} alt={p.caption ?? "صورة الفرع"} loading="lazy" className="aspect-[4/3] w-full rounded-lg object-cover" />{p.caption && <figcaption className="mt-1 text-xs text-ink-500">{p.caption}</figcaption>}</figure>)}
          </div>
        </section>
      )}
      {bank && (
        <section className="rounded-xl bg-ink-50 p-3" data-testid="guest-bank">
          <h2 className="mb-2 flex items-center gap-2 text-sm font-semibold text-ink-800"><Landmark className="h-4 w-4 text-brand-600" /> الدفع بالتحويل البنكي</h2>
          <dl className="space-y-1 text-sm text-ink-700">
            <div className="flex gap-2"><dt className="text-ink-500">البنك:</dt><dd>{bank.bank_name}</dd></div>
            <div className="flex gap-2"><dt className="text-ink-500">المستفيد:</dt><dd>{bank.beneficiary}</dd></div>
            <div className="flex flex-wrap items-center gap-2"><dt className="text-ink-500">الآيبان:</dt><dd className="select-all font-mono" dir="ltr">{bank.iban.replace(/(.{4})/g, "$1 ").trim()}</dd>
              <button type="button" className="btn-ghost min-h-[44px] text-xs" onClick={() => copy(bank.iban)}>{copied ? <><Check className="h-3.5 w-3.5" /> نُسخ</> : <><Copy className="h-3.5 w-3.5" /> نسخ</>}</button></div>
          </dl>
          <p className="mt-2 text-xs text-ink-500">بعد التحويل أرسل الإيصال للاستقبال ليُسجَّل الدفع برقم العملية.</p>
        </section>
      )}
    </Card>
  );
}
