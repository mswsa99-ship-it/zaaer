import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { Sunrise, RefreshCw, Sparkles } from "lucide-react";
import { useBranch } from "../lib/branch";
import { aiOpsBriefing, toArabicError, type Briefing } from "../lib/api";
import { Card, Spinner, ErrorBanner } from "./ui";
import { formatDateTime } from "../lib/utils";

/** Morning briefing: deterministic prioritized items from the ops context + optional AI recommendations. */
export function DailyBriefing() {
  const { branchId } = useBranch();
  const [b, setB] = useState<Briefing | null>(null); const [loading, setLoading] = useState(true); const [error, setError] = useState<string | null>(null);
  const load = useCallback(async () => { if (!branchId) return; setLoading(true); try { setB(await aiOpsBriefing(branchId)); setError(null); } catch (e) { setError(toArabicError(e)); } finally { setLoading(false); } }, [branchId]);
  useEffect(() => { load(); }, [load]);
  const dot = { critical: "bg-danger-500", warning: "bg-warning-500", info: "bg-brand-400" } as const;
  return (
    <Card>
      <div className="mb-3 flex items-center justify-between">
        <h2 className="flex items-center gap-2 text-base font-semibold text-ink-800"><Sunrise className="h-5 w-5 text-warning-500" /> إحاطة اليوم</h2>
        <button onClick={load} className="btn-ghost p-1.5" aria-label="تحديث"><RefreshCw className={`h-4 w-4 ${loading ? "animate-spin" : ""}`} /></button>
      </div>
      {error && <ErrorBanner message={error} />}
      {!b && loading && <div className="py-6 text-center"><Spinner /></div>}
      {b && (
        <>
          <p className="text-sm font-medium text-ink-700">{b.headline}</p>
          <ul className="mt-3 space-y-2">
            {b.items.map((i, k) => (
              <li key={k} className="flex items-start gap-2 text-sm text-ink-700">
                <span className={`mt-1.5 h-2 w-2 shrink-0 rounded-full ${dot[i.level]}`} />
                <span className="flex-1">{i.text}{i.link && <Link to={i.link} className="mr-2 text-xs text-brand-600 hover:underline">فتح</Link>}</span>
              </li>
            ))}
          </ul>
          {b.insights && <div className="mt-4 rounded-xl bg-brand-50 p-3 text-sm text-brand-900"><p className="mb-1 flex items-center gap-1 text-xs font-semibold text-brand-700"><Sparkles className="h-3.5 w-3.5" /> توصيات المساعد (للمراجعة البشرية)</p><p className="whitespace-pre-wrap">{b.insights}</p></div>}
          <p className="mt-3 text-[11px] text-ink-400">{b.date} · {b.generated_at ? formatDateTime(b.generated_at) : ""} · {b.mode === "ai" ? "إحاطة مع توصيات ذكية" : "إحاطة مبنية على بيانات النظام مباشرة"}</p>
        </>
      )}
    </Card>
  );
}
