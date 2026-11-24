import { test, expect } from "./fixtures";
import { readFileSync } from "node:fs";

const TEST_LOGO = "data:image/png;base64," + readFileSync("tests/e2e/assets/hotel-mark.png").toString("base64");

const HOTEL_A = "00000000-0000-0000-0000-000000000001";
const HOTEL_B = "90000000-0000-0000-0000-000000000202";

test("guest hotel header uses its uploaded logo and footer attribution", async ({ page, loginAs, errors }) => {
  await loginAs("owner");
  await expect.poll(() => page.evaluate(() => !!localStorage.getItem("zaaer_demo_store_v9"))).toBe(true);
  await page.evaluate(({ HOTEL_B, TEST_LOGO }) => {
    const key = "zaaer_demo_store_v9";
    const store = JSON.parse(localStorage.getItem(key)!);
    store.organizations[0].logo = TEST_LOGO;
    store.organizations.push({ ...store.organizations[0], id: HOTEL_B, guest_slug: HOTEL_B, name_ar: "فندق النموذج الثاني", logo: null });
    store.branches.push({ ...store.branches[0], id: HOTEL_B, organization_id: HOTEL_B, name_ar: "فرع النموذج الثاني" });
    localStorage.setItem(key, JSON.stringify(store));
    sessionStorage.clear();
  }, { HOTEL_B, TEST_LOGO });
  await page.goto("about:blank");
  await page.goto(`/#/h/${HOTEL_A}/reception`);
  await expect(page.locator("header img")).toBeVisible();
  await expect.poll(() => page.locator("header img").evaluate((image: HTMLImageElement) => image.naturalWidth)).toBe(96);
  await expect(page.locator("header img")).toHaveAttribute("alt", /شعار/);
  await expect(page.locator("footer")).toContainText("يعمل بـ RoomAI");
  await expect(page.locator("header")).not.toContainText("RoomAI");
  const contrast = await page.locator("footer p").evaluate(element => {
    const rgb = getComputedStyle(element).color.match(/[\d.]+/g)!.slice(0, 3).map(Number);
    const linear = rgb.map(value => { const c = value / 255; return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; });
    const luminance = linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722;
    // Guest shell is white at the footer; translucent white footer retains white there.
    return 1.05 / (luminance + 0.05);
  });
  expect(contrast).toBeGreaterThanOrEqual(4.5);
  console.log(`Guest footer contrast on white: ${contrast.toFixed(2)}:1`);

  await page.screenshot({ path: "/downloads/h-branding-desktop.png", fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.screenshot({ path: "/downloads/h-branding-mobile.png", fullPage: true });
  await page.getByRole("link", { name: "سياسة الخصوصية", exact: true }).click();
  await expect(page).toHaveURL(new RegExp(`/h/${HOTEL_A}/privacy`));
  await page.getByRole("link", { name: /فايف اورز/ }).click();
  await expect(page).toHaveURL(new RegExp(`/h/${HOTEL_A}/?$`));
  await page.goto("about:blank");
  await page.goto(`/#/h/${HOTEL_B}/booking/lookup`);
  await expect(page.locator("header")).toContainText("فندق النموذج الثاني");
  await expect(page.locator("header img")).toHaveCount(0);
  await expect(page.getByTestId("guest-lang")).toBeVisible();
  await page.getByTestId("guest-lang").click();
  await expect(page.locator("footer")).toContainText("Powered by RoomAI");
  await expect(page.locator("header")).not.toContainText("فايف اورز");
  expect(errors).toEqual([]);
});
