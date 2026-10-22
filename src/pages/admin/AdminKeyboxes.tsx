import { useEffect, useState, useCallback } from "react";
import { supabase } from "../../lib/supabase";
import { staffApi, toArabicError } from "../../lib/api";
import { useBranch } from "../../lib/branch";
import { SectionTitle, LoadingScreen, Card, Badge, Spinner, ErrorBanner } from "../../components/ui";
import { KeyRound, Lock, History } from "lucide-react";
import { formatDateTime } from "../../lib/utils";

interface KeyboxRow {
  id: string; room_id: string; code_status: string; code_version: number; field_tested: boolean;
  last_changed_at: string | null; last_delivered_at: string | null; last_reservation_id: string | null;
  room?: { room_number: string; status: string } | { room_number: string; status: string }[] | null;
}
interface RotationRow { id: string; from_version: number | null; to_version: number; field_tested: boolean; created_at: string; room_id: string }

const ROOM_STATUS_AR: Record<string, string> = {
  available: "متاحة", reserved: "محجوزة", occupied: "مشغولة", cleaning: "تنظيف", maintenance: "صيانة", blocked: "محجوبة", out_of_service: "خارج الخدمة", ready: "جاهزة",
};

function roomOf(k: KeyboxRow) { return Array.isArray(k.room) ? k.room[0] : k.room ?? undefined; }

export default function AdminKeyboxes() {
  const { branchId, branches, setBranchId } = useBranch();
  const [boxes, setBoxes] = useState<KeyboxRow[]>([]);
  const [events, setEvents] = useState<RotationRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [acting, setActing] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [rotateFor, setRotateFor] = useState<KeyboxRow | null>(null);

  const load = useCallback(async () => {
    if (!branchId) return;
    setError(null);
    const { data, error: e } = await supabase
      .from("keyboxes")
      .select("id, room_id, code_status, code_version, field_tested, last_changed_at, last_delivered_at, last_reservation_id, room:rooms(room_number,status)")
      .eq("branch_id", branchId);
    if (e) setError(toArabicError(e));
    const list = ((data as unknown as KeyboxRow[]) ?? []).sort((a, b) => (roomOf(a)?.room_number ?? "").localeCompare(roomOf(b)?.room_number ?? "", "en", { numeric: true }));
    setBoxes(list);
    const ids = list.map((k) => k.room_id);
    if (ids.length) {
      const { data: ev } = await supabase.from("code_rotation_events").select("id, from_version, to_version, field_tested, created_at, room_id").in("room_id", ids).order("created_at", { ascending: false }).limit(40);
      setEvents((ev as RotationRow[]) ?? []);
    } else setEvents([]);
    setLoading(false);
  }, [branchId]);

  useEffect(() => { load(); }, [load]);

  async function markTested(roomId: string) {
    setActing(roomId); setError(null);
    try { await staffApi.markKeyboxTested(roomId); await load(); } catch (e) { setError(toArabicError(e)); }
    setActing(null);
  }

  if (loading && branchId) return <LoadingScreen />;

  const roomNumber = (roomId: string) => roomOf(boxes.find((b) => b.room_id === roomId) ?? ({} as KeyboxRow))?.room_number ?? "—";

  return (
    <div>
      <SectionTitle title="صناديق المفاتيح" subtitle={`${boxes.length} صندوق`} action={
        <select className="input w-auto" value={branchId ?? ""} onChange={(e) => setBranchId(e.target.value)}>
          {branches.map((b) => <option key={b.id} value={b.id}>{b.name_ar}</option>)}
        </select>
      } />
      {error && <div className="mb-4"><ErrorBanner message={error} /></div>}
      <div className="mb-4 rounded-xl bg-ink-50 p-4 text-sm text-ink-600">
        <p className="flex items-center gap-2"><Lock className="h-4 w-4 text-brand-600" /> الرموز مخزّنة مشفّرة على الخادم فقط ولا تُعرض هنا. يجب تغيير الرمز بعد كل مغادرة واختباره ميدانيًا قبل تسليم الغرفة لنزيل جديد.</p>
      </div>
      <div className="grid gap-4 lg:grid-cols-3">
        <div className="grid gap-3 sm:grid-cols-2 lg:col-span-2">
          {boxes.map((k) => {
            const room = roomOf(k);
            return (
              <Card key={k.id}>
                <div className="flex items-start justify-between">
                  <div className="flex items-center gap-3">
                    <KeyRound className={`h-5 w-5 ${k.code_status === "active" ? "text-success-600" : "text-warning-600"}`} />
                    <div>
                      <p className="text-sm font-semibold text-ink-800">غرفة {room?.room_number ?? "—"}</p>
                      <p className="text-xs text-ink-400">إصدار {k.code_version} · {k.last_changed_at ? formatDateTime(k.last_changed_at) : "لم يُغيّر"}</p>
                      {k.last_delivered_at && <p className="text-xs text-ink-300">آخر تسليم: {formatDateTime(k.last_delivered_at)}</p>}
                    </div>
                  </div>
                  <div className="flex flex-col items-end gap-1">
                    <Badge className={k.code_status === "active" ? "bg-success-500/10 text-success-600" : "bg-warning-500/10 text-warning-600"}>{k.code_status === "active" ? "نشط" : "يحتاج تغيير"}</Badge>
                    {room && <Badge className="bg-ink-100 text-ink-500">{ROOM_STATUS_AR[room.status] ?? room.status}</Badge>}
                    <Badge className={k.field_tested ? "bg-success-500/10 text-success-600" : "bg-danger-500/10 text-danger-600"}>{k.field_tested ? "مُختبر ميدانيًا" : "غير مُختبر"}</Badge>
                  </div>
                </div>
                <div className="mt-3 flex items-center gap-2 border-t border-ink-50 pt-3">
                  {!k.field_tested && (
                    <button onClick={() => markTested(k.room_id)} disabled={acting === k.room_id} className="btn-outline text-xs">
                      {acting === k.room_id ? <Spinner className="h-3 w-3" /> : "تأكيد الاختبار"}
                    </button>
                  )}
                  <button onClick={() => setRotateFor(k)} className="btn-primary text-xs">تغيير الرمز</button>
                </div>
              </Card>
            );
          })}
          {boxes.length === 0 && <p className="text-sm text-ink-400">لا توجد صناديق لهذا الفرع.</p>}
        </div>
        <Card>
          <h3 className="mb-3 flex items-center gap-2 text-sm font-semibold text-ink-700"><History className="h-4 w-4 text-brand-600" /> سجل تغيير الرموز</h3>
          {events.length === 0 ? <p className="text-xs text-ink-400">لا يوجد سجل.</p> : (
            <ul className="max-h-[32rem] space-y-2 overflow-y-auto text-xs">
              {events.map((e) => (
                <li key={e.id} className="rounded-lg bg-ink-50 px-3 py-2">
                  <div className="flex items-center justify-between">
                    <span className="font-medium text-ink-700">غرفة {roomNumber(e.room_id)}</span>
                    <span className="text-ink-400" dir="ltr">v{e.from_version ?? "—"} → v{e.to_version}</span>
                  </div>
                  <div className="mt-0.5 flex items-center justify-between text-ink-400">
                    <span>{formatDateTime(e.created_at)}</span>
                    <span className={e.field_tested ? "text-success-600" : "text-warning-600"}>{e.field_tested ? "مُختبر" : "غير مُختبر"}</span>
                  </div>
                </li>
              ))}
            </ul>
          )}
        </Card>
      </div>
      {rotateFor && <RotateModal box={rotateFor} onClose={() => setRotateFor(null)} onDone={async () => { setRotateFor(null); await load(); }} />}
    </div>
  );
}

function RotateModal({ box, onClose, onDone }: { box: KeyboxRow; onClose: () => void; onDone: () => Promise<void> }) {
  const [code, setCode] = useState("");
  const [code2, setCode2] = useState("");
  const [tested, setTested] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const valid = /^\d{4,8}$/.test(code);
  const room = roomOf(box);

  async function submit() {
    setError(null);
    if (!valid) { setError("الرمز يجب أن يكون من 4 إلى 8 أرقام."); return; }
    if (code !== code2) { setError("الرمزان غير متطابقين."); return; }
    setBusy(true);
    try { await staffApi.rotateKeybox(box.room_id, code, tested); await onDone(); } catch (e) { setError(toArabicError(e)); }
    setBusy(false);
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-ink-900/40 p-4" role="dialog" aria-modal="true">
      <Card className="w-full max-w-md">
        <h3 className="mb-1 text-base font-semibold text-ink-800">تغيير رمز صندوق غرفة {room?.room_number ?? ""}</h3>
        <p className="mb-4 text-xs text-ink-400">الإصدار الحالي {box.code_version}. يجب أن يختلف الرمز الجديد عن السابق. يُحفظ مشفّرًا ولن يُعرض مجددًا.</p>
        {error && <div className="mb-3"><ErrorBanner message={error} /></div>}
        <div className="space-y-3">
          <div>
            <label className="label">الرمز الجديد (4–8 أرقام)</label>
            <input className="input" dir="ltr" type="password" inputMode="numeric" autoComplete="off" value={code} onChange={(e) => setCode(e.target.value.replace(/\D/g, "").slice(0, 8))} />
          </div>
          <div>
            <label className="label">تأكيد الرمز</label>
            <input className="input" dir="ltr" type="password" inputMode="numeric" autoComplete="off" value={code2} onChange={(e) => setCode2(e.target.value.replace(/\D/g, "").slice(0, 8))} />
          </div>
          <label className="flex items-center gap-2 text-sm text-ink-700">
            <input type="checkbox" className="h-4 w-4 accent-brand-600" checked={tested} onChange={(e) => setTested(e.target.checked)} />
            تم اختبار الرمز على الصندوق ميدانيًا
          </label>
        </div>
        <div className="mt-5 flex justify-end gap-2">
          <button onClick={onClose} className="btn-outline text-sm" disabled={busy}>إلغاء</button>
          <button onClick={submit} className="btn-primary text-sm" disabled={busy || !valid || code !== code2}>{busy ? <Spinner className="h-4 w-4" /> : "حفظ الرمز"}</button>
        </div>
      </Card>
    </div>
  );
}
