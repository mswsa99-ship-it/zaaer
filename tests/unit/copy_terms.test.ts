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
const FROZEN: Array<{ word: string; baseline: number; approved: string }> = [
  { word: "ضيف", baseline: 71, approved: "نزيل" },
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
