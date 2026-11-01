/**
 * «شروط الاستخدام» (0056, SETUP-03): built from the settings, never written in the code — the organisation's name, each
 * branch's arrival and departure times, and the branch's public policies (the same ones the assistant may quote).
 * A link with ?branch=<id> shows that branch alone.
 */
import { useEffect, useState } from "react";
import { useSearchParams } from "react-router-dom";
import { supabase } from "../../lib/supabase";
import { guestApi, type PublicBranch } from "../../lib/api";
import { useOrganizationName } from "../../lib/organization";
import { policyTopic } from "../../lib/policies";
import { Spinner } from "../../components/ui";

interface Policy { branch_id: string; topic: string; topic_label: string | null; title: string; content_ar: string; sort_order: number | null }
const time12 = (t: string | null | undefined) => {
  if (!t) return ""; const [h, m] = t.split(":").map(Number); const pm = h >= 12; const hh = h % 12 || 12;
  return `${hh}:${String(m).padStart(2, "0")} ${pm ? (h >= 18 ? "مساءً" : h === 12 ? "ظهرًا" : "عصرًا") : "صباحًا"}`;
};

export default function Terms() {
  const org = useOrganizationName();
  const [params] = useSearchParams();
  const only = params.get("branch");
  const [policies, setPolicies] = useState<Policy[] | null>(null);
  const [branches, setBranches] = useState<Record<string, PublicBranch>>({});

  useEffect(() => {
    let live = true;
    (async () => {
      let q = supabase.from("property_policies").select("branch_id, topic, topic_label, title, content_ar, sort_order").eq("is_public", true).order("sort_order");
      if (only) q = q.eq("branch_id", only);
      const { data } = await q; const rows = ((data as Policy[]) ?? []);
      const ids = [...new Set([...(only ? [only] : []), ...rows.map((p) => p.branch_id)])];
      const out: Record<string, PublicBranch> = {};
      for (const id of ids) { const b = await guestApi.branch(id).catch(() => null); if (b) out[id] = b; }
      if (live) { setPolicies(rows.filter((p) => out[p.branch_id])); setBranches(out); }
    })();
    return () => { live = false; };
  }, [only]);

  const list = Object.values(branches);
  return (
    <div className="mx-auto max-w-2xl px-4 py-8 lg:py-12">
      <h1 className="text-2xl font-bold text-ink-800">شروط الاستخدام</h1>
      <div className="mt-6 max-w-none text-sm leading-relaxed text-ink-600">
        <p>باستخدامك خدمات {org ? `«${org}»` : "المنشأة"} فإنك توافق على الشروط التالية.</p>
        {policies === null ? <Spinner className="mx-auto mt-8 h-6 w-6" /> : list.length === 0 ? (
          <p className="mt-6 rounded-xl bg-ink-50 p-4">لم تُنشر شروط الإقامة بعد. للاستفسار تواصل مع الاستقبال.</p>
        ) : list.map((b) => {
          const own = policies.filter((p) => p.branch_id === b.id);
          return (
            <section key={b.id} className="mt-6" data-testid={`terms-branch-${b.id}`}>
              {list.length > 1 && <h2 className="text-lg font-semibold text-ink-800">{b.name_ar}</h2>}
              <h3 className="mt-4 text-base font-semibold text-ink-800">أوقات الإقامة</h3>
              <ul className="mt-2 list-disc space-y-1 pr-5">
                <li>وقت الوصول: {time12(b.check_in_time)}، وقت المغادرة: {time12(b.check_out_time)}.</li>
                <li>تُسجَّل بيانات جميع النزلاء قبل الدخول، ويُطابق الاستقبال الهوية.</li>
              </ul>
              {own.map((p, i) => (
                <div key={i}>
                  <h3 className="mt-4 text-base font-semibold text-ink-800">{p.title}<span className="mr-2 text-xs font-normal text-ink-400">{policyTopic(p)}</span></h3>
                  <p className="mt-1 whitespace-pre-line">{p.content_ar}</p>
                </div>
              ))}
            </section>
          );
        })}
        <h2 className="mt-8 text-base font-semibold text-ink-800">المسؤولية</h2>
        <p className="mt-2">تسعى المنشأة لتقديم خدمة آمنة وموثوقة، ولا تتحمل مسؤولية تعطل الخدمات الخارجية (منصات الحجز، مزودي الدفع) الخارجة عن سيطرتها.</p>
      </div>
    </div>
  );
}
