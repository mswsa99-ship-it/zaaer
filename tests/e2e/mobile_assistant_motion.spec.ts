/**
 * Plan 6.11 (finding U1) and plan 6.14 (finding U10) — worker package E.
 *
 * 6.11: on a 390 px phone the floating «مساعد العمليات» button never covers the last actionable control of a page,
 *       and it shrinks while the page scrolls. Keyboard operation and the RTL layout are preserved.
 * 6.14: the «تقليل الحركة» preference is honored (animations, transitions, smooth scrolling) and the assistant's
 *       secondary text keeps a computed contrast of at least 4.5:1.
 *
 * Titles stay descriptive without acceptance codes (worker-package rule: no central acceptance-library change);
 * the page lists mirror phone_width.spec.ts so both sweeps cover the same routes.
 */
import { test, expect } from "./fixtures";

const STAFF = ["/staff/dashboard", "/staff/arrivals", "/staff/reservations", "/staff/reservations/new", "/staff/identity-verification", "/staff/payments", "/staff/orders", "/staff/pos-settlement", "/staff/day-close", "/staff/expenses", "/staff/ledger", "/staff/access-approvals", "/staff/followups", "/staff/platforms", "/staff/day-summary", "/staff/rooms", "/staff/housekeeping", "/staff/codes", "/staff/tickets", "/staff/inbox", "/staff/journey"];
const ADMIN = ["/admin/dashboard", "/admin/branches", "/admin/room-categories", "/admin/rooms", "/admin/structure", "/admin/facilities", "/admin/task-types", "/admin/services", "/admin/products", "/admin/rates", "/admin/availability", "/admin/availability-rules", "/admin/reservations", "/admin/guests", "/admin/finance", "/admin/platform-payouts", "/admin/cash-accounts", "/admin/staff", "/admin/roles", "/admin/booking-sources", "/admin/ai-settings", "/admin/whatsapp", "/admin/payment-providers", "/admin/policies", "/admin/knowledge", "/admin/reports", "/admin/audit-logs", "/admin/usage", "/admin/review", "/admin/integrations", "/admin/assistant", "/admin/data-purge", "/admin/journey"];

/** ms values from a computed time list like "0.15s" or "0.01ms, 0.01ms". */
function timeListMs(v: string): number[] {
  return v.split(",").map((p) => {
    const t = p.trim();
    return t.endsWith("ms") ? Number.parseFloat(t) : Number.parseFloat(t) * 1000;
  });
}

test.describe("floating assistant on a phone and motion/contrast (plan 6.11 and 6.14)", () => {
  test("the floating assistant covers no control at the bottom of any staff or admin page on a 390px phone", async ({ page, loginAs, go }) => {
    test.setTimeout(480_000);
    await page.setViewportSize({ width: 390, height: 844 });
    await loginAs("owner");
    const fab = page.getByTestId("ops-copilot-fab");
    const covered: string[] = [];
    for (const p of [...STAFF, ...ADMIN]) {
      await go(p);
      await expect(fab).toBeVisible();
      await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight));
      // the check runs against the resting state: the button is back at full size after the scroll settles
      await expect(fab).not.toHaveAttribute("data-collapsed", "true", { timeout: 8_000 });
      const hits = await page.evaluate(() => {
        const fab = document.querySelector<HTMLElement>('[data-testid="ops-copilot-fab"]');
        if (!fab) return ["<assistant button missing>"];
        const header = [...document.querySelectorAll("header")].find((el) => el.getBoundingClientRect().height > 0);
        const tabs = document.querySelector<HTMLElement>('[data-testid="bottom-tabs"]');
        const safeTop = () => header ? Math.max(0, header.getBoundingClientRect().bottom) : 0;
        const safeBottom = () => tabs && tabs.getBoundingClientRect().height > 0 ? tabs.getBoundingClientRect().top : innerHeight;
        const out: string[] = [];
        const all = [...document.querySelectorAll<HTMLElement>('#main a[href], #main button, #main input, #main select, #main textarea, #main [role="button"], #main summary')];
        // Bottom-viewport targets include rectangles behind the sticky chrome. Never skip those:
        // bring each one into the usable area and prove pointer AND keyboard reachability there.
        const targets = all.filter((el) => {
          const r = el.getBoundingClientRect();
          return r.width > 0 && r.height > 0 && r.bottom > 0 && r.top < innerHeight && !el.matches(":disabled, [aria-disabled=true]");
        });
        for (const el of targets) {
          el.scrollIntoView({ block: "center", inline: "center" });
          const r = el.getBoundingClientRect();
          const top = Math.max(r.top, safeTop()), bottom = Math.min(r.bottom, safeBottom());
          const left = Math.max(r.left, 0), right = Math.min(r.right, innerWidth);
          const name = `${el.tagName.toLowerCase()}:${(el.textContent ?? "").trim().slice(0, 30)}`;
          if (bottom <= top || right <= left) { out.push(`outside usable viewport: ${name}`); continue; }
          const points = [[.5,.5],[.2,.5],[.8,.5],[.5,.2],[.5,.8]];
          const reachable = points.some(([x,y]) => {
            const hit = document.elementFromPoint(left + (right-left)*x, top + (bottom-top)*y);
            return hit === el || !!hit && el.contains(hit);
          });
          if (!reachable) { const hit = document.elementFromPoint((left+right)/2,(top+bottom)/2); out.push(`pointer blocked: ${name} by ${hit?.tagName}:${hit?.textContent?.slice(0,40)} rect ${r.x},${r.y},${r.width},${r.height}`); }
          el.focus({ preventScroll: true });
          if (document.activeElement !== el) out.push(`focus blocked: ${name}`);
        }
        // Independently reject FAB overlap in the actual usable viewport, even if another
        // part of a wide control can still be clicked. Sticky header/nav are separate chrome.
        const f = fab.getBoundingClientRect();
        for (const el of all) {
          const r = el.getBoundingClientRect();
          const l = Math.max(r.left,f.left), right = Math.min(r.right,f.right);
          const top = Math.max(r.top,f.top,safeTop()), bottom = Math.min(r.bottom,f.bottom,safeBottom());
          if (right <= l || bottom <= top) continue;
          const hit = document.elementFromPoint((l+right)/2,(top+bottom)/2);
          if (hit && (hit === fab || fab.contains(hit))) out.push(`assistant overlap: ${el.tagName.toLowerCase()}`);
        }
        return out;
      });
      for (const h of hits) covered.push(`${p} → ${h}`);
    }
    expect(covered).toEqual([]);
  });

  test("the floating assistant shrinks while scrolling down and returns when the scroll stops", async ({ page, loginAs, go }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await loginAs("owner");
    await go("/staff/reservations");
    const fab = page.getByTestId("ops-copilot-fab");
    await expect(fab).not.toHaveAttribute("data-collapsed", "true");
    const fullTransform = await fab.evaluate((el) => getComputedStyle(el).transform);
    await page.evaluate(async () => {
      for (let y = 0; y <= document.documentElement.scrollHeight; y += 120) {
        window.scrollTo(0, y);
        await new Promise((r) => setTimeout(r, 40));
      }
    });
    await expect(fab).toHaveAttribute("data-collapsed", "true", { timeout: 3_000 });
    // the collapse is a real visual shrink (scale transform), not only a flag
    await expect
      .poll(async () => fab.evaluate((el) => getComputedStyle(el).transform), { timeout: 3_000 })
      .toMatch(/^matrix\(0\.[0-6]/);
    // scrolling stopped: the button comes back to full size on its own
    await expect(fab).not.toHaveAttribute("data-collapsed", "true", { timeout: 5_000 });
    await expect
      .poll(async () => fab.evaluate((el) => getComputedStyle(el).transform), { timeout: 3_000 })
      .toBe(fullTransform);
    // scrolling back up also restores it at once
    await page.evaluate(() => window.scrollTo(0, 0));
    await expect(fab).not.toHaveAttribute("data-collapsed", "true");
  });

  test("the assistant opens and closes from the keyboard and the open panel stays inside the RTL phone viewport", async ({ page, loginAs, go }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await loginAs("owner");
    await go("/staff/dashboard");
    expect(await page.evaluate(() => document.dir)).toBe("rtl");
    const fab = page.getByTestId("ops-copilot-fab");
    const tabs = page.getByTestId("bottom-tabs");
    const fabBox = (await fab.boundingBox())!;
    const tabsBox = (await tabs.boundingBox())!;
    expect(fabBox.y + fabBox.height, "the button never sits on the bottom tab bar").toBeLessThanOrEqual(tabsBox.y + 1);
    await fab.focus();
    await expect(fab).toBeFocused();
    await page.keyboard.press("Enter");
    await expect(fab).toHaveAttribute("aria-expanded", "true");
    const dialog = page.getByRole("dialog", { name: "مساعد العمليات" });
    await expect(dialog).toBeVisible();
    const box = (await dialog.boundingBox())!;
    expect(box.x).toBeGreaterThanOrEqual(0);
    expect(box.x + box.width).toBeLessThanOrEqual(390);
    expect(box.y + box.height).toBeLessThanOrEqual(844);
    await dialog.getByRole("button", { name: "إغلاق المساعد" }).focus();
    await page.keyboard.press("Enter");
    await expect(dialog).toBeHidden();
    await expect(fab).toHaveAttribute("aria-expanded", "false");
  });

  test("reduced motion preference turns animations, transitions and smooth scrolling off", async ({ page, loginAs, go }) => {
    const probe = () =>
      page.evaluate(() => {
        const el = document.createElement("div");
        el.className = "animate-spin transition-colors";
        el.style.cssText = "position:fixed;inset:0;pointer-events:none;visibility:hidden";
        document.body.appendChild(el);
        const cs = getComputedStyle(el);
        const out = { animDuration: cs.animationDuration, transDuration: cs.transitionDuration, iter: cs.animationIterationCount };
        el.remove();
        return out;
      });
    await loginAs("owner");
    await go("/staff/dashboard");
    // control: with motion allowed the spinner spins and color transitions tween
    const normal = await probe();
    expect(Math.max(...timeListMs(normal.animDuration)), "control: an animation exists when motion is allowed").toBeGreaterThan(100);
    expect(Math.max(...timeListMs(normal.transDuration)), "control: a transition exists when motion is allowed").toBeGreaterThan(50);
    expect(normal.iter).toBe("infinite");
    // the preference: everything falls to instant
    await page.emulateMedia({ reducedMotion: "reduce" });
    const reduced = await probe();
    expect(Math.max(...timeListMs(reduced.animDuration))).toBeLessThanOrEqual(0.011);
    expect(Math.max(...timeListMs(reduced.transDuration))).toBeLessThanOrEqual(0.011);
    expect(reduced.iter).toBe("1");
    // and the assistant still works with motion off
    await page.getByTestId("ops-copilot-fab").click();
    await expect(page.getByRole("dialog", { name: "مساعد العمليات" })).toBeVisible();
  });

  test("assistant text keeps at least 4.5:1 computed contrast against its background", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/staff/dashboard");
    await page.getByTestId("ops-copilot-fab").click();
    const dialog = page.getByRole("dialog", { name: "مساعد العمليات" });
    await expect(dialog).toBeVisible();
    // every text variant: the intro + suggestions first, then an exchange (both bubbles and the mode note),
    // then a proposal card with its action buttons
    type Pair = { fg: string; bg: string; ratio: number; need: number; sample: string };
    const walk = () =>
      page.evaluate(() => {
      const parse = (s: string): [number, number, number, number] | null => {
        const m = s.match(/rgba?\(([^)]+)\)/);
        if (!m) return null;
        const [r, g, b, a] = m[1].split(",").map((x) => Number.parseFloat(x));
        return [r, g, b, a === undefined || Number.isNaN(a) ? 1 : a];
      };
      const channel = (x: number) => {
        const c = x / 255;
        return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
      };
      const luminance = ([r, g, b]: number[]) => 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
      const effBg = (el: Element | null): [number, number, number, number] => {
        let n = el;
        while (n) {
          const c = parse(getComputedStyle(n).backgroundColor);
          if (c && c[3] > 0) return c;
          n = n.parentElement;
        }
        return [255, 255, 255, 1];
      };
      const ratio = (fg: [number, number, number, number], bg: [number, number, number, number]) => {
        const la = luminance(fg);
        const lb = luminance(bg);
        return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
      };
      const scope = [document.querySelector('[data-testid="ops-copilot-fab"]'), document.querySelector('div[role="dialog"][aria-label="مساعد العمليات"]')].filter(Boolean) as Element[];
      const seen = new Map<string, { fg: string; bg: string; ratio: number; need: number; sample: string }>();
      for (const root of scope) {
        const els = [root, ...root.querySelectorAll("*")];
        for (const el of els) {
          const direct = [...el.childNodes].some((n) => n.nodeType === Node.TEXT_NODE && (n.textContent ?? "").trim());
          if (!direct) continue;
          const cs = getComputedStyle(el);
          if (cs.visibility === "hidden" || cs.display === "none") continue;
          const fg = parse(cs.color);
          const bg = effBg(el);
          if (!fg) continue;
          const px = Number.parseFloat(cs.fontSize);
          const large = px >= 24 || (px >= 18.66 && Number.parseFloat(cs.fontWeight) >= 700);
          const need = large ? 3 : 4.5;
          const r = ratio(fg, bg);
          const key = `${cs.color} on rgb(${bg[0]}, ${bg[1]}, ${bg[2]})`;
          const prev = seen.get(key);
          if (!prev || r < prev.ratio) seen.set(key, { fg: cs.color, bg: `rgb(${bg[0]}, ${bg[1]}, ${bg[2]})`, ratio: r, need, sample: (el.textContent ?? "").trim().slice(0, 40) });
        }
      }
      // the field placeholder is text too (a pseudo-element, walked separately)
      const input = document.querySelector<HTMLInputElement>('div[role="dialog"][aria-label="مساعد العمليات"] input');
      if (input) {
        const pc = getComputedStyle(input, "::placeholder").color;
        const fg = parse(pc);
        if (fg) {
          const bg = effBg(input);
          const r = ratio(fg, bg);
          seen.set(`placeholder ${pc}`, { fg: pc, bg: `rgb(${bg[0]}, ${bg[1]}, ${bg[2]})`, ratio: r, need: 4.5, sample: "placeholder: اكتب سؤالك أو طلبك…" });
        }
      }
      return [...seen.values()];
    });
    const merged = new Map<string, Pair>();
    const merge = (pairs: Pair[]) => {
      for (const v of pairs) {
        const key = `${v.fg} on ${v.bg}`;
        const prev = merged.get(key);
        if (!prev || v.ratio < prev.ratio) merged.set(key, v);
      }
    };
    merge(await walk());   // intro + suggestions + placeholder + header + the button itself
    await dialog.getByRole("button", { name: "ما وضع اليوم؟" }).click();
    await expect(dialog.locator("div.whitespace-pre-wrap")).toHaveCount(2, { timeout: 15_000 });
    merge(await walk());   // both bubbles and the mode note
    await dialog.getByPlaceholder("اكتب سؤالك أو طلبك…").fill("أنشئ مهمة تنظيف للوحدة 102");
    await dialog.getByPlaceholder("اكتب سؤالك أو طلبك…").press("Enter");
    await expect(dialog.getByRole("button", { name: "تأكيد وتنفيذ" })).toBeVisible({ timeout: 15_000 });
    merge(await walk());   // the proposal card and its action buttons
    const pairs = [...merged.values()].sort((a, b) => a.ratio - b.ratio);
    const lines = pairs.map((v) => `${v.ratio.toFixed(2)}:1 (needs ${v.need}:1) ${v.fg} on ${v.bg} — «${v.sample}»`);
    const failures = pairs.filter((v) => v.ratio < v.need).map((v) => `${v.ratio.toFixed(2)}:1 < ${v.need}:1 — ${v.fg} on ${v.bg} — «${v.sample}»`);
    await test.info().attach("assistant-contrast-pairs", { body: lines.join("\n"), contentType: "text/plain" });
    console.info("computed contrast pairs (assistant):\n" + lines.join("\n"));
    expect(failures).toEqual([]);
  });
});
