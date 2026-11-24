import { test, expect } from "./fixtures";
import { mkdirSync } from "node:fs";

for (const width of [390, 1366]) {
  test(`self-hosted Arabic and Latin fonts stay local at ${width}px`, async ({ page, loginAs, baseURL }) => {
    await page.setViewportSize({ width, height: 900 });
    const externalFonts: string[] = [];
    const fontResponses: { url: string; status: number }[] = [];
    page.on("request", (request) => {
      const url = new URL(request.url());
      if ((request.resourceType() === "font" || /fonts\.(googleapis|gstatic)\.com/.test(url.hostname)) && url.origin !== new URL(baseURL!).origin) {
        externalFonts.push(request.url());
      }
    });
    page.on("response", (response) => {
      if (response.request().resourceType() === "font") fontResponses.push({ url: response.url(), status: response.status() });
    });
    await page.goto("/#/", { waitUntil: "networkidle" });
    const fontState = await page.evaluate(async () => {
      for (const weight of [300, 400, 500, 600, 700]) {
        await document.fonts.load(`${weight} 16px "IBM Plex Sans Arabic"`, "مرحبا RoomAI");
      }
      await document.fonts.ready;
      return { ready: document.fonts.check('400 16px "IBM Plex Sans Arabic"', "مرحبا RoomAI"), stack: getComputedStyle(document.body).fontFamily };
    });
    expect(fontState.ready).toBe(true);
    expect(fontState.stack).toContain("system-ui");
    for (const weight of [300, 400, 500, 600, 700]) {
      for (const script of ["arabic", "latin"]) {
        expect(fontResponses.some((response) => response.url.includes(`-${script}-${weight}-`) && response.status === 200)).toBe(true);
      }
    }
    mkdirSync("/downloads/roomai-i-evidence", { recursive: true });
    await page.screenshot({ path: `/downloads/roomai-i-evidence/guest-${width}.png`, fullPage: true });
    await loginAs("owner");
    await page.evaluate(() => document.fonts.ready);
    await page.screenshot({ path: `/downloads/roomai-i-evidence/staff-${width}.png`, fullPage: true });
    expect(externalFonts).toEqual([]);
    expect(fontResponses.every((response) => response.status === 200)).toBe(true);
    console.log(JSON.stringify({ width, externalFonts, fontResponses }));
  });
}

test("local font failure keeps the fallback usable without a third-party retry", async ({ page }) => {
  const external: string[] = [];
  page.on("request", (request) => {
    if (/fonts\.(googleapis|gstatic)\.com/.test(new URL(request.url()).hostname)) external.push(request.url());
  });
  await page.route("**/fonts/*.woff2", (route) => route.abort());
  await page.goto("/#/staff/login", { waitUntil: "networkidle" });
  await expect(page.getByRole("button", { name: "تسجيل الدخول", exact: true }).first()).toBeVisible();
  expect(await page.locator("body").evaluate((el) => getComputedStyle(el).fontFamily)).toContain("system-ui");
  expect(external).toEqual([]);
});
