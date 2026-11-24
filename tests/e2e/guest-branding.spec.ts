/**
 * Plan phase 3, item 3.5 (descriptive names until a prefix is registered in the acceptance library):
 * the guest's pages put the hotel's name and logo first, and the platform's name appears as
 * «يعمل بـ RoomAI» in the footer only — never leading a guest page.
 */
import { test, expect } from "./fixtures";

const POWERED_AR = "يعمل بـ RoomAI";
const POWERED_EN = "Powered by RoomAI";
const HOTEL = "فايف اورز";

/** Every route GuestLayout serves without a private key (the keyed pages are covered below). */
const ROUTES = ["/", "/reception", "/booking/lookup", "/booking/new", "/privacy", "/terms", "/kiosk"];

/** Where «RoomAI» is mentioned on the page versus inside the footer. */
async function roomAiMentions(page: import("@playwright/test").Page) {
  return page.evaluate(() => {
    const count = (hay: string, needle: string) => hay.split(needle).length - 1;
    const body = document.body.innerText;
    const footer = document.querySelector("footer")?.innerText ?? "";
    return { body: count(body, "RoomAI"), footer: count(footer, "RoomAI") };
  });
}

test.describe("guest branding (plan item 3.5)", () => {
  for (const route of ROUTES) {
    test(`the hotel leads ${route} and RoomAI stays in the footer only`, async ({ page, go }) => {
      await go(route);
      // the hotel's name leads the page
      await expect(page.locator("header")).toContainText(HOTEL);
      // «يعمل بـ RoomAI» sits in the footer
      const footer = page.locator("footer");
      await expect(footer).toContainText(POWERED_AR);
      // … and nowhere else on the page
      const mentions = await roomAiMentions(page);
      expect(mentions.footer, "the footer carries «يعمل بـ RoomAI»").toBeGreaterThan(0);
      expect(mentions.body, "RoomAI is mentioned in the footer only").toBe(mentions.footer);
      // the hotel's name comes before any platform mention
      const order = await page.evaluate((hotel) => {
        const t = document.body.innerText;
        return { hotel: t.indexOf(hotel), roomai: t.indexOf("RoomAI") };
      }, HOTEL);
      expect(order.hotel, "the hotel's name is on the page").toBeGreaterThanOrEqual(0);
      expect(order.hotel, "the hotel's name precedes «يعمل بـ RoomAI»").toBeLessThan(order.roomai);
    });
  }

  test("the footer line carries the approved mark and translates with the guest's language toggle", async ({ page, go }) => {
    await go("/booking/lookup");
    // the 16px mark (arch + spark) sits with the line, per the approved GuestBrand spec
    await expect(page.getByTestId("powered-by-roomai").locator("img")).toBeVisible();
    await page.getByTestId("guest-lang").click();
    await expect(page.locator("footer")).toContainText(POWERED_EN);
    await page.getByTestId("guest-lang").click();
    await expect(page.locator("footer")).toContainText(POWERED_AR);
  });

  test("a keyed guest page (review invitation) follows the same branding", async ({ page, go }) => {
    // a synthetic review invitation in the demo store — invented data, no server involved
    const token = "gb35-synthetic-review";
    await go("/");
    await page.evaluate((tok) => {
      const key = "zaaer_demo_store_v9";
      const s = JSON.parse(localStorage.getItem(key)!);
      let a = 0x811c9dc5, b = 0x9e3779b9;
      for (let i = 0; i < tok.length; i++) {
        const c = tok.charCodeAt(i);
        a = Math.imul(a ^ c, 16777619) >>> 0;
        b = Math.imul(b + c, 2246822519) >>> 0;
      }
      const hash = a.toString(16).padStart(8, "0") + b.toString(16).padStart(8, "0") + tok.length.toString(16);
      s.guest_reviews.push({
        id: "gb35", organization_id: s.organizations[0].id, branch_id: s.branches[0].id,
        reservation_id: s.reservations[0].id, token_hash: hash, invited_at: new Date().toISOString(), version: 1,
      });
      localStorage.setItem(key, JSON.stringify(s));
    }, token);
    await page.goto("about:blank");
    await page.goto(`/#/booking/review/${token}`);
    await page.reload();
    await expect(page.getByTestId("mark-overall")).toBeVisible();
    await expect(page.locator("header")).toContainText(HOTEL);
    const footer = page.locator("footer");
    await expect(footer).toContainText(POWERED_AR);
    const mentions = await roomAiMentions(page);
    expect(mentions.body).toBe(mentions.footer);
  });

  test("the hotel's own logo, when the owner sets one, leads the header before the name", async ({ page, go }) => {
    // an invented one-pixel logo stored as the organisation's logo in the demo store
    const PIXEL = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";
    await go("/");
    await page.evaluate((logo) => {
      const key = "zaaer_demo_store_v9";
      const s = JSON.parse(localStorage.getItem(key)!);
      s.organizations[0].logo = logo;
      s.organizations[0].logo_sha256 = "synthetic";
      localStorage.setItem(key, JSON.stringify(s));
      localStorage.removeItem("zaaer_org_name_v1:guest:legacy");
    }, PIXEL);
    await page.goto("about:blank");
    await page.goto("/#/", { waitUntil: "networkidle" });
    await page.reload();
    const logo = page.locator("header").getByRole("img", { name: `شعار ${HOTEL}` });
    await expect(logo).toBeVisible();
    await expect(page.locator("header")).toContainText(HOTEL);
  });
});
