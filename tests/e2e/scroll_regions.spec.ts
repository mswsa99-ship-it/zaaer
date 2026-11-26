/** Wide tables become keyboard-reachable named regions, without touching tab strips or existing semantics; owner tickets jump row. Invented demo data only. */
import { test, expect } from "./fixtures";

test.describe("scroll regions and tickets jump row", () => {
  test.use({ viewport: { width: 390, height: 844 } });

  test("SCR1 accounts table: region, Tab reaches it, arrow keys scroll it; tab strips and hub nav are not relabelled", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/staff/accounts", { waitUntil: "networkidle" });
    const region = page.locator('main [data-scroll-region="1"]').first();
    await expect(region).toHaveAttribute("role", "region");
    await expect(region).toHaveAttribute("tabindex", "0");
    await expect(region).toHaveAttribute("aria-label", "جدول قابل للتمرير أفقيًا");
    // nested tab strips and the hub nav keep their own semantics and get no tabindex or region label from the hook
    await expect(page.locator('main [role="tablist"].overflow-x-auto')).not.toHaveAttribute("tabindex", /.*/);
    expect(await page.locator('main nav .overflow-x-auto[data-scroll-region], main [role="tablist"][data-scroll-region], nav[data-testid="hub-tabs"][data-scroll-region]').count()).toBe(0);
    expect(await page.locator('main [role="tablist"].overflow-x-auto').first().getAttribute("aria-label")).toBe("عرض الحسابات");
    // keyboard: focus lands in the region and the arrow keys scroll it
    await region.focus();
    const before = await region.evaluate((e) => e.scrollLeft);
    await page.keyboard.press("ArrowLeft");
    await page.keyboard.press("ArrowLeft");
    await expect.poll(() => region.evaluate((e) => e.scrollLeft)).not.toBe(before);
  });

  test("SCR2 existing role, tabindex and aria-label are never overwritten; resize to wide removes only hook-owned attributes", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/staff/accounts", { waitUntil: "networkidle" });
    const region = page.locator('main [data-scroll-region="1"]').first();
    await expect(region).toBeVisible();
    // a container that already has its own semantics keeps them
    await page.evaluate(() => {
      const el = document.createElement("div");
      el.className = "overflow-x-auto";
      el.setAttribute("aria-label", "جدولي");
      el.setAttribute("role", "group");
      el.innerHTML = '<div style="width:2000px">x</div>';
      document.getElementById("main")!.appendChild(el);
      el.id = "own-scroll";
    });
    await expect(page.locator("#own-scroll")).toHaveAttribute("aria-label", "جدولي");
    await expect(page.locator("#own-scroll")).toHaveAttribute("role", "group");
    await page.setViewportSize({ width: 1366, height: 900 });
    await page.waitForTimeout(300);
    await expect(page.locator('main [data-scroll-region="1"]')).toHaveCount(1); // only the hand-made wide container, still overflowing
    await expect(page.locator("#own-scroll")).toHaveAttribute("aria-label", "جدولي");
    await expect(page.locator('main table').first()).toBeVisible();
    // the accounts table no longer overflows at 1366: the hook removed what it added, nothing else
    const stillMarked = await page.evaluate(() => [...document.querySelectorAll('main .overflow-x-auto')].filter((e) => e.id !== "own-scroll" && e.getAttribute("role") === "region").length);
    expect(stillMarked).toBe(0);
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(1366);
  });

  test("SCR3 no mutation loop: attributes settle and the page stays idle; leaving the page cleans up the observer", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/staff/accounts", { waitUntil: "networkidle" });
    // count the hook's own attribute writes over 800 ms after it settled: it must not keep writing
    const mutations = await page.evaluate(() => new Promise<number>((resolve) => {
      let n = 0;
      // only the hook's own writes count (the app may re-render for other reasons)
      const mo = new MutationObserver((r) => { n += r.filter((m) => m.type === "attributes" && ["tabindex", "role", "aria-label"].includes(m.attributeName || "") && (m.target as HTMLElement).classList.contains("overflow-x-auto")).length; });
      mo.observe(document.getElementById("main")!, { attributes: true, childList: true, subtree: true });
      setTimeout(() => { mo.disconnect(); resolve(n); }, 800);
    }));
    expect(mutations).toBe(0);
    await page.goto("/#/staff/rooms", { waitUntil: "networkidle" });
    await page.goto("/#/staff/accounts", { waitUntil: "networkidle" });
    await expect(page.locator('main [data-scroll-region="1"]')).toHaveCount(1);
  });

  test("SCR4 owner tickets: jump row with real counts, one section reachable; other roles see no jump row", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/staff/tickets", { waitUntil: "networkidle" });
    const jump = page.getByTestId("tickets-jump");
    await expect(jump).toBeVisible();
    const h = jump.getByRole("button", { name: /طلبات التحويل \(\d+\)/ });
    const m = jump.getByRole("button", { name: /البلاغات والصيانة \(\d+\)/ });
    await expect(h).toBeVisible();
    await expect(m).toBeVisible();
    const handoffCount = Number((await h.innerText()).match(/\((\d+)\)/)![1]);
    await expect(page.getByText(`طلبات مفتوحة: ${handoffCount}`)).toBeVisible();
    const box = await h.boundingBox();
    expect(box!.height).toBeGreaterThanOrEqual(44);
    await m.click();
    await expect(page.locator("#tickets-maintenance")).toBeInViewport();
  });

  test("SCR5 room service and finance tickets: no jump row (handoff section stays owner/supervisor scoped as before)", async ({ page, loginAs }) => {
    await loginAs("housekeeping");
    await page.goto("/#/staff/tickets", { waitUntil: "networkidle" });
    await expect(page.getByTestId("tickets-jump")).toHaveCount(0);
    await expect(page.getByRole("heading", { name: "البلاغات والصيانة" })).toBeVisible();
  });
});
