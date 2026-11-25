/**
 * 5.4 (ق6) — حارس الإطار src/lib/frameGuard.ts: يكشف التأطير، يخفي المحتوى، ويخرج النافذة
 * العليا إلى جذر التطبيق دون أن يسرب مسار الصفحة أو استعلامها أو جزءها (رموز الضيوف في المسار).
 */
import { describe, it, expect } from "vitest";
import { isFramed, breakoutTarget, installFrameGuard } from "../../src/lib/frameGuard";

describe("كشف التأطير", () => {
  it("نافذة عليا (top === self) ليست مؤطرة", () => {
    const w: { top?: unknown; self?: unknown } = {};
    w.top = w.self = w;
    expect(isFramed(w as never)).toBe(false);
  });

  it("نافذة داخل iframe مؤطرة", () => {
    const top = {}, self = {};
    expect(isFramed({ top, self } as never)).toBe(true);
  });

  it("استثناء أثناء المقارنة يعامل كتأطير (فشل نحو الحماية)", () => {
    const w = { get top(): unknown { throw new Error("cross-origin"); }, self: {} };
    expect(isFramed(w as never)).toBe(true);
  });
});

describe("وجهة الخروج لا تسرب شيئًا من العنوان", () => {
  it("قاعدة جذر: تبقى الجذر مهما حمل المسار والاستعلام والجزء", () => {
    expect(breakoutTarget("/", "https://app.example/booking/status/SECRET-TOKEN?x=1#hash")).toBe("https://app.example/");
  });

  it("قاعدة مسار فرعي (صفحات GitHub): تبقى القاعدة فقط", () => {
    expect(breakoutTarget("/zaaer/", "https://mswsa99-ship-it.github.io/zaaer/checkin/SECRET-TOKEN")).toBe("https://mswsa99-ship-it.github.io/zaaer/");
  });

  it("لا يظهر رمز الضيف في الوجهة أبدًا", () => {
    const target = breakoutTarget("/", "https://app.example/checkin/9f8e7d6c-token");
    expect(target).not.toContain("9f8e7d6c");
    expect(target).not.toContain("checkin");
  });

  it("قاعدة فارغة أو عنوان مكسور يسقطان إلى الجذر", () => {
    expect(breakoutTarget("", "https://app.example/staff/inbox")).toBe("https://app.example/");
    expect(breakoutTarget("/", "not a url")).toBe("/");
  });
});

describe("installFrameGuard", () => {
  function framedWindow(href: string) {
    const calls: string[] = [];
    const style = { display: "" };
    const self: Record<string, unknown> = {
      location: { href, replace: (u: string) => calls.push(`self:${u}`) },
      document: { documentElement: { style } },
    };
    const top = { location: { replace: (u: string) => calls.push(`top:${u}`) } };
    self.top = top;
    self.self = self;
    return { w: self, calls, style };
  }

  it("داخل إطار: يخفي المحتوى وينقل الأعلى إلى الجذر بلا تسريب", () => {
    const { w, calls, style } = framedWindow("https://app.example/booking/status/SECRET?a=b#c");
    const framed = installFrameGuard(w as never, "/");
    expect(framed).toBe(true);
    expect(style.display).toBe("none");
    expect(calls).toEqual(["top:https://app.example/"]);
  });

  it("نافذة عليا: لا إخفاء ولا تنقل", () => {
    const style = { display: "" };
    const w: Record<string, unknown> = {
      location: { href: "https://app.example/", replace: () => { throw new Error("لا ينقل"); } },
      document: { documentElement: { style } },
    };
    w.top = w.self = w;
    expect(installFrameGuard(w as never, "/")).toBe(false);
    expect(style.display).toBe("");
  });

  it("منع نقل الأعلى (كروم بلا تفاعل): يكتفي بالإخفاء ولا يعيد تحميل الصفحة في حلقة", () => {
    const calls: string[] = [];
    const style = { display: "" };
    const self: Record<string, unknown> = {
      location: { href: "https://app.example/checkin/SECRET", replace: (u: string) => calls.push(`self:${u}`) },
      document: { documentElement: { style } },
    };
    self.top = { location: { replace: () => { throw new Error("blocked"); } } };
    self.self = self;
    expect(installFrameGuard(self as never, "/")).toBe(true);
    expect(style.display).toBe("none");
    expect(calls).toEqual([]); // لا تنقل ذاتي — الإخفاء هو الحماية
  });
});
