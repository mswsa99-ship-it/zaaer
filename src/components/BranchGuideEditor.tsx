/**
 * The branch's guide for guests (0056, SETUP-05), edited inside «تعديل فرع»:
 *  - the arrival instructions and the bank details shown to a guest who pays by transfer (an IBAN is checked);
 *  - the gallery (photos up to 1 MB each) and the entry videos (https links — a video is linked, not uploaded).
 * A photo or video is archived with a reason and can be restored; nothing is erased.
 */
import { useCallback, useEffect, useState } from "react";
import { Image as ImageIcon, Video, Archive, RotateCcw, Plus } from "lucide-react";
import { ErrorBanner, Spinner } from "./ui";
import { Field, ReasonInput } from "./forms";
import { branchGuideApi, toArabicError, type MediaItem } from "../lib/api";

export function BranchGuideEditor({ branchId }: { branchId: string }) {
  const [g, setG] = useState({ arrival_instructions: "", bank_name: "", bank_beneficiary: "", bank_iban: "" });
  const [items, setItems] = useState<MediaItem[]>([]);
  const [thumbs, setThumbs] = useState<Record<string, string | null>>({});
  const [showArchived, setShowArchived] = useState(false);
  const [video, setVideo] = useState({ url: "", caption: "" });
  const [archiving, setArchiving] = useState<MediaItem | null>(null);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const [guide, media] = await Promise.all([branchGuideApi.publicGuide(branchId), branchGuideApi.media(branchId, true)]);
      setG({ arrival_instructions: guide?.arrival_instructions ?? "", bank_name: guide?.bank?.bank_name ?? "", bank_beneficiary: guide?.bank?.beneficiary ?? "", bank_iban: guide?.bank?.iban ?? "" });
      setItems(media);
      const out: Record<string, string | null> = {};
      for (const m of media.filter((x) => x.kind === "photo")) out[m.id] = await branchGuideApi.photo(m.id);
      setThumbs(out);
    } catch (e) { setError(toArabicError(e)); }
  }, [branchId]);
  useEffect(() => { void load(); }, [load]);

  async function run(key: string, fn: () => Promise<unknown>, ok?: string) {
    setBusy(key); setError(null); setSaved(null);
    try { await fn(); await load(); if (ok) setSaved(ok); return true; } catch (e) { setError(toArabicError(e)); return false; } finally { setBusy(null); }
  }

  const pickPhoto = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]; e.target.value = ""; if (!file) return;
    if (file.size > 1048576) { setError("حجم الصورة أكبر من 1 ميجابايت."); return; }
    await run("photo", async () => {
      const b64 = await new Promise<string>((res, rej) => { const r = new FileReader(); r.onload = () => res(String(r.result).replace(/^data:[^,]*,/, "")); r.onerror = () => rej(new Error("VALIDATION: image")); r.readAsDataURL(file); });
      await branchGuideApi.upsertMedia({ branch_id: branchId, kind: "photo", data_base64: b64 });
    }, "أُضيفت الصورة.");
  };

  const shown = items.filter((m) => showArchived ? m.archived_at : !m.archived_at);
  const photos = shown.filter((m) => m.kind === "photo"); const videos = shown.filter((m) => m.kind === "video");
  const archivedCount = items.filter((m) => m.archived_at).length;
  const set = (k: keyof typeof g) => (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) => setG({ ...g, [k]: e.target.value });

  return (
    <div className="mt-4 space-y-4 rounded-xl border border-ink-100 p-3" data-testid="branch-guide">
      <p className="text-xs font-semibold text-ink-600">دليل النزيل — يظهر في صفحة حجزه</p>
      {error && <ErrorBanner message={error} />}
      {saved && <p className="rounded-lg bg-success-500/10 p-2 text-xs text-success-600" role="status">{saved}</p>}

      <div className="grid gap-3 sm:grid-cols-2">
        <Field label="تعليمات الوصول" className="sm:col-span-2" hint="كيف يصل النزيل للمبنى ويدخل الوحدة: المدخل، الموقف، المصعد…">
          <textarea className="input min-h-[96px]" maxLength={4000} value={g.arrival_instructions} onChange={set("arrival_instructions")} />
        </Field>
        <Field label="اسم البنك"><input className="input" maxLength={80} value={g.bank_name} onChange={set("bank_name")} /></Field>
        <Field label="اسم المستفيد"><input className="input" maxLength={120} value={g.bank_beneficiary} onChange={set("bank_beneficiary")} /></Field>
        <Field label="رقم الآيبان" className="sm:col-span-2" hint="يظهر للنزيل الذي يدفع بالتحويل. اتركه فارغًا لإخفاء بيانات البنك.">
          <input className="input font-mono" dir="ltr" maxLength={34} value={g.bank_iban} onChange={set("bank_iban")} placeholder="SA00 0000 0000 0000 0000 0000" />
        </Field>
      </div>
      <div className="flex justify-end">
        <button type="button" className="btn-primary text-sm" disabled={busy !== null} data-testid="save-branch-guide"
          onClick={() => run("guide", () => branchGuideApi.setGuide({ branch_id: branchId, ...g }), "حُفظ دليل النزيل.")}>
          {busy === "guide" ? <Spinner className="h-4 w-4" /> : "حفظ الدليل"}
        </button>
      </div>

      <div className="flex flex-wrap items-center gap-2 border-t border-ink-100 pt-3">
        <p className="text-xs font-semibold text-ink-600">الصور والفيديو</p>
        {archivedCount > 0 && <button type="button" className="btn-ghost mr-auto min-h-[44px] text-xs" onClick={() => setShowArchived(!showArchived)}>{showArchived ? "عرض الحالية" : `المؤرشفة (${archivedCount})`}</button>}
      </div>
      <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
        {photos.map((m) => (
          <figure key={m.id} className="relative overflow-hidden rounded-lg bg-ink-50">
            {thumbs[m.id] ? <img src={thumbs[m.id]!} alt={m.caption ?? "صورة الفرع"} className="aspect-[4/3] w-full object-cover" /> : <div className="flex aspect-[4/3] items-center justify-center text-ink-400"><ImageIcon className="h-5 w-5" /></div>}
            <figcaption className="flex items-center gap-1 p-1.5">
              <input className="input min-w-0 flex-1 py-1 text-xs" maxLength={160} defaultValue={m.caption ?? ""} placeholder="وصف" aria-label="وصف الصورة" disabled={!!m.archived_at}
                onBlur={(e) => { if (e.target.value !== (m.caption ?? "")) void run(m.id, () => branchGuideApi.upsertMedia({ id: m.id, caption: e.target.value })); }} />
              {m.archived_at
                ? <button type="button" className="btn-ghost min-h-[44px] min-w-[44px]" aria-label="استعادة الصورة" onClick={() => run(m.id, () => branchGuideApi.archiveMedia(m.id, null, false))}><RotateCcw className="h-4 w-4" /></button>
                : <button type="button" className="btn-ghost min-h-[44px] min-w-[44px]" aria-label="أرشفة الصورة" onClick={() => { setArchiving(m); setReason(""); }}><Archive className="h-4 w-4" /></button>}
            </figcaption>
          </figure>
        ))}
        {!showArchived && (
          <label className="flex aspect-[4/3] cursor-pointer flex-col items-center justify-center gap-1 rounded-lg border border-dashed border-ink-200 text-xs text-ink-500">
            {busy === "photo" ? <Spinner className="h-4 w-4" /> : <><Plus className="h-4 w-4" /> صورة (حتى 1 ميجابايت)</>}
            <input type="file" accept="image/png,image/jpeg,image/webp" className="hidden" onChange={pickPhoto} disabled={busy !== null} aria-label="إضافة صورة للفرع" />
          </label>
        )}
      </div>

      {videos.length > 0 && (
        <ul className="space-y-2">
          {videos.map((m) => (
            <li key={m.id} className="flex items-center gap-2 rounded-lg bg-ink-50 p-2 text-xs">
              <Video className="h-4 w-4 shrink-0 text-brand-600" />
              <div className="min-w-0 flex-1"><p className="truncate text-ink-700">{m.caption || "فيديو"}</p><p className="truncate text-ink-400" dir="ltr">{m.url}</p></div>
              {m.archived_at
                ? <button type="button" className="btn-ghost min-h-[44px] min-w-[44px]" aria-label="استعادة الفيديو" onClick={() => run(m.id, () => branchGuideApi.archiveMedia(m.id, null, false))}><RotateCcw className="h-4 w-4" /></button>
                : <button type="button" className="btn-ghost min-h-[44px] min-w-[44px]" aria-label="أرشفة الفيديو" onClick={() => { setArchiving(m); setReason(""); }}><Archive className="h-4 w-4" /></button>}
            </li>
          ))}
        </ul>
      )}
      {!showArchived && (
        <div className="grid items-end gap-2 sm:grid-cols-[1fr_1fr_auto]">
          <Field label="رابط فيديو الدخول" hint="رابط https من يوتيوب أو Google Drive أو غيرهما؛ لا يُرفع الفيديو نفسه."><input className="input" dir="ltr" maxLength={500} value={video.url} onChange={(e) => setVideo({ ...video, url: e.target.value })} placeholder="https://…" /></Field>
          <Field label="وصف الفيديو"><input className="input" maxLength={160} value={video.caption} onChange={(e) => setVideo({ ...video, caption: e.target.value })} placeholder="طريقة الدخول للمبنى" /></Field>
          <button type="button" className="btn-outline min-h-[44px] text-sm" disabled={busy !== null || !video.url.trim()}
            onClick={async () => { if (await run("video", () => branchGuideApi.upsertMedia({ branch_id: branchId, kind: "video", url: video.url.trim(), caption: video.caption }), "أُضيف الفيديو.")) setVideo({ url: "", caption: "" }); }}>
            {busy === "video" ? <Spinner className="h-4 w-4" /> : "إضافة"}
          </button>
        </div>
      )}

      {archiving && (
        <div className="rounded-lg border border-danger-500/30 p-3" role="group" aria-label="أرشفة">
          <p className="mb-2 text-xs text-ink-600">{archiving.kind === "photo" ? "تختفي الصورة عن النزيل وتبقى في «المؤرشفة»." : "يختفي الفيديو عن النزيل ويبقى في «المؤرشفة»."}</p>
          <ReasonInput value={reason} onChange={setReason} />
          <div className="flex justify-end gap-2">
            <button type="button" className="btn-outline text-xs" onClick={() => setArchiving(null)}>إلغاء</button>
            <button type="button" className="btn-danger text-xs" disabled={busy !== null}
              onClick={async () => { if (!reason.trim()) { setError(toArabicError(new Error("VALIDATION: reason"))); return; } if (await run(archiving.id, () => branchGuideApi.archiveMedia(archiving.id, reason.trim()))) setArchiving(null); }}>أرشفة</button>
          </div>
        </div>
      )}
    </div>
  );
}
