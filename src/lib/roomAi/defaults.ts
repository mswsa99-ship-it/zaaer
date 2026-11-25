import type { DraftItem, FieldSpec, ProposalContext, Snapshot, StepId } from "./types";

export const STEP_ORDER: StepId[] = ["policies", "structure", "categories", "facilities", "task_types"];
export const STEP_INFO: Record<StepId, { label: string; path: string; what: string; ask?: FieldSpec[] }> = {
  policies: { label: "السياسات", path: "/admin/policies", what: "ثماني سياسات افتراضية بصياغة فندقية، تعدّلها قبل الإضافة." },
  structure: { label: "البلوكات والطوابق", path: "/admin/structure", what: "بلوك رئيسي وطوابقه حسب ما تحدده.", ask: [{ key: "floors", label: "عدد الطوابق فوق الأرضي", type: "number" }] },
  categories: { label: "أنواع الوحدات", path: "/admin/room-categories", what: "أنواع شائعة بالسعة والوصف. السعر تكتبه أنت." },
  facilities: { label: "المرافق", path: "/admin/facilities", what: "مرافق شائعة (استقبال، مصلى، مصعد…)." },
  task_types: { label: "أنواع المهام", path: "/admin/task-types", what: "مهام التشغيل اليومية (تنظيف، صيانة، تفقد…)." },
};

export const POLICY_TOPICS_FOR_FIELD: Record<string, string> = {
  checkin: "الوصول والمغادرة", cancellation: "الإلغاء", wifi: "الإنترنت", parking: "المواقف", location: "الموقع",
  children: "الأطفال والمرافقون", contact: "التواصل", stay: "شروط الإقامة", privacy: "الخصوصية", other: "أخرى",
};
export const STEP_FIELDS: Record<StepId, FieldSpec[]> = {
  policies: [
    { key: "topic", label: "الموضوع", type: "select", options: POLICY_TOPICS_FOR_FIELD },
    { key: "title", label: "العنوان", type: "text" },
    { key: "content_ar", label: "النص", type: "textarea", wide: true },
    { key: "is_public", label: "عامة: تظهر للنزيل ويذكرها المساعد", type: "check" },
  ],
  structure: [
    { key: "name", label: "اسم البلوك", type: "text" },
    { key: "floors", label: "الطوابق (سطر لكل طابق)", type: "textarea", wide: true },
  ],
  categories: [
    { key: "name_ar", label: "الاسم", type: "text" },
    { key: "name_en", label: "الاسم بالإنجليزية", type: "text", ltr: true },
    { key: "description", label: "الوصف", type: "textarea", wide: true },
    { key: "base_capacity", label: "السعة الأساسية", type: "number" },
    { key: "max_capacity", label: "السعة القصوى", type: "number" },
    { key: "price_sar", label: "السعر الأساسي لليلة (ريال، تكتبه أنت)", type: "money_sar", hint: "لا يُقترح أي سعر" },
  ],
  facilities: [
    { key: "name", label: "الاسم", type: "text" },
    { key: "description", label: "الوصف", type: "textarea", wide: true },
  ],
  task_types: [
    { key: "name", label: "الاسم", type: "text" },
    { key: "description", label: "الوصف", type: "textarea", wide: true },
  ],
};

/** A blank the owner must fill looks like [ ... ]. An item that still has one cannot be confirmed. */
export const PLACEHOLDER = /\[[^\]]*\]/;
export const hasPlaceholder = (v: unknown) => typeof v === "string" && PLACEHOLDER.test(v);

let seq = 0;
const item = (values: DraftItem["values"], note?: string): DraftItem => ({ id: `d${++seq}`, include: true, values, note });

const hhmm = (t?: string | null) => (t ? t.slice(0, 5) : null);

/** Policy defaults. Times come from the branch's own settings when set; otherwise a blank for the owner. */
export function defaultPolicies(s: Snapshot): DraftItem[] {
  const cin = hhmm(s.branch?.check_in_time) ?? "[ساعة الوصول]";
  const cout = hhmm(s.branch?.check_out_time) ?? "[ساعة المغادرة]";
  return [
    item({ topic: "checkin", title: "الوصول والمغادرة", is_public: true, content_ar: `يبدأ الوصول من الساعة ${cin} وتنتهي المغادرة قبل الساعة ${cout}. الوصول المبكر أو المغادرة المتأخرة حسب التوفر وقد يترتب عليهما رسم يُخبَر به النزيل مسبقًا.` }, "الساعتان مأخوذتان من إعدادات الفرع إن وُجدت."),
    item({ topic: "cancellation", title: "الإلغاء والتعديل", is_public: true, content_ar: "يمكن إلغاء الحجز أو تعديله مجانًا قبل [عدد ساعات] ساعة من موعد الوصول. بعد ذلك يُحتسب [ما يُحتسب عند الإلغاء المتأخر]. في حال عدم الحضور يُعامل الحجز وفق شروط الإلغاء المتأخر." }, "المدة والمقابل قرار تجاري تكتبه أنت، لا يُقترح رقم."),
    item({ topic: "stay", title: "شروط الإقامة", is_public: true, content_ar: "يُشترط إبراز هوية سارية لكل نزيل بالغ عند الوصول، وتسجيل بيانات الضيوف وفق الأنظمة المعمول بها. يلتزم النزيل بالهدوء وبعدد الأشخاص المحجوز، والتدخين ممنوع داخل الوحدات. النزيل مسؤول عن أي تلف يحدث في الوحدة أثناء إقامته." }, "راجع الشروط النظامية الخاصة بالتسجيل مع الجهة المختصة؛ هذا نص عام وليس استشارة قانونية."),
    item({ topic: "children", title: "الأطفال والعائلات", is_public: true, content_ar: "نرحب بالعائلات. الأطفال دون [عمر] سنوات لا يُحتسبون في عدد الضيوف. السعة القصوى لكل وحدة كما هي معلنة في نوعها، وأي إضافة تُنسَّق مع الاستقبال." }, "العمر المعتمد تحدده أنت."),
    item({ topic: "privacy", title: "الخصوصية وحماية البيانات", is_public: true, content_ar: "نجمع من النزيل البيانات اللازمة للحجز والتسجيل النظامي فقط، ونحفظها بسرية ولا نشاركها إلا حيث تلزم الأنظمة. يمكن للنزيل طلب تصحيح بياناته عبر الاستقبال." }),
    item({ topic: "wifi", title: "الإنترنت", is_public: true, content_ar: "الإنترنت اللاسلكي متاح للنزلاء في [أماكن التغطية]. اسم الشبكة ورمزها يسلَّمان عند الوصول." }),
    item({ topic: "parking", title: "المواقف", is_public: true, content_ar: "مواقف السيارات [متاحة مجانًا / برسم / غير متاحة] وتخضع للتوفر. الفندق غير مسؤول عن محتويات السيارات." }),
    item({ topic: "contact", title: "التواصل", is_public: true, content_ar: "للتواصل مع الاستقبال: [رقم الهاتف أو واتساب]. ساعات الرد: [ساعات الاستقبال]." }),
  ];
}

export function defaultStructure(ctx: ProposalContext): DraftItem[] {
  const n = Math.max(0, Math.min(40, Math.floor(Number(ctx.answers.floors ?? 3))));
  const names = ["الأرضي", "الأول", "الثاني", "الثالث", "الرابع", "الخامس", "السادس", "السابع", "الثامن", "التاسع", "العاشر"];
  const floors = ["الأرضي", ...Array.from({ length: n }, (_, i) => names[i + 1] ?? `الطابق ${i + 1}`)];
  return [item({ name: "المبنى الرئيسي", floors: floors.join("\n") }, "إن كان للفندق أكثر من مبنى أضف البلوك الآخر من صفحة البلوكات.")];
}

export const defaultCategories = (): DraftItem[] => [
  item({ name_ar: "وحدة مفردة", name_en: "Single Room", description: "وحدة لنزيل واحد بسرير مفرد، مع حمام خاص.", base_capacity: 1, max_capacity: 2, price_sar: null }),
  item({ name_ar: "وحدة مزدوجة", name_en: "Double Room", description: "وحدة بسرير مزدوج أو سريرين منفصلين، مع حمام خاص.", base_capacity: 2, max_capacity: 3, price_sar: null }),
  item({ name_ar: "وحدة عائلية", name_en: "Family Room", description: "وحدة واسعة تتسع لعائلة صغيرة، مع حمام خاص.", base_capacity: 3, max_capacity: 5, price_sar: null }),
  item({ name_ar: "جناح", name_en: "Suite", description: "جناح بحجرة نوم وصالة جلوس منفصلتين.", base_capacity: 2, max_capacity: 4, price_sar: null }),
];

export const defaultFacilities = (): DraftItem[] => [
  item({ name: "الاستقبال", description: "مكتب الاستقبال والوصول والمغادرة." }),
  item({ name: "المصلى", description: "مكان للصلاة للنزلاء." }),
  item({ name: "المصعد", description: "مصاعد النزلاء." }),
  item({ name: "موقف السيارات", description: "مواقف النزلاء." }),
  item({ name: "مخزن البياضات والغسيل", description: "مخزن البياضات والمستلزمات." }),
];

export const defaultTaskTypes = (): DraftItem[] => [
  item({ name: "تنظيف الوحدة وتعقيمها", description: "تنظيف كامل بعد المغادرة وقبل الوصول." }),
  item({ name: "تفقد الوحدة قبل الوصول", description: "فحص سريع للأثاث والتكييف والمرافق قبل تسليم الوحدة." }),
  item({ name: "صيانة", description: "إصلاح عطل في وحدة أو مرفق." }),
  item({ name: "تجهيز المغادرة", description: "جرد المفقودات وفحص التلف بعد خروج النزيل." }),
];
