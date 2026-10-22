/**
 * Knowledge-base matching: the reception assistant answers from staff-authored entries only when
 * the guest's wording clearly points at one; otherwise the question is logged, never guessed.
 */
import { describe, it, expect } from "vitest";
import { matchKnowledge, scriptedReply, kbTokens, normalizeArabic, type KnowledgeEntry, type PropertyKnowledge } from "../../supabase/functions/_shared/guardrails";

const entries: KnowledgeEntry[] = [
  { id: "pool", question: "هل يوجد مسبح؟", keywords: ["مسبح", "سباحه", "pool"], answer: "نعم، يوجد مسبح خارجي مشترك." , priority: 5 },
  { id: "breakfast", question: "هل تقدمون الإفطار؟", keywords: ["افطار", "فطور", "breakfast"], answer: "لا يُقدَّم إفطار داخل المنشأة." },
  { id: "laundry", question: "هل توجد خدمة غسيل ملابس؟", keywords: ["غسيل", "مغسله", "laundry"], answer: "تتوفر غسالة في وحدات الغرفتين." },
  { id: "pets", question: "هل يُسمح بالحيوانات الأليفة؟", keywords: ["حيوان", "حيوانات", "قطه", "كلب", "pet"], answer: "لا يُسمح بالحيوانات الأليفة." },
  { id: "bed", question: "هل يمكن إضافة سرير إضافي؟", keywords: ["سرير اضافي", "مهد", "extra bed"], answer: "يتوفر سرير إضافي بطلب مسبق." },
  { id: "pay", question: "ما طرق الدفع المتاحة؟", keywords: ["دفع", "مدى", "بطاقه", "apple pay"], answer: "مدى وبطاقات الائتمان والتحويل والنقد." },
];

describe("matchKnowledge", () => {
  it("matches a keyword regardless of hamza/taa-marbuta/diacritics and the definite article", () => {
    expect(matchKnowledge("هَل يوجد مَسبح؟", entries)?.entry.id).toBe("pool");
    expect(matchKnowledge("المسبح شغال؟", entries)?.entry.id).toBe("pool");
    expect(matchKnowledge("عندكم إفطار", entries)?.entry.id).toBe("breakfast");
    expect(matchKnowledge("فيه فطور الصباح؟", entries)?.entry.id).toBe("breakfast");
  });

  it("matches English keywords and multi-word keywords as a phrase", () => {
    expect(matchKnowledge("Is there a pool?", entries)?.entry.id).toBe("pool");
    expect(matchKnowledge("ابغى سرير اضافي للطفل", entries)?.entry.id).toBe("bed");
    expect(matchKnowledge("هل تقبلون apple pay", entries)?.entry.id).toBe("pay");
  });

  it("question-wording overlap matches even without a keyword", () => {
    const m = matchKnowledge("ممكن تقدمون الافطار؟", entries);
    expect(m?.entry.id).toBe("breakfast");
  });

  it("possessive / plural suffixes still match (قطتي → قطه, حيواناتي → حيوان)", () => {
    expect(matchKnowledge("أقدر أجيب قطتي معي؟", entries)?.entry.id).toBe("pets");
    expect(matchKnowledge("مسموح حيواناتي؟", entries)?.entry.id).toBe("pets");
  });

  it("returns null when nothing fits — the question must be logged, not guessed", () => {
    expect(matchKnowledge("هل يوجد ملعب تنس؟", entries)).toBeNull();
    expect(matchKnowledge("كم سعر الليلة", entries)).toBeNull();
    expect(matchKnowledge("", entries)).toBeNull();
    expect(matchKnowledge("مسبح", [])).toBeNull();
  });

  it("picks the best entry when several match and reports which keywords hit", () => {
    const m = matchKnowledge("هل المسبح مسموح فيه الحيوانات؟", entries)!;
    expect(["pool", "pets"]).toContain(m.entry.id);
    expect(m.keywordHits.length).toBeGreaterThan(0);
    const strong = matchKnowledge("هل عندكم غسيل ملابس او مغسله؟", entries)!;
    expect(strong.entry.id).toBe("laundry");
    expect(strong.strong).toBe(true);
  });

  it("tokenizer drops stop words and the definite article", () => {
    expect(kbTokens(normalizeArabic("هل يوجد المسبح في الفندق؟"))).toEqual(["مسبح", "فندق"]);
  });
});

describe("scriptedReply with a knowledge base", () => {
  const knowledge: PropertyKnowledge = { branchName: "فرع الرياض", checkInTime: "16:00", checkOutTime: "12:00", policies: [{ topic: "parking", title: "المواقف", content: "مواقف مجانية." }], entries };

  it("answers from the entry and reports the entry id for usage analytics", () => {
    const r = scriptedReply("هل يوجد مسبح؟", "منازل الراحة", undefined, knowledge);
    expect(r.intent).toBe("knowledge");
    expect(r.text).toBe("نعم، يوجد مسبح خارجي مشترك.");
    expect(r.knowledgeId).toBe("pool");
    expect(r.actions.some((a) => a.label === "التحدث مع موظف")).toBe(true);
  });

  it("fixed topics (times, parking) still come from branch settings/policies, not from the Q&A", () => {
    expect(scriptedReply("متى موعد الوصول؟", "x", undefined, knowledge).intent).toBe("policy");
    expect(scriptedReply("هل توجد مواقف؟", "x", undefined, knowledge).text).toBe("مواقف مجانية.");
  });

  it("system intents keep priority over the knowledge base (existing booking, access code, human)", () => {
    expect(scriptedReply("لدي حجز سابق وأبغى أعرف عن المسبح", "x", undefined, knowledge).intent).toBe("existing_booking");
    expect(scriptedReply("أعطني رمز الدخول", "x", undefined, knowledge).intent).toBe("access_code");
  });

  it("a weak match echoes the matched question; no match says the question was logged", () => {
    const weak = scriptedReply("ابي اعرف شي بسيط عن الدفع يا اخوي", "x", undefined, knowledge);
    expect(weak.intent).toBe("knowledge");
    expect(weak.text).toMatch(/^بخصوص «ما طرق الدفع المتاحة؟»:/);
    const none = scriptedReply("هل يوجد ملعب تنس؟", "x", undefined, knowledge);
    expect(none.intent).toBe("unknown");
    expect(none.text).toMatch(/سجّلت سؤالك/);
  });

  it("a keyword in a short message is a clear question; 'عندكم' is not the price word 'كم'", () => {
    const r = scriptedReply("عندكم فطور؟", "x", undefined, knowledge);
    expect(r.intent).toBe("knowledge");
    expect(r.knowledgeId).toBe("breakfast");
    expect(scriptedReply("كم سعر الليلة؟", "x", undefined, knowledge).intent).toBe("availability");
    expect(scriptedReply("عندكم شي؟", "x").intent).not.toBe("availability");
  });

  it("without a knowledge base nothing changes for the existing intents", () => {
    expect(scriptedReply("هل يوجد مسبح؟", "x").intent).toBe("unknown");
  });
});
