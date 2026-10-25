import { SectionTitle, Card } from "../../components/ui";
import { ShieldCheck, Check, X } from "lucide-react";
import { ROLE_LABELS } from "../../lib/types";

const permissions = [
  { name: "إدارة الفروع والمنشأة", owner: true, manager: true, supervisor: false, finance: false, housekeeping: false },
  { name: "إدارة الغرف والتصنيفات", owner: true, manager: true, supervisor: false, finance: false, housekeeping: false },
  { name: "التحكم بالتوفر وقواعد الكشف", owner: true, manager: true, supervisor: false, finance: false, housekeeping: false },
  { name: "إدارة الحجوزات", owner: true, manager: true, supervisor: true, finance: false, housekeeping: false },
  { name: "مطابقة الهويات", owner: true, manager: true, supervisor: true, finance: false, housekeeping: false },
  { name: "مراجعة المدفوعات", owner: true, manager: true, supervisor: true, finance: true, housekeeping: false },
  { name: "تسجيل شموس، وتسجيل الوصول والمغادرة، وتسليم الرمز", owner: true, manager: true, supervisor: true, finance: false, housekeeping: false },
  { name: "فحص المغادرة", owner: true, manager: true, supervisor: true, finance: false, housekeeping: true },
  { name: "رد التأمين بعد المغادرة وفحصها", owner: true, manager: true, supervisor: true, finance: true, housekeeping: false },
  { name: "رسم الضرر، وسبب استمرار إقامة عليها ليلة غير مدفوعة", owner: true, manager: true, supervisor: true, finance: false, housekeeping: false },
  { name: "التصحيحات: التراجع عن الوصول (30 دقيقة) وإعادة فتح المغادرة (ساعتان) والتراجع عن الإلغاء (ساعة)", owner: true, manager: true, supervisor: false, finance: false, housekeeping: false },
  { name: "«الرموز»: عرض رمز الصندوق وتغييره بعد المغادرة (خدمة الغرف: لا وحدة فيها نزيل مقيم)", owner: true, manager: true, supervisor: true, finance: false, housekeeping: true },
  { name: "عرض السجلات المالية", owner: true, manager: true, supervisor: false, finance: true, housekeeping: false },
  { name: "مهام النظافة", owner: true, manager: true, supervisor: true, finance: false, housekeeping: true },
  { name: "إدارة الموظفين والصلاحيات", owner: true, manager: false, supervisor: false, finance: false, housekeeping: false },
  { name: "الإعدادات والتكاملات", owner: true, manager: false, supervisor: false, finance: false, housekeeping: false },
  { name: "سجل الإجراءات", owner: true, manager: true, supervisor: false, finance: false, housekeeping: false },
];

export default function AdminRoles() {
  const roles = ["owner", "manager", "supervisor", "finance", "housekeeping"] as const;
  return (
    <div>
      <SectionTitle title="الصلاحيات" subtitle="مصفوفة الأدوار والصلاحيات (RBAC)" />
      <Card className="overflow-x-auto">
        <table className="w-full text-sm">
          <thead><tr className="border-b border-ink-100 text-xs text-ink-400">
            <th className="py-2 text-right font-medium">الصلاحية</th>
            {roles.map((r) => <th key={r} className="py-2 text-center font-medium">{ROLE_LABELS[r]}</th>)}
          </tr></thead>
          <tbody>
            {permissions.map((p) => (
              <tr key={p.name} className="border-b border-ink-50">
                <td className="py-2.5 text-ink-700">{p.name}</td>
                {roles.map((r) => (
                  <td key={r} className="py-2.5 text-center">
                    {p[r] ? <Check className="mx-auto h-4 w-4 text-success-600" /> : <X className="mx-auto h-4 w-4 text-ink-200" />}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </Card>
      <div className="mt-4 flex items-start gap-2 rounded-xl bg-ink-50 p-4 text-xs text-ink-500">
        <ShieldCheck className="h-4 w-4 shrink-0 text-brand-600" />
        <p>الصلاحيات مطبّقة على مستوى قاعدة البيانات عبر Row Level Security، وليس بإخفاء الأزرار فقط. يعزل النظام بيانات كل فرع عن غيره.</p>
      </div>
    </div>
  );
}
