import { Card, Badge } from "./ui";
import { AlertCircle } from "lucide-react";
import type { ReactNode } from "react";

export function AwaitingCredentials({ title, description, fields, children }: {
  title: string;
  description: string;
  fields: { label: string; placeholder: string; type?: string }[];
  children?: ReactNode;
}) {
  return (
    <div>
      <div className="mb-6">
        <h1 className="text-xl font-bold text-ink-800">{title}</h1>
        <p className="mt-1 text-sm text-ink-500">{description}</p>
      </div>
      <Card className="mb-4 border-warning-500/30">
        <div className="flex items-start gap-3">
          <AlertCircle className="mt-0.5 h-5 w-5 shrink-0 text-warning-700" />
          <div>
            <Badge className="bg-warning-500/10 text-warning-700">بانتظار الاعتماد الخارجي</Badge>
            <p className="mt-2 text-sm text-ink-600">هذا التكامل يحتاج بيانات اعتماد خارجية لم يُدخلها المالك بعد. البنية الخلفية والنموذج جاهزان، وستعمل تلقائيًا عند توفير البيانات.</p>
          </div>
        </div>
      </Card>
      <Card>
        <h3 className="mb-4 text-sm font-semibold text-ink-700">حقول الإعداد</h3>
        <div className="grid gap-4 sm:grid-cols-2">
          {fields.map((f) => (
            <div key={f.label}>
              <label className="label">{f.label}</label>
              <input type={f.type ?? "text"} placeholder={f.placeholder} className="input" dir="ltr" disabled />
              <p className="mt-1 text-xs text-ink-400">يُحفظ بشكل آمن — لا يُعرض في الواجهة</p>
            </div>
          ))}
        </div>
        <button className="btn-primary mt-4" disabled>حفظ (معطّل — يلزم بيانات اعتماد فعلية)</button>
      </Card>
      {children}
    </div>
  );
}
