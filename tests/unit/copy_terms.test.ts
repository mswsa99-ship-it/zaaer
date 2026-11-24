/**
 * Plan phase 3, item 3.8 — the copy guide's guard test (COPY_GUIDE.md).
 * Scans the product's own copy (src/**, excluding src/demo/data.ts: the hotel's seed data and the
 * simulated guest messages are the hotel's words, not the product's) and rejects:
 *   1. words the guide bans outright (abandoned alternatives and misspellings) — any occurrence fails;
 *   2. growth of the two words whose replacement awaits the approved identity spec (COPY_GUIDE §4):
 *      their count is frozen at today's baseline, so nobody adds new uses of a word pending deprecation.
 */
import { describe, it, expect } from "vitest";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const SRC = join(__dirname, "..", "..", "src");
const EXCLUDED = new Set(["src/demo/data.ts"]);

/** Banned outright — the guide names the approved alternative for each (COPY_GUIDE.md §1). */
const BANNED: Array<{ word: string; approved: string }> = [
  // Preventive spelling checks, not terminology/API-key replacements.
  { word: "الى", approved: "إلى" },
  { word: "تعذر", approved: "تعذّر" },
  { word: "عذرا", approved: "ابدأ بما حدث، بلا اعتذار افتتاحي" },
  { word: "زبون", approved: "نزيل" },
  { word: "ساكن", approved: "نزيل" },
  { word: "أيصال", approved: "إيصال" },
  { word: "حجوزه", approved: "حجوزة" },
  { word: "إقامه", approved: "إقامة" },
  { word: "غرفه", approved: "غرفة" },
  { word: "إيصال قبض", approved: "سند قبض" },
  { word: "إيصال دفع", approved: "سند قبض" },
  { word: "إيصال صرف", approved: "سند صرف" },
];

/**
 * Frozen while their replacement awaits the identity-spec decision (COPY_GUIDE.md §4). The number is the
 * count on the day the guide was written; the test refuses growth, and whoever performs the approved
 * rename lowers the baseline in the same change.
 */
// «ضيف» baseline = 72 is the raw-substring count MEASURED on this tree (it also holds on the 1939 and older
// trees). It includes 11 verb forms of «أضاف» (يضيف / أُضيف / أُضيفت / فأُضيف), so it is a no-increase guard
// only; the real noun guard is the exact per-file test below. The earlier 71 has no reproducible source.
const FROZEN: Array<{ word: string; baseline: number; approved: string }> = [
  { word: "ضيف", baseline: 72, approved: "نزيل" },
  { word: "غرفة", baseline: 26, approved: "وحدة" },
];

function* copyFiles(dir: string): Generator<string> {
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) yield* copyFiles(full);
    else if (/\.(ts|tsx)$/.test(name) && !EXCLUDED.has(relative(join(SRC, ".."), full))) yield full;
  }
}

function occurrences(word: string): Array<{ file: string; count: number }> {
  const out: Array<{ file: string; count: number }> = [];
  for (const file of copyFiles(SRC)) {
    const text = readFileSync(file, "utf8");
    const count = text.split(word).length - 1;
    if (count > 0) out.push({ file: relative(join(SRC, ".."), file), count });
  }
  return out;
}

describe("copy terms (plan item 3.8, COPY_GUIDE.md)", () => {
  it("no banned word appears in the product's own copy", () => {
    const findings: string[] = [];
    for (const { word, approved } of BANNED) {
      for (const hit of occurrences(word)) findings.push(`«${word}» (${hit.count}) في ${hit.file} — المعتمد: «${approved}»`);
    }
    expect(findings, `كلمات ممنوعة في صياغة المنتج (COPY_GUIDE.md §1):\n${findings.join("\n")}`).toEqual([]);
  });

  it("words pending the identity-spec decision do not grow beyond their frozen baseline", () => {
    const findings: string[] = [];
    for (const { word, baseline, approved } of FROZEN) {
      const hits = occurrences(word);
      const total = hits.reduce((n, h) => n + h.count, 0);
      if (total > baseline) {
        findings.push(
          `«${word}» زادت من ${baseline} إلى ${total} — الكلمة قيد الاعتماد والبديل «${approved}» (COPY_GUIDE.md §4). ` +
          `لا تضف استعمالًا جديدًا؛ وإن كنت تنفذ التحويل المعتمد فاخفض الرقم في هذا الاختبار مع الدفعة نفسها. المواضع الجديدة غالبًا في: ` +
          hits.map((h) => `${h.file} (${h.count})`).join(", "),
        );
      }
    }
    expect(findings, findings.join("\n")).toEqual([]);
  });

  it("the frozen baselines stay honest: they are never below the real count either", () => {
    // a baseline left higher than the real count after a completed rename would silently allow a comeback
    for (const { word, baseline } of FROZEN) {
      const total = occurrences(word).reduce((n, h) => n + h.count, 0);
      expect(total, `«${word}»: العدد الفعلي ${total} أقل من المجمّد ${baseline} — حدّث الرقم ليعكس التحويل المنجز`).toBeGreaterThanOrEqual(baseline);
    }
  });
});

// ---- «ضيف» as the NOUN "guest": exact per-file freeze (verbs of «أضاف» do not count) -------------------
// Noun forms: ضيف / الضيف / للضيف / لضيف / وضيف / بالضيف ... with at most one Arabic letter-prefix and no
// letter after (so ضيوف, يضيف, أُضيف, أُضيفت, فأُضيف, مضيف are not nouns). Tashkeel before the word (أُ) blocks a match.
export const GUEST_NOUN = /(?<![\u0621-\u064A\p{Mn}])(?:لل|[وفبكل]?(?:ال)?)ضيف(?![\u0621-\u064A])/gu;
const GUEST_NOUN_BASELINE: Record<string, number> = {
  "src/components/BranchGuideEditor.tsx": 1,
  "src/components/GuestJourney.tsx": 1,
  "src/components/StayCycle.tsx": 3,
  "src/demo/client.ts": 4,
  "src/demo/guests.ts": 3,
  "src/demo/journey.ts": 4,
  "src/demo/phase6.ts": 1,
  "src/layouts/AdminLayout.tsx": 2,
  "src/layouts/StaffLayout.tsx": 2,
  "src/lib/api.ts": 4,
  "src/lib/auditLabels.ts": 14,
  "src/lib/capabilityCatalog.ts": 2,
  "src/lib/journeyAlerts.ts": 1,
  "src/lib/nav.ts": 2,
  "src/lib/permissionCatalog.ts": 3,
  "src/pages/admin/AdminJourney.tsx": 9,
  "src/pages/staff/StaffJourney.tsx": 5
};
const GUEST_NOUN_TOTAL = 61;

function guestNounCounts(): Record<string, number> {
  const out: Record<string, number> = {};
  for (const file of copyFiles(SRC)) {
    const k = (readFileSync(file, "utf8").match(GUEST_NOUN) ?? []).length;
    if (k > 0) out[relative(join(SRC, ".."), file).split("\\").join("/")] = k;
  }
  return out;
}

describe("«ضيف» noun guard (COPY_GUIDE.md §4) — exact, per file", () => {
  it("recognizer fixtures: nouns count, verbs do not", () => {
    const n = (s: string) => (s.match(GUEST_NOUN) ?? []).length;
    for (const s of ["ضيف", "الضيف", "للضيف،", "لضيف", "وضيف", "بالضيف", "رحلة الضيف", "ضيف."]) expect(n(s), s).toBe(1);
    for (const s of ["يضيف المالك", "أُضيف إلى", "أُضيفت الصورة", "فأُضيف", "ضيوف", "مضيف", "تضيف", "ضيفة"]) expect(n(s), s).toBe(0);
    expect(n("الضيف وضيف")).toBe(2);
  });

  it("no file gains a guest-noun use and the total never rises", () => {
    const now = guestNounCounts();
    const grew = Object.entries(now).filter(([f, k]) => k > (GUEST_NOUN_BASELINE[f] ?? 0)).map(([f, k]) => `${f}: ${GUEST_NOUN_BASELINE[f] ?? 0} -> ${k}`);
    const total = Object.values(now).reduce((a, b) => a + b, 0);
    expect(grew, `«ضيف» (اسم) زادت: ${grew.join(", ")}`).toEqual([]);
    expect(total).toBeLessThanOrEqual(GUEST_NOUN_TOTAL);
  });

  it("baseline stays exact (a rename must lower it in the same change)", () => {
    const now = guestNounCounts();
    expect(now).toEqual(GUEST_NOUN_BASELINE);
    expect(Object.values(now).reduce((a, b) => a + b, 0)).toBe(GUEST_NOUN_TOTAL);
  });

  it("mutant: one added noun use is caught (+1), one added verb use is not", () => {
    const base = Object.values(guestNounCounts()).reduce((a, b) => a + b, 0);
    const withNoun = base + ("نص جديد: الضيف".match(GUEST_NOUN) ?? []).length;
    const withVerb = base + ("نص جديد: يضيف".match(GUEST_NOUN) ?? []).length;
    expect(withNoun).toBe(GUEST_NOUN_TOTAL + 1);
    expect(withNoun).toBeGreaterThan(GUEST_NOUN_TOTAL);
    expect(withVerb).toBe(GUEST_NOUN_TOTAL);
  });
});
