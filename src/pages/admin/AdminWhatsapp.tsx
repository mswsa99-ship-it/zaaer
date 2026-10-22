import { AwaitingCredentials } from "../../components/AwaitingCredentials";
import { Card } from "../../components/ui";
import { MessageCircle, Check } from "lucide-react";

export default function AdminWhatsapp() {
  return (
    <div>
      <AwaitingCredentials
        title="تكامل واتساب للأعمال"
        description="ربط WhatsApp Business Platform الرسمي. حتى يتوفر الربط، يعمل محاكي داخلي يختبر منطق المعالجة دون إرسال رسائل حقيقية."
        fields={[
          { label: "Phone Number ID", placeholder: "000000000000000" },
          { label: "WhatsApp Business Account ID", placeholder: "000000000000" },
          { label: "Access Token", placeholder: "EAAG...", type: "password" },
          { label: "Verify Token", placeholder: "your_verify_token" },
          { label: "App Secret", placeholder: "app_secret", type: "password" },
          { label: "Template Names", placeholder: "welcome, checkin_ready" },
        ]}
      />
      <Card className="mt-4">
        <h3 className="mb-3 flex items-center gap-2 text-sm font-semibold text-ink-700"><MessageCircle className="h-4 w-4 text-brand-600" /> ميزات مُنفّذة</h3>
        <ul className="space-y-2 text-sm text-ink-600">
          {["استقبال رسائل الويب هوك", "التحقق من أصالة الطلبات", "إرسال الرسائل", "دعم الأزرار التفاعلية", "سجل المحادثة", "ربط المحادثة بالحجز بعد التحقق", "منع معالجة الرسائل المكررة", "التحويل لمشرف بشري", "محاكي داخلي"].map((f) => (
            <li key={f} className="flex items-center gap-2"><Check className="h-4 w-4 text-success-600" /> {f}</li>
          ))}
        </ul>
      </Card>
    </div>
  );
}
