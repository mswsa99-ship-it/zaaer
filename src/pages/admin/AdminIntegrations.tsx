import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { supabase } from "../../lib/supabase";
import { aiHealth } from "../../lib/api";
import { SectionTitle, Card, Badge, Spinner } from "../../components/ui";
import { Plug, Check, Clock, AlertCircle, XCircle } from "lucide-react";

type Status = "connected" | "awaiting" | "future" | "disabled" | "error" | "checking";

interface Integration { name: string; status: Status; description: string; link?: string }

const STATIC: Integration[] = [
  { name: "WhatsApp Business Platform", status: "awaiting", description: "بانتظار بيانات اعتماد Meta", link: "/admin/whatsapp" },
  { name: "مزود الدفع الإلكتروني", status: "awaiting", description: "بانتظار اعتماد مزود محلي", link: "/admin/payment-providers" },
  { name: "جهاز نقاط البيع (POS)", status: "awaiting", description: "يدوي حاليًا" },
  { name: "الفوترة الإلكترونية", status: "future", description: "تكامل مستقبلي مشروط بالمتطلبات" },
  { name: "التكامل الحكومي (شموس/الرصد)", status: "future", description: "مشروط بالتصاريح وواجهات الربط الرسمية" },
];

export default function AdminIntegrations() {
  const [ai, setAi] = useState<Integration>({ name: "مزود الذكاء الاصطناعي (Gemini)", status: "checking", description: "جارٍ الفحص…", link: "/admin/ai-settings" });
  const [db, setDb] = useState<Integration>({ name: "Supabase (قاعدة البيانات)", status: "checking", description: "قاعدة البيانات والمصادقة وRealtime" });

  useEffect(() => {
    (async () => {
      const [settings, health] = await Promise.all([
        supabase.from("ai_settings").select("enabled, provider, model").maybeSingle(),
        aiHealth(),
      ]);
      setDb({ name: "Supabase (قاعدة البيانات)", status: settings.error && /fetch|network/i.test(settings.error.message) ? "error" : "connected", description: "قاعدة البيانات والمصادقة وRealtime" });
      const s = settings.data as { enabled: boolean; provider: string; model: string } | null;
      const base = { name: "مزود الذكاء الاصطناعي (Gemini)", link: "/admin/ai-settings" };
      if (!s || !s.enabled || s.provider === "none") setAi({ ...base, status: "disabled", description: "معطّل من الإعدادات — يعمل المسار الحواري التقليدي" });
      else if (!health.configured) setAi({ ...base, status: "awaiting", description: "مفعّل لكن مفتاح GEMINI_API_KEY غير مضبوط على الخادم" });
      else if (!health.ok) setAi({ ...base, status: "error", description: `فشل الاتصال: ${health.error ?? "غير معروف"}` });
      else setAi({ ...base, status: "connected", description: `متصل — ${health.model ?? s.model}${typeof health.latency_ms === "number" ? ` · ${health.latency_ms} ms` : ""}` });
    })();
  }, []);

  const integrations = [db, ai, ...STATIC];

  return (
    <div>
      <SectionTitle title="التكاملات" subtitle="حالة الربط مع الخدمات الخارجية" />
      <div className="space-y-3">
        {integrations.map((i) => (
          <Card key={i.name} className="flex items-center justify-between">
            <div className="flex items-center gap-3">
              <Plug className="h-5 w-5 text-ink-400" />
              <div>
                <p className="text-sm font-semibold text-ink-800">{i.link ? <Link to={i.link} className="hover:text-brand-600 hover:underline">{i.name}</Link> : i.name}</p>
                <p className="text-xs text-ink-400">{i.description}</p>
              </div>
            </div>
            {i.status === "checking" && <Spinner className="h-4 w-4" />}
            {i.status === "connected" && <Badge className="bg-success-500/10 text-success-600"><Check className="h-3 w-3" /> متصل</Badge>}
            {i.status === "awaiting" && <Badge className="bg-warning-500/10 text-warning-600"><Clock className="h-3 w-3" /> بانتظار الاعتماد</Badge>}
            {i.status === "disabled" && <Badge className="bg-ink-100 text-ink-500"><AlertCircle className="h-3 w-3" /> معطّل</Badge>}
            {i.status === "error" && <Badge className="bg-danger-500/10 text-danger-600"><XCircle className="h-3 w-3" /> خطأ</Badge>}
            {i.status === "future" && <Badge className="bg-ink-100 text-ink-400"><AlertCircle className="h-3 w-3" /> مستقبلي</Badge>}
          </Card>
        ))}
      </div>
    </div>
  );
}
