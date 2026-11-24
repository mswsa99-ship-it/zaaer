import { defaultCategories, defaultFacilities, defaultPolicies, defaultStructure, defaultTaskTypes, hasPlaceholder, STEP_FIELDS } from "./defaults";
import type { DraftItem, Finding, ProposalContext, RoomAiProvider, Snapshot, StepId } from "./types";

const norm = (s: unknown) => String(s ?? "").trim().replace(/\s+/g, " ").toLowerCase();
const live = <T extends { archived_at: string | null }>(l: T[]) => l.filter((x) => !x.archived_at);

/** True when the snapshot already has this item (same name or topic), so Room AI never proposes a duplicate. */
export function alreadyExists(step: StepId, v: DraftItem["values"], s: Snapshot): boolean {
  switch (step) {
    case "policies": return live(s.policies).some((p) => p.topic === v.topic && v.topic !== "other");
    case "structure": return live(s.blocks).some((b) => norm(b.name) === norm(v.name)) && missingFloors(v, s).length === 0;
    case "categories": return live(s.categories).some((c) => norm(c.name_ar) === norm(v.name_ar));
    case "facilities": return live(s.facilities).some((f) => norm(f.name) === norm(v.name));
    case "task_types": return live(s.taskTypes).some((t) => norm(t.name) === norm(v.name));
  }
}
export const floorLines = (v: DraftItem["values"]) => String(v.floors ?? "").split("\n").map((x) => x.trim()).filter(Boolean);
export function missingFloors(v: DraftItem["values"], s: Snapshot): string[] {
  const b = live(s.blocks).find((x) => norm(x.name) === norm(v.name));
  if (!b) return floorLines(v);
  const have = new Set(live(s.floors).filter((f) => f.block_id === b.id).map((f) => norm(f.name)));
  return floorLines(v).filter((n) => !have.has(norm(n)));
}

/** What stops an item from being confirmed. Empty list = ready. */
export function problems(step: StepId, v: DraftItem["values"]): string[] {
  const out: string[] = [];
  for (const f of STEP_FIELDS[step]) if (f.type === "text" || f.type === "textarea") if (hasPlaceholder(v[f.key])) out.push("أكمل الفراغ بين الأقواس [ ]");
  const req = (k: string, msg: string) => { if (!String(v[k] ?? "").trim()) out.push(msg); };
  if (step === "policies") { req("title", "العنوان مطلوب"); req("content_ar", "النص مطلوب"); }
  if (step === "structure") { req("name", "اسم البلوك مطلوب"); if (floorLines(v).length === 0) out.push("أضف طابقًا واحدًا على الأقل"); }
  if (step === "categories") {
    req("name_ar", "الاسم مطلوب");
    const b = Number(v.base_capacity), m = Number(v.max_capacity);
    if (!(b >= 1)) out.push("السعة الأساسية 1 على الأقل");
    if (!(m >= b)) out.push("السعة القصوى لا تقل عن الأساسية");
    if (!(Number(v.price_sar) > 0)) out.push("اكتب السعر الأساسي لليلة");
  }
  if (step === "facilities" || step === "task_types") req("name", "الاسم مطلوب");
  return out;
}
const dedupe = (v: string[]) => Array.from(new Set(v)).slice(0, 2);
export const uniqueProblems = (step: StepId, v: DraftItem["values"]) => dedupe(problems(step, v));

function severityOrder(s: Finding["severity"]) { return s === "risk" ? 0 : s === "warn" ? 1 : 2; }

export function reviewSnapshot(s: Snapshot): Finding[] {
  const out: Finding[] = [];
  const add = (f: Finding) => out.push(f);
  const pol = live(s.policies), cats = live(s.categories), rooms = live(s.rooms), blocks = live(s.blocks), floors = live(s.floors);
  const has = (t: string) => pol.some((p) => p.topic === t);
  if (pol.length === 0) add({ id: "no-policies", severity: "risk", step: "policies", title: "لا توجد سياسات", detail: "المساعد الذكي لا يملك مصدرًا يجيب منه، وكل سؤال سيُحوَّل إلى مشرف.", to: "/admin/policies" });
  else {
    if (!has("cancellation")) add({ id: "no-cancel", severity: "risk", step: "policies", title: "لا توجد سياسة إلغاء", detail: "بدونها لا يعرف النزيل ولا الموظف ما يترتب على الإلغاء أو عدم الحضور، فتنشأ نزاعات.", to: "/admin/policies" });
    if (!has("checkin")) add({ id: "no-checkin", severity: "warn", step: "policies", title: "لا توجد سياسة وصول ومغادرة", detail: "أضف ساعات الوصول والمغادرة ومتى يترتب رسم على التأخير.", to: "/admin/policies" });
    if (!has("stay")) add({ id: "no-stay", severity: "warn", step: "policies", title: "لا توجد شروط إقامة", detail: "الهوية والتسجيل النظامي والتلف تحتاج نصًا يوافق عليه النزيل. راجع صياغتها مع الجهة المختصة.", to: "/admin/policies" });
    if (!has("children")) add({ id: "no-children", severity: "note", step: "policies", title: "لا توجد سياسة للأطفال والعائلات", detail: "العائلات أكثر الأسئلة تكرارًا: العمر المحتسب والسعة والإضافة.", to: "/admin/policies" });
    const ph = pol.filter((p) => hasPlaceholder(p.content_ar) || hasPlaceholder(p.title));
    if (ph.length) add({ id: "placeholders", severity: "risk", step: "policies", title: `${ph.length} سياسة فيها فراغات لم تُكمل`, detail: `قد يقرأ النزيل نصًا مثل «[عدد ساعات]». السياسات: ${ph.slice(0, 3).map((p) => p.title).join("، ")}.`, to: "/admin/policies" });
    const priv = pol.filter((p) => !p.is_public);
    if (priv.length === pol.length) add({ id: "none-public", severity: "warn", step: "policies", title: "كل السياسات داخلية", detail: "لن يراها النزيل ولن يذكرها المساعد.", to: "/admin/policies" });
  }
  if (blocks.length === 0) add({ id: "no-blocks", severity: "warn", step: "structure", title: "لا توجد بلوكات", detail: "الطوابق والوحدات تُنظَّم تحت بلوك. أضف بلوكًا واحدًا على الأقل.", to: "/admin/structure" });
  else for (const b of blocks) if (!floors.some((f) => f.block_id === b.id)) add({ id: `nofloor-${b.id}`, severity: "note", step: "structure", title: `البلوك «${b.name}» بلا طوابق`, detail: "أضف طوابقه ليُسنَد إليها الوحدات والمرافق.", to: "/admin/structure" });
  if (cats.length === 0) add({ id: "no-cats", severity: "risk", step: "categories", title: "لا توجد أنواع وحدات", detail: "لا يمكن إنشاء وحدات ولا أسعار ولا حجوزات بدون نوع.", to: "/admin/room-categories" });
  for (const c of cats) {
    if (!(Number(c.base_price_halalas) > 0)) add({ id: `price-${c.id}`, severity: "risk", step: "categories", title: `النوع «${c.name_ar}» بلا سعر أساسي`, detail: "الحجز عليه سيُسعَّر بصفر أو يفشل.", to: "/admin/room-categories" });
    if (c.max_capacity < c.base_capacity) add({ id: `cap-${c.id}`, severity: "risk", step: "categories", title: `سعة «${c.name_ar}» غير منطقية`, detail: "السعة القصوى أقل من الأساسية.", to: "/admin/room-categories" });
    if (!rooms.some((r) => r.category_id === c.id)) add({ id: `empty-${c.id}`, severity: "note", step: "categories", title: `النوع «${c.name_ar}» بلا وحدات`, detail: "لن يظهر له توفر حتى تنشئ وحدة منه.", to: "/admin/rooms" });
  }
  if (cats.length > 0 && rooms.length === 0) add({ id: "no-rooms", severity: "risk", step: "general", title: "لا توجد وحدات", detail: "الأنواع معرّفة لكن لا وحدة فعلية للحجز. تُضاف الوحدات من صفحة «الوحدات» (خارج المرحلة 1).", to: "/admin/rooms" });
  const nofloor = rooms.filter((r) => !r.floor_id).length;
  if (nofloor) add({ id: "rooms-no-floor", severity: "note", step: "structure", title: `${nofloor} وحدة بلا طابق`, detail: "تحديد الطابق يسهّل توزيع التنظيف والبحث.", to: "/admin/rooms" });
  const tt = live(s.taskTypes), fac = live(s.facilities);
  if (tt.length === 0) add({ id: "no-tt", severity: "warn", step: "task_types", title: "لا توجد أنواع مهام", detail: "خدمة الغرف تحتاج نوعًا للتنظيف والصيانة.", to: "/admin/task-types" });
  else if (!tt.some((t) => /تنظيف/.test(t.name) || t.code === "room_cleaning")) add({ id: "no-clean", severity: "warn", step: "task_types", title: "لا يوجد نوع مهمة تنظيف", detail: "مهام التنظيف بعد المغادرة تحتاجه.", to: "/admin/task-types" });
  if (fac.length === 0) add({ id: "no-fac", severity: "note", step: "facilities", title: "لا توجد مرافق", detail: "الاستقبال والمصلى والمصعد تُسأل عنها كثيرًا.", to: "/admin/facilities" });
  else if (!fac.some((f) => /مصلى|صلاة/.test(f.name))) add({ id: "no-prayer", severity: "note", step: "facilities", title: "لا يوجد مصلى بين المرافق", detail: "إن كان في الفندق مكان للصلاة فسجّله ليعرفه النزيل. وإن لم يكن فتجاهل التنبيه.", to: "/admin/facilities" });
  return out.sort((a, b) => severityOrder(a.severity) - severityOrder(b.severity));
}

/** The only provider shipped in phase 1: fixed templates, no network, no model call. */
export const deterministicProvider: RoomAiProvider = {
  id: "deterministic-templates-v1",
  async propose(step, ctx: ProposalContext) {
    const raw = step === "policies" ? defaultPolicies(ctx.snapshot) : step === "structure" ? defaultStructure(ctx) : step === "categories" ? defaultCategories() : step === "facilities" ? defaultFacilities() : defaultTaskTypes();
    return raw.filter((d) => !alreadyExists(step, d.values, ctx.snapshot));
  },
  async review(s) { return reviewSnapshot(s); },
};

let current: RoomAiProvider = deterministicProvider;
/** The seam: a different provider (e.g. an LLM-backed one) can be installed here. Not used or tested in phase 1. */
export function setRoomAiProvider(p: RoomAiProvider) { current = p; }
export function getRoomAiProvider(): RoomAiProvider { return current; }
