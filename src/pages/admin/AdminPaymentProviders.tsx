import { AwaitingCredentials } from "../../components/AwaitingCredentials";
import { Card } from "../../components/ui";
import { CreditCard, Check } from "lucide-react";

export default function AdminPaymentProviders() {
  return (
    <div>
      <AwaitingCredentials
        title="مزودو الدفع"
        description="ربط مزود دفع محلي معتمد — روابط دفع وأجهزة نقاط بيع. حتى يتوفر الربط، تعمل شاشة المدفوعات اليدوية بإدخال رقم المرجع."
        fields={[
          { label: "اسم المزود", placeholder: "moyasar | tap | hyperpay" },
          { label: "Secret Key", placeholder: "sk_live_...", type: "password" },
          { label: "Publishable Key", placeholder: "pk_live_..." },
          { label: "Webhook Secret", placeholder: "whsec_...", type: "password" },
          { label: "POS Terminal ID", placeholder: "T-0000" },
          { label: "POS API Key", placeholder: "pos_key", type: "password" },
        ]}
      />
      <Card className="mt-4">
        <h3 className="mb-3 flex items-center gap-2 text-sm font-semibold text-ink-700"><CreditCard className="h-4 w-4 text-brand-600" /> آليات الدفع المدعومة</h3>
        <div className="space-y-3">
          <div className="rounded-xl border border-ink-100 p-3">
            <p className="text-sm font-medium text-ink-700">الدفع عبر منصة الحجز</p>
            <p className="mt-1 text-xs text-ink-400">تسجيل مصدر الحجز وحالة الدفع — يعمل الآن <Check className="inline h-3 w-3 text-success-600" /></p>
          </div>
          <div className="rounded-xl border border-warning-500/30 p-3">
            <p className="text-sm font-medium text-ink-700">رابط دفع إلكتروني</p>
            <p className="mt-1 text-xs text-warning-600">بانتظار اعتماد المزود — البنية جاهزة</p>
          </div>
          <div className="rounded-xl border border-warning-500/30 p-3">
            <p className="text-sm font-medium text-ink-700">جهاز نقاط البيع (POS)</p>
            <p className="mt-1 text-xs text-warning-600">يدوي حاليًا — إدخال رقم مرجع يدوي معتمد من المشرف</p>
          </div>
        </div>
      </Card>
    </div>
  );
}
