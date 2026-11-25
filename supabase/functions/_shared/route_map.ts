// GENERATED from src/lib/nav.ts (PAGES, non-hidden) by tests/unit/route_map.test.ts; do not edit by hand.
// Role-level defaults only. An individual permission setting can narrow or widen a person's pages; the server decides.
export interface RouteEntry { path: string; label: string; area: "staff" | "admin"; roles: string[] }
export const ROUTE_MAP: RouteEntry[] = [
  {
    "path": "/staff/rooms",
    "label": "لوحة الوحدات",
    "area": "staff",
    "roles": [
      "owner",
      "manager",
      "supervisor",
      "finance",
      "housekeeping"
    ]
  },
  {
    "path": "/staff/dashboard",
    "label": "لوحة العمليات",
    "area": "staff",
    "roles": [
      "owner",
      "manager",
      "supervisor",
      "finance",
      "housekeeping"
    ]
  },
  {
    "path": "/staff/arrivals",
    "label": "وصول اليوم",
    "area": "staff",
    "roles": [
      "owner",
      "manager",
      "supervisor",
      "finance",
      "housekeeping"
    ]
  },
  {
    "path": "/staff/reservations",
    "label": "الحجوزات",
    "area": "staff",
    "roles": [
      "owner",
      "manager",
      "supervisor",
      "finance",
      "housekeeping"
    ]
  },
  {
    "path": "/staff/identity-verification",
    "label": "مطابقة الهويات",
    "area": "staff",
    "roles": [
      "owner",
      "manager",
      "supervisor"
    ]
  },
  {
    "path": "/staff/payments",
    "label": "المدفوعات",
    "area": "staff",
    "roles": [
      "owner",
      "manager",
      "supervisor",
      "finance"
    ]
  },
  {
    "path": "/staff/orders",
    "label": "طلبات المنتجات",
    "area": "staff",
    "roles": [
      "owner",
      "manager",
      "supervisor",
      "finance"
    ]
  },
  {
    "path": "/staff/journey",
    "label": "رحلة الضيف",
    "area": "staff",
    "roles": [
      "owner",
      "manager",
      "supervisor"
    ]
  },
  {
    "path": "/staff/day-close",
    "label": "إقفال اليوم",
    "area": "staff",
    "roles": [
      "owner",
      "manager",
      "supervisor",
      "finance"
    ]
  },
  {
    "path": "/staff/expenses",
    "label": "المصروفات",
    "area": "staff",
    "roles": [
      "owner",
      "manager",
      "supervisor",
      "finance"
    ]
  },
  {
    "path": "/staff/ledger",
    "label": "دفتر الحركة",
    "area": "staff",
    "roles": [
      "owner",
      "manager",
      "supervisor",
      "finance"
    ]
  },
  {
    "path": "/staff/accounts",
    "label": "الحسابات",
    "area": "staff",
    "roles": [
      "owner",
      "manager",
      "finance"
    ]
  },
  {
    "path": "/staff/bank",
    "label": "الحركات البنكية",
    "area": "staff",
    "roles": [
      "owner",
      "manager",
      "finance"
    ]
  },
  {
    "path": "/staff/pos-settlement",
    "label": "تسوية الشبكة",
    "area": "staff",
    "roles": [
      "owner",
      "manager",
      "supervisor",
      "finance"
    ]
  },
  {
    "path": "/staff/access-approvals",
    "label": "الوصول وتسليم الرمز",
    "area": "staff",
    "roles": [
      "owner",
      "manager",
      "supervisor"
    ]
  },
  {
    "path": "/staff/followups",
    "label": "متابعة الإقامات",
    "area": "staff",
    "roles": [
      "owner",
      "manager",
      "supervisor",
      "finance"
    ]
  },
  {
    "path": "/staff/platforms",
    "label": "مطابقة المنصات",
    "area": "staff",
    "roles": [
      "owner",
      "manager",
      "supervisor"
    ]
  },
  {
    "path": "/staff/day-summary",
    "label": "ملخص اليوم",
    "area": "staff",
    "roles": [
      "owner",
      "manager",
      "supervisor",
      "finance"
    ]
  },
  {
    "path": "/staff/housekeeping",
    "label": "خدمة الغرف",
    "area": "staff",
    "roles": [
      "owner",
      "manager",
      "supervisor",
      "finance",
      "housekeeping"
    ]
  },
  {
    "path": "/staff/codes",
    "label": "الرموز",
    "area": "staff",
    "roles": [
      "owner",
      "manager",
      "supervisor",
      "housekeeping"
    ]
  },
  {
    "path": "/staff/tickets",
    "label": "البلاغات",
    "area": "staff",
    "roles": [
      "owner",
      "manager",
      "supervisor",
      "finance",
      "housekeeping"
    ]
  },
  {
    "path": "/staff/inbox",
    "label": "الوارد",
    "area": "staff",
    "roles": [
      "owner",
      "manager",
      "supervisor",
      "finance",
      "housekeeping"
    ]
  },
  {
    "path": "/admin/dashboard",
    "label": "لوحة الإدارة",
    "area": "admin",
    "roles": [
      "owner",
      "manager"
    ]
  },
  {
    "path": "/admin/organization",
    "label": "المنشأة",
    "area": "admin",
    "roles": [
      "owner"
    ]
  },
  {
    "path": "/admin/branches",
    "label": "الفروع",
    "area": "admin",
    "roles": [
      "owner",
      "manager"
    ]
  },
  {
    "path": "/admin/structure",
    "label": "البلوكات والطوابق",
    "area": "admin",
    "roles": [
      "owner",
      "manager"
    ]
  },
  {
    "path": "/admin/room-categories",
    "label": "أنواع الوحدات",
    "area": "admin",
    "roles": [
      "owner",
      "manager"
    ]
  },
  {
    "path": "/admin/rooms",
    "label": "الوحدات",
    "area": "admin",
    "roles": [
      "owner",
      "manager"
    ]
  },
  {
    "path": "/admin/facilities",
    "label": "المرافق",
    "area": "admin",
    "roles": [
      "owner",
      "manager"
    ]
  },
  {
    "path": "/admin/task-types",
    "label": "أنواع المهام",
    "area": "admin",
    "roles": [
      "owner",
      "manager"
    ]
  },
  {
    "path": "/admin/services",
    "label": "الخدمات",
    "area": "admin",
    "roles": [
      "owner",
      "manager"
    ]
  },
  {
    "path": "/admin/products",
    "label": "المنتجات",
    "area": "admin",
    "roles": [
      "owner",
      "manager"
    ]
  },
  {
    "path": "/admin/rates",
    "label": "تقويم الأسعار",
    "area": "admin",
    "roles": [
      "owner",
      "manager"
    ]
  },
  {
    "path": "/admin/reservations",
    "label": "الحجوزات",
    "area": "admin",
    "roles": [
      "owner",
      "manager",
      "supervisor",
      "finance"
    ]
  },
  {
    "path": "/admin/guests",
    "label": "النزلاء",
    "area": "admin",
    "roles": [
      "owner",
      "manager",
      "supervisor"
    ]
  },
  {
    "path": "/admin/finance",
    "label": "المالية",
    "area": "admin",
    "roles": [
      "owner",
      "manager",
      "finance"
    ]
  },
  {
    "path": "/admin/platform-payouts",
    "label": "إيداعات المنصات",
    "area": "admin",
    "roles": [
      "owner",
      "manager",
      "finance"
    ]
  },
  {
    "path": "/admin/cash-accounts",
    "label": "الصناديق والحسابات",
    "area": "admin",
    "roles": [
      "owner",
      "manager"
    ]
  },
  {
    "path": "/admin/bank-mail",
    "label": "بريد البنك",
    "area": "admin",
    "roles": [
      "owner"
    ]
  },
  {
    "path": "/admin/staff",
    "label": "الموظفون",
    "area": "admin",
    "roles": [
      "owner",
      "manager"
    ]
  },
  {
    "path": "/admin/roles",
    "label": "مصفوفة الصلاحيات",
    "area": "admin",
    "roles": [
      "owner"
    ]
  },
  {
    "path": "/admin/booking-sources",
    "label": "منصات الحجز",
    "area": "admin",
    "roles": [
      "owner",
      "manager"
    ]
  },
  {
    "path": "/admin/journey",
    "label": "رحلة الضيف",
    "area": "admin",
    "roles": [
      "owner",
      "manager"
    ]
  },
  {
    "path": "/admin/finance-controls",
    "label": "الضبط المالي",
    "area": "admin",
    "roles": [
      "owner"
    ]
  },
  {
    "path": "/admin/ai-settings",
    "label": "إعدادات الذكاء الاصطناعي",
    "area": "admin",
    "roles": [
      "owner",
      "manager"
    ]
  },
  {
    "path": "/admin/whatsapp",
    "label": "واتساب الفروع",
    "area": "admin",
    "roles": [
      "owner"
    ]
  },
  {
    "path": "/admin/assistant",
    "label": "تجربة المساعد",
    "area": "admin",
    "roles": [
      "owner",
      "manager",
      "supervisor"
    ]
  },
  {
    "path": "/admin/payment-providers",
    "label": "مزودو الدفع",
    "area": "admin",
    "roles": [
      "owner",
      "manager"
    ]
  },
  {
    "path": "/admin/integrations",
    "label": "التكاملات",
    "area": "admin",
    "roles": [
      "owner",
      "manager"
    ]
  },
  {
    "path": "/admin/knowledge",
    "label": "قاعدة المعرفة",
    "area": "admin",
    "roles": [
      "owner",
      "manager",
      "supervisor"
    ]
  },
  {
    "path": "/admin/policies",
    "label": "السياسات",
    "area": "admin",
    "roles": [
      "owner",
      "manager",
      "supervisor"
    ]
  },
  {
    "path": "/admin/reports",
    "label": "التقارير",
    "area": "admin",
    "roles": [
      "owner",
      "manager",
      "finance"
    ]
  },
  {
    "path": "/admin/audit-logs",
    "label": "سجل الإجراءات",
    "area": "admin",
    "roles": [
      "owner",
      "manager",
      "supervisor"
    ]
  },
  {
    "path": "/admin/usage",
    "label": "استعمال القدرات",
    "area": "admin",
    "roles": [
      "owner"
    ]
  },
  {
    "path": "/admin/review",
    "label": "بحاجة لمراجعة وتدقيق",
    "area": "admin",
    "roles": [
      "owner"
    ]
  },
  {
    "path": "/admin/backups",
    "label": "النسخ الاحتياطي",
    "area": "admin",
    "roles": [
      "owner"
    ]
  },
  {
    "path": "/admin/data-purge",
    "label": "تفريغ البيانات",
    "area": "admin",
    "roles": [
      "owner"
    ]
  }
];

/** The pages a role may open by default, one line each, for the assistant's context (guidance only, never an authority). */
export function routeMapText(role: string): string {
  const mine = ROUTE_MAP.filter((r) => r.roles.includes(role));
  if (mine.length === 0) return "";
  return mine.map((r) => `- ${r.label}: ${r.path}`).join("\n");
}
