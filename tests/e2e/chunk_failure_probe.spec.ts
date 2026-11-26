/** Chunk-failure probe for the lazy staff pages (xcombo). Demo build only, not live proof. */
import { test, expect } from "./fixtures";
const CHUNK = "**/assets/Housekeeping-*.js";
test("CF1 online: a page file that cannot load reloads once, then shows the app message and button", async ({ page, loginAs, errors }) => {
  await loginAs("owner");
  let docLoads = 0;
  page.on("request", (r) => { if (r.resourceType() === "document") docLoads++; });
  await page.route(CHUNK, (r) => r.abort());
  await page.evaluate(() => { location.hash = "#/staff/housekeeping"; });
  await expect(page.getByTestId("app-error")).toBeVisible({ timeout: 15000 });
  await expect(page.getByRole("heading", { name: "تعذّر تحميل الصفحة" })).toBeVisible();
  console.log("CF1 document loads after failure:", docLoads);
  expect(docLoads).toBeLessThanOrEqual(2);   // one automatic reload at most
  await page.screenshot({ path: "/tmp/proof/cf1-online.png" });
  // recovery: the file is reachable again, the button reloads and the page opens
  await page.unroute(CHUNK);
  await page.getByRole("button", { name: "إعادة التحميل" }).click();
  await expect(page.getByTestId("app-error")).toHaveCount(0, { timeout: 15000 });
  errors.splice(0);
});
test("CF2 offline: no automatic reload, the app message and retry button stay", async ({ page, context, loginAs, errors }) => {
  await loginAs("owner");
  await page.evaluate(() => { (window as unknown as { __m: number }).__m = 1; });
  await page.route(CHUNK, (r) => r.abort());
  await context.setOffline(true);
  await page.evaluate(() => { location.hash = "#/staff/housekeeping"; });
  await expect(page.getByTestId("app-error")).toBeVisible({ timeout: 15000 });
  await page.waitForTimeout(1500);
  expect(await page.evaluate(() => (window as unknown as { __m?: number }).__m)).toBe(1);   // the document was not reloaded
  await expect(page.getByRole("button", { name: "إعادة التحميل" })).toBeVisible();
  await page.screenshot({ path: "/tmp/proof/cf2-offline.png" });
  await context.setOffline(false);
  errors.splice(0);
});
